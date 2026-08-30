#!/bin/bash
set -uo pipefail

FC_DIR="/data/firecracker"
PROFILE="${1:-ubuntu}"

case "$PROFILE" in
  ubuntu)
    API_SOCKET="/tmp/firecracker-ubuntu.socket"
    PIDFILE="${FC_DIR}/firecracker-ubuntu.pid"
    TAP_DEV="tap0"
    ;;
  debian)
    API_SOCKET="/tmp/firecracker-debian.socket"
    PIDFILE="${FC_DIR}/firecracker-debian.pid"
    TAP_DEV="tap1"
    ;;
  *)
    echo "Uso: $0 [ubuntu|debian]"
    exit 1
    ;;
esac

if [ -f "$PIDFILE" ]; then
  FC_PID=$(cat "$PIDFILE")
  if kill -0 "$FC_PID" 2>/dev/null; then
    echo "==> [${PROFILE}] Enviando SIGTERM ao Firecracker (PID $FC_PID)"
    sudo kill "$FC_PID"
    sleep 1
  fi
  rm -f "$PIDFILE"
else
  echo "Nenhum PID registrado para '${PROFILE}' — tentando localizar processo pelo socket"
  sudo pkill -f "firecracker --api-sock ${API_SOCKET}" || true
fi

echo "==> [${PROFILE}] Removendo interface de rede (${TAP_DEV})"
sudo ip link del "$TAP_DEV" 2>/dev/null || true

echo "==> [${PROFILE}] Removendo socket"
sudo rm -f "$API_SOCKET"

echo "==> [${PROFILE}] microVM parada e ambiente limpo."
