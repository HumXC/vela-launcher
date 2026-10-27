#!/usr/bin/env python3
"""Run Zig downloader tests against an isolated loopback HTTP fixture.

Usage: python3 scripts/test-downloader.py [zig build options...]
       python3 scripts/test-downloader.py --test-exe PATH
The second form runs an already compiled default Zig test executable.
Requires Python 3; only the first form requires the project Zig toolchain.
"""

import argparse
import collections
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import urllib.parse


BODY = b"hello minecraft\n"
JSON_BODY = b'{"name":"minecraft","version":1}'
ETAG = '"fixture-v1"'
MODIFIED = "Wed, 21 Oct 2015 07:28:00 GMT"


class Fixture(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.counts = collections.Counter()
        self.count_lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, status, body=b"", headers=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        # Absolute URLs also let the fixture act as a minimal HTTP forward proxy.
        path = urllib.parse.urlsplit(self.path).path
        with self.server.count_lock:
            self.server.counts[path] += 1
            if self.headers.get("If-None-Match") or self.headers.get("If-Modified-Since"):
                self.server.counts[path + ":conditional"] += 1
        try:
            self.serve(path)
        except (BrokenPipeError, ConnectionResetError):
            # Cancellation intentionally closes active transfers.
            pass

    def serve(self, path):
        if path == "/stats":
            with self.server.count_lock:
                body = json.dumps(dict(self.server.counts)).encode()
            self.reply(200, body, {"Content-Type": "application/json"})
        elif path in ("/bytes", "/instance-client/jar"):
            self.reply(200, BODY)
        elif path == "/instance-client/index":
            self.reply(200, b'{"objects":{}}', {"Content-Type": "application/json"})
        elif path == "/json":
            self.reply(200, JSON_BODY, {"Content-Type": "application/json"})
        elif path == "/invalid-json":
            self.reply(200, b'{"name":')
        elif path == "/large":
            self.reply(200, b"x" * (1024 * 1024))
        elif path == "/slow":
            self.send_response(200)
            self.send_header("Content-Length", str(256 * 1024))
            self.send_header("Connection", "close")
            self.end_headers()
            for _ in range(16):
                self.wfile.write(b"x" * (16 * 1024))
                self.wfile.flush()
                time.sleep(0.05)
            self.close_connection = True
        elif path == "/stalled":
            self.send_response(200)
            self.send_header("Content-Length", "1")
            self.send_header("Connection", "close")
            self.end_headers()
            time.sleep(4)
            self.wfile.write(b"x")
            self.close_connection = True
        elif path == "/etag":
            if self.headers.get("If-None-Match") == ETAG:
                self.reply(304, headers={"ETag": ETAG})
            else:
                self.reply(200, JSON_BODY, {"ETag": ETAG})
        elif path == "/modified":
            if self.headers.get("If-Modified-Since") == MODIFIED:
                self.reply(304, headers={"Last-Modified": MODIFIED})
            else:
                self.reply(200, JSON_BODY, {"Last-Modified": MODIFIED})
        elif path == "/redirect":
            self.reply(302, b"intermediate response must not enter output", {"Location": "/bytes", "ETag": '"redirect-only"'})
        elif path == "/no-store":
            self.reply(200, JSON_BODY, {"ETag": ETAG, "Cache-Control": "no-store"})
        elif path == "/vary":
            self.reply(200, JSON_BODY, {"ETag": ETAG, "Vary": "Accept-Language"})
        elif path == "/unknown-length":
            self.send_response(200)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(BODY)
            self.close_connection = True
        elif path == "/truncated":
            self.send_response(200)
            self.send_header("Content-Length", "1000")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(BODY)
            self.close_connection = True
        elif path == "/unexpected-304":
            self.reply(304)
        else:
            self.reply(404, b"not found")


def test_command(args=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--test-exe", metavar="PATH", help="run a compiled default Zig test executable without building")
    options, build_args = parser.parse_known_args(args)
    if options.test_exe is not None:
        if build_args:
            parser.error("--test-exe cannot be combined with zig build options")
        # Preserve symlink names and resolve cwd without adding --listen.
        return [os.path.abspath(options.test_exe)]
    return ["zig", "build", "test-downloader", *build_args]


def main(args=None):
    command = test_command(args)
    root = Path(__file__).resolve().parent.parent
    server = Fixture()
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    env = os.environ.copy()
    env["DOWNLOADER_TEST_URL"] = "http://127.0.0.1:" + str(server.server_port)
    # Keep local tests independent from the developer's network proxy settings.
    env["NO_PROXY"] = env["no_proxy"] = "127.0.0.1,localhost"
    print("Local downloader fixture: " + env["DOWNLOADER_TEST_URL"], flush=True)
    try:
        status = subprocess.call(command, cwd=root, env=env)
        return status if status >= 0 else 128 - status
    except KeyboardInterrupt:
        return 130
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


if __name__ == "__main__":
    sys.exit(main())
