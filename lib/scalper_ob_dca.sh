#!/bin/bash
# OB-based DCA grid for scalper_websocket (5 levels; level 4 = SL price)

_LIB_DCA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f _bn_is_positive >/dev/null 2>&1; then
    if [ -f "$_LIB_DCA_DIR/binance_precision.sh" ]; then
        # shellcheck source=lib/binance_precision.sh
        source "$_LIB_DCA_DIR/binance_precision.sh"
    fi
fi

_dca_bc_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 > b + 0) ? 0 : 1 }'
}

# Echo: L1|L2|L3|SL_L4|L5 (limit prices; L4 is stop trigger, not a buy)
# LONG: L1 > L2 > L3 > L5 > L4(SL)   |   SHORT: L1 < L2 < L3 < L5 < L4(SL)
calculate_ob_dca_grid() {
    local direction="$1"
    local anchor="$2"
    local support="$3"
    local resistance="$4"

    local min_pct="${SCALPER_DCA_MIN_DISTANCE_PCT:-0.15}"
    local sl_level="${SCALPER_DCA_SL_LEVEL:-4}"

    if [ -z "$anchor" ] || ! _dca_bc_gt "$anchor" "0"; then
        echo "||||"
        return 1
    fi

    local range step min_step ob_step
    range=$(echo "$resistance - $support" | bc -l 2>/dev/null)
    min_step=$(echo "scale=12; $anchor * $min_pct / 100" | bc -l 2>/dev/null)
    ob_step="0"
    if [ -n "$range" ] && _dca_bc_gt "$range" "0"; then
        ob_step=$(echo "scale=12; $range / 5" | bc -l 2>/dev/null)
    fi
    step="$min_step"
    if [ -n "$ob_step" ] && _dca_bc_gt "$ob_step" "$min_step"; then
        step="$ob_step"
    fi
    if [ -z "$step" ] || ! _dca_bc_gt "$step" "0"; then
        step=$(echo "scale=12; $anchor * 0.001" | bc -l 2>/dev/null)
    fi

    local l1 l2 l3 l4 l5
    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        LONG)
            l1="$anchor"
            l2=$(echo "scale=12; $l1 - $step" | bc -l)
            l3=$(echo "scale=12; $l2 - $step" | bc -l)
            l5=$(echo "scale=12; $l3 - $step" | bc -l)
            l4=$(echo "scale=12; $l5 - $step" | bc -l)
            ;;
        SHORT)
            l1="$anchor"
            l2=$(echo "scale=12; $l1 + $step" | bc -l)
            l3=$(echo "scale=12; $l2 + $step" | bc -l)
            l5=$(echo "scale=12; $l3 + $step" | bc -l)
            l4=$(echo "scale=12; $l5 + $step" | bc -l)
            ;;
        *)
            echo "||||"
            return 1
            ;;
    esac

    local sym="${5:-}"
    if declare -f round_price_for_symbol >/dev/null 2>&1 && [ -n "$sym" ]; then
        l1=$(round_price_for_symbol "$sym" "$l1")
        l2=$(round_price_for_symbol "$sym" "$l2")
        l3=$(round_price_for_symbol "$sym" "$l3")
        l4=$(round_price_for_symbol "$sym" "$l4")
        l5=$(round_price_for_symbol "$sym" "$l5")
    fi

    echo "${l1}|${l2}|${l3}|${l4}|${l5}"
    return 0
}

# return 0 = allowed to open new DCA grid | 1 = blocked
can_place_dca_grid() {
    local symbol="$1"
    local log_fn="${2:-}"

    if declare -f futures_has_open_position >/dev/null 2>&1 && futures_has_open_position "$symbol"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: open position — skip new DCA grid"
        return 1
    fi
    if scalper_dca_grid_active "$symbol"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: DCA grid already on book — skipping"
        return 1
    fi
    return 0
}

# return 0 = grid already active for symbol
scalper_dca_grid_active() {
    local symbol="$1"
    if ! declare -f ob_get >/dev/null 2>&1; then
        return 1
    fi
    [ "$(ob_get DCA_ACTIVE "$symbol")" = "true" ] && return 0
    return 1
}

