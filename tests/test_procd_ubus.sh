#!/bin/sh
# Procd's ubus deletion wrapper must suppress only redundant "Not found".
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP=$(mktemp -d /tmp/sb-ubus-mock.XXXXXX)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ubus" <<'SH'
#!/bin/sh
case "$*" in
 'call service delete '*)
   case "${MOCK_UBUS_DELETE:-missing}" in
     missing) echo 'Command failed: Not found' >&2; exit 4;;
     denied) echo 'Command failed: Permission denied' >&2; exit 5;;
     ok) exit 0;;
   esac ;;
 'call service list '*) echo '{"service":"ok"}'; exit 0 ;;
esac
echo "Unexpected ubus $*" >&2
exit 66
SH
chmod +x "$TMP/bin/ubus"
PATH="$TMP/bin:$PATH"; export PATH
# Sourcing merely defines shell functions; no actual procd or network calls.
. "$BASE/openwrt/sing-box.init"
if ! out=$(MOCK_UBUS_DELETE=missing ubus call service delete '{}' 2>&1); then
    echo 'FAILED: redundant procd service delete was not tolerated' >&2; exit 1
fi
[ -z "$out" ] || { echo 'FAILED: benign Not found was displayed' >&2; exit 1; }
if out=$(MOCK_UBUS_DELETE=denied ubus call service delete '{}' 2>&1); then
    echo 'FAILED: permission error was swallowed' >&2; exit 1
fi
printf '%s\n' "$out" | grep -q 'Permission denied'
[ "$(ubus call service list '{}')" = '{"service":"ok"}' ]
MOCK_UBUS_DELETE=ok ubus call service delete '{}'
echo 'Procd benign missing-instance deletion test passed.'
