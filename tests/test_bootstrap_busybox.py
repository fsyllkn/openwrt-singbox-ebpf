#!/usr/bin/env python3
"""Check source discovery with OpenWrt's reduced BusyBox tr feature set.

The always-run compatibility fixture models tr with character classes disabled.
CI also supplies a real BusyBox built with those options disabled and runs the
same bootstrap through its ash and utility applets. All writes stay in tmp.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile


BASE = Path(__file__).resolve().parent.parent
SOURCE = (BASE / "quick-install.sh").read_text()
REQUIRED_FILES = (
    "install.sh", "uninstall.sh", "scripts/sbctl", "scripts/runtime-paths.sh",
    "scripts/terminal-input.sh", "scripts/download.sh", "scripts/configure-download.sh",
    "scripts/config-parts-lib.sh", "scripts/config-parts.sh", "scripts/route-manager.sh",
    "scripts/gateway.sh", "scripts/dns-guard.sh", "scripts/update-core.sh",
    "openwrt/sing-box.init", "config/config.template.json",
    "examples/xboard.sample.json", "examples/local.sample.json",
)


def write_executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


def run_matrix(root, name, shell, utility_dir=None):
    work = root / name
    work.mkdir()
    tools = work / "tools"
    tools.mkdir()
    launcher = work / "sb-launcher"
    release = work / "openwrt_release"
    release.write_text("fixture\n")
    bootstrap = SOURCE.replace("/etc/openwrt_release", str(release)).replace("/usr/bin/sb", str(launcher))
    write_executable(tools / "id", '#!/bin/sh\n[ "$*" = -u ] || exit 98\nprintf "0\\n"\n')
    for command in ("curl", "wget"):
        write_executable(tools / command, '#!/bin/sh\nprintf "unexpected network\\n" > "$BOOT_NETWORK_LOG"\nexit 99\n')
    if utility_dir is None:
        # GNU tr expands character classes, unlike the default OpenWrt build.
        # Escape class spellings into literal bytes before passing to real tr;
        # octal escapes, ranges and normal translations keep their real behavior.
        native_tr = shutil.which("tr")
        assert native_tr, "The local compatibility fixture requires tr"
        write_executable(tools / "tr", "#!/usr/bin/env python3\n" +
                         "import os, re, sys\n" +
                         "args = [re.sub(r'\\[:[A-Za-z]+:\\]', " +
                         "lambda m: ''.join('\\\\%03o' % ord(c) for c in m[0]), arg) for arg in sys.argv[1:]]\n" +
                         f"os.execv({native_tr!r}, ['tr', *args])\n")

    env = os.environ.copy()
    for variable in ("SB_INSTALL_SOURCE_DIR", "SB_DOWNLOAD_MODE", "SB_HTTP_PROXY", "SB_GITHUB_PROXY", "CDPATH"):
        env.pop(variable, None)
    path_parts = [str(tools)] + ([str(utility_dir)] if utility_dir else []) + [env["PATH"]]
    env.update(PATH=os.pathsep.join(path_parts), SB_DOWNLOAD_MODE="invalid-offline-settings",
               BOOT_NETWORK_LOG=str(work / "network-log"), BOOT_MENU_LOG=str(work / "menu-log"))

    # Assert that this environment actually reproduces the relevant utility
    # behavior; merely invoking ash with the host's GNU tr is insufficient.
    normal_path = b"/root/linux_openwrt-sing-box-openwrt/quick-install.sh"
    probe = subprocess.run(["tr", "-d", "[:cntrl:]"], input=normal_path + b"\n", env=env, capture_output=True)
    expected = bytes(byte for byte in normal_path + b"\n" if byte not in b"[:cntrl:]")
    assert probe.returncode == 0 and probe.stdout == expected, f"{name}: tr character classes were not disabled"

    def make_checkout(directory):
        directory.mkdir(parents=True)
        for relative in REQUIRED_FILES:
            destination = directory / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(BASE / relative, destination)
        write_executable(directory / "quick-install.sh", bootstrap)
        write_executable(directory / "menu.sh", '#!/bin/sh\nprintf "%s\\n" "$0" "$@" > "$BOOT_MENU_LOG"\n')
        (directory / "providers").mkdir()
        (directory / "providers/local.json").write_text('{"private":"preserve"}\n')
        return directory

    def invoke(script, cwd, extra_env=None):
        return subprocess.run([*shell, str(script), "--no-menu"], cwd=cwd,
                              env=dict(env, **(extra_env or {})), capture_output=True, text=True)

    checkouts = [
        make_checkout(work / "root/linux_openwrt-sing-box-openwrt"),
        make_checkout(work / "中文 源码 'quoted' [cntrl] $HOME `literal`"),
    ]
    for checkout in checkouts:
        # Matches the user's downloaded-tree invocation, including relative $0.
        result = invoke("./quick-install.sh", checkout)
        assert result.returncode == 0, f"{name}: normal source rejected: {result.stderr}"
        assert f"source: {checkout}" in result.stdout, f"{name}: chose another source directory"
        launch = subprocess.run([*shell, str(launcher), "--literal", "value with spaces"], env=env,
                                capture_output=True, text=True)
        assert launch.returncode == 0, f"{name}: generated launcher failed: {launch.stderr}"
        assert (work / "menu-log").read_text().splitlines() == [str(checkout / "menu.sh"), "--literal", "value with spaces"]
        assert (checkout / "providers/local.json").read_text() == '{"private":"preserve"}\n'
    assert not (work / "network-log").exists(), f"{name}: existing source triggered a download"

    launcher_before = launcher.read_bytes()
    safe_source = checkouts[0]
    for byte in [*range(1, 32), 127]:
        invalid = work / ("invalid" + chr(byte) + "source")
        result = invoke("./quick-install.sh", safe_source, {"SB_INSTALL_SOURCE_DIR": str(invalid)})
        assert result.returncode != 0 and "control characters" in result.stderr, f"{name}: accepted control byte {byte}"
        assert not invalid.exists() and launcher.read_bytes() == launcher_before, f"{name}: invalid path changed files"

    invalid_source = make_checkout(work / "trailing-newline\n")
    alias = work / "invalid-source-alias"
    alias.symlink_to(invalid_source, target_is_directory=True)
    script_alias = work / "invalid-script-alias.sh"
    script_alias.symlink_to(invalid_source / "quick-install.sh")
    for script, cwd, extra in (
        ("./quick-install.sh", invalid_source, {}),
        ("./quick-install.sh", safe_source, {"SB_INSTALL_SOURCE_DIR": str(alias)}),
        (script_alias, safe_source, {}),
    ):
        result = invoke(script, cwd, extra)
        assert result.returncode != 0, f"{name}: canonicalization accepted a trailing newline"
        assert launcher.read_bytes() == launcher_before, f"{name}: rejected canonical path changed launcher"
    assert not (work / "network-log").exists(), f"{name}: path validation triggered a download"
    print(f"PASS {name}: normal/Unicode source paths, literal launcher, all control bytes and symlink rejection")


with tempfile.TemporaryDirectory(prefix="sb-bootstrap-busybox-") as directory:
    root = Path(directory)
    run_matrix(root, "class-disabled-tr-fixture", [shutil.which("sh")])
    busybox = os.environ.get("SB_TEST_BOOTSTRAP_BUSYBOX")
    if busybox:
        binary = Path(busybox).resolve(strict=True)
        applets = root / "busybox-applets"
        applets.mkdir()
        # The test must use BusyBox utilities as well as its shell. These are
        # the applets used by in-place registration and launcher ownership.
        for command in ("tr", "readlink", "dirname", "sed", "grep", "chmod"):
            (applets / command).symlink_to(binary)
        run_matrix(root, "real-busybox", [str(binary), "ash"], applets)
    else:
        print("SKIP real BusyBox applets (set SB_TEST_BOOTSTRAP_BUSYBOX; mandatory in CI)")
