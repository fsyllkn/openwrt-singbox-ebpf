#!/usr/bin/env bash
# Release-specific integrity and rollback using local fake archives and services.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sb-core-update.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
REAL_SHA=$(command -v sha256sum)
REAL_BASH=$(command -v bash)
REAL_TIMEOUT=$(command -v timeout)
export REAL_SHA REAL_TIMEOUT
mkdir -p "$TEST_DIR/tools" "$TEST_DIR/archive"
cat > "$TEST_DIR/archive/sing-box" <<'SH'
#!/bin/sh
case "$1" in
    version) echo 'sing-box version NEW-test-core' ;;
    check)
        printf 'check:%s\n' "$*" >> "$TEST_EVENTS"
        [ "$2" = -c ] && [ -f "$3" ] || exit 67
        cp "$3" "$TEST_CHECK_CONFIG_CAPTURE"
        if [ "${MOCK_EDIT_PARTS_DURING_CHECK:-0}" -eq 1 ]; then
            printf '\n' >> "${SH_SINGBOX_CONFIG%.json}.d/inbounds.json"
        fi
        if [ "${MOCK_EDIT_CONFIG_DURING_CHECK:-0}" -eq 1 ]; then
            sed 's/10\.8\.0\.104/10.8.0.105/' "$SH_SINGBOX_CONFIG" > "$SH_SINGBOX_CONFIG.edit"
            touch -r "$SH_SINGBOX_CONFIG" "$SH_SINGBOX_CONFIG.edit"
            mv "$SH_SINGBOX_CONFIG.edit" "$SH_SINGBOX_CONFIG"
        fi
        if [ "${MOCK_HASH_FAIL_AFTER_CHECK:-0}" -eq 1 ]; then
            : > "$TEST_HASH_FAILURE_MARKER"
        fi
        if [ "${MOCK_CHECK_SLEEP:-0}" -gt 0 ]; then
            printf '%s\n' "$$" > "$TEST_CHECK_PID"
            exec sleep "$MOCK_CHECK_SLEEP"
        fi
        if [ "${MOCK_CONFIG_STATUS:-0}" -ne 0 ]; then
            printf 'fixture core rejected configuration (exit %s)\n' "$MOCK_CONFIG_STATUS" >&2
        fi
        exit "${MOCK_CONFIG_STATUS:-0}" ;;
    *) exit 66 ;;
esac
SH
chmod 0755 "$TEST_DIR/archive/sing-box"
tar -czf "$TEST_DIR/core.tar.gz" -C "$TEST_DIR/archive" sing-box
TEST_ARCHIVE=$TEST_DIR/core.tar.gz
TEST_DIGEST=$("$REAL_SHA" "$TEST_ARCHIVE" | awk '{print $1}')
export TEST_ARCHIVE TEST_DIGEST
cat > "$TEST_DIR/tools/uname" <<'SH'
#!/bin/sh
[ "$1" = -m ] || exit 66
printf '%s\n' "${MOCK_ARCH:-x86_64}"
SH
cat > "$TEST_DIR/tools/ldd" <<'SH'
#!/bin/sh
echo musl
SH
cat > "$TEST_DIR/tools/id" <<'SH'
#!/bin/sh
[ "$1" = -u ] || exit 66
echo 0
SH
cat > "$TEST_DIR/tools/curl" <<'SH'
#!/bin/sh
dest=; url=
printf '%s\n' "$*" >> "$TEST_DOWNLOAD_ARGS"
printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "${http_proxy-}" "${https_proxy-}" "${all_proxy-}" \
    "${HTTP_PROXY-}" "${HTTPS_PROXY-}" "${ALL_PROXY-}" "${no_proxy-}" "${NO_PROXY-}" >> "$TEST_DOWNLOAD_ENV"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--output) dest=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
[ -n "$dest" ] && [ -n "$url" ] || exit 66
printf 'download:%s\n' "$url" >> "$TEST_EVENTS"
[ "${MOCK_DOWNLOAD_FAIL:-0}" -eq 0 ] || exit 22
case "$url" in
    https://download-mirror.example/proxy/https://*) url=${url#https://download-mirror.example/proxy/} ;;
esac
case "$url" in
    https://api.github.com/*)
        case "${MOCK_METADATA:-valid}" in
            missing_asset) printf '{"assets":[]}\n' > "$dest" ;;
            no_digest) printf '{"assets":[{"name":"%s"}]}\n' "$TEST_ASSET" > "$dest" ;;
            valid) printf '{"assets":[{"name":"%s","digest":"sha256:%s"}]}\n' "$TEST_ASSET" "$TEST_DIGEST" > "$dest" ;;
            *) exit 66 ;;
        esac ;;
    https://github.com/reF1nd/sing-box-releases/releases/download/*)
        [ "${url##*/}" = "$TEST_ASSET" ] || exit 66
        cp "$TEST_ARCHIVE" "$dest" ;;
    *) exit 66 ;;
esac
SH
cat > "$TEST_DIR/tools/sha256sum" <<'SH'
#!/bin/sh
if [ -n "${TEST_REAL_HASH_BUSYBOX:-}" ]; then
    output=$("$TEST_REAL_HASH_BUSYBOX" sha256sum "$@") || exit "$?"
