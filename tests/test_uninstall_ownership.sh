#!/usr/bin/env bash
# Ownership/cleanup checks use only fixture paths; no real service is stopped.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sb-uninstall.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
awk '
  /^(validate_purge_target|remove_owned_sbctl_link|restore_managed_network)\(\) \{/ { emit = 1 }
  emit { print }
  emit && /^}$/ { emit = 0 }
' "$BASE/uninstall.sh" > "$TEST_DIR/functions.sh"
. "$TEST_DIR/functions.sh"
INSTALL_DIR=$TEST_DIR/installation
mkdir -p "$INSTALL_DIR/scripts" "$TEST_DIR/links"
cp "$BASE/scripts/sbctl" "$INSTALL_DIR/scripts/sbctl"
validate_purge_target
for unsafe in / /opt /etc /usr /overlay; do
    if (INSTALL_DIR=$unsafe; validate_purge_target) > "$TEST_DIR/purge.log" 2>&1; then
        fail "unsafe purge target $unsafe accepted"
    fi
done
ln -s / "$TEST_DIR/root-link"
if (INSTALL_DIR=$TEST_DIR/root-link; validate_purge_target) > "$TEST_DIR/purge.log" 2>&1; then
    fail 'symlink to root passed purge guard'
fi
mkdir "$TEST_DIR/foreign"
if (INSTALL_DIR=$TEST_DIR/foreign; validate_purge_target) > "$TEST_DIR/purge.log" 2>&1; then
    fail 'unrecognized directory passed purge guard'
fi

ln -s "$INSTALL_DIR/scripts/sbctl" "$TEST_DIR/links/owned"
ln -s "$BASE/install.sh" "$TEST_DIR/links/foreign"
printf '#!/bin/sh\n# other controller\n' > "$TEST_DIR/links/regular"
remove_owned_sbctl_link "$TEST_DIR/links/owned"
remove_owned_sbctl_link "$TEST_DIR/links/foreign"
remove_owned_sbctl_link "$TEST_DIR/links/regular"
[ ! -L "$TEST_DIR/links/owned" ] || fail 'owned CLI symlink retained'
[ -L "$TEST_DIR/links/foreign" ] || fail 'foreign CLI symlink removed'
[ -f "$TEST_DIR/links/regular" ] || fail 'foreign regular CLI removed'

TEST_EVENTS=$TEST_DIR/events; export TEST_EVENTS
cat > "$INSTALL_DIR/scripts/gateway.sh" <<'SH'
#!/bin/sh
printf 'gateway:%s\n' "$*" >> "$TEST_EVENTS"
exit "${MOCK_GATEWAY_STATUS:-0}"
SH
cat > "$INSTALL_DIR/scripts/dns-guard.sh" <<'SH'
#!/bin/sh
printf 'dns:%s\n' "$*" >> "$TEST_EVENTS"
exit "${MOCK_DNS_STATUS:-0}"
SH
chmod 0755 "$INSTALL_DIR/scripts/gateway.sh" "$INSTALL_DIR/scripts/dns-guard.sh"
restore_managed_network
printf 'gateway:cleanup\ndns:restore\n' > "$TEST_DIR/expected"
cmp "$TEST_DIR/expected" "$TEST_EVENTS" || fail 'managed cleanup invocation differs'
for kind in gateway dns; do
    : > "$TEST_EVENTS"
    if (
        case "$kind" in
            gateway) export MOCK_GATEWAY_STATUS=7 ;;
            dns) export MOCK_DNS_STATUS=9 ;;
        esac
        restore_managed_network
        printf 'unexpected continuation\n' >> "$TEST_EVENTS"
    ) > "$TEST_DIR/cleanup-error.log" 2>&1; then
        fail "$kind cleanup error was hidden"
    fi
    cmp "$TEST_DIR/expected" "$TEST_EVENTS" || fail 'failure prevented DNS cleanup or continued uninstall'
    [ -f "$INSTALL_DIR/scripts/sbctl" ] || fail 'recovery files were lost'
    grep -Fq 'Network cleanup failed' "$TEST_DIR/cleanup-error.log" || fail 'cleanup failure message missing'
done
echo 'Uninstall ownership, purge guards and cleanup error preservation tests passed.'
