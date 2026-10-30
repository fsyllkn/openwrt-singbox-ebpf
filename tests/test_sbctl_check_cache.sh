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

# A normal Linux PATH hides optional OpenWrt applets. Supply only the commands
# used by sbctl check, deliberately omitting cksum in every case below.
REAL_BASH=$(command -v bash)
REAL_SHA256=$(command -v sha256sum)
REAL_STAT=$(command -v stat)
CACHE_CHECK_PATH="$TEST_DIR/cache-tools"
CACHE_HASH_WRAPPER="$TEST_DIR/hash-backend"
SB_TEST_HASH_BUSYBOX=${SB_TEST_HASH_BUSYBOX:-}
export REAL_SHA256 CACHE_HASH_WRAPPER SB_TEST_HASH_BUSYBOX
mkdir "$CACHE_CHECK_PATH"
for command_name in readlink dirname mkdir chmod rm cat tail timeout grep awk; do
    command_path=$(command -v "$command_name")
    ln -s "$command_path" "$CACHE_CHECK_PATH/$command_name"
done
cat > "$CACHE_HASH_WRAPPER" <<'EOF'
#!/bin/sh
case "${CACHE_HASH_BEHAVIOR:-ok}" in
    ok) exec "$REAL_SHA256" "$@" ;;
    failure) "$REAL_SHA256" "$@"; exit 9 ;;
    empty) exit 0 ;;
    malformed) printf '%s\n' 'not-a-sha256-digest  -' ;;
    *) exit 64 ;;
esac
EOF
cat > "$TEST_DIR/busybox-hash" <<'EOF'
#!/bin/sh
[ "$1" = sha256sum ] || exit 64
shift
if [ -n "${SB_TEST_HASH_BUSYBOX:-}" ]; then
    exec "$SB_TEST_HASH_BUSYBOX" sha256sum "$@"
fi
exec "$CACHE_HASH_WRAPPER" "$@"
EOF
cat > "$TEST_DIR/unsupported-stat" <<'EOF'
#!/bin/sh
printf '%s\n' '%s:%Y:%i'
EOF
chmod 0755 "$CACHE_HASH_WRAPPER" "$TEST_DIR/busybox-hash" "$TEST_DIR/unsupported-stat"

cache_fail() { echo "FAILED: $*" >&2; exit 1; }
limited_check() {
    PATH="$CACHE_CHECK_PATH" SH_SINGBOX_HOME="$TEST_DIR" \
        SH_SINGBOX_CONFIG="$TEST_DIR/config/config.json" \
        "$REAL_BASH" "$BASE/scripts/sbctl" check
}
cache_check_count() {
    [ "$(wc -l < "$MOCK_CHECK_EVENTS")" -eq "$1" ] || cache_fail "$2"
}
if [ -n "$SB_TEST_HASH_BUSYBOX" ]; then
    [ -x "$SB_TEST_HASH_BUSYBOX" ] || cache_fail 'requested BusyBox hash binary is not executable'
fi
if PATH="$CACHE_CHECK_PATH" "$REAL_BASH" -c 'command -v cksum >/dev/null 2>&1'; then
    cache_fail 'isolated PATH unexpectedly contains cksum'
fi

