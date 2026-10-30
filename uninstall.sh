#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — Clean Uninstaller for Linux eBPF Sing-box
# Restores DNS, stops services, and cleans up system files
# =============================================================================
set -euo pipefail

UNINSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$UNINSTALL_DIR/scripts/runtime-paths.sh"
sb_load_paths || exit 1
INSTALL_DIR="$SH_SINGBOX_HOME"

ok()   { echo -e "\033[32m[✓]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
info() { echo -e "\033[36m[ℹ]\033[0m $*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

validate_purge_target() {
    local canonical
    canonical=$(readlink -f "$INSTALL_DIR") || die "Cannot resolve purge directory: $INSTALL_DIR"
    case "$canonical" in
        /|/opt|/usr|/usr/local|/usr/bin|/usr/sbin|/bin|/sbin|/etc|/root|/home|/var|/var/lib|/var/run|/tmp|/run|/overlay|/mnt|/media)
            die "Refusing to purge system directory: $canonical" ;;
    esac
    [ -f "$canonical/scripts/sbctl" ] &&
        grep -Fq 'SH Sing-box Linux Service Controller' "$canonical/scripts/sbctl" ||
        die "Purge directory is not a recognized project installation: $canonical"
}

remove_owned_sbctl_link() {
    local link="$1" target expected
    [ -L "$link" ] || return 0
    target=$(readlink -f "$link") || return 0
    expected=$(readlink -f "$INSTALL_DIR/scripts/sbctl") || return 0
    [ "$target" != "$expected" ] || rm -f "$link"
}

restore_managed_network() {
    local failed=0
    if [ -x "$INSTALL_DIR/scripts/gateway.sh" ]; then
        "$INSTALL_DIR/scripts/gateway.sh" cleanup || failed=1
    fi
    if [ -x "$INSTALL_DIR/scripts/dns-guard.sh" ]; then
        "$INSTALL_DIR/scripts/dns-guard.sh" restore || failed=1
    fi
    [ "$failed" -eq 0 ] || die "Network cleanup failed; runtime files are retained for diagnosis. Resolve the reported error and retry uninstall."
}

[ "$(id -u)" -eq 0 ] || { echo "This script must be run as root" >&2; exit 1; }
PURGE="${1:-}"
case "$PURGE" in
    '') [ "$#" -eq 0 ] || die 'Usage: uninstall.sh [--purge]' ;;
    --purge|-y) [ "$#" -eq 1 ] || die 'Usage: uninstall.sh [--purge]'; validate_purge_target ;;
    *) die 'Usage: uninstall.sh [--purge]' ;;
esac

echo "════════════════════════════════════════════════════════════════"
echo "  SH Sing-box Linux eBPF Uninstaller"
echo "════════════════════════════════════════════════════════════════"
echo ""

# 1. Stop and Disable Service
info "Stopping and disabling service..."
if command -v systemctl >/dev/null 2>&1 &&
   grep -Fq 'Description=SH Sing-box eBPF Transparent Proxy (reF1nd)' /etc/systemd/system/sing-box.service 2>/dev/null; then
    systemctl stop sing-box.service || die "Could not stop the project service; uninstall cancelled"
    restore_managed_network
    systemctl disable sing-box.service || die "Could not disable the project service"
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box.slice
    systemctl daemon-reload 2>/dev/null || true
    ok "Removed systemd service units"
fi

if [ -x /etc/init.d/sing-box ]; then
    if grep -Fq 'OpenWrt procd service init script for sing-box eBPF (reF1nd)' /etc/init.d/sing-box; then
        /etc/init.d/sing-box stop || die "Could not stop/clean up the project service; uninstall cancelled"
        restore_managed_network
        /etc/init.d/sing-box disable || die "Could not disable the project service"
        rm -f /etc/init.d/sing-box
        ok "Removed OpenWrt init.d script"
    else
        die "Unrecognized /etc/init.d/sing-box service; uninstall cancelled to preserve that installation"
    fi
fi

# 2. Restore DNS
info "Restoring DNS configurations..."
restore_managed_network
ok "Managed DNS and gateway cleanup completed"

# 3. Remove CLI symlinks
info "Removing CLI links..."
remove_owned_sbctl_link /usr/local/bin/sbctl
remove_owned_sbctl_link /usr/bin/sbctl
source_dir=$UNINSTALL_DIR
if [ -r "$INSTALL_DIR/runtime/source-dir" ]; then
    IFS= read -r source_dir < "$INSTALL_DIR/runtime/source-dir" || source_dir=$UNINSTALL_DIR
fi
if [ -f /usr/bin/sb ] && [ ! -L /usr/bin/sb ]; then
    if grep -Fq "\"$INSTALL_DIR/scripts/menu.sh\"" /usr/bin/sb ||
       { [ -n "$source_dir" ] && grep -Fq "\"$source_dir/menu.sh\"" /usr/bin/sb; }; then
        rm -f /usr/bin/sb
    fi
fi
ok "Removed owned sb/sbctl launcher files"

# 4. Optional Purge
if [ "$PURGE" = "--purge" ] || [ "$PURGE" = "-y" ]; then
    info "Purging all sing-box configurations, logs, and binaries..."
    rm -rf "$INSTALL_DIR"
    ok "Removed $INSTALL_DIR completely"
else
    info "Service uninstalled. Configuration files and caches were preserved at: $INSTALL_DIR"
fi
case "$SH_SINGBOX_CONFIG" in
    "$INSTALL_DIR"/*) ;;
    *) info "External configuration preserved at: $SH_SINGBOX_CONFIG" ;;
esac

echo ""
ok "Uninstallation complete. Project-managed networking cleanup succeeded."
