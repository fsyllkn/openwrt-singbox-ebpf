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
cp "$BASE/scripts/"{sbctl,runtime-paths.sh,config-parts.sh,config-parts-lib.sh} "$SH_SINGBOX_HOME/scripts/"
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

# Regenerating a deleted output uses the saved sources, never the public defaults.
cp "$SH_SINGBOX_CONFIG" "$WORK/expected.json"
rm "$SH_SINGBOX_CONFIG"
run_cli preflight
jq -e --slurpfile expected "$WORK/expected.json" '.==$expected[0]' "$SH_SINGBOX_CONFIG" >/dev/null
echo 'Real-core split-config init, fragment edits, scoped routing and regeneration passed; no service started.'
