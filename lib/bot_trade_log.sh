#!/bin/bash
# Append trade events to TRADES_LOG_FILE (set by ob_websocket / scalper_websocket)

log_trade() {
    if [ -z "${TRADES_LOG_FILE:-}" ]; then
        return 0
    fi
    local dir
    dir=$(dirname "$TRADES_LOG_FILE")
    [ -n "$dir" ] && [ "$dir" != "." ] && mkdir -p "$dir" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$TRADES_LOG_FILE"
}

# Create log files and write startup line (call from main() before trading)
init_bot_logs() {
    local bot_name="${1:-bot}"
    local ts line mode

    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "${DRY_RUN:-false}" = true ]; then
        mode="DRY-RUN"
    else
        mode="LIVE"
    fi
    line="[$ts] === $bot_name started | mode=$mode ==="

    local f dir
    for f in "${LOG_FILE:-}" "${ERROR_LOG_FILE:-}" "${TRADES_LOG_FILE:-}"; do
        [ -z "$f" ] && continue
        dir=$(dirname "$f")
        [ -n "$dir" ] && [ "$dir" != "." ] && mkdir -p "$dir" 2>/dev/null
        echo "$line" >> "$f"
    done

    if [ -n "${TRADES_LOG_FILE:-}" ]; then
        log_trade "START bot=$bot_name mode=$mode"
    fi
}
