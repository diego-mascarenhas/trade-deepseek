#!/bin/bash

# ============================================
# Binance WebSocket - Order Book L2 en tiempo real
# Compatible con MacOS (Bash 3.2)
# ============================================

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Configuración - Cambiar aquí el símbolo
SYMBOL="${1:-ZECUSDT}"
DEPTH="depth20"
SPEED="100ms"

# Convertir símbolo a minúsculas (compatible con MacOS)
LOWERCASE_SYMBOL=$(echo "$SYMBOL | tr '[:upper:]' '[:lower:]'")

# Construir URL del WebSocket
WS_URL="wss://fstream.binance.com/public/ws/${LOWERCASE_SYMBOL}@${DEPTH}@${SPEED}"

# Contadores
message_count=0
bid_walls=0
ask_walls=0

# ============================================
# FUNCIONES
# ============================================

clear_screen() {
    printf "\033[2J\033[H"
}

show_header() {
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}           BINANCE ORDER BOOK L2 - TIEMPO REAL - ${SYMBOL}${NC}"
    echo -e "${CYAN}${BOLD}           Profundidad: ${DEPTH} | Velocidad: ${SPEED}${NC}"
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Prec: ${BOLD}Precio${NC}   ${GREEN}Vol: Cantidad${NC}   ${BLUE}Total: Volumen total${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────────────────${NC}"
}

show_bids() {
    local bids="$1"
    local cumulative=0
    
    echo -e "${GREEN}${BOLD}▶ BIDS (Órdenes de Compra) - Soporte${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────────────────${NC}"
    printf " ${BOLD}%-12s %-15s %-15s${NC}\n" "Precio" "Volumen" "Total USD"
    
    while IFS='|' read -r price quantity; do
        if [ -n "$price" ] && [ -n "$quantity" ]; then
            total_usd=$(echo "$price * $quantity" | bc 2>/dev/null)
            
            if (( $(echo "$quantity > 5" | bc -l 2>/dev/null) )); then
                echo -e " ${GREEN}▶${NC} ${GREEN}$price${NC}  ${GREEN}$quantity${NC}      \$${total_usd}"
                ((bid_walls++))
            else
                echo -e "   ${GREEN}$price${NC}  ${quantity}      \$${total_usd}"
            fi
        fi
    done <<< "$bids"
    echo ""
}

show_asks() {
    local asks="$1"
    local cumulative=0
    
    echo -e "${RED}${BOLD}▼ ASKS (Órdenes de Venta) - Resistencia${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────────────────${NC}"
    printf " ${BOLD}%-12s %-15s %-15s${NC}\n" "Precio" "Volumen" "Total USD"
    
    while IFS='|' read -r price quantity; do
        if [ -n "$price" ] && [ -n "$quantity" ]; then
            total_usd=$(echo "$price * $quantity" | bc 2>/dev/null)
            
            if (( $(echo "$quantity > 5" | bc -l 2>/dev/null) )); then
                echo -e " ${RED}▼${NC} ${RED}$price${NC}  ${RED}$quantity${NC}      \$${total_usd}"
                ((ask_walls++))
            else
                echo -e "   ${RED}$price${NC}  ${quantity}      \$${total_usd}"
            fi
        fi
    done <<< "$asks"
    echo ""
}

show_stats() {
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}📊 Estadísticas:${NC}"
    echo -e "   Mensajes recibidos: ${message_count}"
    echo -e "   Paredes de compra (Bid Walls >5): ${bid_walls}"
    echo -e "   Paredes de venta (Ask Walls >5): ${ask_walls}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
}

# ============================================
# PROCESAR MENSAJE DEL WEBSOCKET
# ============================================

process_message() {
    local msg="$1"
    
    ((message_count++))
    
    # Extraer bids y asks usando jq
    local bids=$(echo "$msg" | jq -r '.b[]? | "\(.[0])|\(.[1])"' 2>/dev/null | head -10)
    local asks=$(echo "$msg" | jq -r '.a[]? | "\(.[0])|\(.[1])"' 2>/dev/null | head -10)
    
    clear_screen
    show_header
    echo ""
    
    if [ -n "$bids" ]; then
        show_bids "$bids"
    else
        echo -e "${YELLOW}No hay datos de Bids disponibles...${NC}\n"
    fi
    
    if [ -n "$asks" ]; then
        show_asks "$asks"
    else
        echo -e "${YELLOW}No hay datos de Asks disponibles...${NC}\n"
    fi
    
    local best_bid=$(echo "$msg" | jq -r '.b[0][0] // "N/A"' 2>/dev/null)
    local best_ask=$(echo "$msg" | jq -r '.a[0][0] // "N/A"' 2>/dev/null)
    local bid_qty=$(echo "$msg" | jq -r '.b[0][1] // "0"' 2>/dev/null)
    local ask_qty=$(echo "$msg" | jq -r '.a[0][1] // "0"' 2>/dev/null)
    
    echo -e "${MAGENTA}${BOLD}📈 RESUMEN${NC}"
    echo -e "   ${GREEN}Best Bid: $best_bid (Vol: $bid_qty)${NC}"
    echo -e "   ${RED}Best Ask: $best_ask (Vol: $ask_qty)${NC}"
    
    if [ "$best_bid" != "N/A" ] && [ "$best_ask" != "N/A" ]; then
        spread=$(echo "$best_ask - $best_bid" | bc -l 2>/dev/null)
        spread_pct=$(echo "scale=4; ($spread / $best_bid) * 100" | bc -l 2>/dev/null)
        echo -e "   ${YELLOW}Spread: $spread (${spread_pct}%)${NC}"
    fi
    
    show_stats
}

# ============================================
# CONEXIÓN WEBSOCKET
# ============================================

connect_websocket() {
    echo -e "${BLUE}🔌 Conectando a Binance WebSocket...${NC}"
    echo -e "${BLUE}   URL: $WS_URL${NC}"
    echo -e "${YELLOW}   Presiona Ctrl+C para salir${NC}"
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
        echo -e "${RED}❌ Error: Necesitas websocat o wscat${NC}"
        echo -e "${YELLOW}Instalación:${NC}"
        echo -e "   brew install websocat    (MacOS)"
        echo -e "   npm install -g wscat     (Node.js)"
        exit 1
    fi
}

# ============================================
# MAIN
# ============================================

main() {
    echo -e "${BLUE}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         BINANCE WEBSOCKET - ORDER BOOK L2 VIEWER            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}❌ jq no está instalado. Instálalo con:${NC}"
        echo -e "   brew install jq"
        exit 1
    fi
    
    connect_websocket
}

trap 'echo -e "\n${YELLOW}👋 Desconectando...${NC}"; exit 0' INT

main "$@"