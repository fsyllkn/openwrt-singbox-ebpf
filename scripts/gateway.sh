#!/usr/bin/env bash
# LAN gateway: nftables TProxy for downstream packets. Preserve the user's
# existing eBPF/local interception and advanced sing-box routing configuration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
[ -r "$SCRIPT_DIR/runtime-paths.sh" ] || {
    echo 'gateway: runtime-paths.sh is missing; deploy the complete scripts directory or rerun install.sh.' >&2
    exit 1
}
# shellcheck source=runtime-paths.sh
. "$SCRIPT_DIR/runtime-paths.sh"
sb_load_paths || exit 1
HOME_DIR="$SH_SINGBOX_HOME"
CONFIG="$SH_SINGBOX_CONFIG"
RUNTIME="$HOME_DIR/runtime"
SETTINGS="$RUNTIME/gateway.json"
ACTIVE="$RUNTIME/gateway-active"
FORWARD_OWNED="$RUNTIME/gateway-forward-owned"
TABLE="singbox_one_arm"
ROUTE_TABLE=53136
RULE_PRIORITY=15360
MARK=0x1536
PORT=1536
# Allow CI to model forwarding without touching the runner's network state.
IP_FORWARD_FILE="${SH_SINGBOX_IP_FORWARD_FILE:-/proc/sys/net/ipv4/ip_forward}"
BOOT_ID_FILE="${SH_SINGBOX_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"

die() { echo "gateway: $*" >&2; exit 1; }
require_root() { [ "$(id -u)" -eq 0 ] || die "root is required"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing $1"; }

# The BusyBox ip applet shipped on some OpenWrt builds rejects nonstandard
# 32-bit routing-table IDs (e.g. 53136). ip-full/iproute2 is mandatory.
# Run this BEFORE changing forwarding, marking or any kernel routing state.
check_iproute2() {
    need ip
    local ip_version
    ip_version="$(ip -V 2>&1 || true)"
    case "$ip_version" in
        "ip utility, iproute2-"*) return 0 ;;
        *)
            die "full iproute2 ip is required for routing table $ROUTE_TABLE (found: ${ip_version:-unknown}). On OpenWrt install package ip-full with opkg/apk; BusyBox ip is unsupported. No routing changes applied."
            ;;
    esac
}

valid_ipv4_cidr() {
    local address prefix a b c d octet
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
    address="${1%/*}"; prefix="${1#*/}"
    IFS=. read -r a b c d <<< "$address"
    for octet in "$a" "$b" "$c" "$d"; do
        [ "$octet" -le 255 ] || return 1
    done
    [ "$prefix" -gt 0 ]
}

