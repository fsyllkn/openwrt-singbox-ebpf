#!/bin/sh
# Exercise menu selection with isolated UCI, interface and gateway fixtures.
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP=$(mktemp -d /tmp/sb-menu-lan.XXXXXX)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin" "$TMP/checkout/scripts" "$TMP/home/scripts" "$TMP/home/runtime" "$TMP/custom config"
cp "$BASE/scripts/runtime-paths.sh" "$BASE/scripts/config-parts-lib.sh" "$BASE/scripts/config-parts.sh" "$BASE/scripts/terminal-input.sh" "$TMP/checkout/scripts/"
cp "$BASE/scripts/runtime-paths.sh" "$BASE/scripts/config-parts-lib.sh" "$BASE/scripts/config-parts.sh" "$BASE/scripts/terminal-input.sh" "$TMP/home/scripts/"
: > "$TMP/checkout/install.sh"

# Keep the production path setup/functions intact. Omit only the OS guard and
# interactive dispatch so the functions can run under sh without a real router.
awk '
  /^\[ -f \/etc\/openwrt_release \] \|\| \{/ { skip = 1; next }
  skip { if ($0 == "}") skip = 0; next }
  /^while :; do$/ { exit }
  { print }
' "$BASE/menu.sh" > "$TMP/checkout/menu.sh"
cat >> "$TMP/checkout/menu.sh" <<'SH'
case "$1" in
    paths) printf '%s\n' "$SB_HOME" "$CONFIG" "$GATEWAY" "$SBCTL" ;;
    default) gateway_default_cidr "$2" ;;
    interface) gateway_default_interface ;;
    source) printf '%s\n' "$REPO_DIR" ;;
    configure) configure_gateway ;;
    update) source_update ;;
    download)
        configure_download_proxy
        printf '%s\n' "${SB_DOWNLOAD_MODE-unset}" "${SB_HTTP_PROXY-unset}" "${SB_GITHUB_PROXY-unset}" > "$TEST_ROOT/download-env"
        ;;
    screen) show_menu ;;
    *) exit 66 ;;
esac
SH
cp "$TMP/checkout/menu.sh" "$TMP/home/scripts/menu.sh"

cat > "$TMP/bin/uci" <<'SH'
#!/bin/sh
case "$*" in
    '-q get sing-box.main.service_dir') printf '%s/home\n' "$TEST_ROOT" ;;
    '-q get sing-box.main.config_file') printf '%s/custom config/live.json\n' "$TEST_ROOT" ;;
    '-q get sing-box.main.source_dir') [ -n "${MOCK_UCI_SOURCE:-}" ] || exit 1; printf '%s\n' "$MOCK_UCI_SOURCE" ;;
    '-q get network.lan.device') [ -n "${MOCK_UCI_LAN_DEVICE:-}" ] || exit 1; printf '%s\n' "$MOCK_UCI_LAN_DEVICE" ;;
    '-q get network.lan.ifname') [ -n "${MOCK_UCI_LAN_IFNAME:-}" ] || exit 1; printf '%s\n' "$MOCK_UCI_LAN_IFNAME" ;;
    *) exit 1 ;;
