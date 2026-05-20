#!/bin/bash

# ============================================
# Crypto Scalper 1 Minuto v1.4
# - Soporta modo dry-run
# - Señales locales: aggTrades (ticks), order book y klines (sin IA)
# - Loop continuo (SCALPER_LOOP_SECONDS, default 2s)
# - Nombre de orden: "Scalper vX.Y.Z"
# ============================================

BOT_VERSION="v1.4"

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
SCALPER_TICK_LIMIT="${SCALPER_TICK_LIMIT:-1000}"
SCALPER_TICK_WINDOW_SECONDS="${SCALPER_TICK_WINDOW_SECONDS:-30}"
SCALPER_LOOP_SECONDS="${SCALPER_LOOP_SECONDS:-2}"
SCALPER_SYMBOL_DELAY="${SCALPER_SYMBOL_DELAY:-0.3}"
SCALPER_WATCHLIST_REFRESH_SECONDS="${SCALPER_WATCHLIST_REFRESH_SECONDS:-300}"
SCALPER_OB_REFRESH_SECONDS="${SCALPER_OB_REFRESH_SECONDS:-5}"
SCALPER_KLINE_REFRESH_SECONDS="${SCALPER_KLINE_REFRESH_SECONDS:-60}"
SCALPER_TICKER_REFRESH_SECONDS="${SCALPER_TICKER_REFRESH_SECONDS:-60}"
SCALPER_SYMBOL_COOLDOWN_SECONDS="${SCALPER_SYMBOL_COOLDOWN_SECONDS:-120}"
SCALPER_VERBOSE="${SCALPER_VERBOSE:-false}"
SCALPER_OB_IMBALANCE="${SCALPER_OB_IMBALANCE:-1.2}"
SCALPER_TICK_RATIO="${SCALPER_TICK_RATIO:-1.15}"
SCALPER_NEAR_ZONE_PERCENT="${SCALPER_NEAR_ZONE_PERCENT:-0.15}"
SCALPER_ENTRY_OFFSET_PERCENT="${SCALPER_ENTRY_OFFSET_PERCENT:-0.1}"
SCALPER_TICK_DELTA_PERCENT="${SCALPER_TICK_DELTA_PERCENT:-0.05}"
SCALPER_WATCHLIST_MODE="${SCALPER_WATCHLIST_MODE:-gainers_losers}"
SCALPER_MIN_VOLATILITY_PERCENT="${SCALPER_MIN_VOLATILITY_PERCENT:-2}"
SCALPER_SYMBOLS="${SCALPER_SYMBOLS:-}"
SCALPER_VOLATILE_THRESHOLD="${SCALPER_VOLATILE_THRESHOLD:-15}"
SCALPER_SL_VOLATILE_MIN="${SCALPER_SL_VOLATILE_MIN:-0.8}"
SCALPER_TP_VOLATILE_MIN="${SCALPER_TP_VOLATILE_MIN:-1.0}"
SCALPER_MIN_SL_SPREAD_MULT="${SCALPER_MIN_SL_SPREAD_MULT:-3}"

# ============================================
# DIRECTORIOS
# ============================================

LOG_DIR="$SCRIPT_DIR/logs"
CACHE_DIR="$LOG_DIR/cache"
mkdir -p "$LOG_DIR" "$CACHE_DIR"

WATCHLIST=""
WATCHLIST_UPDATED_AT=0

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

cache_path() {
    echo "$CACHE_DIR/$1"
}

cache_read() {
    local file
    file=$(cache_path "$1")
    [ -f "$file" ] && cat "$file"
}

cache_write() {
    echo "$2" > "$(cache_path "$1")"
}

cache_is_fresh() {
    local key="$1"
    local max_age="$2"
    local ts_file
    ts_file=$(cache_path "${key}.ts")
    [ -f "$ts_file" ] || return 1
    local now ts
    now=$(date +%s)
    ts=$(cat "$ts_file")
    [ $((now - ts)) -lt "$max_age" ]
}

cache_touch() {
    date +%s > "$(cache_path "$1.ts")"
}

can_send_order() {
    local symbol="$1"
    local cooldown_file
    cooldown_file=$(cache_path "${symbol}_last_order.ts")
    [ ! -f "$cooldown_file" ] && return 0
    local now last
    now=$(date +%s)
    last=$(cat "$cooldown_file")
    [ $((now - last)) -ge "$SCALPER_SYMBOL_COOLDOWN_SECONDS" ]
}

