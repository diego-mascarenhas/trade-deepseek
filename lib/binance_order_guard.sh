#!/bin/bash
# Binance Futures: duplicate order guard + close on opposite OB touch

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f ob_zone_touch_signal >/dev/null 2>&1; then
    # shellcheck source=lib/ob_zone_signal.sh
    source "$_LIB_DIR/ob_zone_signal.sh"
fi
if ! declare -f _bn_is_positive >/dev/null 2>&1; then
    if [ -f "$_LIB_DIR/binance_precision.sh" ]; then
        # shellcheck source=lib/binance_precision.sh
        source "$_LIB_DIR/binance_precision.sh"
    else
        _bn_is_positive() {
            awk -v v="$1" 'BEGIN { exit (v + 0 > 0) ? 0 : 1 }'
        }
    fi
fi

_binance_fapi_signed_get() {
    local path="$1"
    local extra_qs="${2:-}"

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    if ! declare -f binance_timestamp_ms >/dev/null 2>&1; then
        return 1
    fi

    local timestamp qs sig url
    timestamp=$(binance_timestamp_ms)
    qs="timestamp=${timestamp}&recvWindow=5000"
    if [ -n "$extra_qs" ]; then
        qs="${extra_qs}&${qs}"
    fi
    sig=$(echo -n "$qs" | openssl dgst -sha256 -hmac "$BINANCE_SECRET_KEY" | awk '{print $2}')
    url="https://fapi.binance.com${path}?${qs}&signature=${sig}"
    curl -s -X GET "$url" -H "X-MBX-APIKEY: $BINANCE_API_KEY" 2>/dev/null
}

_binance_fapi_signed_post() {
    local path="$1"
    local body_qs="$2"

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    if ! declare -f binance_timestamp_ms >/dev/null 2>&1; then
        return 1
    fi

    local timestamp qs sig url response
    timestamp=$(binance_timestamp_ms)
    qs="${body_qs}&timestamp=${timestamp}&recvWindow=5000"
    sig=$(echo -n "$qs" | openssl dgst -sha256 -hmac "$BINANCE_SECRET_KEY" | awk '{print $2}')
    url="https://fapi.binance.com${path}"
    response=$(curl -s -X POST "$url" \
        -H "X-MBX-APIKEY: $BINANCE_API_KEY" \
        -d "${qs}&signature=${sig}" 2>/dev/null)
    echo "$response"
}

# Echo: none | LONG|<abs_qty> | SHORT|<abs_qty>
futures_get_position() {
    local symbol="$1"
    local positions position_amt abs_amt direction

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        echo "none"
        return 0
    fi

    positions=$(_binance_fapi_signed_get "/fapi/v2/positionRisk" "symbol=${symbol}")
    # Hedge: two rows (LONG/SHORT); take first non-zero positionAmt
    position_amt=$(echo "$positions" | jq -r ".[] | select(.symbol==\"$symbol\") | .positionAmt" 2>/dev/null \
        | while read -r _amt; do
            if [ -n "$_amt" ] && [ "$_amt" != "0" ] && [ "$_amt" != "null" ]; then
                echo "$_amt"
                break
            fi
        done)
    if declare -f _bn_sanitize_num >/dev/null 2>&1; then
        position_amt=$(_bn_sanitize_num "$position_amt")
    else
        position_amt=$(echo "$position_amt" | head -1 | tr -d '[:space:]')
    fi

    if [ -z "$position_amt" ] || [ "$position_amt" = "0" ] || [ "$position_amt" = "null" ]; then
        echo "none"
        return 0
    fi

    if _bn_is_positive "$position_amt"; then
        direction="LONG"
        abs_amt="$position_amt"
    else
        direction="SHORT"
        abs_amt=$(echo "$position_amt" | tr -d '-')
    fi

    if declare -f round_qty_for_symbol >/dev/null 2>&1; then
        abs_amt=$(round_qty_for_symbol "$symbol" "$abs_amt")
    fi
    echo "${direction}|${abs_amt}"
}

futures_cancel_open_orders() {
    local symbol="$1"
    local timestamp qs sig url

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    timestamp=$(binance_timestamp_ms)
    qs="symbol=${symbol}&timestamp=${timestamp}&recvWindow=5000"
    sig=$(echo -n "$qs" | openssl dgst -sha256 -hmac "$BINANCE_SECRET_KEY" | awk '{print $2}')
    url="https://fapi.binance.com/fapi/v1/allOpenOrders?${qs}&signature=${sig}"
    curl -s -X DELETE "$url" -H "X-MBX-APIKEY: $BINANCE_API_KEY" >/dev/null 2>&1
}

