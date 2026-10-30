#!/bin/sh
# Generic-device helpers must preserve explicit listener and private-route data.
# Every external core, process, address, download and API operation is mocked.
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP=$(mktemp -d /tmp/sb-device-helpers.XXXXXX)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAILED: $*" >&2; exit 1; }
SH_SINGBOX_HOME="$TMP/device home"
SH_SINGBOX_CONFIG="$TMP/active config.json"
TARGET="$TMP/real config.json"
export SH_SINGBOX_HOME SH_SINGBOX_CONFIG
SB_DOWNLOAD_MODE=direct; export SB_DOWNLOAD_MODE
mkdir -p "$SH_SINGBOX_HOME/bin" "$SH_SINGBOX_HOME/config" "$SH_SINGBOX_HOME/runtime" "$TMP/tools"
cp "$BASE/config/config.template.json" "$SH_SINGBOX_HOME/config/config.template.json"
ln -s "$TARGET" "$SH_SINGBOX_CONFIG"
REAL_GREP=$(command -v grep)
MOCK_PID_ONE=4001
MOCK_PID_TWO=4002
SB_PROC_ROOT="$TMP/proc"
mkdir -p "$SB_PROC_ROOT/$MOCK_PID_ONE" "$SB_PROC_ROOT/$MOCK_PID_TWO"
printf 'Uid:\t777\t777\t777\t777\n' > "$SB_PROC_ROOT/$MOCK_PID_ONE/status"
printf 'Uid:\t36011\t36011\t36011\t36011\n' > "$SB_PROC_ROOT/$MOCK_PID_TWO/status"
CURL_LOG="$TMP/curl.log"
HEADER_LOG="$TMP/header.log"
export REAL_GREP MOCK_PID_ONE MOCK_PID_TWO SB_PROC_ROOT CURL_LOG HEADER_LOG
cat > "$TMP/tools/id" <<'SH'
#!/bin/sh
[ "$*" = -u ] || exit 64
printf '0\n'
SH
cat > "$TMP/tools/ip" <<'SH'
#!/bin/sh
case "$*" in
 '-4 -o addr show'|'-4 -o addr show scope global')
   printf '3: br-device inet 10.23.40.45/23 scope global br-device\n' ;;
 *) exit 64 ;;
esac
SH
cat > "$TMP/tools/pidof" <<'SH'
#!/bin/sh
[ "$*" = x-tunnel ] || exit 64
printf '%s %s\n' "$MOCK_PID_ONE" "$MOCK_PID_TWO"
SH
cat > "$TMP/tools/grep" <<'SH'
#!/bin/sh
for arg do
 case "$arg" in -*P*) echo 'BusyBox grep: PCRE unsupported' >&2; exit 64 ;; esac
done
exec "$REAL_GREP" "$@"
SH
cat > "$TMP/tools/getent" <<'SH'
#!/bin/sh
printf '203.0.113.21 STREAM www.google.com\n'
SH
cat > "$SH_SINGBOX_HOME/bin/sing-box" <<'SH'
#!/bin/sh
[ "$1" = check ] && [ "$2" = -c ] || exit 64
[ "${MOCK_CHECK_STATUS:-0}" -eq 0 ] || exit "$MOCK_CHECK_STATUS"
if [ -n "${MOCK_RACE_TRIGGER:-}" ] && [ -f "$MOCK_RACE_TRIGGER" ]; then
    cp "$MOCK_RACE_CONTENT" "$MOCK_RACE_DEST"
    rm -f "$MOCK_RACE_TRIGGER"
fi
jq -e 'type=="object" and (.inbounds|type=="array")' "$3" >/dev/null
SH
cat > "$TMP/tools/curl" <<'SH'
#!/bin/sh
set -eu
output= header= method=GET url=
# Log arguments only; this file must never contain the configured API secret.
printf '%s\n' "$*" >> "$CURL_LOG"
while [ "$#" -gt 0 ]; do
 case "$1" in
  -o|--output) output=$2; shift 2 ;;
  --header) header=$2; shift 2 ;;
  -X) method=$2; shift 2 ;;
  --connect-timeout|--max-time|--noproxy) shift 2 ;;
  http://*|https://*) url=$1; shift ;;
  *) shift ;;
 esac
