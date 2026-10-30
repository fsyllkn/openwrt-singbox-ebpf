#!/usr/bin/env bash
# Real composition, path handling and transactions; core/device checks are
# mocked. No network, service, eBPF or firewall operations run in this suite.
set -euo pipefail
umask 077
BASE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d /tmp/sb-config-parts.XXXXXX)
CHILD_PID= SECOND_PID=
cleanup() {
    [ -z "$CHILD_PID" ] || kill "$CHILD_PID" 2>/dev/null || :
    [ -z "$SECOND_PID" ] || kill "$SECOND_PID" 2>/dev/null || :
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
TOOL=$BASE/scripts/config-parts.sh
LIB=$BASE/scripts/config-parts-lib.sh
REAL_MV=$(command -v mv)
REAL_SHA256=$(command -v sha256sum)
REAL_BASH=$(command -v bash)
REAL_GREP=$(command -v grep)
export REAL_MV REAL_SHA256
mkdir "$TEST_ROOT/tools"
cat > "$TEST_ROOT/tools/mv" <<'SH'
#!/bin/bash
set -eu
last=
for argument do last=$argument; done
if [ -n "${TEST_FAIL_MV_ONCE:-}" ] && [ -f "$TEST_FAIL_MV_ONCE" ] && [ "$last" = "${TEST_FAIL_MV_PATH:-}" ]; then
    rm -f -- "$TEST_FAIL_MV_ONCE"
    exit 74
fi
exec "$REAL_MV" "$@"
SH
chmod 0755 "$TEST_ROOT/tools/mv"
PATH="$TEST_ROOT/tools:$PATH"
export PATH

fixture() {
    CASE_DIR=$TEST_ROOT/$1
    SH_SINGBOX_HOME=$CASE_DIR/service\ home
    SH_SINGBOX_CONFIG=$CASE_DIR/active\ configuration.json
    PARTS=${SH_SINGBOX_CONFIG%.json}.d
    PREFLIGHT_LOG=$CASE_DIR/preflight.log
    TEST_ACTIVE_CONFIG=$SH_SINGBOX_CONFIG
    TEST_ACTIVE_HOME=$SH_SINGBOX_HOME
    export SH_SINGBOX_HOME SH_SINGBOX_CONFIG PREFLIGHT_LOG TEST_ACTIVE_CONFIG TEST_ACTIVE_HOME
    unset SB_CONFIG_PARTS_EXPECTED TEST_FAIL_PREFLIGHT TEST_PREFLIGHT_WAIT TEST_PREFLIGHT_READY TEST_FAIL_MV_ONCE TEST_FAIL_MV_PATH
    mkdir -p "$SH_SINGBOX_HOME/config" "$SH_SINGBOX_HOME/scripts" "$SH_SINGBOX_HOME/runtime"
    : > "$PREFLIGHT_LOG"
    cp "$BASE/config/config.template.json" "$SH_SINGBOX_HOME/config/config.template.json"
    jq '
      .inbounds[1] += {tcp_fast_open:true,users:[{username:"fixture",password:"fixture-sensitive-password"}]}
      | .outbounds += [{type:"socks",tag:"office-node",server:"203.0.113.20",server_port:1080,password:"fixture-sensitive-password"}]
      | .route.rules = (.route.rules[:3] + [
          {ip_cidr:["10.77.0.0/24"],source_ip_cidr:["10.1.0.0/16"],inbound:["lan-mixed"],network:["tcp"],port_range:["443:444"],action:"route",outbound:"office-node"},
          {process_name:["fixture-worker"],action:"route",outbound:"direct"}
        ] + .route.rules[3:])
    ' "$BASE/config/config.template.json" > "$SH_SINGBOX_CONFIG"
    cat > "$SH_SINGBOX_HOME/scripts/sbctl" <<'SH'
#!/bin/sh
set -eu
[ "$#" -eq 1 ] && [ "$1" = preflight ] || exit 65
[ "$SH_SINGBOX_HOME" = "$TEST_ACTIVE_HOME" ] || exit 66
[ "$SH_SINGBOX_CONFIG" != "$TEST_ACTIVE_CONFIG" ] || exit 67
case "$SH_SINGBOX_CONFIG" in *.json) parts=${SH_SINGBOX_CONFIG%.json}.d ;; *) parts=$SH_SINGBOX_CONFIG.d ;; esac
[ ! -e "$parts" ] && [ ! -L "$parts" ] || exit 68
[ "$(stat -c %a "$SH_SINGBOX_CONFIG")" = 600 ] || exit 69
printf 'preflight\n' >> "$PREFLIGHT_LOG"
if [ -n "${TEST_PREFLIGHT_READY:-}" ]; then
    : > "$TEST_PREFLIGHT_READY"
    attempts=0
    while [ -e "$TEST_PREFLIGHT_WAIT" ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 400 ] || exit 70
        sleep 0.05
    done
