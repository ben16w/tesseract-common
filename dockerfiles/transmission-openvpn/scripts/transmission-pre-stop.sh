#!/bin/bash
set -euo pipefail

echo "Stopping Dante SOCKS5 proxy"
pkill -x danted 2>/dev/null || true
