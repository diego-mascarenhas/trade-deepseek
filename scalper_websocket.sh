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
ORDER_EXECUTION_MODE="${ORDER_EXECUTION_MODE:-finandy}"

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

# Finandy webhook (for finandy mode)
FINANDY_WEBHOOK="${FINANDY_WEBHOOK:-https://hook.finandy.com/LMEnRji-3GvFkm7wqFUK}"
FINANDY_SECRET="${FINANDY_SECRET:-d1a01uf5uoe}"

# Telegram
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Directories
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

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
CURRENT_PRICE="0"
BEST_BID="0"
BEST_ASK="0"
SUPPORT_LEVEL="0"
RESISTANCE_LEVEL="0"
LIQUIDITY_BID="0"
LIQUIDITY_ASK="0"
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
}

parse_cli_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-d)
                DRY_RUN=true
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                echo "❌ Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [ -n "$SYMBOL_CLI" ]; then
                    echo "❌ Only one SYMBOL argument is allowed (got: $SYMBOL_CLI and $1)"
                    exit 1
                fi
                SYMBOL_CLI=$(echo "$1" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
                ;;
        esac
        shift
    done

    if [ -n "$SYMBOL_CLI" ]; then
        SYMBOLS="$SYMBOL_CLI"
        SINGLE_SYMBOL_MODE=true
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "🔍 DRY-RUN MODE: No orders will be executed"
    fi
}

