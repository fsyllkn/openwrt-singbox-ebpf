#!/bin/sh
# Behavioral filter/UID-guard regressions. Only temporary JSON and mocked
# core/process/service interfaces are touched; no actual network or daemon use.
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required for these tests' >&2; exit 1; }
python3 - "$BASE" <<'PY'
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

base = Path(sys.argv[1])

with tempfile.TemporaryDirectory(prefix='sbctl-portability-') as temp:
    root = Path(temp)
    home = root / 'service home'
    target = root / 'custom config' / 'active-target.json'
    active = root / 'custom config' / 'active.json'
    proc = root / 'proc'
    tools = root / 'tools'
    core_log = root / 'core.log'
    service_log = root / 'service.log'
    pid_file = root / 'pids'
    for path in [home / 'bin', home / 'runtime', target.parent, tools, proc]:
        path.mkdir(parents=True, exist_ok=True)
    active.symlink_to(target)
    core_log.touch()
    service_log.touch()
    pid_file.write_text('')

    def executable(path, content):
        path.write_text(content)
        path.chmod(0o755)

    executable(home / 'bin' / 'sing-box', '''#!/bin/sh
set -eu
[ "$1" = check ] && [ "$2" = -c ] && [ "$#" -eq 3 ] || exit 64
[ "$PWD" = "$SH_SINGBOX_HOME" ] || exit 65
printf '%s\\n' "$3" >> "$CORE_LOG"
[ "${MOCK_CHECK_STATUS:-0}" -eq 0 ] || exit "$MOCK_CHECK_STATUS"
jq -e 'type == "object" and (.inbounds | type == "array")' "$3" >/dev/null
''')
    executable(tools / 'id', '#!/bin/sh\n[ "$*" = -u ] || exit 64\necho 0\n')
    executable(tools / 'pidof', '#!/bin/sh\n[ "$*" = x-tunnel ] || exit 64\ncat "$PID_FILE"\n')
    executable(tools / 'ip', '''#!/bin/sh
[ "$*" = '-4 -o addr show' ] || exit 64
echo '3: br-edge.42 inet 10.23.40.45/23 scope global br-edge.42'
''')
    for name in ['systemctl', 'journalctl']:
        executable(tools / name, '#!/bin/sh\nprintf "%s\\n" "$*" >> "$SERVICE_LOG"\nexit 99\n')
    env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'],
               SH_SINGBOX_HOME=str(home), SH_SINGBOX_CONFIG=str(active),
               SB_PROC_ROOT=str(proc), PID_FILE=str(pid_file),
               CORE_LOG=str(core_log), SERVICE_LOG=str(service_log))
    original = {
        'inbounds': [
            {'type': 'mixed', 'tag': 'mixed-first', 'listen': '127.0.0.1',
             'listen_port': 17890, 'users': [{'username': 'fixture', 'password': 'fixture-only'}]},
            {'type': 'ebpf', 'tag': 'active-a', 'network': ['tcp', 'udp'],
             'udp_timeout': '13m', 'local': {'enabled': True, 'data_plane': 'cgroup',
             'bypass_private_address': False, 'include_uid': [], 'include_uid_range': [],
             'exclude_uid': 88, 'exclude_uid_range': '200:250'}},
            {'type': 'tproxy', 'tag': 'custom-tproxy', 'listen': '::',
             'listen_port': 1536, 'udp_timeout': '17m'},
            {'type': 'ebpf', 'tag': 'disabled', 'local': {'enabled': False,
             'include_uid': [17], 'exclude_uid': [900], 'exclude_uid_range': ['1:100']}},
            {'type': 'ebpf', 'tag': 'active-b', 'local': {'enabled': True,
             'include_uid': [42, 700], 'include_uid_range': ['1000:1100'],
             'exclude_uid': [2], 'exclude_uid_range': []}}
        ],
        'outbounds': [{'type': 'socks', 'tag': 'remote-private',
                       'server': '198.51.100.8', 'server_port': 1080},
                      {'type': 'direct', 'tag': 'local-direct'}],
        'route': {'rules': [
            {'action': 'sniff'},
            {'protocol': 'dns', 'action': 'hijack-dns'},
            {'ip_cidr': ['10.77.0.0/24'], 'action': 'route', 'outbound': 'remote-private'},
            {'process_name': ['x-tunnel', 'sshd'], 'outbound': 'remote-private'},
            {'process_name': ['sshd'], 'ip_cidr': ['172.16.0.0/16'], 'outbound': 'local-direct'},
            {'ip_is_private': True, 'outbound': 'local-direct'}], 'final': 'remote-private'},
        'providers': [{'type': 'local', 'tag': 'custom-nodes', 'path': '/data/custom-nodes.json'}]
    }

    def save(config):
        target.write_text(json.dumps(config, indent=2) + '\n')

    def load():
        return json.loads(target.read_text())

    def run(*args, ok=True, extra_env=None, contains=None):
        result = subprocess.run(['bash', str(base / 'scripts' / 'sbctl'), *args],
                                env=dict(env, **(extra_env or {})), text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert (result.returncode == 0) == ok, (args, result.returncode, result.stdout)
        if contains is not None:
            assert contains in result.stdout, (args, contains, result.stdout)
        return result

    def unchanged(previous):
        assert target.read_bytes() == previous, 'active JSON changed on rejected request'
        assert active.is_symlink() and active.resolve() == target, 'active symlink was replaced'
        assert not list(target.parent.glob(target.name + '.filter.*')), 'staged filter file leaked'

    def preserve_non_uid(before, after):
        for key in ['route', 'outbounds', 'providers']:
            assert after[key] == before[key], key + ' changed'
        assert len(after['inbounds']) == len(before['inbounds'])
        uid_keys = {'include_uid', 'include_uid_range', 'exclude_uid', 'exclude_uid_range'}
        for old, new in zip(before['inbounds'], after['inbounds']):
            if old['type'] != 'ebpf' or not old.get('local', {}).get('enabled'):
                assert new == old, 'unrelated or disabled inbound changed'
            else:
                assert {k: v for k, v in new.items() if k != 'local'} == {
                    k: v for k, v in old.items() if k != 'local'}
                assert {k: v for k, v in new['local'].items() if k not in uid_keys} == {
                    k: v for k, v in old['local'].items() if k not in uid_keys}

    def filter_selection_and_backup():
        save(original)
        before_bytes = target.read_bytes()
        old_backups = set(target.parent.glob(target.name + '.before-filter.*'))
        result = run('filter', 'show')
        for tag in ['active-a', 'active-b', 'disabled']:
            assert tag in result.stdout
        run('filter', 'exclude-user', '700')
        modified = load()
        preserve_non_uid(original, modified)
        assert modified['inbounds'][1]['local']['exclude_uid'] == [88, 700]
        assert modified['inbounds'][4]['local']['exclude_uid'] == [2, 700]
        backups = set(target.parent.glob(target.name + '.before-filter.*')) - old_backups
        assert len(backups) == 1
        backup = backups.pop()
        assert backup.read_bytes() == before_bytes
        assert (backup.stat().st_mode & 0o777) == 0o600
        assert (target.stat().st_mode & 0o777) == 0o600
        assert active.is_symlink()
        assert core_log.read_text().splitlines()[-1].startswith(str(target) + '.filter.')
        run('filter', 'remove-user', '700')
        assert load()['inbounds'][1]['local']['exclude_uid'] == [88]
        assert load()['inbounds'][4]['local']['exclude_uid'] == [2]
        run('filter', 'include-user', '42')
        for index in [1, 4]:
            assert load()['inbounds'][index]['local']['include_uid'] == [42]
            assert load()['inbounds'][index]['local']['include_uid_range'] == []
        run('filter', 'reset')
        after = load()
        preserve_non_uid(original, after)
        for index in [1, 4]:
            for key in ['include_uid', 'include_uid_range', 'exclude_uid', 'exclude_uid_range']:
                assert after['inbounds'][index]['local'][key] == []

    def rejected_filters_are_atomic():
        save(original)
        before = target.read_bytes()
        backups = set(target.parent.glob(target.name + '.before-filter.*'))
        run('filter', 'exclude-user', '700', ok=False, extra_env={'MOCK_CHECK_STATUS': '27'},
            contains='original configuration unchanged')
        unchanged(before)
        assert set(target.parent.glob(target.name + '.before-filter.*')) == backups
        run('filter', 'include-user', '225', ok=False, contains='within exclude_uid_range')
        unchanged(before)
        sentinel = root / 'injection-created'
        for value in ['-1', '4294967296', '1.5', '0] | .route.rules=[] | [0',
                      '0; touch ' + str(sentinel), '$(touch ' + str(sentinel) + ')']:
            run('filter', 'exclude-user', value, ok=False, contains='uint32_uid')
            unchanged(before)
        assert not sentinel.exists()
        config = copy.deepcopy(original)
        for inbound in config['inbounds']:
            if inbound['type'] == 'ebpf':
                inbound['local']['enabled'] = False
        save(config)
        before = target.read_bytes()
        run('filter', 'exclude-user', '700', ok=False, contains='No enabled local eBPF')
        unchanged(before)

    def process_rules_preserve_custom_policy():
        save(original)
        run('filter', 'exclude-proc', 'sshd')
        after = load()
        managed = {'process_name': ['sshd'], 'action': 'route', 'outbound': 'local-direct'}
        assert after['route']['rules'][2] == managed
        assert after['route']['rules'][:2] + after['route']['rules'][3:] == original['route']['rules']
        assert after['inbounds'] == original['inbounds']
        assert after['outbounds'] == original['outbounds']
        run('filter', 'remove-proc', 'sshd')
        assert load() == original, 'process removal altered custom scoped/remote rules'
        config = copy.deepcopy(original)
        config['route']['rules'].insert(2, {'process_name': 'curl', 'outbound': 'local-direct'})
        save(config)
        run('filter', 'exclude-proc', 'sshd')
        after = load()
        assert after['route']['rules'][2]['process_name'] == ['curl', 'sshd']
        assert after['route']['rules'][3:] == config['route']['rules'][3:]
        run('filter', 'remove-proc', 'sshd')
        assert load()['route']['rules'][2]['process_name'] == ['curl']
        config['outbounds'].append({'type': 'direct', 'tag': 'second-direct'})
        save(config)
        before = target.read_bytes()
        run('filter', 'exclude-proc', 'sshd', ok=False, contains='unique direct outbound')
        unchanged(before)
        config['outbounds'].append({'type': 'direct', 'tag': 'direct'})
        save(config)
        run('filter', 'exclude-proc', 'sshd')
        assert any(rule.get('process_name') == ['sshd'] and rule.get('outbound') == 'direct'
                   for rule in load()['route']['rules'])

    def guard(policies, identities, ok, contains=None, vanished=(), missing=(), raw_pids=None):
        for child in proc.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
        config = copy.deepcopy(original)
        config['inbounds'] = [copy.deepcopy(original['inbounds'][0])]
        for index, policy in enumerate(policies):
            config['inbounds'].append({'type': 'ebpf', 'tag': 'guard-' + str(index),
                                       'local': dict(enabled=True, **policy)})
        config['inbounds'].append({'type': 'ebpf', 'tag': 'disabled-capture-all',
                                   'local': {'enabled': False}})
        save(config)
        for pid, uids in identities.items():
            folder = proc / str(pid)
            folder.mkdir()
            values = [uids] * 4 if isinstance(uids, int) else uids
            (folder / 'status').write_text('Name:\tx-tunnel\nUid:\t' + '\t'.join(map(str, values)) + '\n')
        for pid in missing:
            (proc / str(pid)).mkdir()
        all_pids = [*identities, *vanished, *missing]
        pid_file.write_text(raw_pids if raw_pids is not None else ' '.join(map(str, all_pids)))
        before = target.read_bytes()
        result = run('check-xtunnel', ok=ok, contains=contains)
        unchanged(before)
        return result

    def actual_uids_and_all_pids():
        guard([{'exclude_uid': 700}], {101: 700}, True)
        guard([{'exclude_uid': [700]}], {101: 700, 102: 701}, False, 'PID 102 (UID 701)')
        guard([{'exclude_uid': [700]}, {}], {101: 700}, False, 'would be captured')
        guard([{'exclude_uid': 700}, {'include_uid': [701]}], {101: 700}, True)
        guard([{'exclude_uid': 0}], {101: 0}, True)
        guard([{}], {101: 0}, False, 'UID 0')
        guard([{'include_uid': [700]}], {101: 0}, True)
        guard([], {101: 0}, True)

    def implicit_local_enablement_matches_pinned_core():
        folder = proc / '501'
        folder.mkdir(exist_ok=True)
        (folder / 'status').write_text('Name:\tx-tunnel\nUid:\t700\t700\t700\t700\n')
        pid_file.write_text('501')
        variants = [
            ({}, True),
            ({'local': {}, 'shared': {}}, True),
            ({'local': {'enabled': None}, 'shared': {'enabled': None}}, True),
            ({'local': {'enabled': None}}, True),
            ({'shared': {'enabled': None}}, True),
            ({'local': {'enabled': False}}, False),
            ({'local': {'enabled': False}, 'shared': {'enabled': None}}, False),
            ({'shared': {'enabled': True}}, False),
            ({'local': {'enabled': None}, 'shared': {'enabled': True}}, False),
        ]
        for options, enabled in variants:
            config = copy.deepcopy(original)
            inbound = dict(type='ebpf', tag='default-enablement', **copy.deepcopy(options))
            config['inbounds'] = [copy.deepcopy(original['inbounds'][0]), inbound,
                                  copy.deepcopy(original['inbounds'][3])]
            save(config)
            before = target.read_bytes()
            try:
                run('check-xtunnel', ok=not enabled)
                unchanged(before)
                if enabled:
                    run('filter', 'exclude-user', '700')
                    expected = copy.deepcopy(config)
                    expected['inbounds'][1].setdefault('local', {})['exclude_uid'] = [700]
                    assert load() == expected, 'filter changed explicit/null enablement or unrelated options'
                    run('check-xtunnel')
                else:
                    run('filter', 'exclude-user', '700', ok=False, contains='No enabled local eBPF')
                    unchanged(before)
            except AssertionError as error:
                raise AssertionError((options, enabled, error)) from error

    def inclusive_ranges_and_number_bases():
        for encoded in ['700:700', '0x2bc:0x2bc', '0X2BC:0X2BC', '0o1274:0o1274',
                        '01274:01274', '0b1010111100:0b1010111100', '7_00:7_00',
                        '0x_2_bc:0x_2_bc', '0o_12_74:0o_12_74',
                        '0b_1010_1111_00:0b_1010_1111_00', '0_1274:0_1274']:
            guard([{'exclude_uid_range': encoded}], {101: 700}, True)
        guard([{'exclude_uid_range': ['699:701']}], {101: 699, 102: 700, 103: 701}, True)
        guard([{'exclude_uid_range': '699:701'}], {101: 702}, False, 'UID 702')
        guard([{'include_uid_range': '700:710'}], {101: 699}, True)
        guard([{'include_uid_range': ['700:710']}], {101: 700}, False, 'UID 700')
        guard([{'include_uid_range': '700:710'}], {101: 710}, False, 'UID 710')
        guard([{'include_uid': 700, 'exclude_uid_range': '700:700'}], {101: 700}, True)
        guard([{'include_uid_range': ['700:710'], 'exclude_uid': [700]}], {101: 700}, True)
        guard([{'include_uid': [701]}], {101: 700}, True)

    def uid_number_grammar_and_uint32_bounds():
        # UID parsing must not rely on jq's optional regex engine. Exercise
        # the actual process guard with scalar/array selectors and keep the
        # accepted Go-style bases/separators and uint32 boundary intact.
        for encoded, uid in [
                ('0', 0), ('00', 0), ('0_0', 0), ('0x_0', 0),
                ('0o_0', 0), ('0b_0', 0), ('123_456', 123456),
                ('4294967295', 4294967295), ('4_294_967_295', 4294967295),
                ('0xffffffff', 4294967295), ('0X_FF_FF_FF_FF', 4294967295),
                ('0o37777777777', 4294967295), ('037777777777', 4294967295),
                ('0b11111111111111111111111111111111', 4294967295)]:
            try:
                guard([{'exclude_uid': encoded}], {101: uid}, True)
                guard([{'exclude_uid': [encoded]}], {101: uid}, True)
            except AssertionError as error:
                raise AssertionError((encoded, uid, error)) from error
        for encoded in ['', '_', '_0', '0_', '0__0', '00_', '0x', '0x_',
                        '0x__0', '0x0_', '0xg', '0o8', '0b2', '08', '0_8',
                        '00__1', '01_8', '1__0', '1_', '+700', '-1',
                        ' 700', '700 ', '700\n', '700\r', '７００', '١٠',
                        '4294967296', '0x100000000', '040000000000',
                        '0b100000000000000000000000000000000',
                        -1, 4294967296, 700.5, True, {}]:
            try:
                guard([{'exclude_uid': [encoded]}], {101: 700}, False,
                      'Cannot evaluate eBPF UID selectors')
            except AssertionError as error:
                raise AssertionError((encoded, error)) from error

    def inconsistent_or_unreadable_credentials():
        for fields in [[700, 701, 700, 700], [700, 700, 701, 700], [700, 700, 700, 701]]:
            guard([{'exclude_uid_range': '0:1000'}], {101: fields}, False, 'mixed real/effective/saved/fs')
        guard([{}], {}, True, vanished=[101])
        guard([{}], {}, False, 'Cannot read X-Tunnel PID 101', missing=[101])
        guard([{}], {101: ['invalid', 700, 700, 700]}, False, 'Invalid UID fields')
        guard([{}], {}, False, 'Invalid X-Tunnel PID', raw_pids='101;invalid')

    def invalid_policy_does_not_pass_the_guard():
        for policy in [{'exclude_uid_range': '710:700'}, {'exclude_uid_range': '700:701:702'},
                       {'exclude_uid_range': '0:4294967296'}, {'exclude_uid_range': '7__0_0:710'},
                       {'exclude_uid_range': '_700:710'}, {'exclude_uid_range': '700_:710'},
                       {'exclude_uid_range': '0x:710'}, {'exclude_uid_range': '0o8:710'},
                       {'exclude_uid_range': '0b2:710'}]:
            try:
                guard([policy], {101: 700}, False, 'Cannot evaluate eBPF UID selectors')
            except AssertionError as error:
                raise AssertionError((policy, error)) from error

    def malformed_json_does_not_mean_disabled_ebpf():
        pid_file.write_text('101')
        target.write_text('{ invalid JSON\n')
        run('check-xtunnel', ok=False)

    failures = []
    for case in [filter_selection_and_backup, rejected_filters_are_atomic,
                 process_rules_preserve_custom_policy, actual_uids_and_all_pids,
                 implicit_local_enablement_matches_pinned_core,
                 inclusive_ranges_and_number_bases, uid_number_grammar_and_uint32_bounds,
                 inconsistent_or_unreadable_credentials,
                 invalid_policy_does_not_pass_the_guard, malformed_json_does_not_mean_disabled_ebpf]:
        try:
            pid_file.write_text('')
            case()
            print('PASS', case.__name__)
        except AssertionError as error:
            failures.append(case.__name__)
            print('FAIL', case.__name__, str(error), file=sys.stderr)
    assert not service_log.read_text(), 'a filter/guard invoked a service command'
    if failures:
        raise SystemExit(1)
    print('sbctl portability, filter preservation and actual-UID guard tests passed.')
PY