else
    output=$("$REAL_SHA" "$@") || exit "$?"
fi
# Only the fake release archive needs a synthetic pinned digest. Configuration
# fingerprints always hash actual contents, including when passed over stdin.
case "$output" in
    "$TEST_DIGEST "*)
        case "${MOCK_HASH:-real}" in
            missing) exit 127 ;;
            mismatch) printf '%064d  -\n' 0 ;;
            pinned) printf '7179981f14c225e3e872ac60af2086d6d719b4ddfd901c115c86cd9e4581f4fb  -\n' ;;
            real) printf '%s\n' "$output" ;;
            *) exit 66 ;;
        esac ;;
    *)
        [ ! -e "${TEST_HASH_FAILURE_MARKER:-/nonexistent}" ] || exit 74
        case "${MOCK_CONFIG_HASH:-real}" in
            fail) exit 74 ;;
            empty) exit 0 ;;
            malformed) printf 'not-a-sha256-digest\n' ;;
            failed_output) printf '%s\n' "$output"; exit 74 ;;
            real) printf '%s\n' "$output" ;;
            *) exit 66 ;;
        esac ;;
esac
SH
cat > "$TEST_DIR/tools/systemctl" <<'SH'
#!/bin/sh
case "$*" in
    'is-active --quiet sing-box.service') exit "${MOCK_STOPPED:-1}" ;;
    *) printf 'unexpected-systemctl:%s\n' "$*" >> "$TEST_EVENTS"; exit 66 ;;
esac
SH
chmod 0755 "$TEST_DIR/tools/"*
PATH=$TEST_DIR/tools:$PATH
export PATH
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

# Use an allowlist for the missing-command regression: a failing cksum wrapper
# would still make command -v succeed and inherited /usr/bin would hide the bug.
NO_CKSUM_PATH=$TEST_DIR/no-cksum
APPLET_HASH_PATH=$TEST_DIR/applet-hash
NO_HASH_PATH=$TEST_DIR/no-hash
for tool_path in "$NO_CKSUM_PATH" "$APPLET_HASH_PATH" "$NO_HASH_PATH"; do
    mkdir -p "$tool_path"
    for tool in awk bash chmod cp curl dirname find grep gzip head id jq ldd \
        mkdir mktemp mv readlink rm sed sleep systemctl tar timeout touch tr uname; do
        ln -s "$(command -v "$tool")" "$tool_path/$tool"
    done
done

# Firmware may omit timeout entirely, or only expose its BusyBox applet while
# --list is unavailable. Do not let the host timeout symlink mask either case.
NO_TIMEOUT_PATH=$TEST_DIR/no-timeout
APPLET_TIMEOUT_PATH=$TEST_DIR/applet-timeout
for tool_path in "$NO_TIMEOUT_PATH" "$APPLET_TIMEOUT_PATH"; do
    mkdir -p "$tool_path"
    for tool in awk bash cat chmod cp curl dirname find grep gzip head id jq ldd \
        mkdir mktemp mv readlink rm sed sha256sum sleep systemctl tar touch tr uname; do
        ln -s "$(command -v "$tool")" "$tool_path/$tool"
    done
    if PATH=$tool_path "$REAL_BASH" -c 'command -v timeout'; then
        fail 'missing-timeout fixture exposes host timeout'
    fi
done
cat > "$APPLET_TIMEOUT_PATH/busybox" <<'SH'
#!/bin/sh
case "$1" in
    timeout) shift; exec "$REAL_TIMEOUT" "$@" ;;
    --list) exit 64 ;;
    *) exit 127 ;;
esac
SH
chmod 0755 "$APPLET_TIMEOUT_PATH/busybox"
if PATH=$NO_TIMEOUT_PATH "$REAL_BASH" -c 'command -v busybox'; then
    fail 'no-timeout fixture exposes BusyBox'
fi
"$APPLET_TIMEOUT_PATH/busybox" timeout 1 "$REAL_BASH" -c ':' || fail 'BusyBox timeout fixture cannot run a command'
if "$APPLET_TIMEOUT_PATH/busybox" --list >/dev/null 2>&1; then
    fail 'BusyBox timeout fixture unexpectedly supports --list'
fi
ln -s "$TEST_DIR/tools/sha256sum" "$NO_CKSUM_PATH/sha256sum"
cat > "$APPLET_HASH_PATH/busybox" <<'SH'
#!/bin/sh
# Use the real feature-limited BusyBox in CI; local runs without that binary
# still dispatch to a real SHA-256 implementation rather than a fixed digest.
[ "$1" = sha256sum ] || exit 127
shift
TEST_REAL_HASH_BUSYBOX=${SB_TEST_HASH_BUSYBOX:-}
export TEST_REAL_HASH_BUSYBOX
exec "$TEST_SHA_WRAPPER" "$@"
SH
chmod 0755 "$APPLET_HASH_PATH/busybox"
TEST_SHA_WRAPPER=$TEST_DIR/tools/sha256sum
export TEST_SHA_WRAPPER
if [ -n "${SB_TEST_HASH_BUSYBOX:-}" ]; then
    [ -x "$SB_TEST_HASH_BUSYBOX" ] || fail 'SB_TEST_HASH_BUSYBOX is not executable'
    "$SB_TEST_HASH_BUSYBOX" sha256sum </dev/null >/dev/null || fail 'test BusyBox lacks SHA-256'
    if "$SB_TEST_HASH_BUSYBOX" cksum </dev/null >/dev/null 2>&1; then
        fail 'test BusyBox unexpectedly includes cksum'
    fi