done
if [ -n "$output" ]; then printf 'mock rule data\n' > "$output"; exit 0; fi
case "$url" in
 https://cloudflare.com/cdn-cgi/trace) printf 'ip=203.0.113.9\n'; exit 0 ;;
 https://api.ipify.org) printf '203.0.113.9'; exit 0 ;;
esac
case "$header" in @*) header=${header#@} ;; *) exit 70 ;; esac
[ "$(stat -c %a "$header")" = 600 ] || exit 71
[ "$(cat "$header")" = 'Authorization: Bearer private-api-marker' ] || exit 72
printf '%s\n' "$header" >> "$HEADER_LOG"
case "$method $url" in
 'GET http://127.0.0.1:18390/version') printf '{"version":"mock"}\n' ;;
 'GET http://127.0.0.1:18390/providers/proxies') printf '{"providers":{"HK pool":{},"node/two":{}}}\n' ;;
 'PUT http://127.0.0.1:18390/providers/proxies/HK%20pool'|'PUT http://127.0.0.1:18390/providers/proxies/node%2Ftwo') : ;;
 *) exit 73 ;;
esac
SH
chmod 0755 "$TMP/tools/"* "$SH_SINGBOX_HOME/bin/sing-box"
PATH="$TMP/tools:$PATH"; export PATH

# Synthetic fixture: preserve a real LAN bind and a selected remote node for a
# private CIDR, while ordinary private traffic still takes the direct fallback.
jq '
 .inbounds |= map(if .type=="ebpf" then .local.exclude_uid=[1200] else . end)
 | .inbounds |= map(if .tag=="lan-mixed" then
     .listen="10.23.40.45" | .listen_port=18791 | .tcp_fast_open=true
     | .users=[{"username":"block","password":"keep-this-password-1234"}]
   else . end)
 | .inbounds += [{"type":"mixed","tag":"lan-explicit-proxy","listen":"10.23.40.45",
                  "listen_port":18790,"users":[{"username":"other","password":"keep-other-password-1234"}]}]
 | .outbounds += [{"type":"socks","tag":"office-node","server":"203.0.113.10","server_port":31415}]
 | .route.rules = (.route.rules[:3]
     + [{"ip_cidr":["192.168.50.0/24"],"action":"route","outbound":"direct"},
        {"ip_cidr":["10.77.0.0/24"],"action":"route","outbound":"office-node"},
        {"inbound":["lan-mixed"],"action":"sniff","timeout":"750ms"},
        {"inbound":["lan-explicit-proxy"],"port":5353,"action":"hijack-dns"}]
     + .route.rules[3:])
 | .dns.rules += [{"domain":["office.example"],"server":"dns-ai"},
                  {"domain":["office.example"],"query_type":["AAAA"],"action":"predefined","rcode":"REFUSED"}]
' "$BASE/config/config.template.json" > "$TMP/original.json"
cp "$TMP/original.json" "$TARGET"

bash "$BASE/scripts/apply-pc-privacy.sh" apply > "$TMP/privacy.log" 2>&1 || fail 'privacy merge failed'
[ -L "$SH_SINGBOX_CONFIG" ] || fail 'privacy merge replaced active config symlink'
jq -e --slurpfile before "$TMP/original.json" '
 .inbounds==$before[0].inbounds
 and ([.route.rules[]|select(.ip_cidr?)]==[$before[0].route.rules[]|select(.ip_cidr?)])
' "$TARGET" >/dev/null || fail 'privacy merge changed explicit listener/private route data'
# Every original route object must remain in the same order, including scoped
# sniff/hijack rules. Managed guards were already present in this fixture.
jq -e --slurpfile before "$TMP/original.json" '.route.rules==$before[0].route.rules' "$TARGET" >/dev/null || fail 'privacy merge changed custom route order'
jq -e --slurpfile before "$TMP/original.json" '. as $after |
 all($before[0].dns.rules[]; . as $rule | any($after.dns.rules[]; .==$rule))' "$TARGET" >/dev/null || fail 'privacy merge discarded scoped DNS rules'
