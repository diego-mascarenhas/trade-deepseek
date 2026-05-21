#!/bin/bash

# ============================================
# Advanced Scalper Bot v3.0 - Full Version
# - Direct Binance REST & WebSocket orders
# - Multiple order execution modes
# - macOS compatible (no associative arrays)
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Binance precision helpers (required external lib — no inline duplicate)
BINANCE_PRECISION_LIB="$SCRIPT_DIR/lib/binance_precision.sh"
if [ ! -f "$BINANCE_PRECISION_LIB" ]; then
    BINANCE_PRECISION_LIB="$SCRIPT_DIR/binance_precision.sh"
fi
if [ ! -f "$BINANCE_PRECISION_LIB" ]; then
    echo "❌ Error: lib/binance_precision.sh not found"
    echo "   Expected: $SCRIPT_DIR/lib/binance_precision.sh"
    echo "   Deploy the lib/ folder next to this script."
    exit 1
fi
# shellcheck source=lib/binance_precision.sh
source "$BINANCE_PRECISION_LIB"
if [ ! -f "$SCRIPT_DIR/lib/terminal_display.sh" ]; then
    echo "❌ Error: lib/terminal_display.sh not found in $SCRIPT_DIR/lib/"
    exit 1
fi
# shellcheck source=lib/terminal_display.sh
source "$SCRIPT_DIR/lib/terminal_display.sh"
if [ ! -f "$SCRIPT_DIR/lib/ob_symbol_state.sh" ]; then
    echo "❌ Error: lib/ob_symbol_state.sh not found in $SCRIPT_DIR/lib/"
    exit 1
fi
# shellcheck source=lib/ob_symbol_state.sh
source "$SCRIPT_DIR/lib/ob_symbol_state.sh"
if [ ! -f "$SCRIPT_DIR/lib/binance_timestamp.sh" ]; then
    echo "❌ Error: lib/binance_timestamp.sh not found in $SCRIPT_DIR/lib/"
    exit 1
fi
# shellcheck source=lib/binance_timestamp.sh
source "$SCRIPT_DIR/lib/binance_timestamp.sh"
if [ -f "$SCRIPT_DIR/lib/binance_position_mode.sh" ]; then
    # shellcheck source=lib/binance_position_mode.sh
    source "$SCRIPT_DIR/lib/binance_position_mode.sh"
fi
if [ -f "$SCRIPT_DIR/lib/binance_order_guard.sh" ]; then
    # shellcheck source=lib/binance_order_guard.sh
    source "$SCRIPT_DIR/lib/binance_order_guard.sh"
fi
if [ -f "$SCRIPT_DIR/lib/scalper_ob_dca.sh" ]; then
    # shellcheck source=lib/scalper_ob_dca.sh
    source "$SCRIPT_DIR/lib/scalper_ob_dca.sh"
fi

# ============================================
# LOAD CONFIGURATION
# ============================================

if [ -f .env ]; then
    source .env
else
    echo "❌ Error: .env not found"
    exit 1
fi

# ============================================
# CONFIGURATION
# ============================================

# Binance WebSocket (public - no auth)
WS_BASE_URL="wss://fstream.binance.com"
SYMBOLS="${SCALPER_SYMBOLS:-BTCUSDT,ETHUSDT,SOLUSDT}"
DRY_RUN=false
SYMBOL_CLI=""
SINGLE_SYMBOL_MODE=false
DEPTH="${SCALPER_OB_DEPTH:-10}"
SPEED="${SCALPER_WS_SPEED:-500ms}"

# Order execution mode: finandy, rest, websocket
ORDER_EXECUTION_MODE="${ORDER_EXECUTION_MODE:-rest}"

# Binance API Keys (required for rest/websocket modes)
BINANCE_API_KEY="${BINANCE_API_KEY:-}"
BINANCE_SECRET_KEY="${BINANCE_SECRET_KEY:-}"

# Trading parameters
TP_PERCENT="${SCALPER_TP_PERCENT:-0.5}"
SL_PERCENT="${SCALPER_SL_PERCENT:-0.3}"
MIN_CONFIDENCE="${SCALPER_MIN_CONFIDENCE:-70}"

# Volatile market settings
VOLATILE_THRESHOLD="${SCALPER_VOLATILE_THRESHOLD:-15}"
SL_VOLATILE_MIN="${SCALPER_SL_VOLATILE_MIN:-0.8}"
TP_VOLATILE_MIN="${SCALPER_TP_VOLATILE_MIN:-1.0}"
MIN_SL_SPREAD_MULT="${SCALPER_MIN_SL_SPREAD_MULT:-3}"
POSITION_SIZE_USDT="${SCALPER_POSITION_SIZE_USDT:-50}"

# Confirmation thresholds
RSI_OVERSOLD=30
RSI_OVERBOUGHT=70
STOCH_OVERSOLD=20
STOCH_OVERBOUGHT=80
ADX_TREND_THRESHOLD=25
MIN_LIQUIDITY_USD=50000

# Analysis cycle (seconds)
CYCLE_INTERVAL="${SCALPER_CYCLE_INTERVAL:-5}"

# Place STOP/TP on Binance after entry LIMIT fills (REST mode)
REST_PLACE_SL_TP="${REST_PLACE_SL_TP:-true}"
REST_SL_TP_FILL_WAIT="${REST_SL_TP_FILL_WAIT:-90}"
REST_SL_TP_POLL_INTERVAL="${REST_SL_TP_POLL_INTERVAL:-2}"

