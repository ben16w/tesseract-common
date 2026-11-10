#!/bin/bash
set -euo pipefail

echo "Starting Dante SOCKS5 proxy on :1080 (external tun0)"
pkill -x danted 2>/dev/null || true
danted -f /etc/danted.conf -D
echo "Dante started"