cp "$TARGET" "$TMP/privacy-once.json"
bash "$BASE/scripts/apply-pc-privacy.sh" apply > "$TMP/privacy-twice.log" 2>&1 || fail 'second privacy merge failed'
cmp -s "$TARGET" "$TMP/privacy-once.json" || fail 'privacy merge was not idempotent'
# Missing canonical AI policy is inserted after the explicit private routes,
# before the broad private fallback; DNS/STUN guard priority remains intact.
jq 'del(.route.rules[] | select(.outbound=="ai" and .domain_suffix?))' "$TMP/original.json" > "$TARGET"
bash "$BASE/scripts/apply-pc-privacy.sh" apply > "$TMP/privacy-missing-ai.log" 2>&1 || fail 'missing AI policy merge failed'
jq -e '.route.rules as $r |
 ([$r|to_entries[]|select(.value.ip_cidr==["10.77.0.0/24"])|.key][0]) as $private |
 ([$r|to_entries[]|select(.value.outbound=="ai" and .value.domain_suffix?)|.key][0]) as $ai |
 ([$r|to_entries[]|select(.value.ip_is_private==true)|.key][0]) as $fallback |
 $private>2 and $private<$ai and $ai<$fallback and $r[2].action=="reject"
' "$TARGET" >/dev/null || fail 'new AI policy intercepted an explicit private-node route'
jq 'del(.route.rules[] | select((.outbound=="ai" and .domain_suffix?)
       or .ip_is_private==true or ((.rule_set // [] | index("private")) != null)))' \
    "$TMP/original.json" > "$TARGET"
bash "$BASE/scripts/apply-pc-privacy.sh" apply > "$TMP/privacy-no-fallback.log" 2>&1 || fail 'privacy merge without private fallback failed'
jq -e '.route.rules as $r |
 ([$r|to_entries[]|select(.value.ip_cidr==["10.77.0.0/24"])|.key][0]) as $private |
 ([$r|to_entries[]|select(.value.outbound=="ai" and .value.domain_suffix?)|.key][0]) as $ai |
 $private>2 and $private<$ai and $ai==(($r|length)-1)
' "$TARGET" >/dev/null || fail 'missing private fallback moved AI ahead of explicit CIDR routing'

cp "$TMP/original.json" "$TARGET"
printf '\n32322\nnew-user\nnew-password-1234\n' | \
 bash "$BASE/scripts/configure-pc-proxy.sh" configure > "$TMP/lan.log" 2>&1 || fail 'generic LAN listener edit failed'
[ -L "$SH_SINGBOX_CONFIG" ] || fail 'LAN editor replaced active config symlink'
jq -e --slurpfile before "$TMP/original.json" '
 .route==$before[0].route and
 ([.inbounds[]|select(.tag=="lan-explicit-proxy")]==[$before[0].inbounds[]|select(.tag=="lan-explicit-proxy")]) and
 any(.inbounds[]; .tag=="lan-mixed" and .listen=="10.23.40.45" and .listen_port==32322 and .tcp_fast_open==true
     and any(.users[]; .username=="block" and .password=="keep-this-password-1234")
     and any(.users[]; .username=="new-user" and .password=="new-password-1234"))
' "$TARGET" >/dev/null || fail 'LAN edit discarded inbound options/users or custom routes'
cp "$TARGET" "$TMP/lan-once.json"
if printf '\n18790\n' | bash "$BASE/scripts/configure-pc-proxy.sh" configure > "$TMP/lan-collision.log" 2>&1; then
 fail 'LAN editor accepted a port occupied by another configured listener'
fi
cmp -s "$TARGET" "$TMP/lan-once.json" || fail 'port conflict changed the original config'
if printf '192.168.50.11\n' | bash "$BASE/scripts/configure-pc-proxy.sh" configure > "$TMP/lan-stale.log" 2>&1; then
 fail 'LAN editor silently accepted an unassigned address'
fi
cmp -s "$TARGET" "$TMP/lan-once.json" || fail 'LAN editor auto-replaced the requested address'

jq '.inbounds |= map(if .type=="ebpf" then
      .shared={"enabled":false,"interface":["custom-lan"],"data_plane":"packet_rewrite"}
    else . end)' "$TMP/original.json" > "$TARGET"
bash "$BASE/scripts/align-xtunnel-ebpf.sh" > "$TMP/uid.log" 2>&1 || {
 cat "$TMP/uid.log" >&2; fail 'dedicated UIDs below/above 1000 failed alignment';
}
jq -e '.inbounds[]|select(.type=="ebpf")|.local.exclude_uid==[777,1200,36011]' "$TARGET" >/dev/null || fail 'alignment did not preserve explicit UID or inspect every process'
jq -e '.inbounds[]|select(.type=="ebpf")|
 .shared=={"enabled":false,"interface":["custom-lan"],"data_plane":"packet_rewrite"}
' "$TARGET" >/dev/null || fail 'UID alignment rewrote unrelated shared settings'
[ -L "$SH_SINGBOX_CONFIG" ] || fail 'UID alignment replaced active config symlink'
cp "$TARGET" "$TMP/uid-once.json"
for uid_fields in '0 0 0 0' '777 888 777 777'; do
 printf 'Uid:\t%s\n' "$uid_fields" > "$SB_PROC_ROOT/$MOCK_PID_TWO/status"
 if bash "$BASE/scripts/align-xtunnel-ebpf.sh" > "$TMP/uid-refused.log" 2>&1; then
  fail 'root/mixed process credentials were auto-excluded'
 fi
 cmp -s "$TARGET" "$TMP/uid-once.json" || fail 'unsafe process identity changed config'
done

printf 'Uid:\t36011\t36011\t36011\t36011\n' > "$SB_PROC_ROOT/$MOCK_PID_TWO/status"
jq '.inbounds |= map(if .type=="ebpf" then del(.local.enabled, .shared) | .tag="default-local" else . end)
 | .inbounds += [
     {"type":"ebpf","tag":"explicit-disabled","local":{"enabled":false,"exclude_uid":[1300]}},
     {"type":"ebpf","tag":"shared-only","shared":{"enabled":true,"interface":["custom-lan"]},"local":{"exclude_uid":[1400]}}
   ]' "$TMP/original.json" > "$TARGET"
cp "$TARGET" "$TMP/uid-default-before.json"
bash "$BASE/scripts/align-xtunnel-ebpf.sh" > "$TMP/uid-default.log" 2>&1 || fail 'default-enabled local eBPF was not aligned'
jq -e --slurpfile before "$TMP/uid-default-before.json" '
 any(.inbounds[]; .tag=="default-local" and .local.exclude_uid==[777,1200,36011] and .local.enabled==null)
 and ([.inbounds[]|select(.tag=="explicit-disabled" or .tag=="shared-only")]
      ==[$before[0].inbounds[]|select(.tag=="explicit-disabled" or .tag=="shared-only")])
' "$TARGET" >/dev/null || fail 'default enablement alignment rewrote a disabled or shared-only path'

jq '.outbounds += [{"type":"dns","tag":"old-special-dns"}]' "$TMP/original.json" > "$TARGET"
bash "$BASE/scripts/migrate-config.sh" > "$TMP/migration.log" 2>&1 || fail 'migration rejected an unrelated username block'
[ -L "$SH_SINGBOX_CONFIG" ] || fail 'migration replaced active config symlink'
jq -e --slurpfile before "$TMP/original.json" '.route==$before[0].route and .inbounds==$before[0].inbounds' "$TARGET" >/dev/null || fail 'migration changed custom LAN/routes'
jq '.outbounds += [{"type":"dns","tag":"old-special-dns"}] | .route.final="old-special-dns"' "$TMP/original.json" > "$TARGET"
cp "$TARGET" "$TMP/migration-refuse.json"
if bash "$BASE/scripts/migrate-config.sh" > "$TMP/migration-refuse.log" 2>&1; then fail 'migration accepted a dangling removed outbound'; fi
cmp -s "$TARGET" "$TMP/migration-refuse.json" || fail 'rejected migration changed original config'

jq '.experimental.clash_api.external_controller="0.0.0.0:18390"
 | .experimental.clash_api.secret="private-api-marker"' "$TMP/original.json" > "$TARGET"
: > "$CURL_LOG"; : > "$HEADER_LOG"
bash "$BASE/scripts/update-rules.sh" > "$TMP/rules.log" 2>&1 || fail 'portable rules/provider update failed'
grep -Fq 'http://127.0.0.1:18390/providers/proxies/HK%20pool' "$CURL_LOG" || fail 'configured API/provider name not used'
grep -Fq 'http://127.0.0.1:18390/providers/proxies/node%2Ftwo' "$CURL_LOG" || fail 'provider path component not escaped'
if grep -Fq private-api-marker "$CURL_LOG" "$TMP/rules.log"; then fail 'API secret leaked into arguments/output'; fi
[ -s "$HEADER_LOG" ] || fail 'configured API authentication was not exercised'
while IFS= read -r header; do [ ! -e "$header" ] || fail 'API header file was not removed'; done < "$HEADER_LOG"
jq 'del(.experimental.clash_api)' "$TMP/original.json" > "$TARGET"
: > "$CURL_LOG"
bash "$BASE/scripts/update-rules.sh" > "$TMP/rules-no-api.log" 2>&1 || fail 'rules update without API failed'
if grep -Fq 'http://127.0.0.1:' "$CURL_LOG"; then fail 'rules update guessed an absent API'; fi

jq '.dns.servers |= map(if .type=="fakeip" then .inet4_range="203.0.113.0/24" else . end)
 | .inbounds |= map(if .type=="ebpf" then del(.local.enabled) else . end)' "$TMP/original.json" > "$TARGET"
bash "$BASE/scripts/test-leak.sh" > "$TMP/leak.log" 2>&1 || fail 'portable host diagnostics failed'
grep -Fq 'belongs to a configured IPv4 FakeIP range' "$TMP/leak.log" || fail 'diagnostics assumed fixed FakeIP range'
grep -Fq 'exclude_uid=[1200]' "$TMP/leak.log" || fail 'diagnostics did not read configured UID'
if grep -Eq '100% intercepted|All user UIDs intercepted|PCRE unsupported' "$TMP/leak.log"; then fail 'diagnostic portability or certainty regression'; fi

# Exercise the real section composer while keeping core/device validation local
# to this fixture. The helpers must commit sources, not just generated output.
mkdir -p "$SH_SINGBOX_HOME/scripts" "$SH_SINGBOX_HOME/providers"
cp "$BASE/examples/xboard.sample.json" "$SH_SINGBOX_HOME/providers/xboard.json"
cp "$BASE/examples/local.sample.json" "$SH_SINGBOX_HOME/providers/local.json"
cat > "$SH_SINGBOX_HOME/scripts/sbctl" <<'SH'
#!/bin/sh
set -eu
[ "$*" = preflight ] || exit 64
[ "${MOCK_PARTS_PREFLIGHT_FAIL:-0}" = 0 ] || { echo 'mock device preflight rejected candidate' >&2; exit 47; }
exec "$SH_SINGBOX_HOME/bin/sing-box" check -c "$SH_SINGBOX_CONFIG"
SH
chmod 0755 "$SH_SINGBOX_HOME/scripts/sbctl"
PARTS_TOOL="$BASE/scripts/config-parts.sh"
# A source-menu selector must not cross an executable helper boundary. Keep a
# callable decoy exported throughout validation, save and concurrent-edit tests.
SB_CONFIG_PARTS_TOOL="$TMP/old-checkout-composer.sh"
PARTS_SELECTOR_HIT="$TMP/foreign-composer-called"
export SB_CONFIG_PARTS_TOOL PARTS_SELECTOR_HIT
cat > "$SB_CONFIG_PARTS_TOOL" <<'SH'
#!/bin/sh
: > "$PARTS_SELECTOR_HIT"
exit 97
SH
jq --slurpfile existing "$TMP/original.json" '
 .inbounds=$existing[0].inbounds
 | .outbounds += [$existing[0].outbounds[]|select(.tag=="office-node")]
 | .route.rules=(.route.rules[:3]
      + [$existing[0].route.rules[]|select(.ip_cidr?)] + .route.rules[3:])
' "$BASE/config/config.template.json" > "$TARGET"
bash "$PARTS_TOOL" init > "$TMP/parts-init.log" 2>&1 || fail 'could not initialize compatible helper fixture sections'
PARTS_DIR="${SH_SINGBOX_CONFIG%.json}.d"
[ -d "$PARTS_DIR" ] && [ -L "$SH_SINGBOX_CONFIG" ] || fail 'section initialization lost the configured symlink entry'
cp "$PARTS_DIR/routing.json" "$TMP/parts-routing-before.json"

printf '\n32323\nmanaged-user\nmanaged-password-1234\n' | \
 SB_CONFIG_PARTS_TOOL="$TMP/removed-checkout/config-parts.sh" \
 bash "$BASE/scripts/configure-pc-proxy.sh" configure > "$TMP/parts-lan.log" 2>&1 || fail 'managed LAN edit failed with a stale inherited composer selector'
jq -e 'any(.inbounds[]; .tag=="lan-mixed" and .listen_port==32323
  and .tcp_fast_open==true and any(.users[]; .username=="managed-user" and .password=="managed-password-1234")
  and any(.users[]; .username=="block" and .password=="keep-this-password-1234"))' \
  "$PARTS_DIR/inbounds.json" >/dev/null || fail 'managed LAN edit did not update source credentials/options'
