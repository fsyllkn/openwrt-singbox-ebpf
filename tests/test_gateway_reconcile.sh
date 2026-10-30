#!/bin/bash
# All ip/nft/procfs interactions mocked; requires root but changes no real routes.
set -euo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd -P)"
[ "$(id -u)" -eq 0 ] || { echo "Run via sudo" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq missing" >&2; exit 1; }
TMP="$(mktemp -d /tmp/sb-gateway-mock.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/config" "$TMP/home/runtime" "$TMP/state"
printf '%s\n' '{"inbounds":[{"type":"tproxy","tag":"lan-tproxy","listen_port":1536}]}' > "$TMP/home/config/config.json"
printf '%s\n' '{"interface":"br-lan","source_cidr":"192.168.50.0/24"}' > "$TMP/home/runtime/gateway.json"
printf '0\n' > "$TMP/forward"
printf 'test-boot\n' > "$TMP/boot"
: > "$TMP/state/rules"
: > "$TMP/state/routes"
cat > "$TMP/bin/ip" <<'IP'
#!/bin/sh
set -eu
case "$*" in
 "-V") echo 'ip utility, iproute2-6.15.0';;
 "link show dev ${MOCK_INTERFACE:-br-lan}") echo "3: ${MOCK_INTERFACE:-br-lan}: <UP>";;
 "-4 -o addr show dev ${MOCK_INTERFACE:-br-lan} scope global")
   if [ -f "$MOCK_STATE/addresses" ]; then cat "$MOCK_STATE/addresses"
   else echo '3: br-lan inet 192.168.50.11/24 scope global'; fi;;
 "-4 route show default") echo 'default via 203.0.113.1 dev wan0';;
 "-4 rule show"|"-4 -N rule show") cat "$MOCK_STATE/rules";;
 "-4 route show table 53136")
   # Linux can reject a filtered dump when this FIB table does not exist.
   if [ ! -s "$MOCK_STATE/routes" ]; then
     echo 'Error: ipv4: FIB table does not exist.' >&2
     echo 'Dump terminated' >&2
     exit 2
   fi
   cat "$MOCK_STATE/routes";;
 "-4 -o -N route show table all")
   if [ -f "$MOCK_STATE/dump-failure" ]; then
     # Include partial output: an interrupted dump is not proof of absence.
     echo 'default via 192.168.50.1 dev br-lan'
     echo 'Dump terminated' >&2
     exit 2
   fi
   cat "$MOCK_STATE/other-routes"
   # -N prints RTN_LOCAL as 2 and table IDs numerically, even with aliases.
   awk '{ if ($1 == "local") $1 = "2"; print $0 " table 53136" }' "$MOCK_STATE/routes";;
 "-4 route add local 0.0.0.0/0 dev lo table 53136") echo 'local default dev lo scope host' > "$MOCK_STATE/routes";;
 "-4 route del local 0.0.0.0/0 dev lo table 53136") : > "$MOCK_STATE/routes";;
 "-4 rule add fwmark 0x1536 table 53136 priority 15360") echo '15360: from all fwmark 0x1536 lookup 53136' >> "$MOCK_STATE/rules";;
 "-4 rule del priority 15360 fwmark 0x1536 table 53136")
   grep -Ev '^15360:.*fwmark 0x0*1536(/0xffffffff)?[[:space:]].*lookup 53136([[:space:]]|$)' "$MOCK_STATE/rules" > "$MOCK_STATE/new" || true
   mv "$MOCK_STATE/new" "$MOCK_STATE/rules";;
 *) echo "Unmocked ip $*" >&2; exit 98;;
esac
IP
cat > "$TMP/bin/nft" <<'NFT'
#!/bin/sh
set -eu
case "$*" in
 "list table inet singbox_one_arm") [ -f "$MOCK_STATE/nft" ] || exit 1; cat "$MOCK_STATE/nft";;
 "delete table inet singbox_one_arm") rm -f "$MOCK_STATE/nft";;
 -c\ -f\ *) test "$(grep -c 'tproxy ip to :1536' "$3")" -eq 4;;
 -f\ *)
   cp "$2" "$MOCK_STATE/applied.nft"
   printf 'table inet singbox_one_arm {\n chain prerouting {\n' > "$MOCK_STATE/nft"
   grep '^add rule .*tproxy ip to :1536' "$2" | sed 's/^add rule .*prerouting / /' >> "$MOCK_STATE/nft"
   printf ' }\n}\n' >> "$MOCK_STATE/nft";;
 *) echo "Unmocked nft $*" >&2; exit 98;;
