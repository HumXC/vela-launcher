#!/usr/bin/env python3
"""Run public-address guard regressions with zero-contact loopback listeners.

Usage: python3 scripts/test-public-network.py [zig build options...]
       python3 scripts/test-public-network.py --test-exe PATH
PATH is a compiled default HTTP transport Zig test executable.
"""
import os
from pathlib import Path
import runpy
import socket
import subprocess
import sys
import threading
from http.server import ThreadingHTTPServer

fixture = runpy.run_path(str(Path(__file__).with_name("test-http-transport.py")))


class Guarded(fixture["Fixture"]):
    def __init__(self):
        super().__init__()
        self.accepted = 0

    def get_request(self):
        result = super().get_request()
        with self.lock:
            self.accepted += 1
        return result


class Guarded6(Guarded):
    address_family = socket.AF_INET6

    def __init__(self):
        ThreadingHTTPServer.__init__(self, ("::1", 0), fixture["Handler"])
        self.denied_hits = 0
        self.accepted = 0
        self.lock = threading.Lock()


def main(args=None):
    command = fixture["test_command"](args, allow_loader=False)
    root = Path(__file__).resolve().parent.parent
    control = fixture["Fixture"]()
    guard = Guarded()
    servers = [control, guard]
    guard6 = None
    try:
        guard6 = Guarded6()
        servers.append(guard6)
    except OSError as error:
        print("IPv6 fixture unavailable:", error, flush=True)
    threads = []
    for server in servers:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        threads.append(thread)
    env = os.environ.copy()
    env["HTTP_TRANSPORT_TEST_URL"] = f"http://127.0.0.1:{control.server_port}"
    env["PUBLIC_NETWORK_GUARD_TEST_URL"] = f"http://127.0.0.1:{guard.server_port}"
    if guard6 is not None:
        env["PUBLIC_NETWORK_GUARD_TEST_V6_URL"] = f"https://[::1]:{guard6.server_port}/must-not-request"
    else:
        env.pop("PUBLIC_NETWORK_GUARD_TEST_V6_URL", None)
    for name in ("HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"):
        env[name] = env["PUBLIC_NETWORK_GUARD_TEST_URL"]
    env["NO_PROXY"] = env["no_proxy"] = ""
    try:
        status = subprocess.call(command, cwd=root, env=env)
        if status < 0:
            status = 128 - status
    except KeyboardInterrupt:
        status = 130
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join()
    for label, server in (("IPv4", guard), ("IPv6", guard6)):
        if server is not None:
            print(f"Guarded {label} accepted sockets: {server.accepted}; forbidden HTTP hits: {server.denied_hits}", flush=True)
            if server.accepted or server.denied_hits:
                status = 1
    print("Control forbidden HTTP hits after connection-reuse regression:", control.denied_hits, flush=True)
    if control.denied_hits:
        status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