bash "$PARTS_TOOL" render > "$TMP/parts-render.log" 2>&1 || fail 'LAN edits did not survive a rebuild'
jq -e --slurpfile source "$PARTS_DIR/inbounds.json" '.inbounds==$source[0].inbounds' "$TARGET" >/dev/null || fail 'rebuilt LAN settings differ from their source'
cp "$TARGET" "$TMP/parts-lan-valid.json"
cp "$PARTS_DIR/inbounds.json" "$TMP/parts-inbounds-valid.json"
if printf '\n32324\nmanaged-user\nmanaged-password-5678\n' | \
 MOCK_PARTS_PREFLIGHT_FAIL=1 bash "$BASE/scripts/configure-pc-proxy.sh" configure > "$TMP/parts-lan-rejected.log" 2>&1; then
 fail 'managed LAN edit ignored failed candidate device validation'
fi
cmp -s "$TARGET" "$TMP/parts-lan-valid.json" && \
 cmp -s "$PARTS_DIR/inbounds.json" "$TMP/parts-inbounds-valid.json" || fail 'rejected LAN commit changed generated config or source'

# Model a second editor saving the same section after this helper read it but
# before commit begins. Only the new concurrent edit may remain pending.
jq '.inbounds |= map(if .tag=="lan-explicit-proxy" then .listen_port=18792 else . end)' \
 "$PARTS_DIR/inbounds.json" > "$TMP/concurrent-inbounds.json"