esac
NFT
chmod +x "$TMP/bin/ip" "$TMP/bin/nft"
export PATH="$TMP/bin:$PATH" MOCK_STATE="$TMP/state" SH_SINGBOX_HOME="$TMP/home"
export SH_SINGBOX_CONFIG="$TMP/home/config/config.json"
export SH_SINGBOX_IP_FORWARD_FILE="$TMP/forward" SH_SINGBOX_BOOT_ID_FILE="$TMP/boot"
[ "$(command -v ip)" = "$TMP/bin/ip" ]
[ "$(command -v nft)" = "$TMP/bin/nft" ]
gw() { bash "$BASE/scripts/gateway.sh" "$@"; }
rule_count() { grep -c '^15360:' "$TMP/state/rules" || true; }
reset() {
  : > "$TMP/state/rules"; : > "$TMP/state/routes"
  : > "$TMP/state/other-routes"
  rm -f "$TMP/state/dump-failure"
  rm -f "$TMP/state/nft" "$TMP/home/runtime/gateway-active" "$TMP/home/runtime/gateway-forward-owned"
  printf '0\n' > "$TMP/forward"
}
active() {
 [ "$(rule_count)" -eq 1 ] && [ -f "$TMP/state/nft" ] &&
 [ -f "$TMP/home/runtime/gateway-active" ] && grep -q 'local default' "$TMP/state/routes"
}
echo 'TEST external runtime config without a HOME/config directory'
mkdir -p "$TMP/external" "$TMP/alternate-home"
printf '%s\n' '{"inbounds":[{"type":"ebpf","local":{"enabled":true}}]}' > "$TMP/external/config.json"
SH_SINGBOX_HOME="$TMP/alternate-home" SH_SINGBOX_CONFIG="$TMP/external/config.json" \
  gw configure br-lan 192.168.50.0/24
jq -e 'any(.inbounds[]; .tag == "lan-tproxy")' "$TMP/external/config.json" >/dev/null
[ -f "$TMP/alternate-home/runtime/gateway.json" ] && [ ! -d "$TMP/alternate-home/config" ]
reset
SH_SINGBOX_HOME="$TMP/alternate-home" SH_SINGBOX_CONFIG="$TMP/external/config.json" gw disable
jq -e 'all(.inbounds[]; .tag != "lan-tproxy")' "$TMP/external/config.json" >/dev/null
[ ! -f "$TMP/alternate-home/runtime/gateway.json" ]
echo 'TEST configure and disable preserve an external configuration symlink'
mkdir -p "$TMP/linked-config" "$TMP/config-target"
printf '%s\n' '{"inbounds":[],"route":{"rules":[{"ip_cidr":["10.77.0.0/24"],"outbound":"remote-private"}]}}' > "$TMP/config-target/live.json"
cp "$TMP/config-target/live.json" "$TMP/linked-before.json"
ln -s "$TMP/config-target/live.json" "$TMP/linked-config/active.json"
SH_SINGBOX_HOME="$TMP/alternate-home" SH_SINGBOX_CONFIG="$TMP/linked-config/active.json" \
  gw configure br-lan 192.168.50.0/24
[ -L "$TMP/linked-config/active.json" ] && [ "$(readlink "$TMP/linked-config/active.json")" = "$TMP/config-target/live.json" ]
jq -e 'any(.inbounds[]; .tag == "lan-tproxy")' "$TMP/config-target/live.json" >/dev/null
set -- "$TMP/config-target/live.json".gateway.*.bak
[ "$#" -eq 1 ] && cmp "$TMP/linked-before.json" "$1"
SH_SINGBOX_HOME="$TMP/alternate-home" SH_SINGBOX_CONFIG="$TMP/linked-config/active.json" gw disable
[ -L "$TMP/linked-config/active.json" ] && [ "$(readlink "$TMP/linked-config/active.json")" = "$TMP/config-target/live.json" ]
jq -S . "$TMP/linked-before.json" > "$TMP/linked-before-sorted.json"
jq -S . "$TMP/config-target/live.json" > "$TMP/linked-after-sorted.json"
cmp "$TMP/linked-before-sorted.json" "$TMP/linked-after-sorted.json"
echo 'TEST incomplete helper deployment fails clearly'
mkdir -p "$TMP/standalone"
cp "$BASE/scripts/gateway.sh" "$TMP/standalone/gateway.sh"
if bash "$TMP/standalone/gateway.sh" requirements > "$TMP/error" 2>&1; then
  echo 'Missing runtime helper accepted' >&2; exit 1
