#!/usr/bin/env bash
# Configure an authenticated mixed (HTTP CONNECT / SOCKS5) LAN inbound.
# Fail closed, preserve credentials in chmod 0600 config, and do not restart.
set -euo pipefail

SCRIPT_FILE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
. "$(dirname "$SCRIPT_FILE")/runtime-paths.sh"
sb_load_paths || exit 1
umask 077

HOME_DIR="$SH_SINGBOX_HOME"
CONFIG="$SH_SINGBOX_CONFIG"
BIN="$HOME_DIR/bin/sing-box"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[sing-box] %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || die 'Run as root.'
for cmd in jq ip mktemp; do command -v "$cmd" >/dev/null 2>&1 || die "Missing $cmd"; done
[ -f "$CONFIG" ] || die "Missing config: $CONFIG"
CONFIG="$(readlink -f "$CONFIG")" || die 'Cannot resolve the active config target.'
[ -x "$BIN" ] || die "Missing reF1nd binary: $BIN"

case "${1:-}" in
    status)
        jq -r '
          [.inbounds[]? | select(.type=="mixed" and .tag=="lan-mixed")
           | "\(.listen):\(.listen_port) (authenticated users: \((.users // []) | length))"]
          | if length == 0 then "Not configured" else .[] end
        ' "$CONFIG"
        exit 0 ;;
    configure|disable) ;;
    *) die 'Usage: configure-pc-proxy.sh {configure|disable|status}' ;;
esac
action=$1

TMP=$(mktemp "$(dirname "$CONFIG")/.lan-mixed.XXXXXX") || die 'Cannot stage config'
CHECKLOG=$(mktemp "$(dirname "$CONFIG")/.lan-check.XXXXXX") || die 'Cannot stage log'
PASSFILE=
cleanup() { rm -f "$TMP" "$CHECKLOG"; [ -z "$PASSFILE" ] || rm -f "$PASSFILE"; }
trap cleanup EXIT

