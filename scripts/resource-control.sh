#!/usr/bin/env bash
#
# Immich Resource Control — switch Immich between power profiles and view
# the settings currently in effect.
#
#   Modes and what they mean (job concurrency + hard CPU caps):
#
#     ECO  : all job queues at concurrency 1, immich-server pinned to
#            0.5 cores and immich-machine-learning to 0.25 cores.
#            The emergency brake enforces these caps every minute, so the
#            lock survives container recreation or manual cap changes.
#
#     PWR  : Immich's default concurrency (thumbnail 3, metadata 5,
#            ML 2, ...), CPU caps removed (4/4). Backlogs drain fast,
#            other apps just have to share. Caps enforced every minute.
#
#     AUTO : all job queues at concurrency 1 but CPU caps released
#            (3.5/3.0) and the emergency brake (cron cpu-brake.sh)
#            decides every minute whether Immich goes fast or steps
#            aside. Backlog drains when you're not using the machine.
#
# Scheduling (ECO only):
#   resource-control.sh eco [DURATION]
#   DURATION examples: 4d11h9m   7h   20m   3d
#   After the duration elapses the mode auto-reverts to AUTO.
#
# Usage:  resource-control.sh            # interactive menu
#         resource-control.sh eco|pwr|auto   # immediate switch
#         resource-control.sh eco 4d11h9m    # ECO for that long, then AUTO

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PSQL="docker exec immich-postgres psql -U postgres -d immich"
LOG="$DIR/cpu-brake.log"

# job concurrency presets ----------------------------------------------------
JSON_LOW='{"job":{"thumbnailGeneration":{"concurrency":1},"metadataExtraction":{"concurrency":1},"videoConversion":{"concurrency":1},"faceDetection":{"concurrency":1},"smartSearch":{"concurrency":1},"backgroundTask":{"concurrency":1},"migration":{"concurrency":1},"search":{"concurrency":1},"sidecar":{"concurrency":1},"library":{"concurrency":1},"notifications":{"concurrency":1},"ocr":{"concurrency":1},"workflow":{"concurrency":1},"editor":{"concurrency":1},"integrityCheck":{"concurrency":1}}}'
JSON_HIGH='{"job":{"thumbnailGeneration":{"concurrency":3},"metadataExtraction":{"concurrency":5},"videoConversion":{"concurrency":1},"faceDetection":{"concurrency":2},"smartSearch":{"concurrency":2},"backgroundTask":{"concurrency":5},"migration":{"concurrency":5},"search":{"concurrency":5},"sidecar":{"concurrency":5},"library":{"concurrency":5},"notifications":{"concurrency":5},"ocr":{"concurrency":1},"workflow":{"concurrency":5},"editor":{"concurrency":2},"integrityCheck":{"concurrency":1}}}'

caps_for_mode() {
    case "$1" in
        ECO)  echo "0.5 0.25" ;;
        PWR)  echo "4 4" ;;
        AUTO) echo "3.5 3.0" ;;
        *)    echo "?" ;;
    esac
}

get_mode()      { cat "$DIR/.brake-mode" 2>/dev/null || echo AUTO; }
get_caps() {    # "server ml" core numbers from Docker, or "?"
    s=$(docker inspect -f '{{.HostConfig.NanoCpus}}' immich-server 2>/dev/null)
    m=$(docker inspect -f '{{.HostConfig.NanoCpus}}' immich-machine-learning 2>/dev/null)
    if [ -z "$s" ]; then echo "?"; return; fi
    awk -v s="$s" -v m="$m" 'BEGIN{ printf "%.1f/%.1f of 4 cores", s/1e9, m/1e9 }'
}

get_concurrency() {
    $PSQL -Atc "select value from system_metadata where key='system-config';" 2>/dev/null \
        | jq -r '.job | to_entries | sort_by(.key) | map("\(.key)=\(.value.concurrency // "?")") | join(" ")'
}

get_queues() {
    out=""
    for q in faceDetection smartSearch facialRecognition ocr thumbnailGeneration metadataExtraction; do
        n=$(docker exec immich-redis valkey-cli llen "immich_bull:$q:wait" 2>/dev/null)
        out="$out $q=$n"
    done
    echo "$out"
}

