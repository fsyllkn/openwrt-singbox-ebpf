#!/usr/bin/env bash
# =============================================================================
# dns-guard.sh — System DNS takeover and restore for sing-box eBPF
#
# Handles the conflict between systemd-resolved / NetworkManager and
# sing-box's eBPF DNS hijack. With dns_mode=respect_policy, UID selection
# happens before port 53 interception; excluded UIDs need a real resolver.
# The system resolver must not bind 127.0.0.53:53 (systemd-resolved stub)
# or any other local DNS that would conflict.
#
# Usage:
#   dns-guard.sh setup    — Take over system DNS (called by install.sh)
#   dns-guard.sh restore  — Restore original DNS (called by uninstall.sh)
#   dns-guard.sh status   — Show current DNS configuration
# =============================================================================
set -euo pipefail

SCRIPT_FILE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
. "$(dirname "$SCRIPT_FILE")/runtime-paths.sh"
sb_load_paths || exit 1

BACKUP_DIR="$SH_SINGBOX_HOME/runtime/dns-backup"
RESOLV_BACKUP="$BACKUP_DIR/resolv.conf.bak"
RESOLVED_BACKUP="$BACKUP_DIR/resolved.conf.bak"
NM_CONF="/etc/NetworkManager/conf.d/99-sing-box-dns.conf"
NM_BACKUP="$BACKUP_DIR/nm-dns-mode.bak"
DIRECT_DNS_FILE="$SH_SINGBOX_HOME/runtime/direct-dns.conf"

ok()   { echo -e "\033[32m✓\033[0m $*"; }
err()  { echo -e "\033[31m✗\033[0m $*" >&2; }
warn() { echo -e "\033[33m!\033[0m $*"; }
info() { echo -e "\033[36mℹ\033[0m $*"; }

die() { err "$*"; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root"
}

# Detect which DNS resolver is active.
detect_resolver() {
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"
    elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "systemd-resolved"
    elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        # Check if NM manages DNS
        local nm_dns
        nm_dns="$(grep -sP '^\s*dns\s*=' /etc/NetworkManager/NetworkManager.conf 2>/dev/null | tail -1 | awk -F= '{print $2}' | tr -d ' ')"
        if [ "$nm_dns" = "none" ] || [ "$nm_dns" = "unmanaged" ]; then
            echo "manual"
        else
            echo "networkmanager"
        fi
    else
        echo "manual"
    fi
}

# -----------------------------------------------------------------------------
# Setup: take over DNS
# -----------------------------------------------------------------------------
do_setup() {
    require_root
    mkdir -p "$BACKUP_DIR" 2>/dev/null

    local direct_dns="" octet
    if [ -f "$DIRECT_DNS_FILE" ]; then
        direct_dns="$(head -n 1 "$DIRECT_DNS_FILE" | tr -d '\r')"
        [[ "$direct_dns" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid direct DNS IPv4 address"
        local -a octets
        IFS=. read -r -a octets <<< "$direct_dns"
        for octet in "${octets[@]}"; do
            [ "$octet" -le 255 ] || die "Invalid direct DNS IPv4 address"
        done
        [ "${octets[0]}" -ne 0 ] && [ "${octets[0]}" -ne 127 ] || die "Direct DNS cannot be unspecified or loopback"
    fi

    local resolver
    resolver="$(detect_resolver)"
    info "Detected DNS resolver: $resolver"

    case "$resolver" in
        openwrt)
            setup_openwrt
            ;;
        systemd-resolved)
            setup_resolved
            ;;
        networkmanager)
            setup_networkmanager
            ;;
        manual)
            setup_manual
            ;;
    esac

    # An excluded eBPF UID must have a reachable resolver. Other UIDs still
    # have port 53 intercepted by the local eBPF inbound in respect_policy mode.
    if [ -n "$direct_dns" ] && [ "$resolver" != "openwrt" ]; then
        printf '# Managed by sing-box eBPF dns-guard; excluded UID uses this resolver directly.\nnameserver %s\n' "$direct_dns" > /etc/resolv.conf
        ok "Set /etc/resolv.conf → $direct_dns (direct for excluded UIDs)"
    elif [ -n "$direct_dns" ]; then
        warn "OpenWrt: direct-dns.conf is advisory only; keeping netifd-managed /etc/resolv.conf unchanged"
    fi

    # Write a marker for restore to know what was configured.
    echo "$resolver" > "$BACKUP_DIR/resolver-type"
    ok "DNS guard setup complete"
}