fi
if [ "${TEST_FAIL_PREFLIGHT:-0}" = 1 ]; then
    printf 'mock diagnostic: fixture-sensitive-password\n' >&2
    exit 71
fi
jq -e 'type=="object" and (.inbounds|type=="array") and (.outbounds|type=="array")' "$SH_SINGBOX_CONFIG" >/dev/null
SH
    chmod 0755 "$SH_SINGBOX_HOME/scripts/sbctl"
}

tool() { "$REAL_BASH" "$TOOL" "$@"; }
equal_json() { jq -en --slurpfile a "$1" --slurpfile b "$2" '$a==$b' >/dev/null; }
state() {
    local name
    for name in "$SH_SINGBOX_CONFIG" "$PARTS/layout.json" "$PARTS/inbounds.json" "$PARTS/outbounds.json" "$PARTS/providers.json" "$PARTS/routing.json" "$PARTS/settings.json"; do
        if [ -f "$name" ]; then sha256sum "$name"; else printf 'missing %s\n' "$name"; fi
    done | sha256sum
}
reject() {
    if tool "$@" > "$CASE_DIR/rejected.log" 2>&1; then fail "unexpected success: $*"; fi
    if "$REAL_GREP" -q 'fixture-sensitive-password' "$CASE_DIR/rejected.log"; then fail 'sensitive configuration leaked into command output'; fi
}
check_unchanged() { [ "$(state)" = "$1" ] || fail "$2"; }
init() { tool init > "$CASE_DIR/init.log" 2>&1 || { cat "$CASE_DIR/init.log" >&2; fail 'init'; }; }

fixture library
CONFIG=caller-config ROOT=caller-root TMP=caller-temp
export CONFIG ROOT TMP
SB_CONFIG_PARTS_TOOL=/does/not/exist
export SB_CONFIG_PARTS_TOOL
. "$LIB"
[ "$CONFIG/$ROOT/$TMP" = caller-config/caller-root/caller-temp ] || fail 'library changed caller variables'
[ "$(sb_parts_dir)" = "$PARTS" ] || fail '.json companion path'
[ "$(SH_SINGBOX_CONFIG="$CASE_DIR/plain.conf" sb_parts_dir)" = "$CASE_DIR/plain.conf.d" ] || fail 'non-JSON companion path'
sb_parts_prepare || fail 'legacy prepare required a deployed tool'
if sb_parts_active; then fail 'legacy considered active'; fi
ln -s "$CASE_DIR/missing-directory" "$PARTS"
sb_parts_active || fail 'broken parts symlink fell back to legacy'
rm "$PARTS"
unset SB_CONFIG_PARTS_TOOL CONFIG ROOT TMP
pass 'functions-only library, legacy no-op and reserved companion paths'