fi
grep -q 'runtime-paths.sh is missing.*rerun install.sh' "$TMP/error"
reset
echo 'TEST first apply with a nonexistent FIB table'
if ip -4 route show table 53136 > "$TMP/error" 2>&1; then
  echo 'Mock must reproduce missing-table dump failure' >&2; exit 1
fi
grep -q 'Dump terminated' "$TMP/error"
gw apply > "$TMP/output" 2>&1
active
if grep -q 'Dump terminated' "$TMP/output"; then
  echo 'Missing-table error leaked from successful apply' >&2; exit 1
fi
echo 'TEST cleanup is repeatable after the final route disappears'
gw cleanup
gw cleanup
[ "$(rule_count)" -eq 0 ] && [ ! -s "$TMP/state/routes" ] && [ ! -f "$TMP/state/nft" ]
[ "$(cat "$TMP/forward")" = 0 ]
echo 'TEST unrelated tables do not count as gateway routes'
reset
printf '%s\n' \
  'default via 192.168.50.1 dev br-lan' \
  '2 127.0.0.1 dev lo table 255 scope 254' \
  'unreachable default table 531360' \
  '2 default dev lo table 153136 scope 254' > "$TMP/state/other-routes"
cp "$TMP/state/other-routes" "$TMP/other-routes.before"
gw apply
active
gw cleanup
cmp "$TMP/state/other-routes" "$TMP/other-routes.before"
echo 'TEST netlink dump failure aborts before creating any resources'
reset
: > "$TMP/state/dump-failure"
if gw apply > "$TMP/error" 2>&1; then echo 'Failed dump accepted' >&2; exit 1; fi
grep -q 'cannot inspect IPv4 routing table 53136' "$TMP/error"
[ "$(rule_count)" -eq 0 ] && [ ! -s "$TMP/state/routes" ] && [ ! -f "$TMP/state/nft" ]
[ ! -f "$TMP/home/runtime/gateway-active" ] && [ "$(cat "$TMP/forward")" = 0 ]
echo 'TEST netlink dump failure preserves active resources during cleanup'
reset
gw apply
: > "$TMP/state/dump-failure"
if gw cleanup > "$TMP/error" 2>&1; then echo 'Failed cleanup dump accepted' >&2; exit 1; fi
grep -q 'cannot inspect IPv4 routing table 53136' "$TMP/error"
active
[ "$(cat "$TMP/forward")" = 1 ] && [ -f "$TMP/home/runtime/gateway-forward-owned" ]
reset
echo 'TEST orphaned matching rule, no activation marker'
echo '15360: from all fwmark 0x1536 lookup 53136' > "$TMP/state/rules"
gw apply
active
echo 'TEST repeat apply idempotent'
gw apply
active
echo 'TEST lost marker plus active resources'
rm -f "$TMP/home/runtime/gateway-active"
gw apply
active
echo 'TEST cleanup with missing marker'
rm -f "$TMP/home/runtime/gateway-active"
gw cleanup
[ "$(rule_count)" -eq 0 ] && [ ! -s "$TMP/state/routes" ] && [ ! -f "$TMP/state/nft" ]
[ "$(cat "$TMP/forward")" = 0 ]
echo 'TEST foreign priority'
reset
echo '15360: from all fwmark 0x2222 lookup 12345' > "$TMP/state/rules"
if gw apply > "$TMP/error" 2>&1; then echo 'Unsafe foreign priority accepted' >&2; exit 1; fi
grep -q 'belongs to another policy' "$TMP/error"
grep -q 0x2222 "$TMP/state/rules"
[ ! -f "$TMP/state/nft" ] && [ ! -s "$TMP/state/routes" ]
echo 'TEST constrained or partly masked rules are foreign, even with our priority/table'
for rule in \
  '15360: from all fwmark 0x1536/0xff lookup 53136' \
  '15360: from all fwmark 0x15360 lookup 53136' \
  '15360: from 10.77.0.0/24 fwmark 0x1536 lookup 53136' \
  '15360: from all to 10.77.0.0/24 fwmark 0x1536 lookup 53136' \
  '15360: from all fwmark 0x1536 lookup 53136 suppress_prefixlength 0'; do
  reset
  printf '%s\n' "$rule" > "$TMP/state/rules"
  cp "$TMP/state/rules" "$TMP/rules.before"
  if gw cleanup > "$TMP/error" 2>&1; then echo 'Custom policy rule removed' >&2; exit 1; fi
  grep -q 'belongs to another policy' "$TMP/error"
  cmp "$TMP/state/rules" "$TMP/rules.before"
