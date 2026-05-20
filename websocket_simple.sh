#!/bin/bash

# ============================================
# Binance WebSocket - Simple View
# ============================================

SYMBOL="${1:-BTCUSDT}"
LOWERCASE=$(echo "$SYMBOL" | tr '[:upper:]' '[:lower:]')
WS_URL="wss://fstream.binance.com/public/ws/${LOWERCASE}@depth10@500ms"

echo "🔌 Conectando a $SYMBOL..."
echo ""

if command -v websocat &> /dev/null; then
    websocat --text "$WS_URL" 2>/dev/null | while read -r line; do
        best_bid=$(echo "$line" | jq -r '.b[0][0]')
        best_ask=$(echo "$line" | jq -r '.a[0][0]')
        bid_vol=$(echo "$line" | jq -r '.b[0][1]')
        ask_vol=$(echo "$line" | jq -r '.a[0][1]')
        
        # Mover cursor al inicio y limpiar líneas
        printf "\033[2J\033[H"
        
        echo "════════════════════════════════════════"
        echo "  $SYMBOL - ORDER BOOK L2"
        echo "════════════════════════════════════════"
        echo "🟢 BUY:  $best_bid (Vol: $bid_vol)"
        echo "🔴 SELL: $best_ask (Vol: $ask_vol)"
        
        if [ "$best_bid" != "null" ] && [ "$best_ask" != "null" ]; then
            spread=$(echo "$best_ask - $best_bid" | bc -l)
            echo "📊 Spread: $spread"
        fi
        echo "════════════════════════════════════════"
        echo "⏰ $(date '+%H:%M:%S')"
    done
else
    echo "❌ Instala websocat: brew install websocat"
fi