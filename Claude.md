# Convenções do projeto firecracker

Ver README.md para setup, estrutura e como rodar as microVMs. Aqui só o que
não é óbvio a partir do README/código.

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