esac
SH
cat > "$TMP/bin/ip" <<'SH'
#!/bin/sh
emit_addresses() {
    iface=$1
    case "${MOCK_NETWORK:-single}" in
        single)
            echo "4: $iface inet 10.23.40.45/23 brd 10.23.41.255 scope global $iface" ;;
        same_subnet)
            echo "4: $iface inet 10.23.40.45/23 brd 10.23.41.255 scope global $iface"
            echo "4: $iface inet 10.23.41.88/23 brd 10.23.41.255 scope global secondary $iface" ;;
        multiple)
            echo "4: $iface inet 10.23.40.45/23 brd 10.23.41.255 scope global $iface"
            echo "4: $iface inet 172.20.9.1/24 brd 172.20.9.255 scope global secondary $iface" ;;
        absent) : ;;
        failure)
            echo "4: $iface inet 10.23.40.45/23 brd 10.23.41.255 scope global $iface"
            return 2 ;;
        high)
            echo "4: $iface inet 192.168.255.254/17 brd 192.168.255.255 scope global $iface" ;;
        *) return 66 ;;
    esac
}
case "$*" in
    'link show dev '*)
        for valid in ${MOCK_LINKS:-br-lan}; do [ "$4" != "$valid" ] || exit 0; done
        exit 1 ;;
    '-4 route show default') echo 'default via 10.23.40.1 dev br-lan' ;;
    '-4 -o addr show scope global')
        case "${MOCK_INTERFACE_MODE:-single}" in
            single) emit_addresses "${MOCK_GLOBAL_LINK:-br-lan}" ;;
            multiple)
                echo '4: lan0 inet 10.23.40.45/23 brd 10.23.41.255 scope global lan0'
                echo '5: wan0 inet 203.0.113.2/24 brd 203.0.113.255 scope global wan0' ;;
            absent) : ;;
            failure)
                emit_addresses "${MOCK_GLOBAL_LINK:-br-lan}"
                exit 2 ;;
            *) exit 66 ;;
        esac ;;
    '-4 -o addr show dev '*) emit_addresses "$6" ;;
    *) echo "Unexpected ip invocation: $*" >&2; exit 66 ;;
esac
SH
cat > "$TMP/bin/ubus" <<'SH'
#!/bin/sh
[ "$*" = 'call network.interface.lan status' ] || exit 66
[ -n "${MOCK_UBUS_LAN:-}" ] || exit 1
printf '{"l3_device":"%s","device":"ignored-device"}\n' "$MOCK_UBUS_LAN"
SH
cat > "$TMP/bin/nft" <<'SH'
#!/bin/sh
echo 'Unexpected nft operation' >&2
exit 66
SH
cat > "$TMP/bin/id" <<'SH'
#!/bin/sh
[ "$*" = -u ] || exit 66
printf '0\n'
SH
cat > "$TMP/home/scripts/gateway.sh" <<'SH'
#!/bin/sh
case "$1" in
    requirements) exit 0 ;;
    configure)
        printf '%s\n' "$*" "$SH_SINGBOX_HOME" "$SH_SINGBOX_CONFIG" > "$TEST_ROOT/applied"
        ;;
    *) exit 66 ;;
esac
SH
chmod 0755 "$TMP/bin/"* "$TMP/home/scripts/gateway.sh"
TEST_ROOT=$TMP
PATH=$TMP/bin:$PATH
export TEST_ROOT PATH
unset SH_SINGBOX_HOME SH_SINGBOX_CONFIG SB_INSTALL_SOURCE_DIR MOCK_UCI_SOURCE \
    MOCK_UCI_LAN_DEVICE MOCK_UCI_LAN_IFNAME MOCK_UBUS_LAN MOCK_INTERFACE_MODE MOCK_GLOBAL_LINK MOCK_LINKS
printf '{"interface":"br-lan","source_cidr":"192.168.50.0/24"}\n' > "$TMP/home/runtime/gateway.json"

fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
printf '%s\n' "$TMP/home" "$TMP/custom config/live.json" \
    "$TMP/home/scripts/gateway.sh" "$TMP/home/scripts/sbctl" > "$TMP/expected-paths"
for menu in "$TMP/checkout/menu.sh" "$TMP/home/scripts/menu.sh"; do
    sh "$menu" paths > "$TMP/paths"
    cmp "$TMP/expected-paths" "$TMP/paths" || fail 'menu paths do not follow UCI'
done

