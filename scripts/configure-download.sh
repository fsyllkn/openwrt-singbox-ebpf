#!/bin/sh
# Persist project download settings without placing proxy credentials in argv.
set -eu
SB_DOWNLOAD_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if [ ! -r "$SB_DOWNLOAD_SCRIPT_DIR/download.sh" ]; then
    printf '%s\n' 'download: missing download.sh; deploy the complete scripts directory.' >&2
    exit 1
fi
. "$SB_DOWNLOAD_SCRIPT_DIR/download.sh"

usage() {
    printf '%s\n' \
        'Usage: configure-download.sh show' \
        '       configure-download.sh set direct' \
        '       configure-download.sh set http URL | set http --stdin' \
        '       configure-download.sh set github PREFIX | set github --stdin' \
        '       configure-download.sh clear' \
        'Use --stdin to keep an authenticated proxy URL out of process arguments.'
}

redacted_proxy() (
    sb_dl_show_scheme=${1%%://*}
    sb_dl_show_authority=${1#*://}
    sb_dl_show_authority=${sb_dl_show_authority%%/*}
    case "$sb_dl_show_authority" in
        *@*) sb_dl_show_authority=***@${sb_dl_show_authority##*@} ;;
    esac
    printf '%s://%s\n' "$sb_dl_show_scheme" "$sb_dl_show_authority"
)

require_uci_write() {
    _sb_download_uci_dir_valid || exit 1
    command -v uci >/dev/null 2>&1 || { _sb_download_error 'Persistent settings require OpenWrt UCI.'; exit 1; }
    [ "$(id -u)" -eq 0 ] || { _sb_download_error 'Run as root to save download settings.'; exit 1; }
    sb_dl_config_dir=${SB_DOWNLOAD_UCI_DIR:-/etc/config}
    umask 077
    mkdir -p "$sb_dl_config_dir" || exit 1
    if [ ! -e "$sb_dl_config_dir/sing-box" ]; then
        # UCI set cannot create a missing package. Create an empty private
        # package first; this also supports configuring downloads before install.
        : > "$sb_dl_config_dir/sing-box" || exit 1
    fi
    chmod 600 "$sb_dl_config_dir/sing-box" || exit 1
}

saved_settings_match() {
    sb_dl_check=$(_sb_download_uci -q get sing-box.download 2>/dev/null) || return 1
    [ "$sb_dl_check" = download ] || return 1
    sb_dl_check=$(_sb_download_uci -q get sing-box.download.mode 2>/dev/null) || return 1
    [ "$sb_dl_check" = "$sb_dl_mode" ] || return 1
    case "$sb_dl_mode" in
        http)
            sb_dl_check=$(_sb_download_uci -q get sing-box.download.http_proxy 2>/dev/null) || return 1
            [ "$sb_dl_check" = "$sb_dl_value" ] || return 1
            if _sb_download_uci -q get sing-box.download.github_proxy >/dev/null 2>&1; then return 1; fi
            ;;
        github)
            sb_dl_check=$(_sb_download_uci -q get sing-box.download.github_proxy 2>/dev/null) || return 1
            [ "$sb_dl_check" = "$sb_dl_value" ] || return 1
            if _sb_download_uci -q get sing-box.download.http_proxy >/dev/null 2>&1; then return 1; fi
            ;;
        direct)
            if _sb_download_uci -q get sing-box.download.http_proxy >/dev/null 2>&1; then return 1; fi
            if _sb_download_uci -q get sing-box.download.github_proxy >/dev/null 2>&1; then return 1; fi
            ;;
    esac
    return 0
}

save_failed() {
    # Leave other sections and their pending edits alone. Do not leave a failed
    # password update in UCI's pending download section for a later commit.
    _sb_download_uci -q revert sing-box.download >/dev/null 2>&1 || :
    _sb_download_error 'Could not save download settings with UCI.'
    exit 1
}

case "${1:-show}" in
    show)
        [ "$#" -le 1 ] || { usage >&2; exit 1; }
        sb_download_load || exit 1
        printf 'Download mode: %s\nSource: %s\n' "$SB_DOWNLOAD_MODE_RESOLVED" "$SB_DOWNLOAD_SOURCE_RESOLVED"
        case "$SB_DOWNLOAD_MODE_RESOLVED" in
            direct) printf '%s\n' 'No project proxy is set; standard system proxy variables are inherited.' ;;
            http)
                printf 'HTTP proxy: '
                redacted_proxy "$SB_DOWNLOAD_HTTP_PROXY_RESOLVED"
                printf '%s\n' 'Only download/package/git child commands receive this proxy; HTTPS requires curl or GNU Wget.'
                ;;
            github)
                printf 'GitHub prefix (path hidden): '
                redacted_proxy "$SB_DOWNLOAD_GITHUB_PROXY_RESOLVED"
                printf '%s\n' 'Only public github.com, raw.githubusercontent.com and codeload.github.com URLs use this prefix.' \
                    'api.github.com and other domains keep their original URLs and standard system proxy environment.'
                ;;
        esac
        ;;
    set)
        sb_dl_mode=${2:-}
        sb_dl_value=
        case "$sb_dl_mode" in
            direct) [ "$#" -eq 2 ] || { usage >&2; exit 1; } ;;
            http|github)
                [ "$#" -eq 3 ] || { usage >&2; exit 1; }
                if [ "$3" = --stdin ]; then
                    IFS= read -r sb_dl_value || [ -n "$sb_dl_value" ] || { _sb_download_error 'Expected one proxy URL on standard input.'; exit 1; }
                    sb_dl_extra=
                    if IFS= read -r sb_dl_extra || [ -n "$sb_dl_extra" ]; then
                        _sb_download_error 'Expected exactly one proxy URL on standard input.'
                        exit 1
                    fi
                else
                    sb_dl_value=$3
                fi
                if [ "$sb_dl_mode" = http ]; then
                    _sb_download_http_proxy_valid "$sb_dl_value" || { _sb_download_error 'Invalid HTTP proxy URL; use http://[user:password@]host[:port].'; exit 1; }
                else
                    _sb_download_github_proxy_valid "$sb_dl_value" || { _sb_download_error 'Invalid GitHub HTTPS prefix; credentials, queries and fragments are not allowed.'; exit 1; }
                    case "$sb_dl_value" in */) ;; *) sb_dl_value=$sb_dl_value/ ;; esac
                fi
                ;;
            *) usage >&2; exit 1 ;;
        esac
        require_uci_write
        sb_dl_delete_http=0 sb_dl_delete_github=0
        _sb_download_uci -q get sing-box.download.http_proxy >/dev/null 2>&1 && sb_dl_delete_http=1
        _sb_download_uci -q get sing-box.download.github_proxy >/dev/null 2>&1 && sb_dl_delete_github=1
        # URL validation excludes raw single quotes/newlines. UCI's batch input
        # is data (not a shell); the value never appears in uci process argv.
        if ! {
            printf 'set sing-box.download=download\nset sing-box.download.mode=%s\n' "$sb_dl_mode"
            if [ "$sb_dl_delete_http" -eq 1 ]; then printf 'delete sing-box.download.http_proxy\n'; fi
            if [ "$sb_dl_delete_github" -eq 1 ]; then printf 'delete sing-box.download.github_proxy\n'; fi
            case "$sb_dl_mode" in
                http) printf "set sing-box.download.http_proxy='%s'\n" "$sb_dl_value" ;;
                github) printf "set sing-box.download.github_proxy='%s'\n" "$sb_dl_value" ;;
            esac
        } | _sb_download_uci -q batch 2>/dev/null; then
            save_failed
        fi
        # The real UCI batch command returns 0 even when a contained command
        # fails. Read back all settings, then commit with a separate command so
        # write/space/permission errors cannot be mistaken for a successful save.
        saved_settings_match || save_failed
        _sb_download_uci -q commit sing-box 2>/dev/null || save_failed
        chmod 600 "$sb_dl_config_dir/sing-box" || exit 1
        printf 'Saved download mode: %s. No service was restarted.\n' "$sb_dl_mode"
        ;;
    clear)
        [ "$#" -eq 1 ] || { usage >&2; exit 1; }
        require_uci_write
        if _sb_download_uci -q get sing-box.download >/dev/null 2>&1; then
            _sb_download_uci -q delete sing-box.download 2>/dev/null || save_failed
            _sb_download_uci -q commit sing-box 2>/dev/null || save_failed
        fi
        if [ -e "$sb_dl_config_dir/sing-box" ]; then chmod 600 "$sb_dl_config_dir/sing-box" || exit 1; fi
        printf '%s\n' 'Saved download settings cleared. Environment overrides, if present, still apply.'
        ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 1 ;;
esac
