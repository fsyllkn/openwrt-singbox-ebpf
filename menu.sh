#!/bin/sh
# Lightweight SSH menu for OpenWrt / BusyBox ash. No Python needed.
set -u
MENU_FILE=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
MENU_DIR=$(CDPATH= cd -- "$(dirname -- "$MENU_FILE")" && pwd -P) || exit 1
if [ -r "$MENU_DIR/runtime-paths.sh" ]; then
    MENU_PATHS=$MENU_DIR/runtime-paths.sh
else
    MENU_PATHS=$MENU_DIR/scripts/runtime-paths.sh
fi
[ -r "$MENU_PATHS" ] || {
    echo 'Missing runtime-paths.sh; deploy the complete updated scripts directory.' >&2
    exit 1
}
. "$MENU_PATHS"
sb_load_paths || exit 1
MENU_PARTS=$(dirname -- "$MENU_PATHS")/config-parts-lib.sh
[ -r "$MENU_PARTS" ] || {
    echo 'Missing config-parts-lib.sh; deploy the complete updated scripts directory.' >&2
    exit 1
}
. "$MENU_PARTS"
SB_CONFIG_PARTS_TOOL=$(dirname -- "$MENU_PATHS")/config-parts.sh
export SB_CONFIG_PARTS_TOOL
SB_HOME=$SH_SINGBOX_HOME
GATEWAY=$SB_HOME/scripts/gateway.sh
CONFIG=$SH_SINGBOX_CONFIG
SERVICE=/etc/init.d/sing-box
SBCTL=$SB_HOME/scripts/sbctl
find_source_dir() {
    # Source records contain a plain path, never shell code. A copied installed
    # menu must still locate the checkout selected during installation.
    if [ -n "${SB_INSTALL_SOURCE_DIR:-}" ]; then
        printf '%s\n' "$SB_INSTALL_SOURCE_DIR"
        return
    fi
    if [ -f "$MENU_DIR/install.sh" ]; then
        printf '%s\n' "$MENU_DIR"
        return
    fi
    recorded_source=
    if [ -r "$SB_HOME/runtime/source-dir" ]; then
        IFS= read -r recorded_source < "$SB_HOME/runtime/source-dir" || recorded_source=
        case "$recorded_source" in
            /*) if [ -f "$recorded_source/install.sh" ]; then printf '%s\n' "$recorded_source"; return; fi ;;
        esac
    fi
    if command -v uci >/dev/null 2>&1; then
        recorded_source=$(uci -q get sing-box.main.source_dir 2>/dev/null) || recorded_source=
        case "$recorded_source" in
            /*) if [ -f "$recorded_source/install.sh" ]; then printf '%s\n' "$recorded_source"; return; fi ;;
        esac
    fi
    for recorded_source in /overlay/openwrt-singbox-ebpf /root/openwrt-singbox-ebpf /overlay/linux_openwrt-sing-box /root/linux_openwrt-sing-box; do
        if [ -f "$recorded_source/install.sh" ]; then printf '%s\n' "$recorded_source"; return; fi
    done
    printf '%s\n' "$MENU_DIR"
}
REPO_DIR=$(find_source_dir)
[ -f /etc/openwrt_release ] || {
    echo "This distribution requires OpenWrt/procd." >&2
    exit 1
}

say() { printf '%s\n' "$*"; }
ask() {
    printf '%s [Y/n]: ' "$1"
    IFS= read -r answer || return 1
    case "$answer" in ''|y|Y|yes|YES) return 0;; esac
    return 1
}
wait_key() { printf '\n按回车继续...'; IFS= read -r unused; }
root_only() { [ "$(id -u)" -eq 0 ] || { say 'Requires root.'; return 1; }; }
load_download_library() {
    download_library=$REPO_DIR/scripts/download.sh
    [ -r "$download_library" ] || download_library=$SB_HOME/scripts/download.sh
    [ -r "$download_library" ] || {
        say 'Missing download.sh; deploy the complete project scripts.'; return 1;
    }
    . "$download_library"
    sb_download_load
}
run_sbctl() {
    if [ -f "$SBCTL" ]; then
        /bin/bash "$SBCTL" "$@"
    else
        say 'sing-box 尚未安装。请先进入「安装与更新 → 安装/修复核心服务」。'
        return 1
    fi
}
service_status() {
    if [ ! -x "$SERVICE" ]; then
        printf 'not installed'
    elif "$SERVICE" status >/dev/null 2>&1; then
        printf 'running'
    else
        printf 'stopped'
    fi
}
gateway_status() {
    if [ -f "$SB_HOME/runtime/gateway.json" ]; then printf 'configured'
    else printf 'off'; fi
}
package_manager() {
    if command -v opkg >/dev/null 2>&1; then printf opkg
    elif command -v apk >/dev/null 2>&1; then printf apk
    else printf unknown; fi
}
backup_config() {
    [ -f "$CONFIG" ] || { say "Missing $CONFIG"; return 1; }
    dest="$CONFIG.menu.$(date +%Y%m%d-%H%M%S).$$.bak"
    cp -p "$CONFIG" "$dest" || return 1
    chmod 0600 "$dest"
    say "Backup: $dest"
}
edit_config() {
    root_only || return
    if sb_parts_active; then
        edit_config_part
        return
    fi
    say "Editing service configuration: $CONFIG"
    backup_config || return
    vi "$CONFIG" || return
    if command -v jq >/dev/null 2>&1; then
        jq -e . "$CONFIG" >/dev/null 2>&1 || {
            say 'WARNING: JSON syntax invalid. Restore the backup before starting service.'
            return 1
        }
    fi
    say '配置已保存。请先进入「服务管理 → 配置校验」，通过后再重启。'
}
edit_config_part() (
    parts_directory=$(sb_parts_dir)
    say "自定义配置目录：$parts_directory"
    say '1) providers：订阅与本地 Provider 定义'
    say '2) inbounds：LAN 监听、认证与 eBPF 设置'
    say '3) outbounds：节点与 proxy/ai 分组'
    say '4) routing：指定 IP/网段及进程的路由例外'
    say '5) settings：面板、日志等其他设置'
    say '6) 查看运行配置路径与状态'
    say '0) 返回'
    printf '选择要编辑的部分：'
    IFS= read -r part_choice || exit 1
    case "$part_choice" in
        1) part_name=providers ;;
        2) part_name=inbounds ;;
        3) part_name=outbounds ;;
        4) part_name=routing ;;
        5) part_name=settings ;;
        6) run_sbctl config; exit $? ;;
        0|'') exit 0 ;;
        *) say '无效选项。'; exit 1 ;;
    esac
    part_source=$parts_directory/$part_name.json
    [ -f "$part_source" ] || { say "缺少源文件：$part_source，请从备份恢复。"; exit 1; }
    part_expected=$(sb_parts_fingerprint) || exit 1
    mkdir -p "$SB_HOME/runtime" || exit 1
    part_stage=$(mktemp "$SB_HOME/runtime/.config-part-edit.XXXXXX") || exit 1
    trap '[ -z "$part_stage" ] || rm -f "$part_stage"' EXIT HUP INT TERM
    cp "$part_source" "$part_stage" && chmod 0600 "$part_stage" || exit 1
    say "编辑 $part_name；保存后会组装并预检，通过才更新配置，不会重启服务。"
    vi "$part_stage" || exit 1
    chmod 0600 "$part_stage" || exit 1
    if ! SB_CONFIG_PARTS_EXPECTED=$part_expected sb_parts_set "$part_name" "$part_stage"; then
        part_rejected=$SB_HOME/runtime/$part_name.rejected.$(date +%Y%m%d-%H%M%S).$$.json
        if mv "$part_stage" "$part_rejected"; then
            part_stage=
            say "未通过校验，原配置保持不变。编辑内容保存在：$part_rejected"
        else
            trap - EXIT HUP INT TERM
            say "未通过校验，编辑内容仍在：$part_stage"
        fi
        exit 1
    fi
    say '源文件和运行配置已更新；需要应用到服务时，进入「服务管理 → 重启 sing-box」。'
)
manage_config_parts() {
    root_only || return
    run_sbctl config || true
    say '1) 将兼容的单文件配置无损拆分'
    say '2) 保留完整运行 JSON，归档分文件并返回单文件模式'
    say '0) 返回'
    say '这两项都不会重启服务；自定义 DNS 或规则顺序不能无损拆分时会保留原配置。'
    printf '选择：'
    IFS= read -r layout_choice || return
    case "$layout_choice" in
        1) run_sbctl split-config ;;
        2) run_sbctl single-config ;;
        0|'') return 0 ;;
        *) say '无效选项。'; return 1 ;;
    esac
}
install_core() {
    root_only || return
    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64) ;;
        *) say 'This reF1nd build supports Linux amd64/arm64. No packages or services were changed.'; return 1 ;;
    esac
    [ -f "$REPO_DIR/install.sh" ] || {
        say "Source not available in $REPO_DIR. Download openwrt-singbox-ebpf from its public main branch."
        return 1
    }
    say 'Installation registers procd and may update packages and the core binary.'
    say 'It does not start the transparent proxy. Existing running sing-box can be affected by a core update.'
    ask 'Install/repair sing-box now?' || return
    load_download_library || return
    if ! command -v bash >/dev/null 2>&1; then
        say 'Bash is required by the existing sing-box service scripts.'
        if command -v opkg >/dev/null 2>&1; then
            sb_download_run opkg update || true
            sb_download_run opkg install bash || return
        elif command -v apk >/dev/null 2>&1; then
            sb_download_run apk update || true
            sb_download_run apk add bash || return
        else
            say 'No supported package manager to install Bash.'
            return 1
        fi
    fi
    (cd "$REPO_DIR" && bash install.sh)
}
# Derive a network from the selected interface's real address/prefix. Multiple
# addresses in one subnet are fine; multiple distinct subnets need a choice.
# This deliberately does not use the previously saved gateway CIDR, which may
# describe the LAN before the router was moved to another network.
gateway_default_interface() (
    candidate=
    if command -v jq >/dev/null 2>&1 && [ -f "$SB_HOME/runtime/gateway.json" ]; then
        candidate=$(jq -er '.interface | select(type == "string")' "$SB_HOME/runtime/gateway.json" 2>/dev/null) || candidate=
    fi
    valid_interface() {
        case "$1" in ''|lo|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
        ip link show dev "$1" >/dev/null 2>&1
    }
    if valid_interface "$candidate"; then printf '%s\n' "$candidate"; exit 0; fi
    if command -v ubus >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        candidate=$(ubus call network.interface.lan status 2>/dev/null |
            jq -er '.l3_device // .device // empty' 2>/dev/null) || candidate=
        if valid_interface "$candidate"; then printf '%s\n' "$candidate"; exit 0; fi
    fi
    if command -v uci >/dev/null 2>&1; then
        for option in device ifname; do
            candidate=$(uci -q get "network.lan.$option" 2>/dev/null) || candidate=
            if valid_interface "$candidate"; then printf '%s\n' "$candidate"; exit 0; fi
        done
    fi
    # Without an explicit LAN designation, a unique usable interface is safe
    # to suggest. Multiple LAN/WAN/VLAN interfaces require a user selection.
    addresses=$(ip -4 -o addr show scope global 2>/dev/null) || exit 1
    candidate=$(printf '%s\n' "$addresses" | awk '$2 != "lo" {sub(/@.*/, "", $2); names[$2]=1}
        END {for (name in names) {count++; result=name} if (count!=1) exit 1; print result}') || exit 1
    valid_interface "$candidate" || exit 1
    printf '%s\n' "$candidate"
)
gateway_default_cidr() (
    [ "$#" -eq 1 ] || exit 1
    lan_addresses=$(ip -4 -o addr show dev "$1" scope global 2>/dev/null) || exit 1
    printf '%s\n' "$lan_addresses" | awk '
      {
        for (i = 1; i < NF; i++) {
          if ($i != "inet") continue
          if (split($(i + 1), pair, "/") != 2) continue
          if (pair[2] !~ /^[0-9]+$/ || pair[2] < 1 || pair[2] > 32) continue
          if (split(pair[1], octet, ".") != 4) continue
          valid = 1
          address = 0
          for (j = 1; j <= 4; j++) {
            if (octet[j] !~ /^[0-9]+$/ || octet[j] > 255) valid = 0
            address = address * 256 + octet[j]
          }
          if (!valid) continue
          block = 2 ^ (32 - pair[2])
          network = int(address / block) * block
          cidr = sprintf("%d.%d.%d.%d/%d", int(network / 16777216),
                 int(network / 65536) % 256, int(network / 256) % 256,
                 network % 256, pair[2])
          networks[cidr] = 1
        }
      }
      END {
        count = 0
        for (cidr in networks) { count++; result = cidr }
        if (count != 1) exit 1
        print result
      }
    '
)
configure_gateway() {
    root_only || return
    [ -f "$GATEWAY" ] || { say 'Install sing-box before configuring gateway.'; return; }
    command -v nft >/dev/null 2>&1 || { say 'nft missing. Install nftables / nft as available for this firmware.'; return; }
    command -v ip >/dev/null 2>&1 || { say 'ip missing. Install ip-full.'; return; }
    if ! /bin/bash "$GATEWAY" requirements; then
        say '网关设置尚未改动。此固件需要完整 iproute2（OpenWrt 的 ip-full），BusyBox ip 不支持当前专用路由表。'
        return
    fi
    say 'LAN gateway: nftables TProxy for clients on the selected interface; existing local eBPF settings are preserved.'
    say 'Select the actual LAN interface and its on-link client CIDR.'
    ip -4 route show default
    ip -4 -o addr show scope global
    default_interface=$(gateway_default_interface) || default_interface=
    if [ -n "$default_interface" ]; then
        printf 'LAN interface [%s]: ' "$default_interface"
    else
        say 'No unique LAN interface detected; choose the LAN device from the addresses above.'
        printf 'LAN interface: '
    fi
    IFS= read -r interface || return
    interface=${interface:-$default_interface}
    [ -n "$interface" ] || { say 'No LAN interface selected; gateway configuration unchanged.'; return 1; }
    default_cidr=$(gateway_default_cidr "$interface") || default_cidr=
    if [ -n "$default_cidr" ]; then
        printf 'LAN subnet CIDR [%s]: ' "$default_cidr"
    else
        say 'No unique IPv4 LAN subnet detected; enter the actual subnet/prefix explicitly.'
        printf 'LAN subnet CIDR: '
    fi
    IFS= read -r cidr || return
    cidr=${cidr:-$default_cidr}
    [ -n "$cidr" ] || { say 'No subnet selected; gateway configuration unchanged.'; return 1; }
    ask "Configure gateway for $interface / $cidr? Does not enable it until restart." || return
    /bin/bash "$GATEWAY" configure "$interface" "$cidr" || return
    say '请先进入「服务管理 → 配置校验」，通过后在合适的维护时间选择「重启 sing-box」。'
}
disable_gateway() {
    root_only || return
    [ -f "$GATEWAY" ] || return
    say 'Gateway changes can interrupt client traffic.'
    ask 'Stop sing-box and disable LAN TProxy gateway configuration?' || return
    if [ -x "$SERVICE" ]; then "$SERVICE" stop || return; fi
    /bin/bash "$GATEWAY" disable
}
inspect_xtunnel() {
    say 'X-Tunnel provider is a local sing-box provider; only its path needs matching.'
    [ -f "$CONFIG" ] || { say 'Install/configure sing-box first.'; return; }
    command -v jq >/dev/null 2>&1 || { say 'Install jq to inspect JSON provider settings.'; return; }
    jq -r '.providers[]? | select(.type == "local") | [.tag, .path] | @tsv' "$CONFIG" |
    while IFS="$(printf '\t')" read -r provider_tag path; do
        case "$path" in /*) ;; *) path=$SB_HOME/$path ;; esac
        say "Local provider $provider_tag: $path"
        if [ -f "$path" ]; then
            jq -e '.outbounds | type == "array"' "$path" >/dev/null 2>&1 &&
                say 'Provider structure: OK' || say 'Provider structure: INVALID'
        else
            say 'Provider missing. Match its configured path to the actual provider export file.'
        fi
    done
    say 'Important: if X-Tunnel runs as root, eBPF exclude_uid=0 would exclude ALL root processes.'
    say 'Review current X-Tunnel process UIDs and eBPF local.exclude_uid before enabling sing-box.'
    for pid in $(pidof x-tunnel 2>/dev/null || true); do
        [ -r "/proc/$pid/status" ] || continue
        uid=$(awk '/^Uid:/ {print $2; exit}' "/proc/$pid/status")
        say "x-tunnel PID=$pid UID=$uid"
    done
    jq -c '.inbounds[]? | select(.type == "ebpf") | .local.exclude_uid' "$CONFIG"
}
# Safety check: an X-Tunnel core captured by local eBPF may proxy its
# own upstream connection back through itself. Never silently exclude root.
preflight_xtunnel() {
    # Use the same UID/range checks as direct sbctl/procd startup.
    run_sbctl check-xtunnel
}

diagnose() {
    say 'Network diagnostics (read-only):'
    say "Service configuration: $CONFIG"
    uname -r
    grep cgroup2 /proc/mounts || say 'cgroup v2 not mounted'
    ip -4 route show default 2>/dev/null || true
    ip -4 rule show 2>/dev/null || true
    if command -v nft >/dev/null 2>&1; then
        nft list table inet singbox_one_arm 2>/dev/null || say 'LAN TProxy nftables table not active.'
    fi
    [ -f "$GATEWAY" ] && /bin/bash "$GATEWAY" status || true
    [ -x "$SERVICE" ] && "$SERVICE" status || true
}
source_update() {
    root_only || return
    [ -f "$REPO_DIR/quick-install.sh" ] || {
        say '一键脚本不存在。请从 openwrt-singbox-ebpf 公开仓库 main 分支下载 quick-install.sh。'
        return 1
    }
    if [ -d "$REPO_DIR/.git" ]; then
        command -v git >/dev/null 2>&1 || {
            say '当前目录是 Git 仓库，但设备没有 git。为保护本地工作区，请使用电脑更新仓库后再上传。'
            return 1
        }
        branch=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || true)
        case "$branch" in main|openwrt) ;; *)
            say "当前 Git 分支为 '$branch'，拒绝自动更新。"
            return 1
            ;; esac
        [ -z "$(git -C "$REPO_DIR" status --porcelain)" ] || {
            say '存在未提交的 Git 变更，拒绝自动更新。'
            return 1
        }
        load_download_library || return
        if [ "$SB_DOWNLOAD_MODE_RESOLVED" = github ]; then
            say 'GitHub 下载前缀用于源码压缩包；当前目录是 Git 工作树，请在「安装与更新 → 设置下载代理」选择 HTTP 代理或默认下载后拉取。'
            return 1
        fi
        ask "从当前远程拉取 $branch 分支？不会自动重启服务。" || return
        sb_download_run git -C "$REPO_DIR" pull --ff-only || return
    else
        say '在线更新使用 openwrt-singbox-ebpf 公开仓库 main 分支及当前下载代理设置。'
        printf '离线 ZIP/TAR.GZ 路径（回车直接在线更新）: '
        IFS= read -r archive || return
        ask '更新本地 OpenWrt 源码？不会重启服务。' || return
        if [ -n "$archive" ]; then
            SB_INSTALL_SOURCE_DIR="$REPO_DIR" sh "$REPO_DIR/quick-install.sh" --update --archive "$archive" --no-menu || return
        else
            SB_INSTALL_SOURCE_DIR="$REPO_DIR" sh "$REPO_DIR/quick-install.sh" --update --no-menu || return
        fi
    fi
    say "源码更新完成：$REPO_DIR"
    say "仅部署脚本到 $SB_HOME：在该源码目录执行 bash install.sh --scripts-only。"
    say '「安装与更新 → 安装/修复核心服务」是完整安装流程，可能更新运行中的内核。'
    say '仅更新源码不会重启 sing-box。'
}
configure_download_proxy() {
    root_only || return
    proxy_tool=$REPO_DIR/scripts/configure-download.sh
    [ -f "$proxy_tool" ] || proxy_tool=$SB_HOME/scripts/configure-download.sh
    [ -f "$proxy_tool" ] || { say 'Missing configure-download.sh; update the complete project.'; return 1; }
    sh "$proxy_tool" show || true
    say '1) 默认下载（继承系统环境）'
    say '2) 使用本地/局域网 HTTP 代理'
    say '3) 使用公开 GitHub 下载代理前缀'
    say '0) 返回'
    printf '选择下载方式: '
    IFS= read -r proxy_choice || return
    case "$proxy_choice" in
        1) sh "$proxy_tool" set direct || return ;;
        2|3)
            case "$proxy_choice" in
                2) proxy_mode=http; say '输入 HTTP 代理 URL，例如 http://127.0.0.1:7890。输入不会回显。' ;;
                3) proxy_mode=github; say '输入可信 GitHub 下载代理前缀，例如 https://ghfast.top/。输入不会回显。' ;;
            esac
            if ! (
                tty_state=
                if [ -t 0 ]; then
                    tty_state=$(stty -g) || exit 1
                    trap 'stty "$tty_state"' EXIT HUP INT TERM
                    stty -echo || exit 1
                fi
                printf 'URL: ' >&2
                IFS= read -r proxy_url || exit 1
                printf '\n' >&2
                printf '%s\n' "$proxy_url" | sh "$proxy_tool" set "$proxy_mode" --stdin
            ); then return 1; fi
            ;;
        0|'') return ;;
        *) say 'Unknown option.'; return 1 ;;
    esac
    unset SB_DOWNLOAD_MODE SB_HTTP_PROXY SB_GITHUB_PROXY
    say '下载设置已保存，本菜单后续安装/更新使用该设置；不修改 sing-box 代理流量配置。'
    sh "$proxy_tool" show
}
migrate_config() {
    root_only || return
    script="$REPO_DIR/scripts/migrate-config.sh"
    [ -f "$script" ] || script="$SB_HOME/scripts/migrate-config.sh"
    [ -f "$script" ] || {
        say '找不到迁移脚本。请先进入「安装与更新 → 更新公开仓库源码」。'
        return 1
    }
    [ -f "$CONFIG" ] || { say '现有 sing-box 配置不存在。'; return 1; }
    say '将移除旧版 DNS/block 出站，修复 sniff 和 DNS hijack 规则。'
    say '先备份并使用当前内核校验；失败时不写入原配置，不重启服务。'
    ask '现在修复现有 sing-box 配置？' || return
    /bin/bash "$script" "$CONFIG"
}
configure_pc_proxy() {
    root_only || return
    script="$SB_HOME/scripts/configure-pc-proxy.sh"
    [ -f "$script" ] || script="$REPO_DIR/scripts/configure-pc-proxy.sh"
    [ -f "$script" ] || { say '未找到 LAN 代理配置脚本，请更新公开仓库并部署配套脚本。'; return 1; }
    say '只允许将代理绑定到本机已有的 RFC1918 LAN IPv4，必须设置账号密码。'
    say '配置更新前会执行 sing-box check，失败则不替换原配置。'
    /bin/bash "$script" configure
}
disable_pc_proxy() {
    root_only || return
    script="$SB_HOME/scripts/configure-pc-proxy.sh"
    [ -f "$script" ] || script="$REPO_DIR/scripts/configure-pc-proxy.sh"
    [ -f "$script" ] || { say '未找到代理配置脚本。'; return 1; }
    ask '关闭 PC 的 HTTP/SOCKS5 LAN 监听入口？不会立即重启服务。' || return
    /bin/bash "$script" disable
}
apply_pc_privacy() {
    root_only || return
    script="$SB_HOME/scripts/apply-pc-privacy.sh"
    [ -f "$script" ] || script="$REPO_DIR/scripts/apply-pc-privacy.sh"
    [ -f "$script" ] || {
        say '未找到严格隐私策略脚本，请先更新公开仓库源码。'
        return 1
    }
    say '严格模式：PC DNS IPv4 优先、AI 独立 DNS 出站、拒绝 STUN/DTLS。'
    say '注意：视频通话/WebRTC 数据通道可能失效；LAN IPv6 仍须在客户端单独管理。'
    say '不会覆盖已有节点/Provider；校验通过才备份替换，不重启服务。'
    ask '将严格隐私策略合并到已安装配置？' || return
    /bin/bash "$script" apply
}
privacy_audit() {
    say 'PC 网络防泄漏检查（只读，静态配置不等于端到端安全）'
    if [ ! -f "$CONFIG" ]; then say '未安装配置。'; return 1; fi
    if ! command -v jq >/dev/null 2>&1; then say 'jq 未安装。'; return 1; fi
    jq -r '
       "IPv6 DNS NODATA: " + (if any(.dns.rules[]?;
           .action=="predefined" and .query_type==["AAAA"] and .rcode=="NOERROR")
           then "已配置" else "未配置" end),
       "AI DoH 使用 ai 出站: " + (if any(.dns.servers[]?;
           .tag=="dns-ai" and .detour=="ai") then "已配置" else "未配置" end),
       "AI 独立 DNS 规则: " + (if any(.dns.rules[]?;
           .server=="dns-ai") then "已配置" else "未配置" end),
       "WebRTC STUN/DTLS 严格阻断: " + (if any(.route.rules[]?;
           .action=="reject" and .type=="logical" and
           any(.rules[]?; .protocol? == ["stun","dtls"]))
           then "已配置" else "未配置" end),
       "LAN mixed HTTP/SOCKS5: " + ([.inbounds[]? | select(.tag=="lan-mixed")
           | "\(.listen):\(.listen_port), 账号数=\((.users // []) | length)"]
           | if length==0 then "未配置" else .[] end)
    ' "$CONFIG" || return
    if command -v ip >/dev/null 2>&1; then
        say 'OpenWrt IPv4 默认路由:'
        ip -4 route show default || true
        say 'OpenWrt IPv6 默认路由（不能代表 PC 的 IPv6 路由）：'
        ip -6 route show default || true
    fi
    if command -v nft >/dev/null 2>&1; then
        if nft list table inet singbox_one_arm >/dev/null 2>&1; then
            say 'LAN nftables TProxy 表: 已加载'
        else
            say 'LAN nftables TProxy 表: 未加载（未开启网关模式时正常）'
        fi
    fi
    say '重要：PC 必须自行检查默认网关、DNS、IPv6 路由与浏览器 WebRTC；'
    say '手动 HTTP/SOCKS5 代理不接管 PC 系统级 DNS，也不能阻止未代理应用或 IPv6 直连。'
}
align_xtunnel_ebpf() {
    root_only || return
    script="$SB_HOME/scripts/align-xtunnel-ebpf.sh"
    [ -f "$script" ] || script="$REPO_DIR/scripts/align-xtunnel-ebpf.sh"
    [ -f "$script" ] || {
        say '未找到 X-Tunnel UID 适配工具，请先更新 sing-box 公开仓库源码。'
        return 1
    }
    say '读取现有 X-Tunnel 内核的真实 UID，拒绝 root UID 0。'
    say '先验证新配置，再备份覆盖；不会重启 sing-box 或 X-Tunnel。'
    ask '自动对齐 eBPF exclude_uid 和已运行的 X-Tunnel UID？' || return
    /bin/bash "$script"
}
manage_routes() {
    route_tool=$SB_HOME/scripts/route-manager.sh
    [ -f "$route_tool" ] || route_tool=$REPO_DIR/scripts/route-manager.sh
    [ -f "$route_tool" ] || {
        say '未找到特色路由管理工具。请先更新源码并部署配套脚本。'
        return 1
    }
    [ -x /bin/bash ] || {
        say '特色路由工具需要 Bash。请先进入「安装与更新 → 安装/修复核心服务」。'
        return 1
    }
    /bin/bash "$route_tool" menu
}

uninstall_service() {
    root_only || return
    say '卸载会停止 sing-box 并移除本项目服务；保留配置、Provider 和 X-Tunnel。'
    ask '卸载 sing-box 服务并保留现有配置？' || return
    if [ -f "$SB_HOME/uninstall.sh" ]; then
        /bin/bash "$SB_HOME/uninstall.sh"
    elif [ -f "$REPO_DIR/uninstall.sh" ]; then
        /bin/bash "$REPO_DIR/uninstall.sh"
    else
        say 'Uninstaller missing.'
        return 1
    fi
}

# One entry per row stays readable in narrow SSH terminals with CJK text.
show_menu() {
    printf '\n==============================================\n'
    say ' reF1nd sing-box / OpenWrt SSH 管理菜单'
    printf ' 核心服务: %s | LAN 网关: %s | 包管理器: %s\n' \
        "$(service_status)" "$(gateway_status)" "$(package_manager)"
    printf ' 配置文件: %s\n' "$CONFIG"
    say '----------------------------------------------'
    say '   1) 服务管理'
    say '   2) 特色路由'
    say '   3) LAN 接入'
    say '   4) 配置与隐私'
    say '   5) 安装与更新'
    say '   6) 诊断与维护'
    say '   0) 退出'
    say ' 确认提示 [Y/n]：回车或 y 确认，n 或其他输入取消。'
}

show_submenu() {
    printf '\n----------------------------------------------\n'
    case "$1" in
        service)
            say ' 【服务管理】'
            say '   1) 查看服务状态'
            say '   2) 启动 sing-box'
            say '   3) 重启 sing-box'
            say '   4) 停止 sing-box'
            say '   5) 查看服务日志'
            say '   6) 配置校验'
            ;;
        lan)
            say ' 【LAN 接入】'
            say '   1) 设置 LAN 透明网关'
            say '   2) 查看网关状态'
            say '   3) 关闭 LAN 透明网关'
            say '   4) 配置 LAN HTTP/SOCKS5 代理'
            say '   5) 关闭 LAN HTTP/SOCKS5 入口'
            ;;
        config)
            say ' 【配置与隐私】'
            say '   1) 编辑配置'
            say '   2) 配置分文件模式 / 迁移'
            say '   3) 修复旧版 DNS/block 配置'
            say '   4) 应用 PC 严格隐私策略'
            say '   5) DNS/WebRTC/IPv6 防泄漏检查'
            ;;
        install)
            say ' 【安装与更新】'
            say '   1) 安装/修复核心服务'
            say '   2) 更新公开仓库源码'
            say '   3) 设置下载代理'
            say '   4) 更新规则集'
            say '   5) 更新 reF1nd 内核'
            ;;
        diagnostics)
            say ' 【诊断与维护】'
            say '   1) 检查 X-Tunnel 对接'
            say '   2) 对齐 X-Tunnel eBPF 进程 UID'
            say '   3) eBPF/路由诊断'
            say '   4) 卸载服务（保留配置）'
            ;;
    esac
    say '   0) 返回主菜单'
    say '   q) 退出'
}

# A single iterative dispatcher keeps actions in the selected category.
# Return 2 means EOF or an explicit quit, so the main loop exits as well.
run_submenu() {
    submenu_section=$1
    while :; do
        show_submenu "$submenu_section"
        printf '\n请选择：'
        IFS= read -r submenu_choice || return 2
        case "$submenu_choice" in
            0) return 0 ;;
            q|Q) return 2 ;;
        esac
        case "$submenu_section:$submenu_choice" in
            service:1) run_sbctl status ;;
            service:2) root_only && preflight_xtunnel && run_sbctl start ;;
            service:3) root_only && ask 'Restart sing-box? Proxy connections will briefly disconnect.' &&
                preflight_xtunnel && run_sbctl restart ;;
            service:4) root_only && ask 'Stop sing-box and remove gateway rules?' && run_sbctl stop ;;
            service:5) run_sbctl logs ;;
            service:6) run_sbctl check ;;
            lan:1) configure_gateway ;;
            lan:2) [ -f "$GATEWAY" ] && /bin/bash "$GATEWAY" status || say 'Gateway script not installed.' ;;
            lan:3) disable_gateway ;;
            lan:4) configure_pc_proxy ;;
            lan:5) disable_pc_proxy ;;
            config:1) edit_config ;;
            config:2) manage_config_parts ;;
            config:3) migrate_config ;;
            config:4) apply_pc_privacy ;;
            config:5) privacy_audit ;;
            install:1) install_core ;;
            install:2) source_update ;;
            install:3) configure_download_proxy ;;
            install:4) root_only && run_sbctl update-rules ;;
            install:5) root_only && ask 'Update sing-box core? Running service may restart.' && run_sbctl update-core ;;
            diagnostics:1) inspect_xtunnel ;;
            diagnostics:2) align_xtunnel_ebpf ;;
            diagnostics:3) diagnose; run_sbctl ebpf-status 2>/dev/null || true ;;
            diagnostics:4) uninstall_service ;;
            *) say '无效选项，请使用当前菜单中的编号。'; continue ;;
        esac
        wait_key || return 2
    done
}

while :; do
    show_menu
    printf '\n请选择分类：'
    IFS= read -r choice || break
    menu_status=0
    case "$choice" in
        1) run_submenu service || menu_status=$? ;;
        2) manage_routes || menu_status=$? ;;
        3) run_submenu lan || menu_status=$? ;;
        4) run_submenu config || menu_status=$? ;;
        5) run_submenu install || menu_status=$? ;;
        6) run_submenu diagnostics || menu_status=$? ;;
        0|q|Q) break ;;
        *) say '无效分类，请使用主菜单中的编号。' ;;
    esac
    [ "$menu_status" -ne 2 ] || break
done
