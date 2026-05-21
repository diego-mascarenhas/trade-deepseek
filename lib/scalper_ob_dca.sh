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
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 + 0 > b + 0) ? 0 : 1 }'
}

_dca_bc_gte() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 >= b + 0) ? 0 : 1 }'
}

# Ensure each level is at least one tick away from the previous (after rounding)
_dca_bump_min_tick() {
    local symbol="$1"
    local prev="$2"
    local next="$3"
    local tick bumped

    if ! _dca_bc_gt "$next" "$prev"; then
        next="$prev"
    fi
    if declare -f _bnp_get >/dev/null 2>&1; then
        tick=$(_bnp_get TICK "$symbol" 2>/dev/null)
    else
        tick="0.01"
    fi
    [ -z "$tick" ] || ! _dca_bc_gt "$tick" "0" ] && tick="0.01"

    if _dca_bc_gt "$prev" "$next"; then
        bumped=$(echo "scale=12; $prev - $tick" | bc -l)
        if _dca_bc_gt "$bumped" "$next"; then
            echo "$bumped"
            return 0
        fi
    else
        bumped=$(echo "scale=12; $prev + $tick" | bc -l)
        if _dca_bc_gt "$bumped" "$next"; then
            echo "$bumped"
            return 0
        fi
    fi
    echo "$next"
}

# OB fib: 0=support, 1=resistance, >1 = extension above R (e.g. 1.236), <0 = below S
_dca_ob_fib_price() {
    local support="$1"
    local resistance="$2"
    local ratio="$3"
    local range

    range=$(echo "$resistance - $support" | bc -l 2>/dev/null)
    if [ -z "$range" ] || ! _dca_bc_gt "$range" "0"; then
        echo ""
        return 1
    fi

    if _dca_bc_gt "$ratio" "1"; then
        echo "scale=12; $resistance + $range * ($ratio - 1)" | bc -l 2>/dev/null
    elif _dca_bc_gt "0" "$ratio"; then
        echo "scale=12; $support + $range * $ratio" | bc -l 2>/dev/null
    else
        echo "scale=12; $support + $range * $ratio" | bc -l 2>/dev/null
    fi
}

# Percent distance from prev → next (always positive)
_dca_gap_pct() {
    local prev="$1"
    local next="$2"
    if [ -z "$prev" ] || ! _dca_bc_gt "$prev" "0"; then
        echo "0"
        return 0
    fi
    echo "scale=8; ($next - $prev) * 100 / $prev" | bc -l 2>/dev/null | sed 's/^-//'
}

# Bump price so gap from prev is at least min_pct% (SHORT = higher, LONG = lower)
_dca_bump_min_pct_gap() {
    local direction="$1"
    local prev="$2"
    local next="$3"
    local min_pct="$4"
    local sym="${5:-}"
    local gap need target

    gap=$(_dca_gap_pct "$prev" "$next")
    if [ -n "$gap" ] && _dca_bc_gte "$gap" "$min_pct"; then
        echo "$next"
        return 0
    fi

    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        SHORT)
            target=$(echo "scale=12; $prev * (1 + $min_pct / 100)" | bc -l)
            if _dca_bc_gt "$target" "$next"; then
                next="$target"
            fi
            ;;
        LONG)
            target=$(echo "scale=12; $prev * (1 - $min_pct / 100)" | bc -l)
            if _dca_bc_gt "$next" "$target"; then
                next="$target"
            fi
            ;;
    esac

    if [ -n "$sym" ]; then
        next=$(_dca_bump_min_tick "$sym" "$prev" "$next")
        if declare -f round_price_for_symbol >/dev/null 2>&1; then
            next=$(round_price_for_symbol "$sym" "$next")
        fi
    fi
    echo "$next"
}