# CI supplies the minimal compiled BusyBox; the local fallback forwards to a
# real SHA-256 implementation. Hashes must depend on file contents so
# equal-length edits cannot accidentally pass.
for cache_backend in standalone busybox unsupported-stat; do
    rm -f "$CACHE_CHECK_PATH/sha256sum" "$CACHE_CHECK_PATH/busybox" "$CACHE_CHECK_PATH/stat" "$TEST_DIR/runtime/config.valid"
    case "$cache_backend" in
        standalone)
            ln -s "$CACHE_HASH_WRAPPER" "$CACHE_CHECK_PATH/sha256sum"
            ln -s "$REAL_STAT" "$CACHE_CHECK_PATH/stat" ;;
        busybox)
            ln -s "$TEST_DIR/busybox-hash" "$CACHE_CHECK_PATH/busybox"
            if PATH="$CACHE_CHECK_PATH" "$REAL_BASH" -c 'command -v sha256sum >/dev/null 2>&1 || command -v stat >/dev/null 2>&1'; then
                cache_fail 'applet-only fixture unexpectedly has sha256sum or stat'
            fi ;;
        unsupported-stat)
            ln -s "$CACHE_HASH_WRAPPER" "$CACHE_CHECK_PATH/sha256sum"
            ln -s "$TEST_DIR/unsupported-stat" "$CACHE_CHECK_PATH/stat" ;;
    esac
    : > "$MOCK_CHECK_EVENTS"
    printf '{"route":"one"}\n' > "$TEST_DIR/config/config.json"
    limited_check > "$TEST_DIR/$cache_backend-first.log" 2>&1 || cache_fail "$cache_backend: initial check failed"
    [ -f "$TEST_DIR/runtime/config.valid" ] || cache_fail "$cache_backend: no cache without cksum"
    cp -p "$TEST_DIR/config/config.json" "$TEST_DIR/reference.json"
    first_stamp=$("$REAL_STAT" -c '%s:%Y:%i' "$TEST_DIR/config/config.json")
    limited_check > "$TEST_DIR/$cache_backend-cached.log" 2>&1 || cache_fail "$cache_backend: cached check failed"
    cache_check_count 1 "$cache_backend: unchanged config was not cached without cksum"
    printf '{"route":"two"}\n' > "$TEST_DIR/config/config.json"
    touch -r "$TEST_DIR/reference.json" "$TEST_DIR/config/config.json"
    [ "$("$REAL_STAT" -c '%s:%Y:%i' "$TEST_DIR/config/config.json")" = "$first_stamp" ] ||
        cache_fail "$cache_backend: fixture did not preserve size/mtime/inode"
    limited_check > "$TEST_DIR/$cache_backend-edited.log" 2>&1 || cache_fail "$cache_backend: changed config check failed"
    cache_check_count 2 "$cache_backend: same-size same-mtime edit reused stale validation"
    if grep -q 'command not found' "$TEST_DIR/$cache_backend-first.log" "$TEST_DIR/$cache_backend-cached.log" "$TEST_DIR/$cache_backend-edited.log"; then
        cache_fail "$cache_backend: a missing optional command leaked into normal validation"
    fi
done

# Missing, unsuccessful, empty, or malformed hashes must never turn into valid
# cache keys. A passing core check remains usable without this optimization;
# an actual core check failure must still reach the caller.
rm -f "$CACHE_CHECK_PATH/busybox" "$CACHE_CHECK_PATH/stat"
ln -s "$REAL_STAT" "$CACHE_CHECK_PATH/stat"
for hash_failure in missing failure empty malformed; do
    rm -f "$CACHE_CHECK_PATH/sha256sum" "$TEST_DIR/runtime/config.valid"
    ln -s "$CACHE_HASH_WRAPPER" "$CACHE_CHECK_PATH/sha256sum"
    CACHE_HASH_BEHAVIOR=ok
    export CACHE_HASH_BEHAVIOR
    : > "$MOCK_CHECK_EVENTS"
    limited_check > "$TEST_DIR/$hash_failure-baseline.log" 2>&1 || cache_fail "$hash_failure: cannot seed cache"
    [ -f "$TEST_DIR/runtime/config.valid" ] || cache_fail "$hash_failure: baseline did not create cache"
    if [ "$hash_failure" = missing ]; then
        rm "$CACHE_CHECK_PATH/sha256sum"
    else
        CACHE_HASH_BEHAVIOR=$hash_failure
    fi
    limited_check > "$TEST_DIR/$hash_failure-first.log" 2>&1 || cache_fail "$hash_failure: passing core check was rejected"
    cache_check_count 2 "$hash_failure: unverifiable prior cache bypassed the core check"
    [ ! -e "$TEST_DIR/runtime/config.valid" ] || cache_fail "$hash_failure: unusable hash was cached"
    limited_check > "$TEST_DIR/$hash_failure-second.log" 2>&1 || cache_fail "$hash_failure: repeated passing check was rejected"
    cache_check_count 3 "$hash_failure: unusable hash bypassed the repeated core check"
    MOCK_CHECK_STATUS=27
    export MOCK_CHECK_STATUS
    if limited_check > "$TEST_DIR/$hash_failure-core-failure.log" 2>&1; then
        cache_fail "$hash_failure: actual core check failure was hidden"
    fi
    cache_check_count 4 "$hash_failure: failing core check was not executed"
    grep -q 'Configuration check failed (exit 27)' "$TEST_DIR/$hash_failure-core-failure.log" ||
        cache_fail "$hash_failure: actual core error code was lost"
    unset MOCK_CHECK_STATUS
done
unset CACHE_HASH_BEHAVIOR
echo 'sbctl validation and cache fallback tests passed.'
