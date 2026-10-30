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
. "$(dirname "$SCRIPT_FILE")/config-parts-lib.sh"

SERVICE_DIR="$SH_SINGBOX_HOME"
BIN_DIR="$SERVICE_DIR/bin"
BIN="$BIN_DIR/sing-box"
RUNTIME_DIR="$SERVICE_DIR/runtime"
TMP_DIR=
UPDATE_CONFIG=
UPDATE_CONFIG_MODE=
UPDATE_CONFIG_FINGERPRINT=
# Core updates validate the installed service with its deployed composer.
# A source menu/controller may still export a selector from another checkout.
PARTS_TOOL=$SERVICE_DIR/scripts/config-parts.sh
SB_CONFIG_PARTS_TOOL=$PARTS_TOOL
export SB_CONFIG_PARTS_TOOL

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
    local target="$1" sum_line digest
    # OpenWrt enables SHA256SUM by default, but not CKSUM. Use the same
    # supported hash for release verification and configuration fingerprints.
    # Read stdin so filename escaping never becomes part of the digest.
    if command -v sha256sum >/dev/null 2>&1; then
        sum_line=$(sha256sum < "$target") || return 1
    elif command -v busybox >/dev/null 2>&1; then
        sum_line=$(busybox sha256sum < "$target") || return 1
    else
        return 1
    fi
    digest=${sum_line%% *}
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
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
    local candidate="$1" config="$2" max_seconds="${SB_CHECK_TIMEOUT:-90}"
    [[ "$max_seconds" =~ ^[0-9]+$ ]] && [ "$max_seconds" -gt 0 ] || {
        err "SB_CHECK_TIMEOUT must be a positive integer"
        return 1
    }
    if command -v timeout >/dev/null 2>&1; then
        (cd "$SERVICE_DIR" && timeout "$max_seconds" "$candidate" check -c "$config")
    elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx timeout; then
        (cd "$SERVICE_DIR" && busybox timeout "$max_seconds" "$candidate" check -c "$config")
    else
        err "A timeout utility is required to validate an existing configuration before a core update"
        return 1
    fi
}

# Build without render/preflight: the currently installed core must never
# publish a generated configuration on behalf of an unverified new core.
# Require an applied draft so normal restart and binary rollback use the same
# effective configuration; users can apply it explicitly with sbctl preflight.
stage_update_config() {
    local before after
    UPDATE_CONFIG=$SH_SINGBOX_CONFIG
    if sb_parts_active; then
        UPDATE_CONFIG_MODE=parts
        [ -f "$SH_SINGBOX_CONFIG" ] && [ -r "$SH_SINGBOX_CONFIG" ] || {
            err "Generated configuration is missing or unreadable. Run 'sbctl preflight' with the current core to rebuild it before updating the core."
            return 1
        }
        [ -f "$PARTS_TOOL" ] && [ -r "$PARTS_TOOL" ] || { err "Missing or unreadable installed configuration-parts tool: $PARTS_TOOL; update the installed scripts first"; return 1; }
        before=$(bash "$PARTS_TOOL" fingerprint) || return 1
        UPDATE_CONFIG=$TMP_DIR/config-candidate.json
        bash "$PARTS_TOOL" build "$UPDATE_CONFIG" || return 1
        jq -e -s 'length == 2 and .[0] == .[1]' "$SH_SINGBOX_CONFIG" "$UPDATE_CONFIG" >/dev/null || {
            err "Configuration sources contain an unapplied draft or policy change. Run 'sbctl preflight' with the current core before updating the core."
            return 1
        }
        after=$(bash "$PARTS_TOOL" fingerprint) || return 1
        [ "$before" = "$after" ] || { err "Configuration changed while staging the core update; retry after finishing the edit"; return 1; }
        UPDATE_CONFIG_FINGERPRINT=$after
    elif [ -e "$SH_SINGBOX_CONFIG" ] || [ -L "$SH_SINGBOX_CONFIG" ]; then
        UPDATE_CONFIG_MODE=legacy
        [ -f "$SH_SINGBOX_CONFIG" ] && [ -r "$SH_SINGBOX_CONFIG" ] || {
            err "Existing configuration is not a readable file: $SH_SINGBOX_CONFIG"
            return 1
        }
        UPDATE_CONFIG_FINGERPRINT=$(calc_sha256 "$SH_SINGBOX_CONFIG") || {
            err "Cannot fingerprint the existing configuration with SHA-256; sha256sum or the BusyBox sha256sum applet must be available and able to read the file."
            return 1
        }
    else
        UPDATE_CONFIG_MODE=fresh
        UPDATE_CONFIG=
    fi
}

