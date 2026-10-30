#!/bin/sh
# Mock-only regression for sing-box gRPC API discovery in eBPF diagnostics.
# No kernel, DNS, nftables, procd or API service is modified.
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
command -v jq >/dev/null 2>&1 || { echo "jq required for this test" >&2; exit 1; }
TMP=$(mktemp -d /tmp/sb-api-check.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin" "$TMP/home/bin" "$TMP/home/config" "$TMP/home/runtime"
export MOCK_LOG="$TMP/api.log"
cat > "$TMP/bin/systemctl" <<'SH'
#!/bin/sh
[ "$*" = "is-active --quiet sing-box.service" ] && exit 0
echo "Unexpected systemctl call: $*" >&2
exit 98
SH
cat > "$TMP/home/bin/sing-box" <<'SH'
#!/bin/sh
case "$*" in
 "tools ebpf status") echo "mock eBPF kernel capability PASS"; exit 0;;
 "api ebpf --url "*)
    printf 'url=%s\nsecret=%s\nargs=%s\n' \
       "${BOX_API_URL:-}" "${BOX_API_SECRET:-}" "$*" > "$MOCK_LOG"
    if [ "${MOCK_API_FAIL:-0}" = 1 ]; then
        echo "mock API not reachable" >&2
        exit 15
    fi
    echo '{"schemaVersion":1,"state":"normal"}'
    exit 0;;
esac
echo "Unexpected mock sing-box request: $*" >&2
exit 98
SH
chmod +x "$TMP/bin/systemctl" "$TMP/home/bin/sing-box"
export SH_SINGBOX_HOME="$TMP/home"
PATH="$TMP/bin:$PATH"; export PATH
[ "$(command -v systemctl)" = "$TMP/bin/systemctl" ]

# Only a Clash API is configured, NOT services[].type=api; skip the runtime
# query without the misleading "missing API service URL" FATAL.
printf '%s\n' '{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}}}' \
    > "$TMP/home/config/config.json"
rm -f "$MOCK_LOG"
env -u BOX_API_URL -u BOX_API_SECRET bash "$BASE/scripts/sbctl" ebpf-status > "$TMP/output" 2>&1
grep -q 'mock eBPF kernel capability PASS' "$TMP/output"
grep -q 'Dedicated sing-box API service not configured' "$TMP/output"
! grep -q 'FATAL' "$TMP/output"
[ ! -f "$MOCK_LOG" ]

# Dedicated API configured locally with token. Detect the matching gRPC
# listener, not the unrelated clash_api port 9090.
printf '%s\n' '{"services":[{"type":"api","listen":"127.0.0.1","listen_port":9191,"secret":"mock-test-token"}],"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}}}' \
    > "$TMP/home/config/config.json"
env -u BOX_API_URL -u BOX_API_SECRET bash "$BASE/scripts/sbctl" ebpf-status > "$TMP/output" 2>&1
grep -q '"state":"normal"' "$TMP/output"
grep -q '^url=http://127.0.0.1:9191$' "$MOCK_LOG"
grep -q '^secret=mock-test-token$' "$MOCK_LOG"
! grep -q 'mock-test-token' "$TMP/output"

# Explicit environment variables take priority and avoid config inspection.
BOX_API_URL=http://127.0.0.1:9444 BOX_API_SECRET=env-test-token \
    bash "$BASE/scripts/sbctl" ebpf-status > "$TMP/output" 2>&1
grep -q '^url=http://127.0.0.1:9444$' "$MOCK_LOG"
grep -q '^secret=env-test-token$' "$MOCK_LOG"

# A failed real API lookup is reported as a DIAGNOSTIC failure, not as an
# assertion that kernel eBPF attach failed.
if MOCK_API_FAIL=1 BOX_API_URL=http://127.0.0.1:9191 \
      bash "$BASE/scripts/sbctl" ebpf-status > "$TMP/output" 2>&1; then
    echo "Failed API query was not reported as a failed diagnostic" >&2
    exit 1
fi
grep -q 'this does not prove an eBPF runtime failure' "$TMP/output"

# Incomplete service configuration should never invoke the API with no URL.
printf '%s\n' '{"services":[{"type":"api","listen":"127.0.0.1"}]}' \
    > "$TMP/home/config/config.json"
rm -f "$MOCK_LOG"
env -u BOX_API_URL -u BOX_API_SECRET bash "$BASE/scripts/sbctl" ebpf-status > "$TMP/output" 2>&1
grep -q 'no valid listen_port' "$TMP/output"
[ ! -f "$MOCK_LOG" ]
echo 'sing-box eBPF optional runtime API diagnostics passed.'
