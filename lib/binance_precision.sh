#!/bin/bash
# Binance Futures price/qty rounding (tickSize / stepSize from exchangeInfo)

declare -A SYMBOL_TICK_SIZE
declare -A SYMBOL_STEP_SIZE
declare -A SYMBOL_PRICE_PRECISION
declare -A SYMBOL_QTY_PRECISION
declare -A SYMBOL_PRECISION_LOADED

_round_to_tick() {
    local value="$1"
    local tick="$2"
    local prec="${3:-8}"
    awk -v v="$value" -v t="$tick" -v p="$prec" 'BEGIN {
        if (v == "" || v == 0) { print "0"; exit }
        if (t <= 0) { printf "%.*f", p, v; exit }
        n = int((v / t) + 0.5)
        if (n < 1) n = 1
        printf "%.*f", p, n * t
    }'
}

_round_to_step_floor() {
    local value="$1"
    local step="$2"
    local prec="${3:-8}"
    awk -v v="$value" -v s="$step" -v p="$prec" 'BEGIN {
        if (v == "" || v == 0) { print "0"; exit }
        if (s <= 0) { printf "%.*f", p, v; exit }
        n = int(v / s)
        if (n < 1) n = 1
        printf "%.*f", p, n * s
    }'
}

load_symbol_precision() {
    local symbol="$1"
    [ -n "${SYMBOL_PRECISION_LOADED[$symbol]}" ] && return 0
    init_all_symbol_precision "$symbol"
}

# One API call for all configured symbols
init_all_symbol_precision() {
    local symbols=("$@")
    local exchange
    exchange=$(curl -s "https://fapi.binance.com/fapi/v1/exchangeInfo" 2>/dev/null)
    [ -z "$exchange" ] && return 1

    for symbol in "${symbols[@]}"; do
        SYMBOL_TICK_SIZE[$symbol]=$(echo "$exchange" | jq -r "
            .symbols[] | select(.symbol==\"$symbol\") |
            .filters[] | select(.filterType==\"PRICE_FILTER\") | .tickSize" 2>/dev/null | head -1)
        SYMBOL_STEP_SIZE[$symbol]=$(echo "$exchange" | jq -r "
            .symbols[] | select(.symbol==\"$symbol\") |
            .filters[] | select(.filterType==\"LOT_SIZE\") | .stepSize" 2>/dev/null | head -1)
        SYMBOL_PRICE_PRECISION[$symbol]=$(echo "$exchange" | jq -r "
            .symbols[] | select(.symbol==\"$symbol\") | .pricePrecision" 2>/dev/null | head -1)
        SYMBOL_QTY_PRECISION[$symbol]=$(echo "$exchange" | jq -r "
            .symbols[] | select(.symbol==\"$symbol\") | .quantityPrecision" 2>/dev/null | head -1)

        SYMBOL_TICK_SIZE[$symbol]="${SYMBOL_TICK_SIZE[$symbol]:-0.01}"
        SYMBOL_STEP_SIZE[$symbol]="${SYMBOL_STEP_SIZE[$symbol]:-0.001}"
        SYMBOL_PRICE_PRECISION[$symbol]="${SYMBOL_PRICE_PRECISION[$symbol]:-2}"
        SYMBOL_QTY_PRECISION[$symbol]="${SYMBOL_QTY_PRECISION[$symbol]:-3}"
        SYMBOL_PRECISION_LOADED[$symbol]=1
    done
    return 0
}

round_price_for_symbol() {
    local symbol="$1"
    local price="$2"
    [ -z "$price" ] || [ "$price" = "0" ] && echo "0" && return 0
    [ -z "${SYMBOL_PRECISION_LOADED[$symbol]}" ] && load_symbol_precision "$symbol"
    _round_to_tick "$price" "${SYMBOL_TICK_SIZE[$symbol]}" "${SYMBOL_PRICE_PRECISION[$symbol]}"
}

round_qty_for_symbol() {
    local symbol="$1"
    local qty="$2"
    [ -z "$qty" ] || [ "$qty" = "0" ] && echo "0" && return 0
    [ -z "${SYMBOL_PRECISION_LOADED[$symbol]}" ] && load_symbol_precision "$symbol"
    _round_to_step_floor "$qty" "${SYMBOL_STEP_SIZE[$symbol]}" "${SYMBOL_QTY_PRECISION[$symbol]}"
}
