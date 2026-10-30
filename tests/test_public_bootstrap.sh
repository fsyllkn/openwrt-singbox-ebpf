#!/bin/sh
# Execute the standalone bootstrap against isolated archives and mock downloads.
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
python3 - "$BASE" <<'PY'
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

base = Path(sys.argv[1])
source = (base / 'quick-install.sh').read_text()
start = '# BEGIN SHARED DOWNLOAD LIBRARY\n'
end = '# END SHARED DOWNLOAD LIBRARY\n'
assert source.count(start) == source.count(end) == 1, 'Missing/duplicate standalone download library'
embedded = source.split(start, 1)[1].split(end, 1)[0]
assert embedded == (base / 'scripts/download.sh').read_text().rstrip('\n') + '\n', 'Run python3 tools/sync-bootstrap.py after changing download.sh'
public_url = 'https://github.com/fsyllkn/openwrt-singbox-ebpf/archive/refs/heads/main.tar.gz'

with tempfile.TemporaryDirectory(prefix='sb-public-bootstrap-') as directory:
    root = Path(directory)
    tools = root / 'tools'
    tools.mkdir()
    archive_source = root / 'public-source'
    for name in ('scripts', 'openwrt', 'config', 'providers', 'examples'):
        (archive_source / name).mkdir(parents=True)
    for name in ('quick-install.sh', 'install.sh', 'uninstall.sh', 'README.md'):
        shutil.copyfile(base / name, archive_source / name)
    (archive_source / 'menu.sh').write_text('#!/bin/sh\nexit 0\n')
    for name in ('sbctl', 'runtime-paths.sh', 'download.sh', 'configure-download.sh', 'gateway.sh', 'dns-guard.sh', 'update-core.sh'):
        shutil.copyfile(base / 'scripts' / name, archive_source / 'scripts' / name)
    shutil.copyfile(base / 'openwrt/sing-box.init', archive_source / 'openwrt/sing-box.init')
    (archive_source / 'config/config.template.json').write_text('{"public_template":true}\n')
    (archive_source / 'config/config.json').write_text('{"must_not_replace_device":true}\n')
    (archive_source / 'providers/provider.template.json').write_text('{"outbounds":[]}\n')
    for name in ('xboard.sample.json', 'local.sample.json'):
        shutil.copyfile(base / 'examples' / name, archive_source / 'examples' / name)
    (archive_source / 'providers/downloaded.json').write_text('{"must_not_copy":true}\n')
    (archive_source / 'providers/xboard.json').write_text('{"real_runtime_cache":"must_not_copy"}\n')
    (archive_source / 'providers/local.json').write_text('{"real_local_nodes":"must_not_copy"}\n')
    (archive_source / 'examples/README.md').write_text('Public example instructions\n')
    archive = root / 'public-main.tar.gz'
    with tarfile.open(archive, 'w:gz') as bundle:
        bundle.add(archive_source, arcname='openwrt-singbox-ebpf-main')
    (root / 'openwrt_release').write_text('fixture\n')
    launcher = root / 'sb-launcher'
    bootstrap = root / 'bootstrap.sh'
    bootstrap.write_text(source.replace('/etc/openwrt_release', str(root / 'openwrt_release')).replace('/usr/bin/sb', str(launcher)))
    (tools / 'id').write_text('#!/bin/sh\n[ "$*" = -u ] || exit 98\nprintf "0\\n"\n')
    (tools / 'uci').write_text('''#!/bin/sh
if [ "${1:-}" = -c ]; then shift 2; fi
case "$*" in
 '-q get sing-box.download.mode') printf '%s\\n' "${MOCK_SAVED_MODE:-direct}" ;;
 '-q get sing-box.download.http_proxy') printf '%s\\n' 'http://saved.invalid:8080' ;;
 '-q get sing-box.download.github_proxy') printf '%s\\n' 'https://saved.invalid/' ;;
 *) exit 1 ;;
esac
''')
    (tools / 'curl').write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
output = args[args.index('--output') + 1]
url = args[-1]
pathlib.Path(os.environ['BOOT_DOWNLOAD_LOG']).write_text(json.dumps({'url':url,'http_proxy':os.environ.get('http_proxy'),'https_proxy':os.environ.get('https_proxy'),'no_proxy':os.environ.get('no_proxy')}))
if os.environ.get('BOOT_FAIL') == '1':
 pathlib.Path(output).write_text('incomplete')
 sys.exit(7)