fi
for tool_path in "$NO_CKSUM_PATH" "$APPLET_HASH_PATH" "$NO_HASH_PATH"; do
    if PATH=$tool_path "$REAL_BASH" -c 'command -v cksum'; then
        fail 'missing-cksum fixture exposes the host checksum command'
    fi
done
if PATH=$APPLET_HASH_PATH "$REAL_BASH" -c 'command -v sha256sum'; then
    fail 'applet-only fixture exposes standalone sha256sum'
fi
if PATH=$NO_HASH_PATH "$REAL_BASH" -c 'command -v sha256sum || command -v busybox'; then
    fail 'missing-hash fixture exposes a hash implementation'
fi

prepare() {
    CASE_DIR=$TEST_DIR/$1
    SH_SINGBOX_HOME=$CASE_DIR/home
    SH_SINGBOX_CONFIG=$CASE_DIR/custom\ config.json
    TEST_EVENTS=$CASE_DIR/events
    TEST_DOWNLOAD_ARGS=$CASE_DIR/download-args
    TEST_DOWNLOAD_ENV=$CASE_DIR/download-env
    TEST_CHECK_CONFIG_CAPTURE=$CASE_DIR/checked-config.json
    TEST_HASH_FAILURE_MARKER=$CASE_DIR/hash-failed-after-check
    TEST_CHECK_PID=$CASE_DIR/check.pid
    TEST_ASSET=sing-box-1.15.0-alpha.99-reF1nd-linux-amd64-musl.tar.gz
    SB_DOWNLOAD_MODE=direct
    export SH_SINGBOX_HOME SH_SINGBOX_CONFIG TEST_EVENTS TEST_ASSET TEST_DOWNLOAD_ARGS TEST_DOWNLOAD_ENV TEST_CHECK_CONFIG_CAPTURE TEST_HASH_FAILURE_MARKER TEST_CHECK_PID SB_DOWNLOAD_MODE
    mkdir -p "$SH_SINGBOX_HOME/bin" "$SH_SINGBOX_HOME/scripts"
    cat > "$SH_SINGBOX_HOME/bin/sing-box" <<'SH'
#!/bin/sh
[ "$1" = version ] || exit 66
echo 'sing-box version OLD-test-core'
SH
    cat > "$SH_SINGBOX_HOME/scripts/sbctl" <<'SH'
#!/bin/sh
[ "$1" = restart ] || exit 66
version=$("$SH_SINGBOX_HOME/bin/sing-box" version)
printf 'restart:%s\n' "$version" >> "$TEST_EVENTS"
case "$version" in
    *NEW*) exit "${MOCK_RESTART_STATUS:-0}" ;;
    *) exit 0 ;;
esac
SH
    chmod 0755 "$SH_SINGBOX_HOME/bin/sing-box" "$SH_SINGBOX_HOME/scripts/sbctl"
    printf '{"inbounds":[{"listen":"10.77.9.5"}],"route":{"rules":[{"ip_cidr":["10.8.0.104/32"],"outbound":"office"}]}}\n' > "$SH_SINGBOX_CONFIG"
    cp "$SH_SINGBOX_CONFIG" "$CASE_DIR/original.json"
    cp "$SH_SINGBOX_HOME/bin/sing-box" "$CASE_DIR/old-core"
}
assert_old() {
    cmp "$CASE_DIR/old-core" "$SH_SINGBOX_HOME/bin/sing-box" || fail 'existing core was replaced on failure'
    cmp "$CASE_DIR/original.json" "$SH_SINGBOX_CONFIG" || fail 'device configuration was modified'
}

# Mock only the central composition API, never duplicate its validation rules.
# Separate central tests cover real wrapping/digests/locking. These fixtures
# prove updater order, candidate selection and no writes to live JSON/sources.
prepare_parts() {
    prepare "$1"
    PARTS_DIR=${SH_SINGBOX_CONFIG%.json}.d
    mkdir -p "$PARTS_DIR" "$SH_SINGBOX_HOME/config"
    cp "$SH_SINGBOX_CONFIG" "$PARTS_DIR/build.json"
    for part in layout inbounds providers outbounds routing settings; do
        printf '{"fixture":"%s"}\n' "$part" > "$PARTS_DIR/$part.json"
    done
    printf '{"managed":"policy"}\n' > "$SH_SINGBOX_HOME/config/config.template.json"
    cat > "$SH_SINGBOX_HOME/scripts/config-parts.sh" <<'SH'
#!/bin/sh
set -eu
parts=${SH_SINGBOX_CONFIG%.json}.d
case "$1" in
    fingerprint)
        [ "${MOCK_PARTS_INVALID:-0}" -eq 0 ] || { echo 'Configuration generated output was manually edited; import it first.' >&2; exit 36; }
        "$REAL_SHA" "$parts/"*.json "$SH_SINGBOX_CONFIG" "$SH_SINGBOX_HOME/config/config.template.json" | "$REAL_SHA" | awk '{print $1}' ;;
    build)
        printf 'parts:build\n' >> "$TEST_EVENTS"
        [ "${MOCK_PARTS_BUILD_STATUS:-0}" -eq 0 ] || exit "$MOCK_PARTS_BUILD_STATUS"
        cp "$parts/build.json" "$2"
        chmod 0600 "$2" ;;
    *) printf 'unexpected-parts:%s\n' "$*" >> "$TEST_EVENTS"; exit 66 ;;
