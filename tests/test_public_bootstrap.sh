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
    os.chdir(root)
    tools = root / 'tools'
    tools.mkdir()
    launcher = root / 'sb-launcher'
    def isolated_bootstrap(text):
        # Even a regressed fixed-directory implementation must stay inside this
        # fixture. Actual in-place updates also unpack this isolated script.
        return (text.replace('/etc/openwrt_release', str(root / 'openwrt_release'))
                    .replace('/usr/bin/sb', str(launcher))
                    .replace('/overlay/openwrt-singbox-ebpf', str(root / 'wrong-overlay-source'))
                    .replace('/root/openwrt-singbox-ebpf', str(root / 'wrong-root-source')))
    archive_source = root / 'public-source'
    for name in ('scripts', 'openwrt', 'config', 'providers', 'examples'):
        (archive_source / name).mkdir(parents=True)
    for name in ('quick-install.sh', 'install.sh', 'uninstall.sh', 'README.md'):
        shutil.copyfile(base / name, archive_source / name)
    (archive_source / 'quick-install.sh').write_text(isolated_bootstrap(source))
    (archive_source / 'menu.sh').write_text('''#!/bin/sh
if [ -n "${BOOT_MENU_LOG:-}" ]; then
    printf '%s\\n' "$0" "$@" > "$BOOT_MENU_LOG"
fi
exit 0
''')
    for name in ('sbctl', 'runtime-paths.sh', 'terminal-input.sh', 'download.sh', 'configure-download.sh', 'config-parts-lib.sh', 'config-parts.sh', 'route-manager.sh', 'gateway.sh', 'dns-guard.sh', 'update-core.sh'):
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
    bootstrap = root / 'bootstrap.sh'
    bootstrap.write_text(isolated_bootstrap(source))
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
    for name in ('SB_DOWNLOAD_MODE', 'SB_HTTP_PROXY', 'SB_GITHUB_PROXY', 'SB_INSTALL_SOURCE_DIR'):
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
        for helper in ('config-parts-lib.sh', 'config-parts.sh', 'route-manager.sh', 'terminal-input.sh'):
            assert (target / 'scripts' / helper).read_bytes() == (archive_source / 'scripts' / helper).read_bytes(), f'Required helper was not deployed: {helper}'
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
    routing = target / 'config/config.d/routing.json'
    routing.parent.mkdir()
    routing.write_text('{"route":{"rules":[{"ip_cidr":["10.77.90.0/24"],"action":"route","outbound":"custom-node"}]}}\n')
    routing_before = routing.read_bytes()
    (target / 'providers/local.json').write_text('{"device_provider":"keep"}\n')
    (target / 'providers/xboard.json').symlink_to(root / 'missing-runtime-provider')
    (target / 'examples/xboard.sample.json').write_text('{"edited_sample":"keep"}\n')
    (target / 'examples/local.sample.json').unlink()
    (target / 'examples/local.sample.json').symlink_to(root / 'missing-source-sample')
    current = dict(env, SB_INSTALL_SOURCE_DIR=str(target), SB_DOWNLOAD_MODE='github', SB_GITHUB_PROXY='https://accelerator.example.invalid/')
    result = subprocess.run(['sh', str(bootstrap), '--update', '--no-menu'], env=current, capture_output=True, text=True)
    assert result.returncode == 0, 'Online archive update failed'
    assert (target / 'config/config.json').read_text() == '{"device_config":"keep"}\n'
    assert routing.read_bytes() == routing_before, 'Source update overwrote device routing section'
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
    for index, missing in enumerate(('examples/local.sample.json', 'scripts/config-parts-lib.sh', 'scripts/config-parts.sh', 'scripts/route-manager.sh', 'scripts/terminal-input.sh')):
        incomplete_source = root / f'incomplete-source-{index}'
        shutil.copytree(archive_source, incomplete_source)
        (incomplete_source / missing).unlink()
        incomplete_target = root / f'incomplete-target-{index}'
        result = subprocess.run(['sh', str(bootstrap), '--source', str(incomplete_source), '--no-menu'], env=dict(env, SB_INSTALL_SOURCE_DIR=str(incomplete_target)), capture_output=True, text=True)
        assert result.returncode != 0 and not incomplete_target.exists(), f'Source missing {missing} was deployed'
        assert not (root / 'download-log').exists(), 'Incomplete local source triggered an online repair'

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
    assert (legacy / 'scripts/route-manager.sh').read_bytes() == (archive_source / 'scripts/route-manager.sh').read_bytes(), 'Previous bootstrap whitelist lost the route manager'
    assert (legacy / 'scripts/terminal-input.sh').read_bytes() == (archive_source / 'scripts/terminal-input.sh').read_bytes(), 'Previous bootstrap whitelist lost terminal input helper'
    for provider in ('xboard', 'local'):
        assert (legacy / 'examples' / (provider + '.sample.json')).is_file(), 'Previous whitelist lost required sample'
        assert not (legacy / 'providers' / (provider + '.json')).exists(), 'Previous whitelist imported a runtime provider'
    print('PASS compatibility with the previous published bootstrap whitelist')

    # Exercise real source-script invocation, not only the external bootstrap
    # with SB_INSTALL_SOURCE_DIR preselected. A downloaded/cloned project must
    # stay where the user put it, regardless of the SSH working directory.
    auto_env = dict(env, SB_DOWNLOAD_MODE='invalid-offline-settings')
    unrelated = root / 'unrelated working directory'
    unrelated.mkdir()
    def make_checkout(name):
        checkout = root / name
        shutil.copytree(archive_source, checkout)
        return checkout
    def run_auto(script, flags=(), *, cwd=unrelated, current=None):
        (root / 'download-log').unlink(missing_ok=True)
        return subprocess.run(['sh', str(script), '--no-menu', *flags],
                              cwd=cwd, env=current or auto_env, capture_output=True, text=True)
    def assert_launcher(checkout):
        menu_log = root / 'auto-menu-log'
        result = subprocess.run(['sh', str(launcher), '--literal', 'value with spaces'],
                                cwd=root, env=dict(env, BOOT_MENU_LOG=str(menu_log)),
                                capture_output=True, text=True)
        assert result.returncode == 0, f'Launcher failed: {result.stderr}'
        assert menu_log.read_text().splitlines() == [str(checkout / 'menu.sh'), '--literal', 'value with spaces'], 'Launcher selected another source or changed arguments'
        assert not (root / 'PWNED').exists() and not (root / 'BACKTICK').exists(), 'Source path was interpreted as shell code'
    actual = make_checkout("用户选择的 源码 'quoted' $HOME $(touch PWNED) `touch BACKTICK`; directory")
    result = run_auto(actual / 'quick-install.sh')
    assert result.returncode == 0, f'Actual source directory was not reused: {result.stderr}'
    assert not (root / 'download-log').exists(), 'Existing source unexpectedly downloaded another copy'
    assert (actual / 'providers/local.json').read_bytes() == (archive_source / 'providers/local.json').read_bytes(), 'In-place setup changed a private source file'
    assert_launcher(actual)
    assert not (unrelated / 'openwrt-singbox-ebpf').exists(), 'Script-relative source was relocated to cwd'
    print('PASS actual arbitrary source location and literal Unicode/shell characters')

    other = make_checkout('another complete source')
    result = run_auto(actual / 'quick-install.sh', cwd=other)
    assert result.returncode == 0 and not (root / 'download-log').exists(), 'Script source did not take precedence over another checkout in cwd'
    assert_launcher(actual)
    script_alias = root / 'quick-install-link.sh'
    script_alias.symlink_to(actual / 'quick-install.sh')
    result = run_auto(script_alias)
    assert result.returncode == 0, f'Script symlink did not resolve to its source: {result.stderr}'
    assert_launcher(actual)
    result = run_auto(bootstrap, cwd=other)
    assert result.returncode == 0 and not (root / 'download-log').exists(), 'Standalone bootstrap ignored a complete source in cwd'
    assert_launcher(other)
    result = run_auto(actual / 'quick-install.sh', ['--source', '../another complete source'])
    assert result.returncode == 0 and not (root / 'download-log').exists(), 'Explicit local source did not override script directory in place'
    assert_launcher(other)
    assert not (other / 'openwrt-singbox-ebpf').exists(), 'Explicit local source was nested instead of reused'
    print('PASS script, cwd, symlink and explicit local-source priorities')

    moved = root / 'explicit destination'
    result = run_auto(actual / 'quick-install.sh', current=dict(auto_env, SB_INSTALL_SOURCE_DIR=str(moved)))
    assert result.returncode == 0 and not (root / 'download-log').exists(), 'Explicit source destination was ignored'
    assert_launcher(moved)
    assert not (moved / 'providers/local.json').exists(), 'Explicit relocation copied private Provider data'
    for name, flags in [('online standalone', []), ('offline archive', ['--archive', str(archive)])]:
        parent = root / name
        parent.mkdir()
        current = dict(env, SB_DOWNLOAD_MODE='direct') if not flags else auto_env
        result = run_auto(bootstrap, flags, cwd=parent, current=current)
        assert result.returncode == 0, f'{name} did not use caller directory: {result.stderr}'
        assert_launcher(parent / 'openwrt-singbox-ebpf')
        assert (root / 'download-log').exists() == (not flags), 'Standalone source preparation used the wrong download behavior'
    print('PASS explicit destination and standalone caller-directory preparation')

    update_source = make_checkout('self updating source')
    (update_source / 'README.md').write_text('Old source content\n')
    old_bootstrap = update_source / 'quick-install.sh'
    old_text = old_bootstrap.read_text()
    padding = '# Old bootstrap revision has a different source length.\n' * 5000
    old_text = old_text.replace('if [ "$SOURCE" != "$TARGET" ]; then\n', padding + 'if [ "$SOURCE" != "$TARGET" ]; then\n', 1)
    old_text += '\nprintf "old bootstrap completed\\n" > "$BOOT_OLD_COMPLETE"\n'
    old_bootstrap.write_text(old_text)
    old_complete = root / 'old-bootstrap-completed'
    private_before = (update_source / 'providers/local.json').read_bytes()
    result = run_auto(old_bootstrap, ['--update'], current=dict(env, SB_DOWNLOAD_MODE='direct', BOOT_OLD_COMPLETE=str(old_complete)))
    assert result.returncode == 0, f'Real in-place source-script update failed: {result.stderr}'
    assert old_complete.is_file(), 'Updating the running bootstrap skipped its remaining instructions'
    assert old_bootstrap.read_bytes() == (archive_source / 'quick-install.sh').read_bytes(), 'Old bootstrap source was not replaced by the new version'
    assert (root / 'download-log').exists(), '--update reused old source without downloading'
    assert (update_source / 'README.md').read_bytes() == (archive_source / 'README.md').read_bytes(), 'In-place update did not refresh source'
    assert (update_source / 'providers/local.json').read_bytes() == private_before, 'In-place source update replaced personal Provider data'
    assert_launcher(update_source)
    print('PASS actual source script updates itself without relocating private files')

    # Source updates can also be launched from a menu whose interpreter still
    # has more input to read. Preserve that live inode until the old menu exits.
    active_menu_source = make_checkout('source with an active menu')
    active_menu = active_menu_source / 'menu.sh'
    active_menu.write_text('#!/bin/sh\n' + padding +
                          'sh "$BOOT_RUNNING_SOURCE/quick-install.sh" --update --no-menu || exit 1\n' +
                          padding + 'printf "old menu completed\\n" > "$BOOT_MENU_COMPLETE"\n')
    menu_complete = root / 'old-menu-completed'
    result = subprocess.run(['sh', str(active_menu)], cwd=unrelated,
                            env=dict(env, SB_DOWNLOAD_MODE='direct', BOOT_RUNNING_SOURCE=str(active_menu_source),
                                     BOOT_MENU_COMPLETE=str(menu_complete)), capture_output=True, text=True)
    assert result.returncode == 0 and menu_complete.is_file(), f'Source update interrupted its active parent menu: {result.stderr}'
    assert active_menu.read_bytes() == (archive_source / 'menu.sh').read_bytes(), 'Active menu source was not replaced by the new version'
    assert_launcher(active_menu_source)
    print('PASS active old menu finishes after its source file is updated')

    for kind in ('directory', 'file', 'symlink'):
        checkout = make_checkout('git source ' + kind)
        git_path = checkout / '.git'
        if kind == 'directory':
            git_path.mkdir()
        elif kind == 'file':
            git_path.write_text('gitdir: ../worktree-data\n')
        else:
            git_path.symlink_to(root / 'missing-git-data')
        result = run_auto(checkout / 'quick-install.sh')
        assert result.returncode == 0, f'Git {kind} checkout could not register in place: {result.stderr}'
        assert_launcher(checkout)
        launcher_before = launcher.read_bytes()
        readme_before = (checkout / 'README.md').read_bytes()
        for flags in (['--update'], ['--archive', str(archive)]):
            result = run_auto(checkout / 'quick-install.sh', flags, current=dict(env, SB_DOWNLOAD_MODE='direct'))
            assert result.returncode != 0 and 'Refusing to overwrite Git checkout' in result.stderr, f'Git {kind} was not protected'
            assert not (root / 'download-log').exists(), 'Git checkout refusal occurred after network access'
            assert launcher.read_bytes() == launcher_before and (checkout / 'README.md').read_bytes() == readme_before, 'Rejected Git update changed existing files'
    print('PASS Git directory, worktree file and symlink protection before download')

    launcher_before = launcher.read_bytes()
    for control in ('\n', '\r', '\t', '\x1b'):
        bad_target = root / ('invalid' + control + 'source')
        result = run_auto(bootstrap, ['--source', str(other)], current=dict(auto_env, SB_INSTALL_SOURCE_DIR=str(bad_target)))
        assert result.returncode != 0 and not bad_target.exists(), 'Control-character source path was accepted'
        assert launcher.read_bytes() == launcher_before, 'Rejected path changed the existing launcher'
    control_prefix = make_checkout('control-prefix')
    trailing_newline = make_checkout('control-prefix\n')
    control_alias = root / 'source-control-alias'
    control_alias.symlink_to(trailing_newline, target_is_directory=True)
    for flags, cwd, current in (
        (['--source', str(trailing_newline)], unrelated, auto_env),
        ([], trailing_newline, auto_env),
        (['--source', str(other)], unrelated, dict(auto_env, SB_INSTALL_SOURCE_DIR=str(control_alias))),
    ):
        result = run_auto(bootstrap, flags, cwd=cwd, current=current)
        assert result.returncode != 0, 'Canonicalization stripped a control character and selected another source'
        assert launcher.read_bytes() == launcher_before, 'Invalid canonical source changed the existing launcher'
        assert not (root / 'download-log').exists(), 'Invalid canonical source triggered a download'
    invalid_script_alias = root / 'invalid-source-script-link.sh'
    invalid_script_alias.symlink_to(trailing_newline / 'quick-install.sh')
    for script in (trailing_newline / 'quick-install.sh', invalid_script_alias):
        result = run_auto(script)
        assert result.returncode != 0 and launcher.read_bytes() == launcher_before, 'Script path canonicalization selected a different source after stripping controls'
        assert not (root / 'download-log').exists(), 'Invalid script source triggered a download'
    assert not (root / 'wrong-overlay-source').exists() and not (root / 'wrong-root-source').exists(), 'Bootstrap retained a fixed system source directory'
    print('PASS control-character path rejection without changing the launcher')

    for flags in (['--http-proxy', 'http://bad.invalid:8080\nnew-line'], ['--direct', '--github-proxy', 'https://accelerator.example.invalid/']):
        bad_target = root / 'rejected-target'
        result = subprocess.run(['sh', str(bootstrap), '--no-menu', *flags], env=dict(env, SB_INSTALL_SOURCE_DIR=str(bad_target)), capture_output=True, text=True)
        assert result.returncode != 0, 'Invalid or ambiguous download input accepted'
        assert not bad_target.exists(), 'Invalid download input changed source'
        assert not (root / 'download-log').exists(), 'Invalid download input invoked a transport'
    print('PASS offline bootstrap and invalid proxy inputs')
print('Public standalone bootstrap and update tests passed.')
PY
