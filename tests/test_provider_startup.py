#!/usr/bin/env python3
"""Start the pinned core and inspect the public Provider examples via its API.

Run with SB_TEST_CORE pointing to an already verified reF1nd binary. A separate
network namespace has only loopback; no service, gateway, DNS guard or host
firewall is used. The tested providers/outbounds are copied unchanged from the
public starter. eBPF, remote rules and the dashboard are outside this Provider
test, so its success is not a claim about full-device transparent proxying.
"""
from __future__ import annotations

import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener


ROOT = Path(__file__).resolve().parents[1]
OPENER = build_opener(ProxyHandler({}))  # Local fixture/API must bypass proxy env.
CORE = os.environ.get("SB_TEST_CORE", "")
SAMPLES = {"xboard": "xboard.sample.json", "local": "local.sample.json"}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def api(port, path, method="GET", data=None):
    body = None if data is None else json.dumps(data).encode()
    request = Request("http://127.0.0.1:%d%s" % (port, path), data=body, method=method)
    if body is not None:
        request.add_header("Content-Type", "application/json")
    with OPENER.open(request, timeout=1) as response:
        payload = response.read()
    return json.loads(payload) if payload else None


class RunningCore:
    def __init__(self, work, config):
        self.work = work
        self.config = config
        self.port = int(config["experimental"]["clash_api"]["external_controller"].rsplit(":", 1)[1])
        self.process = None
        self.log = None

    def __enter__(self):
        config_path = self.work / "config.json"
        config_path.write_text(json.dumps(self.config, indent=2) + "\n")
        self.log = (self.work / "core.log").open("wb")
        self.process = subprocess.Popen(
            [CORE, "run", "-D", str(self.work), "-c", str(config_path)],
            cwd=self.work, stdout=self.log, stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise AssertionError("Core exited before its API was ready")
                try:
                    api(self.port, "/proxies")
                    return self
                except (HTTPError, URLError, TimeoutError, OSError):
                    time.sleep(0.1)
            raise AssertionError("Core API did not become ready within 20 seconds")
        except BaseException:
            self.close(show_log=True)
            raise

    def close(self, show_log=False):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.log is not None:
            self.log.close()
            self.log = None
        if show_log:
            print((self.work / "core.log").read_text(errors="replace"), file=sys.stderr)

    def __exit__(self, exc_type, exc, traceback):
        self.close(show_log=exc is not None)


def prepare(work):
    starter = json.loads((ROOT / "config/config.template.json").read_text())
    work.mkdir()
    (work / "providers").mkdir()
    for tag, filename in SAMPLES.items():
        shutil.copyfile(ROOT / "examples" / filename, work / "providers" / (tag + ".json"))
    mixed_port = free_port()
    api_port = free_port()
    while api_port == mixed_port:
        api_port = free_port()
    # The Provider/selector graph is unmodified; only unrelated device network
    # capture and downloads are omitted from this isolated integration test.
    return {
        "log": {"level": "info", "timestamp": True},
        "inbounds": [{"type": "mixed", "tag": "sample-test", "listen": "127.0.0.1", "listen_port": mixed_port}],
        "providers": copy.deepcopy(starter["providers"]),
        "outbounds": copy.deepcopy(starter["outbounds"]),
        "route": {"final": starter["route"]["final"]},
        "experimental": {
            "cache_file": {"enabled": True, "path": "sample-test.db"},
            "clash_api": {"external_controller": "127.0.0.1:%d" % api_port, "default_mode": "Rule"},
        },
    }


def assert_loaded(core, remote=False):
    providers = api(core.port, "/providers/proxies")["providers"]
    require(set(providers) == set(SAMPLES), "Both example Providers must actually load")
    expected = []
    for tag, filename in SAMPLES.items():
        sample = json.loads((ROOT / "examples" / filename).read_text())
        names = [tag + "/" + item["tag"] for item in sample["outbounds"]]
        require(names, "Empty Provider is not a runnable example")
        require([item["name"] for item in providers[tag]["proxies"]] == names,
                "Provider API names do not match the public sample")
        vehicle = "Remote" if remote and tag == "xboard" else "Local"
        require(providers[tag]["vehicleType"] == vehicle, "Provider used the wrong source type")
        expected.extend(names)
    proxies = api(core.port, "/proxies")["proxies"]
    choices = proxies["proxy"]["all"]
    require(set(choices) == {"configure-your-proxy", *expected},
            "Proxy selector lost Provider nodes or gained an unintended fallback")
    require(proxies["proxy"]["now"] == "configure-your-proxy",
            "Fresh starter should retain its explicit static default")
    require(proxies["ai"]["all"] == ["proxy"], "AI selector must retain the proxy dependency")
    # Selecting a Provider node through the API must work without dialing it.
    api(core.port, "/proxies/proxy", "PUT", {"name": expected[0]})
    require(api(core.port, "/proxies")["proxies"]["proxy"]["now"] == expected[0],
            "A displayed Provider node cannot actually be selected")
    api(core.port, "/proxies/proxy", "PUT", {"name": "configure-your-proxy"})


def run_tests():
    subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
    with tempfile.TemporaryDirectory(prefix="sb-provider-startup.") as directory:
        root = Path(directory)
        local_work = root / "local"
        local_config = prepare(local_work)
        with RunningCore(local_work, local_config) as core:
            assert_loaded(core)
        print("PASS: real core starts with both local samples; Provider nodes are selectable without a direct fallback")

        # Exercise the HTTP sample against a loopback-only subscription fixture.
        # The placeholder URL in the public file is never requested.
        payload = (ROOT / "examples/xboard.sample.json").read_bytes()
        requests = []

        class Subscription(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append((self.path, self.headers.get("User-Agent")))
                if self.path != "/sample-subscription":
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, format, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Subscription)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            remote_work = root / "remote"
            remote_config = prepare(remote_work)
            fragment = json.loads((ROOT / "examples/http-provider.sample.json").read_text())
            remote = next(copy.deepcopy(item) for item in fragment["providers"] if item["tag"] == "xboard")
            require(remote["type"] == "remote", "HTTP example uses an unsupported Provider type")
            require(remote["path"] == "providers/xboard.json", "HTTP cache path does not match the installed sample")
            remote["url"] = "http://127.0.0.1:%d/sample-subscription" % server.server_port
            remote_config["providers"] = [remote if item["tag"] == "xboard" else item
                                          for item in remote_config["providers"]]
            cache = remote_work / remote["path"]
            cache.unlink()  # A pre-existing fresh cache would skip first fetch.
            with RunningCore(remote_work, remote_config) as core:
                assert_loaded(core, remote=True)
                require(requests == [("/sample-subscription", "clash.meta")],
                        "HTTP Provider did not fetch once with the sample User-Agent")
                cached = json.loads(cache.read_text())
                sample_nodes = json.loads(payload)["outbounds"]
                cached_nodes = cached.get("outbounds", [])
                require(len(cached_nodes) == len(sample_nodes) and
                        all(all(actual.get(key) == value for key, value in expected.items())
                            for actual, expected in zip(cached_nodes, sample_nodes)),
                        "HTTP Provider did not preserve the sample nodes in its normalized JSON cache")
            print("PASS: HTTP sample fetches and loads the loopback fixture and writes its cache")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

        # A valid, recent HTTP cache should permit restart while its endpoint is
        # unavailable. This does not disable later subscription refreshes.
        with RunningCore(remote_work, remote_config) as core:
            assert_loaded(core, remote=True)
        print("PASS: real core restarts from the fresh HTTP cache with its fixture offline")
    print("Provider startup integration passed inside a loopback-only network namespace; no eBPF/TProxy capture was tested")


def main():
    global CORE
    if not CORE:
        print("SKIP: set SB_TEST_CORE to a verified reF1nd binary for the real Provider startup test")
        return 0
    CORE = str(Path(CORE).resolve())
    require(os.path.isfile(CORE) and os.access(CORE, os.X_OK), "SB_TEST_CORE must be an executable file")
    if sys.argv[1:] != ["--inside-netns"]:
        for command in ("unshare", "ip"):
            require(shutil.which(command), command + " is required for the isolated Provider startup test")
        environment = dict(os.environ, SB_TEST_CORE=CORE)
        return subprocess.run(["unshare", "--net", "--", sys.executable, str(Path(__file__).resolve()), "--inside-netns"],
                              env=environment, timeout=120).returncode
    run_tests()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("FAILED: %s" % error, file=sys.stderr)
        sys.exit(1)