read_settings() {
    [ -f "$SETTINGS" ] || return 1
    need jq
    IFACE="$(jq -er '.interface' "$SETTINGS")" || die "invalid gateway settings"
    LAN_CIDR="$(jq -er '.source_cidr' "$SETTINGS")" || die "invalid gateway settings"
    [[ "$IFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid interface name"
    valid_ipv4_cidr "$LAN_CIDR" || die "invalid LAN CIDR"
}

check_interface() {
    need ip
    local addresses
    ip link show dev "$IFACE" >/dev/null 2>&1 || die "interface $IFACE does not exist"
    [ "$IFACE" != lo ] || die "loopback cannot be the LAN interface"
    addresses="$(ip -4 -o addr show dev "$IFACE" scope global)" ||
        die "cannot inspect IPv4 addresses on $IFACE"
    [ -n "$addresses" ] || die "$IFACE has no IPv4 address"
    # A saved client subnet must still overlap an address range on this LAN.
    # Compare ranges rather than requiring the router address to be inside the
    # selected source range: a narrower range may intentionally select clients.
    printf '%s\n' "$addresses" | awk -v source="$LAN_CIDR" '
      function ipv4(value, octets, count, j, number) {
        count = split(value, octets, "[.]")
        if (count != 4) return -1
        number = 0
        for (j = 1; j <= 4; j++) {
          if (octets[j] !~ /^[0-9]+$/ || octets[j] > 255) return -1
          number = number * 256 + octets[j]
        }
        return number
      }
      BEGIN {
        split(source, wanted, "/")
        source_block = 2 ^ (32 - wanted[2])
        source_first = int(ipv4(wanted[1]) / source_block) * source_block
        source_last = source_first + source_block - 1
      }
      {
        for (i = 1; i < NF; i++) {
          if ($i != "inet") continue
          if (split($(i + 1), address, "/") != 2) continue
          if (address[2] !~ /^[0-9]+$/ || address[2] > 32) continue
          number = ipv4(address[1])
          if (number < 0) continue
          block = 2 ^ (32 - address[2])
          first = int(number / block) * block
          last = first + block - 1
          if (source_first <= last && source_last >= first) overlap = 1
        }
      }
      END { exit !overlap }
    ' || die "LAN source CIDR $LAN_CIDR does not overlap any IPv4 subnet on $IFACE; reconfigure the actual LAN interface/subnet. Settings and routing state unchanged."
}

check_tproxy_inbound() {
    local count
    count="$(jq '[.inbounds[]? | select(.tag == "lan-tproxy")] | length' "$CONFIG")" ||
        die "cannot inspect lan-tproxy in $CONFIG"
    [ "$count" -le 1 ] || die "multiple inbounds use tag lan-tproxy; configuration unchanged"
    if [ "$count" -eq 0 ]; then
        [ "${1:-required}" = optional ] && return 0
        die "lan-tproxy inbound is missing"
    fi
    jq -e --argjson port "$PORT" 'any(.inbounds[]?;
      .tag == "lan-tproxy" and .type == "tproxy" and .listen_port == $port)' "$CONFIG" >/dev/null ||
        die "tag lan-tproxy must be a tproxy inbound on managed port $PORT; existing custom inbound was not overwritten"
}

check_shared_interception() {
    if jq -e 'any(.inbounds[]?; .type == "ebpf" and .shared.enabled == true)' "$CONFIG" >/dev/null; then
        die "enabled eBPF shared interception already exists; choose shared or the managed LAN TProxy mode explicitly before configuring this gateway. Existing inbound options were not changed."
    fi
}

configure() {
    require_root; need jq; need nft; check_iproute2
    [ "$#" -eq 2 ] || die "usage: gateway.sh configure INTERFACE LAN_CIDR"
    IFACE="$1"; LAN_CIDR="$2"
    [[ "$IFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid interface name"
    valid_ipv4_cidr "$LAN_CIDR" || die "invalid LAN CIDR: $LAN_CIDR"
    check_interface
    [ -f "$CONFIG" ] || die "configuration not found: $CONFIG"
    jq -e '.inbounds | type == "array"' "$CONFIG" >/dev/null \
        || die "configuration must contain an inbounds array"
    check_shared_interception
    check_tproxy_inbound optional
    mkdir -p "$RUNTIME"
    local target tmp settings_tmp backup
    target="$(readlink -f "$CONFIG")" || die "cannot resolve configuration target: $CONFIG"
    [ -f "$target" ] || die "configuration target not found: $target"
    tmp="$(mktemp "${target}.gateway.XXXXXX")"
    settings_tmp="$(mktemp "$RUNTIME/gateway.json.XXXXXX")"
    backup="$target.gateway.$(date +%Y%m%d-%H%M%S).$$.bak"
    jq --argjson port "$PORT" '
      if any(.inbounds[]?; .tag == "lan-tproxy") then .
      else .inbounds += [{"type":"tproxy","tag":"lan-tproxy","listen":"0.0.0.0","listen_port":$port}]
      end
    ' "$target" > "$tmp" || { rm -f "$tmp" "$settings_tmp"; die "cannot update JSON"; }
    if [ -f "$SETTINGS" ]; then
        jq --arg interface "$IFACE" --arg source_cidr "$LAN_CIDR" \
            '.interface=$interface | .source_cidr=$source_cidr' "$SETTINGS" > "$settings_tmp" ||
            { rm -f "$tmp" "$settings_tmp"; die "cannot update existing gateway settings"; }
    else
        jq -n --arg interface "$IFACE" --arg source_cidr "$LAN_CIDR" \
            '{interface:$interface,source_cidr:$source_cidr}' > "$settings_tmp"
    fi
    cp -p "$target" "$backup"
    chmod --reference="$target" "$tmp" 2>/dev/null || chmod 0600 "$tmp"
    mv -f "$tmp" "$target"
    mv -f "$settings_tmp" "$SETTINGS"
    echo "Configured LAN TProxy gateway on $IFACE for $LAN_CIDR; backup: $backup"
    echo "Run 'sbctl preflight' and 'sbctl restart' before changing a client gateway."
}

# Precisely identify our own policy rule, even if runtime/gateway-active was
# lost across a failed procd stop, reboot or an earlier interrupted restart.
is_own_rule_line() {
    printf '%s\n' "$1" |
        grep -Eq "^${RULE_PRIORITY}:[[:space:]]+from all[[:space:]]+fwmark 0x0*1536(/0xffffffff)?[[:space:]]+lookup ${ROUTE_TABLE}([[:space:]]+proto [[:alnum:]_-]+)?[[:space:]]*$"
}

has_own_rule() {
    local rows row
    rows="$(ip -4 -N rule show)" || die "cannot inspect existing IPv4 policy rules"
    while IFS= read -r row; do
        if is_own_rule_line "$row"; then return 0; fi
    done <<< "$rows"
    return 1
}

priority_is_safe() {
    local rows row
    rows="$(ip -4 -N rule show)" || die "cannot inspect IPv4 policy rules"
    while IFS= read -r row; do
        case "$row" in
            "${RULE_PRIORITY}:"*)
                is_own_rule_line "$row" ||
                    die "IP rule priority $RULE_PRIORITY belongs to another policy: $row; refusing to modify it"
                ;;
        esac
    done <<< "$rows"
}

# A table-specific dump can fail with "FIB table does not exist" / "Dump
# terminated" when the table has not been created (or its last route was
# removed). Dump all IPv4 tables instead and select our exact numeric table.
# -N also prevents /etc/iproute2/rt_tables aliases from hiding table 53136.
# A real netlink/dump failure must still abort before any networking changes.
read_route_table() {
    local rows
    rows="$(ip -4 -o -N route show table all)" || return 1
    printf '%s\n' "$rows" | awk -v table="$ROUTE_TABLE" '
      { for (i = 1; i < NF; i++) {
          if ($i == "table" && $(i + 1) == table) { print; break }
        }
      }
    '
}

# With -N, iproute2 prints RTN_LOCAL as 2 and may use "default" or "0.0.0.0/0".
has_own_route() {
    local rows count
    rows="$(read_route_table)" ||
        die "cannot inspect IPv4 routing table $ROUTE_TABLE"
    [ -n "$rows" ] || return 1
    count="$(printf '%s\n' "$rows" | grep -c .)" || true
    [ "$count" -eq 1 ] &&
        printf '%s\n' "$rows" |
        grep -Eq '^(local|2) (default|0\.0\.0\.0/0) dev lo([[:space:]]|$)'
}

routing_table_is_safe() {
    local rows
    rows="$(read_route_table)" ||
        die "cannot inspect IPv4 routing table $ROUTE_TABLE"
    [ -z "$rows" ] && return 0
    has_own_route ||
        die "routing table $ROUTE_TABLE contains a foreign or unexpected route; refusing cleanup"
}

# The nft table name alone is not ownership evidence. Our exact ruleset has
# four IPv4 TPROXY redirects to port 1536 carrying the 0x1536 fwmark.
nft_table_is_ours() {
    local rules count marks
    rules="$(nft list table inet "$TABLE" 2>/dev/null)" || return 1
    printf '%s\n' "$rules" | grep -Fq "table inet $TABLE" || return 1
    printf '%s\n' "$rules" | grep -Fq 'chain prerouting {' || return 1
    count="$(printf '%s\n' "$rules" | grep -Fc "tproxy ip to :$PORT")" || true
    marks="$(printf '%s\n' "$rules" | grep -Ec 'meta mark set 0x0*1536([[:space:]]|$)')" || true
    [ "$count" -eq 4 ] && [ "$marks" -ge 4 ]
}

nft_table_is_safe() {
    if nft list table inet "$TABLE" >/dev/null 2>&1; then
        nft_table_is_ours ||
            die "nft table inet $TABLE exists but does not match this project's TPROXY rules; refusing to delete it"
    fi
}

# Validate all resources BEFORE mutating one, including when ACTIVE is absent.
check_existing_ownership() {
    priority_is_safe
    routing_table_is_safe
    nft_table_is_safe
}

cleanup() {
    require_root
    # No gateway configuration or activation marker: do not sweep networking.
    if [ -f "$SETTINGS" ] || [ -f "$ACTIVE" ]; then
        need ip; need nft
        check_existing_ownership
        if nft list table inet "$TABLE" >/dev/null 2>&1; then
            nft delete table inet "$TABLE"
        fi
        # Delete only our exact mark/table rule. Preserve unrelated priorities.
        local deleted=0
        while has_own_rule; do
            deleted=$((deleted + 1))
            [ "$deleted" -le 32 ] ||
                die "cannot remove owned IPv4 rule $RULE_PRIORITY after 32 attempts"
            ip -4 rule del priority "$RULE_PRIORITY" fwmark "$MARK" table "$ROUTE_TABLE" ||
                die "failed to delete owned IP rule; inspect ip -4 rule show"
        done
        if has_own_route; then
            ip -4 route del local 0.0.0.0/0 dev lo table "$ROUTE_TABLE" ||
                die "failed to delete owned local route; inspect table $ROUTE_TABLE"
        fi
        rm -f "$ACTIVE"
    fi
    if [ -f "$FORWARD_OWNED" ]; then
        if [ "$(cat "$FORWARD_OWNED")" = "$(cat "$BOOT_ID_FILE")" ] &&
           [ "$(cat "$IP_FORWARD_FILE")" = 1 ]; then
            echo 0 > "$IP_FORWARD_FILE"
        fi
        rm -f "$FORWARD_OWNED"
    fi
}

apply() {
    require_root
    [ -f "$SETTINGS" ] || return 0
    read_settings; check_interface; need nft; check_iproute2
    [ -f "$CONFIG" ] || die "configuration not found"
    check_tproxy_inbound
    check_shared_interception
    # Only packets entering the selected LAN are captured. The upstream may
    # use another device or policy table; sing-box and the host choose it.
    # Safely reconcile exact owned kernel resources even if a failed stop left
    # the old policy route but deleted runtime/gateway-active.
    check_existing_ownership
    cleanup

    # Validate the exact nftables ruleset before changing ip_forward or
    # routing-table state. inet + ip saddr needs an explicit IPv4 TPROXY family
    # on current OpenWrt nftables (otherwise: ip vs unknown parser error).
    local nft_rules
    nft_rules="$(mktemp "$RUNTIME/.gateway-nft.XXXXXX")" || die "cannot create nft preflight file"
    # ShellCrash-style explicit table -> chain -> rules sequence. All commands
    # stay in ONE nft batch, so either the whole table is installed or none is.
    # Never flush fw4 or an unrelated service's nftables objects.
    cat > "$nft_rules" <<EOF
add table inet $TABLE
add chain inet $TABLE prerouting { type filter hook prerouting priority mangle; policy accept; }
# Intercept DNS before any on-link exemptions (TCP and UDP 53).
add rule inet $TABLE prerouting iifname "$IFACE" ip saddr $LAN_CIDR meta l4proto tcp tcp dport 53 counter tproxy ip to :$PORT meta mark set $MARK accept
add rule inet $TABLE prerouting iifname "$IFACE" ip saddr $LAN_CIDR meta l4proto udp udp dport 53 counter tproxy ip to :$PORT meta mark set $MARK accept
# Preserve access to this router and reserved destinations. Other private
# destinations, including routed traffic within the LAN prefix, are decided
# by sing-box route rules so explicit private-CIDR proxy rules remain effective.
add rule inet $TABLE prerouting iifname "$IFACE" ip saddr $LAN_CIDR fib daddr type local counter return
add rule inet $TABLE prerouting iifname "$IFACE" ip saddr $LAN_CIDR ip daddr { 0.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } counter return
# Remaining IPv4 TCP/UDP to transparent inbound; packets receive 0x1536 mark.
add rule inet $TABLE prerouting iifname "$IFACE" ip saddr $LAN_CIDR meta l4proto tcp counter tproxy ip to :$PORT meta mark set $MARK accept
add rule inet $TABLE prerouting iifname "$IFACE" ip saddr $LAN_CIDR meta l4proto udp counter tproxy ip to :$PORT meta mark set $MARK accept
EOF
    if ! nft -c -f "$nft_rules"; then
        rm -f "$nft_rules"
        die "nftables TProxy syntax check failed; forwarding and routing state unchanged"
    fi
    if [ "$(cat "$IP_FORWARD_FILE")" = 0 ]; then
        echo 1 > "$IP_FORWARD_FILE"
        cat "$BOOT_ID_FILE" > "$FORWARD_OWNED"
    fi
    trap 'rm -f "$nft_rules"; cleanup' ERR
    ip -4 route add local 0.0.0.0/0 dev lo table "$ROUTE_TABLE"
    ip -4 rule add fwmark "$MARK" table "$ROUTE_TABLE" priority "$RULE_PRIORITY"
    nft -f "$nft_rules"
    # Marker is committed only after route, rule and nft all succeed.
    : > "$ACTIVE"
    rm -f "$nft_rules"
    trap - ERR
    echo "LAN TProxy gateway active on $IFACE ($LAN_CIDR); local interception settings preserved."
}

disable() {
    require_root; need jq
    cleanup
    [ -f "$CONFIG" ] || die "configuration not found"
    local target tmp
    target="$(readlink -f "$CONFIG")" || die "cannot resolve configuration target: $CONFIG"
    [ -f "$target" ] || die "configuration target not found: $target"
    tmp="$(mktemp "${target}.gateway.XXXXXX")"
    jq --argjson port "$PORT" '.inbounds |= map(select(
      (.tag == "lan-tproxy" and .type == "tproxy" and .listen_port == $port) | not))' "$target" > "$tmp"
    chmod --reference="$target" "$tmp" 2>/dev/null || chmod 0600 "$tmp"
    mv -f "$tmp" "$target"
    rm -f "$SETTINGS"
    echo "LAN TProxy gateway disabled; restart sing-box to apply listener changes."
}

case "${1:-}" in
    configure) shift; configure "$@" ;;
    requirements) need jq; need nft; check_iproute2; echo "Gateway routing tools: OK (full iproute2 / nft / jq)" ;;
    apply) apply ;;
    cleanup) cleanup ;;
    disable) disable ;;
    status)
        if read_settings; then
            echo "Configured: $IFACE ($LAN_CIDR)"
            if [ -f "$ACTIVE" ] && command -v nft >/dev/null 2>&1 && \
               nft list table inet "$TABLE" >/dev/null 2>&1 && has_own_rule; then
                echo "Firewall and policy route: active"
            else
                echo "Firewall and policy route: inactive or incomplete"
            fi
        else
            echo "LAN TProxy gateway is not configured"
        fi ;;
    *) die "usage: gateway.sh {requirements|configure INTERFACE LAN_CIDR|apply|cleanup|disable|status}" ;;
esac
