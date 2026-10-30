"""Static, read-only regression checks for the OpenWrt sing-box menu."""
import re
import unicodedata
import unittest
from pathlib import Path


MENU = (Path(__file__).resolve().parents[1] / "menu.sh").read_text(encoding="utf-8")
EXPECTED_ACTIONS = {
    1: "install_core",
    2: "source_update",
    3: "preflight_xtunnel && run_sbctl restart",
    4: "run_sbctl logs",
    5: "preflight_xtunnel && run_sbctl start",
    6: "run_sbctl stop",
    7: "run_sbctl status",
    8: "run_sbctl check",
    9: "edit_config",
    10: "migrate_config",
    11: "run_sbctl update-rules",
    12: "run_sbctl update-core",
    13: "configure_gateway",
    14: '/bin/bash "$GATEWAY" status',
    15: "disable_gateway",
    16: "configure_pc_proxy",
    17: "disable_pc_proxy",
    18: "apply_pc_privacy",
    19: "privacy_audit",
    20: "inspect_xtunnel",
    21: "align_xtunnel_ebpf",
    22: "run_sbctl ebpf-status",
    23: "Uninstall sing-box services",
    24: "configure_download_proxy",
    25: "manage_config_parts",
}


def menu_parts():
    start = MENU.index("show_menu() {\n")
    end = MENU.index("\n}\nwhile :; do\n    show_menu", start)
    screen = MENU[start:end]
    switch_start = MENU.index('    case "$choice" in\n', end)
    switch_end = MENU.index('        0|q|Q) break ;;', switch_start)
    body = MENU[switch_start:switch_end]
    entries = list(re.finditer(r"(?m)^        (\d+)\)", body))
    cases = {
        int(item.group(1)): body[item.start():(entries[i + 1].start()
                             if i + 1 < len(entries) else len(body))]
        for i, item in enumerate(entries)
    }
    return screen, cases, [int(item.group(1)) for item in entries]


class SingBoxMenuLayoutTest(unittest.TestCase):
    def test_display_contains_every_choice_once_in_order(self):
        screen, _, _ = menu_parts()
        displayed = [int(x) for x in re.findall(r"(?<!\d)(\d{1,2})\)", screen)]
        self.assertEqual(displayed, list(EXPECTED_ACTIONS) + [0])
        for group in ("【安装与常用】", "【配置与更新】", "【LAN 透明网关】",
                      "【PC 代理与隐私】", "【X-Tunnel / eBPF 诊断】", "【维护】"):
            self.assertIn(group, screen)

    def test_all_25_menu_handlers_remain_available(self):
        _, cases, order = menu_parts()
        self.assertEqual(order, list(EXPECTED_ACTIONS))
        for number, marker in EXPECTED_ACTIONS.items():
            with self.subTest(option=number):
                self.assertIn(marker, cases[number])

    def test_aligned_two_column_menu_for_cjk_terminals(self):
        # Static spaces count terminal cells, NOT Python string characters.
        # Chinese ideographs are wide; right-hand descriptions must begin
        # at the same terminal-cell position on every paired menu row.
        screen = menu_parts()[0]
        rows = re.findall(r"(?m)^\s*say '([^']*)'\s*$", screen)
        menu_entries = 0
        paired_entries = 0
        def cells(value):
            return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F")
                       else 1 for ch in value)
        for line in rows:
            if line.startswith("  【"):
                self.assertEqual(line[:2], "  ")
                continue
            if not re.match(r"^\s*\d{1,2}\) ", line):
                continue
            choices = list(re.finditer(r"\d{1,2}\) ", line))
            menu_entries += len(choices)
            self.assertEqual(cells(line[:choices[0].end()]), 6)
            self.assertLessEqual(cells(line), 64)
            if len(choices) == 2:
                paired_entries += 1
                self.assertEqual(cells(line[:choices[1].end()]), 37)
        self.assertGreaterEqual(menu_entries, 25)
        self.assertGreaterEqual(paired_entries, 7)

    def test_restart_preserves_ebpf_uid_safety_and_logs_are_four(self):
        _, cases, _ = menu_parts()
        self.assertIn("root_only && ask", cases[3])
        self.assertIn("preflight_xtunnel && run_sbctl restart", cases[3])
        self.assertIn("preflight_xtunnel && run_sbctl start", cases[5])
        self.assertIn("run_sbctl logs", cases[4])
        self.assertIn("source_update", cases[2])
        self.assertIn("run_sbctl check", cases[8])


if __name__ == "__main__":
    unittest.main()
