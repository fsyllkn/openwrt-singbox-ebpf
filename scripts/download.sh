#!/bin/sh
# Shared download policy. Sourcing this file only defines functions.
# All proxy environment changes are confined to the child executing a command.

_sb_download_error() {
    printf 'download: %s\n' "$*" >&2
}

_sb_download_uci_dir_valid() {
    case "${SB_DOWNLOAD_UCI_DIR:-/etc/config}" in
        /*) return 0 ;;
        *) _sb_download_error 'SB_DOWNLOAD_UCI_DIR must be an absolute directory.'; return 1 ;;
    esac
}

_sb_download_uci() {
    if [ -n "${SB_DOWNLOAD_UCI_DIR:-}" ]; then
        uci -c "$SB_DOWNLOAD_UCI_DIR" "$@"
    else
        uci "$@"
    fi
}

_sb_download_url_chars_valid() (
    [ -n "$1" ] || exit 1
    # Raw quotes/backslashes are not valid configuration input. Percent-encode
    # these characters in credentials; never interpret URL text as shell code.
    case "$1" in *\\*|*\"*|*"'"*|*\`*) exit 1 ;; esac
    if printf '%s' "$1" | LC_ALL=C grep -q '[[:space:][:cntrl:]]'; then
        exit 1
    fi
)

_sb_download_authority_valid() (
    sb_dl_authority=$1
    case "$sb_dl_authority" in
        *@*)
            [ -n "${sb_dl_authority%@*}" ] || exit 1
            case "${sb_dl_authority%@*}" in *@*) exit 1 ;; esac
            sb_dl_authority=${sb_dl_authority##*@}
            ;;
    esac
    sb_dl_port=
    case "$sb_dl_authority" in
        \[*\]*)
            sb_dl_host=${sb_dl_authority#\[}
            sb_dl_host=${sb_dl_host%%\]*}
            case "$sb_dl_host" in ''|*[!0-9A-Fa-f:.]*) exit 1 ;; esac
            case "${sb_dl_authority#*\]}" in
                '') ;;
                :*) sb_dl_port=${sb_dl_authority#*\]:}; [ -n "$sb_dl_port" ] || exit 1 ;;
                *) exit 1 ;;
            esac
            ;;
        *)
            sb_dl_host=${sb_dl_authority%%:*}
            case "$sb_dl_host" in ''|*[!A-Za-z0-9._-]*) exit 1 ;; esac
            case "$sb_dl_authority" in
                *:*) sb_dl_port=${sb_dl_authority#*:}; [ -n "$sb_dl_port" ] || exit 1 ;;
            esac
            ;;
    esac
    if [ -n "$sb_dl_port" ]; then
        case "$sb_dl_port" in *[!0-9]*) exit 1 ;; esac
        [ "${#sb_dl_port}" -le 5 ] && [ "$sb_dl_port" -ge 1 ] && [ "$sb_dl_port" -le 65535 ] || exit 1
    fi
)

_sb_download_http_proxy_valid() (
    _sb_download_url_chars_valid "$1" || exit 1
    case "$1" in http://*) ;; *) exit 1 ;; esac
    case "$1" in *\?*|*\#*) exit 1 ;; esac
    sb_dl_rest=${1#http://}
    sb_dl_authority=${sb_dl_rest%%/*}
    case "$sb_dl_rest" in "$sb_dl_authority"|"$sb_dl_authority/") ;; *) exit 1 ;; esac
    _sb_download_authority_valid "$sb_dl_authority"
)

_sb_download_github_proxy_valid() (
    _sb_download_url_chars_valid "$1" || exit 1
    case "$1" in https://*) ;; *) exit 1 ;; esac
    case "$1" in *\?*|*\#*) exit 1 ;; esac
    sb_dl_rest=${1#https://}
    sb_dl_authority=${sb_dl_rest%%/*}
    case "$sb_dl_authority" in *@*) exit 1 ;; esac
    _sb_download_authority_valid "$sb_dl_authority"
)

sb_download_load() {
    SB_DOWNLOAD_MODE_RESOLVED=
    SB_DOWNLOAD_HTTP_PROXY_RESOLVED=
    SB_DOWNLOAD_GITHUB_PROXY_RESOLVED=
    SB_DOWNLOAD_SOURCE_RESOLVED=default
    _sb_download_uci_dir_valid || return 1

    # Environment URL inference intentionally wins over a saved UCI mode. Two
    # simultaneous URLs require an explicit mode instead of guessing a route.
    if [ "${SB_DOWNLOAD_MODE+x}" = x ]; then
        SB_DOWNLOAD_MODE_RESOLVED=$SB_DOWNLOAD_MODE
        SB_DOWNLOAD_SOURCE_RESOLVED=environment
    elif [ -n "${SB_HTTP_PROXY:-}" ] && [ -n "${SB_GITHUB_PROXY:-}" ]; then
        _sb_download_error 'Set SB_DOWNLOAD_MODE when both proxy URLs are supplied.'
        return 1
    elif [ -n "${SB_HTTP_PROXY:-}" ]; then
        SB_DOWNLOAD_MODE_RESOLVED=http
        SB_DOWNLOAD_SOURCE_RESOLVED=environment
    elif [ -n "${SB_GITHUB_PROXY:-}" ]; then
        SB_DOWNLOAD_MODE_RESOLVED=github
        SB_DOWNLOAD_SOURCE_RESOLVED=environment
    elif command -v uci >/dev/null 2>&1; then
        if SB_DOWNLOAD_MODE_RESOLVED=$(_sb_download_uci -q get sing-box.download.mode 2>/dev/null); then
            SB_DOWNLOAD_SOURCE_RESOLVED=UCI
        else
            SB_DOWNLOAD_MODE_RESOLVED=direct
        fi
    else
        SB_DOWNLOAD_MODE_RESOLVED=direct
    fi

    case "$SB_DOWNLOAD_MODE_RESOLVED" in
        direct) ;;
        http)
            if [ "${SB_HTTP_PROXY+x}" = x ]; then
                SB_DOWNLOAD_HTTP_PROXY_RESOLVED=$SB_HTTP_PROXY
            elif command -v uci >/dev/null 2>&1; then
                SB_DOWNLOAD_HTTP_PROXY_RESOLVED=$(_sb_download_uci -q get sing-box.download.http_proxy 2>/dev/null) || SB_DOWNLOAD_HTTP_PROXY_RESOLVED=
            fi
            if ! _sb_download_http_proxy_valid "$SB_DOWNLOAD_HTTP_PROXY_RESOLVED"; then
                _sb_download_error 'HTTP mode requires an http://[user:password@]host[:port] proxy URL; percent-encode special characters.'
                return 1
            fi
            ;;
        github)
            if [ "${SB_GITHUB_PROXY+x}" = x ]; then
                SB_DOWNLOAD_GITHUB_PROXY_RESOLVED=$SB_GITHUB_PROXY
            elif command -v uci >/dev/null 2>&1; then
                SB_DOWNLOAD_GITHUB_PROXY_RESOLVED=$(_sb_download_uci -q get sing-box.download.github_proxy 2>/dev/null) || SB_DOWNLOAD_GITHUB_PROXY_RESOLVED=
            fi
            if ! _sb_download_github_proxy_valid "$SB_DOWNLOAD_GITHUB_PROXY_RESOLVED"; then
                _sb_download_error 'GitHub mode requires an https:// prefix without user credentials, query, or fragment.'
                return 1
            fi
            case "$SB_DOWNLOAD_GITHUB_PROXY_RESOLVED" in
                */) ;;
                *) SB_DOWNLOAD_GITHUB_PROXY_RESOLVED=$SB_DOWNLOAD_GITHUB_PROXY_RESOLVED/ ;;
            esac
            ;;
        *) _sb_download_error 'Download mode must be direct, http, or github.'; return 1 ;;
    esac
    return 0
}