esac
SH
    chmod 0755 "$SH_SINGBOX_HOME/scripts/config-parts.sh"
    cp -a "$PARTS_DIR" "$CASE_DIR/original-parts"
}

assert_parts_unchanged() {
    diff -r "$CASE_DIR/original-parts" "$PARTS_DIR" || fail 'updater modified layout or editable sources'
    cmp "$CASE_DIR/original.json" "$SH_SINGBOX_CONFIG" || fail 'updater modified generated runtime JSON'
    ! grep -q '^unexpected-parts:' "$TEST_EVENTS" || fail 'updater attempted to render or commit configuration'
}

for timeout_backend in absent applet; do
    case "$timeout_backend" in
        absent) tool_path=$NO_TIMEOUT_PATH ;;
        applet) tool_path=$APPLET_TIMEOUT_PATH ;;
    esac
    prepare "without-timeout-$timeout_backend"
    if ! PATH=$tool_path MOCK_STOPPED=0 "$REAL_BASH" "$BASE/scripts/update-core.sh" \
        1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
        cat "$CASE_DIR/out" >&2
        [ ! -f "$SH_SINGBOX_HOME/runtime/core-update-check.log" ] || cat "$SH_SINGBOX_HOME/runtime/core-update-check.log" >&2
        fail "$timeout_backend timeout environment blocked valid existing configuration"
    fi
    "$SH_SINGBOX_HOME/bin/sing-box" version | grep -Fq NEW-test-core || fail 'timeout-free update did not install the candidate'
    cmp "$CASE_DIR/original.json" "$SH_SINGBOX_CONFIG" || fail 'timeout-free update modified private configuration'
    [ "$(grep -c '^check:' "$TEST_EVENTS")" -eq 1 ] || fail 'configuration validation was skipped or executed more than once'
    [ "$(grep -c '^restart:' "$TEST_EVENTS")" -eq 1 ] || fail 'timeout-free update did not restart running service once'
done

# Both a genuinely empty first install and a first install with a supplied
# configuration must work. An absent old binary does not justify skipping a
# configuration that already exists at the requested runtime path.
prepare fresh_without_timeout
rm "$SH_SINGBOX_HOME/bin/sing-box" "$SH_SINGBOX_CONFIG"
PATH=$NO_TIMEOUT_PATH "$REAL_BASH" "$BASE/scripts/update-core.sh" \
    1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1 || { cat "$CASE_DIR/out" >&2; fail 'empty first install requires timeout'; }
"$SH_SINGBOX_HOME/bin/sing-box" version | grep -Fq NEW-test-core || fail 'empty first install did not acquire core'
[ ! -e "$SH_SINGBOX_CONFIG" ] || fail 'core updater unexpectedly created a configuration'
! grep -Eq '^(check:|restart:)' "$TEST_EVENTS" || fail 'empty first install checked nonexistent config or restarted service'

prepare supplied_config_without_timeout
rm "$SH_SINGBOX_HOME/bin/sing-box"
PATH=$NO_TIMEOUT_PATH "$REAL_BASH" "$BASE/scripts/update-core.sh" \
    1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1 || { cat "$CASE_DIR/out" >&2; fail 'first install with supplied config requires timeout'; }
"$SH_SINGBOX_HOME/bin/sing-box" version | grep -Fq NEW-test-core || fail 'first install with supplied config did not acquire core'
cmp "$CASE_DIR/original.json" "$SH_SINGBOX_CONFIG" || fail 'first install replaced supplied config'
[ "$(grep -c '^check:' "$TEST_EVENTS")" -eq 1 ] || fail 'supplied config was not checked exactly once'
! grep -q '^restart:' "$TEST_EVENTS" || fail 'first install started a stopped service'

prepare rejected_config_without_timeout
if PATH=$NO_TIMEOUT_PATH MOCK_STOPPED=0 MOCK_CONFIG_STATUS=27 "$REAL_BASH" "$BASE/scripts/update-core.sh" \
    1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
    fail 'missing timeout hid actual core rejection'
fi
assert_old
[ "$(grep -c '^check:' "$TEST_EVENTS")" -eq 1 ] || fail 'rejected config never reached core validation'
grep -Fq 'fixture core rejected configuration (exit 27)' "$SH_SINGBOX_HOME/runtime/core-update-check.log" || fail 'actual core rejection was not retained'
grep -Fq 'New core configuration check failed (exit 27)' "$CASE_DIR/out" || fail 'actual core failure status was misreported'
! grep -q '^restart:' "$TEST_EVENTS" || fail 'rejected config restarted a running service'

prepare hung_config_without_timeout
check_result=0
PATH=$NO_TIMEOUT_PATH MOCK_STOPPED=0 MOCK_CHECK_SLEEP=30 SB_CHECK_TIMEOUT=1 \
    "$REAL_TIMEOUT" --kill-after=2 8 "$REAL_BASH" "$BASE/scripts/update-core.sh" \
    1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1 || check_result=$?