mark_order_sent() {
    date +%s > "$(cache_path "${1}_last_order.ts")"
}

send_telegram() {
    local message="$1"
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        return 1
    fi
    
    local payload=$(jq -n \
        --arg chat_id "$TELEGRAM_CHAT_ID" \
        --arg text "$message" \
        '{chat_id: $chat_id, text: $text}')
    
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null
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
        return 1
    fi

    echo "$order_book" | jq -c '{
        support: (.bids[0][0] | tonumber),
        resistance: (.asks[0][0] | tonumber),
        bid_vol: ([.bids[:5][] | .[1] | tonumber] | add // 0),
        ask_vol: ([.asks[:5][] | .[1] | tonumber] | add // 0),
        bid_wall: (([.bids[]] | max_by(.[1] | tonumber)) | .[0] | tonumber),
        ask_wall: (([.asks[]] | max_by(.[1] | tonumber)) | .[0] | tonumber),
        bid_wall_vol: (([.bids[]] | max_by(.[1] | tonumber)) | .[1] | tonumber),
        ask_wall_vol: (([.asks[]] | max_by(.[1] | tonumber)) | .[1] | tonumber)
    }'
}

get_agg_tick_flow() {
    local symbol="$1"
    local now_ms since_ms last_id
    now_ms=$(($(date +%s) * 1000))
    since_ms=$((now_ms - SCALPER_TICK_WINDOW_SECONDS * 1000))
    last_id=$(cache_read "${symbol}_last_agg_id")
    last_id="${last_id:-0}"

    local raw
    raw=$(curl -s "https://api.binance.com/api/v3/aggTrades?symbol=${symbol}&limit=${SCALPER_TICK_LIMIT}")

    local result
    result=$(echo "$raw" | jq -c --argjson since "$since_ms" --argjson last_id "$last_id" '
        [.[] | select(.T >= $since and (.a | tonumber) > $last_id)] as $recent |
        {
            buy_vol: ([$recent[] | select(.m == false) | .q | tonumber] | add // 0),
            sell_vol: ([$recent[] | select(.m == true) | .q | tonumber] | add // 0),
            ticks: ($recent | length),
            last_id: (if ($recent | length) > 0 then ($recent[-1].a | tonumber) else $last_id end),
            last_price: (if ($recent | length) > 0 then ($recent[-1].p | tonumber) else null end),
            delta_pct: (
                if ($recent | length) >= 2 then
                    ((($recent[-1].p | tonumber) - ($recent[0].p | tonumber)) / ($recent[0].p | tonumber) * 100)
                else 0 end
            ),
            buy_ticks: ([$recent[] | select(.m == false)] | length),
            sell_ticks: ([$recent[] | select(.m == true)] | length)
        }
    ')

    local new_last_id
    new_last_id=$(echo "$result" | jq -r '.last_id // 0')
    if [ -n "$new_last_id" ] && [ "$new_last_id" != "0" ]; then
        cache_write "${symbol}_last_agg_id" "$new_last_id"
    fi

    echo "$result"
}

get_cached_order_book() {
    local symbol="$1"
    local cache_key="${symbol}_ob"
    if cache_is_fresh "$cache_key" "$SCALPER_OB_REFRESH_SECONDS"; then
        cache_read "$cache_key"
        return 0
    fi
    local ob_json
    if ! ob_json=$(analyze_order_book "$symbol"); then
        return 1
    fi
    cache_write "$cache_key" "$ob_json"
    cache_touch "$cache_key"
    echo "$ob_json"
}

get_cached_klines() {
    local symbol="$1"
    local cache_key="${symbol}_klines"
    if cache_is_fresh "$cache_key" "$SCALPER_KLINE_REFRESH_SECONDS"; then
        cache_read "$cache_key"
        return 0
    fi
    local klines_json
    klines_json=$(get_klines_momentum "$symbol")
    cache_write "$cache_key" "$klines_json"
    cache_touch "$cache_key"
    echo "$klines_json"
}

get_cached_change_24h() {
    local symbol="$1"
    local cache_key="${symbol}_ticker24"
    if cache_is_fresh "$cache_key" "$SCALPER_TICKER_REFRESH_SECONDS"; then
        cache_read "$cache_key"
        return 0
    fi
    local change
    change=$(get_24h_ticker "$symbol" | jq -r '.priceChangePercent // 0')
    cache_write "$cache_key" "$change"
    cache_touch "$cache_key"
    echo "$change"
}

get_klines_momentum() {
    local symbol="$1"
    curl -s "https://api.binance.com/api/v3/klines?symbol=${symbol}&interval=${SCALPER_INTERVAL}&limit=5" | jq -c '{
        bullish: ([.[-3:][] | (.[4] | tonumber) > (.[1] | tonumber)] | all),
        bearish: ([.[-3:][] | (.[4] | tonumber) < (.[1] | tonumber)] | all)
    }'
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

# Aproxima la pestaña "Volatile" de Binance (no hay endpoint público oficial).
# Ordena por |cambio 24h| con liquidez mínima; opcional refino 15m (SCALPER_VOLATILE_USE_15M).
get_top_volatile() {
    local limit="${1:-$SCALPER_MAX_SYMBOLS}"
    local response
    response=$(curl -s "https://api.binance.com/api/v3/ticker/24hr")

    local candidates
    candidates=$(echo "$response" | jq -r --argjson min_count "$SCALPER_MIN_TRADE_COUNT" \
        --argjson min_vol "$SCALPER_MIN_QUOTE_VOLUME" \
        --argjson min_abs "$SCALPER_MIN_VOLATILITY_PERCENT" \
        --argjson pool "$((limit * 4))" '
        [.[] |
        select(.symbol | endswith("USDT")) |
        select(.symbol | test("^[A-Z0-9]+USDT$")) |
        select(.count | tonumber >= $min_count) |
        select(.quoteVolume | tonumber >= $min_vol) |
        {symbol: .symbol, abs_change: (.priceChangePercent | tonumber | fabs), quoteVolume: (.quoteVolume | tonumber)} |
        select(.abs_change >= $min_abs)] |
        sort_by(-.abs_change) |
        .[:$pool] |
        .[].symbol
    ')

    if [ "${SCALPER_VOLATILE_USE_15M:-false}" != "true" ]; then
        echo "$candidates" | head -"$limit"
        return 0
    fi

    local ranked=""
    local symbol change_15m
    for symbol in $candidates; do
        change_15m=$(curl -s "https://api.binance.com/api/v3/klines?symbol=${symbol}&interval=15m&limit=2" | jq -r '
            if length < 1 then 0 else
            ((.[0][4] | tonumber) - (.[0][1] | tonumber)) / (.[0][1] | tonumber) * 100 | fabs
            end
        ')
        ranked="${ranked}${change_15m} ${symbol}"$'\n'
    done

    echo "$ranked" | sort -rn | head -"$limit" | awk '{print $2}'
}

build_watchlist() {
    local limit="${1:-$SCALPER_MAX_SYMBOLS}"

    case "$SCALPER_WATCHLIST_MODE" in
        volatile)
            get_top_volatile "$limit"
            ;;
        manual)
            if [ -z "$SCALPER_SYMBOLS" ]; then
                log_error "SCALPER_WATCHLIST_MODE=manual requiere SCALPER_SYMBOLS (ej: BTCUSDT,ETHUSDT)"
                return 1
            fi
            echo "$SCALPER_SYMBOLS" | tr ',' ' ' | tr -s ' '
            ;;
        gainers_losers|*)
            local gainers losers merged
            gainers=$(get_top_gainers "$limit")
            losers=$(get_top_losers "$limit")
            printf '%s\n%s' "$gainers" "$losers" | awk 'NF && !seen[$0]++' | head -"$limit"
            ;;
    esac
}

# ============================================
# SEÑAL LOCAL (liquidez OB + ticks + klines)
# ============================================

analyze_signal_local() {
    local symbol="$1"
    local price="$2"
    local change_24h="$3"
    local ob_json="$4"
    local ticks_json="$5"
    local klines_json="$6"

    echo "$ob_json" "$ticks_json" "$klines_json" | jq -s --arg symbol "$symbol" \
        --argjson price "$price" \
        --argjson change_24h "$change_24h" \
        --argjson ob_imbalance "$SCALPER_OB_IMBALANCE" \
        --argjson tick_ratio "$SCALPER_TICK_RATIO" \
        --argjson near_zone "$SCALPER_NEAR_ZONE_PERCENT" \
        --argjson entry_offset "$SCALPER_ENTRY_OFFSET_PERCENT" \
        --argjson sl_pct "$SCALPER_SL_PERCENT" \
        --argjson tp_pct_base "$SCALPER_TP_PERCENT" \
        --argjson volatile_thresh "$SCALPER_VOLATILE_THRESHOLD" \
        --argjson sl_volatile_min "$SCALPER_SL_VOLATILE_MIN" \
        --argjson tp_volatile_min "$SCALPER_TP_VOLATILE_MIN" \
        --argjson min_sl_spread_mult "$SCALPER_MIN_SL_SPREAD_MULT" \
        --argjson tick_delta_min "$SCALPER_TICK_DELTA_PERCENT" \
        '
        .[0] as $ob | .[1] as $ticks | .[2] as $klines |
        ($ob.support) as $support |
        ($ob.resistance) as $resistance |
        ($ob.bid_vol) as $bid_vol |
        ($ob.ask_vol) as $ask_vol |
        (if $ob.ask_vol > 0 then $ob.bid_vol / $ob.ask_vol else 0 end) as $book_ratio |
        (if $ticks.sell_vol > 0 then $ticks.buy_vol / $ticks.sell_vol else 0 end) as $flow_ratio |
        ($ticks.ticks // 0) as $tick_count |
        ($ticks.delta_pct // 0) as $delta_pct |
        ((($price - $support) / $price * 100) | fabs) as $dist_support_pct |
        ((($resistance - $price) / $price * 100) | fabs) as $dist_resist_pct |
        ((($resistance - $support) / $price * 100)) as $spread_pct |
        (($change_24h | tonumber) | fabs) as $abs24h |
        (if $abs24h >= $volatile_thresh then (if $sl_pct < $sl_volatile_min then $sl_volatile_min else $sl_pct end) else $sl_pct end) as $sl_base |
        (if $abs24h >= $volatile_thresh then (if $tp_pct_base < $tp_volatile_min then $tp_volatile_min else $tp_pct_base end) else $tp_pct_base end) as $tp_base |
        (if ($spread_pct * $min_sl_spread_mult) > $sl_base then ($spread_pct * $min_sl_spread_mult) else $sl_base end) as $eff_sl_pct |
        $tp_base as $eff_tp_pct |
        (if $book_ratio >= $ob_imbalance and $dist_support_pct <= $near_zone then "LONG"
         elif (if $ob.ask_vol > 0 then $ob.ask_vol / $ob.bid_vol else 0 end) >= $ob_imbalance and $dist_resist_pct <= $near_zone then "SHORT"
         else "NEUTRAL" end) as $base_trend |
        (if $tick_count < 3 then 0
         elif $base_trend == "LONG" and $flow_ratio >= $tick_ratio and $delta_pct >= $tick_delta_min then 30
         elif $base_trend == "SHORT" and (if $ticks.buy_vol > 0 then $ticks.sell_vol / $ticks.buy_vol else 0 end) >= $tick_ratio and $delta_pct <= (-$tick_delta_min) then 30
         elif $flow_ratio >= $tick_ratio then 15
         elif (if $ticks.buy_vol > 0 then $ticks.sell_vol / $ticks.buy_vol else 0 end) >= $tick_ratio then 15
         else 0 end) as $tick_score |
        (if $base_trend == "LONG" and $klines.bullish then 15
         elif $base_trend == "SHORT" and $klines.bearish then 15
         else 0 end) as $kline_score |
        (if $base_trend == "LONG" and ($change_24h | tonumber) < -3 then 15
         elif $base_trend == "SHORT" and ($change_24h | tonumber) > 3 then 15
         else 0 end) as $reversal_score |
        (if $base_trend == "LONG" then
            (if $book_ratio >= 1.5 then 25 elif $book_ratio >= $ob_imbalance then 15 else 10 end)
         elif $base_trend == "SHORT" then
            (if ($ob.ask_vol / ($ob.bid_vol + 0.0000001)) >= 1.5 then 25 elif ($ob.ask_vol / ($ob.bid_vol + 0.0000001)) >= $ob_imbalance then 15 else 10 end)
         else 0 end) as $book_score |
        (if $spread_pct > 0.5 then -20 else 0 end) as $spread_penalty |
        ([$book_score, $tick_score, $kline_score, $reversal_score, $spread_penalty] | add) as $raw_confidence |
        (if $raw_confidence < 0 then 0 elif $raw_confidence > 100 then 100 else $raw_confidence end) as $confidence |
        (if $tick_count < 3 then "NEUTRAL"
         elif $base_trend == "NEUTRAL" or $confidence < 50 then "NEUTRAL"
         elif $base_trend == "LONG" and ($flow_ratio < 1 or $delta_pct < 0 or ($klines.bearish and ($change_24h | tonumber) > 3)) then "NEUTRAL"
         elif $base_trend == "SHORT" and ((if $ticks.buy_vol > 0 then $ticks.sell_vol / $ticks.buy_vol else 0 end) < 1 or $delta_pct > 0 or ($klines.bullish and ($change_24h | tonumber) < -3)) then "NEUTRAL"
         else $base_trend end) as $trend |
        (if $trend == "LONG" then ($price * (1 + $entry_offset / 100))
         elif $trend == "SHORT" then ($price * (1 - $entry_offset / 100))
         else 0 end) as $entry |
        (if $trend == "LONG" then ($entry * (1 - $eff_sl_pct / 100))
         elif $trend == "SHORT" then ($entry * (1 + $eff_sl_pct / 100))
         else 0 end) as $sl |
        (if $trend == "LONG" then ($entry * (1 + $eff_tp_pct / 100))
         elif $trend == "SHORT" then ($entry * (1 - $eff_tp_pct / 100))
         else 0 end) as $tp |
        {
            trend: $trend,
            confidence: (if $trend == "NEUTRAL" then 0 else $confidence end),
            entry_price: $entry,
            stop_loss: $sl,
            tp_price: $tp,
            meta: {
                book_ratio: $book_ratio,
                flow_ratio: $flow_ratio,
                tick_count: $tick_count,
                delta_pct: $delta_pct,
                dist_support_pct: $dist_support_pct,
                dist_resist_pct: $dist_resist_pct,
                bid_wall: $ob.bid_wall,
                ask_wall: $ob.ask_wall,
                spread_pct: $spread_pct,
                sl_pct: $eff_sl_pct,
                tp_pct: $eff_tp_pct,
                abs_change_24h: $abs24h
            }
        }
        '
}

format_price() {
    local price="$1"
    if awk "BEGIN {exit !($price >= 1)}"; then
        printf "%.4f" "$price"
    elif awk "BEGIN {exit !($price >= 0.01)}"; then
        printf "%.5f" "$price"
    else
        printf "%.8f" "$price"
    fi
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
    
    local order_name="Scalper ${BOT_VERSION}"
    
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

refresh_watchlist() {
    local now
    now=$(date +%s)
    if [ -n "$WATCHLIST" ] && [ $((now - WATCHLIST_UPDATED_AT)) -lt "$SCALPER_WATCHLIST_REFRESH_SECONDS" ]; then
        return 0
    fi

    local symbols
    symbols=$(build_watchlist "$SCALPER_MAX_SYMBOLS") || return 1
    WATCHLIST=$(echo "$symbols" | tr '\n' ' ' | xargs)
    WATCHLIST_UPDATED_AT=$now
    log "📋 Watchlist [${SCALPER_WATCHLIST_MODE}]: $WATCHLIST"
}

process_symbol() {
    local symbol="$1"

    local ticks_json
    ticks_json=$(get_agg_tick_flow "$symbol")
    local tick_count
    tick_count=$(echo "$ticks_json" | jq -r '.ticks // 0')

    local current_price
    current_price=$(echo "$ticks_json" | jq -r '.last_price // empty')
    if [ -z "$current_price" ] || [ "$current_price" = "null" ]; then
        current_price=$(get_current_price "$symbol")
    fi
    if [ -z "$current_price" ] || [ "$current_price" = "0" ]; then
        log_error "No se pudo obtener precio para $symbol"
        return 1
    fi

    local change_24h
    change_24h=$(get_cached_change_24h "$symbol")

    local ob_json
    if ! ob_json=$(get_cached_order_book "$symbol"); then
        [ "$SCALPER_VERBOSE" = "true" ] && log "⏭️ $symbol sin order book activo"
        return 0
    fi

    local support resistance
    support=$(echo "$ob_json" | jq -r '.support // empty')
    resistance=$(echo "$ob_json" | jq -r '.resistance // empty')
    if [ -z "$support" ] || [ -z "$resistance" ]; then
        [ "$SCALPER_VERBOSE" = "true" ] && log "⏭️ $symbol sin niveles OB válidos"
        return 0
    fi

    local klines_json
    klines_json=$(get_cached_klines "$symbol")

    if [ "$SCALPER_VERBOSE" = "true" ]; then
        log "${YELLOW}🔍 $symbol${NC} | $current_price | 24h:${change_24h}% | ticks:${tick_count} ($(echo "$ticks_json" | jq -r '.buy_vol')/$(echo "$ticks_json" | jq -r '.sell_vol')) Δ$(echo "$ticks_json" | jq -r '.delta_pct')%"
    fi

    local analysis
    analysis=$(analyze_signal_local "$symbol" "$current_price" "$change_24h" "$ob_json" "$ticks_json" "$klines_json")
    local trend=$(echo "$analysis" | jq -r '.trend // "NEUTRAL"' 2>/dev/null)
    local confidence=$(echo "$analysis" | jq -r '.confidence // 0' 2>/dev/null)
    local entry=$(echo "$analysis" | jq -r '.entry_price // 0' 2>/dev/null)
    local sl=$(echo "$analysis" | jq -r '.stop_loss // 0' 2>/dev/null)
    local tp=$(echo "$analysis" | jq -r '.tp_price // 0' 2>/dev/null)

    confidence="${confidence:-0}"
    if ! [[ "$confidence" =~ ^[0-9]+$ ]]; then
        confidence=0
    fi

    if [ "$trend" = "NEUTRAL" ] || [ "$confidence" -lt "$SCALPER_MIN_CONFIDENCE" ]; then
        [ "$SCALPER_VERBOSE" = "true" ] && log "⏸️ $symbol NEUTRAL conf=${confidence}% ticks=${tick_count}"
        return 0
    fi

    entry=$(format_price "$entry")
    sl=$(format_price "$sl")
    tp=$(format_price "$tp")

    log "🎯 $symbol $trend conf=${confidence}% | ticks=${tick_count} | entry=${entry} SL=${sl} ($(echo "$analysis" | jq -r '.meta.sl_pct')% vol24h=$(echo "$analysis" | jq -r '.meta.abs_change_24h')%) TP=${tp}"

    if [ -z "$entry" ] || [ "$entry" = "0" ] || [ -z "$sl" ] || [ -z "$tp" ]; then
        log_error "Precios inválidos para $symbol"
        return 1
    fi

    if ! can_send_order "$symbol"; then
        log "⏳ $symbol en cooldown (${SCALPER_SYMBOL_COOLDOWN_SECONDS}s), señal ignorada"
        return 0
    fi

    send_scalp_order "$symbol" "$trend" "$entry" "$sl" "$tp"
    mark_order_sent "$symbol"
}

# ============================================
# FUNCIÓN PRINCIPAL DE SCALPING
# ============================================

scalp_cycle() {
    refresh_watchlist

    if [ -z "$WATCHLIST" ]; then
        log "⚠️ Watchlist vacía, reintentando en ${SCALPER_LOOP_SECONDS}s"
        return 0
    fi

    for symbol in $WATCHLIST; do
        process_symbol "$symbol"
        sleep "$SCALPER_SYMBOL_DELAY"
    done
}

# ============================================
# LOOP PRINCIPAL
# ============================================

main() {
    log "${BLUE}⚡ Scalper ${BOT_VERSION} — loop continuo cada ${SCALPER_LOOP_SECONDS}s${NC}"
    log "📋 TP=${SCALPER_TP_PERCENT}% SL=${SCALPER_SL_PERCENT}% | ticks=${SCALPER_TICK_WINDOW_SECONDS}s | watchlist=${SCALPER_WATCHLIST_MODE}"
    log "🔍 Modo: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "REAL") | Verbose: $SCALPER_VERBOSE"

    if [ "$DRY_RUN" = true ]; then
        send_telegram "🔍 DRY-RUN Scalper ${BOT_VERSION} loop ${SCALPER_LOOP_SECONDS}s ticks ${SCALPER_TICK_WINDOW_SECONDS}s"
    else
        send_telegram "⚡ Scalper ${BOT_VERSION} loop ${SCALPER_LOOP_SECONDS}s"
    fi

    local cycle=0
    while true; do
        cycle=$((cycle + 1))
        [ "$SCALPER_VERBOSE" = "true" ] && log "${BLUE}── Ciclo #$cycle ──${NC}"
        scalp_cycle
        sleep "$SCALPER_LOOP_SECONDS"
    done
}

# ============================================
# EJECUTAR
# ============================================

main "$@"