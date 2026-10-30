#!/usr/bin/env bash
# =============================================================================
# update-core.sh — Update reF1nd sing-box core for Linux (amd64 / arm64)
# Supports Ubuntu/Debian (glibc) and OpenWrt (musl)
# =============================================================================
set -euo pipefail
umask 077

SCRIPT_FILE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
. "$(dirname "$SCRIPT_FILE")/runtime-paths.sh"
sb_load_paths || exit 1
. "$(dirname "$SCRIPT_FILE")/download.sh"

SERVICE_DIR="$SH_SINGBOX_HOME"
BIN_DIR="$SERVICE_DIR/bin"
BIN="$BIN_DIR/sing-box"
RUNTIME_DIR="$SERVICE_DIR/runtime"
TMP_DIR=

ok()   { echo -e "\033[32m✓\033[0m $*"; }
err()  { echo -e "\033[31m✗\033[0m $*" >&2; }
warn() { echo -e "\033[33m!\033[0m $*"; }
info() { echo -e "\033[36mℹ\033[0m $*"; }
die()  { err "$*"; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root"
}

# -----------------------------------------------------------------------------
# Hardware and OS Detection
# -----------------------------------------------------------------------------
detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            die "Unsupported CPU architecture: $arch. Supported: x86_64/amd64, aarch64/arm64."
            ;;
    esac
}

detect_libc() {
    if [ -f /etc/openwrt_release ]; then
        echo "musl"
    elif ldd /bin/ls 2>&1 | grep -iq musl; then
        echo "musl"
    else
        echo "glibc"
    fi
}

detect_init() {
    if [ -f /etc/openwrt_release ] || ! command -v systemctl >/dev/null 2>&1; then
        echo "procd"
    else
        echo "systemd"
    fi
}

# -----------------------------------------------------------------------------
# Known release hashes database for integrity verification
# -----------------------------------------------------------------------------
DEFAULT_CORE_VERSION="v1.15.0-alpha.11-reF1nd"
DEFAULT_RAW_TAG="1.15.0-alpha.11-reF1nd"

# SHA256 checksums for 1.15.0-alpha.11-reF1nd
HASH_amd64_glibc="e22fa94f5e380600ed5b8865884b68c15d9336ad5bbab96765dbfac8c2050a15"
HASH_amd64_musl="7179981f14c225e3e872ac60af2086d6d719b4ddfd901c115c86cd9e4581f4fb"
HASH_arm64_glibc="4affe1df3ec83beb251dadf234cbed74e0d03d2c2683f6cfe4233d0893f7b824"
HASH_arm64_musl="6840a1c1ec3d924bf6620126a2736a89098bf562c50eccd2c2de577dc8a75e1c"

calc_sha256() {
    local target="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$target" | awk '{print $1}'
    elif command -v busybox >/dev/null 2>&1 && busybox sha256sum "$target" >/dev/null 2>&1; then
        busybox sha256sum "$target" | awk '{print $1}'
    else
        return 1
    fi
}