[ -s "$TEST_CHECK_PID" ] || fail 'hung check fixture did not start'
check_pid=$(cat "$TEST_CHECK_PID")
if kill -0 "$check_pid" 2>/dev/null; then
    kill -KILL "$check_pid" 2>/dev/null || :
    fail 'timed-out configuration check was left running'
fi
[ "$check_result" -eq 1 ] || fail "hung core was not stopped by its own validation deadline (exit $check_result)"
assert_old
grep -Eiq 'timed out|timeout expired' "$CASE_DIR/out" || fail 'validation deadline did not identify an actual timeout'
! grep -Fq 'New core rejects the existing configuration' "$CASE_DIR/out" || fail 'timeout was misreported as configuration rejection'
! grep -q '^restart:' "$TEST_EVENTS" || fail 'timed-out core check restarted a running service'
echo 'Timeout-free first installs, retries, validation failures and bounded checks passed.'
if [ "${SB_TEST_CORE_TIMEOUT_ONLY:-0}" -eq 1 ]; then exit 0; fi

for hash_backend in standalone applet; do
    case "$hash_backend" in
        standalone) tool_path=$NO_CKSUM_PATH ;;
        applet) tool_path=$APPLET_HASH_PATH ;;
    esac
    prepare "without-cksum-$hash_backend"
    if ! PATH=$tool_path MOCK_STOPPED=0 "$REAL_BASH" "$BASE/scripts/update-core.sh" \
        1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
        cat "$CASE_DIR/out" >&2; fail "$hash_backend SHA-256 update requires unavailable cksum"
    fi
    "$SH_SINGBOX_HOME/bin/sing-box" version | grep -Fq NEW-test-core || fail 'cksum-free update did not install the candidate'
    cmp "$CASE_DIR/original.json" "$SH_SINGBOX_CONFIG" || fail 'cksum-free update modified private configuration'
    [ "$(grep -c '^restart:' "$TEST_EVENTS")" -eq 1 ] || fail 'running service was not restarted exactly once'
    grep -Fq 'restart:sing-box version NEW-test-core' "$TEST_EVENTS" || fail 'running service did not receive the new core'

    prepare "without-cksum-concurrent-edit-$hash_backend"
    if PATH=$tool_path MOCK_STOPPED=0 MOCK_EDIT_CONFIG_DURING_CHECK=1 \
        "$REAL_BASH" "$BASE/scripts/update-core.sh" 1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
        fail 'same-size configuration edit during validation was ignored'
    fi
    cmp "$CASE_DIR/old-core" "$SH_SINGBOX_HOME/bin/sing-box" || fail 'concurrent legacy edit replaced the old core'
    sed 's/10\.8\.0\.104/10.8.0.105/' "$CASE_DIR/original.json" > "$CASE_DIR/edited.json"
    cmp "$CASE_DIR/edited.json" "$SH_SINGBOX_CONFIG" || fail 'concurrent user edit was lost'
    [ "$(wc -c < "$CASE_DIR/original.json")" -eq "$(wc -c < "$SH_SINGBOX_CONFIG")" ] || fail 'edit fixture changed config length'
    grep -Fq 'changed during core validation' "$CASE_DIR/out" || fail 'same-size edit did not reach the content fingerprint guard'
    ! grep -q '^restart:' "$TEST_EVENTS" || fail 'concurrent edit restarted a running service'
done

prepare no_hash_implementation
if PATH=$NO_HASH_PATH MOCK_STOPPED=0 "$REAL_BASH" "$BASE/scripts/update-core.sh" \
    1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
    fail 'update without a hash implementation succeeded'
fi
assert_old
[ ! -e "$TEST_EVENTS" ] || fail 'missing hash implementation reached download or service actions'
grep -Eiq 'SHA-?256' "$CASE_DIR/out" || fail 'missing hash implementation lacks a useful diagnostic'

for hash_failure in fail empty malformed failed_output; do
    prepare "config-hash-$hash_failure"
    if PATH=$NO_CKSUM_PATH MOCK_STOPPED=0 MOCK_CONFIG_HASH=$hash_failure \
        "$REAL_BASH" "$BASE/scripts/update-core.sh" 1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
        fail "$hash_failure configuration hash was accepted"
    fi
    assert_old
    [ ! -e "$TEST_EVENTS" ] || fail 'invalid configuration hash reached download or service actions'
done

prepare config_hash_recheck_failure
if PATH=$NO_CKSUM_PATH MOCK_STOPPED=0 MOCK_HASH_FAIL_AFTER_CHECK=1 \
    "$REAL_BASH" "$BASE/scripts/update-core.sh" 1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
    fail 'configuration hash failure during recheck was ignored'
fi
assert_old
grep -q '^check:' "$TEST_EVENTS" || fail 'recheck hash failure did not occur after candidate validation'
! grep -q '^restart:' "$TEST_EVENTS" || fail 'recheck hash failure restarted a running service'
echo 'No-cksum updates, real content fingerprints and fail-closed hash checks passed.'
if [ "${SB_TEST_CORE_HASH_ONLY:-0}" -eq 1 ]; then exit 0; fi

