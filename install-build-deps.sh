
#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo." >&2
    exit 1
fi

# Check before modifying installed packages.
if ! command -v dracut >/dev/null 2>&1; then
    echo "ERROR: dracut is required." >&2
    echo "Install/configure dracut separately before continuing." >&2
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
    efibootmgr

echo
echo "=== Build tools ==="

for tool in gcc ld objcopy nm ukify python3 file efibootmgr dracut; do
    command -v "$tool"
done

echo
echo "Build environment ready."
