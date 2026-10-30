#!/usr/bin/env bash
# Real processes: no timeout, setsid, ps or pkill in the command runner's PATH.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
python3 - "$BASE" <<'PY'
import ctypes
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

base = Path(sys.argv[1])
library = base / 'scripts/config-parts-lib.sh'
bash = shutil.which('bash')
sleep = shutil.which('sleep')
assert bash and sleep
# Adopt unexpected orphans rather than relying on the test container's PID 1
# to reap them. A deadline timer must always be reaped by its own watchdog.
assert ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0

with tempfile.TemporaryDirectory(prefix='sb-timeout-guard-') as directory:
    root = Path(directory)
    tools = root / 'tools'
    tools.mkdir()
    timer_pids = root / 'timer-pids'
    timer = tools / 'sleep'
    timer.write_text('''#!/bin/sh
printf '%s\\n' "$$" >> "$GUARD_TIMER_PIDS"
if [ -n "${SB_TEST_SLEEP_BUSYBOX:-}" ]; then
    exec "$SB_TEST_SLEEP_BUSYBOX" sleep "$@"
fi
exec "$GUARD_REAL_SLEEP" "$@"
''')
    timer.chmod(0o755)
    env = {**os.environ, 'PATH': str(tools), 'GUARD_TIMER_PIDS': str(timer_pids),
           'GUARD_REAL_SLEEP': sleep}
    worker = root / 'worker.py'
    worker.write_text('''import json, os, signal, subprocess, sys, time
mode, record = sys.argv[1:3]
child = None
if mode in ('ignore-term', 'descendant'):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode == 'descendant':
    child = subprocess.Popen([sys.executable, '-c',
        'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)'])
with open(record, 'w') as output:
    json.dump({'pid': os.getpid(), 'parent': os.getppid(),
               'child': child.pid if child else None}, output)
time.sleep(30)
''')
    shell = 'set -euo pipefail\n. "$1"\nshift\nsb_run_with_timeout "$@"\n'

    def start(seconds, *command, script=shell, environment=env):
        timer_pids.unlink(missing_ok=True)
        return subprocess.Popen([bash, '-c', script, 'guard-test', str(library),
                                 str(seconds), *command], env=environment,
                                stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def finish(process, expected, allowed_orphans=()):
        output, errors = process.communicate(timeout=10)
        assert process.returncode == expected, (expected, process.returncode, output, errors)
        adopted = []
        while True:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            assert pid != 0, 'command runner left a living adopted child'
            adopted.append(pid)
            assert os.WIFSIGNALED(status) or os.WIFEXITED(status), (pid, status)
        assert set(adopted) <= set(allowed_orphans), ('unreaped watchdog/timer', adopted)
        for text in timer_pids.read_text().splitlines() if timer_pids.exists() else []:
            assert not alive(int(text)), ('timer was not reaped', text)
        for pid in allowed_orphans:
            assert not alive(pid), ('checked descendant survived', pid)
        return output, errors

    def wait_record(path, process):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists():
                try:
                    return json.loads(path.read_text())
                except json.JSONDecodeError:
                    pass
            assert process.poll() is None, process.communicate()
            time.sleep(0.01)
        raise AssertionError('checked command did not start')

    # Real exit status, arguments, stdout/stderr and single invocation survive.
    for status in (0, 27, 127):
        process = start(10, sys.executable, '-c',
                        'import sys; print(sys.argv[1:]); print("core-error",file=sys.stderr); sys.exit(int(sys.argv[3]))',
                        'space value', 'literal $HOME; `echo no`', str(status))
        output, errors = finish(process, status)
        assert output.count(b'space value') == 1 and b'literal $HOME; `echo no`' in output
        assert errors.count(b'core-error') == 1

    for seconds in ('0', '00', '-1', '1.5', 'invalid', '999999999999999999999999'):
        marker = root / 'invalid-ran'
        finish(start(seconds, sys.executable, '-c',
                     'from pathlib import Path; import sys; Path(sys.argv[1]).touch()', str(marker)), 125)
        assert not marker.exists(), 'invalid deadline ran the command'

    # Both ordinary TERM and a process ignoring TERM must finish within the
    # deadline plus the fixed KILL grace. No system timeout participates.
    for mode in ('hang', 'ignore-term'):
        record = root / (mode + '.json')
        process = start(1, sys.executable, str(worker), mode, str(record))
        data = wait_record(record, process)
        finish(process, 124)
        assert not alive(data['pid']), 'checked process was not reaped'

    # On a forced group kill a grandchild is adopted by init (this test). It
    # must already be dead, while the watchdog must reap every timer itself.
    record = root / 'descendant.json'
    process = start(1, sys.executable, str(worker), 'descendant', str(record))
    data = wait_record(record, process)
    finish(process, 124, (data['child'],))
    assert not alive(data['pid'])

    for signum, status in ((signal.SIGHUP, 129), (signal.SIGINT, 130), (signal.SIGTERM, 143)):
        record = root / ('signal-' + str(signum) + '.json')
        process = start(30, sys.executable, str(worker), 'ignore-term', str(record))
        data = wait_record(record, process)
        os.kill(data['parent'], signum)
        finish(process, status)
        assert not alive(data['pid']), 'interruption did not reap the checked process'

    # Interrupt deterministically between asynchronous launch and $! capture,
    # and immediately before wait. Bash's DEBUG trap is only a test injector;
    # no production timing hooks or sleeps are needed.
    for boundary in ('sb_timeout_child=$!', 'sb_timeout_watchdog=$!', 'wait "$sb_timeout_child"'):
        raced = '''set -euo pipefail
. "$1"
shift
set -T
guard_test_boundary=''' + shlex.quote(boundary) + '''
guard_test_interrupt() {
    if [ "$BASH_COMMAND" = "$guard_test_boundary" ]; then
        trap - DEBUG
        kill -TERM "$BASHPID"
    fi
}
trap guard_test_interrupt DEBUG
sb_run_with_timeout "$@"
'''
        finish(start(30, sys.executable, '-c', 'import time; time.sleep(30)', script=raced), 143)

    # A Bash build without usable job control must refuse before execution.
    marker = root / 'no-job-control-ran'
    no_job_control = '''set -euo pipefail
. "$1"
shift
set() { [ "${1:-}" != -m ] || return 1; builtin set "$@"; }
sb_run_with_timeout "$@"
'''
    finish(start(30, sys.executable, '-c',
                 'from pathlib import Path; import sys; Path(sys.argv[1]).touch()',
                 str(marker), script=no_job_control), 125)
    assert not marker.exists()

    # A failing or missing sleep must fail closed, never leave an unbounded
    # checker. The failing executable exercises failure after command launch.
    real_timer = timer.read_text()
    timer.write_text('#!/bin/sh\nexit 7\n')
    finish(start(30, sys.executable, '-c', 'import time; time.sleep(30)'), 125)
    timer.unlink()
    marker = root / 'no-sleep-ran'
    finish(start(30, sys.executable, '-c',
                 'from pathlib import Path; import sys; Path(sys.argv[1]).touch()', str(marker)), 125)
    assert not marker.exists()
    timer.write_text(real_timer)
    timer.chmod(0o755)

    # Subshell isolation must preserve the caller's signal traps, shell options
    # and pre-existing background jobs. Use an absolute sleep for the caller.
    isolated = '''set -euo pipefail
. "$1"
trap ':' HUP INT TERM USR1 USR2
trap 'printf "caller-exit\\n"' EXIT
before_traps=$(trap -p)
before_options=$-
"$GUARD_REAL_SLEEP" 30 &
caller_job=$!
sb_run_with_timeout 5 ''' + shlex.quote(sys.executable) + ''' -c 'pass'
[ "$(trap -p)" = "$before_traps" ]
[ "$-" = "$before_options" ]
kill -0 "$caller_job"
kill "$caller_job"
wait "$caller_job" 2>/dev/null || :
'''
    output, _ = finish(start(5, script=isolated), 0)
    assert output == b'caller-exit\n'

print('Bounded checks without timeout: exit status, deadlines, signals, process cleanup and caller isolation passed.')
PY
