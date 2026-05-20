#!/bin/bash

# ============================================
# Binance Scalper Bot v1.0
# - WebSocket direct connection
# - 5-second analysis cycles
# - Order Book L2 analysis
# - Automatic reconnect
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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

# Binance WebSocket
WS_BASE_URL="wss://fstream.binance.com/public/ws"

# Symbols to track (from .env or default)
SYMBOLS="${SCALPER_SYMBOLS:-ZECUSDT,BTCUSDT,ETHUSDT}"
IFS=',' read -ra SYMBOL_ARRAY <<< "$SYMBOLS"

# Depth level (5, 10, or 20)
DEPTH="${SCALPER_OB_DEPTH:-10}"
# Update speed (100ms, 500ms, 1000ms)
SPEED="${SCALPER_WS_SPEED:-500ms}"

# Trading parameters
TP_PERCENT="${SCALPER_TP_PERCENT:-0.5}"
SL_PERCENT="${SCALPER_SL_PERCENT:-0.3}"
MIN_CONFIDENCE="${SCALPER_MIN_CONFIDENCE:-50}"
MAX_POSITION_SIZE="${SCALPER_MAX_POSITION:-100}"

# Cycle timing (seconds)
CYCLE_INTERVAL="${SCALPER_CYCLE_INTERVAL:-5}"

# Finandy webhook (for order execution)
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
NC='\033[0m'

# ============================================
# STATE VARIABLES
# ============================================

declare -A LAST_PRICE
declare -A BEST_BID
declare -A BEST_ASK
declare -A BID_VOLUME
declare -A ASK_VOLUME
declare -A SUPPORT_LEVEL
declare -A RESISTANCE_LEVEL

LAST_CYCLE_TIME=0

# ============================================
# FUNCTIONS
# ============================================

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/scalper.log"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" | tee -a "$LOG_DIR/errors.log"
}

send_telegram() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && return 1
    local msg=$(echo "$1" | sed 's/\\/\\\\/g' | sed 's/\-/\\-/g' | sed 's/\./\\\\./g')
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": \"${msg}\"}" > /dev/null
}

send_order() {
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
    
    log "📝 ORDER: $symbol $direction | Entry:$entry SL:$sl TP:$tp"
    send_telegram "⚡ SCALP: $symbol $direction Entry:$entry TP:$tp"
    
    local response=$(curl -s -X POST "$FINANDY_WEBHOOK" -H "Content-Type: application/json" -d "$payload")
    
    if echo "$response" | jq -e '.code == 200 or .success == true' >/dev/null 2>&1; then
        log "✅ Order executed: $symbol"
    else
        log_error "Order failed: $response"
    fi
}

# ============================================
# ANALYZE ORDER BOOK DATA
# ============================================

analyze_order_book() {
    local symbol="$1"
    local bids="$2"
    local asks="$3"
    
    # Update best bid/ask
    BEST_BID[$symbol]=$(echo "$bids" | jq -r '.[0][0] // "0"' 2>/dev/null)
    BEST_ASK[$symbol]=$(echo "$asks" | jq -r '.[0][0] // "0"' 2>/dev/null)
    BID_VOLUME[$symbol]=$(echo "$bids" | jq -r '.[0][1] // "0"' 2>/dev/null)
    ASK_VOLUME[$symbol]=$(echo "$asks" | jq -r '.[0][1] // "0"' 2>/dev/null)
    
    # Find support (strongest bid wall)
    local max_bid_vol=0
    local support="0"
    local bid_count=$(echo "$bids" | jq length 2>/dev/null)
    
    for i in $(seq 0 $((bid_count - 1))); do
        local price=$(echo "$bids" | jq -r ".[$i][0]" 2>/dev/null)
        local vol=$(echo "$bids" | jq -r ".[$i][1]" 2>/dev/null)
        if (( $(echo "$vol > $max_bid_vol" | bc -l 2>/dev/null) )); then
            max_bid_vol=$vol
            support=$price
        fi
    done
    SUPPORT_LEVEL[$symbol]=$support
    
    # Find resistance (strongest ask wall)
    local max_ask_vol=0
    local resistance="0"
    local ask_count=$(echo "$asks" | jq length 2>/dev/null)
    
    for i in $(seq 0 $((ask_count - 1))); do
        local price=$(echo "$asks" | jq -r ".[$i][0]" 2>/dev/null)
        local vol=$(echo "$asks" | jq -r ".[$i][1]" 2>/dev/null)
        if (( $(echo "$vol > $max_ask_vol" | bc -l 2>/dev/null) )); then
            max_ask_vol=$vol
            resistance=$price
        fi
    done
    RESISTANCE_LEVEL[$symbol]=$resistance
}

