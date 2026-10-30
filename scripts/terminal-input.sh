#!/bin/sh
# Functions only: safe single-line input shared by ash and Bash menus.
# SB_TERMINAL_INPUT_BACKEND=raw is a test/diagnostic override. No input is
# evaluated, stored in a temporary file, or added to a shell history file.

_sb_ti_backend() (
    case "${SB_TERMINAL_INPUT_BACKEND:-auto}" in
        auto)
            if command -v bash >/dev/null 2>&1; then printf 'readline\n'; exit 0; fi ;;
        raw) ;;
        *) printf '%s\n' 'terminal-input: unsupported input backend.' >&2; exit 1 ;;
    esac
    if command -v stty >/dev/null 2>&1 && stty -g >/dev/null 2>&1; then
        printf 'raw\n'
    elif command -v busybox >/dev/null 2>&1 && busybox stty -g >/dev/null 2>&1; then
        printf 'busybox-raw\n'
    elif printf x | (IFS= read -r -s -n 1 _sb_ti_probe && [ "$_sb_ti_probe" = x ]) >/dev/null 2>&1; then
        printf 'ash-line\n'
    else
        printf '%s\n' 'terminal-input: this terminal needs Bash, stty, or BusyBox ash with read -s -n support.' >&2
        exit 1
    fi
)

_sb_ti_readline() (
    INPUTRC=/dev/null HISTFILE=/dev/null BASH_ENV= bash --noprofile --norc -c '
        set -o emacs
        bind "set bell-style none" 2>/dev/null || :
        bind "set disable-completion on" 2>/dev/null || :
        bind "set enable-bracketed-paste on" 2>/dev/null || :
        bind "\"\C-h\": backward-delete-char" || exit 2
        bind "\"\C-?\": backward-delete-char" || exit 2
        bind "\"\e[3~\": delete-char" || exit 2
        bind "\"\e[D\": backward-char" || exit 2
        bind "\"\e[C\": forward-char" || exit 2
        bind "\"\C-u\": kill-whole-line" || exit 2
        bind "\"\t\": tab-insert" || exit 2
        # Do not expose shell expansion or an external editor while reading
        # a password. The bridge is an input editor, not a command prompt.
        bind -r "\e\C-e" 2>/dev/null || :
        bind -r "\C-x\C-e" 2>/dev/null || :
        # Bash read itself stops at the first LF returned by Readline. Check
        # the complete editing buffer before accept-line, so a bracketed paste
        # containing "y\nn" cannot be silently reduced to confirmation "y".
        _sb_ti_multiline=0
        _sb_ti_newline="
"
        _sb_ti_carriage=$(printf "\r")
        _sb_ti_validate_line() {
            case "$READLINE_LINE" in *"$_sb_ti_newline"*|*"$_sb_ti_carriage"*)
                _sb_ti_multiline=1
                READLINE_LINE=
                READLINE_POINT=0 ;;
            esac
        }
        bind -x "\"\C-x\C-v\":_sb_ti_validate_line" || exit 2
        bind "\"\C-x\C-a\": accept-line" || exit 2
        bind "\"\C-m\": \"\C-x\C-v\C-x\C-a\"" || exit 2
        bind "\"\C-j\": \"\C-x\C-v\C-x\C-a\"" || exit 2
        if [ "$2" = --secret ]; then
            IFS= read -r -e -s -p "$1" _sb_ti_line
            _sb_ti_status=$?
            printf "\n" >&2
        else
            IFS= read -r -e -p "$1" _sb_ti_line
            _sb_ti_status=$?
        fi
        [ "$_sb_ti_status" -eq 0 ] || exit "$_sb_ti_status"
        [ "$_sb_ti_multiline" -eq 0 ] || {
            printf "%s\n" "terminal-input: multi-line input is not accepted." >&2
            exit 1
        }
        printf "%s" "$_sb_ti_line"
    ' -- "$1" "$2"
)

_sb_ti_stty() {
    if [ "$_sb_ti_mode" = busybox-raw ]; then busybox stty "$@"; else stty "$@"; fi
}

