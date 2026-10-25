#!/bin/bash
# Processor-usage-aware "emergency brake" for Immich.
#
# Measures how much CPU *non-Immich* work is using (system-wide minus the
# Immich containers), and adjusts hard CPU caps on immich-server and
# immich-machine-learning via `docker update --cpus`:
#
#   - Machine idle, no other work  -> Immich can go fast (caps ~full)
#   - Some other task(s) running   -> Throttle Immich away
#   - Heavy other load             -> Deep curb
#
# Intent: run as a cron job every minute (each run does one sampling window).
# State/hysteresis kept in .brake-state next to this script.
#
# Levels (cores, adjusted for the 4 threads of the i3-3240):
#   RELEASED : server 3.5 / ml 3.0   (nothing else running)
#   THROTTLE : server 1.0 / ml 0.4   (other work >0.4 cores)
#   CURB     : server 0.4 / ml 0.1   (other work >1.5 cores)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.brake-state"
LOG_FILE="$SCRIPT_DIR/cpu-brake.log"
# AUTO = this script decides caps dynamically; ECO/PWR = manual modes set by
# resource-control.sh (this script must not fight them).
[ "$(cat "$SCRIPT_DIR/.brake-mode" 2>/dev/null || echo AUTO)" = "AUTO" ] || exit 0
WINDOW=10          # sampling window in seconds
THREADS=4
SRV_CONTAINER=immich-server
ML_CONTAINER=immich-machine-learning

# release requires this many consecutive calm samples (won't steal CPU back
# immediately after a burst).
RELEASE_CALM_REQUIRED=3

set_level() { # $1=level, $2=description, $3=server cpus, $4=ml cpus
    local level=$1
    docker update --cpus "$3" "$SRV_CONTAINER" >/dev/null 2>&1 || true
    docker update --cpus "$4" "$ML_CONTAINER" >/dev/null 2>&1 || true
    echo "$level 0" > "$STATE_FILE"
    echo "$(date '+%F %T') level=$level descr=\"$2\" server=$3 ml=$4" >> "$LOG_FILE"
}

# ---- CPU usage sampling -------------------------------------------------
read_proc_stat_busy() { # outputs "busy idle"
    awk 'NR==1 {busy=$2+$4+$6+$8+$10; idle=$3+$5; print busy, idle}' /proc/stat
}

usage_cores() { # container cpu.stat usec -> cores over window
    awk -v w="$WINDOW" '{ if ($1=="usage_usec") { print $2/1000000/w } }' "$1" 2>/dev/null
}

busy_a=$(read_proc_stat_busy)
sleep "$WINDOW"
busy_b=$(read_proc_stat_busy)

read -r a_busy a_idle <<< "$busy_a"
read -r b_busy b_idle <<< "$busy_b"
d_busy=$(( b_busy - a_busy ))
d_idle=$(( b_idle - a_idle ))
total=$(( d_busy + d_idle ))
if (( total <= 0 )); then exit 0; fi

# Total occupied cores across the whole machine
busy_cores=$(awk -v b="$d_busy" -v t="$total" -v n="$THREADS" 'BEGIN { printf "%.2f", n * b / t }')

# Immich's share
immich_cores=0
for id in $(docker ps --filter "name=immich-server" --filter "name=immich-machine-learning" -q 2>/dev/null); do
    cg="/sys/fs/cgroup/system.slice/docker-${id}.scope/cpu.stat"
    immich_cores=$(awk -v a="$immich_cores" -v u="$(usage_cores "$cg")" 'BEGIN { printf "%.2f", a + u }')
done

# Non-Immich occupied cores
other_cores=$(awk -v a="$busy_cores" -v i="$immich_cores" 'BEGIN { o=a-i; if (o<0) o=0; printf "%.2f", o }')

# ---- Level decision with hysteresis ------------------------------------
read -r cur_level calm_count < "$STATE_FILE" 2>/dev/null || { cur_level=THROTTLE; calm_count=0; }
calm_count=${calm_count:-0}

compare() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

if compare "$other_cores" 1.5; then
    # heavy other load: curb immediately
    if [ "$cur_level" != "CURB" ]; then
        set_level CURB "heavy other CPU load" 0.4 0.1
    fi
elif compare "$other_cores" 0.4; then
    # some other work visible: throttle immediately
    if [ "$cur_level" != "THROTTLE" ] && [ "$cur_level" != "CURB" ]; then
        set_level THROTTLE "other work detected" 1.0 0.4
    fi
    echo "$cur_level 0" > "$STATE_FILE"
else
    # machine mostly free: only release after sustained calm
    calm_count=$(( calm_count + 1 ))
    if [ "$cur_level" != "RELEASED" ] && [ "$calm_count" -ge "$RELEASE_CALM_REQUIRED" ]; then
        set_level RELEASED "machine idle" 3.5 3.0
    else
        echo "$cur_level $calm_count" > "$STATE_FILE"
    fi
fi

# keep log small
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt 1048576 ]; then
    tail -c 262144 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi
