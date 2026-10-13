#!/usr/bin/env python3
"""Run transport integration tests against an ephemeral loopback-only fixture."""
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Fixture(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.denied_hits = 0
        self.lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, status, body=b"", headers=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path == "/get":
            self.reply(200, b'{"ok":true}')
        elif self.path == "/empty":
            self.reply(204)
        elif self.path == "/auth":
            self.reply(200 if self.headers.get("Authorization") == "Bearer fixture-secret" else 401, b"auth-result")
        elif self.path == "/redirect":
            self.reply(302, b"discard redirect body", {"Location": "/get"})
        elif self.path == "/secret-redirect":
            self.reply(302, b"not followed", {"Location": "/must-not-request"})
        elif self.path == "/must-not-request":
            with self.server.lock:
                self.server.denied_hits += 1
            self.reply(500, b"unexpected request")
        elif self.path == "/stats":
            with self.server.lock:
                hits = self.server.denied_hits
            self.reply(200, str(hits).encode("ascii"))
        elif self.path == "/external-redirect":
            self.reply(302, b"", {"Location": "http://203.0.113.1:1/never-contact"})
        elif self.path == "/userinfo-redirect":
            self.reply(302, b"", {"Location": "http://fixture:secret@127.0.0.1:1/never-contact"})
        elif self.path == "/loop":
            self.reply(302, b"", {"Location": "/loop"})
        elif self.path == "/error":
            self.reply(429, b'{"error":"fixture-limit"}')
        elif self.path in ("/binary-large", "/binary-large-stream"):
            length = 65 * 1024 * 1024
            self.send_response(200)
            if self.path == "/binary-large":
                self.send_header("Content-Length", str(length))
            else:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            self.close_connection = True
            block = b"b" * (1024 * 1024)
            try:
                for _ in range(65):
                    self.wfile.write(block)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif self.path == "/large":
            self.reply(200, b"x" * 8192)
        elif self.path == "/slow":
            time.sleep(1.5)
            self.reply(200, b"late")
        elif self.path == "/truncated":
            self.send_response(200)
            self.send_header("Content-Length", "100")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"short")
            self.close_connection = True
        else:
            self.reply(404, b"unknown fixture route")

    def do_CONNECT(self):
        # Reject tunnels locally: loader tests can exercise production HTTPS
        # request dispatch for official hosts without contacting those hosts.
        self.reply(502, b"fixture tunnel rejected")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if self.path == "/post":
            self.reply(201, body)
        elif self.path == "/secret-redirect":
            self.reply(307, b"not followed", {"Location": "/must-not-request"})
        else:
            self.reply(404)


def main():
    root = Path(__file__).resolve().parent.parent
    server = Fixture()
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    env = os.environ.copy()
    env["HTTP_TRANSPORT_TEST_URL"] = "http://127.0.0.1:" + str(server.server_port)
    # Verify the transport overrides ambient proxy configuration itself.
    env["HTTP_PROXY"] = env["http_proxy"] = "http://127.0.0.1:1"
    env["ALL_PROXY"] = env["all_proxy"] = "http://127.0.0.1:1"
    env["NO_PROXY"] = env["no_proxy"] = ""
    args = sys.argv[1:]
    targets = ["test-http-transport"]
    if "--loader" in args:
        args.remove("--loader")
        targets.append("test-minecraft")
    command = ["zig", "build", *targets, *args]
    print("Local HTTP transport fixture: " + env["HTTP_TRANSPORT_TEST_URL"], flush=True)
    try:
        return subprocess.call(command, cwd=root, env=env)
    except KeyboardInterrupt:
        return 130
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


if __name__ == "__main__":
    sys.exit(main())
