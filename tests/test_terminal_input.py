#!/usr/bin/env python3
"""PTY regressions for the real shared shell reader; no service/network work.

Set SB_TEST_BUSYBOX to an absolute BusyBox executable in CI to REQUIRE real ash
coverage with neither Bash nor stty discoverable. Python is test tooling only.
"""

from __future__ import annotations

import array
import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import signal
import subprocess
import tempfile
import termios
import time


BASE = Path(__file__).resolve().parents[1]
HELPER = BASE / "scripts/terminal-input.sh"
BASH = shutil.which("bash")
DASH = shutil.which("dash") or "/bin/sh"
BUSYBOX_REQUIRED = os.environ.get("SB_TEST_BUSYBOX")
BUSYBOX = BUSYBOX_REQUIRED or shutil.which("busybox")
assert BASH, "Bash is required to test the Readline backend"
if BUSYBOX_REQUIRED:
    assert os.path.isabs(BUSYBOX_REQUIRED) and os.access(BUSYBOX_REQUIRED, os.X_OK), "SB_TEST_BUSYBOX must name an executable absolute path"

SCRIPT = r'''
. "$1"
CONFIG=caller-config
trap 'printf "\n__CALLER_TRAP__\n"' 0
answer=previous-value
if sb_read_line answer "$SB_TEST_PROMPT" "$SB_TEST_OPTION"; then result=0; else result=$?; fi
printf '\n__STATUS__%s\n' "$result"
if [ "$answer" = "$SB_TEST_EXPECTED" ]; then printf '__MATCH__yes\n'; else printf '__MATCH__no\n'; fi
if [ "$CONFIG" = caller-config ]; then printf '__CALLER_VARIABLE__ok\n'; fi
'''


class Terminal:
    def __init__(self, shell: list[str], *, backend="auto", secret=False,
                 expected="", erase=b"\x7f", path=None, mask_stty=False, stty_wrapper=None):
        self.master, self.slave = pty.openpty()
        attributes = termios.tcgetattr(self.slave)
        attributes[6][termios.VERASE] = erase
        termios.tcsetattr(self.slave, termios.TCSANOW, attributes)
        self.original = termios.tcgetattr(self.slave)
        env = os.environ.copy()
        env.update(TERM="xterm", LC_ALL="C.UTF-8", SB_TERMINAL_INPUT_BACKEND=backend,
                   SB_TEST_PROMPT="SECRET> " if secret else "INPUT> ",
                   SB_TEST_OPTION="--secret" if secret else "", SB_TEST_EXPECTED=expected)
        if path is not None:
            env["PATH"] = str(path)

        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)

        script = SCRIPT
        assert not (mask_stty and stty_wrapper), "Cannot mask stty and inject a wrapper together"
        if mask_stty:
            # Ubuntu's BusyBox ash can discover standalone applets even with
            # PATH empty. Model OpenWrt's disabled STTY applet explicitly;
            # the real ash shell and its native read builtin remain untouched.
            script = "stty() { return 127; }\nbusybox() { return 127; }\n" + script
        elif stty_wrapper is not None:
            # Standalone BusyBox applets may bypass PATH. An explicit shell
            # function ensures the signal-injection fixture is actually used.
            script = f"stty() {{ {shlex.quote(str(stty_wrapper.resolve()))} \"$@\"; }}\n" + script
        self.process = subprocess.Popen(shell + ["-c", script, "terminal-input-test", str(HELPER)],
                                        stdin=self.slave, stdout=self.slave, stderr=self.slave,
                                        env=env, preexec_fn=controlling_terminal)
        self.output = bytearray()
        self.prompt = env["SB_TEST_PROMPT"].encode()

    def read_available(self, timeout=0.05):
        ready, _, _ = select.select([self.master], [], [], timeout)
        if ready:
            try:
                data = os.read(self.master, 65536)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                return
            self.output.extend(data)

    def until(self, marker: bytes, timeout=8):
        deadline = time.monotonic() + timeout
        while marker not in self.output:
            self.read_available()
            assert time.monotonic() < deadline, f"Timed out waiting for {marker!r}: {bytes(self.output)!r}"
            if self.process.poll() is not None:
                self.read_available(0)
                assert marker in self.output, f"Reader exited before prompt: {bytes(self.output)!r}"

    def send(self, data: bytes):
        os.write(self.master, data)

    def wait_native_read(self, previous=None, consumed=0):
        """Wait for the real ash builtin to block after consuming the fixture."""
        deadline = time.monotonic() + 8
        while True:
            attributes = termios.tcgetattr(self.slave)
            queued = array.array("i", [0])
            fcntl.ioctl(self.slave, termios.FIONREAD, queued, True)
            channels = {}
            pending = [self.process.pid]
            while pending:
                pid = pending.pop()
                try:
                    proc = Path("/proc") / str(pid)
                    pending.extend(int(child) for child in (proc / "task" / str(pid) / "children").read_text().split())
                    channel = (proc / "wchan").read_text().strip()
                    channels[pid] = channel
                    if "poll" not in channel:
                        continue
                    rchar = next(int(line.partition(":")[2]) for line in (proc / "io").read_text().splitlines()
                                 if line.startswith("rchar:"))
                except (FileNotFoundError, ProcessLookupError):
                    continue
                if (queued[0] == 0 and attributes[3] & termios.ISIG
                        and not attributes[3] & (termios.ECHO | termios.ICANON)
                        and (previous is None or (pid == previous[0] and rchar >= previous[1] + consumed))):
                    return pid, rchar
            assert self.process.poll() is None, f"Native reader exited before blocking: {bytes(self.output)!r}"
            assert time.monotonic() < deadline, (
                f"Native reader did not reach blocked poll with drained input: queued={queued[0]}, "
                f"wait_channels={channels}, output={bytes(self.output)!r}")
            self.read_available(0.01)

    def finish(self, *, match=True, success=True):
        deadline = time.monotonic() + 8
        while self.process.poll() is None:
            self.read_available()
            assert time.monotonic() < deadline, f"Reader did not exit: {bytes(self.output)!r}"
        for _ in range(3):
            self.read_available(0.01)
        text = bytes(self.output)
        assert self.process.returncode == 0, (self.process.returncode, text)
        assert b"__CALLER_TRAP__" in text and b"__CALLER_VARIABLE__ok" in text, text
        if success:
            assert b"__STATUS__0" in text, text
        else:
            assert b"__STATUS__0" not in text and b"__STATUS__" in text, text
        if match:
            assert b"__MATCH__yes" in text, text
        assert termios.tcgetattr(self.slave) == self.original, "Terminal settings were not restored"
        return text

    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGKILL)
        self.process.wait(timeout=3)
        os.close(self.master)
        os.close(self.slave)


def check(shell, keys: bytes, expected="", *, success=True, backend="auto", secret=False,
          erase=b"\x7f", path=None, mask_stty=False):
    terminal = Terminal(shell, backend=backend, secret=secret, expected=expected,
                        erase=erase, path=path, mask_stty=mask_stty)
    try:
        terminal.until(terminal.prompt)
        terminal.send(keys)
        return terminal.finish(success=success)
    finally:
        terminal.close()


def signal_restore(shell, backend="auto", path=None, mask_stty=False, ctrl_c=False, stty_wrapper=None):
    terminal = Terminal(shell, backend=backend, secret=True, path=path, mask_stty=mask_stty,
                        stty_wrapper=stty_wrapper)
    try:
        terminal.until(terminal.prompt)
        # BusyBox prints the native read prompt before applying termios, and
        # its per-byte read loop has a known signal-before-poll window. Test
        # interruption of a genuinely blocked read, after actual consumption,
        # without changing the builtin or using a timing delay/retry.
        previous = terminal.wait_native_read() if mask_stty else None
        fixture = b"signal-private-fixture"
        terminal.send(fixture)
        if mask_stty:
            terminal.wait_native_read(previous, len(fixture))
        if ctrl_c:
            # Exercise actual terminal VINTR/ISIG processing, not a simulated
            # byte interpreted by the editor. The entire foreground shell
            # group may exit nonzero, which is a valid cancellation outcome.
            terminal.send(b"\x03")
        else:
            os.killpg(terminal.process.pid, signal.SIGTERM)
        deadline = time.monotonic() + 8
        while terminal.process.poll() is None:
            terminal.read_available()
            assert time.monotonic() < deadline, f"{'Ctrl-C' if ctrl_c else 'SIGTERM'} did not stop reader: {bytes(terminal.output)!r}"
        # A child trap may complete just after the outer shell receives TERM.
        deadline = time.monotonic() + 3
        while termios.tcgetattr(terminal.slave) != terminal.original:
            terminal.read_available(0.01)
            assert time.monotonic() < deadline, "Signal left the terminal in raw/no-echo mode"
        terminal.read_available(0)
        assert b"signal-private-fixture" not in terminal.output, terminal.output
        if ctrl_c:
            assert b"__STATUS__0" not in terminal.output, terminal.output
            assert terminal.process.returncode != 0 or b"__STATUS__" in terminal.output, terminal.output
    finally:
        terminal.close()


def cleanup_hup_restore(shell, directory):
    """Deliver a second signal while raw-reader cleanup is restoring termios."""
    directory.mkdir()
    native_stty = shutil.which("stty")
    native_dd = shutil.which("dd")
    assert native_stty and native_dd
    marker = directory / "cleanup-hup-injected"
    wrapper = directory / "stty"
    wrapper.write_text("#!/bin/sh\n"
                       "if [ \"$#\" -eq 1 ]; then\n"
                       "    case \"$1\" in *:*)\n"
                       f"        printf 'cleanup\\n' >> {shlex.quote(str(marker))}\n"
                       "        kill -HUP 0\n"
                       "        ;;\n"
                       "    esac\n"
                       "fi\n"
                       f"exec {shlex.quote(native_stty)} \"$@\"\n")
    wrapper.chmod(0o755)
    (directory / "dd").symlink_to(native_dd)
    # Terminal starts a separate session/process group. This signal targets
    # only its fixture reader and cleanup children, never the test runner.
    # A session leader dying after TERM can cause precisely this follow-up
    # HUP. The cleanup command must inherit ignored termination signals.
    signal_restore(shell, path=directory, stty_wrapper=wrapper)
    assert marker.read_text() == "cleanup\n", "Restoration did not run exactly once"


def non_tty():
    env = os.environ.copy()
    env.update(SB_TEST_PROMPT="PIPE> ", SB_TEST_OPTION="", SB_TEST_EXPECTED="literal\\r\x08\x7f")
    result = subprocess.run([DASH, "-c", SCRIPT, "pipe-test", str(HELPER)],
                            input=b"literal\\r\x08\x7f\n", capture_output=True, env=env, check=True)
    assert result.stdout.startswith(b"PIPE> ") and b"__MATCH__yes" in result.stdout, result
    assert b"__STATUS__0" in result.stdout, result
    env["SB_TEST_EXPECTED"] = "partial"
    result = subprocess.run([DASH, "-c", SCRIPT, "pipe-test", str(HELPER)],
                            input=b"partial", capture_output=True, env=env, check=True)
    assert b"__MATCH__yes" in result.stdout and b"__STATUS__0" not in result.stdout, result
    env["SB_TEST_EXPECTED"] = ""
    result = subprocess.run([DASH, "-c", SCRIPT, "pipe-test", str(HELPER)],
                            input=b"", capture_output=True, env=env, check=True)
    assert b"__MATCH__yes" in result.stdout and b"__STATUS__0" not in result.stdout, result
    print("PASS: non-TTY read preserves literal bytes, partial-line EOF and stdout prompts")


