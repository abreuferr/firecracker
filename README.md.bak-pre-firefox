# firecracker

Estudo sobre o virtualizador Firecracker (VMM leve sobre KVM, não usa QEMU).

Setup validado no host `taquion` (Debian 13 / trixie), com dois perfis de
guest microVM (Ubuntu 22.04 e Debian 13) rodando em paralelo.

## Estrutura

- `src/`: versões de referência dos scripts e configs (`start-vm.sh`,
  `stop-vm.sh`, `vm-config-ubuntu.json`, `vm-config-debian.json`).
- Deploy real roda a partir de `/data/firecracker` no host `taquion`
  (kernel, rootfs, sockets, pids, logs — fora do home, não versionado).
- Acesso aos guests usa a chave pessoal existente `~/.ssh/pessoal_ec1`
  (mesma chave nos dois perfis) — não gerar chave nova por rootfs.
- Todo guest tem usuário `cferreira` (grupo `sudo`) além do root, com a
  mesma chave.

## Pré-requisitos

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo
sudo apt install -y qemu-kvm cpu-checker
sudo kvm-ok   # espera: /dev/kvm exists + KVM acceleration can be used
sudo usermod -aG kvm $USER   # relogar (ou newgrp kvm) depois
```

## 1. Binário do Firecracker

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
```

## 2. Kernel (vmlinux) da CI

```bash
curl -s "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/&delimiter=/&list-type=2" \
  | grep -oP '(?<=<Prefix>)firecracker-ci/[^<]+(?=</Prefix>)'
```

```bash
mkdir -p vmlinux rootfs rootfs-debian
ARCH="$(uname -m)"
CI_VERSION="v1.15"   # ajustar conforme prefixos disponíveis

latest_kernel_key=$(curl -s "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/$CI_VERSION/$ARCH/vmlinux-&list-type=2" \
    | grep -oP "(?<=<Key>)(firecracker-ci/$CI_VERSION/$ARCH/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
    | sort -V | tail -1)

curl -fsSL -o vmlinux/vmlinux.bin "https://s3.amazonaws.com/spec.ccfc.min/${latest_kernel_key}"
```

## 3. Rootfs Ubuntu (squashfs oficial da CI)

```bash
curl -fsSL "http://spec.ccfc.min.s3.amazonaws.com/firecracker-ci/v1.10/x86_64/ubuntu-22.04.squashfs" \
  -o rootfs/ubuntu.squashfs

sudo apt install -y squashfs-tools
unsquashfs -d rootfs/squashfs-root rootfs/ubuntu.squashfs

sudo mkdir -p rootfs/squashfs-root/root/.ssh
sudo cp ~/.ssh/pessoal_ec1.pub rootfs/squashfs-root/root/.ssh/authorized_keys
sudo chmod 700 rootfs/squashfs-root/root/.ssh
sudo chmod 600 rootfs/squashfs-root/root/.ssh/authorized_keys

sudo chroot rootfs/squashfs-root useradd -m -s /bin/bash -G sudo cferreira
sudo mkdir -p rootfs/squashfs-root/home/cferreira/.ssh
sudo cp ~/.ssh/pessoal_ec1.pub rootfs/squashfs-root/home/cferreira/.ssh/authorized_keys
sudo chroot rootfs/squashfs-root chown -R cferreira:cferreira /home/cferreira/.ssh
sudo chmod 700 rootfs/squashfs-root/home/cferreira/.ssh
sudo chmod 600 rootfs/squashfs-root/home/cferreira/.ssh/authorized_keys

sudo chown -R root:root rootfs/squashfs-root
truncate -s 1G rootfs/ubuntu.ext4
sudo mkfs.ext4 -d rootfs/squashfs-root -F rootfs/ubuntu.ext4
sudo /sbin/e2fsck -fn rootfs/ubuntu.ext4
```

## 4. Rootfs Debian 13 (via debootstrap)