[ "$(sh "$TMP/checkout/menu.sh" default br-lan)" = 10.23.40.0/23 ] || fail 'wrong /23 network'
[ "$(MOCK_NETWORK=same_subnet sh "$TMP/checkout/menu.sh" default br-lan)" = 10.23.40.0/23 ] || fail 'same-subnet aliases are ambiguous'
[ "$(MOCK_NETWORK=high sh "$TMP/checkout/menu.sh" default br-lan)" = 192.168.128.0/17 ] || fail 'IPv4 network arithmetic overflow'
for network in multiple absent failure; do
    if MOCK_NETWORK=$network sh "$TMP/checkout/menu.sh" default br-lan > "$TMP/default"; then
        fail "guessed subnet for $network"
    fi
    [ ! -s "$TMP/default" ] || fail "printed a guessed default for $network"
done

printf '\n\ny\n' | sh "$TMP/checkout/menu.sh" configure > "$TMP/configure.log"
printf '%s\n' 'configure br-lan 10.23.40.0/23' "$TMP/home" "$TMP/custom config/live.json" > "$TMP/expected-apply"
cmp "$TMP/expected-apply" "$TMP/applied" || fail 'configure used stale subnet or wrong runtime paths'
grep -Fq 'LAN subnet CIDR [10.23.40.0/23]' "$TMP/configure.log" || fail 'actual subnet absent from prompt'
if grep -Fq '192.168.50.0/24' "$TMP/configure.log"; then fail 'stale saved subnet used as default'; fi

rm "$TMP/applied"
if printf '\n\n' | MOCK_NETWORK=multiple sh "$TMP/checkout/menu.sh" configure > "$TMP/ambiguous.log"; then
    fail 'blank ambiguous subnet accepted'
fi
[ ! -e "$TMP/applied" ] || fail 'gateway changed with ambiguous subnet'
printf '\n172.20.9.0/24\ny\n' | MOCK_NETWORK=multiple sh "$TMP/checkout/menu.sh" configure > "$TMP/explicit.log"
grep -Fxq 'configure br-lan 172.20.9.0/24' "$TMP/applied" || fail 'explicit subnet choice was ignored'

SH_SINGBOX_HOME="$TMP/override home" sh "$TMP/checkout/menu.sh" paths > "$TMP/override-paths"
head -n 2 "$TMP/override-paths" > "$TMP/override-short"
printf '%s\n' "$TMP/override home" "$TMP/override home/config/config.json" > "$TMP/override-expected"
cmp "$TMP/override-expected" "$TMP/override-short" || fail 'explicit HOME override mixed with UCI config'

# Source checkout discovery works after menu.sh was copied away from checkout.
mkdir -p "$TMP/recent source" "$TMP/older source" "$TMP/explicit source"
for source in "$TMP/recent source" "$TMP/older source" "$TMP/explicit source"; do
    : > "$source/install.sh"
