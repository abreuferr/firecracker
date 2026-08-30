# Implementação Prática do Firecracker MicroVM — Debian 13 (host `taquion`)

Guia consolidado com todos os passos executados para instalar, configurar e operar
o Firecracker no host Debian 13, incluindo suporte a múltiplos perfis de guest
(Ubuntu 22.04 e Debian 13) rodando em paralelo.

---

## 1. Pré-requisitos: verificar suporte a KVM

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo
lsmod | grep kvm
sudo apt update
sudo apt install -y qemu-kvm cpu-checker
sudo kvm-ok
```

Saída esperada: `INFO: /dev/kvm exists` e `KVM acceleration can be used`.

No Debian 13, o `apt install qemu-kvm` resolve para o pacote `qemu-system-x86`
(nome real do metapacote). Isso é apenas uma dependência de referência — o
Firecracker **não usa QEMU**, é seu próprio VMM sobre KVM.

## 2. Permissões de acesso ao `/dev/kvm`

```bash
sudo usermod -aG kvm $USER
```

Relogue a sessão (ou `newgrp kvm`) para aplicar, e confirme com:

```bash
groups $USER
```

## 3. Baixar o binário do Firecracker

```bash
sudo mkdir -p /data/firecracker
sudo chown "$(id -u):$(id -g)" /data/firecracker
cd /data/firecracker

ARCH="$(uname -m)"
release_url="https://github.com/firecracker-microvm/firecracker/releases"
latest=$(basename $(curl -fsSLI -o /dev/null -w '%{url_effective}' ${release_url}/latest))

curl -fsSL "${release_url}/download/${latest}/firecracker-${latest}-${ARCH}.tgz" -o firecracker.tgz
tar -xzf firecracker.tgz
sudo mv release-${latest}-${ARCH}/firecracker-${latest}-${ARCH} /usr/local/bin/firecracker
sudo mv release-${latest}-${ARCH}/jailer-${latest}-${ARCH} /usr/local/bin/jailer
sudo chmod +x /usr/local/bin/firecracker /usr/local/bin/jailer

firecracker --version
```

Resultado obtido: **Firecracker v1.16.1**.

## 4. Obter o kernel (vmlinux) da CI do projeto

> **Atenção:** o bucket de CI (`spec.ccfc.min`) organiza os artefatos por versão
> de branch de CI, que **nem sempre coincide** com a versão do release do
> binário. Descubra os prefixos disponíveis antes de tentar baixar direto:

```bash
curl -s "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/&delimiter=/&list-type=2" \
  | grep -oP '(?<=<Prefix>)firecracker-ci/[^<]+(?=</Prefix>)'
```

No nosso caso, a versão instalada era v1.16.1, mas o bucket de CI só tinha até
`v1.15`. Usamos essa versão manualmente:

```bash
cd /data/firecracker
mkdir -p vmlinux rootfs

ARCH="$(uname -m)"
CI_VERSION="v1.15"

latest_kernel_key=$(curl -s "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/$CI_VERSION/$ARCH/vmlinux-&list-type=2" \
    | grep -oP "(?<=<Key>)(firecracker-ci/$CI_VERSION/$ARCH/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
    | sort -V | tail -1)

curl -fsSL -o vmlinux/vmlinux.bin "https://s3.amazonaws.com/spec.ccfc.min/${latest_kernel_key}"

ls -lh vmlinux/vmlinux.bin
file vmlinux/vmlinux.bin
```

Resultado: kernel ELF 64-bit, ~43M, `vmlinux-6.1.155`.

## 5. Preparar o rootfs Ubuntu (a partir do squashfs de CI)

### 5.1 Baixar o squashfs

```bash
curl -fsSL "http://spec.ccfc.min.s3.amazonaws.com/firecracker-ci/v1.10/x86_64/ubuntu-22.04.squashfs" \
  -o rootfs/ubuntu.squashfs
```

### 5.2 Descompactar

```bash
sudo apt install -y squashfs-tools
unsquashfs -d rootfs/squashfs-root rootfs/ubuntu.squashfs
```

### 5.3 Gerar chave SSH e injetar no rootfs

```bash
ssh-keygen -f rootfs/ubuntu.id_rsa -N ""

