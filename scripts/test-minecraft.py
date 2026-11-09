#!/usr/bin/env python3
"""Offline installation/launch integration fixture. Run from the repository root.

    python3 scripts/test-minecraft.py
    python3 scripts/test-minecraft.py --skip-build --binary zig-out/bin/vela-mc

Only stdlib is required. No Minecraft credentials or public network are used.
"""
import argparse
import collections
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import zipfile

REPO = Path(__file__).resolve().parents[1]


def encode(value):
    return json.dumps(value, separators=(",", ":")).encode()


def sha(data):
    return hashlib.sha1(data).hexdigest()


def archive(malicious=False):
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("native.bin", b"native fixture\n")
        z.writestr("META-INF/MANIFEST.MF", b"excluded fixture\n")
        if malicious:
            z.writestr("../../../../escaped.txt", b"must never escape")
    return out.getvalue()


class Fixture(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.lock = threading.Lock()
        self.responses = {}
        self.bodies = collections.Counter()
        self.base = "http://127.0.0.1:" + str(self.server_port)
        self.configure()

    def configure(self, *, bad_hash=False, malicious=False):
        data = {
            "/client.jar": b"client fixture\n",
            "/library.jar": b"library fixture\n",
            "/logging.xml": b"<Configuration/>\n",
            "/native.zip": archive(malicious),
            "/index.json": encode({"objects": {}}),
        }

        def download(endpoint, **extra):
            body = data[endpoint]
            return {"url": self.base + endpoint, "sha1": sha(body), "size": len(body), **extra}

        client = download("/client.jar")
        if bad_hash:
            client["sha1"] = "0" * 40
        version = {
            "id": "fixture",
            "type": "release",
            "mainClass": "fixture.Main",
            "javaVersion": {"component": "java-runtime-test", "majorVersion": 21},
            "downloads": {"client": client},
            "assetIndex": {"id": "fixture-assets", **download("/index.json")},
            "assets": "fixture-assets",
            "libraries": [
                {"name": "test:library:1", "downloads": {"artifact": download("/library.jar", path="test/library/1/library-1.jar")}},
                {"name": "test:native:1", "downloads": {"classifiers": {"natives-linux-64": download("/native.zip", path="test/native/1/native-1-linux.jar")}},
                 "natives": {"linux": "natives-linux-" + "$" + "{arch}"}, "extract": {"exclude": ["META-INF/"]}},
            ],
            "logging": {"client": {"argument": "-Dlog4j.configurationFile=" + "$" + "{path}", "type": "log4j2-xml", "file": {"id": "fixture-log.xml", **download("/logging.xml")}}},
            "arguments": {
                "jvm": ["-Djava.library.path=" + "$" + "{natives_directory}", "-cp", "$" + "{classpath}"],
                "game": ["--username", "$" + "{auth_player_name}", "--version", "$" + "{version_name}", "--gameDir", "$" + "{game_directory}", "--assetsDir", "$" + "{assets_root}", "--assetIndex", "$" + "{assets_index_name}", "--uuid", "$" + "{auth_uuid}", "--accessToken", "$" + "{auth_access_token}", "--userType", "$" + "{user_type}", "--versionType", "$" + "{version_type}"],
            },
        }
        data["/version.json"] = encode(version)
        data["/version_manifest_v2.json"] = encode({
            "latest": {"release": "fixture", "snapshot": "fixture"},
            "versions": [{"id": "fixture", "type": "release", "url": self.base + "/version.json", "time": "2026-01-01T00:00:00Z", "releaseTime": "2026-01-01T00:00:00Z", "sha1": sha(data["/version.json"]), "size": len(data["/version.json"])}],
        })
        with self.lock:
            self.responses = data

    def counts(self):
        with self.lock:
            return self.bodies.copy()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with self.server.lock:
            data = self.server.responses.get(self.path)
        if data is None:
            self.send_error(404)
            return
        etag = '"' + sha(data) + '"'
        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.end_headers()
            return
        with self.server.lock:
            self.server.bodies[self.path] += 1
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("ETag", etag)
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


def checked(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--binary", type=Path, default=REPO / "zig-out/bin/vela-mc")
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not args.skip_build:
        subprocess.run(["direnv", "exec", ".", "zig", "build", "mc-cli"], cwd=REPO, check=True)
    if not binary.is_file():
        parser.error("CLI executable does not exist: " + str(binary))
    server = Fixture()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="vela minecraft fixture ", dir=REPO / ".zig-cache") as tmp:
            base = Path(tmp)
            root = base / "game root with spaces"
            environment = dict(os.environ)
            # Never route this local fixture through an inherited HTTP proxy.
            for key in list(environment):
                if key.lower() in ("http_proxy", "https_proxy", "all_proxy"):
                    environment.pop(key)
            environment["NO_PROXY"] = "127.0.0.1,localhost"
            environment["no_proxy"] = environment["NO_PROXY"]

            def run(command, directory=root, extra=(), success=True):
                cmd = [str(binary), command, "fixture", "--root", str(directory), "--manifest-url", server.base + "/version_manifest_v2.json", *extra]
                result = subprocess.run(cmd, cwd=REPO, env=environment, text=True, capture_output=True, timeout=120)
                if (result.returncode == 0) != success:
                    raise AssertionError("unexpected CLI result: " + repr(cmd) + "\nexit=" + str(result.returncode) + "\n" + result.stdout + result.stderr)
                return result

            run("install")
            expected = {
                "versions/fixture/fixture.jar": "/client.jar",
                "libraries/test/library/1/library-1.jar": "/library.jar",
                "libraries/test/native/1/native-1-linux.jar": "/native.zip",
                "assets/indexes/fixture-assets.json": "/index.json",
                "assets/log_configs/fixture-log.xml": "/logging.xml",
                "versions/fixture/fixture.json": "/version.json",
            }
            for target, endpoint in expected.items():
                checked((root / target).read_bytes() == server.responses[endpoint], "wrong installed bytes: " + target)
            natives = root / "versions/fixture/natives"
            checked((natives / "native.bin").read_bytes() == b"native fixture\n", "native extraction missing")
            checked(not (natives / "META-INF/MANIFEST.MF").exists(), "native exclude ignored")
            print("PASS install: original metadata/files/native extraction and exclusions", flush=True)

            before = server.counts()
            run("install")
            after = server.counts()
            for path in ("/client.jar", "/library.jar", "/native.zip", "/logging.xml"):
                checked(after[path] == before[path], "valid installed file downloaded again: " + path)
            print("PASS reuse: installed file bodies not downloaded again", flush=True)

            (root / "versions/fixture/fixture.jar").write_bytes(b"corrupt")
            before = server.counts()
            run("install")
            checked((root / "versions/fixture/fixture.jar").read_bytes() == server.responses["/client.jar"], "corrupt client was not repaired")
            checked(server.counts()["/client.jar"] == before["/client.jar"], "repair retransferred a cached client body")
            (root / "versions/fixture/fixture.jar").unlink()
            run("install")
            checked((root / "versions/fixture/fixture.jar").read_bytes() == server.responses["/client.jar"], "deleted client was not restored")
            checked(server.counts()["/client.jar"] == before["/client.jar"], "deleted client retransferred")
            cache_file = root / ".vela/cache/artifacts/sha1" / hashlib.sha1(server.responses["/client.jar"]).hexdigest()
            cache_file.write_bytes(b"corrupt-cache")
            (root / "versions/fixture/fixture.jar").unlink()
            run("install")
            checked(server.counts()["/client.jar"] == before["/client.jar"] + 1, "corrupt cache did not refetch client")
            checked(cache_file.read_bytes() == server.responses["/client.jar"], "corrupt cache was not repaired")
            print("PASS artifact cache: repair, deletion, corruption recovery", flush=True)

            capture = base / "java invocation.json"
            fake_java = base / "fake java.py"
            fake_java.write_text("#!" + sys.executable + "\nimport json, os, sys\nif sys.argv[1:] in (['-version'], ['--version']):\n    print('openjdk version \"21.0.11\"', file=sys.stderr)\n    sys.exit(0)\nwith open(" + repr(str(capture)) + ", 'w') as f:\n    json.dump({'argv': sys.argv[1:], 'cwd': os.getcwd()}, f)\n", encoding="utf-8")
            fake_java.chmod(0o755)
            run("launch", extra=("--java", str(fake_java), "--username", "TestPlayer"))
            recorded = json.loads(capture.read_text())
            argv = recorded["argv"]
            checked(Path(recorded["cwd"]) == root, "Java working directory is not instance root")
            checked(argv.count("fixture.Main") == 1, "main class missing or duplicated")
            boundary = argv.index("fixture.Main")
            cp = argv.index("-cp")
            checked(cp + 1 < boundary, "classpath crossed main-class boundary")
            checked(argv[cp + 1].split(os.pathsep) == [str(root / "libraries/test/library/1/library-1.jar"), str(root / "versions/fixture/fixture.jar")], "classpath ordering or space handling incorrect")
            checked("-Djava.library.path=" + str(natives) in argv[:boundary], "native path missing")
            checked("-Dlog4j.configurationFile=" + str(root / "assets/log_configs/fixture-log.xml") in argv[:boundary], "logging configuration path missing")
            checked(argv.index("--username") > boundary, "game arguments crossed main-class boundary")
            checked(argv[argv.index("--username") + 1] == "TestPlayer", "player name substitution failed")
            checked(argv[argv.index("--gameDir") + 1] == str(root), "game directory substitution failed")
            checked(not any("$" + "{" in token for token in argv), "unexpanded placeholder in launch argv")
            print("PASS launch: fake Java receives separated argv and correct cwd", flush=True)

            server.configure(bad_hash=True)
            bad_root = base / "bad hash root"
            run("install", bad_root, success=False)
            checked(not (bad_root / "versions/fixture/fixture.jar").exists(), "checksum mismatch published invalid client")
            print("PASS checksum: corrupt download rejected before publication", flush=True)

            server.configure(malicious=True)
            malicious_root = base / "malicious archive root"
            run("install", malicious_root, success=False)
            checked(not (base / "escaped.txt").exists(), "archive path traversal escaped installation root")
            print("PASS archive: traversal entry rejected", flush=True)
            print("All 6 Minecraft integration scenarios passed.", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    main()
