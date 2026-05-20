#!/bin/bash

# ============================================
# Crypto Bot Automático v5.0
# Múltiples órdenes por ejecución
# Totalmente configurable vía .env
# ============================================

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
# VALORES POR DEFECTO (si no están en .env)
# ============================================

# APIs
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
FINANDY_SECRET="${FINANDY_SECRET:-d1a01uf5uoe}"
FINANDY_WEBHOOK="${FINANDY_WEBHOOK:-https://hook.finandy.com/LMEnRji-3GvFkm7wqFUK}"

# Telegram
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Ventana horaria (UTC)
EXECUTION_HOUR_START="${EXECUTION_HOUR_START:-0}"
EXECUTION_HOUR_END="${EXECUTION_HOUR_END:-23}"

# Días permitidos (1=Lunes, 7=Domingo)
ALLOWED_DAYS="${ALLOWED_DAYS:-1,2,3,4,5,6,7}"

# Reglas de selección
MIN_VOLUME="${MIN_VOLUME:-5000000}"
MAX_LOSER_CHANGE="${MAX_LOSER_CHANGE:--50}"
MAX_GAINER_CHANGE="${MAX_GAINER_CHANGE:-50}"

# Órdenes múltiples
MAX_ORDERS_PER_RUN="${MAX_ORDERS_PER_RUN:-3}"
DELAY_BETWEEN_ORDERS="${DELAY_BETWEEN_ORDERS:-2}"

# ============================================
# DIRECTORIOS Y LOGS
# ============================================

LOG_DIR="$SCRIPT_DIR/logs"
HISTORY_DIR="$SCRIPT_DIR/history"
mkdir -p "$LOG_DIR" "$HISTORY_DIR"

# ============================================
# MODOS
# ============================================

DRY_RUN=false
if [[ "$1" == "--dry-run" ]] || [[ "$1" == "-d" ]]; then
    DRY_RUN=true
    echo "🔍 MODO DRY-RUN: No se ejecutarán órdenes reales"
fi

# ============================================
# COLORES (para consola)
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================
# FUNCIÓN: TELEGRAM (texto plano)
# ============================================

send_telegram() {
    local message="$1"
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo -e "${YELLOW}⚠️ Telegram no configurado${NC}"
        return 1
    fi
    
    local response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"${TELEGRAM_CHAT_ID}\",
            \"text\": \"${message}\"
        }")
    
    if echo "$response" | grep -q '"ok":true'; then
        echo -e "${GREEN}📱 Telegram enviado${NC}"
    else
        echo -e "${RED}❌ Error Telegram: $response${NC}"
    fi
}

# ============================================
# FUNCIÓN: LOGS
# ============================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | tee -a "$LOG_DIR/trades.log"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo -e "${RED}$msg${NC}" | tee -a "$LOG_DIR/errors.log"
    send_telegram "❌ ERROR: $1"
}

# ============================================
# FUNCIÓN: VALIDACIÓN DE EJECUCIÓN
# ============================================

is_execution_time_allowed() {
    local current_hour=$(date +%H | sed 's/^0//')
    local current_day=$(date +%u)
    
    if ! echo "$ALLOWED_DAYS" | grep -q "\b${current_day}\b"; then
        log "⏸️ Día no permitido: $(date +%A) (día $current_day)"
        return 1
    fi
    
    if [ $current_hour -lt $EXECUTION_HOUR_START ] || [ $current_hour -ge $EXECUTION_HOUR_END ]; then
        log "⏸️ Hora no permitida: $current_hour (ventana $EXECUTION_HOUR_START-$EXECUTION_HOUR_END UTC)"
        return 1
    fi
    
    return 0
}

# ============================================
# FUNCIÓN: OBTENER TICKERS DE BINANCE
# ============================================

