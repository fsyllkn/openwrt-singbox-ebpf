#!/usr/bin/env bash
# =============================================================================
# update-rules.sh — Update DustinWin rule-sets and subscription providers
# =============================================================================
set -euo pipefail

SCRIPT_FILE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
. "$(dirname "$SCRIPT_FILE")/runtime-paths.sh"
sb_load_paths || exit 1
. "$(dirname "$SCRIPT_FILE")/download.sh"
sb_download_load || exit 1

SERVICE_DIR="$SH_SINGBOX_HOME"
GEO_DIR="$SERVICE_DIR/geo"
CONFIG="$SH_SINGBOX_CONFIG"

ok()   { echo -e "\033[32m✓\033[0m $*"; }
err()  { echo -e "\033[31m✗\033[0m $*" >&2; }
warn() { echo -e "\033[33m!\033[0m $*"; }
info() { echo -e "\033[36mℹ\033[0m $*"; }

mkdir -p "$GEO_DIR"

RULES=(
    "cnip.srs"
    "private.srs"
    "cn.srs"
    "google-cn.srs"
    "apple-cn.srs"
    "games-cn.srs"
    "ads.srs"
    "networktest.srs"
)

BASE_URL="https://github.com/DustinWin/ruleset_geodata/releases/download/sing-box-ruleset"

download_rule() {
    local rule="$1"
    local dest="$GEO_DIR/$rule"
    local tmp="$dest.tmp"

    local direct_url="$BASE_URL/$rule"
    if sb_download "$direct_url" "$tmp" 60; then
        mv -f "$tmp" "$dest"
        ok "Updated: $rule"
        return 0
    else
        rm -f "$tmp" 2>/dev/null
        warn "Failed to update: $rule"
        return 1
    fi
}

info "Updating DustinWin rule-sets..."
for r in "${RULES[@]}"; do
    download_rule "$r" || true
done

# If the configured Clash API is available, trigger provider updates. Do not
# guess a port, depend on grep -P, or expose an API secret in argv.
update_providers() (
    umask 077
    [ -f "$CONFIG" ] || return 0
    command -v jq >/dev/null 2>&1 || { warn 'jq unavailable; provider API update skipped.'; return 0; }
    local api_addr api_host api_port api_url auth_file providers p
    api_addr=$(jq -r '.experimental.clash_api.external_controller // empty' "$CONFIG") || {
        warn 'Cannot read configured Clash API; provider update skipped.'; return 0;
    }
    [ -n "$api_addr" ] || return 0
    if [[ "$api_addr" =~ ^(\[[^]]+\]|[^/:[:space:]]*):([0-9]{1,5})$ ]]; then
        api_host=${BASH_REMATCH[1]}
        api_port=${BASH_REMATCH[2]}
    else
        warn 'Configured Clash API is not a host:port listener; provider update skipped.'
        return 0
    fi
    (( 10#$api_port >= 1 && 10#$api_port <= 65535 )) || {
        warn 'Invalid configured Clash API port; provider update skipped.'; return 0;
    }
    case "$api_host" in ''|0.0.0.0) api_host=127.0.0.1 ;; '[::]') api_host='[::1]' ;; esac
    api_url="http://$api_host:$api_port"
    auth_file=$(mktemp /tmp/sb-rule-api-header.XXXXXX) || { warn 'Cannot stage API credentials; provider update skipped.'; return 0; }
    trap 'rm -f "$auth_file"' EXIT
    if ! jq -jr '
        (.experimental.clash_api.secret // "") as $secret
        | if ($secret|type)!="string" or ($secret|test("[\r\n]")) then error("invalid API secret format")
          elif $secret=="" then "" else "Authorization: Bearer " + $secret + "\n" end
    ' "$CONFIG" > "$auth_file"; then
        warn 'Cannot prepare API authentication; provider update skipped.'
        return 0
    fi
    api_request() {
        curl --silent --show-error --fail --noproxy '*' --connect-timeout 2 --max-time 15 \
            --header "@$auth_file" "$@"
    }
    if ! api_request "$api_url/version" >/dev/null 2>&1; then
        warn "Clash API unavailable or authentication failed at $api_url; provider update skipped."
        return 0
    fi
    providers=$(api_request "$api_url/providers/proxies" | jq -r '.providers // {} | keys[] | @uri') || {
        warn 'Cannot list proxy providers; provider update skipped.'; return 0;
    }
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if api_request -X PUT "$api_url/providers/proxies/$p" >/dev/null 2>&1; then
            ok "Triggered reload for provider: $p"
        else
            warn "Provider reload failed: $p"
        fi
    done <<< "$providers"
)
update_providers

ok "Rule update routine completed"
