#!/usr/bin/env bash
# Exercise the actual installer sections and updater with mock transports only.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sb-download-integration.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
mkdir -p "$TEST_DIR/tools"

# Keep the complete production package/UI blocks. Nothing in these runners
# registers a service or writes outside the fixture installation directory.
awk '
  /^info "Installing required packages/ { emit = 1 }
  emit { print }
  /^ok "Required installer dependencies available/ { emit = 0 }
' "$BASE/install.sh" > "$TEST_DIR/packages.sh"
awk '
  /^info "Setting up Zashboard Web UI/ { emit = 1 }
  /^# 7\. Geodata/ { emit = 0 }
  emit { print }
' "$BASE/install.sh" > "$TEST_DIR/ui.sh"
test -s "$TEST_DIR/packages.sh" && test -s "$TEST_DIR/ui.sh"
cat > "$TEST_DIR/installer-runner.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
. "$TEST_SOURCE/scripts/download.sh"
info() { printf '%s\n' "$*"; }
ok() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
INSTALL_DIR=$SH_SINGBOX_HOME
case "$1" in
  packages)
    OS=$TEST_OS
    # Force every OpenWrt dependency branch without removing host commands.
    command() {
      if [ "${1:-}" = -v ] && [ "$#" -eq 2 ]; then
        case "$2" in
          opkg|apk) [ "$TEST_MANAGER" = "$2" ] || return 1 ;;
          curl|jq|bash|unzip) [ "$OS" != openwrt ] || return 1 ;;
        esac
      fi
      builtin command "$@"
    }
    . "$TEST_FIXTURES/packages.sh"
    ;;
  ui) . "$TEST_FIXTURES/ui.sh" ;;
  *) exit 64 ;;
esac
printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "${http_proxy-}" "${https_proxy-}" "${all_proxy-}" \
  "${HTTP_PROXY-}" "${HTTPS_PROXY-}" "${ALL_PROXY-}" "${no_proxy-}" "${NO_PROXY-}" > "$TEST_PARENT_ENV"
SH
cat > "$TEST_DIR/tools/curl" <<'SH'
#!/bin/sh
set -eu
output= url= method=GET header= noproxy=
printf '%s\n' "$*" >> "$TEST_ARGS_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output) output=$2; shift 2 ;;
    --header) header=$2; shift 2 ;;
    -X|--request) method=$2; shift 2 ;;
    --noproxy) noproxy=$2; shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
[ -n "$url" ] || exit 64
if [ -n "$output" ]; then
  printf '%s\n' "$url" >> "$TEST_DOWNLOAD_LOG"
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "${http_proxy-}" "${https_proxy-}" "${all_proxy-}" \
    "${HTTP_PROXY-}" "${HTTPS_PROXY-}" "${ALL_PROXY-}" "${no_proxy-}" "${NO_PROXY-}" >> "$TEST_DOWNLOAD_ENV"
  [ "${TEST_FAIL_DOWNLOAD:-0}" -eq 0 ] || exit 22
  case "$url" in
    https://download-mirror.example/proxy/https://*) url=${url#https://download-mirror.example/proxy/} ;;
  esac
  case "$url" in
    https://github.com/zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip)
      printf 'mock UI archive\n' > "$output" ;;
    https://github.com/DustinWin/ruleset_geodata/releases/download/sing-box-ruleset/*.srs)
      printf 'updated rule %s\n' "${url##*/}" > "$output" ;;
    *) exit 65 ;;
  esac
  exit 0
fi

# Local controller traffic must bypass every proxy, preserve the parent
# environment and send the API secret via a private file rather than argv.
[ "$noproxy" = '*' ] || exit 70
[ "${http_proxy-}" = "$TEST_SYSTEM_PROXY" ] || exit 71
[ "${https_proxy-}" = "$TEST_SYSTEM_PROXY" ] || exit 71
[ "${all_proxy-}" = "$TEST_SYSTEM_PROXY" ] || exit 71
case "$header" in @*) header=${header#@} ;; *) exit 72 ;; esac
[ "$(stat -c %a "$header")" = 600 ] || exit 72
[ "$(cat "$header")" = 'Authorization: Bearer integration-api-secret' ] || exit 72
printf '%s %s\n' "$method" "$url" >> "$TEST_API_LOG"
case "$method $url" in
  'GET http://127.0.0.1:18390/version') printf '{"version":"mock"}\n' ;;
  'GET http://127.0.0.1:18390/providers/proxies') printf '{"providers":{"HK pool":{},"node/two":{}}}\n' ;;
  'PUT http://127.0.0.1:18390/providers/proxies/HK%20pool'|'PUT http://127.0.0.1:18390/providers/proxies/node%2Ftwo') : ;;
  *) exit 73 ;;
esac
SH
cat > "$TEST_DIR/package-command" <<'SH'
#!/bin/sh
set -eu
printf '%s %s\n' "${0##*/}" "$*" >> "$TEST_COMMAND_LOG"
printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "${http_proxy-}" "${https_proxy-}" "${all_proxy-}" \
  "${HTTP_PROXY-}" "${HTTPS_PROXY-}" "${ALL_PROXY-}" "${no_proxy-}" "${NO_PROXY-}" >> "$TEST_COMMAND_ENV"
