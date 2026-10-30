#!/bin/sh
# Functions only. Call sb_load_paths before using this library.

sb_parts_dir() (
    case "${SH_SINGBOX_CONFIG:-}" in
        '') printf '%s\n' 'config-parts: SH_SINGBOX_CONFIG is not set.' >&2; exit 1 ;;
        *.json) printf '%s.d\n' "${SH_SINGBOX_CONFIG%.json}" ;;
        *) printf '%s.d\n' "$SH_SINGBOX_CONFIG" ;;
    esac
)

sb_parts_active() (
    sb_parts_path=$(sb_parts_dir) || exit 1
    [ -e "$sb_parts_path" ] || [ -L "$sb_parts_path" ]
)

_sb_parts_run() (
    sb_parts_tool=${SB_CONFIG_PARTS_TOOL:-${SH_SINGBOX_HOME:-/opt/sing-box}/scripts/config-parts.sh}
    [ -r "$sb_parts_tool" ] || {
        printf '%s\n' 'config-parts: missing configuration tool; deploy the complete scripts directory.' >&2
        exit 1
    }
    command -v bash >/dev/null 2>&1 || { printf '%s\n' 'config-parts: bash is required.' >&2; exit 1; }
    bash "$sb_parts_tool" "$@"
)

sb_parts_prepare() (
    if sb_parts_active; then _sb_parts_run render; fi
)

sb_parts_fingerprint() (
    sb_parts_active || { printf '%s\n' 'config-parts: fingerprint requires an active parts directory.' >&2; exit 1; }
    _sb_parts_run fingerprint
)

sb_parts_commit() (
    sb_parts_active || { printf '%s\n' 'config-parts: commit requires an active parts directory.' >&2; exit 1; }
    _sb_parts_run commit "$@"
)

sb_parts_set() (
    sb_parts_active || { printf '%s\n' 'config-parts: set requires an active parts directory.' >&2; exit 1; }
    _sb_parts_run set "$@"
)

sb_parts_import() (
    sb_parts_active || { printf '%s\n' 'config-parts: import requires an active parts directory.' >&2; exit 1; }
    _sb_parts_run import "$@"
)
