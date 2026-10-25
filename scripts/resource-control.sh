#!/usr/bin/env bash
#
# Immich Resource Control — switch Immich between power profiles and view
# the settings currently in effect.
#
#   Modes and what they mean (job concurrency + hard CPU caps):
#
#     ECO  : all job queues at concurrency 1, immich-server pinned to
#            0.5 cores and immich-machine-learning to 0.25 cores.
#            The emergency brake is disabled (caps stay fixed).
#
#     PWR  : Immich's default concurrency (thumbnail 3, metadata 5,
#            ML 2, ...), CPU caps removed (4/4). Backlogs drain fast,
#            other apps just have to share.
#            The emergency brake is disabled (caps stay fixed).
#
#     AUTO : all job queues at concurrency 1 but CPU caps released
#            (3.5/3.0) and the emergency brake (cron cpu-brake.sh)
#            decides every minute whether Immich goes fast or steps
#            aside. Backlog drains when you're not using the machine.
#
# Usage:  resource-control.sh            # interactive menu
#         resource-control.sh eco|pwr|auto   # non-interactive

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

# ---- status helpers --------------------------------------------------------
get_mode()      { cat "$DIR/.brake-mode" 2>/dev/null || echo AUTO; }
get_caps() {    # "server ml" core numbers from Docker, or "unlimited"
    s=$(docker inspect -f '{{.HostConfig.NanoCpus}}' immich-server 2>/dev/null)
    m=$(docker inspect -f '{{.HostConfig.NanoCpus}}' immich-machine-learning 2>/dev/null)
    if [ -z "$s" ]; then echo "?"; return; fi
    awk -v s="$s" -v m="$m" 'BEGIN{ printf "%.1f/%.1f of 4 cores", s/1e9, m/1e9 }'
}

get_concurrency() {  # one line: "queue=1 queue=1 ..."
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

show_status() {
    local mode; mode=$(get_mode)
    local caps; caps=$(get_caps)
    local brake; brake=$(awk '{printf "%s (calm counter %s)", $1, $2}' "$DIR/.brake-state" 2>/dev/null || echo "?")
    local mlstat
    mlstat=$(docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' immich-server immich-machine-learning 2>/dev/null | tr '\n' ' ' )
    echo ""
    echo "Immich Resource Control"
    echo "============================================================"
    echo "Brake mode     : $mode $( [ "$mode" = AUTO ] && echo "(emergency brake ACTIVE)" || echo "(fixed caps, brake disabled)" )"
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
    local jobs_json caps srv ml cur
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
        echo "RELEASED 3" > "$DIR/.brake-state"   # brake releases caps immediately
    else
        echo "$mode 0" > "$DIR/.brake-state"
    fi

    # 3. job concurrency (DB) — restart immich-server only if it changed
    local changed=0
    local want now
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

# ---- dispatcher ------------------------------------------------------------
if [ $# -ge 1 ]; then
    apply_mode "$(echo "$1" | tr 'a-z' 'A-Z')"
    show_status
    exit 0
fi

while true; do
    show_status
    read -rn1 choice < /dev/tty 2>/dev/null || read -rn1 choice
    echo ""
    case "$choice" in
        e|E) apply_mode ECO ;;
        p|P) apply_mode PWR ;;
        a|A) apply_mode AUTO ;;
        r|R) ;;
        q|Q) echo "Bye."; exit 0 ;;
        *) ;;
    esac
done