done
echo 'TEST full-mask owned rule remains recoverable'
reset
printf '%s\n' '15360: from all fwmark 0x00001536/0xffffffff lookup 53136 proto 3' > "$TMP/state/rules"
gw apply
active
echo 'TEST foreign route'
reset
echo 'unicast 1.1.1.0/24 dev br-lan' > "$TMP/state/routes"
if gw apply > "$TMP/error" 2>&1; then echo 'Unsafe foreign route accepted' >&2; exit 1; fi
grep -q 'foreign or unexpected route' "$TMP/error"
grep -q 1.1.1.0 "$TMP/state/routes"
echo 'TEST own route plus a foreign route is not safe to clean'
reset
printf '%s\n' 'local default dev lo scope host' 'unicast 1.1.1.0/24 dev br-lan' > "$TMP/state/routes"
cp "$TMP/state/routes" "$TMP/routes.before"
if gw cleanup > "$TMP/error" 2>&1; then echo 'Mixed route ownership accepted' >&2; exit 1; fi
grep -q 'foreign or unexpected route' "$TMP/error"
cmp "$TMP/state/routes" "$TMP/routes.before"
echo 'TEST foreign nft with stale marker'
reset
echo 'table inet singbox_one_arm { chain prerouting { } }' > "$TMP/state/nft"
: > "$TMP/home/runtime/gateway-active"
if gw cleanup > "$TMP/error" 2>&1; then echo 'Unsafe foreign nft deleted' >&2; exit 1; fi
grep -q 'does not match' "$TMP/error"
[ -f "$TMP/state/nft" ]
echo 'TEST another LAN interface preserves advanced routes and custom inbound options'
reset
export MOCK_INTERFACE=br-edge.42
printf '%s\n' '8: br-edge.42 inet 10.77.0.1/24 scope global br-edge.42' > "$TMP/state/addresses"
cat > "$TMP/home/config/config.json" <<'JSON'
{
  "inbounds": [
    {"type":"ebpf","tag":"local-custom","local":{"enabled":true,"bypass_private_address":false,"exclude_uid":[29002]},"shared":{"enabled":false,"interfaces":["other-lan"]}},
    {"type":"mixed","tag":"custom-proxy","listen":"127.0.0.1","listen_port":17891},
    {"type":"tproxy","tag":"lan-tproxy","listen":"::","listen_port":1536,"network":["tcp","udp"],"udp_timeout":"17m","tcp_fast_open":true}
  ],
  "route": {"rules":[
    {"ip_cidr":["10.77.0.0/24"],"action":"route","outbound":"remote-private"},
    {"ip_is_private":true,"action":"route","outbound":"direct"}
  ],"final":"remote-private"},
  "outbounds":[{"type":"socks","tag":"remote-private","server":"198.51.100.8","server_port":1080},{"type":"direct","tag":"direct"}]
}
JSON
jq -S . "$TMP/home/config/config.json" > "$TMP/config.before"
printf '%s\n' '{"interface":"br-lan","source_cidr":"192.168.50.0/24","operator_note":"preserve this metadata"}' > "$TMP/home/runtime/gateway.json"
gw configure br-edge.42 10.77.0.0/24
jq -S . "$TMP/home/config/config.json" > "$TMP/config.after"
cmp "$TMP/config.before" "$TMP/config.after"
jq -e '.operator_note == "preserve this metadata"' "$TMP/home/runtime/gateway.json" >/dev/null
gw apply
active
# The mock upstream default is on wan0, unlike the selected LAN. Verify the
# batch actually sent to nft cannot bypass the custom overlapping destination.
python3 - "$TMP/state/applied.nft" <<'PY'
import ipaddress, pathlib, sys
rules = pathlib.Path(sys.argv[1]).read_text().splitlines()
destination = ipaddress.ip_address('10.77.0.104')
for rule in rules:
    if not rule.startswith('add rule ') or ' counter return' not in rule or ' ip daddr ' not in rule:
        continue
    prefix = rule.split(' ip daddr ', 1)[1].split(' counter return', 1)[0]
    networks = prefix.replace('{', '').replace('}', '').replace(',', ' ').split()
    assert not any(destination in ipaddress.ip_network(network) for network in networks), rule