verify_update_config_unchanged() {
    local current
    case "$UPDATE_CONFIG_MODE" in
        parts)
            sb_parts_active || return 1
            current=$(bash "$PARTS_TOOL" fingerprint) || return 1
            [ "$current" = "$UPDATE_CONFIG_FINGERPRINT" ] || return 1
            bash "$PARTS_TOOL" build "$TMP_DIR/config-recheck.json" || return 1
            jq -e -s 'length == 2 and .[0] == .[1]' "$UPDATE_CONFIG" "$TMP_DIR/config-recheck.json" >/dev/null || return 1
            current=$(bash "$PARTS_TOOL" fingerprint) || return 1
            [ "$current" = "$UPDATE_CONFIG_FINGERPRINT" ] ;;
        legacy)
            ! sb_parts_active && [ -f "$SH_SINGBOX_CONFIG" ] || return 1
            current=$(calc_sha256 "$SH_SINGBOX_CONFIG") || {
                err "Cannot recheck the configuration SHA-256; refusing to replace the current core."
                return 1
            }
            [ "$current" = "$UPDATE_CONFIG_FINGERPRINT" ] ;;
        fresh)
            ! sb_parts_active && [ ! -e "$SH_SINGBOX_CONFIG" ] && [ ! -L "$SH_SINGBOX_CONFIG" ] ;;
        *) return 1 ;;
    esac
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
    stage_update_config || die "Configuration preparation failed; current core and service are unchanged"
    local expected_hash actual_hash
    expected_hash="$(release_hash "$version" "$filename" "$arch" "$libc")" || return 1
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || die "No verified checksum for $filename"
    local archive="$TMP_DIR/$filename"

    info "Downloading $filename..."
    sb_download "$github_url" "$archive" 300 || die "Failed to download core archive using the configured download mode; existing core is unchanged"
    ok "Downloaded successfully: $archive"

    # Hashes are bound to the selected release, not reused across versions.
    actual_hash="$(calc_sha256 "$archive")" || die "Cannot compute SHA-256; sha256sum or the BusyBox sha256sum applet must be available and able to read the archive"
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

    if [ -n "$UPDATE_CONFIG" ]; then
        info "Checking existing configuration with the new core: $SH_SINGBOX_CONFIG"
        check_candidate_config "$candidate" "$UPDATE_CONFIG" > "$TMP_DIR/config-check.log" 2>&1 || {
            cp "$TMP_DIR/config-check.log" "$RUNTIME_DIR/core-update-check.log"
            chmod 0600 "$RUNTIME_DIR/core-update-check.log"
            die "New core rejects the existing configuration; current core and service are unchanged. Review $RUNTIME_DIR/core-update-check.log"
        }
    fi
    verify_update_config_unchanged || die "Configuration changed during core validation; finish the edit and retry. Current core and service are unchanged."

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
    if ! verify_update_config_unchanged; then
        [ -z "$previous" ] || rm -f "$previous"
        die "Configuration changed before core replacement; finish the edit and retry. Current core and service are unchanged."
    fi
    mv -f "$candidate" "$BIN"
    chmod 0755 "$BIN"
    rm -f "$RUNTIME_DIR/config.valid" 2>/dev/null || true
    ok "Core binary replaced at $BIN"

    if [ "$was_running" -eq 1 ]; then
        info "Restarting sing-box service to apply new core..."
        if ! restart_core_service "$init_sys"; then
            if [ -n "$previous" ]; then
                mv -f "$previous" "$BIN"
                if ! verify_update_config_unchanged; then
                    warn "Configuration changed during restart. User sources and generated output were preserved; recovery must pass the previous core's normal preparation and validation."
                fi
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
