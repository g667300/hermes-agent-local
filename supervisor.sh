#!/bin/sh
# Runs llama-server as a child process and SIGKILLs it (then exits) once a
# slot stall is detected. See README.md for details.
set -u

BIN="${LLAMA_BIN:-/app/llama-server}"
CHECK="${WATCH_CHECK:-/healthcheck-slots.sh}"
POLL="${WATCH_POLL_SECONDS:-30}"
GRACE="${WATCH_START_PERIOD:-120}"
STATE="${WATCH_STATE_FILE:-/tmp/llama-slots-supervisor}"

log() { printf '%s supervisor: %s\n' "$(date '+%F %T')" "$*"; }

"$BIN" "$@" &
CHILD=$!
log "started llama-server (pid $CHILD), poll=${POLL}s grace=${GRACE}s"

# Propagate docker stop to the child process
forward() {
    log "forwarding SIG$1 to pid $CHILD"
    kill -"$1" "$CHILD" 2>/dev/null
    wait "$CHILD"
    exit $?
}
trap 'forward TERM' TERM
trap 'forward INT' INT

STARTED=$(date +%s)

while true; do
    sleep "$POLL" &
    wait $! 2>/dev/null

    # Detect the child exiting (including crashes) via zombie state
    st=$(sed 's/.*) //' /proc/"$CHILD"/stat 2>/dev/null | cut -d' ' -f1)
    if [ -z "$st" ] || [ "$st" = "Z" ]; then
        wait "$CHILD"
        rc=$?
        log "llama-server exited (rc=$rc)"
        exit "$rc"
    fi

    # Grace period right after startup while the model is loading
    now=$(date +%s)
    if [ $(( now - STARTED )) -lt "$GRACE" ]; then
        continue
    fi

    out=$(SLOT_STATE_FILE="$STATE" sh "$CHECK" 2>&1)
    if [ $? -ne 0 ]; then
        log "stall detected: $out"
        log "SIGKILL llama-server (pid $CHILD)"
        kill -KILL "$CHILD" 2>/dev/null
        wait "$CHILD" 2>/dev/null
        exit 1
    fi
done
