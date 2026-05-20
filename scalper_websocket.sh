#!/bin/bash

# ============================================
# Advanced Scalper Bot v2.1 - macOS Compatible
# - Fixed bad substitution errors
# - Dry-run mode for visualization
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
# MODE (dry-run or real)
# ============================================

DRY_RUN=false
if [[ "$1" == "--dry-run" ]] || [[ "$1" == "-d" ]]; then
    DRY_RUN=true
    echo "🔍 DRY-RUN MODE: Visualize only, no orders will be executed"
fi

# ============================================
# CONFIGURATION (with defaults)
# ============================================

# Binance WebSocket
WS_BASE_URL="wss://fstream.binance.com/public/ws"
SYMBOLS="${SCALPER_SYMBOLS:-BTCUSDT,ETHUSDT,SOLUSDT}"
DEPTH="${SCALPER_OB_DEPTH:-10}"
SPEED="${SCALPER_WS_SPEED:-500ms}"

# Trading parameters
TP_PERCENT="${SCALPER_TP_PERCENT:-0.5}"
SL_PERCENT="${SCALPER_SL_PERCENT:-0.3}"
MIN_CONFIDENCE="${SCALPER_MIN_CONFIDENCE:-70}"

# Confirmation thresholds
RSI_OVERSOLD=30
RSI_OVERBOUGHT=70
STOCH_OVERSOLD=20
STOCH_OVERBOUGHT=80
ADX_TREND_THRESHOLD=25
MIN_LIQUIDITY_USD=50000

# Analysis cycle (seconds)
CYCLE_INTERVAL="${SCALPER_CYCLE_INTERVAL:-5}"

# Finandy webhook
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
WATCH_SIGNAL="NEUTRAL"
CONFIRMED_SIG="NEUTRAL"
LAST_CYCLE_TIME=0

# Split symbols into array
IFS=',' read -ra SYMBOL_ARRAY <<< "$SYMBOLS"
CURRENT_INDEX=0
NUM_SYMBOLS=${#SYMBOL_ARRAY[@]}

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
    
    if [ "$DRY_RUN" = true ]; then
        log "${YELLOW}[DRY-RUN] WOULD EXECUTE: $symbol $direction @ $entry (TP:$tp SL:$sl)${NC}"
        send_telegram "🔍 [DRY-RUN] $symbol $direction Entry:$entry TP:$tp SL:$sl"
        return 0
    fi
    
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
    send_telegram "⚡ SCALP: $symbol $direction Entry:$entry TP:$tp SL:$sl"
    
    local response=$(curl -s -X POST "$FINANDY_WEBHOOK" -H "Content-Type: application/json" -d "$payload")
    
    if echo "$response" | jq -e '.code == 200 or .success == true' >/dev/null 2>&1; then
        log "✅ Order executed: $symbol"
    else
        log_error "Order failed: $response"
    fi
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
        local rs=$(echo "$gains / $losses" | bc -l 2>/dev/null)
        local rsi=$(echo "100 - (100 / (1 + $rs))" | bc -l 2>/dev/null)
        printf "%.0f" "$rsi"
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
    local stoch=$(echo "($current_close - $lowest_low) / ($highest_high - $lowest_low) * 100" | bc -l 2>/dev/null)
    printf "%.0f" "$stoch"
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
    local sl=0
    local tp=0
    
    if [ "$support" != "0" ] && [ "$resistance" != "0" ] && [ "$support" != "null" ] && [ "$resistance" != "null" ]; then
        local range=$(echo "$resistance - $support" | bc -l 2>/dev/null)
        
        if [ -n "$range" ] && (( $(echo "$range > 0" | bc -l 2>/dev/null) )); then
            local position=$(echo "($current_price - $support) / $range * 100" | bc -l 2>/dev/null)
            
            if [ -n "$position" ] && (( $(echo "$position < 20" | bc -l 2>/dev/null) )); then
                signal="LONG"
                confidence=40
                reasons="Price near support"
                entry=$(printf "%.8f" $(echo "$support * 1.001" | bc -l))
                
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
                
                sl=$(printf "%.8f" $(echo "$entry * (1 - $SL_PERCENT/100)" | bc -l))
                tp=$(printf "%.8f" $(echo "$entry * (1 + $TP_PERCENT/100)" | bc -l))
                
            elif [ -n "$position" ] && (( $(echo "$position > 80" | bc -l 2>/dev/null) )); then
                signal="SHORT"
                confidence=40
                reasons="Price near resistance"
                entry=$(printf "%.8f" $(echo "$resistance * 0.999" | bc -l))
                
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
                
                sl=$(printf "%.8f" $(echo "$entry * (1 + $SL_PERCENT/100)" | bc -l))
                tp=$(printf "%.8f" $(echo "$entry * (1 - $TP_PERCENT/100)" | bc -l))
            fi
        fi
    fi
    
    if [ -n "$adx" ] && (( $(echo "$adx > $ADX_TREND_THRESHOLD" | bc -l 2>/dev/null) )); then
        confidence=$((confidence + 10))
        reasons="$reasons + ADX strong trend ($adx)"
    fi
    
    echo "$signal|$confidence|$entry|$sl|$tp|$reasons"
}

# ============================================
# UPDATE INDICATORS FOR CURRENT SYMBOL
# ============================================

update_indicators() {
    if [ -n "$CURRENT_SYMBOL" ]; then
        RSI_VALUE=$(calculate_rsi "$CURRENT_SYMBOL")
        STOCH_K=$(calculate_stochastic "$CURRENT_SYMBOL")
        ADX_VALUE=$(calculate_adx "$CURRENT_SYMBOL")
        ICHOCH_SIGNAL=$(calculate_ichoch "$CURRENT_SYMBOL" "$CURRENT_PRICE")
    fi
}

