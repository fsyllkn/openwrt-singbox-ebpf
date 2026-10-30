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

INSTALL_SOURCE_FILE="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$INSTALL_SOURCE_FILE")" && pwd -P)"
case "$REPO_ROOT" in
    *[[:cntrl:]]*) printf '%s\n' 'Source directory must not contain control characters.' >&2; exit 1 ;;
esac
. "$REPO_ROOT/scripts/runtime-paths.sh"
sb_load_paths || exit 1
. "$REPO_ROOT/scripts/download.sh"
. "$REPO_ROOT/scripts/config-parts-lib.sh"
INSTALL_DIR="$SH_SINGBOX_HOME"
CONFIG="$SH_SINGBOX_CONFIG"
# Installation subprocesses must use the scripts deployed into this HOME,
# even when a source-checkout menu exported its own composition tool path.
SB_CONFIG_PARTS_TOOL="$INSTALL_DIR/scripts/config-parts.sh"
export SB_CONFIG_PARTS_TOOL
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

# The source checkout is reused in place, while service files are deployed
# separately. Reject self-copy before package, core or service changes.
if [ "$REPO_ROOT" -ef "$INSTALL_DIR" ]; then
    die "Source checkout and service directory must be different; choose a separate SH_SINGBOX_HOME."
fi

record_source_directory() {
    local source_record
    mkdir -p "$INSTALL_DIR/runtime"
    source_record="$(mktemp "$INSTALL_DIR/runtime/.source-dir.XXXXXX")" || die "Cannot record source directory"
    printf '%s\n' "$REPO_ROOT" > "$source_record" && chmod 0600 "$source_record" &&
        mv -f "$source_record" "$INSTALL_DIR/runtime/source-dir" ||
        { rm -f "$source_record"; die "Cannot record source directory"; }
}

validate_provider_samples() {
    local directory="$1" name sample
    for name in xboard local; do
        sample="$directory/$name.sample.json"
        [ -f "$sample" ] && [ -r "$sample" ] || die "Missing or unreadable provider sample: $sample"
        jq -e '
          type == "object" and
          (.outbounds | type == "array" and length > 0 and
            all(.[]; type == "object" and
              (.type | type == "string" and length > 0) and
              (.tag | type == "string" and length > 0)))
        ' "$sample" >/dev/null 2>&1 || die "Invalid provider sample: $sample (expected a non-empty outbounds array with type and tag)"
    done
}

# Publish a complete private file without replacing any existing directory
# entry, including a dangling symlink. The staging file is on the same volume.
copy_missing_file() {
    local source="$1" destination="$2" temporary
    if [ -e "$destination" ] || [ -L "$destination" ]; then return 0; fi
    mkdir -p "$(dirname "$destination")" || return 1
    temporary="$(mktemp "${destination}.initial.XXXXXX")" || return 1
    if ! cp "$source" "$temporary" || ! chmod 0600 "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    if ln -T "$temporary" "$destination" 2>/dev/null; then
        rm -f "$temporary"
        return 0
    fi
    rm -f "$temporary"
    # Another installer may have supplied this path after the initial check.
    [ -e "$destination" ] || [ -L "$destination" ]
}

deploy_provider_samples() {
    local name
    validate_provider_samples "$REPO_ROOT/examples"
    for name in xboard local; do
        copy_missing_file "$REPO_ROOT/examples/$name.sample.json" "$INSTALL_DIR/providers/$name.sample.json" ||
            die "Cannot deploy missing provider sample: $INSTALL_DIR/providers/$name.sample.json"
    done
}

