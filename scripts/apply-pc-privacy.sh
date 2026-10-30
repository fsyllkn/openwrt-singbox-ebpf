#!/usr/bin/env bash
# Apply the OpenWrt strict PC privacy policy while preserving real proxy
# nodes, subscriptions and private settings. Requires latest template.
set -euo pipefail

SCRIPT_FILE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
. "$(dirname "$SCRIPT_FILE")/runtime-paths.sh"
sb_load_paths || exit 1
umask 077

ROOT="$SH_SINGBOX_HOME"
CONFIG="$SH_SINGBOX_CONFIG"
POLICY="$ROOT/config/config.template.json"
BIN="$ROOT/bin/sing-box"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[sing-box] %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || die 'Run as root'
[ "${1:-}" = apply ] || die 'Usage: apply-pc-privacy.sh apply'
[ -f "$CONFIG" ] && [ -f "$POLICY" ] || die 'Missing installed config or new template (reinstall from updated openwrt source)'
CONFIG="$(readlink -f "$CONFIG")" || die 'Cannot resolve the active config target.'
[ -x "$BIN" ] || die 'Missing running sing-box kernel'
command -v jq >/dev/null 2>&1 || die 'Install jq first'
# Do not touch complex legacy configurations until the earlier migration passed.
if jq -e '
  any(.outbounds[]?; .type == "dns" or .type == "block")
  or any(.route.rules[]?; .action == "sniff-override-destination")
' "$CONFIG" >/dev/null; then
    die 'Legacy DNS/block/sniff rules exist. Run sb menu option 10 first.'
fi
temp=$(mktemp "$(dirname "$CONFIG")/.privacy.XXXXXX") || die 'Cannot stage configuration'
log=$(mktemp "$(dirname "$CONFIG")/.privacy-log.XXXXXX") || die 'Cannot stage check output'
cleanup() { rm -f "$temp" "$log"; }
trap cleanup EXIT

jq -n --slurpfile live "$CONFIG" --slurpfile template "$POLICY" '
    def list: if type=="array" then . elif .==null then [] else [.] end;
    def private_fallback:
        .ip_is_private? == true or ((.rule_set? | list | index("private")) != null);
    $live[0] as $cfg | $template[0] as $tpl
    | if ($cfg.inbounds|type)!="array" or
         ($cfg.outbounds|type)!="array" or
         ($cfg.route.rules|type)!="array" or
         ($cfg.dns.rules|type)!="array"
      then error("expected inbounds, outbounds, route.rules, dns.rules arrays")
      elif any($cfg.dns.servers[]?;
                .tag=="dns-ai" and .detour!="ai")
      then error("existing dns-ai does not detour through ai; inspect manually")
      elif ([$tpl.outbounds[]? | select(.tag=="ai" and .type=="selector")] | length)!=1 or
           ([$cfg.outbounds[]? | select(.tag=="ai" and .type=="selector")] | length)!=1
      then error("missing ai selector in current or template config")
      else . end
    | ($tpl.dns.servers[] | select(.tag=="dns-ai")) as $ai_dns
    | ($tpl.dns.rules[0]) as $aaaa_rule
    | ($tpl.dns.rules[1]) as $ai_dns_rule
    | ($tpl.route.rules[] | select(.action=="sniff")) as $sniff_rule
    | ($tpl.route.rules[] | select(.action=="hijack-dns")) as $hijack_rule
    | ($tpl.route.rules[] | select(.action=="reject" and .type=="logical"
           and any(.rules[]?; (.protocol? | if type=="array" then index("stun")!=null else .=="stun" end)))) as $stun_rule
    | ($tpl.route.rules[] | select(.outbound=="ai" and .domain_suffix?)) as $ai_route
    | ($tpl.inbounds[] | select(.tag=="lan-mixed")) as $mixed
    | $cfg
    | .dns.servers |=
        (if any(.[]; .tag=="dns-ai") then . else . + [$ai_dns] end)
    | .dns.rules |=
        ([$aaaa_rule, $ai_dns_rule] +
           [ .[] | select(. != $aaaa_rule and . != $ai_dns_rule) ])
    | .route.rules |=
        ([ .[] | select(. != $hijack_rule and . != $sniff_rule and . != $stun_rule) ]
         # Keep existing explicit CIDR -> selected-node rules and the existing
         # AI route in their original relative order. A missing AI rule belongs
         # before the generic private fallback, after any preceding exceptions.
         | if any(.[]; . == $ai_route) then .
           else ([to_entries[] | select(.value | private_fallback) | .key][0] // length) as $insert
             | .[:$insert] + [$ai_route] + .[$insert:]
           end
         # Only exact managed guards are deduplicated. Custom scoped DNS,
         # sniff options and rejection rules are retained verbatim.
         | [$hijack_rule, $sniff_rule, $stun_rule] + .)
    | .outbounds |= map(
        if .type=="selector" and (.tag=="proxy" or .tag=="ai")
        then .outbounds |= map(select(.!="direct")) else . end
      )
    | .inbounds |=
        (if any(.[]; .tag=="lan-mixed") then . else . + [$mixed] end)
' > "$temp" || die 'Cannot generate a valid merged privacy policy; live config unchanged'

if ! (cd "$ROOT" && "$BIN" check -c "$temp") > "$log" 2>&1; then
    printf '[ERROR] Strict privacy config did not pass the current kernel check:\n' >&2
    sed -n '1,35p' "$log" >&2
    die 'Existing config unchanged. Resolve the validation failure first.'
fi

backup="$CONFIG.before-privacy.$(date +%Y%m%d-%H%M%S).$$.bak"
cp "$CONFIG" "$backup" || die 'Cannot backup original config'
chmod 0600 "$backup"
mv -f "$temp" "$CONFIG" || die 'Cannot replace config'
chmod 0600 "$CONFIG"
rm -f "$ROOT/runtime/config.valid" 2>/dev/null || true
info "Strict PC DNS/AI/WebRTC policy installed, backup: $backup"
info 'No restart performed. Use sb menu 8 then 3 to restart during a maintenance window.'
info 'NOTE: LAN client IPv6 and external encrypted DNS are not fully controllable by IPv4 TProxy.'
