#!/bin/bash
# Processor-usage-aware "emergency brake" for Immich.
#
# Modes (set by resource-control.sh, stored in .brake-mode):
#   AUTO  : measures whole-machine CPU every run; when *non-Immich* work is
#           detected it throttles immich-server / immich-machine-learning via
#           `docker update --cpus`. Machine idle -> releases caps.
#   ECO   : hard-pins server=0.5 / ML=0.25 cores. Every run re-asserts the
#           caps if something (compose recreation, manual change) drifted them.
#   PWR   : uncaps both containers (4/4). Same re-assert logic.
#
# Scheduling:
#   ECO can be scheduled for a duration (resource-control.sh eco 4d11h9m).
#   Expiry is stored in .brake-expire (epoch seconds); when it passes the
#   brake automatically reverts the mode to AUTO.
#
# Intent: run as a cron job every minute. Each run does at most one 10s
# sampling window (only in AUTO mode).
#
# Levels (cores, tuned for the 4-thread i3-3240; edit THREADS/breakpoints
# to match your box):
#   RELEASED : server 3.5 / ml 3.0   (nothing else running)
#   THROTTLE : server 1.0 / ml 0.4   (other work >0.4 cores)
#   CURB     : server 0.4 / ml 0.1   (other work >1.5 cores)

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.brake-state"
MODE_FILE="$SCRIPT_DIR/.brake-mode"
EXPIRE_FILE="$SCRIPT_DIR/.brake-expire"
LOG_FILE="$SCRIPT_DIR/cpu-brake.log"
WINDOW=10          # sampling window in seconds (AUTO mode only)
THREADS=4          # nproc of your machine
RELEASE_CALM_REQUIRED=3
SRV_CONTAINER=immich-server
ML_CONTAINER=immich-machine-learning

log() { echo "$(date '+%F %T') $*" >> "$LOG_FILE"; }

caps_for_mode() { # $1=mode -> "server ml" core numbers
    case "$1" in
        ECO)  echo "0.5 0.25" ;;
        PWR)  echo "4 4" ;;
        AUTO) echo "3.5 3.0" ;;
        *)    echo "3.5 3.0" ;;
    esac
}

nano_for() { awk -v c="$1" 'BEGIN{ printf "%.0f", c * 1e9 }'; }