# OB-based DCA grid (5 levels; level 4 = SL on Binance after first fill)
SCALPER_DCA_ENABLED="${SCALPER_DCA_ENABLED:-false}"
SCALPER_DCA_LEVELS="${SCALPER_DCA_LEVELS:-5}"
SCALPER_DCA_SL_LEVEL="${SCALPER_DCA_SL_LEVEL:-4}"
SCALPER_DCA_MIN_DISTANCE_PCT="${SCALPER_DCA_MIN_DISTANCE_PCT:-0.15}"
SCALPER_DCA_LIMIT_ORDERS="${SCALPER_DCA_LIMIT_ORDERS:-4}"
# When DCA on, skip generic % SL (grid L4 is the stop)
REST_PLACE_SL_TP="${REST_PLACE_SL_TP:-true}"
if [ "$(echo "${SCALPER_DCA_ENABLED}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
    REST_PLACE_SL_TP=false
fi

# Close open position when price touches opposite OB wall
OB_CLOSE_ON_OPPOSITE="${OB_CLOSE_ON_OPPOSITE:-${SCALPER_OB_CLOSE_OPPOSITE:-true}}"
OB_ZONE_UPPER_PCT="${OB_ZONE_UPPER_PCT:-${SCALPER_OB_ZONE_UPPER:-80}}"
OB_ZONE_LOWER_PCT="${OB_ZONE_LOWER_PCT:-${SCALPER_OB_ZONE_LOWER:-20}}"

# Finandy webhook (for finandy mode)
FINANDY_WEBHOOK="${FINANDY_WEBHOOK:-https://hook.finandy.com/LMEnRji-3GvFkm7wqFUK}"
FINANDY_SECRET="${FINANDY_SECRET:-d1a01uf5uoe}"

# Telegram
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Directories
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
BOT_LOG_BASE_DIR="$SCRIPT_DIR"
LOG_FILE="${SCALPER_LOG_FILE:-$LOG_DIR/scalper.log}"
ERROR_LOG_FILE="${SCALPER_ERROR_LOG_FILE:-$LOG_DIR/scalper_errors.log}"
TRADES_LOG_FILE="${SCALPER_TRADES_LOG_FILE:-$LOG_DIR/scalper_trades.log}"
[[ "$LOG_FILE" != /* ]] && LOG_FILE="$SCRIPT_DIR/${LOG_FILE#./}"
[[ "$ERROR_LOG_FILE" != /* ]] && ERROR_LOG_FILE="$SCRIPT_DIR/${ERROR_LOG_FILE#./}"
[[ "$TRADES_LOG_FILE" != /* ]] && TRADES_LOG_FILE="$SCRIPT_DIR/${TRADES_LOG_FILE#./}"
TRADES_LOG_HEARTBEAT_SECONDS="${TRADES_LOG_HEARTBEAT_SECONDS:-300}"
LAST_TRADES_HEARTBEAT=0
if [ -f "$SCRIPT_DIR/lib/bot_trade_log.sh" ]; then
    # shellcheck source=lib/bot_trade_log.sh
    source "$SCRIPT_DIR/lib/bot_trade_log.sh"
else
    log_trade() { :; }
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================
# GLOBAL VARIABLES
# ============================================

CURRENT_SYMBOL=""
# Order book per symbol: ob_set/ob_get (lib/ob_symbol_state.sh)
RSI_VALUE="50"
STOCH_K="50"
ADX_VALUE="20"
ICHOCH_SIGNAL="NEUTRAL"
CHANGE_24H="0"
LAST_CYCLE_TIME=0
CURRENT_INDEX=0
NUM_SYMBOLS=0
declare -a SYMBOL_ARRAY

# ============================================
# HELPER FUNCTIONS
# ============================================

show_usage() {
    echo "Usage: $(basename "$0") [options] [SYMBOL]"
    echo ""
    echo "Options:"
    echo "  -d, --dry-run    Do not send orders"
    echo "  -h, --help       Show this help"
    echo ""
    echo "Arguments:"
    echo "  SYMBOL           Trade only this pair (e.g. BCHUSDT). Overrides SCALPER_SYMBOLS."
    echo ""
    echo "Examples:"
    echo "  $(basename "$0")                    # all symbols from .env"
    echo "  $(basename "$0") BCHUSDT            # single symbol only"
    echo "  $(basename "$0") --dry-run BCHUSDT"
    echo ""
    echo "Env: SCALPER_ALT_SCREEN=0  disable alternate screen (append log instead)"
}

if [ ! -f "$SCRIPT_DIR/lib/cli_symbols.sh" ]; then
    echo "❌ Error: lib/cli_symbols.sh not found in $SCRIPT_DIR/lib/"
    exit 1
fi
# shellcheck source=lib/cli_symbols.sh
source "$SCRIPT_DIR/lib/cli_symbols.sh"
parse_cli_args "$@"
init_symbol_list

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" | tee -a "$ERROR_LOG_FILE"
}

bc_safe_div() {
    local numerator="$1"
    local denominator="$2"
    if [ -z "$denominator" ] || ! (( $(echo "$denominator > 0" | bc -l 2>/dev/null) )); then
        echo "0"
        return 0
    fi
    echo "scale=8; $numerator / $denominator" | bc -l 2>/dev/null || echo "0"
}

send_telegram() {
    local message="$1"
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        return 1
    fi
    
    # No usar parse_mode, enviar texto plano
    # Solo escapar backslashes para JSON
    local msg=$(echo "$message" | sed 's/\\/\\\\/g')
    
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": \"${msg}\"}" > /dev/null
}

calculate_quantity() {
    local symbol="$1"
    local entry_price="$2"
    if [ -z "$entry_price" ] || ! (( $(echo "$entry_price > 0" | bc -l 2>/dev/null) )); then
        round_qty_for_symbol "$symbol" "0.001"
        return 0
    fi
    local raw_qty
    raw_qty=$(bc_safe_div "$POSITION_SIZE_USDT" "$entry_price")
    round_qty_for_symbol "$symbol" "$raw_qty"
}

# ============================================
# ORDER EXECUTION MODES
# ============================================

# Mode 1: Finandy Webhook
send_order_finandy() {
    local symbol="$1" direction="$2" entry="$3" sl="$4" tp="$5"
    
    local side="buy" pos_side="long"
    if [ "$direction" = "SHORT" ]; then
        side="sell"
        pos_side="short"
    fi
    
    local order_name="Scalp_${symbol}_$(date '+%Y%m%d_%H%M%S')"
    
    local payload=$(cat <<EOF
{
  "name": "$order_name",
  "secret": "$FINANDY_SECRET",
  "symbol": "$symbol",
  "side": "$side",
  "positionSide": "$pos_side",
  "open": {
    "price": "$entry",
    "schedulerMode": "min",
    "schedulerValue": "2"
  },
  "tp": {
    "enabled": true,
    "orders": [{"price": "$tp", "piece": "100.0"}]
  },
  "sl": {"price": "$sl", "enabled": true}
}
EOF
)
    
    log "📝 [FINANDY] $symbol $direction | Entry:$entry SL:$sl TP:$tp"
    
    if [ "$DRY_RUN" = true ]; then
        log "🔍 DRY-RUN: Would execute via Finandy"
        log_trade "DRY-RUN OPEN $symbol $direction entry=$entry sl=$sl tp=$tp mode=FINANDY"
        send_telegram "🔍 [DRY-RUN] $symbol $direction Entry:$entry"
        return 0
    fi
    
    local response=$(curl -s -X POST "$FINANDY_WEBHOOK" -H "Content-Type: application/json" -d "$payload")
    
    if echo "$response" | jq -e '.code == 200 or .success == true' >/dev/null 2>&1; then
        log "✅ Order executed via Finandy: $symbol"
        log_trade "OPEN $symbol $direction entry=$entry sl=$sl tp=$tp mode=FINANDY status=ok"
        send_telegram "✅ ORDER: $symbol $direction Entry:$entry"
    else
        log_error "Order failed: $response"
        log_trade "FAILED OPEN $symbol $direction entry=$entry mode=FINANDY response=$(echo "$response" | tr -d '\n')"
    fi
}

# Mode 2: Binance REST API
send_order_binance_rest() {
    local symbol="$1" direction="$2" entry="$3" sl="$4" tp="$5"
    
    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        log_error "Binance API keys not configured for REST mode"
        return 1
    fi
    
    local side="BUY"
    if [ "$direction" = "SHORT" ]; then
        side="SELL"
    fi
    
    local quantity
    quantity=$(calculate_quantity "$symbol" "$entry")
    local timestamp
    timestamp=$(binance_timestamp_ms)
    local recv_window=5000
    
    local query_string="symbol=$symbol&side=$side&type=LIMIT&timeInForce=GTC&quantity=$quantity&price=$entry&timestamp=$timestamp&recvWindow=$recv_window"
    if declare -f append_position_side_param >/dev/null 2>&1; then
        query_string=$(append_position_side_param "$direction" "$query_string")
    fi
    
    local signature
    signature=$(echo -n "$query_string" | openssl dgst -sha256 -hmac "$BINANCE_SECRET_KEY" | awk '{print $2}')
    
    log "📝 [REST] $symbol $direction | Entry:$entry SL:$sl TP:$tp | Qty:$quantity"
    
    if [ "$DRY_RUN" = true ]; then
        log "🔍 DRY-RUN: Would execute via Binance REST"
        log_trade "DRY-RUN OPEN $symbol $direction entry=$entry sl=$sl tp=$tp qty=$quantity mode=REST"
        send_telegram "🔍 [DRY-RUN] $symbol $direction Entry:$entry"
        return 0
    fi
    
    local response=$(curl -s -X POST "https://fapi.binance.com/fapi/v1/order" \
        -H "X-MBX-APIKEY: $BINANCE_API_KEY" \
        -d "$query_string&signature=$signature")
    
    if echo "$response" | jq -e '.orderId' >/dev/null 2>&1; then
        local order_id
        order_id=$(echo "$response" | jq -r '.orderId' 2>/dev/null)
        log "✅ Order executed via Binance REST: $symbol (orderId $order_id)"
        log_trade "OPEN $symbol $direction entry=$entry sl=$sl tp=$tp qty=$quantity mode=REST status=ok orderId=$order_id"
        send_telegram "✅ [REST] $symbol $direction Entry:$entry"
        if declare -f ob_set >/dev/null 2>&1; then
            ob_set ACTIVE "$symbol" "true"
            ob_set ACTIVE_TS "$symbol" "$(date +%s)"
            ob_set POS_DIR "$symbol" "$direction"
            ob_set LAST_ENTRY "$symbol" "$entry"
        fi
        if declare -f futures_place_sl_tp_after_entry >/dev/null 2>&1; then
            (
                export TRADES_LOG_FILE BOT_LOG_BASE_DIR BINANCE_API_KEY BINANCE_SECRET_KEY
                export DRY_RUN REST_PLACE_SL_TP REST_SL_TP_FILL_WAIT REST_SL_TP_POLL_INTERVAL
                export BINANCE_HEDGE_MODE
                futures_place_sl_tp_after_entry "$symbol" "$direction" "$sl" "$tp" "$quantity" "$order_id" log
            ) &
        fi
    else
        log_error "REST order failed: $response"
        log_trade "FAILED OPEN $symbol $direction entry=$entry qty=$quantity mode=REST response=$(echo "$response" | tr -d '\n')"
    fi
}

# Mode 3: Binance WebSocket (simplified - requires external tool)
send_order_binance_ws() {
    local symbol="$1" direction="$2" entry="$3" sl="$4" tp="$5"
    
    log "📝 [WEBSOCKET] $symbol $direction | Entry:$entry SL:$sl TP:$tp"
    
    if [ "$DRY_RUN" = true ]; then
        log "🔍 DRY-RUN: Would execute via Binance WebSocket"
        log_trade "DRY-RUN OPEN $symbol $direction entry=$entry sl=$sl tp=$tp mode=WEBSOCKET"
        send_telegram "🔍 [DRY-RUN] $symbol $direction Entry:$entry"
        return 0
    fi
    
    log_error "WebSocket order execution requires additional setup (websocat with custom script)"
    log_error "Falling back to REST mode for this order"
    send_order_binance_rest "$symbol" "$direction" "$entry" "$sl" "$tp"
}

# Universal order dispatcher
send_order() {
    local symbol="$1" direction="$2" entry="$3" sl="$4" tp="$5"
    
    entry=$(round_price_for_symbol "$symbol" "$entry")
    sl=$(round_price_for_symbol "$symbol" "$sl")
    tp=$(round_price_for_symbol "$symbol" "$tp")

    if declare -f clamp_limit_price_for_order >/dev/null 2>&1; then
        local mark clamped_entry
        mark=$(get_futures_mark_price "$symbol")
        clamped_entry=$(clamp_limit_price_for_order "$symbol" "$direction" "$entry" "$mark")
        if [ -n "$clamped_entry" ] && [ "$clamped_entry" != "$entry" ]; then
            log "⚠️ Entry clamped for $symbol $direction: $entry → $clamped_entry (mark=$mark)"
            entry="$clamped_entry"
        fi
    fi
    entry=$(round_price_for_symbol "$symbol" "$entry")
    sl=$(round_price_for_symbol "$symbol" "$sl")
    tp=$(round_price_for_symbol "$symbol" "$tp")

    local dca_on=false
    case "$(echo "${SCALPER_DCA_ENABLED}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on) dca_on=true ;;
    esac

    if [ "$dca_on" = true ] && [ "$ORDER_EXECUTION_MODE" = "rest" ] \
        && declare -f send_scalper_ob_dca_grid >/dev/null 2>&1; then
        if declare -f can_place_dca_grid >/dev/null 2>&1 && ! can_place_dca_grid "$symbol" log; then
            log_trade "SKIP_DCA_GRID $symbol $direction reason=guard_blocked"
            return 0
        fi
        local total_qty
        total_qty=$(calculate_quantity "$symbol" "$entry")
        send_scalper_ob_dca_grid "$symbol" "$direction" "$entry" "$tp" "$total_qty" log
        return 0
    fi

    if declare -f can_place_new_order >/dev/null 2>&1; then
        if ! can_place_new_order "$symbol" "$direction" "$entry" log; then
            log_trade "SKIP_ORDER $symbol $direction entry=$entry reason=guard_blocked"
            return 0
        fi
    fi
    
    case "$ORDER_EXECUTION_MODE" in
        "finandy")
            send_order_finandy "$symbol" "$direction" "$entry" "$sl" "$tp"
            ;;
        "rest")
            send_order_binance_rest "$symbol" "$direction" "$entry" "$sl" "$tp"
            ;;
        "websocket")
            send_order_binance_ws "$symbol" "$direction" "$entry" "$sl" "$tp"
            ;;
        *)
            log_error "Unknown ORDER_EXECUTION_MODE: $ORDER_EXECUTION_MODE"
            return 1
            ;;
    esac
}

# ============================================
# CALCULATE INDICATORS
# ============================================

calculate_rsi() {
    local symbol="$1"
    local period=14
    
    local klines=$(curl -s "https://api.binance.com/api/v3/klines?symbol=$symbol&interval=1m&limit=15" 2>/dev/null)
    
    local gains=0
    local losses=0
    local prev_close=0
    
    for i in $(seq 0 13); do
        local close=$(echo "$klines" | jq -r ".[$i][4]" 2>/dev/null)
        if [ "$prev_close" != "0" ] && [ -n "$close" ] && [ "$close" != "null" ]; then
            local change=$(echo "$close - $prev_close" | bc -l 2>/dev/null)
            if [ -n "$change" ] && (( $(echo "$change > 0" | bc -l 2>/dev/null) )); then
                gains=$(echo "$gains + $change" | bc -l 2>/dev/null)
            elif [ -n "$change" ]; then
                losses=$(echo "$losses - $change" | bc -l 2>/dev/null)
            fi
        fi
        prev_close=$close
    done
    
    if [ -z "$losses" ] || (( $(echo "$losses == 0" | bc -l 2>/dev/null) )); then
        echo "100"
    else
        local rs=$(bc_safe_div "$gains" "$losses")
        local rsi_denom=$(echo "1 + $rs" | bc -l 2>/dev/null)
        local rsi="50"
        if [ -n "$rsi_denom" ] && (( $(echo "$rsi_denom != 0" | bc -l 2>/dev/null) )); then
            rsi=$(echo "100 - (100 / $rsi_denom)" | bc -l 2>/dev/null)
        fi
        printf "%.0f" "${rsi:-50}"
    fi
}

calculate_stochastic() {
    local symbol="$1"
    local period=14
    
    local klines=$(curl -s "https://api.binance.com/api/v3/klines?symbol=$symbol&interval=1m&limit=$((period + 5))" 2>/dev/null)
    
    local highest_high=0
    local lowest_low=999999999
    
    for i in $(seq 0 $((period - 1))); do
        local high=$(echo "$klines" | jq -r ".[$i][2]" 2>/dev/null)
        local low=$(echo "$klines" | jq -r ".[$i][3]" 2>/dev/null)
        
        if [ -n "$high" ] && [ "$high" != "null" ] && [ -n "$low" ] && [ "$low" != "null" ]; then
            if (( $(echo "$high > $highest_high" | bc -l 2>/dev/null) )); then
                highest_high=$high
            fi
            if (( $(echo "$low < $lowest_low" | bc -l 2>/dev/null) )); then
                lowest_low=$low
            fi
        fi
    done
    
    local current_close=$(echo "$klines" | jq -r ".[$((period - 1))][4]" 2>/dev/null)
    local stoch="50"
    if [ -n "$current_close" ] && [ "$current_close" != "null" ] \
        && (( $(echo "$highest_high > $lowest_low" | bc -l 2>/dev/null) )); then
        stoch=$(bc_safe_div "($current_close - $lowest_low) * 100" "($highest_high - $lowest_low)")
    fi
    printf "%.0f" "${stoch:-50}"
}

calculate_adx() {
    local symbol="$1"
    echo "25"
}

calculate_ichoch() {
    local symbol="$1"
    local current_price="$2"
    
    local klines=$(curl -s "https://api.binance.com/api/v3/klines?symbol=$symbol&interval=1m&limit=10" 2>/dev/null)
    
    local last_high=$(echo "$klines" | jq -r '.[-2][2]' 2>/dev/null)
    local last_low=$(echo "$klines" | jq -r '.[-2][3]' 2>/dev/null)
    local prev_high=$(echo "$klines" | jq -r '.[-3][2]' 2>/dev/null)
    local prev_low=$(echo "$klines" | jq -r '.[-3][3]' 2>/dev/null)
    
    if [ -n "$current_price" ] && [ -n "$last_high" ] && [ -n "$prev_high" ] && [ "$current_price" != "null" ]; then
        if (( $(echo "$current_price > $last_high && $last_high > $prev_high" | bc -l 2>/dev/null) )); then
            echo "BULLISH"
        elif (( $(echo "$current_price < $last_low && $last_low < $prev_low" | bc -l 2>/dev/null) )); then
            echo "BEARISH"
        else
            echo "NEUTRAL"
        fi
    else
        echo "NEUTRAL"
    fi
}

get_24h_change() {
    local symbol="$1"
    local ticker=$(curl -s "https://api.binance.com/api/v3/ticker/24hr?symbol=$symbol" 2>/dev/null)
    echo "$ticker" | jq -r '.priceChangePercent // 0' 2>/dev/null
}

# ============================================
# ANALYZE ORDER BOOK
# ============================================

is_watched_symbol() {
    local sym="$1"
    local s
    for s in "${SYMBOL_ARRAY[@]}"; do
        [ "$s" = "$sym" ] && return 0
    done
    return 1
}

# REST snapshot when rotating to a symbol without WS data yet
hydrate_scalper_symbol() {
    local symbol="$1"
    local price
    price=$(ob_get PRICE "$symbol")
    if [ -n "$price" ] && [ "$price" != "0" ] && [ "$price" != "null" ]; then
        return 0
    fi
    local depth
    depth=$(curl -s "https://fapi.binance.com/fapi/v1/depth?symbol=${symbol}&limit=${DEPTH}" 2>/dev/null)
    [ -z "$depth" ] && return 1
    local bids asks
    bids=$(echo "$depth" | jq -c '.bids // []' 2>/dev/null)
    asks=$(echo "$depth" | jq -c '.asks // []' 2>/dev/null)
    if [ -n "$bids" ] && [ -n "$asks" ] && [ "$bids" != "[]" ]; then
        analyze_order_book "$symbol" "$bids" "$asks"
        ob_set PRICE "$symbol" "$(echo "$depth" | jq -r '.bids[0][0] // 0' 2>/dev/null)"
    fi
}

analyze_order_book() {
    local symbol="$1"
    local bids="$2"
    local asks="$3"
    
    ob_set BID "$symbol" "$(echo "$bids" | jq -r '.[0][0] // "0"' 2>/dev/null)"
    ob_set ASK "$symbol" "$(echo "$asks" | jq -r '.[0][0] // "0"' 2>/dev/null)"
    
    local bid_liquidity=0
    local ask_liquidity=0
    
    for i in $(seq 0 4); do
        local bid_vol=$(echo "$bids" | jq -r ".[$i][1]" 2>/dev/null)
        local ask_vol=$(echo "$asks" | jq -r ".[$i][1]" 2>/dev/null)
        [ -n "$bid_vol" ] && [ "$bid_vol" != "null" ] && bid_liquidity=$(echo "$bid_liquidity + $bid_vol" | bc -l 2>/dev/null)
        [ -n "$ask_vol" ] && [ "$ask_vol" != "null" ] && ask_liquidity=$(echo "$ask_liquidity + $ask_vol" | bc -l 2>/dev/null)
    done
    
    ob_set BID_LIQ "$symbol" "$bid_liquidity"
    ob_set ASK_LIQ "$symbol" "$ask_liquidity"
    
    local max_bid_vol=0
    local support="0"
    local bid_count=$(echo "$bids" | jq length 2>/dev/null)
    
    for i in $(seq 0 $((bid_count - 1))); do
        local price=$(echo "$bids" | jq -r ".[$i][0]" 2>/dev/null)
        local vol=$(echo "$bids" | jq -r ".[$i][1]" 2>/dev/null)
        if [ -n "$vol" ] && [ "$vol" != "null" ] && [ -n "$price" ] && [ "$price" != "null" ]; then
            if (( $(echo "$vol > $max_bid_vol" | bc -l 2>/dev/null) )); then
                max_bid_vol=$vol
                support=$price
            fi
        fi
    done
    ob_set SUPPORT "$symbol" "$support"
    
    local max_ask_vol=0
    local resistance="0"
    local ask_count=$(echo "$asks" | jq length 2>/dev/null)
    
    for i in $(seq 0 $((ask_count - 1))); do
        local price=$(echo "$asks" | jq -r ".[$i][0]" 2>/dev/null)
        local vol=$(echo "$asks" | jq -r ".[$i][1]" 2>/dev/null)
        if [ -n "$vol" ] && [ "$vol" != "null" ] && [ -n "$price" ] && [ "$price" != "null" ]; then
            if (( $(echo "$vol > $max_ask_vol" | bc -l 2>/dev/null) )); then
                max_ask_vol=$vol
                resistance=$price
            fi
        fi
    done
    ob_set RESISTANCE "$symbol" "$resistance"
}

# ============================================
# CALCULATE DYNAMIC TP/SL BASED ON VOLATILITY
# ============================================

calculate_dynamic_tp_sl() {
    local entry="$1"
    local change_24h="$2"
    local spread="$3"
    local direction="$4"
    
    local sl_pct="$SL_PERCENT"
    local tp_pct="$TP_PERCENT"
    
    if [ -z "$entry" ] || ! (( $(echo "$entry > 0" | bc -l 2>/dev/null) )); then
        echo "0|0"
        return 0
    fi
    
    # Check if volatile
    local abs_change=$(echo "$change_24h" | tr -d '-')
    if (( $(echo "$abs_change >= $VOLATILE_THRESHOLD" | bc -l 2>/dev/null) )); then
        sl_pct="$SL_VOLATILE_MIN"
        tp_pct="$TP_VOLATILE_MIN"
        log "📊 Volatile market detected (|Δ24h|=${abs_change}%) - Using SL:${sl_pct}% TP:${tp_pct}%"
    fi
    
    # Check spread multiplier (skip if entry is zero — avoids bc divide-by-zero)
    if [ -n "$entry" ] && (( $(echo "$entry > 0" | bc -l 2>/dev/null) )) \
        && [ -n "$spread" ] && (( $(echo "$spread > 0" | bc -l 2>/dev/null) )); then
        local min_sl_from_spread=$(echo "$spread * $MIN_SL_SPREAD_MULT" | bc -l 2>/dev/null)
        local min_sl_pct_from_spread=$(bc_safe_div "$min_sl_from_spread * 100" "$entry")
    
    if [ -n "$min_sl_pct_from_spread" ] && (( $(echo "$min_sl_pct_from_spread > $sl_pct" | bc -l 2>/dev/null) )); then
        sl_pct="$min_sl_pct_from_spread"
        log "📊 Spread-based SL adjustment: ${sl_pct}%"
    fi
    fi
    
    local sl=""
    local tp=""
    
    if [ "$direction" = "LONG" ]; then
        sl=$(echo "$entry * (1 - $sl_pct/100)" | bc -l)
        tp=$(echo "$entry * (1 + $tp_pct/100)" | bc -l)
    else
        sl=$(echo "$entry * (1 + $sl_pct/100)" | bc -l)
        tp=$(echo "$entry * (1 - $tp_pct/100)" | bc -l)
    fi
    
    if [ -n "$CURRENT_SYMBOL" ]; then
        sl=$(round_price_for_symbol "$CURRENT_SYMBOL" "$sl")
        tp=$(round_price_for_symbol "$CURRENT_SYMBOL" "$tp")
    fi
    
    echo "$sl|$tp"
}

# ============================================
# DETERMINE TRADE SIGNAL
# ============================================

determine_signal() {
    local current_price="$1"
    
    local support resistance best_bid best_ask
    support=$(ob_get SUPPORT "$CURRENT_SYMBOL")
    resistance=$(ob_get RESISTANCE "$CURRENT_SYMBOL")
    best_bid=$(ob_get BID "$CURRENT_SYMBOL")
    best_ask=$(ob_get ASK "$CURRENT_SYMBOL")
    local rsi="$RSI_VALUE"
    local stoch="$STOCH_K"
    local adx="$ADX_VALUE"
    local ichoch="$ICHOCH_SIGNAL"
    local bid_liq ask_liq
    bid_liq=$(ob_get BID_LIQ "$CURRENT_SYMBOL")
    ask_liq=$(ob_get ASK_LIQ "$CURRENT_SYMBOL")
    
    local signal="NEUTRAL"
    local confidence=0
    local reasons=""
    local entry=0
    
    if [ -n "$current_price" ] && (( $(echo "$current_price > 0" | bc -l 2>/dev/null) )) \
        && [ "$support" != "0" ] && [ "$resistance" != "0" ] && [ "$support" != "null" ] && [ "$resistance" != "null" ]; then
        local range=$(echo "$resistance - $support" | bc -l 2>/dev/null)
        
        if [ -n "$range" ] && (( $(echo "$range > 0" | bc -l 2>/dev/null) )); then
            local position=$(bc_safe_div "($current_price - $support) * 100" "$range")
            
            if [ -n "$position" ] && (( $(echo "$position < 20" | bc -l 2>/dev/null) )); then
                signal="LONG"
                confidence=40
                reasons="Price near support"
                entry=$(echo "$support * 1.001" | bc -l 2>/dev/null)
                if [ -n "$best_bid" ] && (( $(echo "$best_bid > 0" | bc -l 2>/dev/null) )) \
                    && (( $(echo "$entry > $best_bid" | bc -l 2>/dev/null) )); then
                    entry="$best_bid"
                fi
                entry=$(round_price_for_symbol "$CURRENT_SYMBOL" "$entry")
                
                if [ -n "$rsi" ] && (( $(echo "$rsi < $RSI_OVERSOLD" | bc -l 2>/dev/null) )); then
                    confidence=$((confidence + 20))
                    reasons="$reasons + RSI oversold ($rsi)"
                fi
                if [ -n "$stoch" ] && (( $(echo "$stoch < $STOCH_OVERSOLD" | bc -l 2>/dev/null) )); then
                    confidence=$((confidence + 15))
                    reasons="$reasons + Stoch oversold"
                fi
                if [ "$ichoch" = "BULLISH" ]; then
                    confidence=$((confidence + 15))
                    reasons="$reasons + iCHoCH bullish"
                fi
                if [ -n "$bid_liq" ] && (( $(echo "$bid_liq > $MIN_LIQUIDITY_USD" | bc -l 2>/dev/null) )); then
                    confidence=$((confidence + 10))
                    reasons="$reasons + Strong bid liquidity"
                fi
                
            elif [ -n "$position" ] && (( $(echo "$position > 80" | bc -l 2>/dev/null) )); then
                signal="SHORT"
                confidence=40
                reasons="Price near resistance"
                entry=$(echo "$resistance * 0.999" | bc -l 2>/dev/null)
                if [ -n "$best_ask" ] && (( $(echo "$best_ask > 0" | bc -l 2>/dev/null) )) \
                    && (( $(echo "$entry < $best_ask" | bc -l 2>/dev/null) )); then
                    entry="$best_ask"
                fi
                entry=$(round_price_for_symbol "$CURRENT_SYMBOL" "$entry")
                
                if [ -n "$rsi" ] && (( $(echo "$rsi > $RSI_OVERBOUGHT" | bc -l 2>/dev/null) )); then
                    confidence=$((confidence + 20))
                    reasons="$reasons + RSI overbought ($rsi)"
                fi
                if [ -n "$stoch" ] && (( $(echo "$stoch > $STOCH_OVERBOUGHT" | bc -l 2>/dev/null) )); then
                    confidence=$((confidence + 15))
                    reasons="$reasons + Stoch overbought"
                fi
                if [ "$ichoch" = "BEARISH" ]; then
                    confidence=$((confidence + 15))
                    reasons="$reasons + iCHoCH bearish"
                fi
                if [ -n "$ask_liq" ] && (( $(echo "$ask_liq > $MIN_LIQUIDITY_USD" | bc -l 2>/dev/null) )); then
                    confidence=$((confidence + 10))
                    reasons="$reasons + Strong ask liquidity"
                fi
            fi
        fi
    fi
    
    if [ -n "$adx" ] && (( $(echo "$adx > $ADX_TREND_THRESHOLD" | bc -l 2>/dev/null) )); then
        confidence=$((confidence + 10))
        reasons="$reasons + ADX strong trend ($adx)"
    fi
    
    echo "$signal|$confidence|$entry|$reasons"
}

# ============================================
# UPDATE INDICATORS
# ============================================

update_indicators() {
    if [ -n "$CURRENT_SYMBOL" ]; then
        RSI_VALUE=$(calculate_rsi "$CURRENT_SYMBOL")
        STOCH_K=$(calculate_stochastic "$CURRENT_SYMBOL")
        ADX_VALUE=$(calculate_adx "$CURRENT_SYMBOL")
        ICHOCH_SIGNAL=$(calculate_ichoch "$CURRENT_SYMBOL" "$(ob_get PRICE "$CURRENT_SYMBOL")")
        CHANGE_24H=$(get_24h_change "$CURRENT_SYMBOL")
    fi
}

# ============================================
# ROTATE TO NEXT SYMBOL
# ============================================

rotate_symbol() {
    # Single-symbol mode: no round-robin
    [ "$SINGLE_SYMBOL_MODE" = true ] && return 0
    CURRENT_INDEX=$(( (CURRENT_INDEX + 1) % NUM_SYMBOLS ))
    CURRENT_SYMBOL="${SYMBOL_ARRAY[$CURRENT_INDEX]}"
    hydrate_scalper_symbol "$CURRENT_SYMBOL"
}

# ============================================
# VISUAL DISPLAY
# ============================================

draw_visualization() {
    local display_index=$((CURRENT_INDEX + 1))
    
    screen_refresh
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  ADVANCED SCALPER BOT v3.0 - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE") | Orders: $ORDER_EXECUTION_MODE${NC}"
    echo -e "${YELLOW}  Symbol: $CURRENT_SYMBOL (${display_index}/${NUM_SYMBOLS}) | 24h Change: ${CHANGE_24H}%${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local current_price
    current_price=$(ob_get PRICE "$CURRENT_SYMBOL")
    local signal_data
    signal_data=$(determine_signal "$current_price")
    local signal=$(echo "$signal_data" | cut -d'|' -f1)
    local confidence=$(echo "$signal_data" | cut -d'|' -f2)
    local entry=$(echo "$signal_data" | cut -d'|' -f3)
    local reasons=$(echo "$signal_data" | cut -d'|' -f4)
    
    # Calculate spread
    local spread=0
    local best_bid best_ask support resistance bid_liq ask_liq
    best_bid=$(ob_get BID "$CURRENT_SYMBOL")
    best_ask=$(ob_get ASK "$CURRENT_SYMBOL")
    support=$(ob_get SUPPORT "$CURRENT_SYMBOL")
    resistance=$(ob_get RESISTANCE "$CURRENT_SYMBOL")
    bid_liq=$(ob_get BID_LIQ "$CURRENT_SYMBOL")
    ask_liq=$(ob_get ASK_LIQ "$CURRENT_SYMBOL")

    if [ "$best_bid" != "0" ] && [ "$best_ask" != "0" ] && [ "$best_bid" != "null" ] && [ "$best_ask" != "null" ]; then
        spread=$(echo "$best_ask - $best_bid" | bc -l 2>/dev/null)
    fi

    if declare -f try_close_on_opposite_ob >/dev/null 2>&1 \
        && try_close_on_opposite_ob "$CURRENT_SYMBOL" "$current_price" "$OB_ZONE_UPPER_PCT" "$OB_ZONE_LOWER_PCT" log; then
        echo -e "${MAGENTA}  🔒 Position closed (or closing) — opposite OB touch${NC}"
    fi
    
    # Calculate dynamic TP/SL if signal is valid
    local sl="0"
    local tp="0"
    if [ "$signal" != "NEUTRAL" ] && [ "$entry" != "0" ]; then
        local tp_sl_data=$(calculate_dynamic_tp_sl "$entry" "$CHANGE_24H" "$spread" "$signal")
        sl=$(echo "$tp_sl_data" | cut -d'|' -f1)
        tp=$(echo "$tp_sl_data" | cut -d'|' -f2)
    fi
    
    if [ "$signal" = "LONG" ] && [ "$confidence" -ge "$MIN_CONFIDENCE" ]; then
        echo -e "${GREEN}${BOLD}┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${GREEN}${BOLD}│  🟢 $CURRENT_SYMBOL - CONFIRMED LONG (${confidence}%) - ENTRY: $entry${NC}"
        echo -e "${GREEN}${BOLD}└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘${NC}"
        log_trade "SIGNAL $CURRENT_SYMBOL LONG conf=${confidence}% entry=$entry tp=$tp sl=$sl | $reasons"
        
        if [ "$DRY_RUN" = true ]; then
            log_trade "DRY-RUN_SIGNAL $CURRENT_SYMBOL LONG entry=$entry (no order sent)"
        else
            send_order "$CURRENT_SYMBOL" "LONG" "$entry" "$sl" "$tp"
        fi
        
    elif [ "$signal" = "SHORT" ] && [ "$confidence" -ge "$MIN_CONFIDENCE" ]; then
        echo -e "${RED}${BOLD}┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${RED}${BOLD}│  🔴 $CURRENT_SYMBOL - CONFIRMED SHORT (${confidence}%) - ENTRY: $entry${NC}"
        echo -e "${RED}${BOLD}└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘${NC}"
        log_trade "SIGNAL $CURRENT_SYMBOL SHORT conf=${confidence}% entry=$entry tp=$tp sl=$sl | $reasons"
        
        if [ "$DRY_RUN" = true ]; then
            log_trade "DRY-RUN_SIGNAL $CURRENT_SYMBOL SHORT entry=$entry (no order sent)"
        else
            send_order "$CURRENT_SYMBOL" "SHORT" "$entry" "$sl" "$tp"
        fi
        
    elif [ "$signal" != "NEUTRAL" ]; then
        log_trade "WATCH $CURRENT_SYMBOL $signal conf=${confidence}% need=${MIN_CONFIDENCE}% entry=$entry | $reasons"
        echo -e "${YELLOW}┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│  🟡 $CURRENT_SYMBOL - WATCH (${confidence}%) - ${signal} potential${NC}"
        echo -e "${YELLOW}│     Reasons: $reasons${NC}"
        echo -e "${YELLOW}└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘${NC}"
    else
        echo -e "${WHITE}┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${WHITE}│  ⚪ $CURRENT_SYMBOL - NEUTRAL${NC}"
        echo -e "${WHITE}└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘${NC}"
    fi
    
    echo -e "${CYAN}  📊 Order Book:${NC}"
    printf "    ${GREEN}Best Bid: %10s${NC}  ${RED}Best Ask: %10s${NC}\n" "$best_bid" "$best_ask"
    printf "    ${GREEN}Support: %10s${NC}  ${RED}Resistance: %10s${NC}\n" "$support" "$resistance"
    printf "    ${BLUE}Bid Liq: %.0f USDT${NC}  ${BLUE}Ask Liq: %.0f USDT${NC}\n" "$bid_liq" "$ask_liq"
    
    echo -e "${MAGENTA}  📈 Indicators:${NC}"
    printf "    RSI: %3.0f  " "$RSI_VALUE"
    printf "Stoch: %3.0f  " "$STOCH_K"
    printf "ADX: %3.0f  " "$ADX_VALUE"
    printf "iCHoCH: %s\n" "$ICHOCH_SIGNAL"
    
    if [ -n "$RSI_VALUE" ] && (( $(echo "$RSI_VALUE < $RSI_OVERSOLD" | bc -l 2>/dev/null) )); then
        echo -e "    ${GREEN}✓ RSI Oversold (Bullish signal)${NC}"
    elif [ -n "$RSI_VALUE" ] && (( $(echo "$RSI_VALUE > $RSI_OVERBOUGHT" | bc -l 2>/dev/null) )); then
        echo -e "    ${RED}✓ RSI Overbought (Bearish signal)${NC}"
    fi
    
    if [ "$signal" = "LONG" ] || [ "$signal" = "SHORT" ]; then
        echo -e "${GREEN}  🎯 ENTRY DETAILS:${NC}"
        printf "    Entry: %s  TP: %s  SL: %s\n" "$entry" "$tp" "$sl"
        if [ "$(echo "${SCALPER_DCA_ENABLED}" | tr '[:upper:]' '[:lower:]')" = "true" ] \
            && declare -f calculate_ob_dca_grid >/dev/null 2>&1; then
            local dca_g dca_sl
            dca_g=$(calculate_ob_dca_grid "$signal" "$entry" "$support" "$resistance" "$CURRENT_SYMBOL")
            dca_sl=$(echo "$dca_g" | cut -d'|' -f4)
            echo -e "    ${MAGENTA}DCA OB: L1-L3,L5 limits | L4 SL @ ${dca_sl}${NC}"
            echo -e "    ${MAGENTA}Grid: $(echo "$dca_g" | tr '|' ' ')${NC}"
        fi
        echo -e "    ${CYAN}Reasons: $reasons${NC}"
        echo -e "    ${YELLOW}Volatility: |Δ24h|=${CHANGE_24H}% | Spread: $spread${NC}"
    fi
    
    echo -e "${CYAN}  ────────────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "${YELLOW}⏰ Last update: $(date '+%H:%M:%S') | Cycle: ${CYCLE_INTERVAL}s | Ctrl+C to exit${NC}"
    echo -e "${BLUE}📊 Symbols: $SYMBOLS | Order Mode: $ORDER_EXECUTION_MODE${NC}"
}

# ============================================
# PROCESS WEBSOCKET MESSAGE
# ============================================

process_message() {
    local msg="$1"
    local stream_symbol="${2:-}"
    local symbol
    symbol=$(echo "$msg" | jq -r '.s // empty' 2>/dev/null)
    if [ -z "$symbol" ] && [ -n "$stream_symbol" ]; then
        symbol="$stream_symbol"
    fi
    
    [ -z "$symbol" ] && return
    is_watched_symbol "$symbol" || return
    
    local bids asks
    bids=$(echo "$msg" | jq -c '.b' 2>/dev/null)
    asks=$(echo "$msg" | jq -c '.a' 2>/dev/null)
    
    if [ -n "$bids" ] && [ -n "$asks" ]; then
        analyze_order_book "$symbol" "$bids" "$asks"
        ob_set PRICE "$symbol" "$(echo "$msg" | jq -r '.b[0][0] // .a[0][0]' 2>/dev/null)"
    fi
}

# ============================================
# CYCLE ANALYSIS
# ============================================

run_cycle_analysis() {
    local current_time=$(date +%s)
    
    if (( current_time - LAST_CYCLE_TIME < CYCLE_INTERVAL )); then
        return
    fi
    LAST_CYCLE_TIME=$current_time

    if [ -n "${TRADES_LOG_HEARTBEAT_SECONDS:-}" ] \
        && (( current_time - LAST_TRADES_HEARTBEAT >= TRADES_LOG_HEARTBEAT_SECONDS )); then
        LAST_TRADES_HEARTBEAT=$current_time
        log_trade "HEARTBEAT bot=scalper_websocket symbol=$CURRENT_SYMBOL file=${TRADES_LOG_FILE}"
    fi
    
    hydrate_scalper_symbol "$CURRENT_SYMBOL"
    if declare -f scalper_dca_clear_if_done >/dev/null 2>&1; then
        scalper_dca_clear_if_done "$CURRENT_SYMBOL"
    fi
    update_indicators
    draw_visualization
    rotate_symbol
}

# ============================================
# BUILD WEBSOCKET URL
# ============================================

build_ws_url() {
    local streams=""
    local first=true
    
    for symbol in "${SYMBOL_ARRAY[@]}"; do
        local lower=$(echo "$symbol" | tr '[:upper:]' '[:lower:]')
        if [ "$first" = true ]; then
            streams="${lower}@depth${DEPTH}@${SPEED}"
            first=false
        else
            streams="${streams}/${lower}@depth${DEPTH}@${SPEED}"
        fi
    done
    
    echo "${WS_BASE_URL}/stream?streams=${streams}"
}

# ============================================
# WEBSOCKET CONNECTION
# ============================================

connect_websocket() {
    local ws_url=$(build_ws_url)
    
    log "🔌 Connecting to Binance WebSocket..."
    log "   URL: $ws_url"
    log "   Order Mode: $ORDER_EXECUTION_MODE"
    
    if ! command -v websocat &> /dev/null; then
        log_error "websocat not installed. Run: brew install websocat"
        exit 1
    fi
    
    # Initialize first symbol
    CURRENT_SYMBOL="${SYMBOL_ARRAY[0]}"
    CURRENT_INDEX=0
    hydrate_scalper_symbol "$CURRENT_SYMBOL"
    
    while true; do
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local stream stream_sym data
                stream=$(echo "$line" | jq -r '.stream // empty' 2>/dev/null)
                stream_sym=$(ob_symbol_from_stream "$stream")
                data=$(echo "$line" | jq -c '.data // empty' 2>/dev/null)
                if [ -n "$data" ] && [ "$data" != "null" ]; then
                    process_message "$data" "$stream_sym"
                fi
                run_cycle_analysis
            fi
        done < <(websocat --text "$ws_url" 2>/dev/null)
        
        log_error "Connection lost. Reconnecting in 5 seconds..."
        sleep 5
    done
}

# ============================================
# VALIDATE CONFIGURATION
# ============================================

validate_config() {
    local valid=true
    
    case "$ORDER_EXECUTION_MODE" in
        "finandy")
            if [ -z "$FINANDY_SECRET" ]; then
                log_error "FINANDY_SECRET not configured for finandy mode"
                valid=false
            fi
            ;;
        "rest"|"websocket")
            if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
                log_error "BINANCE_API_KEY and BINANCE_SECRET_KEY required for $ORDER_EXECUTION_MODE mode"
                valid=false
            fi
            ;;
        *)
            log_error "Invalid ORDER_EXECUTION_MODE: $ORDER_EXECUTION_MODE"
            valid=false
            ;;
    esac
    
    if [ "$valid" = false ]; then
        exit 1
    fi
}

# ============================================
# MAIN
# ============================================

main() {
    echo -e "${BLUE}${BOLD}"
    echo "╔════════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                    ADVANCED SCALPER BOT v3.0 - BINANCE DIRECT                      ║"
    echo "╚════════════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    validate_config

    if declare -f init_bot_logs >/dev/null 2>&1; then
        init_bot_logs "scalper_websocket v3.0"
    fi
    
    if ! declare -f round_price_for_symbol >/dev/null 2>&1; then
        log_error "round_price_for_symbol missing — check $BINANCE_PRECISION_LIB"
        exit 1
    fi
    
    if init_all_symbol_precision "${SYMBOL_ARRAY[@]}"; then
        log "✅ Binance precision loaded for ${#SYMBOL_ARRAY[@]} symbols (lib/binance_precision.sh)"
    else
        log_error "Could not load exchangeInfo precision (orders may fail)"
        exit 1
    fi
    
    if [[ "$ORDER_EXECUTION_MODE" == "rest" || "$ORDER_EXECUTION_MODE" == "websocket" ]]; then
        if declare -f detect_binance_position_mode >/dev/null 2>&1 && detect_binance_position_mode; then
            if [ "$BINANCE_HEDGE_MODE" = true ]; then
                log "✅ Binance position mode: Hedge (dual) — orders use positionSide"
            else
                log "✅ Binance position mode: One-way — orders without positionSide"
            fi
        else
            log_error "Could not detect position mode (set BINANCE_POSITION_MODE=hedge or oneway in .env)"
        fi
    fi
    
    log "🚀 Starting Advanced Scalper Bot v3.0"
    log "📁 Log: $LOG_FILE | Errors: $ERROR_LOG_FILE | Trades: $TRADES_LOG_FILE"
    log_trade "READY bot=scalper_websocket trades_log=${TRADES_LOG_FILE}"
    log "📋 Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE")"
    log "📊 Order Execution: $ORDER_EXECUTION_MODE"
    if [ "$SINGLE_SYMBOL_MODE" = true ]; then
        log "📈 Symbol: ${SYMBOL_ARRAY[0]} (single-symbol mode)"
    else
        log "📈 Symbols: ${SYMBOLS}"
    fi
    log "🔧 Confirmers: RSI, Stoch, ADX, iCHoCH, Liquidity"
    if [ "$(echo "${SCALPER_DCA_ENABLED}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
        log "📐 DCA: OB grid ${SCALPER_DCA_LEVELS} levels | L${SCALPER_DCA_SL_LEVEL}=SL | min dist ${SCALPER_DCA_MIN_DISTANCE_PCT}% | ${SCALPER_DCA_LIMIT_ORDERS} limits"
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq not installed. Run: brew install jq"
        exit 1
    fi
    
    if ! command -v websocat &> /dev/null; then
        log_error "websocat not installed. Run: brew install websocat"
        exit 1
    fi
    
    send_telegram "🤖 Scalper Bot v3.0 Started - Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE") | Orders: $ORDER_EXECUTION_MODE"
    
    screen_enable_alt
    connect_websocket
}

trap 'screen_disable_alt; echo -e "\n${YELLOW}👋 Shutting down...${NC}"; send_telegram "🛑 Scalper Bot Stopped"; exit 0' INT
trap 'screen_disable_alt' EXIT

main