# Both limited and directed broadcasts must bypass TProxy before DNS hijack.
assert any('ip daddr 255.255.255.255 counter return' in rule for rule in rules)
bcast = [i for i, rule in enumerate(rules) if 'fib daddr type broadcast counter return' in rule]
assert len(bcast) == 1
first_dns = next(i for i, rule in enumerate(rules) if 'udp dport 53' in rule and 'tproxy' in rule)
assert bcast[0] < first_dns
assert any('fib daddr type local counter return' in rule for rule in rules)
assert any('127.0.0.0/8' in rule and 'counter return' in rule for rule in rules)
assert sum('tproxy ip to :1536' in rule for rule in rules) == 4
PY
jq -S . "$TMP/home/config/config.json" > "$TMP/config.after"
cmp "$TMP/config.before" "$TMP/config.after"
echo 'TEST narrower client ranges do not have to contain the router IP'
gw configure br-edge.42 10.77.0.128/25
gw apply
active
echo 'TEST stale source subnet aborts without changing existing settings or resources'
printf '%s\n' '8: br-edge.42 inet 10.23.40.45/23 scope global br-edge.42' > "$TMP/state/addresses"
cp "$TMP/home/runtime/gateway.json" "$TMP/gateway.before"
cp "$TMP/state/nft" "$TMP/nft.before"
cp "$TMP/state/routes" "$TMP/routes.before"
cp "$TMP/state/rules" "$TMP/rules.before"
for operation in apply 'configure br-edge.42 10.77.0.0/24'; do
  # Deliberate word splitting supplies the fixed operation fixture.
  if gw $operation > "$TMP/error" 2>&1; then echo 'Stale LAN subnet accepted' >&2; exit 1; fi
  grep -q 'does not overlap any IPv4 subnet' "$TMP/error"
  cmp "$TMP/home/runtime/gateway.json" "$TMP/gateway.before"
  cmp "$TMP/state/nft" "$TMP/nft.before"
  cmp "$TMP/state/routes" "$TMP/routes.before"
  cmp "$TMP/state/rules" "$TMP/rules.before"
  active
done
gw configure br-edge.42 10.23.41.0/24
gw apply
active
echo 'TEST LAN TProxy works when local eBPF is explicitly disabled or absent'
cp "$TMP/home/config/config.json" "$TMP/advanced-config.json"
for local_mode in disabled absent; do
  jq --arg mode "$local_mode" '
    .inbounds |= map(select(.tag != "lan-tproxy")
      | if .type == "ebpf" then
          if $mode == "absent" then empty else .local.enabled=false end
        else . end)
  ' "$TMP/advanced-config.json" > "$TMP/home/config/config.json"
  jq -S . "$TMP/home/config/config.json" > "$TMP/custom.before"
  gw configure br-edge.42 10.23.40.0/23
  jq -S '.inbounds |= map(select(.tag != "lan-tproxy"))' "$TMP/home/config/config.json" > "$TMP/custom.after"
  cmp "$TMP/custom.before" "$TMP/custom.after"
  gw apply > "$TMP/output" 2>&1
  active
  grep -q 'local interception settings preserved' "$TMP/output"
done
echo 'TEST enabled shared interception is rejected without deleting its options'
jq '.inbounds |= map(if .type == "ebpf" then .shared.enabled=true else . end)' \
  "$TMP/advanced-config.json" > "$TMP/home/config/config.json"
