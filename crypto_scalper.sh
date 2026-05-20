#!/bin/bash

# ============================================
# Crypto Scalper 1 Minuto v1.2
# - Soporta modo dry-run
# - Datos en tiempo real de Binance
# - Order Books para niveles OB
# - Loop infinito cada 60 segundos
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
# MODO DRY-RUN
# ============================================

DRY_RUN=false
if [[ "$1" == "--dry-run" ]] || [[ "$1" == "-d" ]]; then
    DRY_RUN=true
    echo "🔍 MODO DRY-RUN: No se ejecutarán órdenes reales"
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

# Parámetros de scalping
SCALPER_INTERVAL="${SCALPER_INTERVAL:-1m}"
SCALPER_OB_DEPTH="${SCALPER_OB_DEPTH:-10}"
SCALPER_GRID_LEVELS="${SCALPER_GRID_LEVELS:-3}"
SCALPER_TP_PERCENT="${SCALPER_TP_PERCENT:-0.5}"
SCALPER_SL_PERCENT="${SCALPER_SL_PERCENT:-0.3}"
SCALPER_MIN_CONFIDENCE="${SCALPER_MIN_CONFIDENCE:-50}"
SCALPER_MAX_SYMBOLS="${SCALPER_MAX_SYMBOLS:-3}"
SCALPER_SCHEDULER_MINUTES="${SCALPER_SCHEDULER_MINUTES:-2}"
SCALPER_MIN_TRADE_COUNT="${SCALPER_MIN_TRADE_COUNT:-10000}"
SCALPER_MIN_QUOTE_VOLUME="${SCALPER_MIN_QUOTE_VOLUME:-1000000}"

# ============================================
# DIRECTORIOS
# ============================================

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

# ============================================
# COLORES
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================
# FUNCIONES BÁSICAS
# ============================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | tee -a "$LOG_DIR/scalper.log"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo -e "${RED}$msg${NC}" | tee -a "$LOG_DIR/scalper_errors.log"
}

send_telegram() {
    local message="$1"
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        return 1
    fi
    
    local escaped=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/\-/\\-/g' | sed 's/\./\\\\./g')
    
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": \"${escaped}\"}" > /dev/null
}

# ============================================
# FUNCIONES DE BINANCE
# ============================================

get_current_price() {
    local symbol="$1"
    local ticker=$(curl -s "https://api.binance.com/api/v3/ticker/price?symbol=$symbol")
    echo "$ticker" | jq -r '.price // 0'
}

get_24h_ticker() {
    local symbol="$1"
    curl -s "https://api.binance.com/api/v3/ticker/24hr?symbol=$symbol"
}

get_order_book() {
    local symbol="$1"
    local depth="${2:-$SCALPER_OB_DEPTH}"
    curl -s "https://api.binance.com/api/v3/depth?symbol=$symbol&limit=$depth"
}

analyze_order_book() {
    local symbol="$1"
    local order_book=$(get_order_book "$symbol" "$SCALPER_OB_DEPTH")

    local bid_count=$(echo "$order_book" | jq -r '.bids | length // 0' 2>/dev/null)
    if [ "$bid_count" -eq 0 ]; then
        echo "|||"
        return 1
    fi

    local support=$(echo "$order_book" | jq -r '.bids[0][0] // empty')
    local resistance=$(echo "$order_book" | jq -r '.asks[0][0] // empty')
    local bid_volume=$(echo "$order_book" | jq '[.bids[:5][] | .[1] | tonumber] | if length > 0 then add else 0 end')
    local ask_volume=$(echo "$order_book" | jq '[.asks[:5][] | .[1] | tonumber] | if length > 0 then add else 0 end')

    echo "$support|$resistance|$bid_volume|$ask_volume"
}