# Place one LIMIT via FAPI (requires _binance_fapi_signed_post from binance_order_guard)
futures_place_limit_order() {
    local symbol="$1"
    local direction="$2"
    local price="$3"
    local quantity="$4"
    local log_fn="${5:-}"
    local label="${6:-}"

    if ! declare -f _binance_fapi_signed_post >/dev/null 2>&1; then
        return 1
    fi

    local side dry_run query_string response
    dry_run="${DRY_RUN:-false}"
    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        LONG) side="BUY" ;;
        SHORT) side="SELL" ;;
        *) return 1 ;;
    esac

    if declare -f round_price_for_symbol >/dev/null 2>&1; then
        price=$(round_price_for_symbol "$symbol" "$price")
        quantity=$(round_qty_for_symbol "$symbol" "$quantity")
    fi

    if [ -z "$price" ] || ! _dca_bc_gt "$price" "0" \
        || [ -z "$quantity" ] || ! _dca_bc_gt "$quantity" "0"; then
        return 1
    fi

    if [ "$dry_run" = true ]; then
        [ -n "$log_fn" ] && $log_fn "🔍 DRY-RUN: DCA $label $direction $symbol @ $price qty=$quantity"
        if declare -f log_trade >/dev/null 2>&1; then
            log_trade "DRY-RUN DCA_$label $symbol $direction price=$price qty=$quantity"
        fi
        return 0
    fi

    query_string="symbol=${symbol}&side=${side}&type=LIMIT&timeInForce=GTC&quantity=${quantity}&price=${price}"
    if declare -f append_position_side_param >/dev/null 2>&1; then
        query_string=$(append_position_side_param "$direction" "$query_string")
    fi

    response=$(_binance_fapi_signed_post "/fapi/v1/order" "$query_string")
    if echo "$response" | jq -e '.orderId' >/dev/null 2>&1; then
        [ -n "$log_fn" ] && $log_fn "✅ DCA $label $symbol @ $price qty=$quantity"
        if declare -f log_trade >/dev/null 2>&1; then
            log_trade "DCA_$label $symbol $direction price=$price qty=$quantity orderId=$(echo "$response" | jq -r '.orderId')"
        fi
        return 0
    fi

    [ -n "$log_fn" ] && $log_fn "❌ DCA $label failed $symbol: $response"
    if declare -f log_trade >/dev/null 2>&1; then
        log_trade "FAILED DCA_$label $symbol $direction price=$price response=$(echo "$response" | tr -d '\n')"
    fi
    return 1
}

# After any fill: place STOP at grid level 4 and optional TP
scalper_dca_place_sl_tp_watch() {
    local symbol="$1"
    local direction="$2"
    local sl_price="$3"
    local tp_price="$4"
    local log_fn="${5:-}"

    local fill_wait="${REST_SL_TP_FILL_WAIT:-90}"
    local poll="${REST_SL_TP_POLL_INTERVAL:-2}"
    local elapsed=0
    local placed_sl=false

    if [ -z "$BINANCE_API_KEY" ] || [ -z "$BINANCE_SECRET_KEY" ]; then
        return 1
    fi

    while [ "$elapsed" -lt "$fill_wait" ]; do
        if declare -f futures_get_position >/dev/null 2>&1; then
            local pos_info pos_qty
            pos_info=$(futures_get_position "$symbol")
            if [ "$pos_info" != "none" ]; then
                pos_qty=$(echo "$pos_info" | cut -d'|' -f2)
                if [ -n "$pos_qty" ] && _dca_bc_gt "$pos_qty" "0"; then
                    if [ "$placed_sl" = false ] && [ -n "$sl_price" ] && _dca_bc_gt "$sl_price" "0" \
                        && declare -f _futures_place_reduce_conditional >/dev/null 2>&1; then
                        if _futures_place_reduce_conditional "$symbol" "$direction" "STOP_MARKET" "$sl_price" "$pos_qty" "$log_fn"; then
                            placed_sl=true
                            [ -n "$log_fn" ] && $log_fn "🛡️ DCA L4 SL @ $sl_price (qty $pos_qty)"
                            if declare -f log_trade >/dev/null 2>&1; then
                                log_trade "DCA_SL_L4 $symbol $direction stop=$sl_price qty=$pos_qty"
                            fi
                        fi
                    fi
                    if [ -n "$tp_price" ] && _dca_bc_gt "$tp_price" "0" \
                        && declare -f _futures_place_reduce_conditional >/dev/null 2>&1; then
                        _futures_place_reduce_conditional "$symbol" "$direction" "TAKE_PROFIT_MARKET" "$tp_price" "$pos_qty" "$log_fn"
                        if declare -f log_trade >/dev/null 2>&1; then
                            log_trade "DCA_TP $symbol $direction stop=$tp_price qty=$pos_qty"
                        fi
                    fi
                    return 0
                fi
            fi
        fi
        sleep "$poll"
        elapsed=$((elapsed + poll))
    done

    [ -n "$log_fn" ] && $log_fn "⏳ $symbol: DCA grid limits not filled in ${fill_wait}s — L4 SL not placed yet"
    return 1
}