cp "$TMP/home/config/config.json" "$TMP/custom.before"
cp "$TMP/home/runtime/gateway.json" "$TMP/gateway.before"
for operation in apply 'configure br-edge.42 10.23.40.0/23'; do
  if gw $operation > "$TMP/error" 2>&1; then echo 'Overlapping interception accepted' >&2; exit 1; fi
  grep -q 'choose shared or the managed LAN TProxy mode explicitly' "$TMP/error"
  cmp "$TMP/home/config/config.json" "$TMP/custom.before"
  cmp "$TMP/home/runtime/gateway.json" "$TMP/gateway.before"
  active
done
echo 'TEST conflicting or duplicate managed tags preserve all custom JSON'
for conflict in type port duplicate; do
  jq --arg conflict "$conflict" '
    if $conflict == "duplicate" then .inbounds += [.inbounds[] | select(.tag == "lan-tproxy")]
    else .inbounds |= map(if .tag == "lan-tproxy" then
       if $conflict == "type" then .type="mixed" else .listen_port=24567 end
       else . end) end
  ' "$TMP/advanced-config.json" > "$TMP/home/config/config.json"
  cp "$TMP/home/config/config.json" "$TMP/custom.before"
  if gw configure br-edge.42 10.23.40.0/23 > "$TMP/error" 2>&1; then echo 'Custom tag conflict overwritten' >&2; exit 1; fi
  cmp "$TMP/home/config/config.json" "$TMP/custom.before"
  cmp "$TMP/home/runtime/gateway.json" "$TMP/gateway.before"
done
echo 'TEST disable preserves a repurposed non-TProxy inbound'
jq '.inbounds |= map(if .tag == "lan-tproxy" then .type="mixed" else . end)' \
  "$TMP/advanced-config.json" > "$TMP/home/config/config.json"
jq -S . "$TMP/home/config/config.json" > "$TMP/custom.before"
gw disable
jq -S . "$TMP/home/config/config.json" > "$TMP/custom.after"
cmp "$TMP/custom.before" "$TMP/custom.after"
[ ! -f "$TMP/home/runtime/gateway.json" ]
cp "$TMP/gateway.before" "$TMP/home/runtime/gateway.json"
echo 'TEST no configured gateway means no global sweeping'
reset
mv "$TMP/home/runtime/gateway.json" "$TMP/home/runtime/settings.bak"
echo '15360: from all fwmark 0x1536 lookup 53136' > "$TMP/state/rules"
gw cleanup
[ "$(rule_count)" -eq 1 ]

echo 'TEST managed gateway edits persist in source and failed commits retain settings'
reset
mkdir -p "$SH_SINGBOX_HOME/scripts" "$SH_SINGBOX_HOME/providers"
cp "$BASE/config/config.template.json" "$SH_SINGBOX_HOME/config/config.template.json"
cp "$BASE/examples/xboard.sample.json" "$SH_SINGBOX_HOME/providers/xboard.json"
cp "$BASE/examples/local.sample.json" "$SH_SINGBOX_HOME/providers/local.json"
cat > "$SH_SINGBOX_HOME/scripts/sbctl" <<'SH'
#!/bin/sh
set -eu
[ "$*" = preflight ] || exit 64
[ "${MOCK_PARTS_PREFLIGHT_FAIL:-0}" = 0 ] || { echo 'mock device preflight rejected candidate' >&2; exit 47; }
jq -e 'type=="object" and (.inbounds|type=="array")' "$SH_SINGBOX_CONFIG" >/dev/null
SH
chmod 0755 "$SH_SINGBOX_HOME/scripts/sbctl"
PARTS_TOOL="$BASE/scripts/config-parts.sh"
export SB_CONFIG_PARTS_TOOL="$TMP/old-checkout-composer.sh"
export PARTS_SELECTOR_HIT="$TMP/foreign-composer-called"
cat > "$SB_CONFIG_PARTS_TOOL" <<'SH'
#!/bin/sh
: > "$PARTS_SELECTOR_HIT"
exit 97
SH
jq '
 .outbounds += [{"type":"socks","tag":"remote-office","server":"192.0.2.20","server_port":1080}]
 | .route.rules=(.route.rules[:3]
      + [{"ip_cidr":["10.77.50.10/32"],"action":"route","outbound":"remote-office"}]
      + .route.rules[3:])