# Pick L2,L3,L5 from OB fib ladder with >= min_pct between consecutive levels
_dca_pick_ob_ladder() {
    local direction="$1"
    local l1="$2"
    local support="$3"
    local resistance="$4"
    local min_pct="$5"
    local sym="${6:-}"

    local ratio px gap prev l2="" l3="" l5="" picked=0
    local ratios

    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        SHORT) ratios="0.618 0.786 1.0 1.236 1.382 1.618" ;;
        LONG)  ratios="0.382 0.236 0  -0.236 -0.382" ;;
        *) return 1 ;;
    esac

    prev="$l1"
    for ratio in $ratios; do
        px=$(_dca_ob_fib_price "$support" "$resistance" "$ratio")
        [ -z "$px" ] && continue
        if [ -n "$sym" ] && declare -f round_price_for_symbol >/dev/null 2>&1; then
            px=$(round_price_for_symbol "$sym" "$px")
        fi

        case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
            SHORT)
                if ! _dca_bc_gt "$px" "$l1"; then
                    continue
                fi
                ;;
            LONG)
                if ! _dca_bc_gt "$l1" "$px"; then
                    continue
                fi
                ;;
            *)
                return 1
                ;;
        esac

        gap=$(_dca_gap_pct "$prev" "$px")
        if [ -z "$gap" ] || ! _dca_bc_gte "$gap" "$min_pct"; then
            continue
        fi

        case "$picked" in
            0) l2="$px"; picked=1 ;;
            1) l3="$px"; picked=2 ;;
            2) l5="$px"; picked=3; break ;;
        esac
        prev="$px"
    done

    # Fill missing rungs toward next OB fib, enforcing min_pct from previous level
    if [ -z "$l2" ]; then
        case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
            SHORT) l2=$(_dca_ob_fib_price "$support" "$resistance" "0.786") ;;
            LONG)  l2=$(_dca_ob_fib_price "$support" "$resistance" "0.236") ;;
        esac
        [ -n "$sym" ] && declare -f round_price_for_symbol >/dev/null 2>&1 && l2=$(round_price_for_symbol "$sym" "$l2")
        l2=$(_dca_bump_min_pct_gap "$direction" "$l1" "$l2" "$min_pct" "$sym")
    fi
    if [ -z "$l3" ] && [ -n "$l2" ]; then
        l3=$(_dca_ob_fib_price "$support" "$resistance" "1.0")
        [ -n "$sym" ] && declare -f round_price_for_symbol >/dev/null 2>&1 && l3=$(round_price_for_symbol "$sym" "$l3")
        l3=$(_dca_bump_min_pct_gap "$direction" "$l2" "$l3" "$min_pct" "$sym")
    fi
    if [ -z "$l5" ] && [ -n "$l3" ]; then
        case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
            SHORT) l5=$(_dca_ob_fib_price "$support" "$resistance" "1.382") ;;
            LONG)  l5=$(_dca_ob_fib_price "$support" "$resistance" "0") ;;
        esac
        [ -n "$sym" ] && declare -f round_price_for_symbol >/dev/null 2>&1 && l5=$(round_price_for_symbol "$sym" "$l5")
        l5=$(_dca_bump_min_pct_gap "$direction" "$l3" "$l5" "$min_pct" "$sym")
    fi

    echo "${l2}|${l3}|${l5}"
    return 0
}

