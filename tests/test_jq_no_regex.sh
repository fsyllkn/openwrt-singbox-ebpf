#!/usr/bin/env bash
# This gate must run with a real jq built --without-oniguruma. The remaining
# integration suites inherit the same selected binary through PATH in CI.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d /tmp/sb-jq-no-regex.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
command -v jq >/dev/null 2>&1 || { echo 'FAILED: jq is missing' >&2; exit 1; }
jq --version
jq -en '(["a","b"] | join(":")) == "a:b" and ("a:b" | split(":")) == ["a","b"]' >/dev/null
for filter in '"abc" | test("a")' '"abc" | match("a")' \
    '"abc" | capture("(?<first>a)")' '"abc" | scan("a")' \
    '"abc" | sub("a";"b")' '"abc" | gsub("a";"b")' '"abc" | splits("b")'; do
    if jq -n "$filter" > "$TEST_DIR/probe.out" 2> "$TEST_DIR/probe.err"; then
        echo 'FAILED: test environment still provides jq regex support' >&2
        exit 1
    fi
    grep -Fq 'ONIGURUMA' "$TEST_DIR/probe.err" || {
        cat "$TEST_DIR/probe.err" >&2
        echo 'FAILED: jq failed for a reason other than missing regex support' >&2
        exit 1
    }
done

# Run the production controller's start path: the core check succeeds, then
# real jq must inspect a LAN listener and the upstream process UID before the
# service start action. Only process/address/core/service boundaries are mocked.
python3 - "$BASE" "$TEST_DIR" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

base, root = map(Path, sys.argv[1:3])
home = root / 'service'
scripts = home / 'scripts'
tools = root / 'tools'
proc = root / 'proc'
events = root / 'events'
state = root / 'running'
for path in (scripts, tools, home / 'bin', home / 'config', proc / '401'):
    path.mkdir(parents=True)
for name in ('sbctl', 'runtime-paths.sh', 'config-parts-lib.sh'):
    shutil.copyfile(base / 'scripts' / name, scripts / name)
# Keep this fixture safe if somebody runs it on an OpenWrt test host, too.
controller = scripts / 'sbctl'
controller.write_text(controller.read_text().replace('INIT_SYSTEM="$(detect_init)"', 'INIT_SYSTEM=systemd'))

def executable(path, body):
    path.write_text(body)
    path.chmod(0o755)

executable(home / 'bin/sing-box', '''#!/bin/sh
case "$1" in
    check)
        printf 'core-check\n' >> "$NO_REGEX_EVENTS"
        [ "$2" = -c ] || exit 81
        jq -e 'type=="object" and (.inbounds|type=="array")' "$3" >/dev/null ;;
    tools) printf 'fixture eBPF status\n' ;;
    *) exit 82 ;;
esac
''')
executable(tools / 'ip', '''#!/bin/sh
[ "$*" = '-4 -o addr show' ] || exit 83
printf '3: br-test inet 10.23.40.45/24 scope global br-test\n'
''')
executable(tools / 'pidof', '''#!/bin/sh
[ "$*" = x-tunnel ] || exit 84
printf '401\n'
''')
executable(tools / 'systemctl', '''#!/bin/sh
case "$*" in
    'start sing-box.service') printf 'service-start\n' >> "$NO_REGEX_EVENTS"; : > "$NO_REGEX_STATE" ;;
    'is-active --quiet sing-box.service') [ -f "$NO_REGEX_STATE" ] ;;
    *) exit 85 ;;
esac
''')
(proc / '401/status').write_text('Uid:\t29002\t29002\t29002\t29002\n')
config = home / 'config/config.json'
document = {'inbounds': [
    {'type': 'ebpf', 'local': {'enabled': True, 'exclude_uid': ['0x_714a']}},
    {'type': 'mixed', 'tag': 'lan-mixed', 'listen': '10.23.40.45', 'listen_port': 7891},
]}
env = {**os.environ, 'PATH': str(tools) + os.pathsep + os.environ['PATH'],
       'SH_SINGBOX_HOME': str(home), 'SH_SINGBOX_CONFIG': str(config),
       'SB_PROC_ROOT': str(proc), 'NO_REGEX_EVENTS': str(events), 'NO_REGEX_STATE': str(state)}
for key in ('SB_CONFIG_PARTS_TOOL', 'SB_CONFIG_PARTS_EXPECTED'):
    env.pop(key, None)
bash = shutil.which('bash')
assert bash

def start(expected):
    config.write_text(json.dumps(document) + '\n')
    events.write_text('')
    state.unlink(missing_ok=True)
    result = subprocess.run([bash, str(controller), 'start'], env=env,
                            capture_output=True, text=True, timeout=15)
    output = result.stdout + result.stderr
    assert (result.returncode == 0) == expected, output
    assert 'ONIGURUMA' not in output, output
    actions = events.read_text().splitlines()
    assert actions.count('core-check') == 1, actions
    return output, actions

output, actions = start(True)
assert 'Configuration valid; cache refreshed' in output, output
assert 'IPv4 listener addresses are assigned' in output, output
assert actions == ['core-check', 'service-start'], actions

document['inbounds'][1]['listen'] = '10.23.40.46'
output, actions = start(False)
assert 'not assigned to this host' in output, output
assert actions == ['core-check'], actions

document['inbounds'][1]['listen'] = '10.23.40.45'
document['inbounds'][0]['local']['exclude_uid'] = []
output, actions = start(False)
assert 'would be captured by local eBPF' in output, output
assert actions == ['core-check'], actions
print('Real no-regex jq: startup, live LAN bind checks and upstream UID protection passed.')
PY
