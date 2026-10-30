#!/bin/sh
# Runtime selectors and procd must check, prepare and launch the same config.
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sb-runtime-paths.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
mkdir -p "$TEST_DIR/tools"
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
chmod 0755 "$TEST_DIR/tools/uci"
PATH="$TEST_DIR/tools:$PATH"; export PATH
fail() { echo "FAILED: $*" >&2; exit 1; }

# Source-only use must not select paths or mutate an existing environment.
(
    unset SH_SINGBOX_HOME SH_SINGBOX_CONFIG
    . "$BASE/scripts/runtime-paths.sh"
    [ "${SH_SINGBOX_HOME+x}" != x ] && [ "${SH_SINGBOX_CONFIG+x}" != x ]
) || fail 'sourcing the resolver changed runtime selectors'

(
    unset SH_SINGBOX_HOME SH_SINGBOX_CONFIG MOCK_UCI_HOME MOCK_UCI_CONFIG
    . "$BASE/scripts/runtime-paths.sh"
    sb_load_paths
    [ "$SH_SINGBOX_HOME" = /opt/sing-box ]
    [ "$SH_SINGBOX_CONFIG" = /opt/sing-box/config/config.json ]
) || fail 'default paths were not resolved'

MOCK_UCI_HOME="$TEST_DIR/uci home"
MOCK_UCI_CONFIG="$TEST_DIR/uci config/active.json"
export MOCK_UCI_HOME MOCK_UCI_CONFIG
(
    unset SH_SINGBOX_HOME SH_SINGBOX_CONFIG
    . "$BASE/scripts/runtime-paths.sh"
    sb_load_paths
    [ "$SH_SINGBOX_HOME" = "$MOCK_UCI_HOME" ]
    [ "$SH_SINGBOX_CONFIG" = "$MOCK_UCI_CONFIG" ]
    sh -c '[ "$SH_SINGBOX_HOME" = "$MOCK_UCI_HOME" ] && [ "$SH_SINGBOX_CONFIG" = "$MOCK_UCI_CONFIG" ]'
) || fail 'UCI paths with spaces were not resolved and exported'

(
    SH_SINGBOX_HOME="$TEST_DIR/environment home"
    unset SH_SINGBOX_CONFIG
    . "$BASE/scripts/runtime-paths.sh"
    sb_load_paths
    [ "$SH_SINGBOX_HOME" = "$TEST_DIR/environment home" ]
    [ "$SH_SINGBOX_CONFIG" = "$TEST_DIR/environment home/config/config.json" ]
) || fail 'explicit HOME inherited an unrelated UCI config'

(
    unset SH_SINGBOX_HOME
    SH_SINGBOX_CONFIG="$TEST_DIR/environment config.json"
    . "$BASE/scripts/runtime-paths.sh"
    sb_load_paths
    [ "$SH_SINGBOX_HOME" = "$MOCK_UCI_HOME" ]
    [ "$SH_SINGBOX_CONFIG" = "$TEST_DIR/environment config.json" ]
) || fail 'explicit CONFIG did not override UCI config'

for bad_selector in home config; do
    if (
        unset SH_SINGBOX_HOME SH_SINGBOX_CONFIG
        case "$bad_selector" in
            home) SH_SINGBOX_HOME=relative/home ;;
            config) SH_SINGBOX_CONFIG=relative/config.json ;;
        esac
        . "$BASE/scripts/runtime-paths.sh"
        sb_load_paths
    ) > "$TEST_DIR/invalid.log" 2>&1; then
        fail "relative $bad_selector selector was accepted"
    fi
    grep -q 'absolute path' "$TEST_DIR/invalid.log" || fail 'missing path diagnostic'
done
(
    unset SH_SINGBOX_HOME SH_SINGBOX_CONFIG MOCK_UCI_CONFIG
    MOCK_UCI_HOME=relative/uci/home; export MOCK_UCI_HOME
    . "$BASE/scripts/runtime-paths.sh"
    if sb_load_paths > "$TEST_DIR/invalid-uci.log" 2>&1; then
        exit 1
    fi
) || fail 'relative UCI service directory was accepted'

# A controlled procd harness performs no real service or network operations.
# Mock helpers assert the exact exported selectors received from the init script.
EXPECTED_HOME=$MOCK_UCI_HOME
EXPECTED_CONFIG=$MOCK_UCI_CONFIG
TEST_EVENTS="$TEST_DIR/events"
export EXPECTED_HOME EXPECTED_CONFIG TEST_EVENTS
mkdir -p "$EXPECTED_HOME/bin" "$EXPECTED_HOME/scripts" "$(dirname "$EXPECTED_CONFIG")"
cp "$BASE/scripts/runtime-paths.sh" "$EXPECTED_HOME/scripts/runtime-paths.sh"
printf '{}\n' > "$EXPECTED_CONFIG"
cat > "$EXPECTED_HOME/bin/sing-box" <<'SH'
#!/bin/sh
echo 'Unexpected direct core invocation' >&2
exit 65
SH
cat > "$EXPECTED_HOME/scripts/sbctl" <<'SH'
#!/bin/sh
set -eu
[ "$SH_SINGBOX_HOME" = "$EXPECTED_HOME" ]
[ "$SH_SINGBOX_CONFIG" = "$EXPECTED_CONFIG" ]
[ "$*" = preflight ]
printf 'preflight\n' >> "$TEST_EVENTS"
exit "${MOCK_PREFLIGHT_STATUS:-0}"
SH
cat > "$EXPECTED_HOME/scripts/dns-guard.sh" <<'SH'
#!/bin/sh
set -eu
[ "$SH_SINGBOX_HOME" = "$EXPECTED_HOME" ]
[ "$SH_SINGBOX_CONFIG" = "$EXPECTED_CONFIG" ]
printf 'dns:%s\n' "$1" >> "$TEST_EVENTS"
if [ "$1" = setup ]; then exit "${MOCK_DNS_STATUS:-0}"; fi
SH
cat > "$EXPECTED_HOME/scripts/gateway.sh" <<'SH'
#!/bin/sh
set -eu
[ "$SH_SINGBOX_HOME" = "$EXPECTED_HOME" ]
[ "$SH_SINGBOX_CONFIG" = "$EXPECTED_CONFIG" ]
printf 'gateway:%s\n' "$1" >> "$TEST_EVENTS"
exit "${MOCK_GATEWAY_STATUS:-0}"
SH
chmod 0755 "$EXPECTED_HOME/bin/sing-box" "$EXPECTED_HOME/scripts/"*.sh "$EXPECTED_HOME/scripts/sbctl"