prepare custom_release
bash "$BASE/scripts/update-core.sh" 1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1 || { cat "$CASE_DIR/out" >&2; fail 'custom release update failed'; }
"$SH_SINGBOX_HOME/bin/sing-box" version | grep -Fq NEW-test-core || fail 'custom core not installed'
grep -Fq '/releases/tags/v1.15.0-alpha.99-reF1nd' "$TEST_EVENTS" || fail 'wrong release metadata selected'
grep -Fq "check:check -c $SH_SINGBOX_CONFIG" "$TEST_EVENTS" || fail 'custom config not validated before update'
! grep -q '^restart:' "$TEST_EVENTS" || fail 'stopped service restarted'
cmp "$CASE_DIR/original.json" "$SH_SINGBOX_CONFIG" || fail 'custom config changed'

prepare http_release
proxy=http://proxy-user:download-test-secret@127.0.0.1:18888
SB_DOWNLOAD_MODE=http SB_HTTP_PROXY=$proxy no_proxy='*' NO_PROXY='*' \
    bash "$BASE/scripts/update-core.sh" 1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1 || {
    cat "$CASE_DIR/out" >&2; fail 'HTTP-proxied release update failed'
}
[ "$(wc -l < "$TEST_DOWNLOAD_ENV")" -eq 2 ] || fail 'metadata/archive did not both use unified download'
while IFS= read -r environment; do
    [ "$environment" = "$proxy|$proxy|$proxy|$proxy|$proxy|$proxy||" ] || fail 'metadata/archive did not receive selected HTTP proxy'
done < "$TEST_DOWNLOAD_ENV"
if grep -Fq download-test-secret "$TEST_DOWNLOAD_ARGS" "$CASE_DIR/out"; then fail 'download proxy credential leaked into arguments/output'; fi
cmp "$CASE_DIR/original.json" "$SH_SINGBOX_CONFIG" || fail 'HTTP core update changed device configuration'

prepare github_release
SB_DOWNLOAD_MODE=github SB_GITHUB_PROXY=https://download-mirror.example/proxy/ \
    bash "$BASE/scripts/update-core.sh" 1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1 || {
    cat "$CASE_DIR/out" >&2; fail 'GitHub-prefixed release update failed'
}
grep -Fq 'download:https://download-mirror.example/proxy/https://github.com/reF1nd/' "$TEST_EVENTS" || fail 'archive did not use selected GitHub prefix'
grep -Fq 'download:https://api.github.com/repos/reF1nd/' "$TEST_EVENTS" || fail 'release API was rewritten as a GitHub file download'
! grep -Fq 'https://download-mirror.example/proxy/https://api.github.com/' "$TEST_EVENTS" || fail 'unsupported API mirror rewriting attempted'

prepare pinned_release
TEST_ASSET=sing-box-1.15.0-alpha.11-reF1nd-linux-amd64-musl.tar.gz; export TEST_ASSET
MOCK_HASH=pinned bash "$BASE/scripts/update-core.sh" > "$CASE_DIR/out" 2>&1 || { cat "$CASE_DIR/out" >&2; fail 'pinned update failed'; }
! grep -q 'api.github.com' "$TEST_EVENTS" || fail 'pinned version unnecessarily required release API'

prepare failed_download
TEST_ASSET=sing-box-1.15.0-alpha.11-reF1nd-linux-amd64-musl.tar.gz; export TEST_ASSET
if MOCK_DOWNLOAD_FAIL=1 bash "$BASE/scripts/update-core.sh" > "$CASE_DIR/out" 2>&1; then fail 'failed download reported success'; fi
assert_old
[ "$(grep -c '^download:' "$TEST_EVENTS")" -eq 1 ] || fail 'failed download tried an unselected fallback'
! grep -Fq ghfast "$TEST_EVENTS" || fail 'failed core download used a hardcoded mirror'

prepare invalid_download_mode
if SB_DOWNLOAD_MODE=invalid bash "$BASE/scripts/update-core.sh" > "$CASE_DIR/out" 2>&1; then fail 'invalid download configuration accepted'; fi
assert_old
[ ! -e "$TEST_EVENTS" ] && [ ! -d "$SH_SINGBOX_HOME/runtime" ] || fail 'invalid download mode changed runtime or downloaded data'

for scenario in missing_asset no_digest mismatch missing bad_config bad_timeout; do
    prepare "$scenario"
    case "$scenario" in
        missing_asset|no_digest) export MOCK_METADATA=$scenario ;;
        mismatch|missing) export MOCK_HASH=$scenario ;;
        bad_config) export MOCK_CONFIG_STATUS=27 ;;
        bad_timeout) export SB_CHECK_TIMEOUT=invalid ;;
    esac
    if bash "$BASE/scripts/update-core.sh" v1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
        fail "$scenario update unexpectedly succeeded"
    fi
    unset MOCK_METADATA MOCK_HASH MOCK_CONFIG_STATUS SB_CHECK_TIMEOUT
    assert_old
    ! grep -q '^restart:' "$TEST_EVENTS" || fail "$scenario restarted a service"
    if [ "$scenario" = bad_timeout ]; then
        grep -Fq 'SB_CHECK_TIMEOUT must be a positive integer' "$SH_SINGBOX_HOME/runtime/core-update-check.log" ||
            fail 'invalid timeout diagnostic was lost during cleanup'
        grep -Fq 'core-update-check.log' "$CASE_DIR/out" || fail 'config validation failure did not identify retained log'
    fi
