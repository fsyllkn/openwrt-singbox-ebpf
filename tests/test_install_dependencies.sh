#!/usr/bin/env bash
# Run the real dependency stage with isolated tools and package transactions.
set -euo pipefail
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
python3 - "$BASE" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

base = Path(sys.argv[1])
installer = (base / "install.sh").read_text()
start = installer.index('info "Installing required packages..."')
end = installer.index('ok "Required installer dependencies available"', start)
end += len('ok "Required installer dependencies available"')
assert end < installer.index('mkdir -p "$INSTALL_DIR"/{bin,config,scripts'), "Deployment precedes dependency checks"
assert installer.index('    deploy_scripts_only\n    exit 0') < start, "Offline update entered package stage"
packages = installer[start:end]
# Redirect only the system CA lookup; all capability probes remain production
# code, and package fixtures never write to /etc, /usr or the real service.
packages = packages.replace(
    'for bundle in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem /etc/ssl/ca-bundle.pem; do',
    'for bundle in "$TEST_CA_BUNDLE"; do')
basics = ("awk", "basename", "cat", "chmod", "cp", "date", "dirname", "find",
          "grep", "head", "id", "ln", "mkdir", "mktemp", "mv", "pidof",
          "readlink", "rm", "rmdir", "sed", "sh", "tar", "tr", "uname", "wc")
real = {name: shutil.which(name) for name in (*basics, "bash", "jq", "sha256sum", "sleep", "unzip")}
assert all(real.values()), f"Missing test tools: {[name for name, path in real.items() if not path]}"

def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)

