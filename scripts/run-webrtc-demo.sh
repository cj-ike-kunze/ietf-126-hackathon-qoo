#!/usr/bin/env bash
set -euo pipefail

SESSION="${1:-demo}"
SENDER_MODE="${2:-reference}"

cat <<EOF
WebRTC demo bootstrap
- session: ${SESSION}
- sender_mode: ${SENDER_MODE}

Open these pages:
1) Receiver (host browser): http://localhost:8080/webrtc-receiver.html
2) Sender (in browser container noVNC): http://localhost:5800 then open http://172.28.0.10:9000/webrtc/sender

Suggested order:
1) Start Receiver Connect with session ${SESSION}
2) Start Sender with same session + mode ${SENDER_MODE}
3) Start/Stop recording on receiver page
EOF

curl -sS -X POST http://localhost:9000/webrtc/session \
  -H 'Content-Type: application/json' \
  -d "{\"session\":\"${SESSION}\",\"reset\":true}" >/dev/null

echo "Session primed."