done
printf '%s\n' "$TMP/recent source" > "$TMP/home/runtime/source-dir"
MOCK_UCI_SOURCE=$TMP/older\ source; export MOCK_UCI_SOURCE
[ "$(sh "$TMP/checkout/menu.sh" source)" = "$TMP/checkout" ] || fail 'checkout menu lost its own source'
[ "$(sh "$TMP/home/scripts/menu.sh" source)" = "$TMP/recent source" ] || fail 'new scripts-only source record did not override old UCI source'
[ "$(SB_INSTALL_SOURCE_DIR="$TMP/explicit source" sh "$TMP/checkout/menu.sh" source)" = "$TMP/explicit source" ] || fail 'explicit source did not override checkout'
[ "$(SB_INSTALL_SOURCE_DIR="$TMP/explicit source" sh "$TMP/home/scripts/menu.sh" source)" = "$TMP/explicit source" ] || fail 'explicit source did not override installed records'
printf '%s\n' "$TMP/deleted source" > "$TMP/home/runtime/source-dir"
[ "$(sh "$TMP/home/scripts/menu.sh" source)" = "$TMP/older source" ] || fail 'stale runtime record prevented UCI fallback'
printf '%s\n' "$TMP/recent source" > "$TMP/home/runtime/source-dir"
MOCK_UCI_SOURCE=$TMP/deleted\ UCI\ source; export MOCK_UCI_SOURCE
[ "$(sh "$TMP/home/scripts/menu.sh" source)" = "$TMP/recent source" ] || fail 'stale UCI record hid valid runtime source'
printf '%s\n' '$(touch "$TEST_ROOT/record-was-executed")' > "$TMP/home/runtime/source-dir"
MOCK_UCI_SOURCE=$TMP/older\ source; export MOCK_UCI_SOURCE
[ "$(sh "$TMP/home/scripts/menu.sh" source)" = "$TMP/older source" ] || fail 'source record was treated as shell code'
[ ! -e "$TMP/record-was-executed" ] || fail 'plain source path was executed'
printf '%s\n' "$TMP/recent source" > "$TMP/home/runtime/source-dir"
cat > "$TMP/recent source/quick-install.sh" <<'SH'
#!/bin/sh
printf '%s\n' "${SB_INSTALL_SOURCE_DIR:-unset}" "$@" > "$TEST_ROOT/source-update-call"
SH
printf '\ny\n' | sh "$TMP/home/scripts/menu.sh" update > "$TMP/source-update-online.log"
printf '%s\n' "$TMP/recent source" --update --no-menu > "$TMP/source-update-expected"
cmp "$TMP/source-update-expected" "$TMP/source-update-call" || fail 'online update did not target discovered custom checkout'
printf '%s\ny\n' "$TMP/offline archive.zip" | sh "$TMP/home/scripts/menu.sh" update > "$TMP/source-update-offline.log"
printf '%s\n' "$TMP/recent source" --update --archive "$TMP/offline archive.zip" --no-menu > "$TMP/source-update-expected"
cmp "$TMP/source-update-expected" "$TMP/source-update-call" || fail 'offline update did not target discovered custom checkout'
unset MOCK_UCI_SOURCE

# No fixture below has br-lan: use saved selection, netifd or UCI, then only
# an unambiguous global interface. VLAN names and @link suffixes are supported.
printf '{"interface":"client-vlan","source_cidr":"10.23.40.0/23"}\n' > "$TMP/home/runtime/gateway.json"
[ "$(MOCK_LINKS='client-vlan br-home' MOCK_UBUS_LAN=br-home sh "$TMP/checkout/menu.sh" interface)" = client-vlan ] || fail 'saved interface was not preferred'
printf '{"interface":"removed0","source_cidr":"10.23.40.0/23"}\n' > "$TMP/home/runtime/gateway.json"
[ "$(MOCK_LINKS=br-home MOCK_UBUS_LAN=br-home sh "$TMP/checkout/menu.sh" interface)" = br-home ] || fail 'netifd LAN device was not discovered'
[ "$(MOCK_LINKS=switch0.42 MOCK_UCI_LAN_DEVICE=switch0.42 sh "$TMP/checkout/menu.sh" interface)" = switch0.42 ] || fail 'UCI LAN device was not discovered'
[ "$(MOCK_LINKS=legacy-lan MOCK_UCI_LAN_DEVICE=removed0 MOCK_UCI_LAN_IFNAME=legacy-lan sh "$TMP/checkout/menu.sh" interface)" = legacy-lan ] || fail 'legacy UCI ifname fallback failed'
[ "$(MOCK_LINKS=lan42 MOCK_GLOBAL_LINK=lan42@if3 sh "$TMP/checkout/menu.sh" interface)" = lan42 ] || fail 'unique interface with @link suffix was not discovered'
[ "$(MOCK_LINKS=lan42 MOCK_GLOBAL_LINK=lan42 MOCK_NETWORK=same_subnet sh "$TMP/checkout/menu.sh" interface)" = lan42 ] || fail 'same-interface address aliases were considered ambiguous'
for mode in multiple absent failure; do
    if MOCK_LINKS='lan0 wan0' MOCK_INTERFACE_MODE=$mode sh "$TMP/checkout/menu.sh" interface > "$TMP/interface-default"; then
        fail "guessed LAN interface for $mode"
    fi
    [ ! -s "$TMP/interface-default" ] || fail "printed guessed LAN interface for $mode"