fixture lossless
cp "$SH_SINGBOX_CONFIG" "$CASE_DIR/original.json"
init
cmp -s "$CASE_DIR/original.json" "$SH_SINGBOX_CONFIG" || fail 'init changed original runtime bytes'
equal_json "$CASE_DIR/original.json" "$SH_SINGBOX_CONFIG" || fail 'lossless init'
jq -e --slurpfile full "$CASE_DIR/original.json" '.route.rules==$full[0].route.rules[3:5]' "$PARTS/routing.json" >/dev/null || fail 'scoped private rules or order changed'
jq -e --slurpfile full "$CASE_DIR/original.json" '.inbounds==$full[0].inbounds' "$PARTS/inbounds.json" >/dev/null || fail 'custom inbound parameters changed'
[ "$(stat -c %a "$PARTS")" = 700 ] || fail 'parts directory not private'
for file in "$PARTS/"*.json; do [ "$(stat -c %a "$file")" = 600 ] || fail 'source file not private'; done
[ "$(wc -l < "$PREFLIGHT_LOG")" -eq 1 ] || fail 'init did not use isolated staged preflight'
before=$(state)
TEST_FAIL_PREFLIGHT=1 tool render > "$CASE_DIR/no-op.log" 2>&1 || fail 'identical render unnecessarily preflighted repairable current config'
check_unchanged "$before" 'no-op render changed generation or runtime'
reject init
check_unchanged "$before" 'repeat init changed active sources'
pass 'lossless split, scoped private routes, private modes and no-op render'

jq '.inbounds[1].listen_port=17891' "$SH_SINGBOX_CONFIG" > "$CASE_DIR/candidate.json"
expected=$(tool fingerprint)
SB_CONFIG_PARTS_EXPECTED="$expected" tool commit "$CASE_DIR/candidate.json" inbounds > "$CASE_DIR/commit.log" 2>&1 || fail 'named inbounds commit'
jq -e '.inbounds[1].listen_port==17891 and .inbounds[1].tcp_fast_open==true' "$PARTS/inbounds.json" >/dev/null || fail 'inbound source was not updated'
tool render > "$CASE_DIR/render.log" 2>&1
equal_json "$CASE_DIR/candidate.json" "$SH_SINGBOX_CONFIG" || fail 'committed edit did not survive render'
before=$(state)
SB_CONFIG_PARTS_EXPECTED="$expected" reject commit "$CASE_DIR/candidate.json" inbounds
check_unchanged "$before" 'stale expected fingerprint overwrote a newer commit'
SB_CONFIG_PARTS_EXPECTED=bad reject set inbounds "$PARTS/inbounds.json"
check_unchanged "$before" 'malformed fingerprint changed sources'
jq '.inbounds[1].listen_port=17892 | .outbounds[-1].server_port=9999' "$SH_SINGBOX_CONFIG" > "$CASE_DIR/wrong-section.json"
reject commit "$CASE_DIR/wrong-section.json" inbounds
check_unchanged "$before" 'unnamed section change escaped commit contract'
pass 'named section commits, rebuild persistence and expected-fingerprint lost-update guard'

reject_fragment() {
    local section=$1 expression=$2
    jq "$expression" "$PARTS/$section.json" > "$CASE_DIR/fragment.json"
    reject set "$section" "$CASE_DIR/fragment.json"
    check_unchanged "$before" 'invalid fragment changed sources or generated JSON'
}
reject_fragment inbounds '.dns={}'
reject_fragment settings '.route={rules:[]}'
reject_fragment providers '.providers += [.providers[0]]'
reject_fragment outbounds '.outbounds += [.outbounds[0]]'
reject_fragment inbounds '.inbounds += [.inbounds[1]]'
reject_fragment outbounds '(.outbounds[] | select(.tag=="proxy").providers)=["missing-provider"]'
reject_fragment outbounds '(.outbounds[] | select(.tag=="proxy").outbounds)=["missing-node"]'
reject_fragment outbounds '(.outbounds[] | select(.tag=="ai")) += {outbounds:["ai"],default:"ai"}'
reject_fragment outbounds '(.outbounds[] | select(.tag=="proxy")) += {outbounds:["direct"],default:"direct"}'
reject_fragment outbounds '(.outbounds[] | select(.tag=="proxy")) += {outbounds:["nested"],default:"nested"} | .outbounds += [{type:"selector",tag:"nested",outbounds:["direct"],default:"direct"}]'
reject_fragment outbounds '(.outbounds[] | select(.tag=="proxy")) += {outbounds:[],default:""}'
reject_fragment outbounds '(.outbounds[] | select(.tag=="proxy").default)="xboard/dynamic-node"'
reject_fragment outbounds '.outbounds += [{type:"direct",tag:"Compatible"}]'
reject_fragment routing '.route.rules=[{domain_suffix:["example.invalid"],outbound:"proxy"}]'
reject_fragment routing '.route.rules=[{ip_cidr:["10.9.0.0/16"],action:"reject",outbound:"proxy"}]'
reject_fragment routing '.route.rules[0].outbound="missing-node"'
pass 'wrapper ownership, tags, references, cycles, selector safety and scoped-route restrictions'

