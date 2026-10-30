#!/bin/sh
# Git-free bootstrap for fsyllkn/openwrt-singbox-ebpf (main).
# Download this one file, then use direct/HTTP/GitHub-proxy downloads or an
# offline source archive. No repository credentials are needed.
set -eu

error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[sing-box] %s\n' "$*"; }
# BEGIN SHARED DOWNLOAD LIBRARY
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
# END SHARED DOWNLOAD LIBRARY

usage() {
    cat <<'EOF'
Usage: sh quick-install.sh [--archive FILE|--source DIRECTORY] [--update] [--no-menu]
                          [--direct|--http-proxy URL|--github-proxy PREFIX]

Default: use an existing local source tree, or download the public main branch
from fsyllkn/openwrt-singbox-ebpf. No Git required.
--archive: use an already-downloaded branch archive completely offline.
           ZIP requires unzip; tar.gz only needs tar.
--source:  copy the project source tree from a local directory.
--update:  refresh managed source files without touching installed services.
--no-menu: return after preparing source and registering the sb shortcut.
--direct: no project proxy override; standard system proxy environment remains.
--http-proxy: use a local/network HTTP proxy for this invocation and menu.
--github-proxy: prefix public GitHub download URLs for this invocation and menu.
Permanent download settings are available in menu option 24.
EOF
}
[ "$(id -u)" -eq 0 ] || error 'Run as root.'
[ -f /etc/openwrt_release ] || error 'This distribution requires OpenWrt/procd.'

if [ -d /overlay ]; then
    BASE=/overlay/openwrt-singbox-ebpf
else
    BASE=/root/openwrt-singbox-ebpf