# ============================================
# DETERMINE TRADE SIGNAL
# ============================================

determine_signal() {
    local symbol="$1"
    local current_price="$2"
    
    local best_bid="${BEST_BID[$symbol]:-0}"
    local best_ask="${BEST_ASK[$symbol]:-0}"
    local support="${SUPPORT_LEVEL[$symbol]:-0}"
    local resistance="${RESISTANCE_LEVEL[$symbol]:-0}"
    
    # Default: no signal
    local signal="NEUTRAL"
    local confidence=0
    local entry=0
    local sl=0
    local tp=0
    
    # Calculate position between support and resistance
    if [ -n "$support" ] && [ -n "$resistance" ] && [ "$support" != "0" ] && [ "$resistance" != "0" ]; then
        local range=$(echo "$resistance - $support" | bc -l 2>/dev/null)
        if (( $(echo "$range > 0" | bc -l 2>/dev/null) )); then
            local position=$(echo "($current_price - $support) / $range * 100" | bc -l 2>/dev/null)
            
            # Price near support -> LONG
            if (( $(echo "$position < 20" | bc -l 2>/dev/null) )); then
                signal="LONG"
                confidence=70
                entry=$(printf "%.8f" $(echo "$support * 1.001" | bc -l))
                sl=$(printf "%.8f" $(echo "$entry * (1 - $SL_PERCENT/100)" | bc -l))
                tp=$(printf "%.8f" $(echo "$entry * (1 + $TP_PERCENT/100)" | bc -l))
            # Price near resistance -> SHORT
            elif (( $(echo "$position > 80" | bc -l 2>/dev/null) )); then
                signal="SHORT"
                confidence=70
                entry=$(printf "%.8f" $(echo "$resistance * 0.999" | bc -l))
                sl=$(printf "%.8f" $(echo "$entry * (1 + $SL_PERCENT/100)" | bc -l))
                tp=$(printf "%.8f" $(echo "$entry * (1 - $TP_PERCENT/100)" | bc -l))
            fi
        fi
    fi
    
    echo "$signal|$confidence|$entry|$sl|$tp"
}

# ============================================
# PROCESS WEBSOCKET MESSAGE
# ============================================

process_message() {
    local msg="$1"
    local symbol=$(echo "$msg" | jq -r '.s // empty' 2>/dev/null)
    
    if [ -z "$symbol" ]; then
        return
    fi
    
    # Extract bids and asks
    local bids=$(echo "$msg" | jq -c '.b' 2>/dev/null)
    local asks=$(echo "$msg" | jq -c '.a' 2>/dev/null)
    
    if [ -n "$bids" ] && [ -n "$asks" ]; then
        analyze_order_book "$symbol" "$bids" "$asks"
        LAST_PRICE[$symbol]=$(echo "$msg" | jq -r '.b[0][0] // .a[0][0]' 2>/dev/null)
    fi
}

# ============================================
# CYCLE ANALYSIS (every N seconds)
# ============================================

