#!/usr/bin/env bash
# =============================================================================
# install.sh — One-Click Installer for Linux eBPF Sing-box (reF1nd)
#
# Supported OS:
#   - Debian 11/12+
#   - Ubuntu 20.04/22.04/24.04+
#   - OpenWrt 22.03/23.05+
#
# Supported Architectures:
#   - AMD64 (x86_64)
#   - ARM64 (aarch64)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$REPO_ROOT/scripts/runtime-paths.sh"
sb_load_paths || exit 1
. "$REPO_ROOT/scripts/download.sh"
INSTALL_DIR="$SH_SINGBOX_HOME"
CONFIG="$SH_SINGBOX_CONFIG"
SCRIPTS_ONLY=0
case "${1:-}" in
    --scripts-only) [ "$#" -eq 1 ] || { echo 'Usage: bash install.sh [--scripts-only]' >&2; exit 2; }; SCRIPTS_ONLY=1 ;;
    '') ;;
    *) echo 'Usage: bash install.sh [--scripts-only]' >&2; exit 2 ;;
esac

# Output formatting
ok()   { echo -e "\033[32m[✓]\033[0m $*"; }
err()  { echo -e "\033[31m[✗]\033[0m $*" >&2; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
info() { echo -e "\033[36m[ℹ]\033[0m $*"; }
die()  { err "$*"; exit 1; }

record_source_directory() {
    local source_record
    mkdir -p "$INSTALL_DIR/runtime"
    source_record="$(mktemp "$INSTALL_DIR/runtime/.source-dir.XXXXXX")" || die "Cannot record source directory"
    printf '%s\n' "$REPO_ROOT" > "$source_record" && chmod 0600 "$source_record" &&
        mv -f "$source_record" "$INSTALL_DIR/runtime/source-dir" ||
        { rm -f "$source_record"; die "Cannot record source directory"; }
}

create_default_config() {
    # Render machine-dependent paths only for a fresh installation. Existing
    # user inbounds, private-IP routes, providers and credentials stay intact.
    [ ! -f "$CONFIG" ] || return 0
    local candidate
    mkdir -p "$(dirname "$CONFIG")"
    candidate="$(mktemp "${CONFIG}.initial.XXXXXX")" || die "Cannot stage initial configuration"
    jq --arg ui_root "$INSTALL_DIR/board/dist" \
        '.experimental.clash_api.external_ui = $ui_root' \
        "$INSTALL_DIR/config/config.template.json" > "$candidate" &&
        chmod 0600 "$candidate" && mv -f "$candidate" "$CONFIG" ||
        { rm -f "$candidate"; die "Cannot render initial configuration"; }
}

check_service_conflicts() {
    local init_path="${1:-/etc/init.d/sing-box}" first_cli="${2:-/usr/bin/sbctl}" second_cli="${3:-/usr/local/bin/sbctl}" path
    if [ -e "$init_path" ] || [ -L "$init_path" ]; then
        grep -Fq 'OpenWrt procd service init script for sing-box eBPF (reF1nd)' "$init_path" 2>/dev/null ||
            die "Existing $init_path belongs to another sing-box installation; preserve/migrate that service before installing this project"
    fi
    for path in "$first_cli" "$second_cli"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            grep -Fq 'SH Sing-box Linux Service Controller' "$path" 2>/dev/null ||
                die "Existing $path is not this project's controller; installation has not changed it"
        fi
    done
}

# Offline repair for an existing OpenWrt installation. Keep the core, JSON,
# providers and gateway settings; install the init script last so it cannot
# reference a helper that has not yet been deployed.
deploy_scripts_only() {
    local init_path="${1:-/etc/init.d/sing-box}" backup file dest temporary mode
    [ -x "$INSTALL_DIR/bin/sing-box" ] || die "Existing core not found: $INSTALL_DIR/bin/sing-box"
    [ -f "$CONFIG" ] || die "Existing configuration not found: $CONFIG"
    [ -f "$init_path" ] || die "Existing procd service not found: $init_path"
    check_service_conflicts "$init_path"
    for file in scripts/sbctl scripts/runtime-paths.sh scripts/download.sh scripts/configure-download.sh scripts/gateway.sh scripts/dns-guard.sh menu.sh uninstall.sh openwrt/sing-box.init config/config.template.json; do
        [ -f "$REPO_ROOT/$file" ] || die "Incomplete source: missing $file"
    done
    [ ! "$CONFIG" -ef "$INSTALL_DIR/config/config.template.json" ] ||
        die "Active configuration is also the template destination; choose a separate config_file before updating"
    for file in "$REPO_ROOT"/scripts/*; do
        [ -f "$file" ] || continue
        bash -n "$file" || die "Shell syntax failed: $file"
    done
    sh -n "$REPO_ROOT/menu.sh" || die "Menu syntax failed"
    sh -n "$REPO_ROOT/openwrt/sing-box.init" || die "Init syntax failed"
    bash -n "$REPO_ROOT/uninstall.sh" || die "Uninstaller syntax failed"
    jq -e 'type == "object"' "$REPO_ROOT/config/config.template.json" >/dev/null || die "Configuration template is not valid JSON"
    backup="$INSTALL_DIR/runtime/scripts-backup.$(date +%Y%m%d-%H%M%S).$$"
    mkdir -p "$backup" "$INSTALL_DIR/scripts" "$INSTALL_DIR/openwrt" "$INSTALL_DIR/config"
    chmod 0700 "$backup"
    cp -a "$INSTALL_DIR/scripts" "$backup/scripts"
    cp -p "$init_path" "$backup/sing-box.init"
    [ ! -f "$INSTALL_DIR/uninstall.sh" ] || cp -p "$INSTALL_DIR/uninstall.sh" "$backup/uninstall.sh"
    [ ! -f "$INSTALL_DIR/config/config.template.json" ] || cp -p "$INSTALL_DIR/config/config.template.json" "$backup/config.template.json"
    for file in "$REPO_ROOT"/scripts/* "$REPO_ROOT/menu.sh" "$REPO_ROOT/uninstall.sh" "$REPO_ROOT/openwrt/sing-box.init" "$REPO_ROOT/config/config.template.json"; do
        [ -f "$file" ] || continue
        mode=0755
        case "$file" in
            "$REPO_ROOT/menu.sh") dest="$INSTALL_DIR/scripts/menu.sh" ;;
            "$REPO_ROOT/uninstall.sh") dest="$INSTALL_DIR/uninstall.sh" ;;
            "$REPO_ROOT/openwrt/sing-box.init") dest="$INSTALL_DIR/openwrt/sing-box.init" ;;
            "$REPO_ROOT/config/config.template.json") dest="$INSTALL_DIR/config/config.template.json"; mode=0644 ;;
            *) dest="$INSTALL_DIR/scripts/$(basename "$file")" ;;
        esac
        temporary="$(mktemp "${dest}.update.XXXXXX")" || die "Cannot stage $dest"
        cp "$file" "$temporary" && chmod "$mode" "$temporary" && mv -f "$temporary" "$dest" ||
            { rm -f "$temporary"; die "Cannot deploy $dest; backup: $backup"; }
    done
    temporary="$(mktemp "${init_path}.update.XXXXXX")" || die "Cannot stage procd service"
    cp "$INSTALL_DIR/openwrt/sing-box.init" "$temporary" &&
        chmod 0755 "$temporary" && mv -f "$temporary" "$init_path" ||
        { rm -f "$temporary"; die "Cannot deploy procd service; backup: $backup"; }
    rm -f "$INSTALL_DIR/runtime/config.valid" 2>/dev/null || warn "Cannot remove optional validation cache; checks will run without a reusable cache."
    record_source_directory
    ok "Runtime scripts and configuration template updated; backup: $backup"
    info "Active configuration preserved: $CONFIG"
    info "Core and service state unchanged. Run 'sbctl config' and 'sbctl preflight' before restarting."
}

echo "════════════════════════════════════════════════════════════════"
echo "  SH Sing-box Linux eBPF Transparent Proxy Installer"
echo "  Based on reF1nd sing-box core (DNS-consistent, anti-leak)"
echo "════════════════════════════════════════════════════════════════"
echo ""

# -----------------------------------------------------------------------------
# 1. Privileges & Environment Pre-flight
# -----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "This installer must be run as root (use sudo bash install.sh)"

detect_os() {
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"
    elif [ -f /etc/debian_version ] || grep -qE "ID=(debian|ubuntu)" /etc/os-release 2>/dev/null; then
        echo "debian_ubuntu"
    else
        echo "generic_linux"
    fi
}

detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) die "Unsupported architecture: $m. Supported: amd64 (x86_64), arm64 (aarch64)." ;;
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

OS="$(detect_os)"
if [ "$SCRIPTS_ONLY" -eq 1 ]; then
    [ "$OS" = openwrt ] || die "--scripts-only is for an existing OpenWrt/procd installation."
    deploy_scripts_only
    exit 0
fi
ARCH="$(detect_arch)"
LIBC="$(detect_libc)"
[ "$OS" != openwrt ] || check_service_conflicts

info "Detected Platform:"
info "  OS:           $OS"
info "  Architecture: $ARCH"
info "  C Library:    $LIBC"
info "  Kernel:       $(uname -r)"
echo ""

# -----------------------------------------------------------------------------
# 2. Kernel & eBPF Prerequisite Verification
# -----------------------------------------------------------------------------
info "Verifying kernel & eBPF prerequisites..."

# Capability reporting is read-only at install time. The init script checks
# the selected configuration and mounts cgroup2 only when that data plane is
# enabled, before DNS/gateway setup. A kernel version alone is not proof of BPF.
info "Kernel $(uname -r); eBPF availability depends on firmware build options and privileges."
if awk '$2 == "/sys/fs/cgroup" && $3 == "cgroup2" { found = 1 } END { exit !found }' /proc/mounts; then
    ok "cgroup v2 filesystem active"
elif awk '$NF == "cgroup2" { found = 1 } END { exit !found }' /proc/filesystems; then
    info "cgroup2 is supported; startup will check the mount when local cgroup eBPF is enabled."
else
    warn "Firmware does not expose cgroup2; local cgroup eBPF cannot start until compatible firmware is used."
fi

# -----------------------------------------------------------------------------
# 3. Dependency Installation
# -----------------------------------------------------------------------------
info "Installing required packages..."
sb_download_load || die "Invalid download configuration; no packages were changed"
if [ "$OS" = "debian_ubuntu" ]; then
    export DEBIAN_FRONTEND=noninteractive
    sb_download_run apt-get update -qq || true
    sb_download_run apt-get install -y -qq curl ca-certificates tar jq procps unzip nftables iproute2 2>/dev/null ||
        sb_download_run apt-get install -y -qq curl ca-certificates tar jq procps
elif [ "$OS" = "openwrt" ]; then
    # opkg is still standard on many 24.x/custom images; newer images use apk.
    if command -v opkg >/dev/null 2>&1; then
        manager=opkg
    elif command -v apk >/dev/null 2>&1; then
        manager=apk
    else
        die "Neither opkg nor apk found on OpenWrt."
    fi
    sb_download_run "$manager" update || warn "$manager update incomplete; trying available indexes"
    for requirement in "curl:curl" "jq:jq" "bash:bash" "unzip:unzip"; do
        command_name="${requirement%%:*}"
        package_name="${requirement#*:}"
        if ! command -v "$command_name" >/dev/null 2>&1; then
            if [ "$manager" = opkg ]; then
                sb_download_run opkg install "$package_name" || die "Missing $command_name (package $package_name)"
            else
                sb_download_run apk add "$package_name" || die "Missing $command_name (package $package_name)"
            fi
        fi
    done
    # nftables, ip-full and kmod-nft-tproxy are gateway-only prerequisites.
    # Do not download kernel modules before the user selects gateway mode.
fi
ok "Required installer dependencies available"

# -----------------------------------------------------------------------------
# 4. Project Directory Layout
# -----------------------------------------------------------------------------
info "Setting up directory structure at $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"/{bin,config,scripts,systemd,openwrt,board,geo,providers,runtime}
mkdir -p "$(dirname "$CONFIG")"

# Copy repository files into installation directory
cp -a "$REPO_ROOT/scripts"/* "$INSTALL_DIR/scripts/"
cp -a "$REPO_ROOT/systemd"/* "$INSTALL_DIR/systemd/" 2>/dev/null || true
cp -a "$REPO_ROOT/openwrt"/* "$INSTALL_DIR/openwrt/" 2>/dev/null || true
cp -a "$REPO_ROOT/config/config.template.json" "$INSTALL_DIR/config/"

# Production config in the repository may contain server-specific credentials
# and is not appropriate as the OpenWrt router's first boot configuration.
if [ "$OS" != "openwrt" ] && [ -f "$REPO_ROOT/config/config.json" ] && [ ! -f "$CONFIG" ]; then
    cp -a "$REPO_ROOT/config/config.json" "$CONFIG"
fi

# Local menu and uninstaller must survive removal of the source checkout.
if [ "$OS" = "openwrt" ] && [ -f "$REPO_ROOT/menu.sh" ]; then
    cp "$REPO_ROOT/menu.sh" "$INSTALL_DIR/scripts/menu.sh"
    chmod 0755 "$INSTALL_DIR/scripts/menu.sh"
fi
cp "$REPO_ROOT/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
chmod 0755 "$INSTALL_DIR/uninstall.sh"
record_source_directory

chmod +x "$INSTALL_DIR/scripts"/*

# -----------------------------------------------------------------------------
# 5. Core Binary Acquisition (reF1nd)
# -----------------------------------------------------------------------------
info "Downloading reF1nd sing-box core for $ARCH ($LIBC)..."
export SH_SINGBOX_HOME="$INSTALL_DIR"
"$INSTALL_DIR/scripts/update-core.sh"

# -----------------------------------------------------------------------------
# 6. Zashboard Web Management Panel
# -----------------------------------------------------------------------------
info "Setting up Zashboard Web UI..."
UI_ZIP="$INSTALL_DIR/runtime/zashboard.zip"
UI_URL="https://github.com/zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip"
UI_ROOT="$INSTALL_DIR/board/dist"

# Canonical UI root is board/dist/index.html. A relative external_ui="board"
# is not necessarily resolved from INSTALL_DIR and allows the root ZIP folder
# to be confused with the directory actually containing index.html.
# Migrate old flat installs without touching any private configuration.
if [ -f "$INSTALL_DIR/board/index.html" ] && [ ! -f "$UI_ROOT/index.html" ]; then
    mkdir -p "$UI_ROOT"
    for item in "$INSTALL_DIR"/board/*; do
        [ -e "$item" ] || continue
        [ "$item" = "$UI_ROOT" ] && continue
        mv "$item" "$UI_ROOT/" || warn "Cannot relocate legacy Zashboard asset: $item"
    done
fi

if [ -f "$UI_ROOT/index.html" ]; then
    ok "Zashboard Web UI already present at $UI_ROOT/index.html"
else
    if ! command -v unzip >/dev/null 2>&1; then
        warn "unzip is missing. Cannot deploy dashboard; install unzip and retry."
    elif sb_download "$UI_URL" "$UI_ZIP" 180; then
        UI_STAGE="$(mktemp -d "$INSTALL_DIR/runtime/.ui-stage.XXXXXX")" || die "Cannot stage Zashboard UI"
        if unzip -qo "$UI_ZIP" -d "$UI_STAGE"; then
            if [ -f "$UI_STAGE/dist/index.html" ]; then
                UI_SOURCE="$UI_STAGE/dist"
            elif [ -f "$UI_STAGE/index.html" ]; then
                UI_SOURCE="$UI_STAGE"
            else
                UI_SOURCE=""
            fi
            if [ -n "$UI_SOURCE" ]; then
                mkdir -p "$UI_ROOT"
                cp -a "$UI_SOURCE/." "$UI_ROOT/" || die "Cannot install Zashboard assets"
                [ -f "$UI_ROOT/index.html" ] || die "Zashboard index.html was not installed"
                ok "Zashboard Web UI deployed at $UI_ROOT/index.html"
            else
                warn "Zashboard archive does not contain index.html at the expected level."
            fi
        else
            warn "Cannot extract downloaded Zashboard archive."
        fi
        rm -rf "$UI_STAGE"
    else
        warn "Could not download Zashboard UI; check internet and proxy settings."
    fi
    rm -f "$UI_ZIP"
fi

# -----------------------------------------------------------------------------
# 7. Geodata Rule-sets
# -----------------------------------------------------------------------------
info "Downloading DustinWin rule-sets..."
"$INSTALL_DIR/scripts/update-rules.sh" || warn "Initial rule-set download incomplete; sing-box will fetch on run"

# -----------------------------------------------------------------------------
# 8. Configuration Setup
# -----------------------------------------------------------------------------
if [ ! -f "$CONFIG" ]; then
    info "Creating default config from template..."
    create_default_config

    if [ "$OS" = "openwrt" ]; then
        info "OpenWrt: eBPF shared is disabled by default; select the LAN interface for this device explicitly."
        info "After configuring your nodes, use 'sbctl gateway configure LAN_INTERFACE YOUR_LAN_CIDR' for gateway mode."
    fi
    ok "Created $CONFIG"
else
    ok "Preserved existing $CONFIG"
    info "Source checkout config/config.json is not imported. Use 'sbctl import-config FILE' for an explicit validated import."
fi

# -----------------------------------------------------------------------------
# 9. CLI Link & Service Registration
# -----------------------------------------------------------------------------
info "Registering 'sbctl' command line interface..."
ln -sf "$INSTALL_DIR/scripts/sbctl" /usr/local/bin/sbctl 2>/dev/null || true
ln -sf "$INSTALL_DIR/scripts/sbctl" /usr/bin/sbctl 2>/dev/null || true
ok "sbctl installed into PATH (/usr/local/bin/sbctl)"
if [ "$OS" = "openwrt" ]; then
    # Refuse to overwrite an unrelated sb executable. The quick-install
    # launcher may currently point to the checkout's menu.sh.
    if [ -e /usr/bin/sb ] || [ -L /usr/bin/sb ]; then
        [ ! -L /usr/bin/sb ] || die "/usr/bin/sb is an existing symlink; inspect manually"
        grep -Fq '/menu.sh' /usr/bin/sb 2>/dev/null || die "/usr/bin/sb belongs to another program"
    fi
    printf '#!/bin/sh\nexec /bin/sh "%s/scripts/menu.sh" "$@"\n' "$INSTALL_DIR" > /usr/bin/sb
    chmod 0755 /usr/bin/sb
    ok "Registered lightweight SSH management menu: sb"
fi

info "Configuring service manager..."
if [ "$OS" = "openwrt" ] || ! command -v systemctl >/dev/null 2>&1; then
    # OpenWrt procd service
    if command -v uci >/dev/null 2>&1; then
        [ -f /etc/config/sing-box ] || cp "$INSTALL_DIR/openwrt/sing-box.config" /etc/config/sing-box
        uci -q get sing-box.main >/dev/null 2>&1 || uci set sing-box.main=sing-box
        uci set "sing-box.main.service_dir=$INSTALL_DIR"
        uci set "sing-box.main.config_file=$CONFIG"
        uci set "sing-box.main.source_dir=$REPO_ROOT"
        uci commit sing-box
    fi
    cp -f "$INSTALL_DIR/openwrt/sing-box.init" /etc/init.d/sing-box
    chmod 0755 /etc/init.d/sing-box
    /etc/init.d/sing-box enable
    ok "Enabled OpenWrt procd service (/etc/init.d/sing-box)"
else
    # Debian / Ubuntu systemd service
    cp -f "$INSTALL_DIR/systemd/sing-box.service" /etc/systemd/system/
    cp -f "$INSTALL_DIR/systemd/sing-box.slice" /etc/systemd/system/ 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable sing-box.service
    ok "Enabled systemd service (sing-box.service)"
fi

# -----------------------------------------------------------------------------
# 10. DNS Takeover Guard
# -----------------------------------------------------------------------------
info "DNS takeover guard will activate when sing-box starts."

# -----------------------------------------------------------------------------
# 11. Configuration Validation
# -----------------------------------------------------------------------------
info "Validating configuration with sing-box..."
if "$INSTALL_DIR/scripts/sbctl" check; then
    ok "Configuration validation succeeded"
else
    warn "Configuration validation reported issues. Review $CONFIG"
    if jq -e '
      any(.outbounds[]?; .type == "dns" or .type == "block")
      or any(.route.rules[]?; .action == "sniff-override-destination")
    ' "$CONFIG" >/dev/null 2>&1; then
        warn "Detected legacy sing-box DNS/block/sniff configuration (removed or changed in 1.13+)."
        warn "Open sb menu and choose 18 to safely migrate the current config."
        warn "Manual equivalent: bash $INSTALL_DIR/scripts/migrate-config.sh"
        warn "Migration backs up and validates the config; it does NOT restart the service."
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
ok "Installation completed successfully!"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Quick Start Commands:"
echo "  1. Edit your proxy nodes in configuration:"
echo "     vi $CONFIG"
echo ""
echo "  2. Start the service:"
echo "     sbctl start"
echo ""
echo "  3. Check service and eBPF status:"
echo "     sbctl status"
echo "     sbctl ebpf-status"
echo ""
echo "  4. Web Management Dashboard (Clash API):"
echo "     http://127.0.0.1:9090"
echo ""
echo "  5. Security & Leak Diagnostic:"
echo "     sbctl test-leak"
echo ""
echo "  6. Traffic Takeover & Filtering Controls:"
echo "     sbctl filter show"
echo "     sbctl filter exclude-proc sshd"
echo "     sbctl filter exclude-user 1000"
echo "════════════════════════════════════════════════════════════════"
