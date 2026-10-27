#!/usr/bin/env python3
"""Lightweight fixture-runner regression tests; never invokes Zig or public hosts."""

import contextlib
import http.client
import io
import os
from pathlib import Path
import runpy
import shutil
import socket
import subprocess
import sys
import unittest
from unittest import mock
import urllib.parse


ROOT = Path(__file__).resolve().parent.parent
NAMES = ("downloader", "http-transport", "public-network")


def load(name):
    # Use function globals: runpy may return a copy of the namespace.
    return runpy.run_path(str(ROOT / "scripts" / f"test-{name}.py"))["main"].__globals__


def request(url, route):
    parsed = urllib.parse.urlsplit(url)
    connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=2)
    try:
        connection.request("GET", route)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


class FixtureRunnerTests(unittest.TestCase):
    def run_fixture(self, name, callback, args=None):
        module = load(name)
        urls = []

        def child(command, *, cwd, env):
            self.assertEqual(command, [str(Path("already built test").resolve())])
            self.assertEqual(cwd, ROOT)
            self.assertEqual(env["FIXTURE_INHERITED_VALUE"], "kept")
            urls.extend(value for key, value in env.items() if key.endswith("TEST_URL") or key == "PUBLIC_NETWORK_GUARD_TEST_V6_URL")
            return callback(env)

        with mock.patch.dict(os.environ, {"FIXTURE_INHERITED_VALUE": "kept"}), mock.patch.object(subprocess, "call", side_effect=child), contextlib.redirect_stdout(io.StringIO()):
            result = module["main"](args or ["--test-exe", "already built test"])
        for url in urls:
            parsed = urllib.parse.urlsplit(url)
            with self.assertRaises(OSError, msg=f"listener was not closed: {url}"):
                socket.create_connection((parsed.hostname, parsed.port), timeout=0.2)
        return result

    def test_build_arguments_and_loader_are_preserved(self):
        for name, target in (("downloader", "test-downloader"), ("http-transport", "test-http-transport")):
            command = load(name)["test_command"]
            self.assertEqual(command(["-Doptimize=ReleaseSafe", "-j1"]), ["zig", "build", target, "-Doptimize=ReleaseSafe", "-j1"])
        self.assertEqual(load("http-transport")["test_command"](["--loader", "-j1"]), ["zig", "build", "test-http-transport", "test-minecraft", "-j1"])
        module = load("public-network")
        with mock.patch.object(subprocess, "call", return_value=0) as child, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(module["main"](["-j1"]), 0)
        self.assertEqual(child.call_args.args[0], ["zig", "build", "test-http-transport", "-j1"])

    def test_direct_mode_rejects_build_options_and_protocol(self):
        for name in NAMES:
            for args in (["--test-exe"], ["--test-exe", "bin", "-j1"], ["--test-exe", "bin", "--listen=-"], ["--test-exe", "bin", "--loader"]):
                with self.subTest(name=name, args=args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                    load(name)["main"](args)
                self.assertEqual(error.exception.code, 2)

    def test_downloader_environment_and_exit_status(self):
        def child(env):
            self.assertEqual(env["NO_PROXY"], "127.0.0.1,localhost")
            self.assertEqual(env["no_proxy"], env["NO_PROXY"])
            self.assertEqual(request(env["DOWNLOADER_TEST_URL"], "/bytes"), (200, b"hello minecraft\n"))
            return 23
        self.assertEqual(self.run_fixture("downloader", child), 23)

    def test_transport_environment_and_exit_status(self):
        def child(env):
            for key in ("HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"):
                self.assertEqual(env[key], "http://127.0.0.1:1")
            self.assertEqual(env["NO_PROXY"], "")
            self.assertEqual(request(env["HTTP_TRANSPORT_TEST_URL"], "/get"), (200, b'{"ok":true}'))
            return 17
        self.assertEqual(self.run_fixture("http-transport", child), 17)

    def test_public_environment_and_failure_status(self):
        def child(env):
            for key in ("HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"):
                self.assertEqual(env[key], env["PUBLIC_NETWORK_GUARD_TEST_URL"])
            self.assertEqual(request(env["HTTP_TRANSPORT_TEST_URL"], "/get")[0], 200)
            return 19
        self.assertEqual(self.run_fixture("public-network", child), 19)

    def test_public_guard_and_reuse_assertions(self):
        for key in ("PUBLIC_NETWORK_GUARD_TEST_URL", "HTTP_TRANSPORT_TEST_URL", "PUBLIC_NETWORK_GUARD_TEST_V6_URL"):
            exercised = []

            def child(env):
                if key in env:
                    exercised.append(True)
                    request(env[key], "/must-not-request")
                return 0

            with self.subTest(listener=key):
                self.assertEqual(self.run_fixture("public-network", child), 1 if exercised else 0)

    def test_signal_and_interrupt_cleanup(self):
        def interrupt(_env):
            raise KeyboardInterrupt
        for name in NAMES:
            with self.subTest(name=name):
                self.assertEqual(self.run_fixture(name, lambda _env: -15), 143)
                self.assertEqual(self.run_fixture(name, interrupt), 130)

    def test_real_executable_cli(self):
        # Exercise the actual process boundary without needing a Zig compiler.
        for name in NAMES:
            for executable, status in (("true", 0), ("false", 1)):
                binary = shutil.which(executable)
                if binary is None:
                    self.skipTest(f"{executable} executable unavailable")
                with self.subTest(name=name, executable=executable):
                    result = subprocess.run([sys.executable, str(ROOT / "scripts" / f"test-{name}.py"), "--test-exe", binary], cwd=ROOT.parent, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, status, result.stderr)


if __name__ == "__main__":
    unittest.main()
