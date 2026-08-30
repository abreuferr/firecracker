# Convenções do projeto firecracker

Ver README.md para setup, estrutura e como rodar as microVMs. Aqui só o que
não é óbvio a partir do README/código.

Este arquivo é a memória viva do projeto — decisões e histórico relevante
ficam aqui, versionados no repo, em vez de memória externa da sessão.

## Acesso SSH e hardening

- Chave `~/.ssh/pessoal_ec1` (mesma nos dois perfis) — não gerar chave nova
  por rootfs. Todo guest tem `root` e `cferreira` (grupo `sudo`), ambos com
  essa chave. Regra global (qualquer VM), registrada em `~/.claude/CLAUDE.md`.
- `root` e `cferreira` são criados **sem senha** (`useradd -m` sem `passwd`)
  — login só funciona por chave, mesmo com `PermitRootLogin yes` no
  sshd_config, porque não existe senha pra autenticar. Isso equivale na
  prática a `PermitRootLogin prohibit-password`, mas não está escrito
  assim explicitamente — trocar se quiser hardening mais explícito.
- `chmod 700` em `.ssh` e `chmod 600` em `authorized_keys`, pra root e pra
  cferreira — sshd recusa login por chave se as permissões forem mais
  abertas.
- Rootfs existentes antes dessa convenção (ex.: builds anteriores a
  2026-08-30) não têm `cferreira` retroativamente — só vale a partir da
  reconstrução do zero. Rootfs debian já reconstruído com essas etapas em
  2026-08-30.

## Padrão de estrutura (src/, doc/, README.md, CLAUDE.md)

Regra global registrada em `~/.claude/CLAUDE.md`: todo projeto novo tem
`src/`, `doc/`, `README.md` e `CLAUDE.md` na raiz. Aplicada retroativamente
(2026-08-30) em `pessoal/risc-v` (faltavam README.md e CLAUDE.md) e
`pessoal/etc` (faltava CLAUDE.md). Deixados de fora, de propósito:
`pessoal/homelab` (já tem README/CLAUDE.md próprios, organizado por
subpasta temática) e os multi-tópico `criptografia/`, `hsm/`, `lpic/`,
`python/` (cada subpasta é um tema/curso — forçar `src/doc` destruiria
essa organização). `projects/segura/*` não foi tocado.

Este próprio repo não tem mais `doc/` (o guia tutorial que morava lá foi
convertido em README.md/CLAUDE.md em 2026-08-30) — não é uma violação da
regra, só não há conteúdo de doc separado do README no momento.

## Gotchas confirmados

- **Bucket de CI (`spec.ccfc.min.s3.amazonaws.com`)**: prefixos de versão
  (`firecracker-ci/vX.Y/`) não acompanham a versão do release do binário.
  Sempre listar prefixos disponíveis antes de montar a URL manualmente.
- **squashfs da CI é somente-leitura e sem chave SSH** — precisa descompactar,
  injetar chave, reempacotar como ext4 via `mkfs.ext4 -d`. Esse comando faz
  `chown -R root:root` na árvore de origem antes de empacotar — se for tocar
  nesses arquivos depois (ex.: mover, apagar), vai precisar de `sudo`.
- **`e2fsck` fora do PATH** de usuário comum no Debian — usar `sudo /sbin/e2fsck`.
- **`reboot` dentro do guest** é o único jeito de encerrar o processo Firecracker
  no host — não há ACPI/gerência de energia própria.
- **`sudo -v` falha em execução não-interativa** (sem TTY pra senha) mesmo com
  regra NOPASSWD cobrindo os comandos privilegiados reais usados depois — por
  isso `start-vm.sh` trata essa chamada como non-fatal (`|| true`).
- **Produção**: usar `jailer` em vez de invocar `firecracker` direto (chroot,
  cgroups, seccomp, namespace de rede dedicado) — não implementado neste lab.