get_tickers() {
    local response=$(curl -s "https://api.binance.com/api/v3/ticker/24hr")
    echo "$response" | jq -r "
        .[] | 
        select(.symbol | endswith(\"USDT\")) |
        select(.quoteVolume | tonumber > $MIN_VOLUME) |
        \"\(.symbol)|\(.lastPrice|tonumber)|\(.priceChangePercent|tonumber)|\(.quoteVolume|tonumber)\"
    "
}

get_top_gainer() {
    echo "$1" | sort -t'|' -k3 -rn | head -1
}

get_top_loser() {
    echo "$1" | sort -t'|' -k3 -n | head -1
}

# ============================================
# FUNCIÓN: ANALIZAR CON DEEPSEEK
# ============================================

analyze_symbol() {
    local symbol="$1"
    local last_price="$2"
    local change_24h="$3"
    local direction="$4"
    
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
        log_error "DeepSeek no respondió"
        return 1
    fi
    
    # Limpiar y corregir JSON
    content=$(echo "$content" | sed -E 's/```json\s*//g' | sed -E 's/```\s*//g' | tr -d '\n\r' | xargs)
    content=$(echo "$content" | sed -E 's/([a-z_]+):/\"\1\":/g')
    content=$(echo "$content" | sed -E 's/:([A-Za-z][A-Za-z0-9_]*)/:\"\1\"/g')
    content=$(echo "$content" | sed -E 's/: ([A-Za-z][A-Za-z0-9_]*)/: \"\1\"/g')
    content=$(echo "$content" | sed -E 's/^\s*\{?/{/' | sed -E 's/\}?\s*$/}/')
    
    if ! echo "$content" | jq empty 2>/dev/null; then
        log_error "JSON inválido: $content"
        return 1
    fi
    
    echo "$content"
}

# ============================================
# FUNCIÓN: ENVIAR ORDEN A FINANDY
# ============================================

send_order() {
    local symbol="$1" direction="$2" entry="$3" sl="$4" tp1="$5" tp2="$6" trailing="$7"
    
    local side="buy"
    local pos_side="long"
    if [ "$direction" = "SHORT" ]; then
        side="sell"
        pos_side="short"
    fi
    
    local order_name="Deepseek_Auto_${symbol}_${direction}_$(date '+%Y%m%d_%H%M%S')"
    
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
    "schedulerValue": "240"
  },
  "tp": {
    "enabled": true,
    "orders": [
      {"price": "$tp1", "piece": "40.0"},
      {"price": "$tp2", "piece": "30.0"},
      {"ofs": "$trailing", "piece": "30.0"}
    ]
  },
  "sl": {
    "price": "$sl",
    "enabled": true
  }
}
EOF
)
    
    log "📝 Orden: $order_name"
    log "   Entry: $entry | SL: $sl | TP1: $tp1 | TP2: $tp2"
    
    if [ "$DRY_RUN" = true ]; then
        log "🔍 DRY-RUN: No se ejecutó la orden"
        echo "$payload" >> "$HISTORY_DIR/dry_runs.txt"
        send_telegram "🔍 DRY-RUN: $symbol $direction Entry:$entry SL:$sl"
        return 0
    fi
    
    local response=$(curl -s -X POST "$FINANDY_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    log "📡 Respuesta Finandy: $response"
    
    if echo "$response" | jq -e '.code == 200 or .success == true' >/dev/null 2>&1; then
        log "✅ Orden ejecutada"
        echo "$(date '+%Y-%m-%d %H:%M:%S')|$symbol|$direction|$entry|$sl|$tp1|$tp2|$response" >> "$HISTORY_DIR/orders.csv"
        send_telegram "✅ ORDEN: $symbol $direction Entry:$entry SL:$sl TP1:$tp1 TP2:$tp2"
    else
        log_error "Fallo en orden: $response"
        send_telegram "❌ ERROR: Fallo en orden $symbol - $response"
    fi
}

# ============================================
# FUNCIÓN: PROCESAR MÚLTIPLES ÓRDENES
# ============================================

