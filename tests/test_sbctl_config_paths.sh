#!/bin/sh
# Exercise active-config diagnostics, fresh bind checks and atomic imports.
# All core, address and service operations are mocked inside a temporary tree.
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sbctl-config-paths.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
fail() { echo "FAILED: $*" >&2; exit 1; }
TEST_HOME="$TEST_DIR/service home"
TEST_CONFIG="$TEST_DIR/config files/active.json"
TEST_LINK="$TEST_DIR/commands/sbctl"
CORE_LOG="$TEST_DIR/core.log"
SERVICE_LOG="$TEST_DIR/service.log"
MOCK_ADDRESS_FILE="$TEST_DIR/addresses"
export CORE_LOG SERVICE_LOG MOCK_ADDRESS_FILE
mkdir -p "$TEST_HOME/bin" "$TEST_HOME/scripts" "$TEST_HOME/config" \
    "$TEST_DIR/tools" "$TEST_DIR/commands" "$(dirname "$TEST_CONFIG")"
cp "$BASE/scripts/sbctl" "$BASE/scripts/runtime-paths.sh" "$BASE/scripts/config-parts-lib.sh" "$BASE/scripts/config-parts.sh" "$TEST_HOME/scripts/"
ln -s "$TEST_HOME/scripts/sbctl" "$TEST_LINK"
: > "$CORE_LOG"
: > "$SERVICE_LOG"
cat > "$TEST_HOME/bin/sing-box" <<'SH'
#!/bin/sh
set -eu
[ "$1" = check ] && [ "$2" = -c ] && [ "$#" -eq 3 ] || exit 64
[ "$PWD" = "$SH_SINGBOX_HOME" ] || exit 65
printf '%s\n' "$3" >> "$CORE_LOG"
[ "${MOCK_CHECK_STATUS:-0}" -eq 0 ] || exit "$MOCK_CHECK_STATUS"
# A real core rejects malformed JSON before a configuration can be imported.
jq -e 'type == "object" and (.inbounds | type == "array")' "$3" >/dev/null
SH
cat > "$TEST_DIR/tools/ip" <<'SH'
#!/bin/sh
[ "$*" = '-4 -o addr show' ] || exit 64
if [ "${MOCK_IP_STATUS:-0}" -ne 0 ]; then
    echo 'Mock address dump failed' >&2
    exit "$MOCK_IP_STATUS"
fi
cat "$MOCK_ADDRESS_FILE"
SH
cat > "$TEST_DIR/tools/uci" <<'SH'
#!/bin/sh
case "$*" in
    '-q get sing-box.main.service_dir')
        [ -n "${MOCK_UCI_HOME:-}" ] || exit 1
        printf '%s\n' "$MOCK_UCI_HOME" ;;
    '-q get sing-box.main.config_file')
        [ -n "${MOCK_UCI_CONFIG:-}" ] || exit 1
        printf '%s\n' "$MOCK_UCI_CONFIG" ;;
    *) exit 64 ;;
esac
SH
cat > "$TEST_DIR/tools/systemctl" <<'SH'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$SERVICE_LOG"
exit 99
SH
cat > "$TEST_DIR/tools/journalctl" <<'SH'
#!/bin/sh
printf 'journalctl %s\n' "$*" >> "$SERVICE_LOG"
exit 99
SH
cat > "$TEST_DIR/tools/id" <<'SH'
#!/bin/sh
# Permit the import permission gate without requiring root on the test runner.
[ "$*" = -u ] || exit 64
echo 0
SH
chmod 0755 "$TEST_HOME/bin/sing-box" "$TEST_DIR/tools/"*
PATH="$TEST_DIR/tools:$PATH"; export PATH
SH_SINGBOX_HOME=$TEST_HOME
SH_SINGBOX_CONFIG=$TEST_CONFIG
export SH_SINGBOX_HOME SH_SINGBOX_CONFIG
run_cli() { bash "$TEST_LINK" "$@"; }
set_assigned_address() {
    printf '%s\n' \
        '1: lo inet 127.0.0.1/8 scope host lo' \
        '3: br-lan inet 10.23.40.45/23 scope global br-lan' > "$MOCK_ADDRESS_FILE"
}
set_assigned_address
cat > "$TEST_DIR/valid.json" <<'JSON'
{
  "inbounds": [
    {"type":"mixed","tag":"lan-explicit-proxy","listen":"10.23.40.45","listen_port":7890,
     "users":[{"username":"private-user-marker","password":"private-pass-marker-ABCD"}]},
    {"type":"mixed","tag":"lan-mixed","listen":"10.23.40.45","listen_port":7891,
     "users":[{"username":"second-user-marker","password":"second-pass-marker-ABCD"}]},
    {"type":"tproxy","tag":"lan-tproxy","listen":"0.0.0.0","listen_port":1536}
  ],
  "outbounds": [{"type":"direct","tag":"direct"}],
  "providers": [{"type":"http","tag":"provider","url":"https://provider.invalid/private-token-marker"}],
  "experimental": {"clash_api":{"secret":"private-api-marker"}},
  "route": {"rules":[{"domain_suffix":["example.invalid"],"outbound":"direct"}]}
}
JSON
cp "$TEST_DIR/valid.json" "$TEST_CONFIG"

