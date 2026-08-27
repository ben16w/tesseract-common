#!/bin/bash
set -e

BACKEND_PORT="${TTS_BACKEND_PORT:-8081}"
export TTS_BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}"
export PORT="${BACKEND_PORT}"

./entrypoint.sh &
TTS_PID=$!

# Wait for tts-server to start
for _ in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:${BACKEND_PORT}/health" > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

python3 /app/proxy.py &
PROXY_PID=$!

wait -n $TTS_PID $PROXY_PID
kill $TTS_PID $PROXY_PID 2>/dev/null