SH
for package_command in apt-get opkg apk; do cp "$TEST_DIR/package-command" "$TEST_DIR/tools/$package_command"; done
cat > "$TEST_DIR/tools/unzip" <<'SH'
#!/bin/sh
[ "$#" -eq 4 ] && [ "$1" = -qo ] && [ "$3" = -d ] || exit 64
[ "$(cat "$2")" = 'mock UI archive' ] || exit 64
mkdir -p "$4/dist"
printf '<!doctype html><title>fixture UI</title>\n' > "$4/dist/index.html"
SH
cat > "$TEST_DIR/tools/uci" <<'SH'
#!/bin/sh
exit 1
SH
chmod 0755 "$TEST_DIR/tools/"*
PATH=$TEST_DIR/tools:$PATH
TEST_SOURCE=$BASE
TEST_FIXTURES=$TEST_DIR
TEST_SYSTEM_PROXY=http://system-proxy.example:8118
TEST_SELECTED_PROXY=http://proxy-user:download-test-secret@127.0.0.1:18888
http_proxy=$TEST_SYSTEM_PROXY https_proxy=$TEST_SYSTEM_PROXY all_proxy=$TEST_SYSTEM_PROXY
HTTP_PROXY=$TEST_SYSTEM_PROXY HTTPS_PROXY=$TEST_SYSTEM_PROXY ALL_PROXY=$TEST_SYSTEM_PROXY
no_proxy=system-no-proxy.example NO_PROXY=system-no-proxy.example
export PATH TEST_SOURCE TEST_FIXTURES TEST_SYSTEM_PROXY TEST_SELECTED_PROXY
export http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY

prepare_case() {
  CASE_DIR=$TEST_DIR/$1
  SH_SINGBOX_HOME=$CASE_DIR/installation
  SH_SINGBOX_CONFIG=$CASE_DIR/device\ config.json
  TEST_ARGS_LOG=$CASE_DIR/args
  TEST_DOWNLOAD_LOG=$CASE_DIR/downloads
  TEST_DOWNLOAD_ENV=$CASE_DIR/download-env
  TEST_COMMAND_LOG=$CASE_DIR/commands
  TEST_COMMAND_ENV=$CASE_DIR/command-env
  TEST_PARENT_ENV=$CASE_DIR/parent-env
  TEST_API_LOG=$CASE_DIR/api
  SB_DOWNLOAD_MODE=$2
  SB_HTTP_PROXY=$TEST_SELECTED_PROXY
  SB_GITHUB_PROXY=https://download-mirror.example/proxy/
  export SH_SINGBOX_HOME SH_SINGBOX_CONFIG TEST_ARGS_LOG TEST_DOWNLOAD_LOG TEST_DOWNLOAD_ENV
  export TEST_COMMAND_LOG TEST_COMMAND_ENV TEST_PARENT_ENV TEST_API_LOG SB_DOWNLOAD_MODE SB_HTTP_PROXY SB_GITHUB_PROXY
  mkdir -p "$CASE_DIR"
  for log in "$TEST_ARGS_LOG" "$TEST_DOWNLOAD_LOG" "$TEST_DOWNLOAD_ENV" "$TEST_COMMAND_LOG" "$TEST_COMMAND_ENV" "$TEST_API_LOG"; do : > "$log"; done
}
assert_environment() {
  local log=$1 mode=$2 selected=$TEST_SYSTEM_PROXY bypass=system-no-proxy.example line
  if [ "$mode" = http ]; then selected=$TEST_SELECTED_PROXY; bypass=; fi
  [ -s "$log" ] || fail 'expected child command did not execute'
  while IFS= read -r line; do
    [ "$line" = "$selected|$selected|$selected|$selected|$selected|$selected|$bypass|$bypass" ] || fail 'wrong proxy environment for child command'
  done < "$log"
}
assert_download_url() {
  if [ "$SB_DOWNLOAD_MODE" = github ]; then
    ! grep -v '^https://download-mirror.example/proxy/https://github.com/' "$TEST_DOWNLOAD_LOG" || fail 'GitHub resource bypassed selected prefix'
  else
    ! grep -v '^https://github.com/' "$TEST_DOWNLOAD_LOG" || fail 'ordinary download URL unexpectedly rewritten'
  fi
  if grep -Eq 'download-test-secret|integration-api-secret' "$TEST_ARGS_LOG" "$CASE_DIR/output"; then fail 'proxy/API credential leaked into arguments/output'; fi
}