release_hash() {
    local version="$1" filename="$2" arch="$3" libc="$4" key digest
    if [ "${version#v}" = "$DEFAULT_RAW_TAG" ]; then
        key="HASH_${arch}_${libc}"
        printf '%s\n' "${!key}"
        return 0
    fi
    command -v jq >/dev/null 2>&1 || die "jq is required to verify a non-default core release"
    sb_download "https://api.github.com/repos/reF1nd/sing-box-releases/releases/tags/$version" \
        "$TMP_DIR/release.json" 60 || die "Cannot read metadata for requested release $version; existing core is unchanged"
    digest=$(jq -er --arg asset "$filename" '
      [.assets[]? | select(.name == $asset)]
      | if length == 1 then .[0].digest else error("requested asset is unavailable") end
      | select(type == "string" and test("^sha256:[0-9a-fA-F]{64}$"))
    ' "$TMP_DIR/release.json") ||
        die "Release $version has no uniquely identified SHA256-verified asset $filename; existing core is unchanged"
    printf '%s\n' "${digest#sha256:}" | tr 'A-F' 'a-f'
}

restart_core_service() {
    local init_sys="$1"
    if [ -x "$SERVICE_DIR/scripts/sbctl" ]; then
        "$SERVICE_DIR/scripts/sbctl" restart
    elif [ "$init_sys" = systemd ]; then
        systemctl restart sing-box.service
    else
        /etc/init.d/sing-box restart
    fi
}

check_candidate_config() {
    local candidate="$1" max_seconds="${SB_CHECK_TIMEOUT:-90}"
    [[ "$max_seconds" =~ ^[0-9]+$ ]] && [ "$max_seconds" -gt 0 ] || {
        err "SB_CHECK_TIMEOUT must be a positive integer"
        return 1
    }
    if command -v timeout >/dev/null 2>&1; then
        (cd "$SERVICE_DIR" && timeout "$max_seconds" "$candidate" check -c "$SH_SINGBOX_CONFIG")
    elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx timeout; then
        (cd "$SERVICE_DIR" && busybox timeout "$max_seconds" "$candidate" check -c "$SH_SINGBOX_CONFIG")
    else
        err "A timeout utility is required to validate an existing configuration before a core update"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Main Update Process
# -----------------------------------------------------------------------------
do_update() {
    require_root
    local version="${1:-$DEFAULT_CORE_VERSION}"
    [ "$#" -le 1 ] || die "Usage: update-core.sh [RELEASE_TAG]"
    version="v${version#v}"
    [[ "$version" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] || die "Invalid release tag: $version"
    local tag="${version#v}"

    local arch libc init_sys
    arch="$(detect_arch)"
    libc="$(detect_libc)"
    init_sys="$(detect_init)"
    sb_download_load || die "Invalid download configuration; existing core is unchanged"

    info "Target Architecture: $arch"
    info "Target C Library:    $libc"
    info "Target Core Version: $version"

    local filename="sing-box-${tag}-linux-${arch}-${libc}.tar.gz"
    local github_url="https://github.com/reF1nd/sing-box-releases/releases/download/${version}/${filename}"

    mkdir -p "$RUNTIME_DIR"
    TMP_DIR="$(mktemp -d "$RUNTIME_DIR/core-update.XXXXXX")" || die "Cannot create core staging directory"
    trap 'rm -rf "$TMP_DIR"' EXIT
    local expected_hash actual_hash
    expected_hash="$(release_hash "$version" "$filename" "$arch" "$libc")" || return 1
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || die "No verified checksum for $filename"
    local archive="$TMP_DIR/$filename"

    info "Downloading $filename..."
    sb_download "$github_url" "$archive" 300 || die "Failed to download core archive using the configured download mode; existing core is unchanged"
    ok "Downloaded successfully: $archive"

    # Hashes are bound to the selected release, not reused across versions.
    actual_hash="$(calc_sha256 "$archive")" || die "Cannot compute SHA256; install sha256sum before updating the core"
    [ "$actual_hash" = "$expected_hash" ] || die "SHA256 checksum mismatch; existing core is unchanged"
    ok "SHA256 verified: $actual_hash"

    # Unpack
    info "Extracting binary..."
    rm -rf "$TMP_DIR/extracted"
    mkdir -p "$TMP_DIR/extracted"
    tar -xzf "$archive" -C "$TMP_DIR/extracted"

    # Find the sing-box binary in extracted directory
    local candidate
    candidate="$(find "$TMP_DIR/extracted" -type f -name "sing-box" | head -n 1)"
    [ -n "$candidate" ] || die "Extracted archive does not contain a sing-box binary"

    chmod 0755 "$candidate"

    # Self-test the new binary
    info "Verifying core executable..."
    local new_ver
    new_ver="$("$candidate" version 2>/dev/null | head -n 1)" || die "New sing-box binary failed self-test"
    ok "New core test passed: $new_ver"

    if [ -f "$SH_SINGBOX_CONFIG" ]; then
        info "Checking existing configuration with the new core: $SH_SINGBOX_CONFIG"
        check_candidate_config "$candidate" > "$TMP_DIR/config-check.log" 2>&1 || {
            cp "$TMP_DIR/config-check.log" "$RUNTIME_DIR/core-update-check.log"
            chmod 0600 "$RUNTIME_DIR/core-update-check.log"
            die "New core rejects the existing configuration; current core and service are unchanged. Review $RUNTIME_DIR/core-update-check.log"
        }
    fi

    # Check if sing-box is currently running
    local was_running=0
    if [ "$init_sys" = "systemd" ]; then
        if systemctl is-active --quiet sing-box.service 2>/dev/null; then
            was_running=1
        fi
    elif [ "$init_sys" = "procd" ]; then
        if [ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box status >/dev/null 2>&1; then
            was_running=1
        fi
    fi

    # Keep a rollback binary on the same filesystem until restart succeeds.
    mkdir -p "$BIN_DIR"
    local previous=
    if [ -f "$BIN" ]; then
        previous="$(mktemp "$BIN_DIR/.sing-box.previous.XXXXXX")" || die "Cannot back up existing core"
        cp -p "$BIN" "$previous" || die "Cannot back up existing core"
    fi
    mv -f "$candidate" "$BIN"
    chmod 0755 "$BIN"
    rm -rf "$TMP_DIR"
    rm -f "$RUNTIME_DIR/config.valid" 2>/dev/null || true
    ok "Core binary replaced at $BIN"

    if [ "$was_running" -eq 1 ]; then
        info "Restarting sing-box service to apply new core..."
        if ! restart_core_service "$init_sys"; then
            if [ -n "$previous" ]; then
                mv -f "$previous" "$BIN"
                warn "New core restart failed; previous binary restored. Attempting to restore service."
                restart_core_service "$init_sys" || warn "Previous core restored, but service recovery failed; inspect service logs."
            fi
            die "Core update did not complete successfully"
        fi
        ok "Sing-box restarted with new core"
    else
        info "Sing-box was not running; service not restarted"
    fi
    [ -z "$previous" ] || rm -f "$previous"
}

do_update "$@"