if [ "$action" = configure ]; then
    jq -e '
        [.inbounds[]? | select(.tag=="lan-mixed")] as $matches
        | ($matches|length)<=1 and all($matches[]; .type=="mixed")
    ' "$CONFIG" >/dev/null || die 'lan-mixed must identify at most one mixed inbound; inspect duplicate/custom tags manually.'
    current_listen=$(jq -r '.inbounds[]? | select(.tag=="lan-mixed") | .listen // empty' "$CONFIG")
    current_port=$(jq -r '.inbounds[]? | select(.tag=="lan-mixed") | .listen_port // empty' "$CONFIG")
    echo 'Configure a LAN-only authenticated HTTP/SOCKS5 proxy.'
    echo 'The listen IP must be an IPv4 address currently assigned to this OpenWrt router.'
    ip -4 -o addr show scope global
    read -r -p "LAN listen IPv4${current_listen:+ [$current_listen]}: " listen
    listen=${listen:-$current_listen}
    [[ "$listen" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die 'Invalid IPv4 address'
    IFS=. read -r a b c d <<< "$listen"
    for octet in "$a" "$b" "$c" "$d"; do
        (( ${#octet} <= 3 && 10#$octet <= 255 )) || die 'Invalid IPv4 address'
    done
    case "$listen" in
        10.*|192.168.*) ;;
        172.*)
            second="${listen#172.}"; second="${second%%.*}"
            [[ "$second" =~ ^[0-9]+$ ]] && (( 10#$second >= 16 && 10#$second <= 31 )) ||
                die 'LAN listen address must be RFC1918 private IP' ;;
        *) die 'LAN listen address must be an RFC1918 private IP; never expose an HTTP/SOCKS proxy publicly' ;;
    esac
    ip -4 -o addr show | grep -F " $listen/" >/dev/null ||
        die 'This IP is not assigned to the router; choose a real LAN interface address'

    current_port=${current_port:-7891}
    read -r -p "Port [$current_port]: " port
    port="${port:-$current_port}"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1024 && 10#$port <= 65535 )) ||
        die 'Port must be 1024..65535'
    port=$((10#$port))
    # Inspect actual configured listeners and local SOCKS backends. Node ports
    # and dashboard ports vary between installations; no fixed port blacklist.
    port_conflict=$(jq -r --arg ip "$listen" --argjson port "$port" '
        def overlaps: . == $ip or . == "0.0.0.0" or . == "::" or . == "[::]";
        any(.inbounds[]?; .tag!="lan-mixed" and .listen_port==$port and ((.listen // "::") | overlaps))
        or any(.services[]?; .listen_port==$port and ((.listen // "::") | overlaps))
        or any(.outbounds[]?; .type=="socks" and .server_port==$port and .server==$ip)
        or ((.experimental.clash_api.external_controller // "" |
             try capture("^(?<host>.*):(?<port>[0-9]+)$") catch null) as $api
            | $api != null and ($api.port|tonumber)==$port and ($api.host|overlaps))
    ' "$CONFIG") || die 'Cannot inspect configured listener ports; original config unchanged.'
    if [ "$port_conflict" = true ]; then
        die 'Port conflicts with another configured listener or a SOCKS backend at this address; choose an unused port.'
    fi
    read -r -p 'Proxy username (updates this user; preserves other users): ' username
    [[ "$username" =~ ^[a-zA-Z0-9_.-]{1,32}$ ]] ||
        die 'Username must be 1-32 safe ASCII characters'
    read -r -s -p 'Proxy password (minimum 12 characters): ' password
    printf '\n'
    [ "${#password}" -ge 12 ] || die 'Password too short'

    # Passing passwords to jq --arg would expose them in /proc/PID/cmdline.
    # Use a mode-0600 file in OpenWrt /tmp (normally tmpfs) instead.
    PASSFILE=$(mktemp /tmp/sb-pc-proxy-pass.XXXXXX) || die 'Cannot stage password'
    chmod 0600 "$PASSFILE"
    printf '%s' "$password" > "$PASSFILE"
    unset password
    jq --arg ip "$listen" --argjson port "$port" \
       --arg username "$username" --rawfile password "$PASSFILE" '
      def update_listener:
        .listen=$ip | .listen_port=$port
        | .users = ([.users[]? | select(.username != $username)]
                    + [{"username":$username,"password":$password}]);
      .inbounds |=
        if any(.[]; .tag=="lan-mixed")
        then map(if .tag=="lan-mixed" then update_listener else . end)
        else . + [({"type":"mixed","tag":"lan-mixed"} | update_listener)] end
    ' "$CONFIG" > "$TMP" || die 'Could not stage proxy configuration'
    rm -f "$PASSFILE"
    PASSFILE=
else
    jq '.inbounds |= map(select(.tag != "lan-mixed"))' "$CONFIG" > "$TMP" ||
        die 'Could not stage proxy removal'
fi

if ! (cd "$HOME_DIR" && "$BIN" check -c "$TMP") > "$CHECKLOG" 2>&1; then
    echo '[ERROR] Staged configuration failed sing-box check:' >&2
    # Do not echo secret-bearing command arguments or config contents.
    sed -n '1,30p' "$CHECKLOG" >&2
    die 'Original config was not changed. Fix other configuration problems first.'
fi
backup="$CONFIG.before-lan-mixed.$(date +%Y%m%d-%H%M%S).$$.bak"
cp "$CONFIG" "$backup" || die 'Cannot create backup'
chmod 0600 "$backup"
mv -f "$TMP" "$CONFIG"
chmod 0600 "$CONFIG"
rm -f "$HOME_DIR/runtime/config.valid" 2>/dev/null || true
info "Validated and saved; backup: $backup"
info 'Restart sing-box manually using sb menu option 3 when ready.'
info 'For SOCKS5, enable remote DNS (SOCKS5h); manual proxy does not capture the PC system DNS/IPv6.'
