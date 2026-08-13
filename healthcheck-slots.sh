#!/bin/sh
# Healthcheck that watches inference-slot progress. See README.md for details.
set -u

URL="${LLAMA_URL:-http://localhost:8080}"
STALL="${SLOT_STALL_SECONDS:-180}"
STATE="${SLOT_STATE_FILE:-/tmp/llama-slots-watch}"
UNRESP="${STATE}.unresponsive"

fetch_slots() {
    if [ -n "${LLAMA_SLOTS_FIXTURE:-}" ]; then
        cat "$LLAMA_SLOTS_FIXTURE"
    else
        curl -sf -m 5 "$URL/slots"
    fi
}

# Basic liveness check
if [ -z "${LLAMA_SLOTS_FIXTURE:-}" ]; then
    health=$(curl -sf -m 5 "$URL/health") || {
        echo "unhealthy: /health did not respond"
        exit 1
    }
    case "$health" in
        *'"ok"'*) ;;
        *) echo "unhealthy: /health returned: $health"; exit 1 ;;
    esac
fi

# Treat a /slots timeout (28) differently from other errors
slots=$(fetch_slots)
rc=$?
if [ $rc -ne 0 ]; then
    if [ $rc -eq 28 ]; then
        now=$(date +%s)
        first=$(cat "$UNRESP" 2>/dev/null)
        case "$first" in
            ''|*[!0-9]*) first=$now; printf '%s\n' "$now" > "$UNRESP" ;;
        esac
        down=$(( now - first ))
        if [ "$down" -ge "$STALL" ]; then
            echo "unhealthy: /slots unresponsive for ${down}s while /health was OK" \
                 "(wedged server, cf. llama.cpp #20921)"
            exit 1
        fi
        exit 0
    fi
    echo "warn: /slots unavailable (curl rc=$rc), falling back to /health only"
    exit 0
fi
rm -f "$UNRESP"

# No slot processing -> healthy
if ! printf '%s' "$slots" | grep -q '"is_processing":true'; then
    rm -f "$STATE" "$UNRESP"
    exit 0
fi

# Detect stalls by comparing a progress fingerprint
fp=$(printf '%s' "$slots" \
    | grep -o '"id_task":[-0-9]*\|"n_prompt_tokens_processed":[0-9]*\|"n_decoded":[0-9]*' \
    | tr '\n' ' ')
now=$(date +%s)

prev_ts=""
prev_fp=""
if [ -r "$STATE" ]; then
    prev_ts=$(sed -n 1p "$STATE")
    prev_fp=$(sed -n 2p "$STATE")
fi

if [ "$fp" != "$prev_fp" ] || [ -z "$prev_ts" ]; then
    printf '%s\n%s\n' "$now" "$fp" > "$STATE"
    exit 0
fi

stalled=$(( now - prev_ts ))
if [ "$stalled" -ge "$STALL" ]; then
    echo "unhealthy: slot made no progress for ${stalled}s (threshold ${STALL}s): $fp"
    exit 1
fi
exit 0
