
#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Lance ce script avec sudo." >&2
    exit 1
fi

apt-get update

apt-get install -y \
    build-essential \
    binutils \
    gnu-efi \
    systemd-ukify \
    python3 \
    file \
    efibootmgr \
    initramfs-tools

echo
echo "=== Outils disponibles ==="
for tool in gcc ld objcopy nm ukify python3 file efibootmgr update-initramfs; do
    command -v "$tool"
done

echo
echo "Environnement de compilation prêt."