# Close open LONG/SHORT with MARKET reduceOnly
futures_close_position_market() {
    local symbol="$1"
    local position_direction="$2"
    local quantity="$3"
    local log_fn="${4:-}"
    local side close_dir query_string response dry_run

    dry_run="${DRY_RUN:-false}"
    case "$(echo "$position_direction" | tr '[:lower:]' '[:upper:]')" in
        LONG) side="SELL"; close_dir="LONG" ;;
        SHORT) side="BUY"; close_dir="SHORT" ;;
        *)
            return 1
            ;;
    esac

    if [ -z "$quantity" ] || ! _bn_is_positive "$quantity"; then
        return 1
    fi

    if [ "$dry_run" = true ]; then
        [ -n "$log_fn" ] && $log_fn "🔍 DRY-RUN: Would CLOSE $close_dir $symbol qty=$quantity (opposite OB)"
        if declare -f log_trade >/dev/null 2>&1; then
            log_trade "DRY-RUN CLOSE $symbol $close_dir qty=$quantity reason=opposite_ob mode=REST"
        fi
        return 0
    fi

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        [ -n "$log_fn" ] && $log_fn "❌ Cannot close $symbol: API keys missing"
        return 1
    fi

    futures_cancel_open_orders "$symbol"

    query_string="symbol=${symbol}&side=${side}&type=MARKET&quantity=${quantity}&reduceOnly=true"
    if declare -f append_position_side_param >/dev/null 2>&1; then
        query_string=$(append_position_side_param "$close_dir" "$query_string")
    fi

    response=$(_binance_fapi_signed_post "/fapi/v1/order" "$query_string")

    if echo "$response" | jq -e '.orderId' >/dev/null 2>&1; then
        [ -n "$log_fn" ] && $log_fn "✅ Closed $close_dir position on $symbol (qty $quantity) — opposite OB touch"
        if declare -f log_trade >/dev/null 2>&1; then
            log_trade "CLOSE $symbol $close_dir qty=$quantity reason=opposite_ob mode=REST status=ok"
        fi
        if declare -f ob_set >/dev/null 2>&1; then
            ob_set ACTIVE "$symbol" "false"
            ob_set POS_DIR "$symbol" ""
            ob_set LAST_ENTRY "$symbol" ""
        fi
        if declare -f send_telegram >/dev/null 2>&1; then
            send_telegram "🔒 CLOSE $symbol $close_dir — opposite order book (qty $quantity)"
        fi
        return 0
    fi

    [ -n "$log_fn" ] && $log_fn "❌ Close failed $symbol: $response"
    if declare -f log_trade >/dev/null 2>&1; then
        log_trade "FAILED CLOSE $symbol $close_dir qty=$quantity reason=opposite_ob response=$(echo "$response" | tr -d '\n')"
    fi
    if declare -f log_error >/dev/null 2>&1; then
        log_error "Close failed $symbol: $response"
    fi
    return 1
}

# Return 0 if close was triggered (or dry-run); 1 if nothing to do
try_close_on_opposite_ob() {
    local symbol="$1"
    local current_price="$2"
    local upper_pct="${3:-75}"
    local lower_pct="${4:-25}"
    local log_fn="${5:-}"

    local close_flag="${OB_CLOSE_ON_OPPOSITE:-${SCALPER_OB_CLOSE_OPPOSITE:-true}}"
    case "$(echo "$close_flag" | tr '[:upper:]' '[:lower:]')" in
        false|0|no|off) return 1 ;;
    esac

    local pos_info pos_dir pos_qty ob_zone
    pos_info=$(futures_get_position "$symbol")
    if [ "$pos_info" = "none" ]; then
        return 1
    fi

    pos_dir=$(echo "$pos_info" | cut -d'|' -f1)
    pos_qty=$(echo "$pos_info" | cut -d'|' -f2)
    ob_zone=$(ob_zone_touch_signal "$symbol" "$current_price" "$upper_pct" "$lower_pct")

    if [ "$pos_dir" = "LONG" ] && [ "$ob_zone" = "SHORT" ]; then
        [ -n "$log_fn" ] && $log_fn "🔄 $symbol: LONG open + price at resistance OB — closing"
        futures_close_position_market "$symbol" "LONG" "$pos_qty" "$log_fn"
        return 0
    fi

    if [ "$pos_dir" = "SHORT" ] && [ "$ob_zone" = "LONG" ]; then
        [ -n "$log_fn" ] && $log_fn "🔄 $symbol: SHORT open + price at support OB — closing"
        futures_close_position_market "$symbol" "SHORT" "$pos_qty" "$log_fn"
        return 0
    fi

    return 1
}

