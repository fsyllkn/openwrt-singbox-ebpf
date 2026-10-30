#!/usr/bin/env python3
"""Guard the public starter/examples against private configuration and caches.

An optional SB_PUBLIC_FINGERPRINTS file stays outside the repository. Test
failures report paths/categories only, never the matching private values.
"""
from __future__ import annotations

import collections
import ipaddress
import json
import os
from pathlib import Path
import re
import unittest
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
JSON_FILES = (
    ROOT / "config" / "config.json",
    ROOT / "config" / "config.template.json",
    ROOT / "providers" / "provider.template.json",
    ROOT / "examples" / "lan-private-routing.json",
)
DOCUMENTATION_NETS = tuple(ipaddress.ip_network(cidr) for cidr in
                           ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"))
CREDENTIAL_KEYS = {
    "username", "password", "uuid", "psk", "secret", "token", "api_key",
    "access_token", "private_key", "public_key", "short_id", "authorization",
}
FLAG = re.compile(r"[\U0001F1E6-\U0001F1FF]")


def entries(value, path=()):
    if isinstance(value, dict):
        for key, child in value.items():
            yield from entries(child, path + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from entries(child, path + (str(index),))
    else:
        yield path, value


def placeholder_host(value):
    if value == "example.invalid" or value.endswith(".example.invalid"):
        return True
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return address.is_loopback or any(address in network for network in DOCUMENTATION_NETS)


class PublicSanitizationTests(unittest.TestCase):
    def setUp(self):
        self.docs = {}
        for path in JSON_FILES:
            try:
                self.docs[path.name if path.parent.name != "config" else str(path.relative_to(ROOT))] = json.loads(path.read_text())
            except (OSError, ValueError):
                self.fail(f"Missing/invalid public JSON: {path.relative_to(ROOT)}")
        self.starter = self.docs["config/config.json"]
        self.example = self.docs["lan-private-routing.json"]

    def test_starter_matches_template_and_has_no_automatic_subscription(self):
        self.assertTrue(
            (ROOT / "config/config.json").read_bytes() == (ROOT / "config/config.template.json").read_bytes(),
            "The public starter and installation template must be identical.",
        )
        for name, doc in (("starter", self.starter), ("example", self.example)):
            self.assertTrue(doc.get("providers", []) == [], f"{name}: unexpected automatic provider subscription")
        self.assertTrue(self.docs["provider.template.json"] == {"outbounds": []},
                        "Provider template must contain no downloaded/private nodes.")

    def test_proxy_paths_do_not_fall_back_to_direct(self):
        outbounds = {item.get("tag"): item for item in self.starter.get("outbounds", [])}
        self.assertTrue(set(outbounds) == {"proxy", "ai", "configure-your-proxy", "direct"},
                        "Starter contains unexpected real/example nodes.")
        self.assertTrue(outbounds["proxy"].get("outbounds") == ["configure-your-proxy"],
                        "Proxy selector must use only the explicitly pending upstream.")
        self.assertTrue(outbounds["ai"].get("outbounds") == ["proxy"],
                        "AI selector must keep the proxy dependency.")
        self.assertTrue(outbounds["configure-your-proxy"].get("type") == "socks"
                        and outbounds["configure-your-proxy"].get("server") == "127.0.0.1"
                        and outbounds["configure-your-proxy"].get("server_port") == 1080,
                        "Starter upstream must be an obvious configurable local SOCKS placeholder.")
        self.assertTrue(self.starter.get("route", {}).get("final") == "proxy",
                        "Default proxy traffic must not silently fall back to direct.")
        for doc in (self.starter, self.example):
            for outbound in doc.get("outbounds", []):
                if outbound.get("tag") in {"proxy", "ai"}:
                    self.assertTrue("direct" not in outbound.get("outbounds", [])
                                    and outbound.get("default") != "direct",
                                    "Proxy/AI selectors must not contain a direct fallback.")
                if "server" in outbound:
                    self.assertTrue(placeholder_host(outbound["server"]),
                                    "An outbound contains a non-documentation endpoint.")

    def test_no_personal_credentials_or_regional_node_labels(self):
        for path in JSON_FILES:
            doc = json.loads(path.read_text())
            for location, value in entries(doc):
                if isinstance(value, str):
                    self.assertTrue(not FLAG.search(value),
                                    f"Regional node label in {path.relative_to(ROOT)}")
                if location and location[-1].lower() in CREDENTIAL_KEYS and value not in (None, ""):
                    allowed = path.parent.name == "examples" and isinstance(value, str) and value.startswith("REPLACE_WITH_")
                    self.assertTrue(allowed, f"Non-placeholder credential in {path.relative_to(ROOT)}")
                if location and location[-1].lower() in {"listen", "server_name", "servername", "sni", "host", "hostname"} and value:
                    self.assertTrue(isinstance(value, str) and placeholder_host(value),
                                    f"Non-documentation listener/hostname in {path.relative_to(ROOT)}")
                if isinstance(value, str) and value.startswith(("http://", "https://")):
                    parsed = urlsplit(value)
                    self.assertTrue(parsed.username is None and parsed.password is None and not parsed.query,
                                    f"Credential/query-bearing URL in {path.relative_to(ROOT)}")
                    self.assertTrue(parsed.hostname in {"github.com", "raw.githubusercontent.com", "sing-box.sagernet.org"},
                                    f"Unexpected download/schema URL in {path.relative_to(ROOT)}")

    def test_fresh_install_does_not_trust_a_personal_lan_or_uid(self):
        mixed = [item for item in self.starter.get("inbounds", []) if item.get("tag") == "lan-mixed"]
        self.assertTrue(len(mixed) == 1 and mixed[0].get("listen") == "127.0.0.1"
                        and mixed[0].get("users") == [],
                        "Fresh installation must not copy a personal LAN address/account.")
        for inbound in self.starter.get("inbounds", []):
            if inbound.get("type") == "ebpf":
                self.assertTrue(inbound.get("local", {}).get("exclude_uid", []) == []
                                and inbound.get("local", {}).get("include_uid", []) == []
                                and inbound.get("local", {}).get("exclude_uid_range", []) == [],
                                "Fresh installation must detect deliberate local UID policy.")
        self.assertTrue(self.starter.get("experimental", {}).get("clash_api", {}).get("external_controller") == "127.0.0.1:9090",
                        "Public starter must not expose a personal/public API bind.")
        self.assertTrue(not any("ip_cidr" in rule or "source_ip_cidr" in rule
                                for rule in self.starter.get("route", {}).get("rules", [])),
                        "Fresh installation must not inherit a personal destination/source subnet.")

    def test_example_preserves_authenticated_lan_and_remote_private_priority(self):
        mixed = [item for item in self.example.get("inbounds", []) if item.get("tag") == "lan-mixed"]
        self.assertTrue(len(mixed) == 1 and mixed[0].get("listen") == "192.0.2.10"
                        and bool(mixed[0].get("users")),
                        "LAN example must show an authenticated documentation-address listener.")
        rules = self.example.get("route", {}).get("rules", [])
        private_rules = [(index, rule) for index, rule in enumerate(rules) if rule.get("outbound") == "remote-office"]
        self.assertTrue(len(private_rules) == 1, "Missing or duplicate remote private-network exception.")
        index, rule = private_rules[0]
        self.assertTrue(rule.get("ip_cidr") == ["10.77.50.10/32", "10.88.60.0/24"],
                        "Private-network example must use only the documented fictional networks.")
        self.assertTrue([item for item in rules if "ip_cidr" in item] == [rule],
                        "Example contains an undocumented destination subnet.")
        self.assertTrue(index > 2 and rules[0].get("action") == "hijack-dns"
                        and rules[1].get("action") == "sniff" and rules[2].get("action") == "reject",
                        "Custom private routing must retain DNS/sniff/STUN guard priority.")
        fallback = [i for i, item in enumerate(rules)
                    if item.get("ip_is_private") is True or "private" in item.get("rule_set", [])]
        self.assertTrue(bool(fallback) and all(index < i for i in fallback),
                        "Specific remote private destinations must precede general private direct rules.")
        self.assertTrue(any(item.get("tag") == "remote-office" for item in self.example.get("outbounds", [])),
                        "Private exception must reference a defined outbound.")

    def test_downloaded_provider_cache_is_absent_and_ignored(self):
        provider_files = {path.name for path in (ROOT / "providers").iterdir() if path.is_file()}
        self.assertTrue(provider_files == {"provider.template.json", "README.md"},
                        "Public provider directory contains downloaded/private data.")
        ignores = (ROOT / ".gitignore").read_text().splitlines()
        self.assertTrue(all(item in ignores for item in (
            "/providers/*", "!/providers/provider.template.json", "!/providers/README.md",
            "/runtime/", "/geo/", "/bin/", "/board/",
        )), "Downloaded nodes/assets/runtime state must be ignored.")

    def test_downloaded_rules_are_available_to_first_start(self):
        updater = (ROOT / "scripts/update-rules.sh").read_text()
        rule_names = re.findall(r'^\s+"([a-z0-9-]+\.srs)"$', updater, re.MULTILINE)
        self.assertTrue(bool(rule_names), "Rule downloader publishes no seed files.")
        for name in ("config/config.json", "config/config.template.json", "examples/lan-private-routing.json"):
            doc = json.loads((ROOT / name).read_text())
            self.assertTrue(doc.get("experimental", {}).get("cache_file", {}).get("enabled") is True,
                            f"{name}: initial_path requires the core cache service.")
            seeds = set()
            for item in doc.get("route", {}).get("rule_set", []):
                if item.get("type") != "remote":
                    continue
                seed = item.get("initial_path")
                self.assertTrue(seed == "geo/" + item["tag"] + ".srs" and "path" not in item,
                                f"{name}: remote rules do not reference installed seed files.")
                self.assertTrue(Path(urlsplit(item.get("url", "")).path).name == Path(seed).name,
                                f"{name}: downloaded resource and startup seed differ.")
                seeds.add(Path(seed).name)
            self.assertTrue(seeds == set(rule_names), f"{name}: startup seeds differ from the updater assets.")

    @unittest.skipUnless(os.environ.get("SB_PUBLIC_FINGERPRINTS"),
                         "Private fingerprint inventory intentionally stays outside the public repository.")
    def test_external_private_fingerprints(self):
        try:
            inventory = json.loads(Path(os.environ["SB_PUBLIC_FINGERPRINTS"]).read_text())
        except (OSError, ValueError):
            self.fail("Cannot read the external private fingerprint inventory.")
        candidates = inventory.get("scan_candidates", [])
        self.assertTrue(bool(candidates), "External inventory contains no scan candidates.")
        hits = collections.Counter()
        for path in ROOT.rglob("*"):
            if not path.is_file() or ".git" in path.relative_to(ROOT).parts:
                continue
            try:
                content = path.read_text()
            except (OSError, UnicodeError):
                continue
            for item in candidates:
                value = item.get("value")
                if isinstance(value, str) and value and value in content:
                    hits[(str(path.relative_to(ROOT)), item.get("category", "identifier"))] += 1
        # Never include a matched private value in unittest diagnostics.
        summary = "; ".join(f"{path} [{category}]: {count}" for (path, category), count in sorted(hits.items()))
        self.assertTrue(not hits, f"Private identifier matches by file/category: {summary}")


if __name__ == "__main__":
    unittest.main()