fixture pending
init
cp "$SH_SINGBOX_CONFIG" "$CASE_DIR/runtime-before.json"
jq '(.outbounds[]|select(.tag=="office-node").server_port)=11080' "$PARTS/outbounds.json" > "$CASE_DIR/draft.json"
cp "$CASE_DIR/draft.json" "$PARTS/outbounds.json"
before=$(state)
checks=$(wc -l < "$PREFLIGHT_LOG")
tool build "$CASE_DIR/built.json" > "$CASE_DIR/build.log" 2>&1
[ "$(wc -l < "$PREFLIGHT_LOG")" -eq "$checks" ] || fail 'build invoked old core preflight'
check_unchanged "$before" 'build published source/runtime metadata'
jq -e 'any(.outbounds[];.tag=="office-node" and .server_port==11080)' "$CASE_DIR/built.json" >/dev/null || fail 'build used stale generated output'
TEST_FAIL_PREFLIGHT=1 reject render
check_unchanged "$before" 'failed preflight changed pending sources or old output'
[ "$(stat -c %a "$SH_SINGBOX_HOME/runtime/config-parts-last-error.log")" = 600 ] || fail 'diagnostics not private'
tool render > "$CASE_DIR/render.log" 2>&1
equal_json "$CASE_DIR/built.json" "$SH_SINGBOX_CONFIG" || fail 'pending sources were not applied'
cp "$PARTS/inbounds.json" "$CASE_DIR/inbounds-before.json"
jq '.dns.independent_cache = (.dns.independent_cache|not)' "$SH_SINGBOX_HOME/config/config.template.json" > "$CASE_DIR/policy.json"
cp "$CASE_DIR/policy.json" "$SH_SINGBOX_HOME/config/config.template.json"
tool render > "$CASE_DIR/policy-render.log" 2>&1
jq -e --slurpfile policy "$CASE_DIR/policy.json" '.dns==$policy[0].dns' "$SH_SINGBOX_CONFIG" >/dev/null || fail 'managed DNS policy was not refreshed'
cmp -s "$CASE_DIR/inbounds-before.json" "$PARTS/inbounds.json" || fail 'policy render rewrote user source'
pass 'pending-source build, failed validation retention and project policy refresh'

fixture manual
init
jq '.inbounds[1].listen_port=18901' "$SH_SINGBOX_CONFIG" > "$CASE_DIR/manual.json"
cp "$CASE_DIR/manual.json" "$SH_SINGBOX_CONFIG"
before=$(state)
reject render
reject build "$CASE_DIR/built.json"
check_unchanged "$before" 'manual output was overwritten silently'
TEST_FAIL_PREFLIGHT=1 reject import "$SH_SINGBOX_CONFIG"
check_unchanged "$before" 'identical manual-output import bypassed core/device checks'
tool import "$SH_SINGBOX_CONFIG" > "$CASE_DIR/import.log" 2>&1
jq -e '.inbounds[1].listen_port==18901' "$PARTS/inbounds.json" >/dev/null || fail 'valid manual edit was not adopted into sources'
tool render > "$CASE_DIR/render.log" 2>&1
jq -e '.inbounds[1].listen_port==18901' "$SH_SINGBOX_CONFIG" >/dev/null || fail 'adopted manual edit was lost'
pass 'manual generated edit protection and explicit, always-validated import'