setup_resolved() {
    info "Configuring systemd-resolved for sing-box eBPF..."

    # Backup current resolved.conf if not already backed up
    if [ ! -f "$RESOLVED_BACKUP" ] && [ -f /etc/systemd/resolved.conf ]; then
        cp -a /etc/systemd/resolved.conf "$RESOLVED_BACKUP"
        ok "Backed up /etc/systemd/resolved.conf"
    fi

    # Backup resolv.conf
    if [ ! -f "$RESOLV_BACKUP" ]; then
        if [ -L /etc/resolv.conf ]; then
            readlink -f /etc/resolv.conf > "$BACKUP_DIR/resolv.conf.link"
        fi
        cp -aL /etc/resolv.conf "$RESOLV_BACKUP" 2>/dev/null || true
        ok "Backed up /etc/resolv.conf"
    fi

    # Disable the stub listener so it doesn't bind 127.0.0.53:53
    # This is the key step — eBPF will capture all port 53 traffic.
    if ! grep -q '^DNSStubListener=no' /etc/systemd/resolved.conf 2>/dev/null; then
        # Create a drop-in to avoid modifying the original file destructively
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/99-sing-box.conf <<'DROPIN'
# Installed by sing-box eBPF dns-guard.
# Disables the stub listener so eBPF can capture all DNS traffic.
[Resolve]
DNSStubListener=no
DROPIN
        ok "Created resolved drop-in: DNSStubListener=no"
    fi

    # Restart resolved to release port 53
    systemctl restart systemd-resolved 2>/dev/null || warn "Failed to restart systemd-resolved"

    # Point resolv.conf to localhost — all DNS queries go through sing-box eBPF
    # (eBPF hijacks port 53 at the cgroup level, so the target 127.0.0.1 is
    # captured before it reaches any local listener)
    rm -f /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf <<'RESOLV'
# Managed by sing-box eBPF dns-guard.
# All DNS queries are captured by eBPF at the cgroup level.
nameserver 127.0.0.1
options edns0 trust-ad
RESOLV
    ok "Set /etc/resolv.conf → 127.0.0.1 (eBPF captured)"
}

setup_networkmanager() {
    info "Configuring NetworkManager for sing-box eBPF..."

    # Backup resolv.conf
    if [ ! -f "$RESOLV_BACKUP" ]; then
        if [ -L /etc/resolv.conf ]; then
            readlink -f /etc/resolv.conf > "$BACKUP_DIR/resolv.conf.link"
        fi
        cp -aL /etc/resolv.conf "$RESOLV_BACKUP" 2>/dev/null || true
        ok "Backed up /etc/resolv.conf"
    fi

    # Backup current NM DNS mode
    local current_dns
    current_dns="$(grep -sP '^\s*dns\s*=' /etc/NetworkManager/NetworkManager.conf 2>/dev/null | tail -1 | awk -F= '{print $2}' | tr -d ' ')"
    echo "${current_dns:-default}" > "$NM_BACKUP"

    # Tell NM to stop managing /etc/resolv.conf
    mkdir -p /etc/NetworkManager/conf.d 2>/dev/null
    cat > "$NM_CONF" <<'NMCONF'
# Installed by sing-box eBPF dns-guard.
# Prevents NetworkManager from overwriting /etc/resolv.conf.
[main]
dns=none
NMCONF
    ok "Created NetworkManager drop-in: dns=none"

    # Reload NM
    systemctl reload NetworkManager 2>/dev/null || nmcli general reload 2>/dev/null || warn "Failed to reload NetworkManager"

    # Set resolv.conf
    rm -f /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf <<'RESOLV'
# Managed by sing-box eBPF dns-guard.
nameserver 127.0.0.1
options edns0 trust-ad
RESOLV
    ok "Set /etc/resolv.conf → 127.0.0.1 (eBPF captured)"
}