parse_ai_json() {
    local content="$1"

    content=$(echo "$content" | sed -E 's/```json\s*//g' | sed -E 's/```\s*//g' | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if echo "$content" | jq -e '.' >/dev/null 2>&1; then
        echo "$content" | jq -c '.'
        return 0
    fi

    if [[ "$content" =~ (\{.*\}) ]]; then
        local extracted="${BASH_REMATCH[1]}"
        if echo "$extracted" | jq -e '.' >/dev/null 2>&1; then
            echo "$extracted" | jq -c '.'
            return 0
        fi
    fi

    echo '{"trend":"NEUTRAL","confidence":0,"entry_price":0,"stop_loss":0,"tp_price":0}'
    return 1
}

# ============================================
# OBTENER TOP GAINERS Y LOSERS
# ============================================

get_top_gainers() {
    local limit="${1:-$SCALPER_MAX_SYMBOLS}"
    local response=$(curl -s "https://api.binance.com/api/v3/ticker/24hr")
    echo "$response" | jq -r --argjson min_count "$SCALPER_MIN_TRADE_COUNT" --argjson min_vol "$SCALPER_MIN_QUOTE_VOLUME" '
        [.[] |
        select(.symbol | endswith("USDT")) |
        select(.symbol | test("^[A-Z0-9]+USDT$")) |
        select(.priceChangePercent | tonumber > 3) |
        select(.count | tonumber >= $min_count) |
        select(.quoteVolume | tonumber >= $min_vol)] |
        sort_by(-(.quoteVolume | tonumber)) |
        .[:'"$limit"'] |
        .[].symbol
    '
}

get_top_losers() {
    local limit="${1:-$SCALPER_MAX_SYMBOLS}"
    local response=$(curl -s "https://api.binance.com/api/v3/ticker/24hr")
    echo "$response" | jq -r --argjson min_count "$SCALPER_MIN_TRADE_COUNT" --argjson min_vol "$SCALPER_MIN_QUOTE_VOLUME" '
        [.[] |
        select(.symbol | endswith("USDT")) |
        select(.symbol | test("^[A-Z0-9]+USDT$")) |
        select(.priceChangePercent | tonumber < -3) |
        select(.count | tonumber >= $min_count) |
        select(.quoteVolume | tonumber >= $min_vol)] |
        sort_by(-(.quoteVolume | tonumber)) |
        .[:'"$limit"'] |
        .[].symbol
    '
}

# ============================================
# ANÁLISIS CON DEEPSEEK
# ============================================

analyze_trend_with_deepseek() {
    local symbol="$1"
    local last_price="$2"
    local change_24h="$3"
    local support="$4"
    local resistance="$5"
    
    local prompt=$(cat <<EOF
Eres un analista de scalping en criptomonedas.

Simbolo: $symbol
Precio actual: $last_price
Cambio 24h: $change_24h%
Soporte (OB): $support
Resistencia (OB): $resistance

Analiza la tendencia para SCALPING a 1 minuto.
Devuelve SOLO este JSON:
{"trend":"LONG|SHORT|NEUTRAL","confidence":0,"entry_price":0.0,"stop_loss":0.0,"tp_price":0.0}

Reglas:
- trend: LONG si el precio está cerca de soporte, SHORT si cerca de resistencia
- confidence: 0-100 (minimo 50 para operar)
- entry_price: precio de entrada (LONG = soporte +0.1%, SHORT = resistencia -0.1%)
- stop_loss: LONG = entrada -0.3%, SHORT = entrada +0.3%
- tp_price: LONG = entrada +0.5%, SHORT = entrada -0.5%

SOLO JSON. NADA MAS.
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
        echo '{"trend":"NEUTRAL","confidence":0,"entry_price":0,"stop_loss":0,"tp_price":0}'
        return 1
    fi

    parse_ai_json "$content"
}

# ============================================
# ENVIAR ORDEN SCALPING
# ============================================

send_scalp_order() {
    local symbol="$1" direction="$2" entry="$3" sl="$4" tp="$5"
    
    local side="buy"
    local pos_side="long"
    if [ "$direction" = "SHORT" ]; then
        side="sell"
        pos_side="short"
    fi
    
    local order_name="Scalp_${symbol}_${direction}_$(date '+%Y%m%d_%H%M%S')"
    
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
    "schedulerValue": "$SCALPER_SCHEDULER_MINUTES"
  },
  "tp": {
    "enabled": true,
    "orders": [
      {"price": "$tp", "piece": "100.0"}
    ]
  },
  "sl": {
    "price": "$sl",
    "enabled": true
  }
}
EOF
)
    
    log "📝 SCALP: $symbol $direction | Entry:$entry SL:$sl TP:$tp"
    
    if [ "$DRY_RUN" = true ]; then
        log "🔍 DRY-RUN: No se ejecutó la orden"
        echo "$payload" >> "$LOG_DIR/dry_runs_scalper.txt"
        send_telegram "🔍 DRY-RUN SCALP: $symbol $direction Entry:$entry TP:$tp SL:$sl"
        return 0
    fi
    
    local response=$(curl -s -X POST "$FINANDY_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    log "📡 Respuesta Finandy: $response"
    
    if echo "$response" | jq -e '.code == 200 or .success == true' >/dev/null 2>&1; then
        log "✅ Scalp ejecutado: $symbol"
        send_telegram "⚡ SCALP: $symbol $direction Entry:$entry TP:$tp SL:$sl"
    else
        log_error "Fallo en scalp: $response"
        send_telegram "❌ ERROR: Fallo scalp $symbol"
    fi
}

# ============================================
# PROCESAR UN SÍMBOLO
# ============================================