run_cycle_analysis() {
    local current_time=$(date +%s)
    
    # Check if enough time has passed
    if (( current_time - LAST_CYCLE_TIME < CYCLE_INTERVAL )); then
        return
    fi
    LAST_CYCLE_TIME=$current_time
    
    log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${BLUE}📊 Analysis Cycle - $(date '+%H:%M:%S')${NC}"
    
    for symbol in "${SYMBOL_ARRAY[@]}"; do
        local current_price="${LAST_PRICE[$symbol]:-0}"
        local best_bid="${BEST_BID[$symbol]:-0}"
        local best_ask="${BEST_ASK[$symbol]:-0}"
        
        if [ "$current_price" = "0" ] || [ "$best_bid" = "0" ]; then
            continue
        fi
        
        # Get trade signal
        local signal_data=$(determine_signal "$symbol" "$current_price")
        local signal=$(echo "$signal_data" | cut -d'|' -f1)
        local confidence=$(echo "$signal_data" | cut -d'|' -f2)
        local entry=$(echo "$signal_data" | cut -d'|' -f3)
        local sl=$(echo "$signal_data" | cut -d'|' -f4)
        local tp=$(echo "$signal_data" | cut -d'|' -f5)
        
        log "${CYAN}📈 $symbol | Price: $current_price | Bid: $best_bid | Ask: $best_ask${NC}"
        log "   Support: ${SUPPORT_LEVEL[$symbol]} | Resistance: ${RESISTANCE_LEVEL[$symbol]}"
        log "   Signal: $signal (confidence: ${confidence}%)"
        
        # Execute trade if confidence is high enough
        if [ "$signal" != "NEUTRAL" ] && [ "$confidence" -ge "$MIN_CONFIDENCE" ]; then
            log "${GREEN}🎯 EXECUTING: $symbol $signal @ $entry${NC}"
            send_order "$symbol" "$signal" "$entry" "$sl" "$tp"
        fi
    done
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
# WEBSOCKET CONNECTION WITH AUTO-RECONNECT
# ============================================

connect_websocket() {
    local ws_url=$(build_ws_url)
    
    log "${BLUE}🔌 Connecting to Binance WebSocket...${NC}"
    log "   URL: $ws_url"
    
    if ! command -v websocat &> /dev/null; then
        log_error "websocat not installed. Run: brew install websocat"
        exit 1
    fi
    
    while true; do
        log "🔄 Connecting..."
        websocat --text "$ws_url" 2>/dev/null | while read -r line; do
            if [ -n "$line" ]; then
                # Extract stream data
                local data=$(echo "$line" | jq -r '.data // empty' 2>/dev/null)
                if [ -n "$data" ]; then
                    process_message "$data"
                fi
                run_cycle_analysis
            fi
        done
        
        log_error "Connection lost. Reconnecting in 5 seconds..."
        sleep 5
    done
}

# ============================================
# MAIN
# ============================================

main() {
    echo -e "${BLUE}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         BINANCE SCALPER BOT - WEBSOCKET DIRECT              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    log "🚀 Starting Scalper Bot v1.0"
    log "📋 Config: TP=${TP_PERCENT}% SL=${SL_PERCENT}% Cycle=${CYCLE_INTERVAL}s"
    log "📊 Symbols: ${SYMBOLS}"
    log "🔧 Depth: ${DEPTH} | Speed: ${SPEED}"
    
    if ! command -v jq &> /dev/null; then
        log_error "jq not installed. Run: brew install jq"
        exit 1
    fi
    
    if [ -z "$FINANDY_SECRET" ]; then
        log_error "FINANDY_SECRET not configured in .env"
        exit 1
    fi
    
    send_telegram "🤖 Scalper Bot Started | TP:${TP_PERCENT}% SL:${SL_PERCENT}% Cycle:${CYCLE_INTERVAL}s"
    
    connect_websocket
}

# Graceful shutdown
trap 'echo -e "\n${YELLOW}👋 Shutting down...${NC}"; send_telegram "🛑 Scalper Bot Stopped"; exit 0' INT

main "$@"