fi
TARGET=${SB_INSTALL_SOURCE_DIR:-$BASE}
validate_source_target() {
    case "$1" in
        /*) ;;
        *) error 'SB_INSTALL_SOURCE_DIR must be an absolute directory.' ;;
    esac
    # Spaces are supported by every copy/launcher path. Reject shell expansion
    # characters because the launcher embeds this directory in double quotes.
    case "$1" in
        *[!a-zA-Z0-9_./\ -]*) error 'Source directory may contain letters, digits, spaces and _ . / - only.' ;;
    esac
}
validate_source_target "$TARGET"

ARCHIVE=
SOURCE=
UPDATE=0
OPEN_MENU=1
DOWNLOAD_OPTION_SEEN=0
set_download_option() {
    [ "$DOWNLOAD_OPTION_SEEN" -eq 0 ] || error 'Choose only one download mode option.'
    DOWNLOAD_OPTION_SEEN=1
    SB_DOWNLOAD_MODE=$1
    export SB_DOWNLOAD_MODE
    case "$1" in
        http) SB_HTTP_PROXY=$2; export SB_HTTP_PROXY ;;
        github) SB_GITHUB_PROXY=$2; export SB_GITHUB_PROXY ;;
    esac
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --archive)
            [ "$#" -ge 2 ] || error '--archive requires a path.'
            ARCHIVE=$2
            shift 2 ;;
        --source)
            [ "$#" -ge 2 ] || error '--source requires a path.'
            SOURCE=$2
            shift 2 ;;
        --update) UPDATE=1; shift ;;
        --no-menu) OPEN_MENU=0; shift ;;
        --direct) set_download_option direct; shift ;;
        --http-proxy|--github-proxy)
            [ "$#" -ge 2 ] || error "$1 requires a URL."
            case "$1" in
                --http-proxy) set_download_option http "$2" ;;
                --github-proxy) set_download_option github "$2" ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown argument: $1" ;;
    esac
done
[ -z "$ARCHIVE" ] || [ -z "$SOURCE" ] || error 'Use either --archive or --source.'
if [ "$OPEN_MENU" -eq 1 ]; then
    [ -t 0 ] || error 'An interactive SSH terminal is required (or use --no-menu).'
fi

TMP=
cleanup() {
    [ -z "$TMP" ] || rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM
validate_source() {
    [ -f "$1/quick-install.sh" ] &&
    [ -f "$1/menu.sh" ] &&
    [ -f "$1/install.sh" ] &&
    [ -f "$1/uninstall.sh" ] &&
    [ -f "$1/scripts/sbctl" ] &&
    [ -f "$1/scripts/runtime-paths.sh" ] &&
    [ -f "$1/scripts/download.sh" ] &&
    [ -f "$1/scripts/configure-download.sh" ] &&
    [ -f "$1/scripts/gateway.sh" ] &&
    [ -f "$1/scripts/dns-guard.sh" ] &&
    [ -f "$1/scripts/update-core.sh" ] &&
    [ -f "$1/openwrt/sing-box.init" ] &&
    [ -f "$1/config/config.template.json" ]
}
download_archive() {
    dest=$1
    url=https://github.com/fsyllkn/openwrt-singbox-ebpf/archive/refs/heads/main.tar.gz
    info 'Downloading public main branch source archive (no Git)...'
    sb_download "$url" "$dest" 180 ||
        error 'Source download failed. Check the selected proxy, or use --archive with a local ZIP/TAR.GZ.'
}
unpack_archive() {
    archive=$1
    dest=$2
    [ -f "$archive" ] || error "Archive not found: $archive"
    case "$archive" in
        *.zip|*.ZIP)
            command -v unzip >/dev/null 2>&1 ||
                error 'ZIP extraction needs unzip (opkg install unzip / apk add unzip).'
            unzip -q "$archive" -d "$dest" || error 'Could not unpack ZIP.' ;;
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$dest" || error 'Could not unpack tar.gz.' ;;
        *) error 'Archive must be a GitHub .zip, .tar.gz, or .tgz.' ;;
    esac
    FOUND=
    for d in "$dest"/*; do
        if [ -d "$d" ] && validate_source "$d"; then
            [ -z "$FOUND" ] || error 'Multiple source trees in archive.'
            FOUND=$d
        fi
    done
    [ -n "$FOUND" ] || error 'Archive does not contain a valid openwrt source tree.'
    SOURCE=$FOUND
}

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || error 'Cannot resolve script directory.'
# Without explicit inputs, opening sb or rerunning this file uses local
# source. --update instead fetches a fresh archive unless it is supplied.
if [ -z "$SOURCE" ] && [ -z "$ARCHIVE" ] && [ "$UPDATE" -eq 0 ]; then
    if validate_source "$TARGET"; then
        SOURCE=$TARGET
    elif validate_source "$SELF"; then
        SOURCE=$SELF
    fi
fi

if [ -n "$ARCHIVE" ] || [ -z "$SOURCE" ]; then
    TMP=$(mktemp -d /tmp/sb-openwrt.XXXXXX) || error 'Cannot create temporary directory.'
    if [ -z "$ARCHIVE" ]; then
        ARCHIVE=$TMP/openwrt.tar.gz
        download_archive "$ARCHIVE"
    fi
    unpack_archive "$ARCHIVE" "$TMP"
fi
validate_source "$SOURCE" || error "Invalid OpenWrt source: $SOURCE"
SOURCE=$(CDPATH= cd -- "$SOURCE" && pwd -P) || error 'Cannot resolve source directory.'
if [ -d "$TARGET" ]; then
    TARGET=$(CDPATH= cd -- "$TARGET" && pwd -P) || error 'Cannot resolve target directory.'
fi
validate_source_target "$TARGET"

if [ "$SOURCE" != "$TARGET" ]; then
    [ ! -d "$TARGET/.git" ] ||
        error "Refusing to overwrite Git checkout: $TARGET (use git pull on its current branch)."
    if [ -d "$TARGET" ] && [ ! -f "$TARGET/menu.sh" ]; then
        error "Target exists but is not an installed OpenWrt source: $TARGET"
    fi
    info "Preparing $TARGET (preserving local/private settings)..."
    mkdir -p "$TARGET/scripts" "$TARGET/openwrt" "$TARGET/config" "$TARGET/providers"
    # Whitelist only operational OpenWrt source files; never copy the
    # repository's real config.json or subscription/provider private data.
    for file in README.md quick-install.sh install.sh menu.sh uninstall.sh; do
        cp "$SOURCE/$file" "$TARGET/$file" || error "Failed copying $file"
    done
    for file in "$SOURCE"/scripts/*; do
        [ -f "$file" ] || continue
        cp "$file" "$TARGET/scripts/$(basename "$file")" || error 'Failed copying script.'
    done
    for file in "$SOURCE"/openwrt/*; do
        [ -f "$file" ] || continue
        cp "$file" "$TARGET/openwrt/$(basename "$file")" || error 'Failed copying OpenWrt file.'
    done
    cp "$SOURCE/config/config.template.json" "$TARGET/config/config.template.json" ||
        error 'Failed copying config template.'
    if [ -f "$SOURCE/providers/provider.template.json" ]; then
        cp "$SOURCE/providers/provider.template.json" "$TARGET/providers/provider.template.json"
    fi
    if [ -f "$SOURCE/providers/README.md" ]; then
        cp "$SOURCE/providers/README.md" "$TARGET/providers/README.md"
    fi
    if [ -d "$SOURCE/examples" ]; then
        mkdir -p "$TARGET/examples"
        for file in "$SOURCE"/examples/*.json "$SOURCE/examples/README.md"; do
            [ ! -f "$file" ] || cp "$file" "$TARGET/examples/$(basename "$file")"
        done
    fi
fi

# Never clobber a foreign sb executable or a symlink to an unknown target.
if [ -e /usr/bin/sb ] || [ -L /usr/bin/sb ]; then
    [ ! -L /usr/bin/sb ] || error '/usr/bin/sb is a symlink; inspect it first.'
    grep -Fq '/menu.sh' /usr/bin/sb 2>/dev/null ||
        error '/usr/bin/sb belongs to another application.'
fi
printf '#!/bin/sh\nexec /bin/sh "%s/menu.sh" "$@"\n' "$TARGET" > /usr/bin/sb ||
    error 'Could not register sb launcher.'
chmod 0755 /usr/bin/sb
info "SSH shortcut: sb (source: $TARGET)"
info 'No service, kernel, DNS or firewall has been started or changed.'
[ "$OPEN_MENU" -eq 0 ] || exec /bin/sh "$TARGET/menu.sh"