done
if MOCK_LINKS='lan0 wan0' MOCK_INTERFACE_MODE=multiple MOCK_UCI_LAN_IFNAME='lan0 wan0' \
    sh "$TMP/checkout/menu.sh" interface > "$TMP/interface-default"; then
    fail 'multiple legacy ifnames were treated as one LAN interface'
fi
rm -f "$TMP/applied"
if printf '\n' | MOCK_LINKS='lan0 wan0' MOCK_INTERFACE_MODE=multiple \
    sh "$TMP/checkout/menu.sh" configure > "$TMP/ambiguous-interface.log"; then
    fail 'blank ambiguous LAN interface accepted'
fi
[ ! -e "$TMP/applied" ] || fail 'gateway changed with ambiguous interface'
printf 'lan0\n\ny\n' | MOCK_LINKS='lan0 wan0' MOCK_INTERFACE_MODE=multiple \
    sh "$TMP/checkout/menu.sh" configure > "$TMP/explicit-interface.log"
grep -Fxq 'configure lan0 10.23.40.0/23' "$TMP/applied" || fail 'explicit LAN interface selection ignored'
# The new persistent settings menu sends authenticated URLs over stdin and
# releases temporary SB_* overrides only after a successful explicit choice.
mkdir -p "$TMP/proxy-source/scripts"
cat > "$TMP/proxy-source/scripts/configure-download.sh" <<'SH'
#!/bin/sh
case "$1" in
    show) echo 'Download settings (redacted)' ;;
    set)
        printf '%s\n' "$@" > "$TEST_ROOT/download-call"
        if [ "${3:-}" = --stdin ]; then cat > "$TEST_ROOT/download-url"; fi
        echo 'Saved mode'
        ;;
    *) exit 66 ;;
esac
SH
printf '2\nhttp://fixture:fixture-password@proxy.example.invalid:8080\n' |
    SB_INSTALL_SOURCE_DIR="$TMP/proxy-source" SB_DOWNLOAD_MODE=github SB_GITHUB_PROXY=https://temporary.example.invalid/ \
    sh "$TMP/home/scripts/menu.sh" download > "$TMP/download-menu.log"
printf 'set\nhttp\n--stdin\n' > "$TMP/download-expected"
cmp "$TMP/download-expected" "$TMP/download-call" || fail 'HTTP settings URL passed in argv'
grep -Fxq 'http://fixture:fixture-password@proxy.example.invalid:8080' "$TMP/download-url" || fail 'HTTP URL was not passed via stdin'
! grep -Fq 'fixture-password' "$TMP/download-menu.log" || fail 'menu exposed proxy credentials'
printf 'unset\nunset\nunset\n' > "$TMP/download-env-expected"
cmp "$TMP/download-env-expected" "$TMP/download-env" || fail 'temporary proxy overrides still shadow saved settings'
printf '3\nhttps://accelerator.example.invalid/\n' | SB_INSTALL_SOURCE_DIR="$TMP/proxy-source" \
    sh "$TMP/home/scripts/menu.sh" download > "$TMP/download-menu.log"
printf 'set\ngithub\n--stdin\n' > "$TMP/download-expected"
cmp "$TMP/download-expected" "$TMP/download-call" || fail 'GitHub prefix menu did not use settings helper'
printf '1\n' | SB_INSTALL_SOURCE_DIR="$TMP/proxy-source" sh "$TMP/home/scripts/menu.sh" download > "$TMP/download-menu.log"
printf 'set\ndirect\n' > "$TMP/download-expected"
cmp "$TMP/download-expected" "$TMP/download-call" || fail 'default download menu did not clear project mode'
echo 'Menu runtime paths, LAN selection and download settings tests passed.'