: > "$TMP/race-ready"
if printf '\n32324\nmanaged-user\nmanaged-password-5678\n' | \
 MOCK_RACE_TRIGGER="$TMP/race-ready" MOCK_RACE_CONTENT="$TMP/concurrent-inbounds.json" \
 MOCK_RACE_DEST="$PARTS_DIR/inbounds.json" \
 bash "$BASE/scripts/configure-pc-proxy.sh" configure > "$TMP/parts-lan-concurrent.log" 2>&1; then
 fail 'managed LAN edit overwrote a concurrent edit to the same section'
fi
[ ! -e "$TMP/race-ready" ] || fail 'concurrent edit fixture was not exercised'
cmp -s "$PARTS_DIR/inbounds.json" "$TMP/concurrent-inbounds.json" || fail 'stale helper discarded a newer pending section'
cmp -s "$TARGET" "$TMP/parts-lan-valid.json" || fail 'stale helper changed generated output'
bash "$PARTS_TOOL" render > "$TMP/parts-concurrent-render.log" 2>&1 || fail 'preserved concurrent edit could not be rendered'
jq -e 'any(.inbounds[]; .tag=="lan-explicit-proxy" and .listen_port==18792)' "$TARGET" >/dev/null || fail 'concurrent edit disappeared after rebuild'

