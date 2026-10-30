#!/usr/bin/env bash
set -euo pipefail

# Prepare a reproducible EFI source tree from pinned upstream code and a patch.
# This script never modifies the ESP, GRUB, or installed kernels.

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
UPSTREAM_URL="https://github.com/bbatchelder/macbookpro11-5-intel-efi.git"
UPSTREAM_SOURCE="intel-before-linux.c"

PIN_FILE="$ROOT/upstream.commit"
PATCH_FILE="$ROOT/patches/ubuntu-uki.patch"
BUILD_DIR="$ROOT/build"
SOURCE_DIR="$BUILD_DIR/source"
LOCK_FILE="$BUILD_DIR/.setup.lock"

# -----------------------------------------------------------------------------
# Helpers and cleanup
# -----------------------------------------------------------------------------

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

TEMP_DIR=""
BACKUP_DIR=""
INSTALLED_NEW=0

cleanup() {
    local status=$?
    trap - EXIT

    if (( status != 0 )) && [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        if (( INSTALLED_NEW )); then
            rm -rf -- "$SOURCE_DIR"
        fi
        mv -- "$BACKUP_DIR" "$SOURCE_DIR" || {
            printf 'ERROR: Recovery failed; previous sources are at %s\n' "$BACKUP_DIR" >&2
            exit "$status"
        }
    fi

    [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
    exit "$status"
}

# -----------------------------------------------------------------------------
# Dependencies and configuration validation
# -----------------------------------------------------------------------------

for tool in git patch sha256sum mktemp flock cmp find; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing command: $tool"
done

[[ -s "$PIN_FILE" ]] || fail "Missing upstream.commit"
[[ -s "$PATCH_FILE" ]] || fail "Missing patches/ubuntu-uki.patch"

COMMIT=$(tr -d '\r\n' < "$PIN_FILE")
[[ "$COMMIT" =~ ^[a-fA-F0-9]{40}$ ]] || fail "upstream.commit must contain a full 40-character Git commit hash"
COMMIT=${COMMIT,,}
PATCH_SHA=$(sha256sum "$PATCH_FILE")
PATCH_SHA=${PATCH_SHA%% *}

mkdir -p -- "$BUILD_DIR"
exec 9>"$LOCK_FILE"
flock -x 9 || fail "Unable to acquire setup lock"

# -----------------------------------------------------------------------------
# Verify whether existing generated sources are safe to reuse or replace
# -----------------------------------------------------------------------------

# A generated directory is trusted only if its manifest matches its contents.
# Any manually modified or unexpected files cause a safe refusal.
source_is_managed() {
    [[ -d "$SOURCE_DIR" && ! -L "$SOURCE_DIR" ]] || return 1
    [[ -f "$SOURCE_DIR/intel-gmux.c" && -f "$SOURCE_DIR/.setup-manifest" ]] || return 1

    local version saved_commit saved_patch saved_source actual_source extra
    IFS=' ' read -r version saved_commit saved_patch saved_source < "$SOURCE_DIR/.setup-manifest"
    [[ "$version" == "v1" && "$saved_commit" =~ ^[a-f0-9]{40}$ && "$saved_patch" =~ ^[a-f0-9]{64}$ && "$saved_source" =~ ^[a-f0-9]{64}$ ]] || return 1

    actual_source=$(sha256sum "$SOURCE_DIR/intel-gmux.c")
    actual_source=${actual_source%% *}
    [[ "$actual_source" == "$saved_source" ]] || return 1

    # No additional files, directories, or symlinks may be silently overwritten.
    extra=$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 \
        ! -name intel-gmux.c ! -name .setup-manifest -print -quit)
    [[ -z "$extra" ]] || return 1

    # All expected entries must be ordinary files, not symlinks.
    [[ ! -L "$SOURCE_DIR/intel-gmux.c" && ! -L "$SOURCE_DIR/.setup-manifest" ]]
}

if [[ -e "$SOURCE_DIR" || -L "$SOURCE_DIR" ]]; then
    source_is_managed || fail "Existing source directory contains unrecognized or modified files: $SOURCE_DIR"

    read -r _ saved_commit saved_patch _ < "$SOURCE_DIR/.setup-manifest"
    if [[ "$saved_commit" == "$COMMIT" && "$saved_patch" == "$PATCH_SHA" ]]; then
        info "Sources are already up to date; no changes made."
        exit 0
    fi

    info "Configuration changed; preparing updated sources."
fi

# -----------------------------------------------------------------------------
# Fetch and patch upstream in a temporary directory (no changes to output)
# -----------------------------------------------------------------------------

TEMP_DIR=$(mktemp -d -p "$BUILD_DIR" .setup-tmp.XXXXXXXX) || fail "Unable to create temporary directory"
trap cleanup EXIT

info "Fetching pinned upstream revision $COMMIT..."
git clone --quiet "$UPSTREAM_URL" "$TEMP_DIR/upstream" || fail "Unable to clone upstream repository"
git -C "$TEMP_DIR/upstream" checkout --quiet --detach "$COMMIT" || fail "Pinned upstream revision is unavailable"

actual_commit=$(git -C "$TEMP_DIR/upstream" rev-parse HEAD)
[[ "$actual_commit" == "$COMMIT" ]] || fail "Upstream revision mismatch"
[[ -f "$TEMP_DIR/upstream/$UPSTREAM_SOURCE" ]] || fail "Missing upstream source: $UPSTREAM_SOURCE"

mkdir -- "$TEMP_DIR/prepared"
cp -- "$TEMP_DIR/upstream/$UPSTREAM_SOURCE" "$TEMP_DIR/prepared/intel-gmux.c"

info "Applying Ubuntu patch..."
(
    cd "$TEMP_DIR/prepared"
    patch --batch --fuzz=0 --forward -p1 < "$PATCH_FILE"
) || fail "Patch does not apply cleanly"

[[ -s "$TEMP_DIR/prepared/intel-gmux.c" ]] || fail "Patched source is empty"

SOURCE_SHA=$(sha256sum "$TEMP_DIR/prepared/intel-gmux.c")
SOURCE_SHA=${SOURCE_SHA%% *}
printf 'v1 %s %s %s\n' "$COMMIT" "$PATCH_SHA" "$SOURCE_SHA" > "$TEMP_DIR/prepared/.setup-manifest"

# -----------------------------------------------------------------------------
# Publish prepared sources, preserving the last valid version on failure
# -----------------------------------------------------------------------------

if [[ -d "$SOURCE_DIR" ]]; then
    BACKUP_DIR=$(mktemp -d -p "$BUILD_DIR" .setup-backup.XXXXXXXX)
    rmdir -- "$BACKUP_DIR"
    mv -- "$SOURCE_DIR" "$BACKUP_DIR"
fi

mv -- "$TEMP_DIR/prepared" "$SOURCE_DIR"
INSTALLED_NEW=1

# Once publication succeeds, remove the previous generated version.
if [[ -n "$BACKUP_DIR" ]]; then
    rm -rf -- "$BACKUP_DIR"
    BACKUP_DIR=""
fi

info "Sources prepared successfully."
sha256sum "$SOURCE_DIR/intel-gmux.c"
