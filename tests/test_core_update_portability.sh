#!/usr/bin/env bash
# Release-specific integrity and rollback using local fake archives and services.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sb-core-update.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
REAL_SHA=$(command -v sha256sum)
export REAL_SHA
mkdir -p "$TEST_DIR/tools" "$TEST_DIR/archive"
cat > "$TEST_DIR/archive/sing-box" <<'SH'
#!/bin/sh
case "$1" in
    version) echo 'sing-box version NEW-test-core' ;;
    check)
        printf 'check:%s\n' "$*" >> "$TEST_EVENTS"
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
case "${MOCK_HASH:-real}" in
    missing) exit 127 ;;
    mismatch) printf '%064d  %s\n' 0 "$1" ;;
    pinned) printf '7179981f14c225e3e872ac60af2086d6d719b4ddfd901c115c86cd9e4581f4fb  %s\n' "$1" ;;
    real) exec "$REAL_SHA" "$@" ;;
    *) exit 66 ;;
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
prepare() {
    CASE_DIR=$TEST_DIR/$1
    SH_SINGBOX_HOME=$CASE_DIR/home
    SH_SINGBOX_CONFIG=$CASE_DIR/custom\ config.json
    TEST_EVENTS=$CASE_DIR/events
    TEST_DOWNLOAD_ARGS=$CASE_DIR/download-args
    TEST_DOWNLOAD_ENV=$CASE_DIR/download-env
    TEST_ASSET=sing-box-1.15.0-alpha.99-reF1nd-linux-amd64-musl.tar.gz
    SB_DOWNLOAD_MODE=direct
    export SH_SINGBOX_HOME SH_SINGBOX_CONFIG TEST_EVENTS TEST_ASSET TEST_DOWNLOAD_ARGS TEST_DOWNLOAD_ENV SB_DOWNLOAD_MODE
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

prepare unsupported_arch
if MOCK_ARCH=mips bash "$BASE/scripts/update-core.sh" > "$CASE_DIR/out" 2>&1; then
    fail 'unsupported arch accepted'
fi
assert_old
[ ! -e "$TEST_EVENTS" ] && [ ! -d "$SH_SINGBOX_HOME/runtime" ] || fail 'unsupported arch changed runtime or downloaded data'
echo 'Core release integrity, custom paths, validation and rollback tests passed.'