# Echo: L1|L2|L3|SL_L4|L5 — limits at OB fib levels; >= min_pct between each step (default 1%)
calculate_ob_dca_grid() {
    local direction="$1"
    local anchor="$2"
    local support="$3"
    local resistance="$4"
    local sym="${5:-}"

    local min_pct="${SCALPER_DCA_MIN_DISTANCE_PCT:-1.0}"
    local min_range_pct="${SCALPER_DCA_MIN_RANGE_PCT:-2.0}"

    if [ -z "$anchor" ] || ! _dca_bc_gt "$anchor" "0"; then
        echo "||||"
        return 1
    fi
    if [ -z "$support" ] || [ -z "$resistance" ] \
        || ! _dca_bc_gt "$support" "0" || ! _dca_bc_gt "$resistance" "0" \
        || ! _dca_bc_gt "$resistance" "$support"; then
        echo "||||"
        return 1
    fi

    local range range_pct l1 l2 l3 l4 l5 ladder

    range=$(echo "$resistance - $support" | bc -l 2>/dev/null)
    range_pct=$(echo "scale=8; $range * 100 / $anchor" | bc -l 2>/dev/null)

    if [ -z "$range_pct" ] || ! _dca_bc_gte "$range_pct" "$min_range_pct"; then
        echo "||||"
        return 1
    fi

    l1="$anchor"
    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        LONG|SHORT) ;;
        *)
            echo "||||"
            return 1
            ;;
    esac

    if [ -n "$sym" ] && declare -f round_price_for_symbol >/dev/null 2>&1; then
        l1=$(round_price_for_symbol "$sym" "$l1")
    fi

    ladder=$(_dca_pick_ob_ladder "$direction" "$l1" "$support" "$resistance" "$min_pct" "$sym")
    l2=$(echo "$ladder" | cut -d'|' -f1)
    l3=$(echo "$ladder" | cut -d'|' -f2)
    l5=$(echo "$ladder" | cut -d'|' -f3)

    if [ -z "$l2" ] || [ -z "$l3" ] || [ -z "$l5" ]; then
        echo "||||"
        return 1
    fi

    l2=$(_dca_bump_min_pct_gap "$direction" "$l1" "$l2" "$min_pct" "$sym")
    l3=$(_dca_bump_min_pct_gap "$direction" "$l2" "$l3" "$min_pct" "$sym")
    l5=$(_dca_bump_min_pct_gap "$direction" "$l3" "$l5" "$min_pct" "$sym")
    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        SHORT)
            l4=$(_dca_ob_fib_price "$support" "$resistance" "1.618")
            l4=$(_dca_bump_min_pct_gap "$direction" "$l5" "$l4" "$min_pct" "$sym")
            ;;
        LONG)
            l4=$(_dca_ob_fib_price "$support" "$resistance" "-0.382")
            l4=$(_dca_bump_min_pct_gap "$direction" "$l5" "$l4" "$min_pct" "$sym")
            ;;
    esac

    echo "${l1}|${l2}|${l3}|${l4}|${l5}"
    return 0
}

scalper_dca_count_open_limits() {
    local symbol="$1"
    local direction="$2"
    local orders count

    if [ -z "$BINANCE_API_KEY" ] || ! declare -f _binance_fapi_signed_get >/dev/null 2>&1; then
        echo "0"
        return 0
    fi

    case "$(echo "$direction" | tr '[:lower:]' '[:upper:]')" in
        LONG) ;;
        SHORT) ;;
        *) echo "0"; return 0 ;;
    esac

    orders=$(_binance_fapi_signed_get "/fapi/v1/openOrders" "symbol=${symbol}")
    count=$(echo "$orders" | jq -r --arg sym "$symbol" --arg dir "$direction" '
        [.[] | select(.symbol == $sym)
         | select(.type == "LIMIT" or .type == "LIMIT_MAKER")
         | select(
             ($dir == "LONG" and .side == "BUY") or
             ($dir == "SHORT" and .side == "SELL")
           )
        ] | length' 2>/dev/null)
    echo "${count:-0}"
}