bash "$BASE/scripts/align-xtunnel-ebpf.sh" > "$TMP/parts-uid.log" 2>&1 || fail 'managed UID alignment failed'
jq -e '.inbounds[]|select(.type=="ebpf")|.local.exclude_uid==[777,1200,36011]' \
 "$PARTS_DIR/inbounds.json" >/dev/null || fail 'UID exclusions were not written to the inbounds source'
bash "$PARTS_TOOL" render > "$TMP/parts-uid-render.log" 2>&1 || fail 'UID source could not be rebuilt'
jq -e '.inbounds[]|select(.type=="ebpf")|.local.exclude_uid==[777,1200,36011]' "$TARGET" >/dev/null || fail 'UID exclusions disappeared on rebuild'
cmp -s "$PARTS_DIR/routing.json" "$TMP/parts-routing-before.json" || fail 'inbound helpers rewrote user routing exceptions'
bash "$BASE/scripts/configure-pc-proxy.sh" disable > "$TMP/parts-lan-disable.log" 2>&1 || fail 'managed LAN disable failed'
jq -e 'all(.inbounds[]; .tag!="lan-mixed")' "$PARTS_DIR/inbounds.json" >/dev/null || fail 'managed LAN disable did not update its source'

# A policy refresh may replace fixed DNS, but cannot restore a removed inbound
# or rewrite any of the user's five section files.
for section in providers inbounds outbounds routing settings; do
 cp "$PARTS_DIR/$section.json" "$TMP/parts-$section-before-privacy.json"
