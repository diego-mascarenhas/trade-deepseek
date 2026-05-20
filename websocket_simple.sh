#!/bin/bash

# ============================================
# Binance WebSocket Simple - Best Bid/Ask
# Compatible con MacOS
# ============================================

SYMBOL="${1:-ZECUSDT}"
DEPTH="depth10"
SPEED="500ms"

# Convertir a minúsculas (MacOS compatible)
LOWERCASE=$(echo "$SYMBOL" | tr '[:upper:]' '[:lower:]')
WS_URL="wss://fstream.binance.com/public/ws/${LOWERCASE}@${DEPTH}@${SPEED}"

echo "🔌 Conectando a $SYMBOL (Presiona Ctrl+C para salir)"
echo "URL: $WS_URL"
echo ""

if command -v websocat &> /dev/null; then
    websocat --text "$WS_URL" 2>/dev/null | while read -r line; do
        best_bid=$(echo "$line" | jq -r '.b[0][0] // "N/A"' 2>/dev/null)
        best_ask=$(echo "$line" | jq -r '.a[0][0] // "N/A"' 2>/dev/null)
        bid_qty=$(echo "$line" | jq -r '.b[0][1] // "0"' 2>/dev/null)
        ask_qty=$(echo "$line" | jq -r '.a[0][1] // "0"' 2>/dev/null)
        
        clear
        echo "═══════════════════════════════════"
        echo "  $SYMBOL - ORDER BOOK L2"
        echo "═══════════════════════════════════"
        echo "🟢 COMPRA: $best_bid (Vol: $bid_qty)"
        echo "🔴 VENTA:  $best_ask (Vol: $ask_qty)"
        
        if [ "$best_bid" != "N/A" ] && [ "$best_ask" != "N/A" ]; then
            spread=$(echo "$best_ask - $best_bid" | bc -l 2>/dev/null)
            echo "📊 Spread: $spread"
        fi
        echo "═══════════════════════════════════"
        echo "$(date '+%H:%M:%S') - Actualizado"
    done
else
    echo "❌ Instala websocat: brew install websocat"
    exit 1
fi