_sb_ti_pop_character() {
    # LC_ALL=C makes shell patterns byte-oriented. Remove the trailing UTF-8
    # continuation bytes together with their leading byte, never half a glyph.
    while [ -n "$_sb_ti_line" ]; do
        _sb_ti_prefix=${_sb_ti_line%?}
        _sb_ti_last=${_sb_ti_line#"$_sb_ti_prefix"}
        _sb_ti_line=$_sb_ti_prefix
        case "$_sb_ti_last" in $_sb_ti_continuation) ;; *) break ;; esac
    done
}

_sb_ti_character() {
    # Return 0 to continue, 10 to submit, and 11/130 to cancel.
    case "$_sb_ti_byte" in
        "$_sb_ti_lf"|"$_sb_ti_cr") return 10 ;;
        "$_sb_ti_eof") return 11 ;;
        "$_sb_ti_interrupt") return 130 ;;
        "$_sb_ti_bs"|"$_sb_ti_del") _sb_ti_pop_character ;;
        "$_sb_ti_kill") _sb_ti_line= ;;
        "$_sb_ti_escape") _sb_ti_sequence=escape; return 0 ;;
        *)
            case "$_sb_ti_sequence" in
                escape)
                    case "$_sb_ti_byte" in '['|'O') _sb_ti_sequence=csi ;; *) _sb_ti_sequence= ;; esac
                    return 0 ;;
                csi)
                    case "$_sb_ti_byte" in [@-~]) _sb_ti_sequence= ;; esac
                    return 0 ;;
            esac
            # Ignore other control characters; they must not become terminal
            # escapes, menu choices, or printable password diagnostics.
            case "$_sb_ti_byte" in $_sb_ti_controls) return 0 ;; esac
            _sb_ti_line=$_sb_ti_line$_sb_ti_byte ;;
    esac
    _sb_ti_sequence=
    return 0
}

_sb_ti_character_constants() {
    _sb_ti_bs=$(printf '\010') _sb_ti_del=$(printf '\177')
    _sb_ti_cr=$(printf '\015') _sb_ti_lf='
'
    _sb_ti_eof=$(printf '\004') _sb_ti_interrupt=$(printf '\003')
    _sb_ti_kill=$(printf '\025') _sb_ti_escape=$(printf '\033')
    _sb_ti_continuation=$(printf '[\200-\277]')
    _sb_ti_controls=$(printf '[\001-\037]')
    _sb_ti_sequence= _sb_ti_line=
}

_sb_ti_raw() (
    LC_ALL=C; export LC_ALL
    _sb_ti_prompt=$1 _sb_ti_secret=$2 _sb_ti_mode=$3
    _sb_ti_saved=$(_sb_ti_stty -g) || exit 1
    trap '_sb_ti_stty "$_sb_ti_saved" 2>/dev/null || :' 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    _sb_ti_stty -echo -icanon -isig -ixon -icrnl -inlcr -igncr min 1 time 0 || exit 1
    _sb_ti_character_constants
    # The mode is ready before the prompt appears, including for secret input.
    printf '%s' "$_sb_ti_prompt" >&2
    while :; do
        # The sentinel preserves an actual LF in command substitution and
        # distinguishes Enter from a zero-byte read/EOF. BusyBox dd has no
        # guaranteed status=none support, hence stderr redirection instead.
        _sb_ti_byte=$(dd bs=1 count=1 2>/dev/null; printf '.')
        _sb_ti_byte=${_sb_ti_byte%.}
        if [ -z "$_sb_ti_byte" ]; then printf '\n' >&2; exit 1; fi
        if _sb_ti_character; then _sb_ti_result=0; else _sb_ti_result=$?; fi
        case "$_sb_ti_result" in
            10) printf '\n' >&2; printf '%s' "$_sb_ti_line"; exit 0 ;;
            11|130) printf '\n' >&2; exit "$_sb_ti_result" ;;
        esac
        if [ "$_sb_ti_secret" != --secret ]; then
            printf '\r\033[2K%s%s' "$_sb_ti_prompt" "$_sb_ti_line" >&2
        fi
    done
)

