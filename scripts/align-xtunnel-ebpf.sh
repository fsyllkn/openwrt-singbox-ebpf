#!/usr/bin/env bash
# Align local eBPF exclusions with currently running non-root X-Tunnel kernels.
set -euo pipefail

SCRIPT_FILE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_FILE")"
. "$SCRIPT_DIR/runtime-paths.sh"
sb_load_paths || exit 1
. "$SCRIPT_DIR/config-parts-lib.sh"
SB_CONFIG_PARTS_TOOL="${SB_CONFIG_PARTS_TOOL:-$SCRIPT_DIR/config-parts.sh}"
umask 077

ROOT="$SH_SINGBOX_HOME"
CONFIG="$SH_SINGBOX_CONFIG"
BIN="$ROOT/bin/sing-box"
PROC_ROOT="${SB_PROC_ROOT:-/proc}"
die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[sing-box] $*"; }

[ "$(id -u)" -eq 0 ] || die 'Run as root.'
sb_parts_prepare || die 'Cannot prepare managed configuration; correct the section files first.'
PARTS_FINGERPRINT=
if sb_parts_active; then
    PARTS_FINGERPRINT=$(sb_parts_fingerprint) || die 'Cannot snapshot managed configuration before editing.'
fi
[ -f "$CONFIG" ] && [ -x "$BIN" ] || die 'Missing sing-box config or binary.'
CONFIG="$(readlink -f "$CONFIG")" || die 'Cannot resolve the active config target.'
command -v jq >/dev/null || die 'jq required.'
command -v pidof >/dev/null || die 'pidof required.'

pids=$(pidof x-tunnel 2>/dev/null || true)
[ -n "$pids" ] || die 'No X-Tunnel kernel is running; start it under a dedicated UID first.'
uids=
for pid in $pids; do
    [ -r "$PROC_ROOT/$pid/status" ] || die "Cannot read PID $pid status."
    # Cgroup interception matches current real UID, while TC can match the
    # socket UID created from fsuid. Do not guess for setuid/mixed credentials.
    uid_fields=$(awk '/^Uid:/ { print $2, $3, $4, $5; exit }' "$PROC_ROOT/$pid/status")
    read -r uid effective_uid saved_uid fs_uid extra <<< "$uid_fields"
    for value in "$uid" "$effective_uid" "$saved_uid" "$fs_uid"; do
        case "$value" in ''|*[!0-9]*) die "Invalid UID fields for X-Tunnel PID $pid." ;; esac
        [ "$value" -ne 0 ] || die "X-Tunnel PID $pid retains root UID credentials; use a dedicated non-root account first."
    done
    [ -z "$extra" ] && [ "$uid" = "$effective_uid" ] &&
        [ "$uid" = "$saved_uid" ] && [ "$uid" = "$fs_uid" ] ||
        die "X-Tunnel PID $pid has different real/effective/saved/fs UIDs ($uid_fields); normalize its service credentials before automatic alignment."
    uids="${uids}${uid}
"
    info "Found X-Tunnel kernel PID $pid, UID $uid"
done
uid_json=$(printf '%s' "$uids" | jq -R -s 'split("\n") | map(select(length>0) | tonumber) | unique') ||
    die 'Could not serialize X-Tunnel UIDs.'
stage=$(mktemp "$(dirname "$CONFIG")/.xt-ebpf.XXXXXX") || die 'Cannot stage config.'
checklog=$(mktemp "$(dirname "$CONFIG")/.xt-check.XXXXXX") || die 'Cannot stage log.'
cleanup() { rm -f "$stage" "$checklog"; }
trap cleanup EXIT

jq --argjson uids "$uid_json" '
  def local_enabled:
    .local.enabled==true or (.local.enabled==null and .shared.enabled==null);
  if (any(.inbounds[]?; .type=="ebpf" and local_enabled) | not) then
    error("No enabled eBPF local inbound; refusing to edit")
  else . end
  | .inbounds |= map(
      if .type=="ebpf" and local_enabled then
          .local.exclude_uid |= ((if type=="array" then . elif .==null then [] else [.] end) + $uids | unique)
      else . end
    )
' "$CONFIG" > "$stage" || die 'Cannot construct a safe eBPF configuration.'
if ! (cd "$ROOT" && "$BIN" check -c "$stage") >"$checklog" 2>&1; then
    echo '[ERROR] New eBPF config failed kernel validation:' >&2
    sed -n '1,45p' "$checklog" >&2
    die 'Original config untouched.'
fi
if cmp -s "$CONFIG" "$stage"; then
    info 'UID exclusions already match X-Tunnel kernels; no change.'
    exit 0
fi
backup="$CONFIG.before-xt-ebpf.$(date +%Y%m%d-%H%M%S).$$.bak"
cp -p "$CONFIG" "$backup" || die 'Backup failed.'
chmod 0600 "$backup"
if [ -n "$PARTS_FINGERPRINT" ]; then
    SB_CONFIG_PARTS_EXPECTED="$PARTS_FINGERPRINT" sb_parts_commit "$stage" inbounds ||
        die 'Could not save managed inbounds; another edit may have changed the source. Review and retry.'
else
    sb_parts_active && die 'Configuration mode changed while editing; review and retry.'
    mv -f "$stage" "$CONFIG" || die 'Could not replace configuration.'
    chmod 0600 "$CONFIG"
fi
rm -f "$ROOT/runtime/config.valid" 2>/dev/null || true
info "Config validated and updated; backup: $backup"
info "Excluded X-Tunnel UIDs: $uid_json"
info 'No restart performed. Use sb → 服务管理 → 配置校验, then 重启 sing-box when ready.'