sudo mkdir -p rootfs/squashfs-root/root/.ssh
sudo cp rootfs/ubuntu.id_rsa.pub rootfs/squashfs-root/root/.ssh/authorized_keys
sudo chmod 700 rootfs/squashfs-root/root/.ssh
sudo chmod 600 rootfs/squashfs-root/root/.ssh/authorized_keys
```

### 5.4 Converter squashfs → ext4

```bash
sudo chown -R root:root rootfs/squashfs-root
truncate -s 1G rootfs/ubuntu.ext4
sudo mkfs.ext4 -d rootfs/squashfs-root -F rootfs/ubuntu.ext4
```

### 5.5 Verificar integridade

```bash
sudo /sbin/e2fsck -fn rootfs/ubuntu.ext4
```

(`e2fsck` pode não estar no PATH do usuário normal no Debian — use o caminho
completo `/sbin/e2fsck` com `sudo`.)

## 6. Preparar o rootfs Debian 13 (via debootstrap)

Não existe imagem oficial de Debian no bucket de CI do Firecracker (só Ubuntu).
O caminho é montar manualmente com `debootstrap`, reaproveitando o mesmo kernel.

### 6.1 Criar e formatar a imagem ext4

```bash
sudo apt install -y debootstrap
cd /data/firecracker
mkdir -p rootfs-debian

truncate -s 1G rootfs-debian/debian13.ext4
sudo mkfs.ext4 rootfs-debian/debian13.ext4
```

### 6.2 Montar e rodar debootstrap

```bash
mkdir -p /tmp/debian13-mnt
sudo mount rootfs-debian/debian13.ext4 /tmp/debian13-mnt

sudo debootstrap --arch=amd64 \
  --include=openssh-server,systemd-sysv,iproute2,udev \
  trixie /tmp/debian13-mnt http://deb.debian.org/debian
```

### 6.3 Injetar chave SSH e habilitar login root

```bash
ssh-keygen -f rootfs-debian/debian13.id_rsa -N ""

sudo mkdir -p /tmp/debian13-mnt/root/.ssh
sudo cp rootfs-debian/debian13.id_rsa.pub /tmp/debian13-mnt/root/.ssh/authorized_keys
sudo chmod 700 /tmp/debian13-mnt/root/.ssh
sudo chmod 600 /tmp/debian13-mnt/root/.ssh/authorized_keys

sudo chroot /tmp/debian13-mnt sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
```

### 6.4 Configurar rede estática (sub-rede exclusiva: 172.16.1.x)

```bash
sudo tee /tmp/debian13-mnt/etc/network/interfaces > /dev/null <<'EOF'
auto eth0
iface eth0 inet static
    address 172.16.1.2
    netmask 255.255.255.252
    gateway 172.16.1.1
EOF

