#!/bin/bash

# ============================================
# Binance WebSocket - Order Book L2 Visual
# Muestra Bids y Asks en formato de libro
# ============================================

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# Configuración
SYMBOL="${1:-BTCUSDT}"
DEPTH="depth10"
SPEED="500ms"

# Convertir a minúsculas (MacOS compatible)
LOWERCASE=$(echo "$SYMBOL" | tr '[:upper:]' '[:lower:]')
WS_URL="wss://fstream.binance.com/public/ws/${LOWERCASE}@${DEPTH}@${SPEED}"

# Variables de estado
best_bid="N/A"
best_ask="N/A"
bid_qty="0"
ask_qty="0"
spread="0"
spread_pct="0"
mid_price="0"

# Arrays para bids y asks
declare -a bid_prices
declare -a bid_quantities
declare -a ask_prices
declare -a ask_quantities

# ============================================
# FUNCIONES VISUALES
# ============================================

clear_screen() {
    printf "\033[2J\033[H"
}

draw_title() {
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║                         BINANCE ORDER BOOK L2 - ${SYMBOL}                                    ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

draw_depth_chart() {
    local max_volume=0
    
    # Encontrar máximo volumen para escala
    for qty in "${bid_quantities[@]}"; do
        if (( $(echo "$qty > $max_volume" | bc -l 2>/dev/null) )); then
            max_volume=$qty
        fi
    done
    for qty in "${ask_quantities[@]}"; do
        if (( $(echo "$qty > $max_volume" | bc -l 2>/dev/null) )); then
            max_volume=$qty
        fi
    done
    
    if (( $(echo "$max_volume == 0" | bc -l 2>/dev/null) )); then
        max_volume=1
    fi
    
    echo -e "${YELLOW}${BOLD}📊 DEPTH VISUALIZATION (Volume Scale: █ = $(printf "%.1f" $(echo "$max_volume / 20" | bc -l)))${NC}"
    echo ""
    
    # Mostrar ASKS (parte superior - resistencia)
    echo -e "${RED}${BOLD}┌─────────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${RED}${BOLD}│  SELL ORDERS (Resistance)                                                    │${NC}"
    echo -e "${RED}${BOLD}├─────────┬─────────────┬───────────────────────────────────────────────────────┤${NC}"
    
    local len=${#ask_prices[@]}
    for ((i=0; i<len; i++)); do
        local price="${ask_prices[$i]}"
        local qty="${ask_quantities[$i]}"
        local bar_length=$(echo "$qty / $max_volume * 20" | bc -l 2>/dev/null | xargs printf "%.0f" 2>/dev/null || echo "0")
        local bar=$(printf '%0.s█' $(seq 1 $bar_length 2>/dev/null))
        
        printf "│ ${RED}%8s${NC} │ ${YELLOW}%9s${NC} │ ${RED}%-50s${NC} │\n" "$price" "$qty" "$bar"
    done
    
    # Mostrar SPREAD
    echo -e "${RED}${BOLD}├─────────┼─────────────┼───────────────────────────────────────────────────────┤${NC}"
    echo -e "${RED}${BOLD}│${NC}  SPREAD  │             │  ${WHITE}$spread (${spread_pct}%)${NC}                                                  ${RED}${BOLD}│${NC}"
    echo -e "${RED}${BOLD}├─────────┼─────────────┼───────────────────────────────────────────────────────┤${NC}"
    
    # Mostrar BIDS (parte inferior - soporte)
    echo -e "${GREEN}${BOLD}│  BUY ORDERS (Support)                                                     │${NC}"
    echo -e "${GREEN}${BOLD}├─────────┬─────────────┬───────────────────────────────────────────────────────┤${NC}"
    
    len=${#bid_prices[@]}
    for ((i=0; i<len; i++)); do
        local price="${bid_prices[$i]}"
        local qty="${bid_quantities[$i]}"
        local bar_length=$(echo "$qty / $max_volume * 20" | bc -l 2>/dev/null | xargs printf "%.0f" 2>/dev/null || echo "0")
        local bar=$(printf '%0.s█' $(seq 1 $bar_length 2>/dev/null))
        
        printf "│ ${GREEN}%8s${NC} │ ${YELLOW}%9s${NC} │ ${GREEN}%-50s${NC} │\n" "$price" "$qty" "$bar"
    done
    
    echo -e "${GREEN}${BOLD}└─────────┴─────────────┴───────────────────────────────────────────────────────┘${NC}"
    echo ""
}

draw_summary() {
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║  SUMMARY                                                                                ║${NC}"
    echo -e "${CYAN}${BOLD}╠════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    printf "║  ${GREEN}Best Bid${NC}: %10s (Vol: %8s)                                          ║\n" "$best_bid" "$bid_qty"
    printf "║  ${RED}Best Ask${NC}: %10s (Vol: %8s)                                          ║\n" "$best_ask" "$ask_qty"
    printf "║  ${YELLOW}Mid Price${NC}: %10s                                                          ║\n" "$mid_price"
    printf "║  ${WHITE}Spread${NC}:    %10s (${spread_pct}%%)                                                    ║\n" "$spread"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
}

draw_footer() {
    echo ""
    echo -e "${BLUE}⏰ Last Update: $(date '+%H:%M:%S') | Press Ctrl+C to exit${NC}"
    echo -e "${YELLOW}📊 Binance WebSocket | Depth: ${DEPTH} | Speed: ${SPEED}${NC}"
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
    best_bid=$(echo "$msg" | jq -r '.b[0][0] // "N/A"' 2>/dev/null)
    best_ask=$(echo "$msg" | jq -r '.a[0][0] // "N/A"' 2>/dev/null)
    bid_qty=$(echo "$msg" | jq -r '.b[0][1] // "0"' 2>/dev/null)
    ask_qty=$(echo "$msg" | jq -r '.a[0][1] // "0"' 2>/dev/null)
    
    # Calcular spread
    if [ "$best_bid" != "N/A" ] && [ "$best_ask" != "N/A" ]; then
        spread=$(echo "$best_ask - $best_bid" | bc -l 2>/dev/null)
        spread_pct=$(echo "scale=4; ($spread / $best_bid) * 100" | bc -l 2>/dev/null)
        mid_price=$(echo "scale=2; ($best_bid + $best_ask) / 2" | bc -l 2>/dev/null)
    fi
    
    # Extraer bids (hasta 10 niveles)
    local bid_count=$(echo "$msg" | jq '.b | length' 2>/dev/null)
    for ((i=0; i<bid_count && i<10; i++)); do
        local price=$(echo "$msg" | jq -r ".b[$i][0]" 2>/dev/null)
        local qty=$(echo "$msg" | jq -r ".b[$i][1]" 2>/dev/null)
        if [ -n "$price" ] && [ "$price" != "null" ]; then
            bid_prices+=("$price")
            bid_quantities+=("$qty")
        fi
    done
    
    # Extraer asks (hasta 10 niveles)
    local ask_count=$(echo "$msg" | jq '.a | length' 2>/dev/null)
    for ((i=0; i<ask_count && i<10; i++)); do
        local price=$(echo "$msg" | jq -r ".a[$i][0]" 2>/dev/null)
        local qty=$(echo "$msg" | jq -r ".a[$i][1]" 2>/dev/null)
        if [ -n "$price" ] && [ "$price" != "null" ]; then
            ask_prices+=("$price")
            ask_quantities+=("$qty")
        fi
    done
    
    # Mostrar interfaz
    clear_screen
    draw_title
    draw_depth_chart
    draw_summary
    draw_footer
}

# ============================================
# CONEXIÓN WEBSOCKET
# ============================================

connect_websocket() {
    echo -e "${BLUE}🔌 Connecting to Binance WebSocket...${NC}"
    echo -e "${BLUE}   URL: $WS_URL${NC}"
    echo ""
    echo -e "${YELLOW}   Waiting for data...${NC}"
    echo ""
    
    if command -v websocat &> /dev/null; then
        websocat --text "$WS_URL" 2>/dev/null | while read -r line; do
            if [ -n "$line" ]; then
                process_message "$line"
            fi
        done
    elif command -v wscat &> /dev/null; then
        wscat --connect "$WS_URL" -x "echo" 2>/dev/null | while read -r line; do
            if [ -n "$line" ]; then
                process_message "$line"
            fi
        done
    else
        echo -e "${RED}❌ Error: Need websocat or wscat${NC}"
        echo -e "${YELLOW}Install: brew install websocat${NC}"
        exit 1
    fi
}

# ============================================
# MAIN
# ============================================

main() {
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}❌ jq not installed. Run: brew install jq${NC}"
        exit 1
    fi
    
    connect_websocket
}

trap 'echo -e "\n${YELLOW}👋 Disconnecting...${NC}"; exit 0' INT

main "$@"