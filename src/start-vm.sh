#!/bin/bash
set -euo pipefail

FC_DIR="/data/firecracker"
PROFILE="${1:-ubuntu}"

case "$PROFILE" in
  ubuntu)
    CONFIG_FILE="${FC_DIR}/vm-config-ubuntu.json"
    API_SOCKET="/tmp/firecracker-ubuntu.socket"
    PIDFILE="${FC_DIR}/firecracker-ubuntu.pid"
    LOGFILE="${FC_DIR}/firecracker-ubuntu.log"
    TAP_DEV="tap0"
    TAP_IP="172.16.0.1"
    GUEST_IP="172.16.0.2"
    SSH_KEY="${FC_DIR}/rootfs/ubuntu.id_rsa"
    ;;
  debian)
    CONFIG_FILE="${FC_DIR}/vm-config-debian.json"
    API_SOCKET="/tmp/firecracker-debian.socket"
    PIDFILE="${FC_DIR}/firecracker-debian.pid"
    LOGFILE="${FC_DIR}/firecracker-debian.log"
    TAP_DEV="tap1"
    TAP_IP="172.16.1.1"
    GUEST_IP="172.16.1.2"
    SSH_KEY="${FC_DIR}/rootfs-debian/debian13.id_rsa"
    ;;
  firefox)
    CONFIG_FILE="${FC_DIR}/vm-config-firefox.json"
    API_SOCKET="/tmp/firecracker-firefox.socket"
    PIDFILE="${FC_DIR}/firecracker-firefox.pid"
    LOGFILE="${FC_DIR}/firecracker-firefox.log"
    TAP_DEV="tap2"
    TAP_IP="172.16.2.1"
    GUEST_IP="172.16.2.2"
    SSH_KEY="${FC_DIR}/rootfs-firefox/firefox.id_rsa"
    ;;
  *)
    echo "Uso: $0 [ubuntu|debian|firefox]"
    exit 1
    ;;
esac

MASK_SHORT="/30"

sudo -v 2>/dev/null || true

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "microVM '${PROFILE}' já está rodando (PID $(cat "$PIDFILE")). Rode stop-vm.sh ${PROFILE} primeiro."
  exit 1
fi

echo "==> [${PROFILE}] Limpando socket antigo"
sudo rm -f "$API_SOCKET"
sudo rm -f "$LOGFILE"
sudo touch "$LOGFILE"
sudo chown "$(id -u):$(id -g)" "$LOGFILE"

echo "==> [${PROFILE}] Configurando rede (${TAP_DEV})"
sudo ip link del "$TAP_DEV" 2>/dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
sudo ip link set dev "$TAP_DEV" up

sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
sudo iptables -P FORWARD ACCEPT

HOST_IFACE=$(ip -j route list default | jq -r '.[0].dev')
echo "    Interface de saída detectada: ${HOST_IFACE}"

sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE

echo "==> [${PROFILE}] Iniciando Firecracker"
sudo firecracker --api-sock "$API_SOCKET" --config-file "$CONFIG_FILE" &>"$LOGFILE" &
FC_PID=$!
echo "$FC_PID" > "$PIDFILE"

sleep 2

if ! kill -0 "$FC_PID" 2>/dev/null; then
  echo "ERRO: Firecracker encerrou ao iniciar. Veja $LOGFILE:"
  tail -n 30 "$LOGFILE"
  rm -f "$PIDFILE"
  exit 1
fi

echo "==> [${PROFILE}] microVM iniciada (PID $FC_PID)"
echo "    SSH:   ssh -i ${SSH_KEY} root@${GUEST_IP}"
echo "    Logs:  tail -f $LOGFILE"
