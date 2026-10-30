#!/usr/bin/env bash
# Host-side observations and static privacy checks; this does not certify the
# DNS/WebRTC behavior of every application or a separate LAN client.
set -euo pipefail

SCRIPT_FILE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
. "$(dirname "$SCRIPT_FILE")/runtime-paths.sh"
sb_load_paths || exit 1
CONFIG="$SH_SINGBOX_CONFIG"

ok()   { echo -e "  \033[32m[PASS]\033[0m $*"; }
fail() { echo -e "  \033[31m[FAIL]\033[0m $*"; }
warn() { echo -e "  \033[33m[WARN]\033[0m $*"; }
info() { echo -e "\033[36m▶\033[0m $*"; }
command -v jq >/dev/null 2>&1 || { fail 'jq is required for configuration diagnostics.'; exit 1; }
[ -f "$CONFIG" ] && jq -e 'type=="object"' "$CONFIG" >/dev/null || {
    fail "Cannot read configuration: $CONFIG"; exit 1;
}

echo '════════════════════════════════════════════════════════════════'
echo '  Sing-box host observations and configured privacy policy'
echo '════════════════════════════════════════════════════════════════'
info "Configuration: $CONFIG"

info 'Test 1: DNS response and configured FakeIP ranges'
test_domain=www.google.com
resolved_ip=
if command -v getent >/dev/null 2>&1; then
    resolved_ip=$(getent ahosts "$test_domain" 2>/dev/null | awk 'NR==1 {value=$1} END {print value}' || true)
fi
if [ -z "$resolved_ip" ] && command -v nslookup >/dev/null 2>&1; then
    resolved_ip=$(nslookup "$test_domain" 2>/dev/null | awk '
        /^Name:/ {answer=1; next}
        answer && /^Address [0-9]+:/ && value=="" {value=$3}
        answer && /^Address[0-9]*:/ && value=="" {value=$2}
        END {print value}
    ' || true)
fi
if [ -z "$resolved_ip" ] && command -v ping >/dev/null 2>&1; then
    resolved_ip=$(ping -c 1 -W 2 "$test_domain" 2>/dev/null | sed -n '1s/.*(\([^)]*\)).*/\1/p' || true)
fi
fakeip4=$(jq -r '[.dns.servers[]? | select(.type=="fakeip") | .inet4_range // empty]
    + [.dns.fakeip.inet4_range? // empty] | unique[]' "$CONFIG")
if [ -n "$resolved_ip" ]; then
    ok "Host DNS response for $test_domain: $resolved_ip"
    if [[ "$resolved_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [ -n "$fakeip4" ] &&
       printf '%s\n' "$fakeip4" | awk -v address="$resolved_ip" '
        function ipv4(s, parts, i, n) {
            if (split(s, parts, ".") != 4) return -1
            n=0
            for(i=1;i<=4;i++) {if(parts[i]<0 || parts[i]>255) return -1; n=n*256+parts[i]}
            return n
        }
        BEGIN {value=ipv4(address)}
        {split($0, range, "/"); base=ipv4(range[1]); prefix=range[2]
         if(value>=0 && base>=0 && prefix>=0 && prefix<=32) {
             size=2^(32-prefix)
             if(int(value/size)==int(base/size)) found=1
         }}
        END {exit !found}
       '; then
        ok 'This response belongs to a configured IPv4 FakeIP range.'
    else
        info 'This response is not a detected IPv4 FakeIP response; real-IP policies may intentionally return it.'
    fi
else
    fail "Unable to resolve $test_domain with the available host tools."
fi
info 'One DNS response does not establish interception of other applications or LAN clients.'
echo

info 'Test 2: Host IPv4 egress observations'
egress_cf=$(curl -4 -fsS --connect-timeout 5 --max-time 10 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' || true)
egress_ipify=$(curl -4 -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)
if [ -n "$egress_cf" ]; then ok "Cloudflare trace IPv4: $egress_cf"; else warn 'Cloudflare trace was unavailable.'; fi
if [ -n "$egress_ipify" ]; then ok "Ipify IPv4: $egress_ipify"; else warn 'Ipify was unavailable.'; fi
if [ -n "$egress_cf" ] && [ -n "$egress_ipify" ]; then
    if [ "$egress_cf" = "$egress_ipify" ]; then
        ok 'These two host requests used the same IPv4 egress.'
    else
        warn 'Host IPv4 egress differed; inspect the selected routes and node policy.'
    fi
fi
echo

info 'Test 3: Configured WebRTC STUN/DTLS rejection'
if jq -e '
    def list: if type=="array" then . elif .==null then [] else [.] end;
    any(.route.rules[]?; .action=="reject" and
        any(.. | objects; (.protocol? | list | index("stun"))!=null or
                          (.protocol? | list | index("dtls"))!=null))
' "$CONFIG" >/dev/null; then
    ok 'A route rejection rule matches STUN or DTLS; check its scope and order.'
else
    warn 'No STUN/DTLS protocol rejection rule was found.'
fi
info 'UDP port reachability alone cannot prove WebRTC leak protection; validate in the target browser/app.'
echo

info 'Test 4: Configured QUIC rejection'
if jq -e '
    def list: if type=="array" then . elif .==null then [] else [.] end;
    any(.route.rules[]?; .action=="reject" and
        any(.. | objects; (.protocol? | list | index("quic"))!=null))
' "$CONFIG" >/dev/null; then
    ok 'A QUIC rejection rule is configured; its domains/inbounds may limit its scope.'
else
    info 'No QUIC protocol rejection rule was found.'
fi
echo

info 'Test 5: Configured process bypasses and eBPF UID selection'
excluded_procs=$(jq -r '
    def list: if type=="array" then . elif .==null then [] else [.] end;
    [.route.rules[]? | select(.outbound=="direct") | .. | objects | .process_name? | list[]]
    | unique[]
' "$CONFIG")
if [ -n "$excluded_procs" ]; then
    info 'Process names in direct-route rules (scope/order still apply):'
    while IFS= read -r p; do printf '     - %s\n' "$p"; done <<< "$excluded_procs"
else
    info 'No process-name direct rules found; other bypass rules may still apply.'
fi
jq -r '
    .inbounds[]? | select(.type=="ebpf" and
        (.local.enabled==true or (.local.enabled==null and .shared.enabled==null)))
    | "  eBPF \(.tag // "(untagged)"): include_uid=\(.local.include_uid // []) include_uid_range=\(.local.include_uid_range // []) exclude_uid=\(.local.exclude_uid // []) exclude_uid_range=\(.local.exclude_uid_range // [])"
' "$CONFIG"
echo
info 'Diagnostics finished. These observations do not establish DNS/WebRTC safety for separate LAN devices.'