# return 0 = allowed | 1 = blocked
can_place_dca_grid() {
    local symbol="$1"
    local direction="$2"
    local log_fn="${3:-}"
    local now last_ts elapsed cooldown open_n

    if declare -f futures_has_open_position >/dev/null 2>&1 && futures_has_open_position "$symbol"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: open position — skip new DCA grid"
        return 1
    fi

    if declare -f ob_get >/dev/null 2>&1 && [ "$(ob_get DCA_ACTIVE "$symbol")" = "true" ]; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: DCA grid already active for $symbol — skipping"
        return 1
    fi

    open_n=$(scalper_dca_count_open_limits "$symbol" "$direction")
    if [ -n "$open_n" ] && [ "$open_n" -gt 0 ] 2>/dev/null; then
        [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: $open_n pending $direction limits — skip duplicate grid"
        return 1
    fi

    cooldown="${SCALPER_DCA_GRID_COOLDOWN_SECONDS:-120}"
    if declare -f ob_get >/dev/null 2>&1; then
        last_ts=$(ob_get DCA_GRID_TS "$symbol")
        if [ -n "$last_ts" ] && [ "$last_ts" != "0" ]; then
            now=$(date +%s)
            elapsed=$((now - last_ts))
            if [ "$elapsed" -lt "$cooldown" ]; then
                [ -n "$log_fn" ] && $log_fn "⏸️ $symbol: DCA grid cooldown ${elapsed}s / ${cooldown}s"
                return 1
            fi
        fi
    fi

    return 0
}

scalper_dca_grid_active() {
    local symbol="$1"
    if ! declare -f ob_get >/dev/null 2>&1; then
        return 1
    fi
    [ "$(ob_get DCA_ACTIVE "$symbol")" = "true" ] && return 0
    return 1
}

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

    if declare -f futures_has_limit_at_price >/dev/null 2>&1 \
        && futures_has_limit_at_price "$symbol" "$direction" "$price"; then
        [ -n "$log_fn" ] && $log_fn "⏸️ DCA $label skipped — limit already at $price"
        if declare -f log_trade >/dev/null 2>&1; then
            log_trade "SKIP DCA_$label $symbol $direction price=$price reason=duplicate_price"
        fi
        return 2
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

    [ -n "$log_fn" ] && $log_fn "⏳ $symbol: DCA limits not filled in ${fill_wait}s — L4 SL not placed yet"
    return 1
}

