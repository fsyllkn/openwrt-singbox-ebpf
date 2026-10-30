#!/usr/bin/env bash
# Real route-manager + central composer, with only core/service checks mocked.
# No network, firewall, eBPF or actual service operation is performed.
set -euo pipefail
umask 077
BASE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d /tmp/sb-route-manager.XXXXXX)
CHILD_PID=
cleanup() { [ -z "$CHILD_PID" ] || kill "$CHILD_PID" 2>/dev/null || :; rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
MANAGER=$BASE/scripts/route-manager.sh
PARTS_TOOL=$BASE/scripts/config-parts.sh
REAL_MV=$(command -v mv)
export REAL_MV

fixture() {
    CASE_DIR=$TEST_ROOT/$1
    SH_SINGBOX_HOME=$CASE_DIR/service\ home
    SH_SINGBOX_CONFIG=$CASE_DIR/live\ config.json
    PARTS=${SH_SINGBOX_CONFIG%.json}.d
    CALL_LOG=$CASE_DIR/sbctl-calls
    SB_CONFIG_PARTS_TOOL=$CASE_DIR/old-checkout-composer.sh
    PARTS_SELECTOR_HIT=$CASE_DIR/foreign-composer-called
    export SH_SINGBOX_HOME SH_SINGBOX_CONFIG CALL_LOG SB_CONFIG_PARTS_TOOL PARTS_SELECTOR_HIT
    unset SB_CONFIG_PARTS_EXPECTED TEST_FAIL_PREFLIGHT
    mkdir -p "$SH_SINGBOX_HOME/config" "$SH_SINGBOX_HOME/scripts" "$SH_SINGBOX_HOME/runtime"
    cat > "$SB_CONFIG_PARTS_TOOL" <<'SH'
#!/bin/sh
: > "$PARTS_SELECTOR_HIT"
exit 97
SH
    cp "$BASE/config/config.template.json" "$SH_SINGBOX_HOME/config/config.template.json"
    printf -v ODD_GROUP 'remote;$(touch %s)' "$CASE_DIR/should-not-exist"
    jq --arg odd "$ODD_GROUP" '
      .outbounds += [
        {type:"socks",tag:"private-node",server:"203.0.113.20",server_port:1080,username:"fixture-login",password:"fixture-node-secret"},
        {type:"selector",tag:"remote-office",outbounds:["private-node"],default:"private-node"},
        {type:"selector",tag:"remote-home",outbounds:["private-node"],default:"private-node"},
        {type:"urltest",tag:"latency-pool",outbounds:["private-node"]},
        {type:"loadbalance",tag:$odd,outbounds:["private-node"]}
      ]
      | .providers += [{type:"remote",tag:"fixture-subscription",url:"https://fixture-subscription-secret.invalid/private",http_client:{headers:{"User-Agent":"fixture"}}}]
      | .route.rules=(.route.rules[:3]+[
        {type:"default",source_ip_cidr:["10.1.0.0/16"],ip_cidr:"10.77.0.0/24",inbound:["lan-mixed"],
         process_name:["fixture-client"],domain_suffix:["internal.example"],port_range:["8000:9000"],network:"tcp",action:"route",outbound:"remote-office"}
      ]+.route.rules[3:])
    ' "$BASE/config/config.template.json" > "$SH_SINGBOX_CONFIG"
    cat > "$SH_SINGBOX_HOME/scripts/sbctl" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$1" >> "$CALL_LOG"
case "$1" in
  preflight)
    [ "${TEST_FAIL_PREFLIGHT:-0}" != 1 ] || exit 31
    jq -e 'type=="object" and (.route.rules|type=="array")' "$SH_SINGBOX_CONFIG" >/dev/null ;;
  restart) : ;;
  *) exit 32 ;;
esac
SH
    chmod 0755 "$SH_SINGBOX_HOME/scripts/sbctl"
    : > "$CALL_LOG"
}
manager() { bash "$MANAGER" "$@"; }
init() { bash "$PARTS_TOOL" init > "$CASE_DIR/init.log" 2>&1 || { cat "$CASE_DIR/init.log" >&2; fail init; }; }
state() {
    local name
    for name in "$SH_SINGBOX_CONFIG" "$PARTS/layout.json" "$PARTS/inbounds.json" "$PARTS/outbounds.json" "$PARTS/providers.json" "$PARTS/routing.json" "$PARTS/settings.json"; do
        if [ -f "$name" ]; then sha256sum "$name"; else printf 'missing %s\n' "$name"; fi
    done | sha256sum
}
unchanged() { [ "$(state)" = "$1" ] || fail "$2"; }
no_secrets() {
    if grep -Eq 'fixture-node-secret|fixture-subscription-secret|fixture-login' "$1"; then fail 'node/subscription credentials appeared in output'; fi
}
reject() {
    if manager "$@" > "$CASE_DIR/rejected.log" 2>&1; then fail "unexpected success: $*"; fi
    no_secrets "$CASE_DIR/rejected.log"
}
menu_input() { printf '%s' "$1" | manager menu > "$CASE_DIR/menu.log" 2>&1; }