create_default_config() {
    # Render machine-dependent paths only for a fresh installation. Existing
    # user inbounds, private-IP routes, providers and credentials stay intact.
    # An absent generated output never makes an existing parts layout fresh.
    if SH_SINGBOX_CONFIG="$CONFIG" sb_parts_active; then
        return 0
    fi
    if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
        [ -f "$CONFIG" ] && [ -r "$CONFIG" ] || die "Existing configuration is not a readable file; refusing to replace it: $CONFIG"
        return 0
    fi
    local candidate name provider
    validate_provider_samples "$INSTALL_DIR/providers"
    for name in xboard local; do
        provider="$INSTALL_DIR/providers/$name.json"
        if [ -e "$provider" ] || [ -L "$provider" ]; then
            [ -f "$provider" ] && [ -r "$provider" ] ||
                die "Existing provider is not a readable file; refusing to replace it: $provider"
        fi
    done
    mkdir -p "$(dirname "$CONFIG")"
    candidate="$(mktemp "${CONFIG}.initial.XXXXXX")" || die "Cannot stage initial configuration"
    if ! jq --arg ui_root "$INSTALL_DIR/board/dist" \
        '.experimental.clash_api.external_ui = $ui_root' \
        "$INSTALL_DIR/config/config.template.json" > "$candidate"; then
        rm -f "$candidate"
        die "Cannot render initial configuration"
    fi
    for name in xboard local; do
        copy_missing_file "$INSTALL_DIR/providers/$name.sample.json" "$INSTALL_DIR/providers/$name.json" ||
            { rm -f "$candidate"; die "Cannot initialize missing provider: $INSTALL_DIR/providers/$name.json"; }
    done
    copy_missing_file "$candidate" "$CONFIG" || { rm -f "$candidate"; die "Cannot create initial configuration"; }
    rm -f "$candidate"
    info "Local example providers are ready; start the service to inspect its status and dashboard."
    info "Example nodes do not provide a working proxy; configure and select real nodes before use."
}

initialize_configuration() {
    local parts_tool
    if SH_SINGBOX_CONFIG="$CONFIG" sb_parts_active; then
        info "Preserved existing configuration sources: $(SH_SINGBOX_CONFIG="$CONFIG" sb_parts_dir)"
        return 0
    fi
    if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
        create_default_config
        info "Preserved existing single-file configuration: $CONFIG"
        info "Use 'sbctl split-config' for an explicit, lossless migration."
        return 0
    fi
    parts_tool="$INSTALL_DIR/scripts/config-parts.sh"
    [ -f "$parts_tool" ] && [ -r "$parts_tool" ] ||
        die "Missing or unreadable configuration-parts tool: $parts_tool; update the installed scripts before continuing"
    create_default_config
    SH_SINGBOX_HOME="$INSTALL_DIR" SH_SINGBOX_CONFIG="$CONFIG" SB_CONFIG_PARTS_TOOL="$parts_tool" bash "$parts_tool" init ||
        die "Initial configuration could not be split; the full JSON and providers were preserved. Resolve the validation error, then run 'sbctl split-config'."
    info "Editable configuration sources: $(SH_SINGBOX_CONFIG="$CONFIG" sb_parts_dir)"
}

prepare_existing_parts() {
    SH_SINGBOX_CONFIG="$CONFIG" sb_parts_active || return 0
    [ -x "$INSTALL_DIR/bin/sing-box" ] ||
        die "Existing configuration sources require an installed core for validation; restore that core before running a full installation"
    info "Validating existing configuration sources with the current core before updating it..."
    SH_SINGBOX_HOME="$INSTALL_DIR" SH_SINGBOX_CONFIG="$CONFIG" "$INSTALL_DIR/scripts/sbctl" preflight ||
        die "Existing configuration sources could not be prepared with the current core. Resolve the draft/validation error before updating; the core and current service were not changed."
}