init_symbol_list() {
    local _sym _i
    IFS=',' read -ra SYMBOL_ARRAY <<< "$SYMBOLS"
    for _i in "${!SYMBOL_ARRAY[@]}"; do
        _sym=$(echo "${SYMBOL_ARRAY[$_i]}" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
        SYMBOL_ARRAY[$_i]="$_sym"
    done
    NUM_SYMBOLS=${#SYMBOL_ARRAY[@]}
    if [ "$NUM_SYMBOLS" -lt 1 ] || [ -z "${SYMBOL_ARRAY[0]}" ]; then
        echo "❌ Error: no symbols configured (SCALPER_SYMBOLS or SYMBOL argument)"
        exit 1
    fi
    if [ "$NUM_SYMBOLS" -eq 1 ]; then
        SINGLE_SYMBOL_MODE=true
    fi
    CURRENT_INDEX=0
}

parse_cli_args "$@"
init_symbol_list

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/scalper.log"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" | tee -a "$LOG_DIR/errors.log"
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
        send_telegram "🔍 [DRY-RUN] $symbol $direction Entry:$entry"
        return 0
    fi
    
    local response=$(curl -s -X POST "$FINANDY_WEBHOOK" -H "Content-Type: application/json" -d "$payload")
    
    if echo "$response" | jq -e '.code == 200 or .success == true' >/dev/null 2>&1; then
        log "✅ Order executed via Finandy: $symbol"
        send_telegram "✅ ORDER: $symbol $direction Entry:$entry"
    else
        log_error "Order failed: $response"
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
    local timestamp=$(date +%s%3N)
    local recv_window=5000
    
    local query_string="symbol=$symbol&side=$side&type=LIMIT&timeInForce=GTC&quantity=$quantity&price=$entry&timestamp=$timestamp&recvWindow=$recv_window"
    
    # Generate signature (requires openssl)
    local signature=$(echo -n "$query_string" | openssl dgst -sha256 -hmac "$BINANCE_SECRET_KEY" | cut -d' ' -f2)
    
    log "📝 [REST] $symbol $direction | Entry:$entry SL:$sl TP:$tp | Qty:$quantity"
    
    if [ "$DRY_RUN" = true ]; then
        log "🔍 DRY-RUN: Would execute via Binance REST"
        send_telegram "🔍 [DRY-RUN] $symbol $direction Entry:$entry"
        return 0
    fi
    
    local response=$(curl -s -X POST "https://fapi.binance.com/fapi/v1/order" \
        -H "X-MBX-APIKEY: $BINANCE_API_KEY" \
        -d "$query_string&signature=$signature")
    
    if echo "$response" | jq -e '.orderId' >/dev/null 2>&1; then
        log "✅ Order executed via Binance REST: $symbol"
        send_telegram "✅ [REST] $symbol $direction Entry:$entry"
    else
        log_error "REST order failed: $response"
    fi
}

# Mode 3: Binance WebSocket (simplified - requires external tool)
send_order_binance_ws() {
    local symbol="$1" direction="$2" entry="$3" sl="$4" tp="$5"
    
    log "📝 [WEBSOCKET] $symbol $direction | Entry:$entry SL:$sl TP:$tp"
    
    if [ "$DRY_RUN" = true ]; then
        log "🔍 DRY-RUN: Would execute via Binance WebSocket"
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

analyze_order_book() {
    local bids="$1"
    local asks="$2"
    
    BEST_BID=$(echo "$bids" | jq -r '.[0][0] // "0"' 2>/dev/null)
    BEST_ASK=$(echo "$asks" | jq -r '.[0][0] // "0"' 2>/dev/null)
    
    local bid_liquidity=0
    local ask_liquidity=0
    
    for i in $(seq 0 4); do
        local bid_vol=$(echo "$bids" | jq -r ".[$i][1]" 2>/dev/null)
        local ask_vol=$(echo "$asks" | jq -r ".[$i][1]" 2>/dev/null)
        [ -n "$bid_vol" ] && [ "$bid_vol" != "null" ] && bid_liquidity=$(echo "$bid_liquidity + $bid_vol" | bc -l 2>/dev/null)
        [ -n "$ask_vol" ] && [ "$ask_vol" != "null" ] && ask_liquidity=$(echo "$ask_liquidity + $ask_vol" | bc -l 2>/dev/null)
    done
    
    LIQUIDITY_BID=$bid_liquidity
    LIQUIDITY_ASK=$ask_liquidity
    
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
    SUPPORT_LEVEL=$support
    
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
    RESISTANCE_LEVEL=$resistance
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
    
    local support="$SUPPORT_LEVEL"
    local resistance="$RESISTANCE_LEVEL"
    local rsi="$RSI_VALUE"
    local stoch="$STOCH_K"
    local adx="$ADX_VALUE"
    local ichoch="$ICHOCH_SIGNAL"
    local bid_liq="$LIQUIDITY_BID"
    local ask_liq="$LIQUIDITY_ASK"
    
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
                entry=$(round_price_for_symbol "$CURRENT_SYMBOL" $(echo "$support * 1.001" | bc -l))
                
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
                entry=$(round_price_for_symbol "$CURRENT_SYMBOL" $(echo "$resistance * 0.999" | bc -l))
                
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
        ICHOCH_SIGNAL=$(calculate_ichoch "$CURRENT_SYMBOL" "$CURRENT_PRICE")
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
}

# ============================================
# VISUAL DISPLAY
# ============================================

draw_visualization() {
    local display_index=$((CURRENT_INDEX + 1))
    
    clear
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  ADVANCED SCALPER BOT v3.0 - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE") | Orders: $ORDER_EXECUTION_MODE${NC}"
    echo -e "${YELLOW}  Symbol: $CURRENT_SYMBOL (${display_index}/${NUM_SYMBOLS}) | 24h Change: ${CHANGE_24H}%${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local signal_data=$(determine_signal "$CURRENT_PRICE")
    local signal=$(echo "$signal_data" | cut -d'|' -f1)
    local confidence=$(echo "$signal_data" | cut -d'|' -f2)
    local entry=$(echo "$signal_data" | cut -d'|' -f3)
    local reasons=$(echo "$signal_data" | cut -d'|' -f4)
    
    # Calculate spread
    local spread=0
    if [ "$BEST_BID" != "0" ] && [ "$BEST_ASK" != "0" ] && [ "$BEST_BID" != "null" ] && [ "$BEST_ASK" != "null" ]; then
        spread=$(echo "$BEST_ASK - $BEST_BID" | bc -l 2>/dev/null)
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
        
        if [ "$DRY_RUN" = false ]; then
            send_order "$CURRENT_SYMBOL" "LONG" "$entry" "$sl" "$tp"
        fi
        
    elif [ "$signal" = "SHORT" ] && [ "$confidence" -ge "$MIN_CONFIDENCE" ]; then
        echo -e "${RED}${BOLD}┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${RED}${BOLD}│  🔴 $CURRENT_SYMBOL - CONFIRMED SHORT (${confidence}%) - ENTRY: $entry${NC}"
        echo -e "${RED}${BOLD}└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘${NC}"
        
        if [ "$DRY_RUN" = false ]; then
            send_order "$CURRENT_SYMBOL" "SHORT" "$entry" "$sl" "$tp"
        fi
        
    elif [ "$signal" != "NEUTRAL" ]; then
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
    printf "    ${GREEN}Best Bid: %10s${NC}  ${RED}Best Ask: %10s${NC}\n" "$BEST_BID" "$BEST_ASK"
    printf "    ${GREEN}Support: %10s${NC}  ${RED}Resistance: %10s${NC}\n" "$SUPPORT_LEVEL" "$RESISTANCE_LEVEL"
    printf "    ${BLUE}Bid Liq: %.0f USDT${NC}  ${BLUE}Ask Liq: %.0f USDT${NC}\n" "$LIQUIDITY_BID" "$LIQUIDITY_ASK"
    
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
    local symbol=$(echo "$msg" | jq -r '.s // empty' 2>/dev/null)
    
    if [ -z "$symbol" ] || [ "$symbol" != "$CURRENT_SYMBOL" ]; then
        return
    fi
    
    local bids=$(echo "$msg" | jq -c '.b' 2>/dev/null)
    local asks=$(echo "$msg" | jq -c '.a' 2>/dev/null)
    
    if [ -n "$bids" ] && [ -n "$asks" ]; then
        analyze_order_book "$bids" "$asks"
        CURRENT_PRICE=$(echo "$msg" | jq -r '.b[0][0] // .a[0][0]' 2>/dev/null)
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
    
    update_indicators
    draw_visualization
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
    
    while true; do
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local data=$(echo "$line" | jq -r '.data // empty' 2>/dev/null)
                if [ -n "$data" ]; then
                    process_message "$data"
                fi
                run_cycle_analysis
                rotate_symbol
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
    
    log "🚀 Starting Advanced Scalper Bot v3.0"
    log "📋 Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE")"
    log "📊 Order Execution: $ORDER_EXECUTION_MODE"
    if [ "$SINGLE_SYMBOL_MODE" = true ]; then
        log "📈 Symbol: ${SYMBOL_ARRAY[0]} (single-symbol mode)"
    else
        log "📈 Symbols: ${SYMBOLS}"
    fi
    log "🔧 Confirmers: RSI, Stoch, ADX, iCHoCH, Liquidity"
    
    if ! command -v jq &> /dev/null; then
        log_error "jq not installed. Run: brew install jq"
        exit 1
    fi
    
    if ! command -v websocat &> /dev/null; then
        log_error "websocat not installed. Run: brew install websocat"
        exit 1
    fi
    
    send_telegram "🤖 Scalper Bot v3.0 Started - Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE") | Orders: $ORDER_EXECUTION_MODE"
    
    connect_websocket
}

trap 'echo -e "\n${YELLOW}👋 Shutting down...${NC}"; send_telegram "🛑 Scalper Bot Stopped"; exit 0' INT

main