done
jq '.dns.timeout="6s"' "$SH_SINGBOX_HOME/config/config.template.json" > "$TMP/next-policy.json"
mv "$TMP/next-policy.json" "$SH_SINGBOX_HOME/config/config.template.json"
bash "$BASE/scripts/apply-pc-privacy.sh" apply > "$TMP/parts-privacy.log" 2>&1 || fail 'managed policy refresh failed'
jq -e '.dns.timeout=="6s" and all(.inbounds[]; .tag!="lan-mixed")' "$TARGET" >/dev/null || fail 'managed privacy refresh rewrote user inbounds or did not refresh fixed DNS'
for section in providers inbounds outbounds routing settings; do
 cmp -s "$PARTS_DIR/$section.json" "$TMP/parts-$section-before-privacy.json" || fail "managed privacy refresh rewrote $section source"
done
cp "$TARGET" "$TMP/parts-before-migration.json"
if bash "$BASE/scripts/migrate-config.sh" > "$TMP/parts-migration.log" 2>&1; then
 fail 'legacy migration wrote managed generated config'
fi
if bash "$BASE/scripts/migrate-config.sh" "$TARGET" > "$TMP/parts-migration-alias.log" 2>&1; then
 fail 'legacy migration accepted the resolved alias of managed generated config'
fi
cmp -s "$TARGET" "$TMP/parts-before-migration.json" || fail 'refused legacy migration changed generated output'

printf '{\n' > "$PARTS_DIR/inbounds.json"
bash "$BASE/scripts/configure-pc-proxy.sh" status > "$TMP/parts-status.log" 2>&1 || fail 'LAN status tried to apply malformed pending source'
if bash "$BASE/scripts/configure-pc-proxy.sh" disable > "$TMP/parts-invalid.log" 2>&1; then
 fail 'LAN edit silently used stale generated output with malformed source'
fi
cmp -s "$TARGET" "$TMP/parts-before-migration.json" || fail 'malformed source changed generated output'
if grep -Fq managed-password-1234 "$TMP/parts-"*.log; then fail 'managed helper logged a proxy password'; fi
[ ! -e "$PARTS_SELECTOR_HIT" ] || fail 'a device helper called an inherited foreign composer instead of its sibling'
echo 'PASS helper composer binding ignores stale/foreign selectors without bypassing validation or concurrent-edit guards'
echo 'Generic-device helper preservation and portability tests passed.'
