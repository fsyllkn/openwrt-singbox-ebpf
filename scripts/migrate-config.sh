#!/usr/bin/env bash
# Migrate the installed reF1nd sing-box config away from 1.13-removed fields.
# No live service restart. Validate the staged config before replacing it.
set -euo pipefail

SCRIPT_FILE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_FILE")"
. "$SCRIPT_DIR/runtime-paths.sh"
sb_load_paths || exit 1
. "$SCRIPT_DIR/config-parts-lib.sh"
SB_CONFIG_PARTS_TOOL="${SB_CONFIG_PARTS_TOOL:-$SCRIPT_DIR/config-parts.sh}"
umask 077

CONFIG="${1:-$SH_SINGBOX_CONFIG}"
ROOT="$SH_SINGBOX_HOME"
BIN="$ROOT/bin/sing-box"

fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[sing-box] %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || fail 'Run as root.'
# A generated config is never the input to the legacy DNS/block migration.
# Check both its configured entry path and an explicit alias to the same file.
if sb_parts_active && { [ "$CONFIG" = "$SH_SINGBOX_CONFIG" ] || [ "$CONFIG" -ef "$SH_SINGBOX_CONFIG" ]; }; then
    fail 'DNS/routing is project-managed in section mode. Edit the section files or explicitly use sbctl single-config before this legacy migration.'
fi
if [ "$CONFIG" != "$SH_SINGBOX_CONFIG" ] && (SH_SINGBOX_CONFIG="$CONFIG"; sb_parts_active); then
    fail 'The selected configuration has managed sections; legacy migration will not edit generated output.'
fi
[ -f "$CONFIG" ] || fail "Configuration not found: $CONFIG"
CONFIG="$(readlink -f "$CONFIG")" || fail 'Cannot resolve the active config target.'
[ -x "$BIN" ] || fail "Kernel not found: $BIN"
command -v jq >/dev/null 2>&1 || fail 'jq is required for safe JSON migration.'
command -v mktemp >/dev/null 2>&1 || fail 'mktemp is required.'

DIR=$(dirname "$CONFIG")
CANDIDATE=$(mktemp "$DIR/.sing-box-migrated.XXXXXX") || fail 'Cannot create staging file'
CHECKLOG=$(mktemp "$DIR/.sing-box-check.XXXXXX") || fail 'Cannot create check log'
cleanup() { rm -f "$CANDIDATE" "$CHECKLOG"; }
trap cleanup EXIT

# Outbound tags in selectors, route rules, etc. cannot be silently discarded.
# Reject any dangling references to removed special outbound tags.
if ! jq -e '
    if (.outbounds | type) != "array" or (.route.rules | type) != "array" then
      error("expected outbounds[] and route.rules[] arrays")
    else . end
    | [.outbounds[] | select(.type == "dns" or .type == "block") | .tag] as $removed
    | .inbounds |= map(
        if .type == "ebpf" and .shared? != null and .shared.enabled == false
        then del(.shared) else . end
      )
    | .outbounds |= map(select(.type != "dns" and .type != "block"))
    | .route.rules |= map(
        if .action? == "sniff-override-destination" then .action = "sniff"
        elif . == {"action":"hijack-dns"} then
          {"type":"logical","mode":"or","rules":[{"protocol":"dns"},{"port":53}],"action":"hijack-dns"}
        else . end
      )
    | ([.route.final?]
       + [.. | objects | .outbound?, .detour?]
       + [.outbounds[]? | .default?, (.outbounds[]? | select(type=="string"))]
       | map(select(type=="string"))) as $references
    | if any($references[]; . as $tag | $removed | index($tag) != null) then
        error("removed legacy outbound tags remain referenced; migrate those rules or selectors manually")
      else . end
' "$CONFIG" > "$CANDIDATE"; then
    fail 'Could not migrate JSON automatically; original configuration untouched.'
fi

if cmp -s "$CONFIG" "$CANDIDATE"; then
    info 'No obsolete DNS/block/sniff settings to migrate.'
    exit 0
fi

# Match sbctl's working directory for relative rule-set/provider paths.
if ! (cd "$ROOT" && "$BIN" check -c "$CANDIDATE") > "$CHECKLOG" 2>&1; then
    printf '[ERROR] Kernel validation of migrated config failed:\n' >&2
    sed -n '1,45p' "$CHECKLOG" >&2
    fail 'Original config was NOT changed. Resolve the errors above before trying again.'
fi

BACKUP="$CONFIG.before-v113-migration.$(date +%Y%m%d-%H%M%S).$$.bak"
cp "$CONFIG" "$BACKUP" || fail 'Could not save configuration backup'
chmod 0600 "$BACKUP"
# Avoid clobbering a configuration modified while the check was running.
# Make another backup first; no background updater should write simultaneously.
mv -f "$CANDIDATE" "$CONFIG" || fail 'Could not replace configuration'
chmod 0600 "$CONFIG"
rm -f "$ROOT/runtime/config.valid" 2>/dev/null || true
info 'Legacy DNS/block outbounds removed and hijack/sniff rules migrated.'
info "Kernel check passed; backup: $BACKUP"
info 'Service was not restarted. Use sb → 服务管理 → 配置校验, then 重启 sing-box when ready.'