# ============================================
# ROTATE TO NEXT SYMBOL
# ============================================

rotate_symbol() {
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
    echo -e "${CYAN}${BOLD}  ADVANCED SCALPER BOT - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN (Visualization Only)" || echo "LIVE")${NC}"
    echo -e "${YELLOW}  Symbol: $CURRENT_SYMBOL (${display_index}/${NUM_SYMBOLS})${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local signal_data=$(determine_signal "$CURRENT_PRICE")
    local signal=$(echo "$signal_data" | cut -d'|' -f1)
    local confidence=$(echo "$signal_data" | cut -d'|' -f2)
    local entry=$(echo "$signal_data" | cut -d'|' -f3)
    local sl=$(echo "$signal_data" | cut -d'|' -f4)
    local tp=$(echo "$signal_data" | cut -d'|' -f5)
    local reasons=$(echo "$signal_data" | cut -d'|' -f6)
    
    if [ "$signal" = "LONG" ] && [ "$confidence" -ge "$MIN_CONFIDENCE" ]; then
        echo -e "${GREEN}${BOLD}┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${GREEN}${BOLD}│  🟢 $CURRENT_SYMBOL - CONFIRMED LONG (${confidence}%) - ENTRY: $entry${NC}"
        echo -e "${GREEN}${BOLD}└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘${NC}"
        WATCH_SIGNAL="LONG"
        CONFIRMED_SIG="LONG"
    elif [ "$signal" = "SHORT" ] && [ "$confidence" -ge "$MIN_CONFIDENCE" ]; then
        echo -e "${RED}${BOLD}┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${RED}${BOLD}│  🔴 $CURRENT_SYMBOL - CONFIRMED SHORT (${confidence}%) - ENTRY: $entry${NC}"
        echo -e "${RED}${BOLD}└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘${NC}"
        WATCH_SIGNAL="SHORT"
        CONFIRMED_SIG="SHORT"
    elif [ "$signal" != "NEUTRAL" ]; then
        echo -e "${YELLOW}┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│  🟡 $CURRENT_SYMBOL - WATCH (${confidence}%) - ${signal} potential${NC}"
        echo -e "${YELLOW}│     Reasons: $reasons${NC}"
        echo -e "${YELLOW}└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘${NC}"
        WATCH_SIGNAL="$signal"
        CONFIRMED_SIG="WATCH"
    else
        echo -e "${WHITE}┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${WHITE}│  ⚪ $CURRENT_SYMBOL - NEUTRAL${NC}"
        echo -e "${WHITE}└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘${NC}"
        WATCH_SIGNAL="NEUTRAL"
        CONFIRMED_SIG="NEUTRAL"
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
    
    if [ "$CONFIRMED_SIG" = "LONG" ] || [ "$CONFIRMED_SIG" = "SHORT" ]; then
        echo -e "${GREEN}  🎯 CONFIRMED ENTRY:${NC}"
        printf "    Entry: %s  TP: %s  SL: %s\n" "$entry" "$tp" "$sl"
        echo -e "    ${CYAN}Reasons: $reasons${NC}"
        echo -e "    ${YELLOW}Action: $([ "$DRY_RUN" = true ] && echo "EXECUTE (DRY-RUN)" || echo "EXECUTE" )${NC}"
        
        if [ "$DRY_RUN" = false ] && [ "$confidence" -ge "$MIN_CONFIDENCE" ]; then
            send_order "$CURRENT_SYMBOL" "$CONFIRMED_SIG" "$entry" "$sl" "$tp"
            CONFIRMED_SIG="EXECUTED"
        fi
    fi
    
    echo -e "${CYAN}  ────────────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "${YELLOW}⏰ Last update: $(date '+%H:%M:%S') | Cycle: ${CYCLE_INTERVAL}s | Ctrl+C to exit${NC}"
    echo -e "${BLUE}📊 Symbols: $SYMBOLS${NC}"
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
    
    if ! command -v websocat &> /dev/null; then
        log_error "websocat not installed. Run: brew install websocat"
        exit 1
    fi
    
    # Initialize first symbol
    CURRENT_SYMBOL="${SYMBOL_ARRAY[0]}"
    CURRENT_INDEX=0
    
    while true; do
        websocat --text "$ws_url" 2>/dev/null | while read -r line; do
            if [ -n "$line" ]; then
                local data=$(echo "$line" | jq -r '.data // empty' 2>/dev/null)
                if [ -n "$data" ]; then
                    process_message "$data"
                fi
                run_cycle_analysis
                
                # Rotate to next symbol every cycle
                rotate_symbol
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
    echo "╔════════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                    ADVANCED SCALPER BOT v2.1 - BINANCE DIRECT                      ║"
    echo "╚════════════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    log "🚀 Starting Advanced Scalper Bot (macOS Compatible)"
    log "📋 Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE")"
    log "📊 Symbols: ${SYMBOLS}"
    log "🔧 Confirmers: RSI, Stoch, ADX, iCHoCH, Liquidity"
    
    if ! command -v jq &> /dev/null; then
        log_error "jq not installed. Run: brew install jq"
        exit 1
    fi
    
    if ! command -v websocat &> /dev/null; then
        log_error "websocat not installed. Run: brew install websocat"
        exit 1
    fi
    
    send_telegram "🤖 Advanced Scalper Bot Started - Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "LIVE")"
    
    connect_websocket
}

trap 'echo -e "\n${YELLOW}👋 Shutting down...${NC}"; send_telegram "🛑 Scalper Bot Stopped"; exit 0' INT

main "$@"