fixture legacy
before=$(state)
reject list
reject groups
reject add --destination 10.9.0.1 --group proxy
grep -q 'split-config' "$CASE_DIR/rejected.log" || fail 'legacy mode gave no migration guidance'
unchanged "$before" 'legacy operation modified the full JSON'
[ ! -e "$PARTS" ] || fail 'legacy operation silently initialized parts'
pass 'legacy mode gives explicit migration guidance and preserves full JSON'

fixture read-only
init
before=$(state)
checks=$(wc -l < "$CALL_LOG")
manager list > "$CASE_DIR/list.log"
manager groups > "$CASE_DIR/groups.log"
manager --help > "$CASE_DIR/help.log"
grep -q 'remote-office' "$CASE_DIR/groups.log" || fail 'dynamic office group missing'
grep -q 'remote-home' "$CASE_DIR/groups.log" || fail 'dynamic home group missing'
grep -q '\[urltest\]' "$CASE_DIR/groups.log" || fail 'urltest groups missing'
grep -q '\[loadbalance\]' "$CASE_DIR/groups.log" || fail 'loadbalance groups missing'
if grep -q 'private-node' "$CASE_DIR/groups.log"; then fail 'node details leaked into group listing'; fi
no_secrets "$CASE_DIR/groups.log"
no_secrets "$CASE_DIR/list.log"
[ "$(wc -l < "$CALL_LOG")" -eq "$checks" ] || fail 'read operation preflighted or restarted'
unchanged "$before" 'read operation generated configuration'
pass 'read-only lists derive actual group tags/types without node or subscription data'

cp "$PARTS/routing.json" "$CASE_DIR/original-routing.json"
SB_CONFIG_PARTS_TOOL="$CASE_DIR/removed-checkout/config-parts.sh" \
    manager add --source 10.23.40.12 --destination 10.88.60.10 --group remote-office --port 14432 --network tcp --protocol tls > "$CASE_DIR/add.log"
jq -e '.route.rules[1]=={action:"route",source_ip_cidr:["10.23.40.12/32"],ip_cidr:["10.88.60.10/32"],outbound:"remote-office",port:[14432],network:["tcp"],protocol:["tls"]}' "$PARTS/routing.json" >/dev/null || fail 'new rule normalization or native field structure'
manager edit 2 --group remote-home --port 443,8443 > "$CASE_DIR/edit.log"
jq -e '.route.rules[1].outbound=="remote-home" and .route.rules[1].port==[443,8443] and .route.rules[1].protocol==["tls"]' "$PARTS/routing.json" >/dev/null || fail 'edit changed unspecified fields'
manager edit 1 --group remote-home > "$CASE_DIR/edit-advanced.log"
jq -e --slurpfile original "$CASE_DIR/original-routing.json" '(.route.rules[0]|del(.outbound))==($original[0].route.rules[0]|del(.outbound))' "$PARTS/routing.json" >/dev/null || fail 'advanced qualifiers or scalar CIDR were rewritten'
manager move 2 1 > "$CASE_DIR/move.log"
jq -e '.route.rules[0].port==[443,8443] and .route.rules[1].port_range==["8000:9000"]' "$PARTS/routing.json" >/dev/null || fail 'move did not use final 1-based index'
manager remove 2 > "$CASE_DIR/remove.log"
manager edit 1 --clear-port --clear-protocol > "$CASE_DIR/clear.log"
jq -e '(.route.rules|length)==1 and (.route.rules[0]|has("port")|not) and (.route.rules[0]|has("protocol")|not)' "$PARTS/routing.json" >/dev/null || fail 'clear did not remove only selected fields'
manager add --destination 192.0.2.1 --group "$ODD_GROUP" --position 1 > "$CASE_DIR/odd.log"
jq -e --arg tag "$ODD_GROUP" '.route.rules[0].outbound==$tag' "$PARTS/routing.json" >/dev/null || fail 'group shell metacharacters were not treated as data'
[ ! -e "$CASE_DIR/should-not-exist" ] || fail 'group tag executed shell text'
if grep -q '^restart$' "$CALL_LOG"; then fail 'saving route implicitly restarted'; fi
jq -e --slurpfile template "$SH_SINGBOX_HOME/config/config.template.json" --slurpfile fragment "$PARTS/routing.json" '
 .dns==$template[0].dns and (.route|del(.rules))==($template[0].route|del(.rules))
 and .route.rules==($template[0].route.rules[:3]+$fragment[0].route.rules+$template[0].route.rules[3:])' "$SH_SINGBOX_CONFIG" >/dev/null || fail 'route manager changed fixed DNS/route policy'