# Returns 0 if futures position size != 0 for symbol
futures_has_open_position() {
    local symbol="$1"
    local positions position_amt

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi

    positions=$(_binance_fapi_signed_get "/fapi/v2/positionRisk" "symbol=${symbol}")
    position_amt=$(echo "$positions" | jq -r ".[] | select(.symbol==\"$symbol\") | .positionAmt" 2>/dev/null \
        | while read -r _amt; do
            if [ -n "$_amt" ] && [ "$_amt" != "0" ] && [ "$_amt" != "null" ]; then
                echo "$_amt"
                break
            fi
        done)
    if declare -f _bn_sanitize_num >/dev/null 2>&1; then
        position_amt=$(_bn_sanitize_num "$position_amt")
    fi

    if [ -n "$position_amt" ] && [ "$position_amt" != "0" ] && [ "$position_amt" != "null" ]; then
        return 0
    fi
    return 1
}

# Returns 0 if any open LIMIT exists for this symbol + direction (any price)
futures_has_open_limit_same_side() {
    local symbol="$1"
    local direction="$2"
    local side want_pos_side pos_side oside

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi

    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        LONG) side="BUY"; want_pos_side="LONG" ;;
        SHORT) side="SELL"; want_pos_side="SHORT" ;;
        *) return 1 ;;
    esac

    local orders count
    orders=$(_binance_fapi_signed_get "/fapi/v1/openOrders" "symbol=${symbol}")
    [ -z "$orders" ] && return 1
    echo "$orders" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1

    count=$(echo "$orders" | jq -r --arg side "$side" --arg ps "$want_pos_side" '
        [.[] | select(.type == "LIMIT" or .type == "LIMIT_MAKER")
         | select(.side == $side)
         | select(
             ($ps == "LONG" or $ps == "SHORT") as $hedge |
             if $hedge then (.positionSide // "") == $ps or (.positionSide // "") == "" else true end
           )
        ] | length' 2>/dev/null)

    if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
        return 0
    fi
    return 1
}

# Returns 0 if an open LIMIT order exists at the same price and side
futures_has_limit_at_price() {
    local symbol="$1"
    local direction="$2"
    local entry="$3"
    local side pos_side want_pos_side oside oprice rounded

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi
    if ! declare -f round_price_for_symbol >/dev/null 2>&1; then
        return 1
    fi

    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        LONG) side="BUY"; want_pos_side="LONG" ;;
        SHORT) side="SELL"; want_pos_side="SHORT" ;;
        *) return 1 ;;
    esac

    entry=$(round_price_for_symbol "$symbol" "$entry")
    [ -z "$entry" ] || [ "$entry" = "0" ] && return 1

    local orders
    orders=$(_binance_fapi_signed_get "/fapi/v1/openOrders" "symbol=${symbol}")
    [ -z "$orders" ] && return 1
    echo "$orders" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        oside=$(echo "$line" | cut -d'|' -f1)
        oprice=$(echo "$line" | cut -d'|' -f2)
        pos_side=$(echo "$line" | cut -d'|' -f3)
        [ "$oside" != "$side" ] && continue
        if [ "${BINANCE_HEDGE_MODE:-false}" = true ] && [ -n "$pos_side" ] && [ "$pos_side" != "$want_pos_side" ]; then
            continue
        fi
        rounded=$(round_price_for_symbol "$symbol" "$oprice")
        if [ "$rounded" = "$entry" ]; then
            return 0
        fi
    done < <(echo "$orders" | jq -r '
        .[] | select(.type == "LIMIT" or .type == "LIMIT_MAKER")
        | "\(.side)|\(.price)|\(.positionSide // "")"' 2>/dev/null)

    return 1
}

# return 0 = allowed to place | return 1 = blocked (skip)
can_place_new_order() {
    local symbol="$1"
    local direction="$2"
    local entry="$3"
    local log_fn="${4:-}"

    # Local memory fallback (no API keys)
    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        if declare -f ob_get >/dev/null 2>&1 && [ "$(ob_get ACTIVE "$symbol")" = "true" ]; then
            [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: position flagged active locally — skipping order"
            return 1
        fi
        return 0
    fi

    if futures_has_open_position "$symbol"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: open position on Binance — skipping order"
        return 1
    fi

    if futures_has_open_limit_same_side "$symbol" "$direction"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: pending $direction limit already on book — skipping order"
        return 1
    fi

    if futures_has_limit_at_price "$symbol" "$direction" "$entry"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: limit order already exists at $entry ($direction) — skipping"
        return 1
    fi

    return 0
}