with tempfile.TemporaryDirectory(prefix="sb-install-dependencies.") as temporary:
    work = Path(temporary)
    (work / "packages.sh").write_text(packages)
    runner = work / "runner.sh"
    runner.write_text('''set -euo pipefail
. "$TEST_SOURCE/scripts/download.sh"
info() { printf '%s\\n' "$*"; }
ok() { printf '%s\\n' "$*"; }
warn() { printf '%s\\n' "$*"; }
die() { printf 'ERROR: %s\\n' "$*" >&2; exit 1; }
OS=openwrt
. "$TEST_PACKAGES"
: > "$TEST_AFTER_DEPENDENCIES"
''')
    available = work / "available"
    available.mkdir()
    for name in ("bash", "jq", "sha256sum", "sleep", "unzip"):
        (available / name).symlink_to(real[name])
    executable(available / "curl", '''#!/bin/sh
[ "$*" = '-q --version' ] || exit 90
printf 'curl fixture\\nProtocols: http https\\n'
''')
    manager_script = '''#!/bin/sh
set -eu
printf '%s %s\\n' "${0##*/}" "$*" >> "$TEST_COMMANDS"
if [ "$*" = update ]; then
    [ "${TEST_UPDATE_FAIL:-0}" = 0 ]
    exit "$?"
fi
[ "$#" -eq 2 ] || exit 91
case "${0##*/} $1" in 'opkg install'|'apk add') ;; *) exit 91 ;; esac
package=$2
[ "$package" != "${TEST_FAIL_PACKAGE:-}" ] || exit 47
[ "$package" != "${TEST_STUCK_PACKAGE:-}" ] || exit 0
case "$package" in
    ca-bundle) printf '%s\\n' '-----BEGIN CERTIFICATE-----' > "$TEST_CA_BUNDLE" ;;
    coreutils-sha256sum) ln -sf "$TEST_AVAILABLE/sha256sum" "$TEST_BIN/sha256sum" ;;
    coreutils-sleep) ln -sf "$TEST_AVAILABLE/sleep" "$TEST_BIN/sleep" ;;
    curl|jq|bash|unzip) ln -sf "$TEST_AVAILABLE/$package" "$TEST_BIN/$package" ;;
    *) exit 92 ;;
esac
'''
    busybox_script = '''#!/bin/sh
[ "${1:-}" = sha256sum ] || exit 93
shift
exec "$TEST_REAL_SHA" "$@"
'''
    count = 0

    def run(name, *, manager="opkg", missing=(), broken=None, fail_package="",
            stuck_package="", busybox=False, update_fail=False, mode="direct",
            expected=(), error=None, custom_ca=False):
        global count
        root = work / name
        root.mkdir()
        tools = root / "tools"
        tools.mkdir()
        for tool in basics:
            (tools / tool).symlink_to(real[tool])
        for tool in ("curl", "jq", "bash", "unzip", "sha256sum", "sleep"):
            (tools / tool).symlink_to(available / tool)
        ca = root / "ca-bundle.pem"
        ca.write_text("-----BEGIN CERTIFICATE-----\n")
        for tool in missing:
            if tool == "ca":
                ca.unlink()
            else:
                (tools / tool).unlink()
        if broken:
            for tool, body in broken.items():
                (tools / tool).unlink()
                executable(tools / tool, "#!/bin/sh\n" + body + "\n")
        if manager:
            executable(tools / manager, manager_script)
        if busybox:
            executable(tools / "busybox", busybox_script)
        # These existing private files must remain byte-for-byte unchanged
        # whether package installation succeeds or stops at an error.
        home = root / "service"
        (home / "config").mkdir(parents=True)
        (home / "bin").mkdir()
        config = home / "config/config.json"
        core = home / "bin/sing-box"
        config.write_bytes(b'{"inbounds":[{"listen":"10.4.2.1"}],"private":"keep"}\n')
        core.write_bytes(b"existing core\n")
        original = config.read_bytes(), core.read_bytes()
        commands = root / "commands"
        commands.touch()
        after = root / "after-dependencies"
        env = os.environ.copy()
        for variable in ("CURL_CA_BUNDLE", "SB_HTTP_PROXY", "SB_GITHUB_PROXY", "SB_DOWNLOAD_UCI_DIR"):
            env.pop(variable, None)
        env.update(PATH=str(tools), TEST_SOURCE=str(base),
                   TEST_PACKAGES=str(work / "packages.sh"), TEST_BIN=str(tools),
                   TEST_AVAILABLE=str(available), TEST_CA_BUNDLE=str(ca),
                   TEST_COMMANDS=str(commands), TEST_AFTER_DEPENDENCIES=str(after),
                   TEST_REAL_SHA=real["sha256sum"], SB_DOWNLOAD_MODE=mode,
                   SH_SINGBOX_HOME=str(home), SH_SINGBOX_CONFIG=str(config),
                   TEST_FAIL_PACKAGE=fail_package, TEST_STUCK_PACKAGE=stuck_package,
                   TEST_UPDATE_FAIL="1" if update_fail else "0", TMPDIR=str(root))
        if custom_ca:
            env["CURL_CA_BUNDLE"] = str(root / "missing-custom-ca.pem")
        result = subprocess.run([real["bash"], str(runner)], env=env, capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        (root / "output").write_text(output)
        if error:
            assert result.returncode != 0 and error in output, f"{name}: expected {error!r}:\n{output}"
            assert not after.exists(), f"{name}: failed prerequisite reached deployment"
            assert "Required installer dependencies available" not in output, f"{name}: false success reported"
        else:
            assert result.returncode == 0 and after.is_file(), f"{name}:\n{output}"
        assert (config.read_bytes(), core.read_bytes()) == original, f"{name}: private config or core changed"
        assert not (home / "scripts").exists() and not (home / "runtime").exists(), f"{name}: service files deployed in dependency stage"
        actual = commands.read_text().splitlines()
        assert actual == list(expected), f"{name}: unexpected package transactions: {actual!r}"
        assert not list(root.glob("sb-install-unzip.*")), f"{name}: leaked probe temporary directory"
        count += 1

    required = ("ca", "curl", "jq", "bash", "unzip", "sha256sum", "sleep")
    package_names = ("ca-bundle", "curl", "jq", "bash", "unzip", "coreutils-sha256sum", "coreutils-sleep")
    run("working-dependencies-no-package-manager", manager="")
    for manager in ("opkg", "apk"):
        action = "install" if manager == "opkg" else "add"
        run(f"{manager}-missing-dependencies", manager=manager, missing=required,
            expected=[f"{manager} update", *[f"{manager} {action} {p}" for p in package_names]])
        run(f"{manager}-package-error", manager=manager, missing=("jq",), fail_package="jq",
            expected=[f"{manager} update", f"{manager} {action} jq"],
            error=f"Cannot install package 'jq' with {manager}")
        run(f"{manager}-installed-but-still-unusable", manager=manager, missing=("jq",), stuck_package="jq",
            expected=[f"{manager} update", f"{manager} {action} jq"],
            error=f"Package 'jq' was installed with {manager}, but jq")
    run("busybox-sha256-only", manager="", missing=("sha256sum",), busybox=True)
    run("missing-tool-no-manager", manager="", missing=("jq",), error="No supported package manager")
    run("missing-base-tool", missing=("tar",), error="Missing base tool 'tar'")
    run("invalid-download-config", missing=("jq",), mode="invalid", error="Invalid download configuration")
    run("cached-package-index", missing=("sleep",), update_fail=True,
        expected=["opkg update", "opkg install coreutils-sleep"])
    run("custom-ca-stays-invalid", custom_ca=True,
        expected=["opkg update", "opkg install ca-bundle"], error="but readable TLS CA certificate bundle is still unavailable")
    # Existing executable names and successful --version/exit statuses are
    # insufficient; the real operation must produce its expected result.
    faults = {
        "curl": "printf 'curl fixture\\nProtocols: http\\n'",
        "jq": "exit 0",
        "bash": "printf no-job-control",
        "unzip": "exit 0",
        "sha256sum": "printf 'bad-digest  -\\n'",
        "sleep": "exit 1",
    }
    for tool, body in faults.items():
        package = {"sha256sum": "coreutils-sha256sum", "sleep": "coreutils-sleep"}.get(tool, tool)
        run(f"broken-{tool}-repaired", broken={tool: body},
            expected=["opkg update", f"opkg install {package}"])
    run("bad-sha256-still-bad", broken={"sha256sum": faults["sha256sum"]}, stuck_package="coreutils-sha256sum",
        expected=["opkg update", "opkg install coreutils-sha256sum"],
        error="but working SHA-256 (sha256sum or BusyBox sha256sum) is still unavailable")
    regex = subprocess.run([real["jq"], "-n", '"x"|test("x")'], capture_output=True, text=True)
    if regex.returncode != 0 and "ONIGURUMA" in regex.stderr:
        print("PASS real jq without Oniguruma accepted without installing jq-full")
    print(f"Installer dependency capabilities, package repair and failure-isolation tests passed ({count} cases).")
PY