# duration helpers -----------------------------------------------------------
# parse_duration "4d11h9m" -> prints total seconds
parse_duration() {
    local s="$1" total=0 num rest unit
    [ -n "$s" ] || { echo "empty duration" >&2; return 1; }
    while [ -n "$s" ]; do
        num="${s%%[!0-9]*}"
        [ -n "$num" ] || { echo "invalid duration: $s" >&2; return 1; }
        rest="${s#"$num"}"
        unit="${rest:0:1}"
        s="${rest:1}"
        case "$unit" in
            d) total=$(( total + num * 86400 )) ;;
            h) total=$(( total + num * 3600 )) ;;
            m) total=$(( total + num * 60 )) ;;
            s) total=$(( total + num )) ;;
            *) echo "invalid duration unit '$unit' in $1" >&2; return 1 ;;
        esac
    done
    echo "$total"
}

# format_duration seconds -> 3d11h9m (omits zero parts)
format_duration() {
    local s=$1 d=0 h=0 m=0 out=""
    d=$(( s / 86400 )); s=$(( s % 86400 ))
    h=$(( s / 3600 ));  s=$(( s % 3600 ))
    m=$(( s / 60 ))
    [ "$d" -gt 0 ] && out="${out}${d}d"
    [ "$h" -gt 0 ] && out="${out}${h}h"
    [ "$m" -gt 0 ] && out="${out}${m}m"
    [ -z "$out" ] && out="0m"
    echo "$out"
}

# ---- status ----------------------------------------------------------------
show_status() {
    local mode; mode=$(get_mode)
    local caps; caps=$(get_caps)
    local brake; brake=$(awk '{printf "%s (calm counter %s)", $1, $2}' "$DIR/.brake-state" 2>/dev/null || echo "?")
    local mlstat
    mlstat=$(docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' immich-server immich-machine-learning 2>/dev/null | tr '\n' ' ' )

    local sched_line="" expiry_warning=""
    if [ "$mode" = ECO ] && [ -f "$DIR/.brake-expire" ]; then
        local now rem; now=$(date +%s); rem=$(( $(cat "$DIR/.brake-expire") - now ))
        if [ "$rem" -gt 0 ]; then
            sched_line=" [scheduled: reverts to AUTO in $(format_duration "$rem")]"
        else
            expiry_warning=" [expiring on next brake run]"
        fi
    fi

    echo ""
    echo "Immich Resource Control"
    echo "============================================================"
    if [ "$mode" = AUTO ]; then
        echo "Brake mode     : AUTO (emergency brake ACTIVE)$sched_line"
    else
        echo "Brake mode     : $mode (fixed caps, brake enforces)$sched_line$expiry_warning"
    fi
    echo "Brake state    : $brake"
    echo "CPU caps       : $caps"
    echo "ML tasks       : facialRecognition/OCR/smartSearch ENABLED, memories generation OFF"
    echo "Transcoding    : vaapi (QSV unsupported on this iGPU), 720p, ultrafast, two-pass off"
    echo "CPU shares     : server 512 / ML 256 of 1024"
    echo "Job concurrency: $(get_concurrency)"
    echo "Queues waiting :$(get_queues)"
    echo "Live usage     : $mlstat"
    echo "============================================================"
    echo "Resource Control Setting: [E]ECO mode  [P]PWR mode  [A]AUTO mode  [R]refresh  [Q]Quit"
    echo -n "Choice: "
}

# ---- mode switching --------------------------------------------------------
apply_mode() {
    local mode="$1"
    local jobs_json caps srv ml cur changed=0 want now
    cur=$(get_mode)

    case "$mode" in
        ECO)  jobs_json="$JSON_LOW" ;;
        PWR)  jobs_json="$JSON_HIGH" ;;
        AUTO) jobs_json="$JSON_LOW" ;;
        *) echo "Unknown mode: $mode"; return 1 ;;
    esac
    read -r srv ml <<< "$(caps_for_mode "$mode")"

    # 1. CPU caps (instant, no restart needed)
    docker update --cpus "$srv" immich-server >/dev/null 2>&1
    docker update --cpus "$ml" immich-machine-learning >/dev/null 2>&1

    # 2. mode file + brake state
    echo "$mode" > "$DIR/.brake-mode"
    if [ "$mode" = AUTO ]; then
        echo "RELEASED 3" > "$DIR/.brake-state"   # release immediately
        rm -f "$DIR/.brake-expire"          # cancel any pending schedule
    else
        echo "$mode 0" > "$DIR/.brake-state"
    fi

    # 3. job concurrency (DB) — restart immich-server only if it changed
    want=$(echo "$jobs_json" | jq -cS '.job')
    now=$($PSQL -Atc "select value from system_metadata where key='system-config';" 2>/dev/null \
        | jq -cS '.job // {}')
    if [ "$want" != "$now" ]; then
        $PSQL -c "UPDATE system_metadata SET value = value || '${jobs_json}'::jsonb WHERE key='system-config';" >/dev/null
        echo "Applying job concurrency for $mode mode (restarting immich-server, ~20s)..."
        docker restart immich-server >/dev/null
        changed=1
    fi

    echo "$(date '+%F %T') manual mode switch $cur -> $mode (caps server=$srv ml=$ml, concurrency_changed=$changed)" >> "$LOG"
    echo ""
    echo ">> Mode set to $mode: caps server=${srv} cores / ML=${ml} cores."
}

