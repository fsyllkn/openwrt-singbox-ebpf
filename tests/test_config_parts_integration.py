#!/usr/bin/env python3
"""Exercise the real sbctl/menu composition path with isolated core/service tools.

The central layer's transaction and schema tests are separate. These cases cover
the callers that used to edit the runtime JSON directly. Nothing touches the
host's service manager, interfaces, DNS or firewall.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


class ConfigPartsIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sb-parts-integration-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.home = self.work / "service home"
        self.config = self.work / "external configs" / "active.json"
        self.parts = self.config.with_suffix(".d")
        self.tools = self.work / "tools"
        for path in (self.home / "scripts", self.home / "bin", self.home / "config",
                     self.home / "runtime", self.home / "providers", self.config.parent,
                     self.tools):
            path.mkdir(parents=True, exist_ok=True)
        for name in ("sbctl", "runtime-paths.sh", "config-parts.sh", "config-parts-lib.sh"):
            shutil.copyfile(ROOT / "scripts" / name, self.home / "scripts" / name)
        self.cli = self.home / "scripts" / "sbctl"
        # Select only the fixture's systemctl even if this test runs on OpenWrt.
        self.cli.write_text(self.cli.read_text().replace(
            'INIT_SYSTEM="$(detect_init)"', 'INIT_SYSTEM="systemd"'))
        self.cli.chmod(0o755)
        shutil.copyfile(ROOT / "config/config.template.json", self.home / "config/config.template.json")
        shutil.copyfile(ROOT / "config/config.template.json", self.config)
        for tag in ("local", "xboard"):
            shutil.copyfile(ROOT / f"examples/{tag}.sample.json", self.home / f"providers/{tag}.json")
        self.core_log = self.work / "core-events"
        self.service_log = self.work / "service-events"
        self.core_log.touch()
        self.service_log.touch()
        self.script(self.home / "bin/sing-box", '''#!/bin/sh
set -eu
[ "$1" = check ] && [ "$2" = -c ] && [ "$#" -eq 3 ] || exit 64
[ "$PWD" = "$SH_SINGBOX_HOME" ] || exit 65
printf '%s\n' "$3" >> "$FIXTURE_CORE_LOG"
jq -e 'type=="object" and (.inbounds|type=="array") and .log.level!="reject-fixture"' "$3" >/dev/null
''')
        self.script(self.tools / "systemctl", '''#!/bin/sh
printf '%s\n' "$*" >> "$FIXTURE_SERVICE_LOG"
exit 0
''')
        self.script(self.tools / "pidof", "#!/bin/sh\nexit 1\n")
        self.script(self.tools / "id", "#!/bin/sh\n[ \"$*\" = -u ] || exit 64\necho 0\n")
        self.script(self.tools / "uci", "#!/bin/sh\nexit 1\n")
        self.script(self.tools / "ip", '''#!/bin/sh
[ "$*" = '-4 -o addr show' ] || exit 64
printf '%s\n' '1: lo inet 127.0.0.1/8 scope host lo' '2: lan42 inet 10.23.40.45/23 scope global lan42'
''')
        self.script(self.tools / "vi", '''#!/bin/sh
set -eu
cp "$FIXTURE_EDIT" "$1"
if [ -n "${FIXTURE_CONCURRENT_EDIT:-}" ]; then
    cp "$FIXTURE_CONCURRENT_EDIT" "$FIXTURE_CONCURRENT_DEST"
fi
''')
        self.env = {**os.environ, "SH_SINGBOX_HOME": str(self.home),
                    "SH_SINGBOX_CONFIG": str(self.config),
                    "PATH": str(self.tools) + os.pathsep + os.environ["PATH"],
                    "FIXTURE_CORE_LOG": str(self.core_log),
                    "FIXTURE_SERVICE_LOG": str(self.service_log)}
        self.run_cli("split-config")
        self.assertTrue((self.parts / "layout.json").is_file())

    @staticmethod
    def script(path, content):
        path.write_text(content)
        path.chmod(0o755)

    def command(self, args, *, success=True, input=None, extra_env=None):
        result = subprocess.run(args, env={**self.env, **(extra_env or {})}, input=input,
                                text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def run_cli(self, *args, **kwargs):
        return self.command(["bash", str(self.cli), *map(str, args)], **kwargs)

    def read_config(self):
        return json.loads(self.config.read_text())

    def test_changed_sources_precede_cache_and_failed_restart_keeps_service(self):
        self.run_cli("preflight")
        count = len(self.core_log.read_text().splitlines())
        self.run_cli("preflight")
        self.assertEqual(len(self.core_log.read_text().splitlines()), count)
        part = self.parts / "inbounds.json"
        data = json.loads(part.read_text())
        mixed = next(item for item in data["inbounds"] if item["type"] == "mixed")
        mixed["listen_port"] += 1
        write_json(part, data)
        self.run_cli("preflight")
        self.assertGreater(len(self.core_log.read_text().splitlines()), count)
        actual = next(item for item in self.read_config()["inbounds"] if item["type"] == "mixed")
        self.assertEqual(actual["listen_port"], mixed["listen_port"])

        before = self.config.read_bytes()
        part.write_text('{"inbounds": [broken}\n')
        output = self.run_cli("restart", success=False)
        self.assertIn("NOT stopped", output)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(self.service_log.read_text(), "")
        self.run_cli("stop")
        self.assertEqual(self.service_log.read_text(), "stop sing-box.service\n")

    def test_uid_and_process_changes_survive_recomposition(self):
        policy = json.loads((self.home / "config/config.template.json").read_text())
        self.run_cli("filter", "exclude-user", "34567")
        inbounds = json.loads((self.parts / "inbounds.json").read_text())["inbounds"]
        local = next(item["local"] for item in inbounds if item["type"] == "ebpf")
        self.assertIn(34567, local["exclude_uid"])
        self.run_cli("filter", "exclude-proc", "fixture-agent")
        routes = json.loads((self.parts / "routing.json").read_text())["route"]["rules"]
        self.assertTrue(any("fixture-agent" in rule.get("process_name", []) for rule in routes))
        self.run_cli("preflight")
        config = self.read_config()
        self.assertEqual(config["inbounds"], inbounds)
        self.assertEqual(config["dns"], policy["dns"])
        self.assertEqual(config["route"]["rules"],
                         policy["route"]["rules"][:3] + routes + policy["route"]["rules"][3:])
        self.run_cli("filter", "remove-proc", "fixture-agent")
        self.assertEqual(json.loads((self.parts / "routing.json").read_text())["route"]["rules"], [])
        self.assertEqual(self.read_config()["route"]["rules"], policy["route"]["rules"])
        self.assertEqual(self.service_log.read_text(), "")

    def test_full_import_updates_sources_or_leaves_everything_intact(self):
        imported = self.read_config()
        imported["log"]["level"] = "debug"
        imported["route"]["rules"].insert(3, {
            "source_ip_cidr": ["10.23.40.12/32"], "ip_cidr": ["10.77.50.0/24"],
            "action": "route", "outbound": "configure-your-proxy"})
        draft = self.work / "full-import.json"
        write_json(draft, imported)
        self.run_cli("import-config", draft)
        self.assertEqual(self.read_config(), imported)
        self.assertEqual(json.loads((self.parts / "settings.json").read_text())["log"]["level"], "debug")
        before = self.config.read_bytes()
        sources = {path.name: path.read_bytes() for path in self.parts.glob("*.json")}
        imported["dns"]["final"] = "dns-direct"
        write_json(draft, imported)
        self.run_cli("import-config", draft, success=False)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual({path.name: path.read_bytes() for path in self.parts.glob("*.json")}, sources)
        self.assertEqual(self.service_log.read_text(), "")

    def test_menu_edits_fragment_transactionally_and_retains_failed_draft(self):
        # Remove only the host OS guard and interactive dispatch. Keep production
        # path resolution, functions and editor handling unchanged.
        menu_source = (ROOT / "menu.sh").read_text().split("\nwhile :; do\n", 1)[0]
        menu_source = re.sub(r'^\[ -f /etc/openwrt_release \] \|\| \{\n.*?^\}\n', "",
                             menu_source, count=1, flags=re.M | re.S)
        self.assertNotIn("This distribution requires OpenWrt", menu_source)
        menu = self.home / "scripts/menu.sh"
        menu.write_text(menu_source + "\nedit_config\n")
        edit = self.work / "edited-settings.json"
        settings = json.loads((self.parts / "settings.json").read_text())
        settings["log"]["level"] = "debug"
        write_json(edit, settings)
        self.command(["sh", str(menu)], input="5\n", extra_env={"FIXTURE_EDIT": str(edit)})
        self.assertEqual(self.read_config()["log"]["level"], "debug")
        self.assertEqual(json.loads((self.parts / "settings.json").read_text()), settings)
        before = self.config.read_bytes()
        settings["log"]["level"] = "reject-fixture"
        write_json(edit, settings)
        self.command(["sh", str(menu)], success=False, input="5\n",
                     extra_env={"FIXTURE_EDIT": str(edit)})
        self.assertEqual(self.config.read_bytes(), before)
        drafts = list((self.home / "runtime").glob("settings.rejected.*.json"))
        self.assertEqual(len(drafts), 1)
        self.assertEqual(json.loads(drafts[0].read_text()), settings)
        self.assertEqual(drafts[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.service_log.read_text(), "")

    def test_menu_does_not_overwrite_a_concurrent_edit_to_the_same_section(self):
        menu_source = (ROOT / "menu.sh").read_text().split("\nwhile :; do\n", 1)[0]
        menu_source = re.sub(r'^\[ -f /etc/openwrt_release \] \|\| \{\n.*?^\}\n', "",
                             menu_source, count=1, flags=re.M | re.S)
        menu = self.home / "scripts/menu.sh"
        menu.write_text(menu_source + "\nedit_config\n")
        original = json.loads((self.parts / "settings.json").read_text())
        edited = {**original, "log": {**original["log"], "level": "debug"}}
        concurrent = {**original, "log": {**original["log"], "level": "warn"}}
        edit = self.work / "user-draft.json"
        other = self.work / "concurrent-draft.json"
        write_json(edit, edited)
        write_json(other, concurrent)
        before = self.config.read_bytes()
        self.command(["sh", str(menu)], success=False, input="5\n", extra_env={
            "FIXTURE_EDIT": str(edit), "FIXTURE_CONCURRENT_EDIT": str(other),
            "FIXTURE_CONCURRENT_DEST": str(self.parts / "settings.json")})
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(json.loads((self.parts / "settings.json").read_text()), concurrent)
        drafts = list((self.home / "runtime").glob("settings.rejected.*.json"))
        self.assertEqual(len(drafts), 1)
        self.assertEqual(json.loads(drafts[0].read_text()), edited)
        self.assertEqual(self.service_log.read_text(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