pass 'native add/edit/move/remove, bare IPv4 normalization, advanced qualifiers and dynamic group data'

fixture address-validation
init
manager add --source '2001:db8::1,::ffff:192.0.2.7/128' --destination '10.0.0.0/8,192.000.002.001' --group remote-office > "$CASE_DIR/ipv6.log"
jq -e '.route.rules[1].source_ip_cidr==["2001:db8::1/128","::ffff:192.0.2.7/128"] and .route.rules[1].ip_cidr==["10.0.0.0/8","192.0.2.1/32"]' "$PARTS/routing.json" >/dev/null || fail 'IPv6/CIDR/decimal IPv4 normalization'
before=$(state)
for invalid in 256.1.2.3 1.2.3 1.2.3.4/33 1.2.3.4/-1 '2001:db8::1:' '1:2:3:4:5:6:7:8::' '::1/129' '::ffff:999.0.0.1' '10.0.0.1,'; do
    reject add --destination "$invalid" --group remote-office
    unchanged "$before" 'invalid IP input changed config'
done
reject add --destination '1.2.3.4;$(touch bad)' --group remote-office
reject add --destination $'10.1.1.1\n10.2.2.2' --group remote-office
reject add --destination 1.2.3.4 --port $'443\r,80' --group remote-office
reject add --destination 1.2.3.4 --port '1$(touch bad)' --group remote-office
reject add --destination 1.2.3.4 --network 'tcp;bad' --group remote-office
reject add --destination 1.2.3.4 --port 65536 --group remote-office
reject add --destination 1.2.3.4 --group private-node
reject add --destination 1.2.3.4 --group direct
reject add --group remote-office
reject edit 2 --clear-source --clear-destination
reject edit 2 --port 443 --clear-port
reject move 0 1
unchanged "$before" 'invalid fields, scope or indexes changed config'
pass 'IPv4/IPv6 validation, numeric input safety, explicit IP scope and valid group restriction'

fixture repair
init
jq '.route.rules[0].outbound="removed-group"' "$PARTS/routing.json" > "$CASE_DIR/bad-reference.json"
cp "$CASE_DIR/bad-reference.json" "$PARTS/routing.json"
checks=$(wc -l < "$CALL_LOG")
manager list > "$CASE_DIR/bad-reference-list.log"
[ "$(wc -l < "$CALL_LOG")" -eq "$checks" ] || fail 'list tried to render invalid pending reference'
manager edit 1 --group remote-home > "$CASE_DIR/repair.log"
jq -e '.route.rules[0].outbound=="remote-home"' "$PARTS/routing.json" >/dev/null || fail 'bad pending reference could not be edited'
jq '.route.rules[0].outbound="removed-group"' "$PARTS/routing.json" > "$CASE_DIR/bad-reference.json"
cp "$CASE_DIR/bad-reference.json" "$PARTS/routing.json"
manager remove 1 > "$CASE_DIR/repair-remove.log"
jq -e '.route.rules==[]' "$PARTS/routing.json" >/dev/null || fail 'bad pending reference could not be removed'
pass 'invalid pending route references remain readable and repairable without pre-render'

fixture failed-validation
init
before=$(state)
TEST_FAIL_PREFLIGHT=1 reject add --destination 10.9.0.1 --group remote-office
unchanged "$before" 'failed core/device validation changed sources/runtime'
grep -q 'route-edit\.' "$CASE_DIR/rejected.log" || fail 'failed draft could not be located'
draft_count=0
for directory in "$PARTS".route-edit.*; do
    [ -d "$directory" ] || continue
    draft_count=$((draft_count+1))
    [ "$(stat -c %a "$directory")" = 700 ] || fail 'draft directory permissions'
    for file in "$directory/"*; do [ "$(stat -c %a "$file")" = 600 ] || fail 'draft file permissions'; done
done
[ "$draft_count" -eq 1 ] || fail 'failed draft was deleted or duplicated'
expected=$(bash "$PARTS_TOOL" fingerprint)
manager add --destination 10.9.0.1 --group remote-office > "$CASE_DIR/add.log"
before=$(state)
SB_CONFIG_PARTS_EXPECTED="$expected" reject remove 1
unchanged "$before" 'stale caller index overwrote newer source'
pass 'failed validation retains private drafts and old runtime; stale expected fingerprint is rejected'