# ---- AUTO mode: dynamic evaluation ---------------------------------------
run_auto() {
    rm -f "$EXPIRE_FILE"   # no schedule while in AUTO

    read -r cur_level calm_count < "$STATE_FILE" 2>/dev/null \
        || { cur_level=THROTTLE; calm_count=0; }
    calm_count=${calm_count:-0}

    read -r busy_a idle_a <<< "$(awk 'NR==1{print $2+$4+$6+$8+$10, $3+$5}' /proc/stat)"
    sleep "$WINDOW"
    read -r busy_b idle_b <<< "$(awk 'NR==1{print $2+$4+$6+$8+$10, $3+$5}' /proc/stat)"
    d_busy=$(( busy_b - busy_a )); d_idle=$(( idle_b - idle_a ))
    total=$(( d_busy + d_idle ))
    if (( total <= 0 )); then exit 0; fi

    # Total occupied cores across the whole machine
    busy_cores=$(awk -v b="$d_busy" -v t="$total" -v n="$THREADS" \
        'BEGIN { printf "%.2f", n * b / t }')

    # Immich's share, summed over its containers
    immich_cores=0
    for id in $(docker ps --filter "name=immich-server" \
                   --filter "name=immich-machine-learning" -q 2>/dev/null); do
        cg="/sys/fs/cgroup/system.slice/docker-${id}.scope/cpu.stat"
        u=$(awk '$1=="usage_usec"{print $2}' "$cg" 2>/dev/null)
        immich_cores=$(awk -v a="$immich_cores" -v u="$u" -v w="$WINDOW" \
            'BEGIN { printf "%.2f", a + u/1000000/w }')
    done

    # Non-Immich occupied cores
    other_cores=$(awk -v a="$busy_cores" -v i="$immich_cores" \
        'BEGIN { o=a-i; if(o<0)o=0; printf "%.2f", o }')

    compare() { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a>=b) }'; }

    if compare "$other_cores" 1.5; then
        # heavy other load: curb immediately
        if [ "$cur_level" != "CURB" ]; then
            docker update --cpus 0.4 "$SRV_CONTAINER" >/dev/null 2>&1 || true
            docker update --cpus 0.1 "$ML_CONTAINER" >/dev/null 2>&1 || true
            echo "CURB 0" > "$STATE_FILE"
            log "level=CURB descr=\"heavy other CPU load\" server=0.4 ml=0.1"
        fi
    elif compare "$other_cores" 0.4; then
        # some other work visible: throttle immediately
        if [ "$cur_level" != "THROTTLE" ] && [ "$cur_level" != "CURB" ]; then
            docker update --cpus 1.0 "$SRV_CONTAINER" >/dev/null 2>&1 || true
            docker update --cpus 0.4 "$ML_CONTAINER" >/dev/null 2>&1 || true
            echo "THROTTLE 0" > "$STATE_FILE"
            log "level=THROTTLE descr=\"other work detected\" server=1.0 ml=0.4"
        else
            echo "$cur_level 0" > "$STATE_FILE"
        fi
    else
        # machine mostly free: only release after sustained calm
        calm_count=$(( calm_count + 1 ))
        if [ "$cur_level" != "RELEASED" ] && [ "$calm_count" -ge "$RELEASE_CALM_REQUIRED" ]; then
            docker update --cpus 3.5 "$SRV_CONTAINER" >/dev/null 2>&1 || true
            docker update --cpus 3.0 "$ML_CONTAINER" >/dev/null 2>&1 || true
            echo "RELEASED 0" > "$STATE_FILE"
            log "level=RELEASED descr=\"machine idle\" server=3.5 ml=3.0"
        else
            echo "$cur_level $calm_count" > "$STATE_FILE"
        fi
    fi

    # keep log small
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        tail -c 262144 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

# ---- ECO / PWR enforcement: re-assert fixed caps if they drifted ---------
enforce_fixed() {
    local mode=$1
    read -r expect_srv expect_ml <<< "$(caps_for_mode "$mode")"
    local cur_srv cur_ml need_update=0
    cur_srv=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$SRV_CONTAINER" 2>/dev/null)
    cur_ml=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$ML_CONTAINER" 2>/dev/null)

    local exp_srv_nano exp_ml_nano cur_srv_nano cur_ml_nano
    exp_srv_nano=$(nano_for "$expect_srv")
    exp_ml_nano=$(nano_for "$expect_ml")
    cur_srv_nano=${cur_srv:-0}
    cur_ml_nano=${cur_ml:-0}

    if [ "$cur_srv_nano" != "$exp_srv_nano" ]; then
        docker update --cpus "$expect_srv" "$SRV_CONTAINER" >/dev/null 2>&1 || true
        need_update=1
    fi
    if [ "$cur_ml_nano" != "$exp_ml_nano" ]; then
        docker update --cpus "$expect_ml" "$ML_CONTAINER" >/dev/null 2>&1 || true
        need_update=1
    fi

    if [ "$need_update" -eq 1 ]; then
        log "re-asserted $mode caps server=$expect_srv ml=$expect_ml"
    fi
    echo "$mode 0" > "$STATE_FILE"
}

# ---- main ----------------------------------------------------------------
MODE=$(cat "$MODE_FILE" 2>/dev/null || echo AUTO)

# Schedule expiry: a scheduled ECO past its revert time -> back to AUTO
if [ -f "$EXPIRE_FILE" ]; then
    now=$(date +%s)
    exp=$(cat "$EXPIRE_FILE" 2>/dev/null || echo 0)
    if [ "$now" -ge "$exp" ]; then
        echo AUTO > "$MODE_FILE"
        rm -f "$EXPIRE_FILE"
        MODE=AUTO
        echo "RELEASED 3" > "$STATE_FILE"
        log "schedule expired: ECO -> AUTO"
    fi
fi

case "$MODE" in
    ECO|PWR)  enforce_fixed "$MODE" ;;
    AUTO|*)   MODE=AUTO; echo AUTO > "$MODE_FILE"; run_auto ;;
esac