send_scalper_ob_dca_grid() {
    local symbol="$1"
    local direction="$2"
    local anchor_entry="$3"
    local tp_price="$4"
    local total_qty="$5"
    local log_fn="${6:-log}"

    if ! can_place_dca_grid "$symbol" "$direction" "$log_fn"; then
        return 0
    fi

    if ! declare -f calculate_ob_dca_grid >/dev/null 2>&1; then
        return 1
    fi

    local support resistance grid l1 l2 l3 sl_l4 l5 min_pct base_step
    support=$(ob_get SUPPORT "$symbol")
    resistance=$(ob_get RESISTANCE "$symbol")
    grid=$(calculate_ob_dca_grid "$direction" "$anchor_entry" "$support" "$resistance" "$symbol")
    l1=$(echo "$grid" | cut -d'|' -f1)
    l2=$(echo "$grid" | cut -d'|' -f2)
    l3=$(echo "$grid" | cut -d'|' -f3)
    sl_l4=$(echo "$grid" | cut -d'|' -f4)
    l5=$(echo "$grid" | cut -d'|' -f5)

    min_pct="${SCALPER_DCA_MIN_DISTANCE_PCT:-1.0}"

    if [ -z "$l1" ] || ! _dca_bc_gt "$l1" "0" \
        || [ -z "$l2" ] || ! _dca_bc_gt "$l2" "0" \
        || [ -z "$l3" ] || ! _dca_bc_gt "$l3" "0" \
        || [ -z "$l5" ] || ! _dca_bc_gt "$l5" "0"; then
        [ -n "$log_fn" ] && $log_fn "❌ $symbol: DCA grid rejected — OB range too narrow or no fib levels with ≥${min_pct}% spacing (S=$support R=$resistance)"
        if declare -f log_trade >/dev/null 2>&1; then
            log_trade "SKIP_DCA_GRID $symbol $direction reason=ob_range_or_spacing support=$support resistance=$resistance min_pct=$min_pct"
        fi
        return 1
    fi

    local split="${SCALPER_DCA_LIMIT_ORDERS:-4}"
    local leg_qty placed=0
    if [ -z "$total_qty" ] || ! _dca_bc_gt "$total_qty" "0"; then
        return 1
    fi
    leg_qty=$(echo "scale=12; $total_qty / $split" | bc -l 2>/dev/null)
    if declare -f round_qty_for_symbol >/dev/null 2>&1; then
        leg_qty=$(round_qty_for_symbol "$symbol" "$leg_qty")
    fi

    if declare -f ob_set >/dev/null 2>&1; then
        ob_set DCA_ACTIVE "$symbol" "true"
        ob_set DCA_DIR "$symbol" "$direction"
        ob_set DCA_GRID_TS "$symbol" "$(date +%s)"
        ob_set DCA_SL "$symbol" "$sl_l4"
        ob_set DCA_TP "$symbol" "$tp_price"
        ob_set DCA_L1 "$symbol" "$l1"
        ob_set ACTIVE "$symbol" "true"
        ob_set ACTIVE_TS "$symbol" "$(date +%s)"
        ob_set POS_DIR "$symbol" "$direction"
        ob_set LAST_ENTRY "$symbol" "$l1"
    fi

    [ -n "$log_fn" ] && $log_fn "📐 DCA $symbol $direction | OB S=$support R=$resistance | L1=$l1 L2=$l2 L3=$l3 L5=$l5 SL=$sl_l4 | min gap ${min_pct}%"

    if declare -f log_trade >/dev/null 2>&1; then
        log_trade "DCA_GRID $symbol $direction L1=$l1 L2=$l2 L3=$l3 L5=$l5 SL_L4=$sl_l4 min_pct=${min_pct} support=$support resistance=$resistance"
    fi

    local rc
    for _dca_lvl in "L1:$l1" "L2:$l2" "L3:$l3" "L5:$l5"; do
        _dca_label="${_dca_lvl%%:*}"
        _dca_px="${_dca_lvl#*:}"
        futures_place_limit_order "$symbol" "$direction" "$_dca_px" "$leg_qty" "$log_fn" "$_dca_label"
        rc=$?
        [ "$rc" -eq 0 ] && placed=$((placed + 1))
    done

    if [ "$placed" -eq 0 ]; then
        if declare -f ob_set >/dev/null 2>&1; then
            ob_set DCA_ACTIVE "$symbol" "false"
        fi
        [ -n "$log_fn" ] && $log_fn "⚠️ $symbol: no DCA limits placed (all duplicates or failed)"
        return 1
    fi

    (
        export TRADES_LOG_FILE BOT_LOG_BASE_DIR BINANCE_API_KEY BINANCE_SECRET_KEY
        export DRY_RUN REST_SL_TP_FILL_WAIT REST_SL_TP_POLL_INTERVAL BINANCE_HEDGE_MODE BINANCE_POSITION_MODE
        scalper_dca_place_sl_tp_watch "$symbol" "$direction" "$sl_l4" "$tp_price" "$log_fn"
    ) &

    return 0
}

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

    local dir open_any
    dir=$(ob_get DCA_DIR "$symbol")
    if declare -f _binance_fapi_signed_get >/dev/null 2>&1; then
        open_any=$(echo "$(_binance_fapi_signed_get "/fapi/v1/openOrders" "symbol=${symbol}")" \
            | jq -r '[.[] | select(.type == "LIMIT" or .type == "LIMIT_MAKER")] | length' 2>/dev/null)
        if [ -n "$open_any" ] && [ "$open_any" -gt 0 ] 2>/dev/null; then
            return 0
        fi
    elif declare -f futures_has_open_limit_same_side >/dev/null 2>&1 \
        && [ -n "$dir" ] && futures_has_open_limit_same_side "$symbol" "$dir"; then
        return 0
    fi

    ob_set DCA_ACTIVE "$symbol" "false"
    ob_set DCA_DIR "$symbol" ""
    ob_set DCA_SL "$symbol" ""
    ob_set DCA_TP "$symbol" ""
    ob_set DCA_L1 "$symbol" ""
    ob_set ACTIVE "$symbol" "false"
    return 0
}