# Every systemd process, including reload/check/cleanup helpers, must resolve
# the same custom HOME and CONFIG as the core. Quote paths and disable systemd
# specifier/environment expansion of literal path characters.
render_systemd_service() {
    local output="$1"
    case "$INSTALL_DIR$CONFIG" in
        *$'\n'*|*$'\r'*) die "Systemd service paths must not contain line breaks" ;;
    esac
    jq -nr --arg home "$INSTALL_DIR" --arg config "$CONFIG" \
        --rawfile unit "$INSTALL_DIR/systemd/sing-box.service" '
      # Literal replacements also work when jq is built without regex support.
      def escaped: split("\\") | join("\\\\") | split("\"") | join("\\\"") | split("%") | join("%%");
      ($home | escaped) as $home_path | ($config | escaped) as $config_path |
      $unit | split("\n") | map(
        if startswith("WorkingDirectory=") then
          "WorkingDirectory=" + ($home | split("%") | join("%%"))
        else
        startswith("Exec") as $command |
        ($home_path | if $command then split("$") | join("$$") else . end) as $home_replacement |
        ($config_path | if $command then split("$") | join("$$") else . end) as $config_replacement |
        # Split the longer token first, transform only original fragments, then
        # join. Replacement paths containing either token are never rescanned.
        split("/opt/sing-box/config/config.json") |
        map(split("/opt/sing-box") | join($home_replacement)) |
        join($config_replacement)
        end
      ) | join("\n")
    ' > "$output" || die "Cannot render systemd service for the selected runtime paths"
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
    [ -f "$CONFIG" ] || SH_SINGBOX_CONFIG="$CONFIG" sb_parts_active ||
        die "Existing configuration or configuration sources not found: $CONFIG"
    [ -f "$init_path" ] || die "Existing procd service not found: $init_path"
    check_service_conflicts "$init_path"
    for file in scripts/sbctl scripts/runtime-paths.sh scripts/terminal-input.sh scripts/download.sh scripts/configure-download.sh scripts/config-parts-lib.sh scripts/config-parts.sh scripts/route-manager.sh scripts/gateway.sh scripts/dns-guard.sh menu.sh uninstall.sh openwrt/sing-box.init config/config.template.json examples/xboard.sample.json examples/local.sample.json; do
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
    validate_provider_samples "$REPO_ROOT/examples"
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
    deploy_provider_samples
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

# Probe the operations used by this project, not optional jq regex features or
# a version banner. These checks do not read or modify the running config.
installer_dependency_ready() {
    local dependency=$1 output line digest probe_dir probe_text probe_status=1 bundle
    case "$dependency" in
        curl)
            command -v curl >/dev/null 2>&1 || return 1
            output=$(curl -q --version 2>/dev/null) || return 1
            while IFS= read -r line; do
                case "$line" in
                    Protocols:*) case " ${line#Protocols:} " in *' https '*) return 0 ;; esac ;;
                esac
            done <<< "$output"
            return 1 ;;
        jq)
            command -v jq >/dev/null 2>&1 || return 1
            output=$(jq -cen --arg text 'A._B' --argjson values '[1,2]' '
              {text:$text,values:$values}
              | .text=="A._B" and (.text|ascii_downcase|split(".")|join("/")=="a/_b")
                and (.values|all(.[]; type=="number" and .>0))
                and ("0123"|explode|all(.[]; .>=48 and .<=57))
                and ((["a","b"]|index("b"))==1)
            ' 2>/dev/null) || return 1
            [ "$output" = true ] ;;
        bash)
            command -v bash >/dev/null 2>&1 || return 1
            output=$(bash -c 'set -m || exit 1; case $- in *m*) ;; *) exit 1 ;; esac
              [ -n "${BASHPID:-}" ] || exit 1
              (exit 0) & child=$!; wait "$child" || exit 1
              printf ready' 2>/dev/null) || return 1
            [ "$output" = ready ] ;;
        sha256)
            if command -v sha256sum >/dev/null 2>&1; then
                output=$(sha256sum </dev/null 2>/dev/null) || return 1
            elif command -v busybox >/dev/null 2>&1; then
                output=$(busybox sha256sum </dev/null 2>/dev/null) || return 1
            else
                return 1
            fi
            digest=${output%% *}
            [ "$digest" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ] ;;
        sleep)
            command -v sleep >/dev/null 2>&1 && sleep 0 >/dev/null 2>&1 ;;
        ca)
            if [ -n "${CURL_CA_BUNDLE:-}" ]; then
                [ -r "$CURL_CA_BUNDLE" ] && [ -s "$CURL_CA_BUNDLE" ] &&
                    grep -Fq -- '-----BEGIN CERTIFICATE-----' "$CURL_CA_BUNDLE"
                return
            fi
            for bundle in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem /etc/ssl/ca-bundle.pem; do
                if [ -r "$bundle" ] && [ -s "$bundle" ] &&
                    grep -Fq -- '-----BEGIN CERTIFICATE-----' "$bundle"; then return 0; fi
            done
            return 1 ;;
        unzip)
            command -v unzip >/dev/null 2>&1 || return 1
            probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/sb-install-unzip.XXXXXX") || return 1
            # One stored ZIP member, probe.txt = "ready\n". No optional
            # encoder or network is needed to check the exact extraction flags.
            if printf '%b' '\x50\x4b\x03\x04\x14\x00\x00\x00\x00\x00\x00\x00\x21\x00\x6f\x2d\x96\x74\x06\x00\x00\x00\x06\x00\x00\x00\x09\x00\x00\x00\x70\x72\x6f\x62\x65\x2e\x74\x78\x74\x72\x65\x61\x64\x79\x0a\x50\x4b\x01\x02\x14\x03\x14\x00\x00\x00\x00\x00\x00\x00\x21\x00\x6f\x2d\x96\x74\x06\x00\x00\x00\x06\x00\x00\x00\x09\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01\x00\x00\x00\x00\x70\x72\x6f\x62\x65\x2e\x74\x78\x74\x50\x4b\x05\x06\x00\x00\x00\x00\x01\x00\x01\x00\x37\x00\x00\x00\x2d\x00\x00\x00\x00\x00' > "$probe_dir/probe.zip" &&
               unzip -qo "$probe_dir/probe.zip" -d "$probe_dir/extracted" >/dev/null 2>&1 &&
               IFS= read -r probe_text < "$probe_dir/extracted/probe.txt" && [ "$probe_text" = ready ]; then
                probe_status=0
            fi
            rm -rf "$probe_dir"
            return "$probe_status" ;;
        *) return 1 ;;
    esac
}