# Config inspection through the installed symlink shows paths and both tags,
# but must not disclose accounts, passwords, provider tokens or API secrets.
run_cli config > "$TEST_DIR/config.log" 2>&1 || fail 'config inspection failed'
grep -Fq "Configuration file: $TEST_CONFIG" "$TEST_DIR/config.log" || fail 'wrong explicit config path'
grep -Fq 'lan-explicit-proxy: mixed 10.23.40.45:7890' "$TEST_DIR/config.log" || fail 'first listener not shown'
grep -Fq 'lan-mixed: mixed 10.23.40.45:7891' "$TEST_DIR/config.log" || fail 'second listener not shown'
if grep -Eq 'private-(user|pass|token|api)-marker|second-(user|pass)-marker' "$TEST_DIR/config.log"; then
    fail 'config diagnostics exposed configuration secrets'
fi
run_cli preflight > "$TEST_DIR/preflight.log" 2>&1 || fail 'assigned LAN listeners were rejected'
grep -Fxq "$TEST_CONFIG" "$CORE_LOG" || fail 'core checked a different explicit config'
check_count=$(wc -l < "$CORE_LOG")
run_cli preflight > "$TEST_DIR/cached.log" 2>&1 || fail 'cached preflight failed'
grep -Fq 'Configuration valid (cached)' "$TEST_DIR/cached.log" || fail 'syntax cache was not exercised'
[ "$(wc -l < "$CORE_LOG")" -eq "$check_count" ] || fail 'unchanged syntax was rechecked'

# Interface changes invalidate listener availability even while JSON and its
# syntax cache remain unchanged. Both independently named listeners are checked.
printf '%s\n' '1: lo inet 127.0.0.1/8 scope host lo' > "$MOCK_ADDRESS_FILE"
if run_cli preflight > "$TEST_DIR/address-changed.log" 2>&1; then
    fail 'cached syntax hid a removed interface address'
fi
grep -Fq "Inbound 'lan-explicit-proxy'" "$TEST_DIR/address-changed.log" || fail 'first stale listener omitted'
grep -Fq "Inbound 'lan-mixed'" "$TEST_DIR/address-changed.log" || fail 'second stale listener omitted'
[ "$(wc -l < "$CORE_LOG")" -eq "$check_count" ] || fail 'live-address test did not reuse syntax cache'
set_assigned_address

# Correcting lan-mixed alone must not hide a stale earlier lan-explicit-proxy.
jq '.inbounds[0].listen = "192.168.50.11"' "$TEST_DIR/valid.json" > "$TEST_CONFIG"
if run_cli preflight > "$TEST_DIR/first-stale.log" 2>&1; then
    fail 'stale first listener passed because lan-mixed was valid'
fi
grep -Fq "Inbound 'lan-explicit-proxy' binds 192.168.50.11:7890" "$TEST_DIR/first-stale.log" || fail 'wrong stale listener diagnostic'
if grep -Fq "Inbound 'lan-mixed' binds" "$TEST_DIR/first-stale.log"; then
    fail 'assigned second listener was incorrectly rejected'