. "$BASE/openwrt/sing-box.init"
check_cgroup2() { :; }
procd_open_instance() { printf 'procd:open\n' >> "$TEST_EVENTS"; }
procd_set_param() {
    if [ "$1" = command ]; then
        [ "$#" -eq 7 ] || return 1
        [ "$2" = "$EXPECTED_HOME/bin/sing-box" ] || return 1
        [ "$3" = run ] && [ "$4" = -c ] || return 1
        [ "$5" = "$EXPECTED_CONFIG" ] && [ "$6" = -D ] || return 1
        [ "$7" = "$EXPECTED_HOME" ] || return 1
        printf 'procd:command\n' >> "$TEST_EVENTS"
    fi
}
procd_close_instance() { printf 'procd:close\n' >> "$TEST_EVENTS"; }

(
    unset SH_SINGBOX_HOME SH_SINGBOX_CONFIG
    : > "$TEST_EVENTS"
    start_service > "$TEST_DIR/start.log" 2>&1
    expected=$(printf 'preflight\ndns:setup\ngateway:apply\nprocd:open\nprocd:command\nprocd:close')
    [ "$(cat "$TEST_EVENTS")" = "$expected" ]
) || fail 'UCI preflight/helpers/procd launch disagreed on runtime paths'

# Explicit selectors point to another config even with conflicting UCI values.
(
    SH_SINGBOX_HOME=$EXPECTED_HOME
    EXPECTED_CONFIG="$TEST_DIR/environment config.json"
    SH_SINGBOX_CONFIG=$EXPECTED_CONFIG
    export SH_SINGBOX_HOME SH_SINGBOX_CONFIG EXPECTED_CONFIG
    printf '{}\n' > "$EXPECTED_CONFIG"
    : > "$TEST_EVENTS"
    start_service > "$TEST_DIR/start-explicit.log" 2>&1
    grep -qx 'procd:command' "$TEST_EVENTS"
) || fail 'explicit config path was not passed through the complete startup'

for failed_step in preflight dns gateway; do
    (
        unset SH_SINGBOX_HOME SH_SINGBOX_CONFIG
        : > "$TEST_EVENTS"
        case "$failed_step" in
            preflight) MOCK_PREFLIGHT_STATUS=23; export MOCK_PREFLIGHT_STATUS ;;
            dns) MOCK_DNS_STATUS=24; export MOCK_DNS_STATUS ;;
            gateway) MOCK_GATEWAY_STATUS=25; export MOCK_GATEWAY_STATUS ;;
        esac
        if start_service > "$TEST_DIR/$failed_step.log" 2>&1; then
            exit 1
        fi
        ! grep -q '^procd:' "$TEST_EVENTS"
        grep -q 'core was not started' "$TEST_DIR/$failed_step.log"
        case "$failed_step" in
            preflight) [ "$(cat "$TEST_EVENTS")" = preflight ] ;;
            dns) [ "$(cat "$TEST_EVENTS")" = "$(printf 'preflight\ndns:setup\ndns:restore')" ] ;;
            gateway) [ "$(cat "$TEST_EVENTS")" = "$(printf 'preflight\ndns:setup\ngateway:apply\ndns:restore')" ] ;;
        esac
    ) || fail "$failed_step failure launched the core or skipped required DNS restoration"
done

(
    unset SH_SINGBOX_HOME SH_SINGBOX_CONFIG
    : > "$TEST_EVENTS"
    stop_service
    [ "$(cat "$TEST_EVENTS")" = "$(printf 'gateway:cleanup\ndns:restore')" ]
) || fail 'stop helpers did not receive the same resolved paths'

(
    SH_SINGBOX_HOME="$TEST_DIR/missing-helper"
    unset SH_SINGBOX_CONFIG
    export SH_SINGBOX_HOME
    : > "$TEST_EVENTS"
    if start_service > "$TEST_DIR/missing-helper.log" 2>&1; then exit 1; fi
    grep -q 'install the updated scripts' "$TEST_DIR/missing-helper.log"
    [ ! -s "$TEST_EVENTS" ]
) || fail 'partial upgrade silently fell back to another installation'

echo 'Runtime path and procd startup alignment tests passed.'