done

prepare rollback
if MOCK_STOPPED=0 MOCK_RESTART_STATUS=4 bash "$BASE/scripts/update-core.sh" v1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
    fail 'failed new core restart reported success'
fi
assert_old
[ "$(grep -c '^restart:' "$TEST_EVENTS")" -eq 2 ] || fail 'previous core service was not restored'
grep -Fq 'restart:sing-box version OLD-test-core' "$TEST_EVENTS" || fail 'rollback did not restart previous core'

prepare_parts split_applied
bash "$BASE/scripts/update-core.sh" v1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1 || {
    cat "$CASE_DIR/out" >&2; fail 'applied split configuration could not update its core'
}
"$SH_SINGBOX_HOME/bin/sing-box" version | grep -Fq NEW-test-core || fail 'split installation did not receive candidate core'
grep -Eq 'check:check -c .*/runtime/core-update\.[^/]+/config-candidate.json$' "$TEST_EVENTS" || fail 'new core did not validate the temporary composed config'
cmp "$PARTS_DIR/build.json" "$TEST_CHECK_CONFIG_CAPTURE" || fail 'new core checked the wrong composed configuration'
[ "$(grep -c '^parts:build' "$TEST_EVENTS")" -ge 3 ] || fail 'split sources were not rechecked before binary replacement'
assert_parts_unchanged

# A source menu/controller can export a missing, non-executable or obsolete
# composer path. The updater must always use the deployed service's readable
# script, including on archives/filesystems that do not preserve execute bits.
for selector in missing nonexecutable executable; do
    prepare_parts "split inherited $selector"
    stale_tool="$CASE_DIR/old source/scripts/config-parts.sh"
    mkdir -p "$(dirname "$stale_tool")"
    if [ "$selector" != missing ]; then
        cat > "$stale_tool" <<'SH'
#!/bin/sh
printf 'wrong-source-composer\n' >> "$TEST_EVENTS"
exit 91
SH
        case "$selector" in
            nonexecutable) chmod 0644 "$stale_tool" ;;
            executable) chmod 0755 "$stale_tool" ;;
        esac
    fi
    chmod 0644 "$SH_SINGBOX_HOME/scripts/config-parts.sh"
    SB_CONFIG_PARTS_TOOL="$stale_tool" \
        bash "$BASE/scripts/update-core.sh" v1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1 || {
        cat "$CASE_DIR/out" >&2; fail "inherited $selector selector blocked the installed updater"
    }
    "$SH_SINGBOX_HOME/bin/sing-box" version | grep -Fq NEW-test-core || fail 'readable installed composer did not validate the update'
    ! grep -q '^wrong-source-composer' "$TEST_EVENTS" || fail 'core updater executed an inherited source composer'
    [ "$(grep -c '^parts:build' "$TEST_EVENTS")" -ge 3 ] || fail 'installed composer was not used for all update checks'
    [ "$(stat -c '%a' "$SH_SINGBOX_HOME/scripts/config-parts.sh")" = 644 ] || fail 'updater changed composer permissions instead of invoking Bash'
    if [ "$selector" = nonexecutable ]; then
        [ "$(stat -c '%a' "$stale_tool")" = 644 ] || fail 'updater changed source permissions'
    fi
    assert_parts_unchanged
done

for scenario in missing_output pending invalid_manual broken_build missing_tool directory_tool; do
    prepare_parts "split-$scenario"
    case "$scenario" in
        missing_output) rm "$SH_SINGBOX_CONFIG" ;;
        pending)
            jq '.unapplied = true' "$PARTS_DIR/build.json" > "$CASE_DIR/pending.json"
            mv "$CASE_DIR/pending.json" "$PARTS_DIR/build.json"
            cp "$PARTS_DIR/build.json" "$CASE_DIR/original-parts/build.json" ;;
        invalid_manual) export MOCK_PARTS_INVALID=1 ;;
        broken_build) export MOCK_PARTS_BUILD_STATUS=37 ;;
        missing_tool) rm "$SH_SINGBOX_HOME/scripts/config-parts.sh" ;;
        directory_tool)
            rm "$SH_SINGBOX_HOME/scripts/config-parts.sh"
            mkdir "$SH_SINGBOX_HOME/scripts/config-parts.sh" ;;
    esac
    if bash "$BASE/scripts/update-core.sh" v1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
        fail "split $scenario update unexpectedly succeeded"
    fi
    unset MOCK_PARTS_INVALID MOCK_PARTS_BUILD_STATUS
    cmp "$CASE_DIR/old-core" "$SH_SINGBOX_HOME/bin/sing-box" || fail 'rejected split configuration changed the core'
    diff -r "$CASE_DIR/original-parts" "$PARTS_DIR" || fail 'rejected split configuration changed sources'
    if [ "$scenario" = missing_output ]; then
        [ ! -e "$SH_SINGBOX_CONFIG" ] || fail 'core updater recreated missing generated output'
    else
        cmp "$CASE_DIR/original.json" "$SH_SINGBOX_CONFIG" || fail 'rejected split configuration changed generated output'
    fi
    if [ -e "$TEST_EVENTS" ]; then
        ! grep -Eq '^(download:|restart:|check:|unexpected-parts:)' "$TEST_EVENTS" || fail 'unapplied/invalid configuration triggered core or network actions'
    fi
    case "$scenario" in
        missing_output|pending) grep -Fq 'sbctl preflight' "$CASE_DIR/out" || fail 'unapplied parts error omitted recovery command' ;;
        missing_tool|directory_tool)
            grep -Fq "Missing or unreadable installed configuration-parts tool: $SH_SINGBOX_HOME/scripts/config-parts.sh" "$CASE_DIR/out" ||
                fail 'missing installed composer did not identify the actual service path' ;;
    esac