fi
# Source the real lifecycle implementation and force the mocked systemd path,
# so this test can never invoke a real OpenWrt init script on an OpenWrt runner.
if bash -c '. "$1" help >/dev/null; INIT_SYSTEM=systemd; cmd_restart' \
        test "$TEST_LINK" > "$TEST_DIR/restart.log" 2>&1; then
    fail 'restart accepted an unassigned listener'
fi
grep -Fq 'existing sing-box service was NOT stopped' "$TEST_DIR/restart.log" || fail 'restart preflight did not protect existing service'
[ ! -s "$SERVICE_LOG" ] || fail 'service command executed before listener preflight passed'

# Wildcard and the whole IPv4 loopback range do not need an enumerated LAN IP.
jq '.inbounds[0].listen = "0.0.0.0" | .inbounds[1].listen = "127.0.0.2"' \
    "$TEST_DIR/valid.json" > "$TEST_CONFIG"
(
    MOCK_IP_STATUS=87; export MOCK_IP_STATUS
    run_cli preflight > "$TEST_DIR/wildcard.log" 2>&1
) || fail 'wildcard/127.0.0.2 bind was rejected'
# IPv6 literals remain outside the IPv4-address enumeration, including on a
# jq build with no regex engine. They must not force an IPv4 address dump.
jq '.inbounds[0].listen = "::" | .inbounds[1].listen = "::1"' \
    "$TEST_DIR/valid.json" > "$TEST_CONFIG"
(
    MOCK_IP_STATUS=87; export MOCK_IP_STATUS
    run_cli preflight > "$TEST_DIR/ipv6.log" 2>&1
) || fail 'IPv6-only listeners incorrectly required IPv4 addresses'
cp "$TEST_DIR/valid.json" "$TEST_CONFIG"
if (
    MOCK_IP_STATUS=87; export MOCK_IP_STATUS
    run_cli preflight > "$TEST_DIR/ip-failure.log" 2>&1
); then
    fail 'address dump failure was treated as a successful preflight'
fi
grep -Fq 'Cannot inspect local IPv4 addresses' "$TEST_DIR/ip-failure.log" || fail 'address inspection failure was not explained'

# A symlinked sbctl must find its own helper and honor UCI selectors when no
# environment override is present; an explicit home must ignore UCI config.
MOCK_UCI_HOME=$TEST_HOME
MOCK_UCI_CONFIG="$TEST_DIR/config files/uci-active.json"
export MOCK_UCI_HOME MOCK_UCI_CONFIG
cp "$TEST_DIR/valid.json" "$MOCK_UCI_CONFIG"
(
    unset SH_SINGBOX_HOME SH_SINGBOX_CONFIG
    run_cli preflight > "$TEST_DIR/uci-preflight.log" 2>&1
) || fail 'UCI config selection through sbctl symlink failed'
grep -Fxq "$MOCK_UCI_CONFIG" "$CORE_LOG" || fail 'core ignored the UCI config path'
cp "$TEST_DIR/valid.json" "$TEST_HOME/config/config.json"
(
    unset SH_SINGBOX_CONFIG
    run_cli config > "$TEST_DIR/home-only.log" 2>&1
) || fail 'explicit-home config inspection failed'
grep -Fq "Configuration file: $TEST_HOME/config/config.json" "$TEST_DIR/home-only.log" || fail 'explicit home inherited unrelated UCI config'

# Import through a config symlink must replace its target atomically, preserve
# the symlink and full supplied JSON, protect permissions, and back up old data.
IMPORT_TARGET="$TEST_DIR/config files/installed-target.json"
cp "$TEST_DIR/valid.json" "$IMPORT_TARGET"
cp "$IMPORT_TARGET" "$TEST_DIR/before-import.json"
rm "$TEST_CONFIG"
ln -s "$IMPORT_TARGET" "$TEST_CONFIG"
jq '.inbounds[0].users += [{"username":"extra-user","password":"extra-password-1234"}]
    | .route.rules += [{"ip_cidr":["10.77.0.104/32"],"outbound":"direct"}]' \
    "$TEST_DIR/valid.json" > "$TEST_DIR/import-valid.json"