setup_openwrt() {
    # OpenWrt owns /etc/resolv.conf via netifd and dnsmasq. Replacing its
    # symlink with 127.0.0.1 can break resolver updates or bootstrap of
    # eBPF-excluded X-Tunnel processes. Never modify it automatically.
    info "OpenWrt: preserving netifd/dnsmasq DNS and /etc/resolv.conf"
    info "LAN client DNS interception is handled by the selected eBPF shared or gateway TProxy mode."
}

setup_manual() {
    info "Manual DNS configuration detected..."

    if [ ! -f "$RESOLV_BACKUP" ]; then
        if [ -L /etc/resolv.conf ]; then
            readlink -f /etc/resolv.conf > "$BACKUP_DIR/resolv.conf.link"
        fi
        cp -aL /etc/resolv.conf "$RESOLV_BACKUP" 2>/dev/null || true
        ok "Backed up /etc/resolv.conf"
    fi

    rm -f /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf <<'RESOLV'
# Managed by sing-box eBPF dns-guard.
nameserver 127.0.0.1
options edns0 trust-ad
RESOLV
    ok "Set /etc/resolv.conf → 127.0.0.1 (eBPF captured)"
}

# -----------------------------------------------------------------------------
# Restore: undo DNS changes
# -----------------------------------------------------------------------------
do_restore() {
    require_root

    if [ ! -d "$BACKUP_DIR" ]; then
        warn "No DNS backup found; nothing to restore"
        return 0
    fi

    local resolver
    resolver="$(cat "$BACKUP_DIR/resolver-type" 2>/dev/null || echo "manual")"
    info "Restoring DNS for resolver type: $resolver"

    case "$resolver" in
        openwrt)
            # New OpenWrt installs do not modify resolv.conf. If a legacy
            # installation previously changed DNS, only restore its backup.
            if [ -f "$RESOLV_BACKUP" ] || [ -f "$BACKUP_DIR/resolv.conf.link" ]; then
                restore_openwrt
            fi
            ;;
        systemd-resolved)
            restore_resolved
            ;;
        networkmanager)
            restore_networkmanager
            ;;
        manual)
            restore_manual
            ;;
    esac

    ok "DNS guard restore complete"
}

restore_resolved() {
    # Remove our drop-in
    rm -f /etc/systemd/resolved.conf.d/99-sing-box.conf 2>/dev/null
    rmdir /etc/systemd/resolved.conf.d 2>/dev/null || true

    # Restore original resolv.conf
    if [ -f "$BACKUP_DIR/resolv.conf.link" ]; then
        local orig_link
        orig_link="$(cat "$BACKUP_DIR/resolv.conf.link")"
        ln -sf "$orig_link" /etc/resolv.conf 2>/dev/null || true
        ok "Restored resolv.conf symlink → $orig_link"
    elif [ -f "$RESOLV_BACKUP" ]; then
        cp -a "$RESOLV_BACKUP" /etc/resolv.conf
        ok "Restored /etc/resolv.conf from backup"
    fi

    systemctl restart systemd-resolved 2>/dev/null || true
    ok "Restarted systemd-resolved"
}