sudo chroot /tmp/debian13-mnt apt install -y ifupdown
```

### 6.5 Desmontar

```bash
sudo umount /tmp/debian13-mnt
```

## 7. Arquivos de configuração da microVM (`vm-config-*.json`)

Cada perfil (Ubuntu / Debian) tem seu próprio JSON, TAP device e sub-rede, para
poder rodar as duas microVMs **simultaneamente** sem conflito.

### 7.1 `vm-config-ubuntu.json`

```json
{
  "boot-source": {
    "kernel_image_path": "/data/firecracker/vmlinux/vmlinux.bin",
    "boot_args": "console=ttyS0 reboot=k panic=1"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "/data/firecracker/rootfs/ubuntu.ext4",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "machine-config": {
    "vcpu_count": 2,
    "mem_size_mib": 512
  },
  "network-interfaces": [
    {
      "iface_id": "net1",
      "guest_mac": "06:00:AC:10:00:02",
      "host_dev_name": "tap0"
    }
  ]
}
```

### 7.2 `vm-config-debian.json`

```json
{
  "boot-source": {
    "kernel_image_path": "/data/firecracker/vmlinux/vmlinux.bin",
    "boot_args": "console=ttyS0 reboot=k panic=1"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "/data/firecracker/rootfs-debian/debian13.ext4",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "machine-config": {
    "vcpu_count": 2,
    "mem_size_mib": 512
  },
  "network-interfaces": [
    {
      "iface_id": "net1",
      "guest_mac": "06:00:AC:10:01:02",
      "host_dev_name": "tap1"
    }
  ]
}
```

## 8. Scripts de ciclo de vida (`start-vm.sh` / `stop-vm.sh`)

Ambos os scripts aceitam um argumento de perfil: `ubuntu` (padrão) ou `debian`.

### 8.1 `start-vm.sh`

```bash
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
  *)
    echo "Uso: $0 [ubuntu|debian]"
    exit 1
    ;;
esac

MASK_SHORT="/30"

sudo -v

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
```

### 8.2 `stop-vm.sh`

```bash
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
```

### 8.3 Permissões e uso

```bash
chmod +x /data/firecracker/start-vm.sh /data/firecracker/stop-vm.sh

./start-vm.sh ubuntu     # ou: ./start-vm.sh debian
./stop-vm.sh ubuntu      # ou: ./stop-vm.sh debian
```

## 9. Tabela-resumo dos dois perfis

| | Ubuntu 22.04 | Debian 13 (trixie) |
|---|---|---|
| TAP device | `tap0` | `tap1` |
| IP do host na TAP | `172.16.0.1` | `172.16.1.1` |
| IP do guest | `172.16.0.2` | `172.16.1.2` |
| API socket | `/tmp/firecracker-ubuntu.socket` | `/tmp/firecracker-debian.socket` |
| Rootfs | `rootfs/ubuntu.ext4` | `rootfs-debian/debian13.ext4` |
| Chave SSH | `rootfs/ubuntu.id_rsa` | `rootfs-debian/debian13.id_rsa` |
| Origem do rootfs | squashfs oficial da CI (v1.10) | `debootstrap` manual |
| Comando | `./start-vm.sh ubuntu` | `./start-vm.sh debian` |

Ambos compartilham o mesmo kernel (`vmlinux/vmlinux.bin`, 6.1.155) e podem
rodar **simultaneamente**, pois usam TAPs, sub-redes e sockets distintos.

## 10. Configurar rede/DNS dentro do guest (primeira sessão)

Se a interface de rede do guest ainda não tiver rota default/DNS configurados
(guest Ubuntu do squashfs de CI, por exemplo, não vem com isso pronto):

```bash
ip route add default via <TAP_IP> dev eth0
echo 'nameserver 8.8.8.8' > /etc/resolv.conf
```

Teste de conectividade:

```bash
ping -c 3 8.8.8.8
ping -c 3 google.com
```

## 11. Notas e pontos de atenção

- **KVM**: sem suporte a `.metal`/hardware virtualization, Firecracker não
  funciona — sempre confirme com `kvm-ok` antes de qualquer coisa.
- **Bucket de CI da Firecracker**: os prefixos de versão (`firecracker-ci/vX.Y/`)
  nem sempre acompanham a versão do release do binário. Sempre liste os
  prefixos disponíveis antes de montar a URL manualmente.
- **squashfs vs ext4**: o squashfs da CI é somente-leitura e sem chave SSH.
  É necessário descompactar, injetar a chave e reempacotar como ext4 gravável.
- **Debian não tem imagem oficial**: só existe para Ubuntu no bucket da CI.
  A alternativa (usada aqui) é montar via `debootstrap` + configuração manual
  de rede/SSH.
- **`iptables` no Debian 13**: por padrão já é backed por `nftables`
  (`iptables-nft`), os comandos usados aqui funcionam normalmente.
- **`e2fsck` fora do PATH**: no Debian, binários de `/sbin` só entram no PATH
  de root por padrão — use `sudo /sbin/e2fsck` quando necessário.
- **`reboot` dentro do guest** é o mecanismo correto de desligar — o Firecracker
  não implementa gerência de energia própria (ACPI), então `reboot` do guest
  encerra o processo Firecracker no host.
- **Produção**: para isolamento real (chroot, cgroups, seccomp, namespace de
  rede dedicado), usar o binário `jailer` em vez de invocar o `firecracker`
  diretamente como foi feito neste guia de laboratório.

## 12. Próximos passos possíveis (não implementados ainda)

- Isolamento via `jailer` para uso multi-tenant/produção.
- Snapshot/restore de microVMs para cold-start rápido (uso tipo serverless).
- Integração com `firecracker-containerd` para orquestração via containerd.
- Redimensionamento do rootfs Debian (atualmente 1G fixo) via `resize2fs`.
