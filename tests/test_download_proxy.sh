#!/usr/bin/env bash
# Behavioral tests only: every transport and UCI command is a local fixture.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sb-download-proxy.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
HOST_SH=$(command -v sh)
HOST_PYTHON=$(command -v python3)
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/uci" "$TEST_DIR/output"
for tool in sh mktemp rm mv grep tr chmod mkdir dirname cp ln cmp cat stat wc find; do
    ln -s "$(command -v "$tool")" "$TEST_DIR/bin/$tool"
done
printf '#!%s\n' "$HOST_PYTHON" > "$TEST_DIR/transport"
cat >> "$TEST_DIR/transport" <<'PY'
import json, os, pathlib, sys
kind = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if kind == "wget" and args in (["--version"], ["--help"]):
    mode = os.environ.get("TEST_WGET_KIND", "gnu")
    if mode == "gnu":
        print("GNU Wget 1.25.0 built on fixture-linux-gnu.")
        raise SystemExit(0)
    print("uclient-fetch: invalid option" if mode == "uclient" else "BusyBox v1.36.1 multi-call binary.")
    raise SystemExit(1)
env_names = ("http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "no_proxy", "NO_PROXY")
with open(os.environ["TEST_TRANSPORT_LOG"], "a") as log:
    log.write(json.dumps({"kind": kind, "args": args, "env": {k: os.environ.get(k) for k in env_names}}) + "\n")
if kind == "child-command":
    raise SystemExit(int(os.environ.get("TEST_RUN_STATUS", "0")))
output = None
for i, arg in enumerate(args):
    if arg in ("-o", "--output", "-O"):
        output = args[i + 1]
if not output:
    raise SystemExit(90)
pathlib.Path(output).write_text("mock complete download\n")
if os.environ.get("TEST_DOWNLOAD_FAIL") == "1":
    pathlib.Path(output).write_text("incomplete bytes")
    # A real client may echo proxy diagnostics. The library must not leak them.
    print("failed proxy: " + os.environ.get("http_proxy", ""), file=sys.stderr)
    raise SystemExit(22)
PY
printf '#!%s\n' "$HOST_PYTHON" > "$TEST_DIR/bin/uci"
cat >> "$TEST_DIR/bin/uci" <<'PY'
import json, os, pathlib, shlex, sys
args = sys.argv[1:]
with open(os.environ["TEST_UCI_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
root = os.environ["SB_DOWNLOAD_UCI_DIR"]
while args and args[0].startswith("-"):
    if args[0] == "-c":
        root = args[1]
        args = args[2:]
    elif args[0] == "-q":
        args = args[1:]
    else:
        raise SystemExit(64)
config = pathlib.Path(root) / "sing-box"
pending = pathlib.Path(root) / "sing-box.pending"
committed = json.loads(config.read_text() or "{}") if config.exists() else {}
state = json.loads(pending.read_text()) if pending.exists() else committed.copy()
if args and args[0] == "get":
    if args[1] not in state:
        raise SystemExit(1)
    print(state[args[1]])
    raise SystemExit(0)
if args == ["commit", "sing-box"]:
    if os.environ.get("TEST_UCI_FAIL") == "1":
        raise SystemExit(1)
    config.write_text(json.dumps(state, sort_keys=True))
    if pending.exists():
        pending.unlink()
    raise SystemExit(0)
if args == ["delete", "sing-box.download"]:
    if "sing-box.download" not in state:
        raise SystemExit(1)
    state = {k: v for k, v in state.items() if k != "sing-box.download" and not k.startswith("sing-box.download.")}
    pending.write_text(json.dumps(state))
    raise SystemExit(0)
if args == ["revert", "sing-box.download"]:
    state = {k: v for k, v in state.items() if k != "sing-box.download" and not k.startswith("sing-box.download.")}
    state.update({k: v for k, v in committed.items() if k == "sing-box.download" or k.startswith("sing-box.download.")})
    if state == committed:
        if pending.exists():
            pending.unlink()
    else:
        pending.write_text(json.dumps(state))
    raise SystemExit(0)
if args != ["batch"]:
    raise SystemExit(64)
for line in sys.stdin:
    words = shlex.split(line)
    if words[0] == "set":
        if not config.exists():
            continue  # Real UCI cannot create an absent package with set.
        key, value = words[1].split("=", 1)
        if os.environ.get("TEST_UCI_DROP_SET") == "1" and key.endswith(".http_proxy"):
            continue  # Real UCI batch masks the failed command's status.
        state[key] = value
    elif words[0] == "delete":
        key = words[1]
        if key not in state:
            continue
        state = {k: v for k, v in state.items() if k != key and not k.startswith(key + ".")}
    else:
        raise SystemExit(64)
    pending.write_text(json.dumps(state))
PY
cat > "$TEST_DIR/bin/id" <<'SH'
#!/bin/sh
[ "$#" -eq 1 ] && [ "$1" = -u ] || exit 64
printf '0\n'
SH
cat > "$TEST_DIR/timeout" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_TIMEOUT_LOG"
shift
if [ "${TEST_TIMEOUT_FAIL:-0}" = 1 ]; then exit 124; fi
"$@"
SH
chmod 0755 "$TEST_DIR/transport" "$TEST_DIR/bin/uci" "$TEST_DIR/bin/id" "$TEST_DIR/timeout"
ln -s "$TEST_DIR/transport" "$TEST_DIR/bin/curl"
ln -s "$TEST_DIR/transport" "$TEST_DIR/bin/wget"
ln -s "$TEST_DIR/transport" "$TEST_DIR/bin/child-command"
PATH=$TEST_DIR/bin
SB_TEST_LIBRARY=$BASE/scripts/download.sh
SB_DOWNLOAD_UCI_DIR=$TEST_DIR/uci
TEST_TRANSPORT_LOG=$TEST_DIR/transports.jsonl
TEST_UCI_LOG=$TEST_DIR/uci-args.jsonl
TEST_TIMEOUT_LOG=$TEST_DIR/timeout.log
export PATH SB_TEST_LIBRARY SB_DOWNLOAD_UCI_DIR TEST_TRANSPORT_LOG TEST_UCI_LOG TEST_TIMEOUT_LOG
unset SB_DOWNLOAD_MODE SB_HTTP_PROXY SB_GITHUB_PROXY
http_proxy=http://system.example:8118 https_proxy=http://system.example:8118 all_proxy=http://system.example:8118
HTTP_PROXY=$http_proxy HTTPS_PROXY=$http_proxy ALL_PROXY=$http_proxy
no_proxy=system-bypass.example NO_PROXY=system-bypass.example
export http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY

reset_logs() { : > "$TEST_TRANSPORT_LOG"; : > "$TEST_UCI_LOG"; : > "$TEST_TIMEOUT_LOG"; }
sb() { "$HOST_SH" -eu -c '. "$SB_TEST_LIBRARY"; "$@"' download-test "$@"; }
cli() { "$HOST_SH" "$BASE/scripts/configure-download.sh" "$@"; }
assert_no_staging() {
    [ -z "$(find "$TEST_DIR/output" -name '*.download.*' -print)" ] || fail 'download staging files retained'
}
assert_load() {
    "$HOST_SH" -eu -c '
        . "$SB_TEST_LIBRARY"
        sb_download_load
        [ "$SB_DOWNLOAD_MODE_RESOLVED" = "$1" ]
        [ "$SB_DOWNLOAD_SOURCE_RESOLVED" = "$2" ]
        [ "$SB_DOWNLOAD_HTTP_PROXY_RESOLVED" = "$3" ]
        [ "$SB_DOWNLOAD_GITHUB_PROXY_RESOLVED" = "$4" ]
    ' check-load "$@" || fail 'incorrect effective policy/precedence'
}
assert_transport() {
    "$HOST_PYTHON" - "$TEST_TRANSPORT_LOG" "$@" <<'PY'
import json, pathlib, sys
rows = [json.loads(s) for s in pathlib.Path(sys.argv[1]).read_text().splitlines()]
kind, proxy, bypass, url = sys.argv[2:]
assert len(rows) == 1, rows
row = rows[0]
assert row["kind"] == kind, row
for name in ("http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
    assert row["env"][name] == proxy, (name, row)
for name in ("no_proxy", "NO_PROXY"):
    assert row["env"][name] == bypass, row
if url:
    assert row["args"][-1] == url, row
assert not any("proxy-fixture-secret" in a for a in row["args"]), row
if kind == "curl":
    assert row["args"][0] == "-q", row
    assert "--max-time" in row["args"] and "--connect-timeout" in row["args"], row
PY
}

reset_logs
"$HOST_SH" -eu -c '
    before_umask=$(umask)
    before_dir=$PWD
    . "$SB_TEST_LIBRARY"
    [ "$(umask)" = "$before_umask" ] && [ "$PWD" = "$before_dir" ]
    [ "${SB_DOWNLOAD_MODE_RESOLVED+x}" != x ]
' || fail 'sourcing helper had side effects'
[ ! -s "$TEST_UCI_LOG" ] && [ ! -e "$SB_DOWNLOAD_UCI_DIR/sing-box" ] || fail 'source read/wrote UCI'
assert_load direct default '' ''
printf '%s\n' '{"sing-box.main":"sing-box","sing-box.main.config_file":"/fixture/active.json","sing-box.download":"download","sing-box.download.mode":"http","sing-box.download.http_proxy":"http://saved.example:8080"}' > "$SB_DOWNLOAD_UCI_DIR/sing-box"
assert_load http UCI http://saved.example:8080 ''
SB_DOWNLOAD_MODE=direct assert_load direct environment '' ''
SB_HTTP_PROXY=http://temporary.example:8081 assert_load http environment http://temporary.example:8081 ''
SB_GITHUB_PROXY=https://accelerator.example/prefix assert_load github environment '' https://accelerator.example/prefix/
SB_HTTP_PROXY=http://one.example SB_GITHUB_PROXY=https://two.example sb sb_download_load > "$TEST_DIR/ambiguous" 2>&1 && fail 'ambiguous environment proxies were accepted'
SB_DOWNLOAD_MODE=http SB_HTTP_PROXY= sb sb_download_load > "$TEST_DIR/empty" 2>&1 && fail 'explicit empty proxy fell back to UCI'
SB_DOWNLOAD_MODE= SB_HTTP_PROXY=http://one.example sb sb_download_load > "$TEST_DIR/empty-mode" 2>&1 && fail 'explicit empty mode was accepted'
printf 'PASS: functions-only source and environment/UCI precedence\n'

reset_logs
SB_DOWNLOAD_MODE=direct sb sb_download https://github.com/example/project/archive/main.tar.gz "$TEST_DIR/output/direct" 42
assert_transport curl http://system.example:8118 system-bypass.example https://github.com/example/project/archive/main.tar.gz
[ "$(cat "$TEST_DIR/output/direct")" = 'mock complete download' ] || fail 'complete file missing'
[ "$http_proxy" = http://system.example:8118 ] && [ "$no_proxy" = system-bypass.example ] || fail 'parent environment changed'
reset_logs
SB_DOWNLOAD_MODE=http SB_HTTP_PROXY=http://user:proxy-fixture-secret@127.0.0.1:18888 sb sb_download https://github.com/example/project/releases/download/v1/archive.tar.gz "$TEST_DIR/output/http" 42
assert_transport curl http://user:proxy-fixture-secret@127.0.0.1:18888 '' https://github.com/example/project/releases/download/v1/archive.tar.gz
reset_logs
SB_DOWNLOAD_MODE=http SB_HTTP_PROXY=http://user:proxy-fixture-secret@127.0.0.1:18888 sb sb_download_run child-command install a-package
assert_transport child-command http://user:proxy-fixture-secret@127.0.0.1:18888 '' ''
reset_logs
SB_DOWNLOAD_MODE=github SB_GITHUB_PROXY=https://accelerator.example sb sb_download_run child-command clone public-repository
assert_transport child-command http://system.example:8118 system-bypass.example ''
if SB_DOWNLOAD_MODE=direct TEST_RUN_STATUS=7 sb sb_download_run child-command >/dev/null 2>&1; then fail 'child command failure ignored'; else [ "$?" -eq 7 ] || fail 'child status changed'; fi
printf 'PASS: curl and command proxy environments are child-only; credentials stay out of argv\n'

for url in \
    https://github.com/example/project/archive/main.tar.gz \
    https://raw.githubusercontent.com/example/project/main/install.sh \
    https://codeload.github.com/example/project/tar.gz/refs/heads/main; do
    reset_logs
    SB_DOWNLOAD_MODE=github SB_GITHUB_PROXY=https://accelerator.example/prefix sb sb_download "$url" "$TEST_DIR/output/github" 42
    assert_transport curl http://system.example:8118 system-bypass.example "https://accelerator.example/prefix/$url"
done
for url in \
    https://api.github.com/repos/example/project/releases/latest \
    https://subscription.example/feed?token=fixture \
    https://github.com.evil.example/repo; do
    reset_logs
    SB_DOWNLOAD_MODE=github SB_GITHUB_PROXY=https://accelerator.example sb sb_download "$url" "$TEST_DIR/output/original" 42
    assert_transport curl http://system.example:8118 system-bypass.example "$url"
done
reset_logs
for url in \
    https://github.com/example/private?token=fixture \
    https://github.com/example/project\#fragment \
    https://user:private-fixture@github.com/example/project \
    https://user:private-fixture@subscription.example/feed \
    https://github.com@other.example/secret; do
    SB_DOWNLOAD_MODE=github SB_GITHUB_PROXY=https://accelerator.example sb sb_download "$url" "$TEST_DIR/output/rejected" 42 > "$TEST_DIR/rejected" 2>&1 && fail 'credential-bearing GitHub input accepted'
done
[ ! -s "$TEST_TRANSPORT_LOG" ] && [ ! -e "$TEST_DIR/output/rejected" ] || fail 'rejected URL reached transport'
printf 'PASS: GitHub prefix is limited to public allowlisted origins; API and subscription origins stay unchanged\n'

reset_logs
printf 'keep old complete file\n' > "$TEST_DIR/output/failure"
SB_DOWNLOAD_MODE=http SB_HTTP_PROXY=http://user:proxy-fixture-secret@127.0.0.1:18888 TEST_DOWNLOAD_FAIL=1 sb sb_download https://github.com/example/project/archive/main.tar.gz "$TEST_DIR/output/failure" 42 > "$TEST_DIR/failure-log" 2>&1 && fail 'failed transfer reported success'
[ "$(cat "$TEST_DIR/output/failure")" = 'keep old complete file' ] || fail 'failed transfer replaced complete destination'
[ "$(wc -l < "$TEST_TRANSPORT_LOG")" -eq 1 ] || fail 'download tried an unselected fallback'
! grep -q proxy-fixture-secret "$TEST_DIR/failure-log" || fail 'transport diagnostics leaked proxy credentials'
SB_DOWNLOAD_MODE=direct TEST_DOWNLOAD_FAIL=1 sb sb_download https://github.com/example/project/archive/main.tar.gz "$TEST_DIR/output/missing-failure" 42 >/dev/null 2>&1 && fail 'failed new download reported success'
[ ! -e "$TEST_DIR/output/missing-failure" ] || fail 'partial destination retained'
assert_no_staging
printf 'PASS: failures remove partial bytes, preserve complete files and never retry another route\n'

rm "$TEST_DIR/bin/curl"
for wget_kind in busybox uclient; do
    reset_logs
    TEST_WGET_KIND=$wget_kind SB_DOWNLOAD_MODE=http SB_HTTP_PROXY=http://user:proxy-fixture-secret@proxy.example:8080 sb sb_download https://github.com/example/project/archive/main.tar.gz "$TEST_DIR/output/unsupported" 30 > "$TEST_DIR/unsupported" 2>&1 && fail 'minimal wget falsely accepted HTTPS HTTP-proxy tunnel'
    [ ! -s "$TEST_TRANSPORT_LOG" ] || fail 'unsupported HTTPS proxy silently attempted a download'
    grep -q 'Install curl first' "$TEST_DIR/unsupported" || fail 'unsupported wget error has no actionable instruction'
    reset_logs
    TEST_WGET_KIND=$wget_kind SB_DOWNLOAD_MODE=direct sb sb_download https://github.com/example/project/archive/main.tar.gz "$TEST_DIR/output/minimal-wget" 30
    assert_transport wget http://system.example:8118 system-bypass.example https://github.com/example/project/archive/main.tar.gz
    reset_logs
    TEST_WGET_KIND=$wget_kind SB_DOWNLOAD_MODE=github SB_GITHUB_PROXY=https://accelerator.example sb sb_download https://raw.githubusercontent.com/example/project/main/install.sh "$TEST_DIR/output/minimal-github" 30
    assert_transport wget http://system.example:8118 system-bypass.example https://accelerator.example/https://raw.githubusercontent.com/example/project/main/install.sh
done
reset_logs
TEST_WGET_KIND=gnu SB_DOWNLOAD_MODE=http SB_HTTP_PROXY=http://user:proxy-fixture-secret@proxy.example:8080 sb sb_download https://github.com/example/project/archive/main.tar.gz "$TEST_DIR/output/gnu-wget" 30
assert_transport wget http://user:proxy-fixture-secret@proxy.example:8080 '' https://github.com/example/project/archive/main.tar.gz
"$HOST_PYTHON" - "$TEST_TRANSPORT_LOG" <<'PY'
import json, pathlib, sys
args = json.loads(pathlib.Path(sys.argv[1]).read_text())["args"]
assert "--no-config" in args and "--no-netrc" in args and "--tries=1" in args, args
assert args[args.index("-T") + 1] == "30", args
PY
ln -s "$TEST_DIR/timeout" "$TEST_DIR/bin/timeout"
reset_logs
TEST_WGET_KIND=gnu SB_DOWNLOAD_MODE=direct sb sb_download https://github.com/example/project/archive/main.tar.gz "$TEST_DIR/output/deadline" 30
grep -q '^30 wget ' "$TEST_TIMEOUT_LOG" || fail 'available total timeout wrapper ignored'
TEST_WGET_KIND=gnu TEST_TIMEOUT_FAIL=1 SB_DOWNLOAD_MODE=direct sb sb_download https://github.com/example/project/archive/main.tar.gz "$TEST_DIR/output/timeout" 30 >/dev/null 2>&1 && fail 'total timeout ignored'
[ ! -e "$TEST_DIR/output/timeout" ] || fail 'timed out destination retained'
assert_no_staging
ln -s "$TEST_DIR/transport" "$TEST_DIR/bin/curl"
printf 'PASS: GNU Wget proxy fallback and minimal OpenWrt wget capability checks/timeouts\n'

reset_logs
for invalid in 'https://proxy.example' 'http://user:pw@proxy.example/path' 'http://proxy.example?secret=x' 'http://proxy.example:0' 'http://proxy.example:65536' 'http://proxy.example:bad' 'http://user:pw@other@proxy.example' 'http://proxy.example:8080\escape'; do
    SB_DOWNLOAD_MODE=http SB_HTTP_PROXY=$invalid sb sb_download https://github.com/example/project/archive/main.tar.gz "$TEST_DIR/output/invalid" 30 >/dev/null 2>&1 && fail 'invalid HTTP proxy accepted'
done
for invalid in 'http://accelerator.example/' 'https://user:pw@accelerator.example/' 'https://accelerator.example/?token=secret' 'https://accelerator.example/#fragment'; do
    SB_DOWNLOAD_MODE=github SB_GITHUB_PROXY=$invalid sb sb_download https://github.com/example/project/archive/main.tar.gz "$TEST_DIR/output/invalid" 30 >/dev/null 2>&1 && fail 'invalid GitHub prefix accepted'
done
for invalid in 0 -1 1.5 '1;touch sentinel' '$(touch sentinel)' ''; do
    # An omitted/empty optional value uses the documented default; the others
    # must be rejected before any transport or destination mutation.
    [ -n "$invalid" ] || continue
    SB_DOWNLOAD_MODE=direct sb sb_download https://github.com/example/project/archive/main.tar.gz "$TEST_DIR/output/invalid" "$invalid" >/dev/null 2>&1 && fail 'invalid timeout accepted'
done
[ ! -s "$TEST_TRANSPORT_LOG" ] && [ ! -e "$TEST_DIR/output/invalid" ] || fail 'invalid input reached transport'
SB_DOWNLOAD_MODE=http SB_HTTP_PROXY='http://user:pw%27encoded@[::1]:8080' assert_load http environment 'http://user:pw%27encoded@[::1]:8080' ''
printf 'PASS: URL/numeric validation rejects injection without evaluating input\n'

unset SB_DOWNLOAD_MODE SB_HTTP_PROXY SB_GITHUB_PROXY
reset_logs
chmod 0644 "$SB_DOWNLOAD_UCI_DIR/sing-box"
printf '%s\n' 'http://user:proxy-fixture-secret@proxy.example:18888' | cli set http --stdin > "$TEST_DIR/cli-save"
[ "$(stat -c %a "$SB_DOWNLOAD_UCI_DIR/sing-box")" = 600 ] || fail 'proxy configuration was not private'
assert_load http UCI http://user:proxy-fixture-secret@proxy.example:18888 ''
cli show > "$TEST_DIR/cli-show"
grep -q 'Source: UCI' "$TEST_DIR/cli-show" || fail 'show omitted configuration source'
grep -Fq 'http://***@proxy.example:18888' "$TEST_DIR/cli-show" || fail 'show omitted redacted endpoint'
! grep -q 'proxy-fixture-secret\|http://user:' "$TEST_DIR/cli-save" "$TEST_DIR/cli-show" "$TEST_UCI_LOG" || fail 'CLI or UCI arguments leaked credentials'
SB_DOWNLOAD_MODE=direct cli show > "$TEST_DIR/cli-env"
grep -q 'Source: environment' "$TEST_DIR/cli-env" || fail 'show ignored environment override'
"$HOST_PYTHON" - "$SB_DOWNLOAD_UCI_DIR/sing-box" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert state["sing-box.main.config_file"] == "/fixture/active.json", state
assert state["sing-box.download.http_proxy"] == "http://user:proxy-fixture-secret@proxy.example:18888", state
PY
printf '%s\n' 'https://accelerator.example/private-prefix-token' | cli set github --stdin > "$TEST_DIR/cli-save"
assert_load github UCI '' https://accelerator.example/private-prefix-token/
cli show > "$TEST_DIR/cli-show"
! grep -q private-prefix-token "$TEST_DIR/cli-show" || fail 'show exposed prefix path'
grep -q 'api.github.com' "$TEST_DIR/cli-show" || fail 'show omitted GitHub API limitation'
! grep -q proxy-fixture-secret "$SB_DOWNLOAD_UCI_DIR/sing-box" || fail 'mode change retained inactive proxy password'
cli set direct >/dev/null
assert_load direct UCI '' ''
cli clear >/dev/null
assert_load direct default '' ''
"$HOST_PYTHON" - "$SB_DOWNLOAD_UCI_DIR/sing-box" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert state == {"sing-box.main": "sing-box", "sing-box.main.config_file": "/fixture/active.json"}, state
PY
printf 'PASS: CLI stdin persistence, 0600 permissions, redacted display, mode changes and clear preserve service settings\n'

cp "$SB_DOWNLOAD_UCI_DIR/sing-box" "$TEST_DIR/before-invalid"
reset_logs
printf '%s\n%s\n' http://proxy.example:8080 'set sing-box.main.config_file=/malicious' | cli set http --stdin >/dev/null 2>&1 && fail 'multiline proxy input accepted'
printf '%s\n' "http://user:quote'@proxy.example:8080" | cli set http --stdin >/dev/null 2>&1 && fail 'quote injection accepted'
cmp "$SB_DOWNLOAD_UCI_DIR/sing-box" "$TEST_DIR/before-invalid" || fail 'invalid CLI input modified saved settings'
[ ! -s "$TEST_UCI_LOG" ] || fail 'invalid CLI input invoked UCI'
printf '%s\n' http://proxy.example:8080 | TEST_UCI_FAIL=1 cli set http --stdin > "$TEST_DIR/uci-failure" 2>&1 && fail 'failed UCI commit reported success'
cmp "$SB_DOWNLOAD_UCI_DIR/sing-box" "$TEST_DIR/before-invalid" || fail 'failed UCI fixture changed committed settings'
[ ! -e "$SB_DOWNLOAD_UCI_DIR/sing-box.pending" ] || fail 'failed save left pending credentials'
printf '%s\n' http://proxy.example:8080 | TEST_UCI_DROP_SET=1 cli set http --stdin > "$TEST_DIR/uci-failure" 2>&1 && fail 'silently failed UCI batch setting reported success'
cmp "$SB_DOWNLOAD_UCI_DIR/sing-box" "$TEST_DIR/before-invalid" || fail 'partial UCI batch changed committed settings'
[ ! -e "$SB_DOWNLOAD_UCI_DIR/sing-box.pending" ] || fail 'partial save left pending settings'
rm "$SB_DOWNLOAD_UCI_DIR/sing-box"
printf '%s\n' http://proxy.example:8080 | cli set http --stdin > "$TEST_DIR/new-uci-package"
assert_load http UCI http://proxy.example:8080 ''
[ "$(stat -c %a "$SB_DOWNLOAD_UCI_DIR/sing-box")" = 600 ] || fail 'new proxy package was not private'
printf 'PASS: CLI rejects multiline/quote injection before mutation and reports persistence failure\n'
printf 'All download proxy tests passed (mock network only; no live router compatibility claim).\n'
