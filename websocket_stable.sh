#!/bin/bash

# ============================================
# Binance WebSocket - Order Book L2 Stable
# Sin flicker - actualización en tiempo real
# ============================================

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# Configuración
SYMBOL="${1:-BTCUSDT}"
DEPTH="depth10"
SPEED="500ms"

LOWERCASE=$(echo "$SYMBOL" | tr '[:upper:]' '[:lower:]')
WS_URL="wss://fstream.binance.com/public/ws/${LOWERCASE}@${DEPTH}@${SPEED}"

# Estado
best_bid="---"
best_ask="---"
bid_qty="0"
ask_qty="0"
spread="0"
spread_pct="0"
mid_price="0"

# Arrays
declare -a bid_prices
declare -a bid_quantities
declare -a ask_prices
declare -a ask_quantities

# Control de refresco
first_run=true

# ============================================
# FUNCIONES
# ============================================

move_to_top() {
    printf "\033[;H"
}

clear_line() {
    printf "\033[K"
}

draw_header() {
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  BINANCE ORDER BOOK L2 - ${SYMBOL}  |  Depth: ${DEPTH}  |  Speed: ${SPEED}${NC}"
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

draw_bids() {
    echo -e "${GREEN}${BOLD}▶ BUY ORDERS (Support)${NC}"
    echo -e "${GREEN}┌──────────┬─────────────┬────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}│  PRICE   │  VOLUME     │  DEPTH                                  │${NC}"
    echo -e "${GREEN}├──────────┼─────────────┼────────────────────────────────────────┤${NC}"
    
    local len=${#bid_prices[@]}
    local max_vol=0
    
    # Encontrar máximo volumen para escala
    for qty in "${bid_quantities[@]}"; do
        if (( $(echo "$qty > $max_vol" | bc -l 2>/dev/null) )); then
            max_vol=$qty
        fi
    done
    for qty in "${ask_quantities[@]}"; do
        if (( $(echo "$qty > $max_vol" | bc -l 2>/dev/null) )); then
            max_vol=$qty
        fi
    done
    [ "$max_vol" = "0" ] && max_vol=1
    
    for ((i=0; i<len && i<8; i++)); do
        local price="${bid_prices[$i]}"
        local qty="${bid_quantities[$i]}"
        local bar_len=$(echo "$qty / $max_vol * 20" | bc -l 2>/dev/null | xargs printf "%.0f" 2>/dev/null || echo "0")
        local bar=$(printf '%0.s█' $(seq 1 $bar_len 2>/dev/null))
        printf "│ ${GREEN}%8s${NC} │ ${YELLOW}%9s${NC} │ ${GREEN}%-40s${NC} │\n" "$price" "$qty" "$bar"
    done
    echo -e "${GREEN}└──────────┴─────────────┴────────────────────────────────────────┘${NC}"
    echo ""
}

draw_asks() {
    echo -e "${RED}${BOLD}▼ SELL ORDERS (Resistance)${NC}"
    echo -e "${RED}┌──────────┬─────────────┬────────────────────────────────────────┐${NC}"
    echo -e "${RED}│  PRICE   │  VOLUME     │  DEPTH                                  │${NC}"
    echo -e "${RED}├──────────┼─────────────┼────────────────────────────────────────┤${NC}"
    
    local len=${#ask_prices[@]}
    local max_vol=0
    
    for qty in "${ask_quantities[@]}"; do
        if (( $(echo "$qty > $max_vol" | bc -l 2>/dev/null) )); then
            max_vol=$qty
        fi
    done
    for qty in "${bid_quantities[@]}"; do
        if (( $(echo "$qty > $max_vol" | bc -l 2>/dev/null) )); then
            max_vol=$qty
        fi
    done
    [ "$max_vol" = "0" ] && max_vol=1
    
    for ((i=0; i<len && i<8; i++)); do
        local price="${ask_prices[$i]}"
        local qty="${ask_quantities[$i]}"
        local bar_len=$(echo "$qty / $max_vol * 20" | bc -l 2>/dev/null | xargs printf "%.0f" 2>/dev/null || echo "0")
        local bar=$(printf '%0.s█' $(seq 1 $bar_len 2>/dev/null))
        printf "│ ${RED}%8s${NC} │ ${YELLOW}%9s${NC} │ ${RED}%-40s${NC} │\n" "$price" "$qty" "$bar"
    done
    echo -e "${RED}└──────────┴─────────────┴────────────────────────────────────────┘${NC}"
    echo ""
}

draw_summary() {
    echo -e "${CYAN}┌────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  SUMMARY                                                       │${NC}"
    echo -e "${CYAN}├────────────────────────────────────────────────────────────────┤${NC}"
    printf "${CYAN}│${NC}  ${GREEN}Best Bid${NC}: %10s  (Vol: %8s)                           ${CYAN}│${NC}\n" "$best_bid" "$bid_qty"
    printf "${CYAN}│${NC}  ${RED}Best Ask${NC}: %10s  (Vol: %8s)                           ${CYAN}│${NC}\n" "$best_ask" "$ask_qty"
    printf "${CYAN}│${NC}  ${YELLOW}Mid Price${NC}: %10s                                           ${CYAN}│${NC}\n" "$mid_price"
    printf "${CYAN}│${NC}  ${WHITE}Spread${NC}:    %10s  (${spread_pct}%%)                                   ${CYAN}│${NC}\n" "$spread"
    echo -e "${CYAN}└────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}⏰ Update: $(date '+%H:%M:%S')  |  Ctrl+C to exit${NC}"
}

draw_all() {
    if [ "$first_run" = true ]; then
        clear
        draw_header
        draw_bids
        draw_asks
        draw_summary
        first_run=false
    else
        move_to_top
        clear_line
        draw_header
        draw_bids
        draw_asks
        draw_summary
    fi
}

# ============================================
# PROCESAR MENSAJE
# ============================================

process_message() {
    local msg="$1"
    
    # Limpiar arrays
    bid_prices=()
    bid_quantities=()
    ask_prices=()
    ask_quantities=()
    
    # Extraer best bid/ask
    best_bid=$(echo "$msg" | jq -r '.b[0][0] // "---"' 2>/dev/null)
    best_ask=$(echo "$msg" | jq -r '.a[0][0] // "---"' 2>/dev/null)
    bid_qty=$(echo "$msg" | jq -r '.b[0][1] // "0"' 2>/dev/null)
    ask_qty=$(echo "$msg" | jq -r '.a[0][1] // "0"' 2>/dev/null)
    
    # Calcular spread
    if [ "$best_bid" != "---" ] && [ "$best_ask" != "---" ]; then
        spread=$(echo "$best_ask - $best_bid" | bc -l 2>/dev/null)
        spread_pct=$(echo "scale=4; ($spread / $best_bid) * 100" | bc -l 2>/dev/null)
        mid_price=$(echo "scale=2; ($best_bid + $best_ask) / 2" | bc -l 2>/dev/null)
    fi
    
    # Extraer bids
    local bid_count=$(echo "$msg" | jq '.b | length' 2>/dev/null)
    for ((i=0; i<bid_count && i<10; i++)); do
        local price=$(echo "$msg" | jq -r ".b[$i][0]" 2>/dev/null)
        local qty=$(echo "$msg" | jq -r ".b[$i][1]" 2>/dev/null)
        if [ -n "$price" ] && [ "$price" != "null" ]; then
            bid_prices+=("$price")
            bid_quantities+=("$qty")
        fi
    done
    
    # Extraer asks
    local ask_count=$(echo "$msg" | jq '.a | length' 2>/dev/null)
    for ((i=0; i<ask_count && i<10; i++)); do
        local price=$(echo "$msg" | jq -r ".a[$i][0]" 2>/dev/null)
        local qty=$(echo "$msg" | jq -r ".a[$i][1]" 2>/dev/null)
        if [ -n "$price" ] && [ "$price" != "null" ]; then
            ask_prices+=("$price")
            ask_quantities+=("$qty")
        fi
    done
    
    draw_all
}

# ============================================
# CONEXIÓN WEBSOCKET
# ============================================

connect_websocket() {
    echo -e "${BLUE}🔌 Connecting to Binance WebSocket...${NC}"
    
    if command -v websocat &> /dev/null; then
        websocat --text "$WS_URL" 2>/dev/null | while read -r line; do
            [ -n "$line" ] && process_message "$line"
        done
    elif command -v wscat &> /dev/null; then
        wscat --connect "$WS_URL" -x "echo" 2>/dev/null | while read -r line; do
            [ -n "$line" ] && process_message "$line"
        done
    else
        echo -e "${RED}❌ Install: brew install websocat${NC}"
        exit 1
    fi
}

# ============================================
# MAIN
# ============================================

main() {
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}❌ Install: brew install jq${NC}"
        exit 1
    fi
    
    connect_websocket
}

trap 'echo -e "\n${YELLOW}👋 Exit${NC}"; exit 0' INT

main "$@"