run_cli import-config "$TEST_DIR/import-valid.json" > "$TEST_DIR/import.log" 2>&1 || fail 'valid import failed'
[ -L "$TEST_CONFIG" ] && [ "$(readlink "$TEST_CONFIG")" = "$IMPORT_TARGET" ] || fail 'import replaced the config symlink'
cmp -s "$TEST_DIR/import-valid.json" "$IMPORT_TARGET" || fail 'import altered or dropped supplied config data'
[ "$(stat -c %a "$IMPORT_TARGET")" = 600 ] || fail 'imported config mode is not 0600'
set -- "$IMPORT_TARGET".before-import.*
[ "$#" -eq 1 ] && [ -f "$1" ] || fail 'missing or duplicate import backup'
cmp -s "$TEST_DIR/before-import.json" "$1" || fail 'backup does not preserve previous content'
[ "$(stat -c %a "$1")" = 600 ] || fail 'import backup mode is not 0600'
[ ! -e "$TEST_HOME/runtime/config.valid" ] || fail 'import left a staged-config cache behind'
[ ! -s "$SERVICE_LOG" ] || fail 'import performed a service operation'
cp "$IMPORT_TARGET" "$TEST_DIR/after-valid-import.json"

printf '{"inbounds": [\n' > "$TEST_DIR/import-invalid-json.json"
jq '.inbounds[0].listen = "192.168.50.11"' "$TEST_DIR/valid.json" > "$TEST_DIR/import-nonlocal.json"
for rejected_import in invalid-json kernel nonlocal; do
    case "$rejected_import" in
        invalid-json) import_source="$TEST_DIR/import-invalid-json.json" ;;
        kernel) import_source="$TEST_DIR/import-valid.json" ;;
        nonlocal) import_source="$TEST_DIR/import-nonlocal.json" ;;
    esac
    if (
        if [ "$rejected_import" = kernel ]; then
            MOCK_CHECK_STATUS=26; export MOCK_CHECK_STATUS
        fi
        run_cli import-config "$import_source" > "$TEST_DIR/import-$rejected_import.log" 2>&1
    ); then
        fail "$rejected_import candidate was imported"
    fi
    cmp -s "$TEST_DIR/after-valid-import.json" "$IMPORT_TARGET" || fail "$rejected_import changed installed content"
    [ -L "$TEST_CONFIG" ] || fail "$rejected_import removed the active config symlink"
    set -- "$IMPORT_TARGET".before-import.*
    [ "$#" -eq 1 ] || fail "$rejected_import produced a misleading backup"
    for staged in "$IMPORT_TARGET".import.*; do
        [ ! -e "$staged" ] || fail "$rejected_import left a staged config behind"
    done
done
[ ! -s "$SERVICE_LOG" ] || fail 'rejected import performed a service operation'

# An unusable cache is only a lost optimization. In particular, best-effort
# EXIT cleanup must not report a successfully installed config as a failure.
mkdir "$TEST_HOME/runtime/config.valid"
printf 'keep-cache-directory\n' > "$TEST_HOME/runtime/config.valid/sentinel"
cache_inode=$(stat -c %i "$TEST_HOME/runtime/config.valid")
run_cli import-config "$TEST_DIR/valid.json" > "$TEST_DIR/import-cache-directory.log" 2>&1 ||
    fail 'unusable cache turned a successful import into a reported failure'
cmp -s "$TEST_DIR/valid.json" "$IMPORT_TARGET" || fail 'cache failure prevented the new config from being installed'
[ -L "$TEST_CONFIG" ] || fail 'cache failure replaced the active config symlink'
[ -d "$TEST_HOME/runtime/config.valid" ] &&
    [ "$(stat -c %i "$TEST_HOME/runtime/config.valid")" = "$cache_inode" ] &&
    [ "$(cat "$TEST_HOME/runtime/config.valid/sentinel")" = keep-cache-directory ] ||
    fail 'best-effort import cleanup modified the cache directory'
[ ! -s "$SERVICE_LOG" ] || fail 'import with an unusable cache performed a service operation'
echo 'sbctl config selection, listener preflight and safe import tests passed.'
