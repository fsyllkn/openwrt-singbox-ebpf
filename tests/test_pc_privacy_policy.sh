#!/bin/sh
# Static regression checks for the OpenWrt privacy template.
# Does not require sing-box or touch any firewall/route settings.
set -eu
BASE=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
CONFIG="$BASE/config/config.template.json"
command -v jq >/dev/null 2>&1 || { echo 'jq required' >&2; exit 1; }
jq -e '
    . as $c
    | ([.dns.servers[]? | select(.tag=="dns-ai" and .detour=="ai")] | length)==1
      and ([.dns.rules[]? | select(.server=="dns-ai")] | length)==1
      and ([.dns.rules[]? | select(.query_type==["AAAA"] and .action=="predefined" and .rcode=="NOERROR")] | length)==1
      and ([.inbounds[]? | select(.tag=="lan-mixed" and .type=="mixed"
          and .listen=="127.0.0.1")] | length)==1
      and ([.outbounds[]? | select(.type=="selector" and
          (.tag=="proxy" or .tag=="ai") and (.outbounds | index("direct") != null))] | length)==0
      and ([.route.rules[]? | select(.action=="reject" and .type=="logical" and
          any(.rules[]?; .protocol? == ["stun","dtls"]))] | length)==1
      and (([.route.rules[]? | select(.action=="reject" and .type=="logical" and
          any(.rules[]?; .protocol? == ["stun","dtls"]))][0] |
          .rules[0].protocol | index("stun")) != null)
      and (([.dns.rules[]? | select(.server=="dns-ai")][0].domain_suffix) ==
           ([.route.rules[]? | select(.outbound=="ai" and .domain_suffix?)][0].domain_suffix))
' "$CONFIG" >/dev/null || { echo 'OpenWrt privacy template failed regression check' >&2; exit 1; }
echo 'OpenWrt privacy template static checks: OK'
