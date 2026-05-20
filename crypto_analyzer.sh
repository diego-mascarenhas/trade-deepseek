#!/bin/bash

# ============================================
# Crypto Analyzer Interactivo v1.0
# - Nombre de orden: "Deepseek Analyzer vX.Y.Z"
# ============================================

BOT_VERSION="v1.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ============================================
# CARGAR CONFIGURACIÓN DESDE .env
# ============================================

if [ -f .env ]; then
    source .env
else
    echo "❌ Error: .env no encontrado en $SCRIPT_DIR"
    exit 1
fi

# ============================================
# CONFIGURACIÓN
# ============================================

DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
FINANDY_WEBHOOK="${FINANDY_WEBHOOK:-https://hook.finandy.com/LMEnRji-3GvFkm7wqFUK}"
FINANDY_SECRET="${FINANDY_SECRET:-d1a01uf5uoe}"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================
# VALIDAR API KEY
# ============================================

if [ -z "$DEEPSEEK_API_KEY" ]; then
    echo -e "${RED}❌ DEEPSEEK_API_KEY no configurada en .env${NC}"
    exit 1
fi

# ============================================
# FUNCIONES
# ============================================

parse_deepseek_json() {
    local raw="$1"
    local content="$raw"
    
    content=$(echo "$content" | sed -E 's/```json\s*//g' | sed -E 's/```\s*//g')
    content=$(echo "$content" | tr -d '\n\r')
    content="${content#"${content%%[![:space:]]*}"}"
    content="${content%"${content##*[![:space:]]}"}"
    
    if [[ "$content" =~ (\{[[:print:]]+\}) ]]; then
        content="${BASH_REMATCH[1]}"
    fi
    
    if echo "$content" | jq empty 2>/dev/null; then
        echo "$content"
        return 0
    fi
    
    local fixed="$content"
    fixed=$(echo "$fixed" | sed -E 's/([{,][[:space:]]*)([a-z_][a-z0-9_]*):/\1"\2":/g')
    fixed=$(echo "$fixed" | sed -E 's/:([[:space:]]*)([A-Za-z][A-Za-z0-9_]*)([,}])/: "\2"\3/g')
    
    if echo "$fixed" | jq empty 2>/dev/null; then
        echo "$fixed"
        return 0
    fi
    
    return 1
}

get_tickers() {
    local response=$(curl -s "https://api.binance.com/api/v3/ticker/24hr")
    echo "$response" | jq -r '
        .[] | 
        select(.symbol | endswith("USDT")) |
        select(.quoteVolume | tonumber > 5000000) |
        "\(.symbol)|\(.lastPrice|tonumber)|\(.priceChangePercent|tonumber)|\(.quoteVolume|tonumber)"
    '
}

show_gainers() {
    echo -e "\n${GREEN}📈 TOP 20 GAINERS (24h)${NC}"
    printf "%-3s %-15s %-12s %-10s %-15s\n" "#" "SÍMBOLO" "PRECIO" "% 24h" "VOL(USDT)"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    local i=1
    echo "$1" | sort -t'|' -k3 -rn | head -20 | while IFS='|' read -r symbol last change volume; do
        printf "%-3s ${GREEN}%-15s${NC} %-12s ${GREEN}+%-9.2f${NC} %-15s\n" "$i" "$symbol" "$last" "$change" "$(printf "%.0f" "$volume")"
        ((i++))
    done
}

show_losers() {
    echo -e "\n${RED}📉 TOP 20 LOSERS (24h)${NC}"
    printf "%-3s %-15s %-12s %-10s %-15s\n" "#" "SÍMBOLO" "PRECIO" "% 24h" "VOL(USDT)"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    local i=1
    echo "$1" | sort -t'|' -k3 -n | head -20 | while IFS='|' read -r symbol last change volume; do
        printf "%-3s ${RED}%-15s${NC} %-12s ${RED}%-9.2f${NC} %-15s\n" "$i" "$symbol" "$last" "$change" "$(printf "%.0f" "$volume")"
        ((i++))
    done
}

analyze_symbol() {
    local symbol="$1"
    local last_price="$2"
    local change_24h="$3"
    local direction="$4"
    
    echo -e "${BLUE}🤖 Consultando a DeepSeek para $symbol...${NC}"
    
    local prompt=$(cat <<EOF
Eres un analista de criptomonedas.

Símbolo: $symbol
Precio actual: $last_price
Cambio 24h: $change_24h%
Dirección: $direction

Devuelve EXACTAMENTE este JSON válido:
{"symbol":"$symbol","direction":"$direction","entry_price":0.0,"stop_loss":0.0,"take_profits":[0.0,0.0],"trailing_ofs":1.5,"leverage":5,"scheduler_minutes":240}

Reemplaza:
- entry_price: precio de entrada (si LONG < $last_price, si SHORT > $last_price)
- stop_loss: stop loss (1.5-3% de distancia)
- take_profits: dos objetivos

SOLO JSON. NADA MÁS.
EOF
)

    local response=$(curl -s "https://api.deepseek.com/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -d "{
            \"model\": \"deepseek-chat\",
            \"messages\": [{\"role\": \"user\", \"content\": $(echo "$prompt" | jq -s -R -r @json)}]
        }")
    
    local content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    
    if [ -z "$content" ]; then
        echo -e "${RED}❌ DeepSeek no respondió${NC}"
        return 1
    fi
    
    content=$(parse_deepseek_json "$content")
    if [ $? -ne 0 ] || [ -z "$content" ]; then
        echo -e "${RED}❌ JSON inválido en respuesta DeepSeek${NC}"
        return 1
    fi
    
    echo "$content"
}

generate_curl() {
    local symbol="$1" direction="$2" entry="$3" sl="$4" tp1="$5" tp2="$6" trailing="$7"
    local side="buy"; local pos_side="long"
    [ "$direction" = "SHORT" ] && side="sell" && pos_side="short"
    
    local order_name="Deepseek Analyzer ${BOT_VERSION}"
    
    cat <<EOF
curl -X POST "$FINANDY_WEBHOOK" -H "Content-Type: application/json" -d '{"name":"${order_name}","secret":"$FINANDY_SECRET","symbol":"$symbol","side":"$side","positionSide":"$pos_side","open":{"price":"$entry","schedulerMode":"min","schedulerValue":"240"},"tp":{"enabled":true,"orders":[{"price":"$tp1","piece":"40.0"},{"price":"$tp2","piece":"30.0"},{"ofs":"$trailing","piece":"30.0"}]},"sl":{"price":"$sl","enabled":true}}'
EOF
}

# ============================================
# MAIN
# ============================================

main() {
    echo -e "${BLUE}🔍 Crypto Analyzer ${BOT_VERSION}${NC}"
    local tickers=$(get_tickers)
    
    show_gainers "$tickers"
    show_losers "$tickers"
    
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "🔍 Símbolo: " selected_symbol
    
    local symbol_data=$(echo "$tickers" | grep -i "^${selected_symbol}|")
    if [ -z "$symbol_data" ]; then
        echo -e "${RED}❌ Símbolo no encontrado${NC}"
        exit 1
    fi
    
    IFS='|' read -r symbol last change volume <<< "$symbol_data"
    
    local direction=""
    local gainers_list=$(echo "$tickers" | sort -t'|' -k3 -rn | head -20 | cut -d'|' -f1)
    local losers_list=$(echo "$tickers" | sort -t'|' -k3 -n | head -20 | cut -d'|' -f1)
    
    if echo "$gainers_list" | grep -qi "^${symbol}$" && ! echo "$losers_list" | grep -qi "^${symbol}$"; then
        direction="SHORT"
        echo -e "${RED}📉 $symbol en GAINERS → SHORT${NC}"
    elif echo "$losers_list" | grep -qi "^${symbol}$" && ! echo "$gainers_list" | grep -qi "^${symbol}$"; then
        direction="LONG"
        echo -e "${GREEN}📈 $symbol en LOSERS → LONG${NC}"
    else
        read -p "Dirección (LONG/SHORT): " direction
        direction=$(echo "$direction" | tr '[:lower:]' '[:upper:]')
    fi
    
    local analysis=$(analyze_symbol "$symbol" "$last" "$change" "$direction")
    if [ $? -ne 0 ] || [ -z "$analysis" ]; then
        exit 1
    fi
    
    local entry=$(echo "$analysis" | jq -r '.entry_price // empty')
    local sl=$(echo "$analysis" | jq -r '.stop_loss // empty')
    local tp1=$(echo "$analysis" | jq -r '.take_profits[0] // empty')
    local tp2=$(echo "$analysis" | jq -r '.take_profits[1] // empty')
    local trailing=$(echo "$analysis" | jq -r '.trailing_ofs // 1.5')
    
    if [ -z "$entry" ] || [ -z "$sl" ] || [ -z "$tp1" ] || [ -z "$tp2" ]; then
        echo -e "${RED}❌ Datos incompletos${NC}"
        exit 1
    fi
    
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}📊 ESTRATEGIA PARA $symbol${NC}"
    echo -e "📌 Dirección: $direction"
    echo -e "🎯 Entrada: $entry"
    echo -e "🛑 Stop Loss: $sl"
    echo -e "✅ TP1: $tp1 (40%) | TP2: $tp2 (30%) | Trailing: ${trailing}% (30%)"
    
    local curl_cmd=$(generate_curl "$symbol" "$direction" "$entry" "$sl" "$tp1" "$tp2" "$trailing")
    echo -e "\n${YELLOW}📋 cURL para Finandy:${NC}\n$curl_cmd"
    
    read -p "🚀 ¿Ejecutar? (s/N): " execute
    if [[ "$execute" =~ ^[Ss]$ ]]; then
        eval "$curl_cmd"
        echo -e "${GREEN}✅ Orden enviada${NC}"
    else
        echo -e "${YELLOW}⏸️ No ejecutada${NC}"
    fi
}

main "$@"
