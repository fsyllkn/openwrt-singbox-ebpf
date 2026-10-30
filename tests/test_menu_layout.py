"""Static regression checks for the two-level OpenWrt SSH menu."""
import re
import unicodedata
import unittest
from pathlib import Path


MENU = (Path(__file__).resolve().parents[1] / "menu.sh").read_text(encoding="utf-8")
TOP_LEVEL = {
    1: ("服务管理", "run_submenu service"),
    2: ("特色路由", "manage_routes"),
    3: ("LAN 接入", "run_submenu lan"),
    4: ("配置与隐私", "run_submenu config"),
    5: ("安装与更新", "run_submenu install"),
    6: ("诊断与维护", "run_submenu diagnostics"),
}
EXPECTED_ACTIONS = {
    "service:1": "run_sbctl status",
    "service:2": "preflight_xtunnel && run_sbctl start",
    "service:3": "preflight_xtunnel && run_sbctl restart",
    "service:4": "run_sbctl stop",
    "service:5": "run_sbctl logs",
    "service:6": "run_sbctl check",
    "lan:1": "configure_gateway",
    "lan:2": '/bin/bash "$GATEWAY" status',
    "lan:3": "disable_gateway",
    "lan:4": "configure_pc_proxy",
    "lan:5": "disable_pc_proxy",
    "config:1": "edit_config",
    "config:2": "manage_config_parts",
    "config:3": "migrate_config",
    "config:4": "apply_pc_privacy",
    "config:5": "privacy_audit",
    "install:1": "install_core",
    "install:2": "source_update",
    "install:3": "configure_download_proxy",
    "install:4": "run_sbctl update-rules",
    "install:5": "run_sbctl update-core",
    "diagnostics:1": "inspect_xtunnel",
    "diagnostics:2": "align_xtunnel_ebpf",
    "diagnostics:3": "run_sbctl ebpf-status",
    "diagnostics:4": "uninstall_service",
}


def function(name):
    match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{\n(.*?)^\}}", MENU)
    if match is None:
        raise AssertionError(f"Missing menu function: {name}")
    return match.group(1)


def handlers():
    source = function("run_submenu")
    items = list(re.finditer(r"(?m)^            ([a-z]+:\d+)\)", source))
    return {
        item.group(1): source[item.end():items[i + 1].start()
                             if i + 1 < len(items) else source.index("            *)", item.end())]
        for i, item in enumerate(items)
    }


class SingBoxMenuLayoutTest(unittest.TestCase):
    def test_top_level_has_only_six_categories_and_exit(self):
        screen = function("show_menu")
        entries = re.findall(r"say '\s+(\d+)\) ([^']+)'", screen)
        self.assertEqual(entries, [(str(k), v[0]) for k, v in TOP_LEVEL.items()]
                         + [("0", "退出")])
        main = MENU.split("\nwhile :; do\n", 1)[1]
        for number, (_, marker) in TOP_LEVEL.items():
            self.assertRegex(main, rf"(?m)^        {number}\) {re.escape(marker)}")
        self.assertNotRegex(main, r"(?m)^        (?:[7-9]|[1-9]\d+)\)")
        self.assertNotIn("run_sbctl restart", main)
        self.assertNotIn("uninstall_service", main)

    def test_all_original_25_actions_have_one_category(self):
        cases = handlers()
        self.assertEqual(list(cases), list(EXPECTED_ACTIONS))
        self.assertEqual(len(cases), 25)
        for path, marker in EXPECTED_ACTIONS.items():
            with self.subTest(path=path):
                self.assertIn(marker, cases[path])
        screen = function("show_submenu")
        groups = list(re.finditer(r"(?m)^        (service|lan|config|install|diagnostics)\)", screen))
        for index, group in enumerate(groups):
            body = screen[group.end():groups[index + 1].start()
                          if index + 1 < len(groups) else screen.index("    esac", group.end())]
            labels = [int(x) for x in re.findall(r"say '\s+(\d+)\)", body)]
            wanted = [int(key.split(":")[1]) for key in EXPECTED_ACTIONS
                      if key.startswith(group.group(1) + ":")]
            self.assertEqual(labels, wanted)
        self.assertIn("0) 返回主菜单", screen)
        self.assertIn("q) 退出", screen)

    def test_labels_are_single_column_and_fit_narrow_cjk_terminals(self):
        count = 0
        for source in (function("show_menu"), function("show_submenu")):
            for line in re.findall(r"(?m)^\s*say '([^']*)'\s*$", source):
                prefix = re.match(r"^\s*\d+\) ", line)
                if not prefix:
                    continue
                cells = lambda text: sum(2 if unicodedata.east_asian_width(ch) in ("W", "F")
                                         else 1 for ch in text)
                self.assertEqual(cells(prefix.group()), 6)
                self.assertLessEqual(cells(line), 64)
                self.assertEqual(len(re.findall(r"\d+\) ", line)), 1)
                count += 1
        self.assertEqual(count, 33)  # 7 primary + 25 actions + shared return row.

    def test_start_restart_and_confirmations_keep_existing_guards(self):
        cases = handlers()
        self.assertIn("root_only && preflight_xtunnel && run_sbctl start", cases["service:2"])
        self.assertIn("root_only && ask", cases["service:3"])
        self.assertIn("preflight_xtunnel && run_sbctl restart", cases["service:3"])
        self.assertIn("root_only && ask", cases["service:4"])
        self.assertIn("root_only && ask", cases["install:5"])
        self.assertIn("保留配置、Provider 和 X-Tunnel", function("uninstall_service"))
        self.assertIn("ask '卸载 sing-box 服务并保留现有配置？'", function("uninstall_service"))
        self.assertIn("[Y/n]", function("ask"))
        self.assertNotIn("[y/N]", MENU)

    def test_navigation_is_iterative_and_old_number_hints_are_gone(self):
        self.assertEqual(len(re.findall(r"(?m)^while :; do$", MENU)), 1)
        submenu = function("run_submenu")
        self.assertIn("    while :; do\n", submenu)
        self.assertNotIn("run_submenu", submenu)
        self.assertNotIn("show_menu", submenu)
        self.assertIn('IFS= read -r submenu_choice || return 2', submenu)
        self.assertIn("wait_key || return 2", submenu)
        self.assertNotRegex(MENU, r"(?:menu option|Choose|选项|菜单)\s+[1-9]\d*")

    def test_route_manager_uses_installed_tool_then_checkout(self):
        source = function("manage_routes")
        installed = source.index("route_tool=$SB_HOME/scripts/route-manager.sh")
        fallback = source.index("route_tool=$REPO_DIR/scripts/route-manager.sh")
        call = source.index('/bin/bash "$route_tool" menu')
        self.assertLess(installed, fallback)
        self.assertLess(fallback, call)
        self.assertNotIn("jq ", source)
        self.assertNotIn("routing.json", source)


if __name__ == "__main__":
    unittest.main()