def main():
    non_tty()
    for shell in ([BASH], [DASH]):
        for erase in (b"\x08", b"\x7f"):
            check(shell, b"12\x083\x7f4\n", "14", erase=erase)
        check(shell, b"123\x1b[D\x1b[D\x1b[3~9\x1b[C\x08\n", "19")
        check(shell, "A中".encode() + b"\x08" + "😀".encode() + b"\x7f" + "好\n".encode(), "A好")
        check(shell, b"discard this\x15ok\n", "ok")
        check(shell, b"\x08\x7f\x04", success=False)
    print("PASS: Readline under Bash/dash handles BS, DEL, arrows, Delete, UTF-8, Ctrl-U and EOF")

    with tempfile.TemporaryDirectory(prefix="sb-terminal-test-") as temporary:
        sentinel = Path(temporary) / "must-not-exist"
        literal = f"$(touch {sentinel}); `touch {sentinel}` \\r"
        check([DASH], literal.encode() + b"\n", literal)
        assert not sentinel.exists(), "Input was evaluated as shell code"

        for shell in ([BASH], [DASH]):
            keys = b"fixtureSENSITIVE12\x1b[D\x1b[3~\x08\x0c\tZ\n"
            output = check(shell, keys, "fixtureSENSITIVE\tZ", secret=True)
            assert b"fixtureSENSITIVE" not in output and b"SENSITIVE" not in output, output
            output = check(shell, b"cancel-secret\x15\x04", success=False, secret=True)
            assert b"cancel-secret" not in output, output
        print("PASS: secret Readline editing, Tab/redraw and cancellation never echo the fixture secret")

        output = check([DASH], b"\x1b[200~y\nn\x1b[201~\n", success=False)
        assert b"multi-line input is not accepted" in output, output
        print("PASS: shell metacharacters remain data and multiline bracketed paste is rejected")

        # Restrict PATH to the exact tools available to a no-Bash raw reader.
        raw_path = Path(temporary) / "raw-bin"
        raw_path.mkdir()
        for command in ("stty", "dd"):
            executable = shutil.which(command)
            assert executable, f"{command} is required for raw-backend tests"
            (raw_path / command).symlink_to(executable)
        for erase in (b"\x08", b"\x7f"):
            check([DASH], b"12\x083\x7f4\n", "14", path=raw_path, erase=erase)
        check([DASH], "A中".encode() + b"\x08" + "😀".encode() + b"\x7f" + "好\n".encode(), "A好", path=raw_path)
        check([DASH], b"discard\x15ok\n", "ok", path=raw_path)
        check([DASH], b"\x04", success=False, path=raw_path)
        output = check([DASH], b"raw-privateXY\x08\x7fZ\n", "raw-privateZ", secret=True, path=raw_path)
        assert b"raw-private" not in output, output
        output = check([DASH], b"raw-cancel\x04", success=False, secret=True, path=raw_path)
        assert b"raw-cancel" not in output, output
        signal_restore([DASH], path=raw_path)
        signal_restore([BASH])
        print("PASS: no-Bash raw input deletes UTF-8 characters, hides secrets and restores termios on cancellation/signals")

        cleanup_hup_restore([DASH], Path(temporary) / "cleanup-signal-bin")
        print("PASS: raw terminal restoration survives a second HUP during cleanup")

        # Exercise buffered editing locally even when BusyBox is unavailable;
        # this checks our algorithm, not BusyBox's native read implementation.
        empty_path = Path(temporary) / "ash-no-bash-no-stty"
        empty_path.mkdir()
        output = check([BASH], b"buffered-privateXY\x08\x7fZ\n", "buffered-privateZ", secret=True, path=empty_path)
        assert b"buffered-private" not in output, output
        check([BASH], b"\x04\n", success=False, path=empty_path)
        check([BASH], b"a" * 4096 + b"\n", success=False, path=empty_path)
        print("PASS: buffered no-stty editing algorithm rejects Ctrl-D and length-limit truncation")

        if BUSYBOX:
            # Also mask standalone applet lookup: PATH alone is insufficient
            # for some CI BusyBox builds that include stty.
            ash = [str(Path(BUSYBOX).resolve()), "ash"]
            ash_options = {"path": empty_path, "mask_stty": True}
            for erase in (b"\x08", b"\x7f"):
                output = check(ash, b"12\x083\x7f4\n", "14", erase=erase, **ash_options)
                assert "首次安装兼容输入".encode() in output, (
                    "BusyBox test did not exercise the required no-Bash/no-stty ash-line backend: "
                    f"{output!r}")
            check(ash, "A中".encode() + b"\x08" + "😀".encode() + b"\x7f" + "好\n".encode(), "A好", **ash_options)
            check(ash, b"discard\x15ok\n", "ok", **ash_options)
            check(ash, b"\x04\n", success=False, **ash_options)
            output = check(ash, b"ash-privateXY\x08\x7fZ\n", "ash-privateZ", secret=True, **ash_options)
            assert b"ash-private" not in output, output
            output = check(ash, b"ash-cancel\x04\n", success=False, secret=True, **ash_options)
            assert b"ash-cancel" not in output, output
            check(ash, b"a" * 4096 + b"\n", success=False, **ash_options)
            signal_restore(ash, **ash_options)
            signal_restore(ash, ctrl_c=True, **ash_options)
            print("PASS: real BusyBox ash with no Bash/stty supports hidden buffered editing and rejects cancellation/overflow")
            cleanup_hup_restore(ash, Path(temporary) / "ash-cleanup-signal-bin")
            print("PASS: real BusyBox ash raw cleanup survives a second HUP during restoration")
        else:
            print("SKIP: real BusyBox ash is unavailable locally; CI requires SB_TEST_BUSYBOX")

    print("All available terminal-input tests passed.")


if __name__ == "__main__":
    main()