pathlib.Path(output).write_bytes(pathlib.Path(os.environ['BOOT_ARCHIVE']).read_bytes())
''')
    for tool in tools.iterdir():
        tool.chmod(0o755)
    env = os.environ.copy()
    for name in ('SB_DOWNLOAD_MODE', 'SB_HTTP_PROXY', 'SB_GITHUB_PROXY'):
        env.pop(name, None)
    env.update(PATH=str(tools) + os.pathsep + env['PATH'], BOOT_ARCHIVE=str(archive), BOOT_DOWNLOAD_LOG=str(root / 'download-log'), SB_DOWNLOAD_UCI_DIR=str(root / 'uci'),
               http_proxy='http://environment.invalid:8080', https_proxy='http://environment.invalid:8080', all_proxy='http://environment.invalid:8080',
               HTTP_PROXY='http://environment.invalid:8080', HTTPS_PROXY='http://environment.invalid:8080', ALL_PROXY='http://environment.invalid:8080', no_proxy='example.invalid', NO_PROXY='example.invalid')
    cases = (
        ('direct', ['--direct'], public_url, 'http://environment.invalid:8080'),
        ('http', ['--http-proxy', 'http://127.0.0.1:28080'], public_url, 'http://127.0.0.1:28080'),
        ('github', ['--github-proxy', 'https://accelerator.example.invalid/'], 'https://accelerator.example.invalid/' + public_url, 'http://environment.invalid:8080'),
        ('saved', [], 'https://saved.invalid/' + public_url, 'http://environment.invalid:8080'),
    )
    for name, flags, wanted_url, wanted_proxy in cases:
        target = root / ('installed source ' + name)
        current = dict(env, SB_INSTALL_SOURCE_DIR=str(target), MOCK_SAVED_MODE='github')
        result = subprocess.run(['sh', str(bootstrap), '--no-menu', *flags], env=current, capture_output=True, text=True)
        assert result.returncode == 0, f'{name} bootstrap failed: {result.stderr}'
        call = json.loads((root / 'download-log').read_text())
        assert call['url'] == wanted_url, f'{name} did not use the public main URL and chosen transport'
        assert call['http_proxy'] == call['https_proxy'] == wanted_proxy, f'{name} proxy environment differs'
        if name == 'http':
            assert call['no_proxy'] == '', 'Explicit HTTP mode silently bypassed selected proxy'
        assert (target / 'scripts/download.sh').is_file(), 'Shared downloader was not deployed'
        assert not (target / 'config/config.json').exists(), 'Bootstrap copied the source config over a device config location'
        assert not (target / 'providers/downloaded.json').exists(), 'Bootstrap copied a provider cache'
        for provider in ('xboard', 'local'):
            assert not (target / 'providers' / (provider + '.json')).exists(), 'Bootstrap copied runtime provider data'
            assert (target / 'examples' / (provider + '.sample.json')).read_bytes() == (archive_source / 'examples' / (provider + '.sample.json')).read_bytes(), 'Public provider sample missing from source'
            assert not (target / 'providers' / (provider + '.sample.json')).exists(), 'Bootstrap mixed source samples with installed provider files'
        assert (target / 'examples/README.md').is_file(), 'Generic feature examples were lost'
        assert str(target / 'menu.sh') in launcher.read_text(), 'Launcher points outside selected source'
        print('PASS standalone ' + name + ' download mode')

    target = root / 'installed source github'
    (target / 'config/config.json').write_text('{"device_config":"keep"}\n')
    (target / 'providers/local.json').write_text('{"device_provider":"keep"}\n')
    (target / 'providers/xboard.json').symlink_to(root / 'missing-runtime-provider')
    (target / 'examples/xboard.sample.json').write_text('{"edited_sample":"keep"}\n')
    (target / 'examples/local.sample.json').unlink()
    (target / 'examples/local.sample.json').symlink_to(root / 'missing-source-sample')
    current = dict(env, SB_INSTALL_SOURCE_DIR=str(target), SB_DOWNLOAD_MODE='github', SB_GITHUB_PROXY='https://accelerator.example.invalid/')
    result = subprocess.run(['sh', str(bootstrap), '--update', '--no-menu'], env=current, capture_output=True, text=True)
    assert result.returncode == 0, 'Online archive update failed'
    assert (target / 'config/config.json').read_text() == '{"device_config":"keep"}\n'
    assert (target / 'providers/local.json').read_text() == '{"device_provider":"keep"}\n'
    assert (target / 'providers/xboard.json').is_symlink() and not (target / 'providers/xboard.json').exists(), 'Source update replaced a dangling runtime provider'
    assert (target / 'examples/xboard.sample.json').read_text() == '{"edited_sample":"keep"}\n', 'Source update replaced edited sample'
    assert (target / 'examples/local.sample.json').is_symlink() and not (target / 'examples/local.sample.json').exists(), 'Source update replaced dangling sample'
    before = (target / 'README.md').read_bytes()
    result = subprocess.run(['sh', str(bootstrap), '--update', '--no-menu'], env=dict(current, BOOT_FAIL='1'), capture_output=True, text=True)
    assert result.returncode != 0, 'Failed download was accepted'
    assert (target / 'README.md').read_bytes() == before, 'Failed download damaged existing source'
    print('PASS online update preserves device configuration and failed downloads')

    offline = root / 'offline source'
    (root / 'download-log').unlink()
    result = subprocess.run(['sh', str(bootstrap), '--archive', str(archive), '--no-menu'], env=dict(env, SB_INSTALL_SOURCE_DIR=str(offline), SB_DOWNLOAD_MODE='invalid-saved-settings'), capture_output=True, text=True)
    assert result.returncode == 0, 'Offline bootstrap unexpectedly depended on download settings'
    assert not (root / 'download-log').exists(), 'Offline bootstrap invoked a downloader'
    incomplete_source = root / 'incomplete-source'
    shutil.copytree(archive_source, incomplete_source)
    (incomplete_source / 'examples/local.sample.json').unlink()
    incomplete_target = root / 'incomplete-target'
    result = subprocess.run(['sh', str(bootstrap), '--source', str(incomplete_source), '--no-menu'], env=dict(env, SB_INSTALL_SOURCE_DIR=str(incomplete_target)), capture_output=True, text=True)
    assert result.returncode != 0 and not incomplete_target.exists(), 'Source missing a required sample was deployed'

    # Reproduce the previous published bootstrap's whitelist: it copied all
    # examples/*.json but only the provider template/README. A one-step update
    # performed by that version must still yield a complete current source.
    legacy = root / 'source-from-previous-whitelist'
    for name in ('scripts', 'openwrt', 'config', 'providers', 'examples'):
        (legacy / name).mkdir(parents=True)
    for name in ('README.md', 'quick-install.sh', 'install.sh', 'menu.sh', 'uninstall.sh'):
        shutil.copyfile(archive_source / name, legacy / name)
    for directory_name in ('scripts', 'openwrt'):
        for file in (archive_source / directory_name).iterdir():
            if file.is_file():
                shutil.copyfile(file, legacy / directory_name / file.name)
    shutil.copyfile(archive_source / 'config/config.template.json', legacy / 'config/config.template.json')
    for name in ('provider.template.json', 'README.md'):
        if (archive_source / 'providers' / name).is_file():
            shutil.copyfile(archive_source / 'providers' / name, legacy / 'providers' / name)
    for file in (archive_source / 'examples').iterdir():
        if file.is_file() and (file.suffix == '.json' or file.name == 'README.md'):
            shutil.copyfile(file, legacy / 'examples' / file.name)
    result = subprocess.run(['sh', str(bootstrap), '--source', str(legacy), '--no-menu'], env=dict(env, SB_INSTALL_SOURCE_DIR=str(legacy), SB_DOWNLOAD_MODE='invalid-offline-settings'), capture_output=True, text=True)
    assert result.returncode == 0, f'Previous bootstrap whitelist produced incomplete current source: {result.stderr}'
    assert not (root / 'download-log').exists(), 'Legacy source required an unexpected online repair'
    for provider in ('xboard', 'local'):
        assert (legacy / 'examples' / (provider + '.sample.json')).is_file(), 'Previous whitelist lost required sample'
        assert not (legacy / 'providers' / (provider + '.json')).exists(), 'Previous whitelist imported a runtime provider'
    print('PASS compatibility with the previous published bootstrap whitelist')

    for flags in (['--http-proxy', 'http://bad.invalid:8080\nnew-line'], ['--direct', '--github-proxy', 'https://accelerator.example.invalid/']):
        bad_target = root / 'rejected-target'
        result = subprocess.run(['sh', str(bootstrap), '--no-menu', *flags], env=dict(env, SB_INSTALL_SOURCE_DIR=str(bad_target)), capture_output=True, text=True)
        assert result.returncode != 0, 'Invalid or ambiguous download input accepted'
        assert not bad_target.exists(), 'Invalid download input changed source'
        assert not (root / 'download-log').exists(), 'Invalid download input invoked a transport'
    print('PASS offline bootstrap and invalid proxy inputs')
print('Public standalone bootstrap and update tests passed.')
PY