installer_dependency_description() {
    case "$1" in
        curl) printf '%s' 'curl with HTTPS support' ;;
        jq) printf '%s' 'jq JSON parsing and literal string/array operations (regex is not required)' ;;
        bash) printf '%s' 'Bash with non-interactive job control' ;;
        sha256) printf '%s' 'working SHA-256 (sha256sum or BusyBox sha256sum)' ;;
        sleep) printf '%s' 'integer sleep' ;;
        ca) printf '%s' 'readable TLS CA certificate bundle' ;;
        unzip) printf '%s' 'unzip with -qo archive -d directory extraction' ;;
    esac
}

dependency_manager= dependency_indexes_ready=0
if [ "$OS" = "debian_ubuntu" ]; then
    command -v apt-get >/dev/null 2>&1 || die "apt-get is required to install missing Debian/Ubuntu dependencies"
    dependency_manager=apt-get
    export DEBIAN_FRONTEND=noninteractive
    sb_download_run apt-get update -qq || true
    dependency_indexes_ready=1
    sb_download_run apt-get install -y -qq curl ca-certificates tar jq procps unzip nftables iproute2 2>/dev/null ||
        sb_download_run apt-get install -y -qq curl ca-certificates tar jq procps unzip ||
        die "Dependency installation failed with apt-get; check package indexes and the configured download proxy before retrying"
elif [ "$OS" = "openwrt" ]; then
    # opkg is still standard on many 24.x/custom images; newer images use apk.
    if command -v opkg >/dev/null 2>&1; then
        dependency_manager=opkg
    elif command -v apk >/dev/null 2>&1; then
        dependency_manager=apk
    fi
    # nftables, ip-full and kmod-nft-tproxy are gateway-only prerequisites.
    # Do not download kernel modules before the user selects gateway mode.
fi

# Normal OpenWrt images provide these BusyBox basics. Debian/Ubuntu's package
# step above also supplies tar/procps on minimal images. Do not invent package
# mappings for an incomplete OpenWrt base firmware.
for base_command in awk basename cat chmod cp date dirname find grep head id ln mkdir mktemp mv pidof readlink rm rmdir sed sh tar tr uname wc; do
    command -v "$base_command" >/dev/null 2>&1 ||
        die "Missing base tool '$base_command'. Restore the OS's BusyBox/base utilities before installation; no service files were deployed."
done