_sb_download_http_environment() {
    http_proxy=$SB_DOWNLOAD_HTTP_PROXY_RESOLVED
    https_proxy=$SB_DOWNLOAD_HTTP_PROXY_RESOLVED
    all_proxy=$SB_DOWNLOAD_HTTP_PROXY_RESOLVED
    HTTP_PROXY=$SB_DOWNLOAD_HTTP_PROXY_RESOLVED
    HTTPS_PROXY=$SB_DOWNLOAD_HTTP_PROXY_RESOLVED
    ALL_PROXY=$SB_DOWNLOAD_HTTP_PROXY_RESOLVED
    # An explicit project HTTP proxy must not be silently bypassed by a parent
    # no_proxy value. These assignments happen only inside a child subshell.
    no_proxy= NO_PROXY=
    export http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
}

sb_download_run() (
    [ "$#" -gt 0 ] || { _sb_download_error 'A command is required.'; exit 1; }
    sb_download_load || exit 1
    if [ "$SB_DOWNLOAD_MODE_RESOLVED" = http ]; then
        _sb_download_http_environment
    fi
    "$@"
)

sb_download() (
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || {
        _sb_download_error 'Usage: sb_download URL DEST [TIMEOUT_SECONDS]'; exit 1;
    }
    sb_download_load || exit 1
    sb_dl_url=$1
    sb_dl_dest=$2
    sb_dl_timeout=${3:-180}
    case "$sb_dl_timeout" in ''|*[!0-9]*) _sb_download_error 'Timeout must be a positive number of seconds.'; exit 1 ;; esac
    [ "${#sb_dl_timeout}" -le 5 ] && [ "$sb_dl_timeout" -gt 0 ] || {
        _sb_download_error 'Timeout must be between 1 and 99999 seconds.'; exit 1;
    }
    _sb_download_url_chars_valid "$sb_dl_url" || { _sb_download_error 'Invalid download URL.'; exit 1; }
    case "$sb_dl_url" in http://*|https://*) ;; *) _sb_download_error 'Only HTTP(S) download URLs are supported.'; exit 1 ;; esac
    sb_dl_rest=${sb_dl_url#*://}
    sb_dl_authority=${sb_dl_rest%%/*}
    sb_dl_authority=${sb_dl_authority%%\?*}
    sb_dl_authority=${sb_dl_authority%%\#*}
    case "$sb_dl_authority" in *@*) _sb_download_error 'Download URLs must not contain user credentials.'; exit 1 ;; esac
    _sb_download_authority_valid "$sb_dl_authority" || { _sb_download_error 'Invalid download host.'; exit 1; }
    sb_dl_host=$(printf '%s' "$sb_dl_authority" | LC_ALL=C tr 'A-Z' 'a-z')
    sb_dl_effective_url=$sb_dl_url
    if [ "$SB_DOWNLOAD_MODE_RESOLVED" = github ]; then
        case "$sb_dl_url" in
            https://*)
                case "$sb_dl_host" in
                    github.com|github.com:443|raw.githubusercontent.com|raw.githubusercontent.com:443|codeload.github.com|codeload.github.com:443)
                        case "$sb_dl_url" in
                            *\?*|*\#*) _sb_download_error 'GitHub accelerator URLs must be public and have no query or fragment.'; exit 1 ;;
                        esac
                        sb_dl_effective_url=$SB_DOWNLOAD_GITHUB_PROXY_RESOLVED$sb_dl_url
                        ;;
                esac
                ;;
        esac
    fi

    # Prefer curl. The default OpenWrt uclient-fetch and BusyBox wget do not
    # implement HTTPS CONNECT through an HTTP proxy. A successful mock is not
    # evidence of that capability; only GNU Wget is accepted for this fallback.
    sb_dl_client=
    sb_dl_gnu_wget=0
    if command -v curl >/dev/null 2>&1; then
        sb_dl_client=curl
    elif command -v wget >/dev/null 2>&1; then
        sb_dl_client=wget
        sb_dl_wget_version=$(wget --version 2>/dev/null) || sb_dl_wget_version=
        case "$sb_dl_wget_version" in *'GNU Wget '*) sb_dl_gnu_wget=1 ;; esac
        if [ "$SB_DOWNLOAD_MODE_RESOLVED" = http ] && [ "$sb_dl_gnu_wget" -ne 1 ]; then
            case "$sb_dl_effective_url" in
                https://*)
                    _sb_download_error 'HTTPS through an HTTP proxy requires curl or GNU Wget. Install curl first; OpenWrt/BusyBox wget cannot provide this CONNECT tunnel.'
                    exit 1
                    ;;
            esac
        fi
    else
        _sb_download_error 'Install curl or wget before downloading.'
        exit 1
    fi

    case "$sb_dl_dest" in '') _sb_download_error 'A destination file is required.'; exit 1 ;; -*) sb_dl_dest=./$sb_dl_dest ;; esac
    [ ! -d "$sb_dl_dest" ] || { _sb_download_error 'The download destination is a directory.'; exit 1; }
    umask 077
    sb_dl_stage=$(mktemp "$sb_dl_dest.download.XXXXXX") || { _sb_download_error 'Cannot create a download staging file.'; exit 1; }
    trap 'rm -f "$sb_dl_stage"' 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$SB_DOWNLOAD_MODE_RESOLVED" = http ]; then
        _sb_download_http_environment
    fi

    sb_dl_status=0
    if [ "$sb_dl_client" = curl ]; then
        sb_dl_connect_timeout=$sb_dl_timeout
        [ "$sb_dl_connect_timeout" -le 15 ] || sb_dl_connect_timeout=15
        # -q must be the first option: do not inherit credentials/headers from
        # .curlrc when sending a public URL to a selected GitHub accelerator.
        curl -q --fail --location --silent --connect-timeout "$sb_dl_connect_timeout" \
            --max-time "$sb_dl_timeout" --output "$sb_dl_stage" -- "$sb_dl_effective_url" \
            2>/dev/null || sb_dl_status=$?
    else
        set -- wget -q -T "$sb_dl_timeout" -O "$sb_dl_stage"
        if [ "$sb_dl_gnu_wget" -eq 1 ]; then
            set -- "$@" --no-config --no-netrc --tries=1
        fi
        set -- "$@" -- "$sb_dl_effective_url"
        # Minimal wget -T is a connection/request timeout, not a total transfer
        # deadline. Use timeout when available, without making it a dependency.
        if command -v timeout >/dev/null 2>&1; then
            timeout "$sb_dl_timeout" "$@" 2>/dev/null || sb_dl_status=$?
        else
            "$@" 2>/dev/null || sb_dl_status=$?
        fi
    fi
    if [ "$sb_dl_status" -ne 0 ]; then
        _sb_download_error "Download failed in $SB_DOWNLOAD_MODE_RESOLVED mode ($sb_dl_client exit $sb_dl_status); no fallback was attempted."
        exit "$sb_dl_status"
    fi
    mv -f "$sb_dl_stage" "$sb_dl_dest" || { _sb_download_error 'Cannot install the completed download.'; exit 1; }
)