for mode in direct http github; do
  for manager in apt-get opkg apk; do
    prepare_case "packages-$mode-$manager" "$mode"
    TEST_MANAGER=$manager TEST_OS=openwrt
    if [ "$manager" = apt-get ]; then TEST_OS=debian_ubuntu; fi
    export TEST_MANAGER TEST_OS
    bash "$TEST_DIR/installer-runner.sh" packages > "$CASE_DIR/output" 2>&1 || { cat "$CASE_DIR/output" >&2; fail 'package installation block failed'; }
    assert_environment "$TEST_COMMAND_ENV" "$mode"
    assert_environment "$TEST_PARENT_ENV" direct
    if [ "$manager" = apt-get ]; then
      [ "$(wc -l < "$TEST_COMMAND_LOG")" -eq 2 ] || fail 'Debian package operations skipped'
    else
      [ "$(wc -l < "$TEST_COMMAND_LOG")" -eq 5 ] || fail 'OpenWrt dependency package operations skipped'
      for package in curl jq bash unzip; do
        action=install; [ "$manager" != apk ] || action=add
        grep -Fxq "$manager $action $package" "$TEST_COMMAND_LOG" || fail 'missing OpenWrt dependency command'
      done
    fi
    if grep -Fq download-test-secret "$TEST_COMMAND_LOG" "$CASE_DIR/output"; then fail 'package proxy credential leaked into arguments/output'; fi
  done

  prepare_case "ui-$mode" "$mode"
  mkdir -p "$SH_SINGBOX_HOME/runtime"
  bash "$TEST_DIR/installer-runner.sh" ui > "$CASE_DIR/output" 2>&1 || { cat "$CASE_DIR/output" >&2; fail 'UI installation block failed'; }
  [ -f "$SH_SINGBOX_HOME/board/dist/index.html" ] || fail 'UI assets were not installed'
  [ "$(wc -l < "$TEST_DOWNLOAD_LOG")" -eq 1 ] || fail 'UI download used an unselected fallback'
  assert_environment "$TEST_DOWNLOAD_ENV" "$mode"
  assert_environment "$TEST_PARENT_ENV" direct
  assert_download_url
  bash "$TEST_DIR/installer-runner.sh" ui > "$CASE_DIR/output" 2>&1 || fail 'existing UI was rejected'
  [ "$(wc -l < "$TEST_DOWNLOAD_LOG")" -eq 1 ] || fail 'existing UI was downloaded again'

  prepare_case "rules-$mode" "$mode"
  printf '{"experimental":{"clash_api":{"external_controller":"0.0.0.0:18390","secret":"integration-api-secret"}}}\n' > "$SH_SINGBOX_CONFIG"
  cp "$SH_SINGBOX_CONFIG" "$CASE_DIR/original.json"
  bash "$BASE/scripts/update-rules.sh" > "$CASE_DIR/output" 2>&1 || { cat "$CASE_DIR/output" >&2; fail 'rule update failed'; }
  [ "$(wc -l < "$TEST_DOWNLOAD_LOG")" -eq 8 ] || fail 'not all rules used unified download'
  for rule in cnip private cn google-cn apple-cn games-cn ads networktest; do
    [ "$(cat "$SH_SINGBOX_HOME/geo/$rule.srs")" = "updated rule $rule.srs" ] || fail 'downloaded rule not installed'
  done
  assert_environment "$TEST_DOWNLOAD_ENV" "$mode"
  assert_download_url
  [ "$(wc -l < "$TEST_API_LOG")" -eq 4 ] || fail 'local provider API used download proxy or lost authentication'
  grep -Fxq 'PUT http://127.0.0.1:18390/providers/proxies/HK%20pool' "$TEST_API_LOG" || fail 'provider name encoding changed'
  cmp "$CASE_DIR/original.json" "$SH_SINGBOX_CONFIG" || fail 'rule update changed runtime configuration'
done

prepare_case rules-failure direct
mkdir -p "$SH_SINGBOX_HOME/geo"
for rule in cnip private cn google-cn apple-cn games-cn ads networktest; do printf 'keep previous rule\n' > "$SH_SINGBOX_HOME/geo/$rule.srs"; done
TEST_FAIL_DOWNLOAD=1 bash "$BASE/scripts/update-rules.sh" > "$CASE_DIR/output" 2>&1 || fail 'rule failure handling regressed'
[ "$(wc -l < "$TEST_DOWNLOAD_LOG")" -eq 8 ] || fail 'failed rules tried a hardcoded mirror'
for rule in cnip private cn google-cn apple-cn games-cn ads networktest; do
  [ "$(cat "$SH_SINGBOX_HOME/geo/$rule.srs")" = 'keep previous rule' ] || fail 'failed download replaced existing rule'
done
[ -z "$(find "$SH_SINGBOX_HOME/geo" -type f ! -name '*.srs' -print)" ] || fail 'failed rule staging files were retained'

for operation in packages rules; do
  prepare_case "invalid-$operation" invalid
  if [ "$operation" = packages ]; then
    TEST_OS=debian_ubuntu TEST_MANAGER=apt-get bash "$TEST_DIR/installer-runner.sh" packages > "$CASE_DIR/output" 2>&1 && fail 'invalid package download configuration accepted'
  else
    bash "$BASE/scripts/update-rules.sh" > "$CASE_DIR/output" 2>&1 && fail 'invalid rule download configuration accepted'
  fi
  [ ! -s "$TEST_COMMAND_LOG" ] && [ ! -s "$TEST_DOWNLOAD_LOG" ] && [ ! -e "$SH_SINGBOX_HOME" ] || fail 'invalid download configuration mutated installation'
done
echo 'Unified package, UI and rule download integration and local API isolation tests passed.'