_sb_ti_ash_line() (
    # With the default signal disposition ash can terminate inside its native
    # read builtin before shell_common.c restores the saved terminal settings.
    # A trapped signal interrupts read first, allowing its cleanup to run;
    # these traps then exit only this isolated input subshell.
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    LC_ALL=C; export LC_ALL
    _sb_ti_prompt=$1 _sb_ti_secret=$2
    # Stock OpenWrt may have neither Bash nor the BusyBox stty applet. A single
    # native ash read keeps echo off for the entire entry. Per-character ash
    # reads would repeatedly restore echo between characters and can leak a
    # password. Native read -p retains BusyBox's own prompt/setup ordering.
    if IFS= read -r -s -n 4096 -p "$_sb_ti_prompt" _sb_ti_pending; then
        printf '\n' >&2
    else
        printf '\n' >&2
        exit 1
    fi
    [ "${#_sb_ti_pending}" -lt 4096 ] || {
        printf '%s\n' 'terminal-input: input limit reached; cancelled without accepting a truncated value.' >&2
        exit 1
    }
    _sb_ti_character_constants
    while [ -n "$_sb_ti_pending" ]; do
        _sb_ti_tail=${_sb_ti_pending#?}
        _sb_ti_byte=${_sb_ti_pending%"$_sb_ti_tail"}
        _sb_ti_pending=$_sb_ti_tail
        if _sb_ti_character; then :; else
            # Native read already consumed the actual newline. An embedded
            # cancellation/control terminator must never become confirmation.
            exit 1
        fi
    done
    if [ "$_sb_ti_secret" != --secret ]; then printf '%s\n' "$_sb_ti_line" >&2; fi
    printf '%s' "$_sb_ti_line"
)

_sb_ti_collect() (
    case "$3" in
        readline) _sb_ti_readline "$1" "$2" ;;
        raw|busybox-raw) _sb_ti_raw "$1" "$2" "$3" ;;
        ash-line) _sb_ti_ash_line "$1" "$2" ;;
        *) exit 1 ;;
    esac
)

sb_read_line() {
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { printf '%s\n' 'Usage: sb_read_line VARIABLE PROMPT [--secret]' >&2; return 2; }
    case "$1" in ''|[0-9]*|*[!a-zA-Z0-9_]*|_sb_ti_*) printf '%s\n' 'terminal-input: invalid destination variable.' >&2; return 2 ;; esac
    case "${3:-}" in ''|--secret) ;; *) printf '%s\n' 'terminal-input: unsupported input option.' >&2; return 2 ;; esac
    if [ ! -t 0 ]; then
        printf '%s' "$2"
        IFS= read -r "$1"
        return $?
    fi
    set -- "$1" "$2" "${3:-}" "$(_sb_ti_backend)"
    [ -n "$4" ] || return 1
    if [ "$4" = ash-line ] && [ "${_sb_ti_compat_noticed:-0}" != 1 ]; then
        printf '%s\n' '当前为首次安装兼容输入：输入不回显，支持退格，按回车提交；Ctrl+C取消。此模式 Ctrl+D 后需按回车取消。' >&2
        _sb_ti_compat_noticed=1
    fi
    # Only positional parameters are used in the caller shell. The editor's
    # private variables and terminal traps live in isolated subshells.
    set -- "$1" "$(_sb_ti_collect "$2" "$3" "$4"; printf '\n%s' "$?")"
    set -- "$1" "${2%
*}" "${2##*
}"
    # Readline bracketed paste can contain embedded newlines. Reject them
    # before the one-line read assignment, rather than silently accepting a
    # first line such as "y" from a pasted multi-line confirmation.
    case "$2" in *'
'*|*"$(printf '\015')"*)
        printf '%s\n' 'terminal-input: multi-line input is not accepted.' >&2
        set -- "$1" '' 1 ;;
    esac
    if IFS= read -r "$1" <<SB_TERMINAL_INPUT_VALUE
$2
SB_TERMINAL_INPUT_VALUE
    then return "$3"; else return 1; fi
}