process_symbol() {
    local symbol="$1"
    
    log "${YELLOW}🔍 Analizando $symbol${NC}"
    
    # Obtener datos en tiempo real
    local current_price=$(get_current_price "$symbol")
    if [ -z "$current_price" ] || [ "$current_price" = "0" ]; then
        log_error "No se pudo obtener precio para $symbol"
        return 1
    fi
    
    local ticker_24h=$(get_24h_ticker "$symbol")
    local change_24h=$(echo "$ticker_24h" | jq -r '.priceChangePercent // 0')
    
    # Obtener order book (saltar pares sin libro activo)
    local ob_data
    if ! ob_data=$(analyze_order_book "$symbol"); then
        log "⏭️ $symbol sin order book activo, saltando"
        return 0
    fi
    local support=$(echo "$ob_data" | cut -d'|' -f1)
    local resistance=$(echo "$ob_data" | cut -d'|' -f2)
    local bid_vol=$(echo "$ob_data" | cut -d'|' -f3)
    local ask_vol=$(echo "$ob_data" | cut -d'|' -f4)

    if [ -z "$support" ] || [ -z "$resistance" ]; then
        log "⏭️ $symbol sin niveles OB válidos, saltando"
        return 0
    fi

    log "📊 $symbol | Precio: $current_price | 24h: ${change_24h}%"
    log "   Soporte: $support | Resistencia: $resistance"
    log "   Volumen Bid: $bid_vol | Ask: $ask_vol"
    
    # Analizar con DeepSeek
    local analysis=$(analyze_trend_with_deepseek "$symbol" "$current_price" "$change_24h" "$support" "$resistance")
    local trend=$(echo "$analysis" | jq -r '.trend // "NEUTRAL"' 2>/dev/null)
    local confidence=$(echo "$analysis" | jq -r '.confidence // 0' 2>/dev/null)
    local entry=$(echo "$analysis" | jq -r '.entry_price // 0' 2>/dev/null)
    local sl=$(echo "$analysis" | jq -r '.stop_loss // 0' 2>/dev/null)
    local tp=$(echo "$analysis" | jq -r '.tp_price // 0' 2>/dev/null)

    confidence="${confidence:-0}"
    if ! [[ "$confidence" =~ ^[0-9]+$ ]]; then
        log_error "Confianza inválida de DeepSeek para $symbol: $confidence"
        return 1
    fi

    log "🎯 DeepSeek: trend=$trend confidence=${confidence}%"

    # Validar confianza
    if [ "$confidence" -lt "$SCALPER_MIN_CONFIDENCE" ]; then
        log "⏸️ Confianza baja (${confidence}% < ${SCALPER_MIN_CONFIDENCE}%), saltando"
        return 0
    fi
    
    # Validar que tenemos precios válidos
    if [ -z "$entry" ] || [ "$entry" = "0" ] || [ -z "$sl" ] || [ -z "$tp" ]; then
        log_error "Precios inválidos para $symbol"
        return 1
    fi
    
    # Enviar orden
    send_scalp_order "$symbol" "$trend" "$entry" "$sl" "$tp"
}

# ============================================
# FUNCIÓN PRINCIPAL DE SCALPING
# ============================================

scalp() {
    log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${BLUE}⚡ Ciclo de Scalping - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Verificar API key
    if [ -z "$DEEPSEEK_API_KEY" ]; then
        log_error "DEEPSEEK_API_KEY no configurada"
        return 1
    fi
    
    # Obtener top gainers y losers
    local gainers=$(get_top_gainers "$SCALPER_MAX_SYMBOLS")
    local losers=$(get_top_losers "$SCALPER_MAX_SYMBOLS")
    
    log "📈 Top Gainers: $(echo "$gainers" | tr '\n' ' ')"
    log "📉 Top Losers: $(echo "$losers" | tr '\n' ' ')"
    
    local symbols_processed=0
    
    # Procesar gainers (posible SHORT por reversión)
    for symbol in $gainers; do
        if [ $symbols_processed -ge $SCALPER_MAX_SYMBOLS ]; then
            break
        fi
        process_symbol "$symbol"
        symbols_processed=$((symbols_processed + 1))
        sleep 2
    done
    
    # Procesar losers (posible LONG por reversión)
    for symbol in $losers; do
        if [ $symbols_processed -ge $SCALPER_MAX_SYMBOLS ]; then
            break
        fi
        process_symbol "$symbol"
        symbols_processed=$((symbols_processed + 1))
        sleep 2
    done
    
    log "${GREEN}✅ Ciclo completado - $symbols_processed símbolos procesados${NC}"
}

# ============================================
# LOOP PRINCIPAL
# ============================================

main() {
    log "${BLUE}⚡ Servicio Scalper 1 Minuto v1.2 Iniciado${NC}"
    log "📋 Configuración: TP=${SCALPER_TP_PERCENT}% SL=${SCALPER_SL_PERCENT}% Confianza mínima=${SCALPER_MIN_CONFIDENCE}%"
    log "🔍 Modo: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "REAL")"
    
    # Enviar notificación de inicio
    if [ "$DRY_RUN" = true ]; then
        send_telegram "🔍 DRY-RUN: Scalper 1M iniciado - TP:${SCALPER_TP_PERCENT}% SL:${SCALPER_SL_PERCENT}%"
    else
        send_telegram "⚡ Scalper 1M iniciado - TP:${SCALPER_TP_PERCENT}% SL:${SCALPER_SL_PERCENT}%"
    fi
    
    # Loop infinito
    local cycle=0
    while true; do
        cycle=$((cycle + 1))
        log "${BLUE}📊 Ciclo #$cycle${NC}"
        
        scalp
        
        log "⏰ Esperando 60 segundos para próximo ciclo..."
        sleep 60
    done
}

# ============================================
# EJECUTAR
# ============================================

main "$@"