apply_scheduled() { # $1=mode, $2=optional duration string
    local mode=$1 sched_input=$2
    if [ -z "$sched_input" ]; then
        rm -f "$DIR/.brake-expire"
        apply_mode "$mode"
    else
        local seconds expiry
        seconds=$(parse_duration "$sched_input")
        if [ $? -ne 0 ]; then return 1; fi
        expiry=$(( $(date +%s) + seconds ))
        echo "$expiry" > "$DIR/.brake-expire"
        apply_mode "$mode"
        echo ">> $mode scheduled for $(format_duration "$seconds"), then auto-reverts to AUTO."
    fi
}

# ---- dispatcher ------------------------------------------------------------
if [ $# -ge 1 ]; then
    mode_arg=$(echo "$1" | tr 'a-z' 'A-Z')
    case "$mode_arg" in
        ECO|PWR|AUTO)
            if [ "$mode_arg" != AUTO ] && [ $# -ge 2 ]; then
                seconds=$(parse_duration "$2")
                if [ $? -ne 0 ]; then exit 1; fi
                expiry=$(( $(date +%s) + seconds ))
                echo "$expiry" > "$DIR/.brake-expire"
                echo "Scheduling $mode_arg for $(format_duration "$seconds"), then auto-revert to AUTO."
            else
                rm -f "$DIR/.brake-expire"
            fi
            apply_mode "$mode_arg"
            show_status
            exit 0
            ;;
        *)
            echo "Usage: $0 [eco|pwr|auto [DURATION]]"
            echo "  DURATION (eco only): e.g. 4d11h9m  7h  20m  3d"
            exit 1
            ;;
    esac
fi

while true; do
    show_status
    read -rn1 choice < /dev/tty 2>/dev/null || read -rn1 choice
    echo ""
    case "$choice" in
        e|E)
            echo -n "Toggle to ECO [Enter] or Schedule ECO (input in format: 4d11h9m or 7h or 20m or 3d): "
            read -r sched_input < /dev/tty 2>/dev/null || read -r sched_input
            echo ""
            apply_scheduled ECO "$sched_input"
            ;;
        p|P)
            echo -n "Toggle to PWR [Enter] or Schedule PWR (input in format: 4d11h9m or 7h or 20m or 3d): "
            read -r sched_input < /dev/tty 2>/dev/null || read -r sched_input
            echo ""
            apply_scheduled PWR "$sched_input"
            ;;
        a|A) rm -f "$DIR/.brake-expire"; apply_mode AUTO ;;
        r|R) ;;
        q|Q) echo "Bye."; exit 0 ;;
        *) ;;
    esac
done