# Place full OB DCA grid (levels 1,2,3,5 limits + monitor L4 SL)
send_scalper_ob_dca_grid() {
    local symbol="$1"
    local direction="$2"
    local anchor_entry="$3"
    local tp_price="$4"
    local total_qty="$5"
    local log_fn="${6:-log}"

    if ! declare -f calculate_ob_dca_grid >/dev/null 2>&1; then
        return 1
    fi

    local support resistance grid l1 l2 l3 sl_l4 l5
    support=$(ob_get SUPPORT "$symbol")
    resistance=$(ob_get RESISTANCE "$symbol")
    grid=$(calculate_ob_dca_grid "$direction" "$anchor_entry" "$support" "$resistance" "$symbol")
    l1=$(echo "$grid" | cut -d'|' -f1)
    l2=$(echo "$grid" | cut -d'|' -f2)
    l3=$(echo "$grid" | cut -d'|' -f3)
    sl_l4=$(echo "$grid" | cut -d'|' -f4)
    l5=$(echo "$grid" | cut -d'|' -f5)

    if [ -z "$l1" ] || ! _dca_bc_gt "$l1" "0"; then
        [ -n "$log_fn" ] && $log_fn "❌ $symbol: invalid DCA grid (check OB support/resistance)"
        return 1
    fi

    local split="${SCALPER_DCA_LIMIT_ORDERS:-4}"
    local leg_qty
    if [ -z "$total_qty" ] || ! _dca_bc_gt "$total_qty" "0"; then
        return 1
    fi
    leg_qty=$(echo "scale=12; $total_qty / $split" | bc -l 2>/dev/null)
    if declare -f round_qty_for_symbol >/dev/null 2>&1; then
        leg_qty=$(round_qty_for_symbol "$symbol" "$leg_qty")
    fi

    [ -n "$log_fn" ] && $log_fn "📐 DCA grid $symbol $direction | L1=$l1 L2=$l2 L3=$l3 L5=$l5 | L4(SL)=$sl_l4 | leg_qty=$leg_qty"

    if declare -f log_trade >/dev/null 2>&1; then
        log_trade "DCA_GRID $symbol $direction L1=$l1 L2=$l2 L3=$l3 L5=$l5 SL_L4=$sl_l4 step_ob support=$support resistance=$resistance"
    fi

    futures_place_limit_order "$symbol" "$direction" "$l1" "$leg_qty" "$log_fn" "L1"
    futures_place_limit_order "$symbol" "$direction" "$l2" "$leg_qty" "$log_fn" "L2"
    futures_place_limit_order "$symbol" "$direction" "$l3" "$leg_qty" "$log_fn" "L3"
    futures_place_limit_order "$symbol" "$direction" "$l5" "$leg_qty" "$log_fn" "L5"

    if declare -f ob_set >/dev/null 2>&1; then
        ob_set DCA_ACTIVE "$symbol" "true"
        ob_set DCA_DIR "$symbol" "$direction"
        ob_set DCA_SL "$symbol" "$sl_l4"
        ob_set DCA_TP "$symbol" "$tp_price"
        ob_set ACTIVE "$symbol" "true"
        ob_set ACTIVE_TS "$symbol" "$(date +%s)"
        ob_set POS_DIR "$symbol" "$direction"
        ob_set LAST_ENTRY "$symbol" "$l1"
    fi

    (
        export TRADES_LOG_FILE BOT_LOG_BASE_DIR BINANCE_API_KEY BINANCE_SECRET_KEY
        export DRY_RUN REST_SL_TP_FILL_WAIT REST_SL_TP_POLL_INTERVAL BINANCE_HEDGE_MODE
        scalper_dca_place_sl_tp_watch "$symbol" "$direction" "$sl_l4" "$tp_price" "$log_fn"
    ) &

    return 0
}

# Clear local DCA flags when position flat and no pending limits (call from cycle)
scalper_dca_clear_if_done() {
    local symbol="$1"
    if ! declare -f ob_get >/dev/null 2>&1; then
        return 0
    fi
    [ "$(ob_get DCA_ACTIVE "$symbol")" != "true" ] && return 0

    if declare -f futures_has_open_position >/dev/null 2>&1 \
        && futures_has_open_position "$symbol"; then
        return 0
    fi
    if declare -f futures_has_open_limit_same_side >/dev/null 2>&1; then
        local dir
        dir=$(ob_get DCA_DIR "$symbol")
        [ -n "$dir" ] && futures_has_open_limit_same_side "$symbol" "$dir" && return 0
    fi

    ob_set DCA_ACTIVE "$symbol" "false"
    ob_set DCA_DIR "$symbol" ""
    ob_set DCA_SL "$symbol" ""
    ob_set DCA_TP "$symbol" ""
    ob_set ACTIVE "$symbol" "false"
    return 0
}
