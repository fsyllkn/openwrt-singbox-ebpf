#!/bin/sh
# Cache failures must not hide a passing sing-box check; kernel failures must fail.
set -eu
BASE=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sbctl-cache-test.XXXXXX) || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/config" "$TEST_DIR/runtime"
printf '{}\n' > "$TEST_DIR/config/config.json"
cat > "$TEST_DIR/bin/sing-box" <<'EOF'
#!/bin/sh
case "$1" in
    check)
        if [ -n "${MOCK_CHECK_EVENTS:-}" ]; then printf 'check\n' >> "$MOCK_CHECK_EVENTS"; fi
        exit "${MOCK_CHECK_STATUS:-0}" ;;
    version) echo mock ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "$TEST_DIR/bin/sing-box"
mkdir "$TEST_DIR/runtime/config.valid"
if ! SH_SINGBOX_HOME="$TEST_DIR" bash "$BASE/scripts/sbctl" check > "$TEST_DIR/success.log" 2>&1; then
    echo 'FAILED: a passing kernel check must succeed even without cache access' >&2
    cat "$TEST_DIR/success.log" >&2
    exit 1
fi
grep -q 'Configuration valid (validation cache unavailable)' "$TEST_DIR/success.log" ||
    { echo 'FAILED: missing success message' >&2; exit 1; }
if MOCK_CHECK_STATUS=27 SH_SINGBOX_HOME="$TEST_DIR" bash "$BASE/scripts/sbctl" check > "$TEST_DIR/failure.log" 2>&1; then
    echo 'FAILED: kernel check status 27 was hidden' >&2
    exit 1
fi
grep -q 'Configuration check failed (exit 27)' "$TEST_DIR/failure.log" ||
    { echo 'FAILED: kernel error code not reported' >&2; exit 1; }
rm -r "$TEST_DIR/runtime/config.valid"
if ! SH_SINGBOX_HOME="$TEST_DIR" bash "$BASE/scripts/sbctl" check > "$TEST_DIR/normal.log" 2>&1; then
    echo 'FAILED: normal cache check failed' >&2
    cat "$TEST_DIR/normal.log" >&2
    exit 1
fi
[ -f "$TEST_DIR/runtime/config.valid" ] ||
    { echo 'FAILED: cache was not written' >&2; exit 1; }

# An in-place equal-length edit with the original mtime/inode must invalidate
# the content cache; stat-only fingerprints cannot distinguish these files.
MOCK_CHECK_EVENTS="$TEST_DIR/check-events"
export MOCK_CHECK_EVENTS
: > "$MOCK_CHECK_EVENTS"
printf '{"route":"one"}\n' > "$TEST_DIR/config/config.json"
SH_SINGBOX_HOME="$TEST_DIR" bash "$BASE/scripts/sbctl" check > "$TEST_DIR/content-first.log" 2>&1
cp -p "$TEST_DIR/config/config.json" "$TEST_DIR/reference.json"
first_stamp=$(stat -c '%s:%Y:%i' "$TEST_DIR/config/config.json")
SH_SINGBOX_HOME="$TEST_DIR" bash "$BASE/scripts/sbctl" check > "$TEST_DIR/content-cached.log" 2>&1
[ "$(wc -l < "$MOCK_CHECK_EVENTS")" -eq 1 ] ||
    { echo 'FAILED: unchanged config was not cached' >&2; exit 1; }
printf '{"route":"two"}\n' > "$TEST_DIR/config/config.json"
touch -r "$TEST_DIR/reference.json" "$TEST_DIR/config/config.json"
[ "$(stat -c '%s:%Y:%i' "$TEST_DIR/config/config.json")" = "$first_stamp" ] ||
    { echo 'FAILED: test did not preserve size/mtime/inode' >&2; exit 1; }
SH_SINGBOX_HOME="$TEST_DIR" bash "$BASE/scripts/sbctl" check > "$TEST_DIR/content-edited.log" 2>&1
[ "$(wc -l < "$MOCK_CHECK_EVENTS")" -eq 2 ] ||
    { echo 'FAILED: same-size same-mtime config edit reused stale validation' >&2; exit 1; }
echo 'sbctl validation and cache fallback tests passed.'
