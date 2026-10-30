#!/usr/bin/env bash
set -euo pipefail

# Build an EFI helper and a UKI candidate without changing the ESP or GRUB.
# Run as root to read Ubuntu's root-only initramfs.

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE="$ROOT/build/source/intel-gmux.c"
CMDLINE="$ROOT/cmdline.txt"
BUILD_DIR="$ROOT/build"
OUTPUT="$BUILD_DIR/candidate"
LOCK="$BUILD_DIR/.build.lock"
HELPER_NAME="intel-before-candidate.efi"
UKI_NAME="ubuntu-intel-candidate.efi"
LOG_NAME="intel-before-candidate.log"

# -----------------------------------------------------------------------------
# Messages and cleanup
# -----------------------------------------------------------------------------

info() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

TEMP=""
cleanup() {
    if [[ -n "$TEMP" && -d "$TEMP" ]]; then
        rm -rf -- "$TEMP"
    fi
}
trap cleanup EXIT

usage() {
    printf 'Usage: sudo %s [installed-kernel-version]\n' "${0##*/}" >&2
    printf 'Without an argument, the newest installed kernel with an initramfs is selected.\n' >&2
    exit 2
}

# -----------------------------------------------------------------------------
# Kernel selection
# -----------------------------------------------------------------------------

select_kernel() {
    local kernel version
    local -a versions=()

    # Use installed /boot artifacts, not the currently running kernel.
    # Only kernels with a matching, nonempty initramfs are eligible.
    for kernel in /boot/vmlinuz-*; do
        [[ -f "$kernel" && -s "$kernel" ]] || continue
        version=${kernel##*/vmlinuz-}
        [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || continue
        [[ -f "/boot/initrd.img-$version" && -s "/boot/initrd.img-$version" ]] || continue
        versions+=("$version")
    done

    ((${#versions[@]} > 0)) || fail "No installed kernel with a matching initramfs was found in /boot"
    printf '%s\n' "${versions[@]}" | LC_ALL=C sort -V | tail -n 1
}

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

[[ $# -le 1 ]] || usage
[[ $(id -u) -eq 0 ]] || fail "Run with sudo to read the initramfs"

if [[ $# -eq 1 ]]; then
    KERNEL_VERSION=$1
    [[ "$KERNEL_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || fail "Invalid kernel version"
else
    command -v sort >/dev/null 2>&1 || fail "Missing command: sort"
    KERNEL_VERSION=$(select_kernel)
    info "Automatically selected installed kernel: $KERNEL_VERSION"
fi

for tool in gcc ld nm objcopy ukify python3 sha256sum flock cmp file findmnt; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing command: $tool"
done

KERNEL="/boot/vmlinuz-$KERNEL_VERSION"
INITRD="/boot/initrd.img-$KERNEL_VERSION"
[[ -s "$SOURCE" ]] || fail "Missing prepared source: $SOURCE (run setup.sh first)"
[[ -s "$CMDLINE" ]] || fail "Missing kernel command line: $CMDLINE"
[[ -s "$KERNEL" ]] || fail "Missing kernel: $KERNEL"
[[ -s "$INITRD" ]] || fail "Missing initramfs: $INITRD"
[[ -f /usr/lib/elf_x86_64_efi.lds && -f /usr/lib/crt0-efi-x86_64.o ]] || fail "Missing GNU-EFI development files"
[[ -f /usr/include/efi/efi.h ]] || fail "Missing GNU-EFI headers"

# -----------------------------------------------------------------------------
# Root filesystem and kernel command line
# -----------------------------------------------------------------------------

# Only support a directly mounted ext4 root filesystem for this MBP setup.
# More complex roots (LUKS, LVM, Btrfs subvolumes) need separate handling.
ROOT_FS=$(findmnt -n -o FSTYPE --target /)
[[ "$ROOT_FS" == "ext4" ]] || fail "Unsupported root filesystem: $ROOT_FS (expected ext4)"

ROOT_UUID=$(findmnt -n -o UUID --target /)
[[ "$ROOT_UUID" =~ ^[a-fA-F0-9-]{36}$ ]] || fail "Unable to determine a valid root filesystem UUID"

# cmdline.txt contains shared boot parameters only; root= is generated here.
mkdir -p -- "$BUILD_DIR"
TEMP=$(mktemp -d -p "$BUILD_DIR" .build-tmp.XXXXXXXX) || fail "Unable to create temporary directory"
GENERATED_CMDLINE="$TEMP/cmdline.txt"

python3 - "$CMDLINE" "$GENERATED_CMDLINE" "$ROOT_UUID" <<'PY'
from pathlib import Path
import sys

config = Path(sys.argv[1]).read_text().strip()
tokens = config.split()
required = (
    'ro',
    'intel_iommu=off',
    'modprobe.blacklist=amdgpu,radeon',
    'rd.driver.blacklist=amdgpu,radeon',
    'initcall_blacklist=simpledrm_platform_driver_init,efifb_driver_init',
)
if not tokens or any(token.startswith('root=') for token in tokens):
    sys.exit('ERROR: cmdline.txt must contain boot options but no root= parameter')
if not all(token in tokens for token in required):
    sys.exit('ERROR: Kernel command line is missing required Intel boot parameters')
if any(ch in config for ch in '\\r\\n\\x00'):
    sys.exit('ERROR: cmdline.txt must contain a single line')

Path(sys.argv[2]).write_text(
    f'root=UUID={sys.argv[3]} {config}\\n'
)
PY

mkdir -p -- "$BUILD_DIR"
exec 9>"$LOCK"
flock -x 9 || fail "Unable to acquire build lock"

# -----------------------------------------------------------------------------
# Idempotence: verify both inputs and existing outputs
# -----------------------------------------------------------------------------

# Include the compiler and UKI tool versions to invalidate stale artifacts.
INPUT_SHA=$(
    {
        printf '%s\n' "$KERNEL_VERSION"
        sha256sum "$SOURCE" "$GENERATED_CMDLINE" "$KERNEL" "$INITRD"
        gcc --version | head -n 1
        ld --version | head -n 1
        ukify --version
    } | sha256sum | cut -d' ' -f1
)

if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    [[ -d "$OUTPUT" && ! -L "$OUTPUT" ]] || fail "Existing candidate path is not a regular directory"
    if [[ -f "$OUTPUT/.build-manifest" && -f "$OUTPUT/$HELPER_NAME" && -f "$OUTPUT/$UKI_NAME" ]]; then
        read -r saved_input saved_helper saved_uki < "$OUTPUT/.build-manifest"
        if [[ "$saved_input" == "$INPUT_SHA" && \
              "$(sha256sum "$OUTPUT/$HELPER_NAME" | cut -d' ' -f1)" == "$saved_helper" && \
              "$(sha256sum "$OUTPUT/$UKI_NAME" | cut -d' ' -f1)" == "$saved_uki" ]]; then
            info "Candidate is already up to date; no changes made."
            exit 0
        fi
    fi
    fail "Existing candidate differs or is incomplete: $OUTPUT. Review it before replacing."
fi

# -----------------------------------------------------------------------------
# Prepare a candidate-specific source in an isolated working directory
# -----------------------------------------------------------------------------

mkdir -- "$TEMP/out"

python3 - "$SOURCE" "$TEMP/intel-gmux-candidate.c" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
replacements = {
    'ubuntu-intel-no-ghost.efi': 'ubuntu-intel-candidate.efi',
    'intel-before-no-ghost.log': 'intel-before-candidate.log',
}
for old, new in replacements.items():
    count = source.count(old)
    if count == 0:
        sys.exit(f'ERROR: Expected EFI source string not found: {old}')
    source = source.replace(old, new)
if 'ubuntu-intel-no-ghost.efi' in source or 'intel-before-no-ghost.log' in source:
    sys.exit('ERROR: Stable EFI references remain in candidate source')
Path(sys.argv[2]).write_text(source)
PY

# -----------------------------------------------------------------------------
# Compile the EFI helper
# -----------------------------------------------------------------------------

info "Compiling EFI candidate helper..."
gcc -I/usr/include/efi -I/usr/include/efi/x86_64 -DGNU_EFI_USE_MS_ABI \
    -fpic -ffreestanding -fno-stack-protector -fno-stack-check -fshort-wchar \
    -mno-red-zone -maccumulate-outgoing-args -Wall -Wextra -Werror -O2 \
    -c "$TEMP/intel-gmux-candidate.c" -o "$TEMP/intel-gmux.o"

ld -nostdlib -znocombreloc -T /usr/lib/elf_x86_64_efi.lds \
    -shared -Bsymbolic /usr/lib/crt0-efi-x86_64.o \
    "$TEMP/intel-gmux.o" -L/usr/lib -lefi -lgnuefi \
    -o "$TEMP/intel-gmux.so"

if [[ -n "$(nm -u "$TEMP/intel-gmux.so")" ]]; then
    fail "EFI helper contains unresolved symbols"
fi

objcopy -j .text -j .data -j .rodata -j .dynamic -j .dynsym -j .dynstr \
    -j .rel -j .rela -j .reloc -O pei-x86-64 --subsystem=10 \
    "$TEMP/intel-gmux.so" "$TEMP/out/$HELPER_NAME"

# -----------------------------------------------------------------------------
# Build and verify the UKI
# -----------------------------------------------------------------------------

info "Building UKI for kernel $KERNEL_VERSION..."
ukify build --linux="$KERNEL" --initrd="$INITRD" \
    --cmdline="@$GENERATED_CMDLINE" --output="$TEMP/out/$UKI_NAME"

[[ -s "$TEMP/out/$HELPER_NAME" && -s "$TEMP/out/$UKI_NAME" ]] || fail "Missing build outputs"
file "$TEMP/out/$HELPER_NAME" "$TEMP/out/$UKI_NAME"

# Verify the embedded command line against the generated input.
objcopy --dump-section ".cmdline=$TEMP/embedded-cmdline" "$TEMP/out/$UKI_NAME" >/dev/null
python3 - "$GENERATED_CMDLINE" "$TEMP/embedded-cmdline" <<'PY'
from pathlib import Path
import sys
expected = Path(sys.argv[1]).read_bytes().rstrip(b'\x00\r\n')
actual = Path(sys.argv[2]).read_bytes().rstrip(b'\x00\r\n')
if actual != expected:
    sys.exit('ERROR: Embedded UKI command line differs from generated command line')
PY

# -----------------------------------------------------------------------------
# Publish only after all checks succeed
# -----------------------------------------------------------------------------

HELPER_SHA=$(sha256sum "$TEMP/out/$HELPER_NAME" | cut -d' ' -f1)
UKI_SHA=$(sha256sum "$TEMP/out/$UKI_NAME" | cut -d' ' -f1)
printf '%s %s %s\n' "$INPUT_SHA" "$HELPER_SHA" "$UKI_SHA" > "$TEMP/out/.build-manifest"
printf '%s\n' "$KERNEL_VERSION" > "$TEMP/out/kernel-version"

mv -- "$TEMP/out" "$OUTPUT"
info "Candidate built successfully: $OUTPUT"
sha256sum "$OUTPUT/$HELPER_NAME" "$OUTPUT/$UKI_NAME"
info "No files on the ESP or GRUB were changed."