fixture symlinks
mkdir "$CASE_DIR/external"
mv "$SH_SINGBOX_CONFIG" "$CASE_DIR/external/runtime.json"
ln -s "$CASE_DIR/external/runtime.json" "$SH_SINGBOX_CONFIG"
init
jq '.inbounds[1].listen_port=18902' "$SH_SINGBOX_CONFIG" > "$CASE_DIR/candidate.json"
tool commit "$CASE_DIR/candidate.json" inbounds > "$CASE_DIR/commit.log" 2>&1
[ -L "$SH_SINGBOX_CONFIG" ] || fail 'commit replaced runtime symlink'
equal_json "$CASE_DIR/candidate.json" "$CASE_DIR/external/runtime.json" || fail 'commit did not write actual runtime target'
rm "$CASE_DIR/external/runtime.json"
tool render > "$CASE_DIR/rebuild.log" 2>&1
[ -L "$SH_SINGBOX_CONFIG" ] && [ -f "$CASE_DIR/external/runtime.json" ] || fail 'missing symlink target was not rebuilt'
mv "$PARTS/providers.json" "$CASE_DIR/external/providers.json"
ln -s "$CASE_DIR/external/providers.json" "$PARTS/providers.json"
before=$(state)
reject build "$CASE_DIR/external/providers.json"
reject build "$PARTS/providers.json"
reject build "$SH_SINGBOX_CONFIG"
reject build "$SH_SINGBOX_HOME/config/config.template.json"
check_unchanged "$before" 'build overwrote source/runtime through an alias'
pass 'external runtime symlink, missing-output rebuild and source-alias write protection'

fixture migration
cp "$SH_SINGBOX_CONFIG" "$CASE_DIR/original.json"
jq '.dns.independent_cache = (.dns.independent_cache|not)' "$CASE_DIR/original.json" > "$CASE_DIR/custom-dns.json"
reject init "$CASE_DIR/custom-dns.json"
[ ! -e "$PARTS" ] || fail 'unsafe DNS migration created active parts'
cmp -s "$SH_SINGBOX_CONFIG" "$CASE_DIR/original.json" || fail 'unsafe migration replaced legacy JSON'
jq '.route.rules = (.route.rules[:3] + .route.rules[5:] + .route.rules[3:5])' "$CASE_DIR/original.json" > "$CASE_DIR/custom-order.json"
reject init "$CASE_DIR/custom-order.json"
[ ! -e "$PARTS" ] || fail 'unsafe rule order migration created active parts'
init
printf '{bad-json\n' > "$PARTS/inbounds.json"
before=$(state)
reject render
check_unchanged "$before" 'malformed active source changed old runtime'
tool disable > "$CASE_DIR/disable.log" 2>&1
[ ! -e "$PARTS" ] && [ ! -L "$PARTS" ] || fail 'disable did not leave legacy mode'
cmp -s "$SH_SINGBOX_CONFIG" "$CASE_DIR/original.json" || fail 'disable rewrote valid full JSON'
mkdir "$PARTS"
reject render
cmp -s "$SH_SINGBOX_CONFIG" "$CASE_DIR/original.json" || fail 'missing marker fell back to writing generated output'
pass 'conservative migration, malformed-source fail-closed and explicit legacy escape'