Não existe imagem oficial de Debian no bucket de CI — só Ubuntu.

```bash
sudo apt install -y debootstrap
truncate -s 1G rootfs-debian/debian13.ext4
sudo mkfs.ext4 rootfs-debian/debian13.ext4

mkdir -p /tmp/debian13-mnt
sudo mount rootfs-debian/debian13.ext4 /tmp/debian13-mnt

sudo debootstrap --arch=amd64 \
  --include=openssh-server,systemd-sysv,iproute2,udev,sudo \
  trixie /tmp/debian13-mnt http://deb.debian.org/debian

sudo mkdir -p /tmp/debian13-mnt/root/.ssh
sudo cp ~/.ssh/pessoal_ec1.pub /tmp/debian13-mnt/root/.ssh/authorized_keys
sudo chmod 700 /tmp/debian13-mnt/root/.ssh
sudo chmod 600 /tmp/debian13-mnt/root/.ssh/authorized_keys
sudo chroot /tmp/debian13-mnt sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

sudo chroot /tmp/debian13-mnt useradd -m -s /bin/bash -G sudo cferreira
sudo mkdir -p /tmp/debian13-mnt/home/cferreira/.ssh
sudo cp ~/.ssh/pessoal_ec1.pub /tmp/debian13-mnt/home/cferreira/.ssh/authorized_keys
sudo chroot /tmp/debian13-mnt chown -R cferreira:cferreira /home/cferreira/.ssh
sudo chmod 700 /tmp/debian13-mnt/home/cferreira/.ssh
sudo chmod 600 /tmp/debian13-mnt/home/cferreira/.ssh/authorized_keys

sudo tee /tmp/debian13-mnt/etc/network/interfaces > /dev/null <<'EOF'
auto eth0
iface eth0 inet static
    address 172.16.1.2
    netmask 255.255.255.252
    gateway 172.16.1.1
EOF
sudo chroot /tmp/debian13-mnt apt install -y ifupdown

sudo umount /tmp/debian13-mnt
```

## Rodando as microVMs

Os dois perfis rodam em paralelo, cada um com TAP/sub-rede/socket próprios:

| | Ubuntu 22.04 | Debian 13 (trixie) |
|---|---|---|
| TAP | `tap0` | `tap1` |
| Sub-rede | `172.16.0.x/30` | `172.16.1.x/30` |
| Socket API | `/tmp/firecracker-ubuntu.socket` | `/tmp/firecracker-debian.socket` |
| Rootfs | `rootfs/ubuntu.ext4` | `rootfs-debian/debian13.ext4` |

```bash
cd /data/firecracker
./start-vm.sh ubuntu     # ou: ./start-vm.sh debian
ssh -i ~/.ssh/pessoal_ec1 root@172.16.0.2
./stop-vm.sh ubuntu      # ou: ./stop-vm.sh debian
```

`ssh -i ~/.ssh/pessoal_ec1 cferreira@172.16.0.2` também funciona, mas só em
rootfs reconstruído com os passos das seções 3/4 acima (que criam o usuário).
Nos rootfs que já existiam antes dessa convenção, só `root` tem a chave —
`cferreira` precisa ser criado manualmente na VM já ligada (`useradd -m -G
sudo cferreira` + chave em `~cferreira/.ssh/authorized_keys`) ou o rootfs
precisa ser reconstruído do zero.

Configurar rede/DNS na primeira sessão do guest, se necessário:

```bash
ip route add default via <TAP_IP> dev eth0
echo 'nameserver 8.8.8.8' > /etc/resolv.conf
```

## Próximos passos (não implementados)

- Isolamento via `jailer` para multi-tenant/produção.
- Snapshot/restore de microVMs (cold-start rápido, uso serverless).
- Integração com `firecracker-containerd`.
- Resize do rootfs Debian (atualmente 1G fixo) via `resize2fs`.
