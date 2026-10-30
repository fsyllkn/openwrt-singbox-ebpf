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

# Run an external command once with a deadline. Only the Bash controllers call
# this function; keep this library parseable by /bin/sh for the init helpers.
# Do not require optional timeout applets or their differing exit conventions.
sb_run_with_timeout() (
    case "${1:-}" in
        ''|*[!0-9]*) printf '%s\n' 'config-check: timeout must be a positive integer.' >&2; exit 125 ;;
    esac
    [ "$1" -gt 0 ] 2>/dev/null && [ "$#" -ge 2 ] || {
        printf '%s\n' 'config-check: timeout must be a positive integer followed by a command.' >&2
        exit 125
    }
    [ -n "${BASH_VERSION:-}" ] && [ -n "${BASHPID:-}" ] || {
        printf '%s\n' 'config-check: the bounded command runner requires Bash.' >&2
        exit 125
    }
    command -v sleep >/dev/null 2>&1 || {
        printf '%s\n' 'config-check: sleep is required by the bounded command runner.' >&2
        exit 125
    }
    sb_timeout_seconds=$1
    shift
    sb_timeout_owner=$BASHPID
    sb_timeout_child= sb_timeout_watchdog=
    sb_timeout_expired=0 sb_timeout_failed=0 sb_timeout_status=0

    _sb_timeout_cleanup() {
        trap '' HUP INT TERM USR1 USR2
        trap - 0
        set +m
        # Include jobs not yet assigned to $! variables if a signal arrives
        # just after spawning. This subshell has no caller-owned background jobs.
        sb_timeout_jobs="$sb_timeout_child $sb_timeout_watchdog $(jobs -p)"
        for sb_timeout_job in $sb_timeout_jobs; do
            [ -n "$sb_timeout_job" ] || continue
            kill -TERM -- "-$sb_timeout_job" 2>/dev/null || :
        done
        # The watchdog handles TERM and reaps its own timer. Killing its shell
        # immediately could orphan sleep before that reap. A signal before the
        # first $! assignment can only have created the checked command's job.
        if [ -n "$sb_timeout_child" ]; then
            kill -KILL -- "-$sb_timeout_child" 2>/dev/null || :
        else
            for sb_timeout_job in $sb_timeout_jobs; do
                [ -n "$sb_timeout_job" ] || continue
                kill -KILL -- "-$sb_timeout_job" 2>/dev/null || :
            done
        fi
        wait 2>/dev/null || :
    }
    trap '_sb_timeout_cleanup' 0
    trap '_sb_timeout_cleanup; exit 129' HUP
    trap '_sb_timeout_cleanup; exit 130' INT
    trap '_sb_timeout_cleanup; exit 143' TERM
    trap 'sb_timeout_expired=1' USR1
    trap 'sb_timeout_failed=1' USR2
    # Non-interactive Bash job control creates distinct process groups without
    # requiring a terminal or the optional setsid command.
    set -m 2>/dev/null || {
        printf '%s\n' 'config-check: Bash job control is required for bounded process cleanup.' >&2
        exit 125
    }
    (
        set +m
        trap - 0 HUP INT TERM USR1 USR2
        exec "$@"
    ) &
    sb_timeout_child=$!
    (
        set +m
        trap - 0 HUP INT TERM USR1 USR2
        sb_timeout_clock=
        _sb_timeout_watch_cleanup() {
            trap '' HUP INT TERM USR1 USR2
            trap - 0
            sb_timeout_clocks="$sb_timeout_clock $(jobs -p)"
            for sb_timeout_clock_pid in $sb_timeout_clocks; do
                [ -n "$sb_timeout_clock_pid" ] || continue
                kill -KILL "$sb_timeout_clock_pid" 2>/dev/null || :
            done
            wait 2>/dev/null || :
        }
        trap '_sb_timeout_watch_cleanup' 0
        trap '_sb_timeout_watch_cleanup; exit 0' HUP INT TERM
        sleep "$sb_timeout_seconds" &
        sb_timeout_clock=$!
        sb_timeout_clock_status=0
        wait "$sb_timeout_clock" || sb_timeout_clock_status=$?
        sb_timeout_clock=
        if [ "$sb_timeout_clock_status" -ne 0 ]; then
            kill -USR2 "$sb_timeout_owner" 2>/dev/null || :
            kill -KILL -- "-$sb_timeout_child" 2>/dev/null || :
            exit 125
        fi
        kill -USR1 "$sb_timeout_owner" 2>/dev/null || exit 0
        kill -TERM -- "-$sb_timeout_child" 2>/dev/null || :
        sleep 2 &
        sb_timeout_clock=$!
        wait "$sb_timeout_clock" 2>/dev/null || :
        sb_timeout_clock=
        kill -KILL -- "-$sb_timeout_child" 2>/dev/null || :
    ) &
    sb_timeout_watchdog=$!
    set +m
    wait "$sb_timeout_child" || sb_timeout_status=$?
    if [ "$sb_timeout_failed" -eq 1 ]; then
        printf '%s\n' 'config-check: the deadline watchdog failed.' >&2
        sb_timeout_status=125
    elif [ "$sb_timeout_expired" -eq 1 ]; then
        # USR1 interrupts wait before TERM/KILL necessarily finishes the child.
        wait "$sb_timeout_child" 2>/dev/null || :
        sb_timeout_status=124
    fi
    _sb_timeout_cleanup
    exit "$sb_timeout_status"
)