fixture rollback
init
before=$(state)
jq '.inbounds[1].listen_port=18903' "$SH_SINGBOX_CONFIG" > "$CASE_DIR/candidate.json"
: > "$CASE_DIR/fail-once"
TEST_FAIL_MV_ONCE="$CASE_DIR/fail-once" TEST_FAIL_MV_PATH="$PARTS/layout.json" reject commit "$CASE_DIR/candidate.json" inbounds
[ ! -e "$CASE_DIR/fail-once" ] || fail 'publication failure injection did not run'
check_unchanged "$before" 'transaction did not roll back source, runtime and layout together'
[ ! -e "$PARTS/.transaction" ] || fail 'successful rollback left a blocking transaction marker'
for backup in "$PARTS".backup.*; do [ "$(stat -c %a "$backup")" = 700 ] || fail 'transaction backup directory not private'; done
pass 'publication failure rolls back generated JSON, selected source and metadata'

fixture concurrency
init
cp "$SH_SINGBOX_CONFIG" "$CASE_DIR/runtime-before.json"
jq '(.outbounds[]|select(.tag=="office-node").server_port)=12080' "$PARTS/outbounds.json" > "$CASE_DIR/outbound-draft.json"
: > "$CASE_DIR/hold-preflight"
TEST_PREFLIGHT_WAIT="$CASE_DIR/hold-preflight" TEST_PREFLIGHT_READY="$CASE_DIR/preflight-ready" tool set outbounds "$CASE_DIR/outbound-draft.json" > "$CASE_DIR/concurrent.log" 2>&1 &
CHILD_PID=$!
for attempt in {1..100}; do [ ! -e "$CASE_DIR/preflight-ready" ] || break; sleep 0.05; done
[ -e "$CASE_DIR/preflight-ready" ] || fail 'preflight did not reach concurrency checkpoint'
( tool fingerprint > "$CASE_DIR/queued-fingerprint" && : > "$CASE_DIR/second-finished" ) &
SECOND_PID=$!
sleep 0.2
[ ! -e "$CASE_DIR/second-finished" ] || fail 'second command bypassed transaction lock'
jq '.inbounds[1].listen_port=19901' "$PARTS/inbounds.json" > "$CASE_DIR/concurrent-edit.json"
cp "$CASE_DIR/concurrent-edit.json" "$PARTS/inbounds.json"
rm "$CASE_DIR/hold-preflight"
if wait "$CHILD_PID"; then fail 'concurrent source mutation was overwritten'; fi
CHILD_PID=
wait "$SECOND_PID" || fail 'queued command did not acquire released lock'
SECOND_PID=
cmp -s "$CASE_DIR/runtime-before.json" "$SH_SINGBOX_CONFIG" || fail 'concurrent validation published stale generated config'
cmp -s "$CASE_DIR/concurrent-edit.json" "$PARTS/inbounds.json" || fail 'concurrent editor change was lost'
[ ! -e "$PARTS.lock" ] || fail 'completed command leaked lock'
pass 'writer serialization and concurrent source edit detection before publication'

fixture busybox-hash
mkdir "$CASE_DIR/applet-path"
for command_name in bash dirname readlink jq mktemp chmod mkdir date cp mv rm rmdir sleep stat; do
    ln -s "$(command -v "$command_name")" "$CASE_DIR/applet-path/$command_name"
done
cat > "$CASE_DIR/applet-path/busybox" <<'SH'
#!/bin/sh
[ "$1" = sha256sum ] || exit 64
shift
exec "$REAL_SHA256" "$@"
SH
chmod 0755 "$CASE_DIR/applet-path/busybox"
PATH="$CASE_DIR/applet-path" tool init > "$CASE_DIR/applet.log" 2>&1 || { cat "$CASE_DIR/applet.log" >&2; fail 'BusyBox-only SHA-256 applet unavailable'; }
PATH="$CASE_DIR/applet-path" tool render > "$CASE_DIR/applet-render.log" 2>&1 || fail 'SHA-256 fallback was not used for all stream hashes'
rm "$CASE_DIR/applet-path/busybox"
PATH="$CASE_DIR/applet-path" reject fingerprint
pass 'BusyBox SHA-256 applet fallback and explicit missing-hash error'

printf 'All configuration-parts behavior tests passed (mock core/device preflight).\n'