' "$BASE/config/config.template.json" > "$SH_SINGBOX_CONFIG"
bash "$PARTS_TOOL" init > "$TMP/parts-init.log" 2>&1
PARTS_DIR="${SH_SINGBOX_CONFIG%.json}.d"
cp "$SH_SINGBOX_CONFIG" "$TMP/parts-generated-before.json"
cp "$PARTS_DIR/inbounds.json" "$TMP/parts-inbounds-before.json"
cp "$PARTS_DIR/routing.json" "$TMP/parts-routing-before.json"
if (export MOCK_PARTS_PREFLIGHT_FAIL=1; gw configure br-edge.42 10.23.40.0/23) > "$TMP/parts-rejected.log" 2>&1; then
  echo 'Gateway ignored failed managed inbound validation' >&2; exit 1
fi
cmp "$SH_SINGBOX_CONFIG" "$TMP/parts-generated-before.json"
cmp "$PARTS_DIR/inbounds.json" "$TMP/parts-inbounds-before.json"
[ ! -f "$SH_SINGBOX_HOME/runtime/gateway.json" ]
SB_CONFIG_PARTS_TOOL="$TMP/removed-checkout/config-parts.sh" gw configure br-edge.42 10.23.40.0/23
jq -e 'any(.inbounds[]; .tag=="lan-tproxy" and .type=="tproxy" and .listen_port==1536)' "$PARTS_DIR/inbounds.json" >/dev/null
bash "$PARTS_TOOL" render > "$TMP/parts-render.log" 2>&1
jq -e --slurpfile source "$PARTS_DIR/inbounds.json" '.inbounds==$source[0].inbounds' "$SH_SINGBOX_CONFIG" >/dev/null
cmp "$PARTS_DIR/routing.json" "$TMP/parts-routing-before.json"
gw apply
active

echo 'TEST broken source blocks apply but cannot block owned network cleanup'
cp "$PARTS_DIR/inbounds.json" "$TMP/parts-inbounds-valid.json"
cp "$SH_SINGBOX_CONFIG" "$TMP/parts-generated-valid.json"
cp "$SH_SINGBOX_HOME/runtime/gateway.json" "$TMP/parts-settings-valid.json"
printf '{\n' > "$PARTS_DIR/inbounds.json"
if gw apply > "$TMP/parts-invalid-apply.log" 2>&1; then
  echo 'Gateway applied stale output despite malformed managed source' >&2; exit 1
fi
active
gw status > "$TMP/parts-status.log" 2>&1
gw cleanup
[ "$(rule_count)" -eq 0 ] && [ ! -s "$TMP/state/routes" ] && [ ! -f "$TMP/state/nft" ]
[ "$(cat "$TMP/forward")" = 0 ]
if gw disable > "$TMP/parts-invalid-disable.log" 2>&1; then
  echo 'Gateway silently removed managed configuration with malformed source' >&2; exit 1
fi
cmp "$SH_SINGBOX_CONFIG" "$TMP/parts-generated-valid.json"
cmp "$SH_SINGBOX_HOME/runtime/gateway.json" "$TMP/parts-settings-valid.json"
cp "$TMP/parts-inbounds-valid.json" "$PARTS_DIR/inbounds.json"
gw disable
bash "$PARTS_TOOL" render > "$TMP/parts-disable-render.log" 2>&1
jq -e 'all(.inbounds[]; .tag!="lan-tproxy")' "$PARTS_DIR/inbounds.json" >/dev/null
jq -e 'all(.inbounds[]; .tag!="lan-tproxy")' "$SH_SINGBOX_CONFIG" >/dev/null
cmp "$PARTS_DIR/routing.json" "$TMP/parts-routing-before.json"
[ ! -f "$SH_SINGBOX_HOME/runtime/gateway.json" ]
[ ! -e "$PARTS_SELECTOR_HIT" ] || { echo 'Gateway called an inherited foreign composer' >&2; exit 1; }
echo 'PASS gateway uses its sibling composer despite inherited stale/foreign selectors'
echo 'Gateway ownership and stale-rule recovery tests passed.'
