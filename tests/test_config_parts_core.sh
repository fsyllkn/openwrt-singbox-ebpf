#!/usr/bin/env bash
# Exercise actual source composition and preflight with the verified pinned core.
# This performs check/Close only; never installs or starts a service or attaches
# a transparent-proxy data plane. Provider runtime tests live in a separate file.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ -z "${SB_TEST_CORE:-}" ]; then
    echo 'SKIP: set SB_TEST_CORE to a verified reF1nd executable for the real-core split-config test.'
    exit 0
fi
CORE=$SB_TEST_CORE
case "$CORE" in /*) ;; *) CORE="$PWD/$CORE" ;; esac
[ -x "$CORE" ] || { echo 'SB_TEST_CORE must be executable' >&2; exit 1; }
WORK=$(mktemp -d /tmp/sb-parts-core.XXXXXX)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
export SH_SINGBOX_HOME="$WORK/service home"
export SH_SINGBOX_CONFIG="$WORK/external config/live.json"
mkdir -p "$SH_SINGBOX_HOME/"{bin,scripts,config,providers,runtime} "$(dirname "$SH_SINGBOX_CONFIG")"
ln -s "$CORE" "$SH_SINGBOX_HOME/bin/sing-box"
cp "$BASE/scripts/"{sbctl,runtime-paths.sh,config-parts.sh,config-parts-lib.sh,route-manager.sh,terminal-input.sh} "$SH_SINGBOX_HOME/scripts/"
chmod 0755 "$SH_SINGBOX_HOME/scripts/sbctl"
cp "$BASE/config/config.template.json" "$SH_SINGBOX_HOME/config/config.template.json"
cp "$BASE/config/config.template.json" "$SH_SINGBOX_CONFIG"
cp "$BASE/examples/xboard.sample.json" "$SH_SINGBOX_HOME/providers/xboard.json"
cp "$BASE/examples/local.sample.json" "$SH_SINGBOX_HOME/providers/local.json"
run_cli() {
    if ! timeout 60 bash "$SH_SINGBOX_HOME/scripts/sbctl" "$@" > "$WORK/last-check.log" 2>&1; then
        cat "$WORK/last-check.log" >&2
        return 1
    fi
}
run_cli split-config
PARTS=${SH_SINGBOX_CONFIG%.json}.d
[ -f "$PARTS/layout.json" ] && [ -f "$PARTS/providers.json" ]
run_cli preflight
jq -e --slurpfile original "$BASE/config/config.template.json" '.==$original[0]' \
    "$SH_SINGBOX_CONFIG" >/dev/null

# Add a scoped private-network route through a real static tag. The complete
# generated config must parse with the actual core, preserving fixed policy.
cat > "$WORK/routing.json" <<'JSON'
{
  "route": {
    "rules": [
      {"source_ip_cidr":["10.23.40.12/32"],"ip_cidr":["10.77.50.0/24"],
       "action":"route","outbound":"configure-your-proxy"}
    ]
  }
}
JSON
run_cli config-part routing "$WORK/routing.json"
jq '.outbounds |= map(if .tag=="configure-your-proxy" then .server_port=1081 else . end)' \
    "$PARTS/outbounds.json" > "$WORK/outbounds.json"
run_cli config-part outbounds "$WORK/outbounds.json"
run_cli filter exclude-user 34567
run_cli preflight
jq -e --slurpfile template "$BASE/config/config.template.json" \
    --slurpfile custom "$WORK/routing.json" '
    .dns==$template[0].dns
    and (.route|del(.rules))==($template[0].route|del(.rules))
    and .route.rules==($template[0].route.rules[:3] + $custom[0].route.rules + $template[0].route.rules[3:])
    and any(.outbounds[]; .tag=="configure-your-proxy" and .server_port==1081)
    and any(.inbounds[]; .type=="ebpf" and (.local.exclude_uid|index(34567))!=null)
    and .providers==$template[0].providers
  ' "$SH_SINGBOX_CONFIG" >/dev/null

# Use actual outbound group tags through the routing manager. It must retain
# unrelated rules and native qualifiers while the real core validates every
# composition. These fixture groups point at the existing sample SOCKS node;
# no connection to that placeholder is attempted during check.
jq '.outbounds += [
      {type:"selector",tag:"remote-office",outbounds:["configure-your-proxy"],default:"configure-your-proxy"},
      {type:"selector",tag:"remote-home",outbounds:["configure-your-proxy"],default:"configure-your-proxy"}
    ]' "$PARTS/outbounds.json" > "$WORK/outbounds.json"
run_cli config-part outbounds "$WORK/outbounds.json"
run_cli routes add --destination 10.88.60.10 --source 10.23.40.12 --group remote-office --port 14432 --network tcp
run_cli routes edit 2 --group remote-home
run_cli routes move 2 1
run_cli preflight
jq -e --slurpfile original "$WORK/routing.json" '
  (.route.rules|length)==2
  and .route.rules[0].outbound=="remote-home"
  and .route.rules[0].ip_cidr==["10.88.60.10/32"]
  and .route.rules[0].source_ip_cidr==["10.23.40.12/32"]
  and .route.rules[0].port==[14432]
  and .route.rules[1]==$original[0].route.rules[0]
' "$PARTS/routing.json" >/dev/null
run_cli routes remove 2
jq -e --slurpfile policy "$BASE/config/config.template.json" --slurpfile user "$PARTS/routing.json" '
  .dns==$policy[0].dns
  and .route.rules==($policy[0].route.rules[:3]+$user[0].route.rules+$policy[0].route.rules[3:])
  and .route.rules[3].outbound=="remote-home"
' "$SH_SINGBOX_CONFIG" >/dev/null

# Regenerating a deleted output uses the saved sources, never the public defaults.
cp "$SH_SINGBOX_CONFIG" "$WORK/expected.json"
rm "$SH_SINGBOX_CONFIG"
run_cli preflight
jq -e --slurpfile expected "$WORK/expected.json" '.==$expected[0]' "$SH_SINGBOX_CONFIG" >/dev/null
echo 'Real-core split-config init, fragment edits, outbound-group routing CRUD and regeneration passed; no service started.'