fixture staging-failure
init
mkdir "$CASE_DIR/tools"
cat > "$CASE_DIR/tools/mv" <<'SH'
#!/bin/sh
last=
for argument do last=$argument; done
case "$last" in
  *.route-edit.*/patch.json) : > "$TEST_PATCH_FAILURE_REACHED"; exit 74 ;;
esac
exec "$REAL_MV" "$@"
SH
chmod 0755 "$CASE_DIR/tools/mv"
before=$(state)
checks=$(wc -l < "$CALL_LOG")
TEST_PATCH_FAILURE_REACHED="$CASE_DIR/failure-reached" PATH="$CASE_DIR/tools:$PATH" \
    menu_input $'3\n1\n10.9.0.7\n\n\n\n\n4\n\n0\n'
[ -e "$CASE_DIR/failure-reached" ] || fail 'staging failure injection did not run'
unchanged "$before" 'conditional menu function saved a partially written patch after mv failure'
[ "$(wc -l < "$CALL_LOG")" -eq "$checks" ] || fail 'staging failure reached preflight/save'
grep -q '无法保存字段草稿' "$CASE_DIR/menu.log" || fail 'staging failure did not give an explicit error'
pass 'interactive staging failures abort before any partial request reaches central publication'

fixture confirmations
init
before=$(state)
if menu_input $'q\n'; then fail 'q did not propagate exit'; else result=$?; fi
[ "$result" -eq 2 ] || fail 'q did not propagate exit 2'
unchanged "$before" 'q changed routing'
menu_input $'4\n1\nn\n0\n'
unchanged "$before" 'n confirmation deleted rule'
menu_input $'4\n1\nunexpected\n0\n'
unchanged "$before" 'unexpected confirmation deleted rule'
if menu_input $'4\n1\n'; then fail 'EOF at confirmation was accepted'; else result=$?; fi
[ "$result" -eq 2 ] || fail 'EOF did not propagate exit 2'
unchanged "$before" 'EOF deleted rule'
menu_input $'4\n1\n\n0\n'
jq -e '.route.rules==[]' "$PARTS/routing.json" >/dev/null || fail 'successful Enter confirmation did not delete'
menu_input $'2\n10.8.0.7\n10.9.0.0/24\n443\ntcp\ntls\n4\n\n\n0\n'
jq -e '.route.rules[0].outbound=="remote-home" and .route.rules[0].source_ip_cidr==["10.8.0.7/32"]' "$PARTS/routing.json" >/dev/null || fail 'interactive add did not use displayed dynamic group index'
no_secrets "$CASE_DIR/menu.log"
if grep -q '^restart$' "$CALL_LOG"; then fail 'interactive save restarted service'; fi
: > "$CALL_LOG"
menu_input $'7\n\n0\n'
[ "$(cat "$CALL_LOG")" = $'preflight\nrestart' ] || fail 'explicit apply did not preflight before restart'
: > "$CALL_LOG"
TEST_FAIL_PREFLIGHT=1 menu_input $'7\n\n0\n'
[ "$(cat "$CALL_LOG")" = preflight ] || fail 'failed preflight still invoked restart'
pass 'interactive Enter/n/EOF semantics, dynamic numbered groups and separate validated restart'

fixture prompt-race
init
mkfifo "$CASE_DIR/input"
manager menu < "$CASE_DIR/input" > "$CASE_DIR/race.log" 2>&1 &
CHILD_PID=$!
exec 3> "$CASE_DIR/input"
printf '4\n' >&3
for attempt in {1..100}; do grep -q '规则编号:' "$CASE_DIR/race.log" && break; sleep 0.05; done
grep -q '规则编号:' "$CASE_DIR/race.log" || fail 'interactive edit never displayed snapshot indexes'
jq '.route.rules=[{ip_cidr:["10.200.0.1/32"],action:"route",outbound:"remote-home"}]+.route.rules' "$PARTS/routing.json" > "$CASE_DIR/newer-routing.json"
cp "$CASE_DIR/newer-routing.json" "$PARTS/routing.json"
before=$(state)
printf '1\n\n0\n' >&3
exec 3>&-
wait "$CHILD_PID" || fail 'menu did not recover after rejected concurrent save'
CHILD_PID=
unchanged "$before" 'display-time stale index deleted another editor rule'
grep -q 'changed since editing began' "$CASE_DIR/race.log" || fail 'race was not rejected by central expected fingerprint'
no_secrets "$CASE_DIR/race.log"
pass 'snapshot fingerprint is captured before interactive indexes and held through confirmation'

for marker in "$TEST_ROOT"/*/foreign-composer-called; do
    [ ! -e "$marker" ] || fail 'route manager called an inherited foreign composer'
done
pass 'route manager binds its sibling composer despite stale/foreign selectors and preserves fingerprint guards'

printf 'All route-manager behavior tests passed (mock core/service; real composition).\n'
