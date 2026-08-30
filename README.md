# firecracker
estudo sobre o virtualizador firecracker

No host (`taquion`), kernel, rootfs, sockets, pids e logs das microVMs ficam
em `/data/firecracker` (fora do home, não versionado). Os arquivos em `src/`
são as versões de referência; o deploy real roda a partir de `/data/firecracker`.