process_multiple_orders() {
    local tickers="$1"
    local orders_processed=0
    
    # Obtener top 3 losers y top 3 gainers
    local top_losers=$(echo "$tickers" | sort -t'|' -k3 -n | head -3)
    local top_gainers=$(echo "$tickers" | sort -t'|' -k3 -rn | head -3)
    
    local orders_to_execute=()
    
    # 1. Procesar LOSERS (para LONG)
    while IFS='|' read -r symbol last change volume; do
        if [ -z "$symbol" ]; then continue; fi
        if (( $(echo "$volume > $MIN_VOLUME" | bc -l) )) && (( $(echo "$change > $MAX_LOSER_CHANGE" | bc -l) )); then
            orders_to_execute+=("$symbol|$last|$change|LONG")
            log "${GREEN}📋 Candidato LONG: $symbol (${change}%) @ $last${NC}"
        fi
    done <<< "$top_losers"
    
    # 2. Procesar GAINERS (para SHORT)
    while IFS='|' read -r symbol last change volume; do
        if [ -z "$symbol" ]; then continue; fi
        if (( $(echo "$volume > $MIN_VOLUME" | bc -l) )) && (( $(echo "$change < $MAX_GAINER_CHANGE" | bc -l) )); then
            orders_to_execute+=("$symbol|$last|$change|SHORT")
            log "${RED}📋 Candidato SHORT: $symbol (+${change}%) @ $last${NC}"
        fi
    done <<< "$top_gainers"
    
    # 3. Ejecutar hasta MAX_ORDERS_PER_RUN
    for order in "${orders_to_execute[@]}"; do
        if [ $orders_processed -ge $MAX_ORDERS_PER_RUN ]; then
            log "⏸️ Límite de $MAX_ORDERS_PER_RUN órdenes alcanzado"
            break
        fi
        
        IFS='|' read -r symbol last change direction <<< "$order"
        
        log "🎯 Procesando orden $((orders_processed+1)): $symbol ($direction)"
        send_telegram "🎯 Procesando: $symbol - $direction (${change}%)"
        
        local analysis=$(analyze_symbol "$symbol" "$last" "$change" "$direction")
        if [ $? -ne 0 ] || [ -z "$analysis" ]; then
            log_error "Fallo en análisis de $symbol"
            continue
        fi
        
        local entry=$(echo "$analysis" | jq -r '.entry_price // empty')
        local sl=$(echo "$analysis" | jq -r '.stop_loss // empty')
        local tp1=$(echo "$analysis" | jq -r '.take_profits[0] // empty')
        local tp2=$(echo "$analysis" | jq -r '.take_profits[1] // empty')
        local trailing=$(echo "$analysis" | jq -r '.trailing_ofs // 1.5')
        
        if [ -z "$entry" ] || [ -z "$sl" ] || [ -z "$tp1" ] || [ -z "$tp2" ]; then
            log_error "Datos incompletos para $symbol"
            continue
        fi
        
        send_order "$symbol" "$direction" "$entry" "$sl" "$tp1" "$tp2" "$trailing"
        orders_processed=$((orders_processed + 1))
        
        if [ $orders_processed -lt $MAX_ORDERS_PER_RUN ]; then
            sleep $DELAY_BETWEEN_ORDERS
        fi
    done
    
    log "📊 Total órdenes procesadas: $orders_processed"
    send_telegram "📊 Total órdenes esta ejecución: $orders_processed"
}

# ============================================
# FUNCIÓN PRINCIPAL
# ============================================

main() {
    log "${BLUE}🚀 Iniciando Crypto Bot v5.0${NC}"
    
    # Validar ventana horaria
    if ! is_execution_time_allowed; then
        log "⏸️ Bot detenido por ventana horaria/días"
        exit 0
    fi
    
    # Verificar API key
    if [ -z "$DEEPSEEK_API_KEY" ]; then
        log_error "DEEPSEEK_API_KEY no configurada"
        exit 1
    fi
    
    # Notificar inicio
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        send_telegram "🤖 Bot iniciado - $(date '+%H:%M:%S')"
    fi
    
    # Obtener datos del mercado
    local tickers=$(get_tickers)
    if [ -z "$tickers" ]; then
        log_error "No se pudieron obtener datos de Binance"
        exit 1
    fi
    
    # Obtener top gainer y top loser para reporte
    local top_gainer=$(get_top_gainer "$tickers")
    local top_loser=$(get_top_loser "$tickers")
    
    IFS='|' read -r gainer_symbol gainer_last gainer_change gainer_vol <<< "$top_gainer"
    IFS='|' read -r loser_symbol loser_last loser_change loser_vol <<< "$top_loser"
    
    log "${GREEN}📈 Top Gainer: $gainer_symbol (+${gainer_change}%) @ $gainer_last${NC}"
    log "${RED}📉 Top Loser: $loser_symbol (${loser_change}%) @ $loser_last${NC}"
    
    # Procesar múltiples órdenes
    process_multiple_orders "$tickers"
    
    log "${GREEN}✅ Bot finalizado${NC}"
    send_telegram "✅ Bot finalizado - $(date '+%H:%M:%S')"
}

# ============================================
# EJECUTAR
# ============================================

main "$@"