# Install only failed capabilities on OpenWrt, then repeat the actual probe.
# This is deliberately part of full installation, after the --scripts-only
# early return, so offline script repair never starts a package transaction.
for dependency in ca curl jq bash unzip sha256 sleep; do
    if installer_dependency_ready "$dependency"; then continue; fi
    dependency_description=$(installer_dependency_description "$dependency")
    case "$dependency" in
        ca) dependency_package=ca-bundle; [ "$OS" != debian_ubuntu ] || dependency_package=ca-certificates ;;
        sha256) dependency_package=coreutils-sha256sum; [ "$OS" != debian_ubuntu ] || dependency_package=coreutils ;;
        sleep) dependency_package=coreutils-sleep; [ "$OS" != debian_ubuntu ] || dependency_package=coreutils ;;
        *) dependency_package=$dependency ;;
    esac
    [ -n "$dependency_manager" ] ||
        die "Missing or unusable $dependency_description. No supported package manager is available; install package '$dependency_package' with the firmware's package tools and retry. No service files were deployed."
    if [ "$dependency_indexes_ready" -eq 0 ]; then
        sb_download_run "$dependency_manager" update || warn "$dependency_manager update incomplete; trying available indexes"
        dependency_indexes_ready=1
    fi
    info "Installing dependency: $dependency_description (package $dependency_package)"
    case "$dependency_manager" in
        apt-get) sb_download_run apt-get install -y -qq "$dependency_package" ;;
        opkg) sb_download_run opkg install "$dependency_package" ;;
        apk) sb_download_run apk add "$dependency_package" ;;
    esac || die "Cannot install package '$dependency_package' with $dependency_manager for $dependency_description; check the package feed and download proxy. No service files were deployed."
    hash -r
    installer_dependency_ready "$dependency" ||
        die "Package '$dependency_package' was installed with $dependency_manager, but $dependency_description is still unavailable. Check the executable selected by PATH or a custom CA bundle; no service files were deployed."
done
for dependency in ca curl jq bash unzip sha256 sleep; do
    installer_dependency_ready "$dependency" ||
        die "Dependency recheck failed: $(installer_dependency_description "$dependency"). No service files were deployed."
done
ok "Required installer dependencies available"

# -----------------------------------------------------------------------------
# 4. Project Directory Layout
# -----------------------------------------------------------------------------
info "Setting up directory structure at $INSTALL_DIR..."
validate_provider_samples "$REPO_ROOT/examples"
for file in config-parts-lib.sh config-parts.sh route-manager.sh terminal-input.sh; do
    [ -f "$REPO_ROOT/scripts/$file" ] || die "Incomplete source: missing scripts/$file"
done
mkdir -p "$INSTALL_DIR"/{bin,config,scripts,systemd,openwrt,board,geo,providers,runtime}
mkdir -p "$(dirname "$CONFIG")"

# Copy repository files into installation directory
cp -a "$REPO_ROOT/scripts"/* "$INSTALL_DIR/scripts/"
cp -a "$REPO_ROOT/systemd"/* "$INSTALL_DIR/systemd/" 2>/dev/null || true
cp -a "$REPO_ROOT/openwrt"/* "$INSTALL_DIR/openwrt/" 2>/dev/null || true
cp -a "$REPO_ROOT/config/config.template.json" "$INSTALL_DIR/config/"
deploy_provider_samples

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
prepare_existing_parts
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
initialize_configuration
info "Source checkout config/config.json is not imported. Use 'sbctl import-config FILE' for an explicit validated import."

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
    SYSTEMD_STAGE=$(mktemp /etc/systemd/system/.sing-box.service.XXXXXX) || die "Cannot stage systemd service"
    render_systemd_service "$SYSTEMD_STAGE"
    chmod 0644 "$SYSTEMD_STAGE" && mv -f "$SYSTEMD_STAGE" /etc/systemd/system/sing-box.service ||
        { rm -f "$SYSTEMD_STAGE"; die "Cannot install systemd service"; }
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
        warn "Open sb → 配置与隐私 → 修复旧版 DNS/block 配置 to safely migrate the current config."
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
if sb_parts_active; then
    echo "     sb → 配置与隐私 → 编辑配置"
    echo "     Sources: $(sb_parts_dir)"
else
    echo "     vi $CONFIG"
fi
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