restore_networkmanager() {
    # Remove our NM drop-in
    rm -f "$NM_CONF" 2>/dev/null

    # Restore resolv.conf
    if [ -f "$BACKUP_DIR/resolv.conf.link" ]; then
        local orig_link
        orig_link="$(cat "$BACKUP_DIR/resolv.conf.link")"
        ln -sf "$orig_link" /etc/resolv.conf 2>/dev/null || true
    elif [ -f "$RESOLV_BACKUP" ]; then
        cp -a "$RESOLV_BACKUP" /etc/resolv.conf
    fi

    systemctl reload NetworkManager 2>/dev/null || nmcli general reload 2>/dev/null || true
    ok "Restored NetworkManager DNS management"
}

restore_openwrt() {
    info "Restoring OpenWrt DNS..."

    if [ -f "$BACKUP_DIR/resolv.conf.link" ]; then
        local orig_link
        orig_link="$(cat "$BACKUP_DIR/resolv.conf.link")"
        ln -sf "$orig_link" /etc/resolv.conf 2>/dev/null || true
        ok "Restored resolv.conf symlink → $orig_link"
    elif [ -f "$RESOLV_BACKUP" ]; then
        cp -a "$RESOLV_BACKUP" /etc/resolv.conf
        ok "Restored /etc/resolv.conf from backup"
    fi

    if [ -x /etc/init.d/dnsmasq ]; then
        /etc/init.d/dnsmasq restart 2>/dev/null || true
    fi
}

restore_manual() {
    if [ -f "$BACKUP_DIR/resolv.conf.link" ]; then
        local orig_link
        orig_link="$(cat "$BACKUP_DIR/resolv.conf.link")"
        ln -sf "$orig_link" /etc/resolv.conf 2>/dev/null || true
    elif [ -f "$RESOLV_BACKUP" ]; then
        cp -a "$RESOLV_BACKUP" /etc/resolv.conf
    fi
    ok "Restored /etc/resolv.conf"
}

# -----------------------------------------------------------------------------
# Status
# -----------------------------------------------------------------------------
do_status() {
    echo "════════════════════════════════════════════"
    echo "  DNS Guard Status"
    echo "════════════════════════════════════════════"
    echo ""

    local resolver
    resolver="$(detect_resolver)"
    info "Active resolver: $resolver"

    # Check resolv.conf
    if [ -f /etc/resolv.conf ]; then
        local ns
        ns="$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | head -3)"
        info "resolv.conf nameservers:"
        echo "    $ns"
    fi

    # Check if port 53 is in use
    if command -v ss >/dev/null 2>&1; then
        local listeners
        listeners="$(ss -tlnp '( sport = 53 )' 2>/dev/null | tail -n +2)"
        if [ -n "$listeners" ]; then
            warn "Port 53 TCP listeners:"
            echo "    $listeners"
        else
            ok "No TCP listener on port 53 (eBPF will capture directly)"
        fi
        listeners="$(ss -ulnp '( sport = 53 )' 2>/dev/null | tail -n +2)"
        if [ -n "$listeners" ]; then
            warn "Port 53 UDP listeners:"
            echo "    $listeners"
        else
            ok "No UDP listener on port 53 (eBPF will capture directly)"
        fi
    fi

    # Check systemd-resolved stub
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        if grep -q '^DNSStubListener=no' /etc/systemd/resolved.conf.d/99-sing-box.conf 2>/dev/null; then
            ok "systemd-resolved stub listener: disabled (by sing-box)"
        elif grep -q '^DNSStubListener=no' /etc/systemd/resolved.conf 2>/dev/null; then
            ok "systemd-resolved stub listener: disabled"
        else
            warn "systemd-resolved stub listener: may be active (potential conflict)"
        fi
    fi

    # Check backup status
    if [ -d "$BACKUP_DIR" ]; then
        info "DNS backup directory: $BACKUP_DIR"
        ls -la "$BACKUP_DIR/" 2>/dev/null | tail -n +2 | sed 's/^/    /'
    else
        info "No DNS backup (guard not yet configured)"
    fi
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
case "${1:-status}" in
    setup)   do_setup ;;
    restore) do_restore ;;
    status)  do_status ;;
    *)
        echo "Usage: $0 {setup|restore|status}"
        exit 2
        ;;
esac