done

prepare_parts split_bad_candidate
if MOCK_CONFIG_STATUS=27 bash "$BASE/scripts/update-core.sh" v1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
    fail 'new core rejection of split candidate was accepted'
fi
assert_old
assert_parts_unchanged
! grep -q '^restart:' "$TEST_EVENTS" || fail 'rejected new core stopped/restarted existing service'

prepare_parts split_concurrent_edit
if MOCK_EDIT_PARTS_DURING_CHECK=1 bash "$BASE/scripts/update-core.sh" v1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
    fail 'source edit during candidate validation was ignored'
fi
assert_old
printf '\n' >> "$CASE_DIR/original-parts/inbounds.json"
assert_parts_unchanged
grep -Fq 'changed during core validation' "$CASE_DIR/out" || fail 'concurrent edit error was unclear'
! grep -q '^restart:' "$TEST_EVENTS" || fail 'concurrent user edit stopped/restarted existing service'

prepare_parts split_rollback
if MOCK_STOPPED=0 MOCK_RESTART_STATUS=4 bash "$BASE/scripts/update-core.sh" v1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
    fail 'failed split restart reported success'
fi
assert_old
assert_parts_unchanged
[ "$(grep -c '^restart:' "$TEST_EVENTS")" -eq 2 ] || fail 'split update did not recover the old core through its normal controller'

# Run the same rollback through the real parts engine as well. Only the binary,
# transport and service are mocked, so fingerprint/build/no-op render must agree
# across the updater and both normal controller restart attempts.
prepare real_parts_rollback
mkdir -p "$SH_SINGBOX_HOME/config"
cp "$BASE/config/config.template.json" "$SH_SINGBOX_HOME/config/config.template.json"
cp "$BASE/config/config.template.json" "$SH_SINGBOX_CONFIG"
cp "$SH_SINGBOX_CONFIG" "$CASE_DIR/original.json"
for helper in runtime-paths.sh config-parts-lib.sh config-parts.sh; do
    cp "$BASE/scripts/$helper" "$SH_SINGBOX_HOME/scripts/$helper"
    chmod 0755 "$SH_SINGBOX_HOME/scripts/$helper"
done
cat > "$SH_SINGBOX_HOME/scripts/sbctl" <<'SH'
#!/bin/sh
set -eu
case "$1" in
    preflight) jq -e 'type == "object"' "$SH_SINGBOX_CONFIG" >/dev/null ;;
    restart)
        bash "$SH_SINGBOX_HOME/scripts/config-parts.sh" render
        version=$("$SH_SINGBOX_HOME/bin/sing-box" version)
        printf 'restart:%s\n' "$version" >> "$TEST_EVENTS"
        case "$version" in *NEW*) exit "${MOCK_RESTART_STATUS:-0}" ;; esac ;;
    *) exit 66 ;;
esac
SH
chmod 0755 "$SH_SINGBOX_HOME/scripts/sbctl"
bash "$SH_SINGBOX_HOME/scripts/config-parts.sh" init > "$CASE_DIR/init.log" 2>&1 || {
    cat "$CASE_DIR/init.log" >&2; fail 'real parts engine failed to initialize fixture'
}
PARTS_DIR=${SH_SINGBOX_CONFIG%.json}.d
cp -a "$PARTS_DIR" "$CASE_DIR/original-parts"
if MOCK_STOPPED=0 MOCK_RESTART_STATUS=4 bash "$BASE/scripts/update-core.sh" v1.15.0-alpha.99-reF1nd > "$CASE_DIR/out" 2>&1; then
    fail 'real-parts failed restart reported success'
fi
assert_old
assert_parts_unchanged
[ "$(grep -c '^restart:' "$TEST_EVENTS")" -eq 2 ] || { cat "$CASE_DIR/out" >&2; fail 'real parts rollback failed to restart old core'; }
! grep -Fq 'Configuration changed during restart' "$CASE_DIR/out" || fail 'no-op real parts render unexpectedly changed state'

prepare unsupported_arch
if MOCK_ARCH=mips bash "$BASE/scripts/update-core.sh" > "$CASE_DIR/out" 2>&1; then
    fail 'unsupported arch accepted'
fi
assert_old
[ ! -e "$TEST_EVENTS" ] && [ ! -d "$SH_SINGBOX_HOME/runtime" ] || fail 'unsupported arch changed runtime or downloaded data'
echo 'Core release integrity, custom paths, validation and rollback tests passed.'
