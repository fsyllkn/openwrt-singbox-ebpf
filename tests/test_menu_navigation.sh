#!/bin/sh
# Exercise the real POSIX menu loops with isolated tools and no host mutations.
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
python3 - "$BASE" <<'PY'
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile


base = Path(sys.argv[1])
source = (base / "menu.sh").read_text()
assert source.count("\nwhile :; do\n") == 1, "Function extraction requires one top-level loop"
source = re.sub(r'^\[ -f /etc/openwrt_release \] \|\| \{\n.*?^\}\n', "",
                source, count=1, flags=re.M | re.S)
assert "This distribution requires OpenWrt" not in source
functions, main_loop = source.split("\nwhile :; do\n", 1)


def script(path, content):
    path.write_text(content)
    path.chmod(0o755)


with tempfile.TemporaryDirectory(prefix="sb-menu-navigation-") as directory:
    work = Path(directory)
    home = work / "service home"
    checkout = work / "source checkout"
    tools = work / "tools"
    config = work / "external config" / "active.json"
    events = work / "events"
    service = work / "mock-service"
    for path in (home / "scripts", home / "runtime", home / "providers",
                 checkout / "scripts", tools, config.parent):
        path.mkdir(parents=True)
    config.write_text('{"providers":[],"inbounds":[],"outbounds":[]}\n')
    provider = home / "providers" / "private.json"
    provider.write_text('{"fixture":"preserve existing provider"}\n')
    original_config = config.read_bytes()
    original_provider = provider.read_bytes()
    for name in ("runtime-paths.sh", "config-parts-lib.sh", "config-parts.sh", "download.sh"):
        shutil.copyfile(base / "scripts" / name, checkout / "scripts" / name)
        shutil.copyfile(base / "scripts" / name, home / "scripts" / name)
    script(tools / "id", '#!/bin/sh\n[ "$*" = -u ] || exit 80\necho 0\n')
    script(tools / "uname", '#!/bin/sh\n[ "$*" = -m ] || exit 80\necho x86_64\n')
    script(tools / "uci", '#!/bin/sh\nexit 1\n')
    script(tools / "vi", '#!/bin/sh\nprintf "editor\\n" >> "$TEST_EVENTS"\n')
    for name in ("curl", "wget", "opkg", "apk", "systemctl", "nft", "ip"):
        script(tools / name, '''#!/bin/sh
printf 'FORBIDDEN:%s %s\n' "$0" "$*" >> "$TEST_EVENTS"
exit 98
''')
    script(service, '''#!/bin/sh
case "$*" in
    status) exit 1 ;;
    stop) printf 'service:stop\n' >> "$TEST_EVENTS" ;;
    *) printf 'FORBIDDEN:service:%s\n' "$*" >> "$TEST_EVENTS"; exit 98 ;;
esac
''')
    script(home / "scripts" / "sbctl", '''#!/bin/sh
printf 'sbctl:%s\n' "$*" >> "$TEST_EVENTS"
if [ "$*" = check-xtunnel ]; then exit "$MOCK_XTUNNEL_STATUS"; fi
if [ "$*" = "$MOCK_FAILED_ACTION" ]; then exit 29; fi
exit 0
''')
    script(home / "scripts" / "gateway.sh", '''#!/bin/sh
printf 'gateway:%s\n' "$*" >> "$TEST_EVENTS"
''')
    for name in ("configure-pc-proxy.sh", "apply-pc-privacy.sh",
                 "align-xtunnel-ebpf.sh", "migrate-config.sh"):
        body = f'#!/bin/sh\nprintf "tool:{name}:%s\\n" "$*" >> "$TEST_EVENTS"\n'
        script(home / "scripts" / name, body)
        script(checkout / "scripts" / name, body)
    proxy_tool = '''#!/bin/sh
printf 'download:%s\n' "$*" >> "$TEST_EVENTS"
'''
    script(home / "scripts" / "configure-download.sh", proxy_tool)
    script(checkout / "scripts" / "configure-download.sh", proxy_tool)
    script(checkout / "install.sh", '#!/bin/sh\nprintf "install\\n" >> "$TEST_EVENTS"\n')
    script(checkout / "quick-install.sh", '''#!/bin/sh
[ "$SB_INSTALL_SOURCE_DIR" = "$TEST_CHECKOUT" ] || exit 80
printf 'source-update:%s\n' "$*" >> "$TEST_EVENTS"
''')
    script(home / "uninstall.sh", '#!/bin/sh\nprintf "uninstall:%s\\n" "$*" >> "$TEST_EVENTS"\n')
    script(checkout / "uninstall.sh", '#!/bin/sh\nprintf "source-uninstall:%s\\n" "$*" >> "$TEST_EVENTS"\n')

    def route_tool(origin):
        return f'''#!/bin/sh
[ "$*" = menu ] || exit 80
printf 'routes:{origin}:menu\\n' >> "$TEST_EVENTS"
while :; do
    IFS= read -r route_choice || exit 2
    case "$route_choice" in 0) exit 0 ;; esac
done
'''

    installed_routes = home / "scripts" / "route-manager.sh"
    source_routes = checkout / "scripts" / "route-manager.sh"
    script(installed_routes, route_tool("installed"))
    script(source_routes, route_tool("source"))

    # Preserve the actual navigation, confirmation and consequential-action
    # helpers. Only the read-only diagnostic bodies and LAN discovery are
    # stubbed here; their device behavior has dedicated fixture coverage.
    overrides = '''
SERVICE=$TEST_SERVICE
configure_gateway() { printf 'configure_gateway\\n' >> "$TEST_EVENTS"; }
privacy_audit() { printf 'privacy_audit\\n' >> "$TEST_EVENTS"; }
inspect_xtunnel() { printf 'inspect_xtunnel\\n' >> "$TEST_EVENTS"; }
diagnose() { printf 'diagnose\\n' >> "$TEST_EVENTS"; }
'''
    menu = checkout / "menu.sh"
    script(menu, functions + overrides + "\nwhile :; do\n" + main_loop)
    ask_runner = checkout / "ask.sh"
    script(ask_runner, functions + '\nask "Proceed?"\n')
    env = dict(os.environ, SH_SINGBOX_HOME=str(home), SH_SINGBOX_CONFIG=str(config),
               PATH=str(tools) + os.pathsep + os.environ["PATH"],
               TEST_EVENTS=str(events), TEST_SERVICE=str(service), TEST_CHECKOUT=str(checkout),
               SB_DOWNLOAD_MODE="direct", MOCK_XTUNNEL_STATUS="0", MOCK_FAILED_ACTION="")
    env.pop("SB_INSTALL_SOURCE_DIR", None)

    def run_menu(text, **overrides):
        events.write_text("")
        result = subprocess.run(["sh", str(menu)], input=text, text=True, capture_output=True,
                                env={**env, **overrides}, timeout=25)
        assert result.returncode == 0, result.stdout + result.stderr
        calls = events.read_text().splitlines()
        assert not any(line.startswith("FORBIDDEN:") for line in calls), calls
        return result.stdout, calls

    # Confirmation defaults apply only to a successfully read line. EOF,
    # including an unterminated "y", must never approve an operation.
    for text in ("\n", "y\n", "Y\n", "yes\n", "YES\n",
                 "n\n", "N\n", "no\n", "Yes\n", "invalid\n", " \n", "", "y"):
        result = subprocess.run(["sh", str(ask_runner)], input=text, text=True,
                                capture_output=True, env=env, timeout=10)
        accepted = text in ("\n", "y\n", "Y\n", "yes\n", "YES\n")
        assert (result.returncode == 0) == accepted, (repr(text), result.returncode)
        assert "[Y/n]" in result.stdout and "[y/N]" not in result.stdout
    print("PASS confirmation: Enter equals y; negative input and EOF cancel")

    # Visit all 25 existing operations through their new category paths.
    lines = []

    def action(number, *answers):
        lines.extend((str(number), *answers, ""))  # final line acknowledges the result

    lines.append("1")
    action(1); action(2); action(3, ""); action(4, "y"); action(5); action(6)
    lines.extend(("0", "3"))
    action(1); action(2); action(3, ""); action(4); action(5, "")
    lines.extend(("0", "4"))
    action(1); action(2, "1"); action(3, ""); action(4, ""); action(5)
    lines.extend(("0", "5"))
    action(1, ""); action(2, "", ""); action(3, "1"); action(4); action(5, "")
    lines.extend(("0", "6"))
    action(1); action(2, ""); action(3); action(4, "")
    lines.extend(("0", "2", "0", "0"))
    output, calls = run_menu("\n".join(lines) + "\n")
    expected = [
        "sbctl:status", "sbctl:check-xtunnel", "sbctl:start",
        "sbctl:check-xtunnel", "sbctl:restart", "sbctl:stop", "sbctl:logs", "sbctl:check",
        "configure_gateway", "gateway:status", "service:stop", "gateway:disable",
        "tool:configure-pc-proxy.sh:configure", "tool:configure-pc-proxy.sh:disable",
        "editor", "sbctl:config", "sbctl:split-config",
        f"tool:migrate-config.sh:{config}", "tool:apply-pc-privacy.sh:apply", "privacy_audit",
        "install", "source-update:--update --no-menu",
        "download:show", "download:set direct", "download:show",
        "sbctl:update-rules", "sbctl:update-core", "inspect_xtunnel",
        "tool:align-xtunnel-ebpf.sh:", "diagnose", "sbctl:ebpf-status", "uninstall:",
        "routes:installed:menu",
    ]
    assert calls == expected, (calls, expected, output)
    for heading, minimum in (("【服务管理】", 7), ("【LAN 接入】", 6),
                             ("【配置与隐私】", 6), ("【安装与更新】", 6),
                             ("【诊断与维护】", 5)):
        assert output.count(heading) == minimum, (heading, output.count(heading))
    assert config.read_bytes() == original_config and provider.read_bytes() == original_provider
    assert "卸载会停止 sing-box" in output and "保留配置、Provider 和 X-Tunnel" in output
    print("PASS all 25 actions, category retention, custom paths and preserved uninstall arguments")

    # Enter and explicit y produce identical actions. Cancelled and EOF
    # confirmations never call the core/controller or the uninstaller.
    for category, action_number in (("1", "3"), ("1", "4"), ("5", "5"), ("6", "4")):
        _, enter_calls = run_menu(f"{category}\n{action_number}\n\n\n0\n0\n")
        _, yes_calls = run_menu(f"{category}\n{action_number}\ny\n\n0\n0\n")
        assert enter_calls == yes_calls and enter_calls, (category, action_number)
        for answer in ("n", "N", "unexpected"):
            _, calls = run_menu(f"{category}\n{action_number}\n{answer}\n\n0\n0\n")
            assert calls == [], calls
        _, calls = run_menu(f"{category}\n{action_number}\n")
        assert calls == [], calls
    print("PASS restart/stop/core-update/uninstall default confirmation and cancellation")

    _, calls = run_menu("1\n2\n\n3\n\n\n0\n0\n", MOCK_XTUNNEL_STATUS="31")
    assert calls == ["sbctl:check-xtunnel", "sbctl:check-xtunnel"], calls
    output, calls = run_menu("1\n1\n\n6\n\n0\n0\n", MOCK_FAILED_ACTION="status")
    assert calls == ["sbctl:status", "sbctl:check"], calls
    assert output.count("【服务管理】") == 3
    print("PASS failed preflight blocks start/restart; action failure stays in its category")

    # Legacy flat numbers must not alias destructive operations.
    _, calls = run_menu("7\n8\n9\n12\n13\n23\n24\n25\n0\n")
    assert calls == [], calls
    _, calls = run_menu("3\n99\n0\n0\n")
    assert calls == [], calls
    for text in ("", "1\n", "3\n", "4\n", "5\n", "6\n", "1\nq\n"):
        output, calls = run_menu(text)
        assert calls == [], calls
        assert output.count("reF1nd sing-box / OpenWrt SSH 管理菜单") == 1
    print("PASS old flat numbers are inactive; invalid input, back, quit and EOF are bounded")

    output, calls = run_menu("2\n0\n0\n")
    assert calls == ["routes:installed:menu"], calls
    installed_routes.unlink()
    output, calls = run_menu("2\n0\n0\n")
    assert calls == ["routes:source:menu"], calls
    output, calls = run_menu("2\n")
    assert calls == ["routes:source:menu"], calls
    assert output.count("reF1nd sing-box / OpenWrt SSH 管理菜单") == 1
    source_routes.unlink()
    output, calls = run_menu("2\n0\n")
    assert calls == [] and "未找到特色路由管理工具" in output
    print("PASS route manager installed/source dispatch, missing helper and EOF propagation")

    text = "".join(f"{category}\n0\n" for _ in range(30) for category in (1, 3, 4, 5, 6)) + "0\n"
    output, calls = run_menu(text)
    assert calls == []
    assert output.count("reF1nd sing-box / OpenWrt SSH 管理菜单") == 151
    print("PASS repeated category transitions use iterative navigation without nested menu stacks")

print("Two-level menu navigation and confirmation tests passed.")
PY
