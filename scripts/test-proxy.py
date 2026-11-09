#!/usr/bin/env python3
"""Exercise real HTTPS through local HTTP CONNECT and SOCKS5 proxies.

All sockets bind loopback; proxy destinations are restricted to this fixture.
The checked-in TLS key is public test data, never a production credential.
"""
import argparse
import base64
import os
from pathlib import Path
import select
import socket
import socketserver
import ssl
import struct
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def relay(left, right):
    with right:
        while True:
            ready, _, _ = select.select([left, right], [], [], 5)
            if not ready:
                return
            for source in ready:
                data = source.recv(65536)
                if not data:
                    return
                (right if source is left else left).sendall(data)


class Origin(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.headers.get("Proxy-Authorization"):
            self.server.leaked = True
        redirect = self.path == "/redirect"
        body = b"discard" if redirect else b"verified HTTPS proxy fixture"
        self.send_response(302 if redirect else 200)
        if redirect:
            self.send_header("Location", f"https://127.0.0.1:{self.server.server_port}/ok")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Connect(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_CONNECT(self):
        expected = "Basic " + base64.b64encode(b"fixture-user:fixture-password").decode()
        if self.headers.get("Proxy-Authorization") != expected:
            self.server.challenges += 1
            self.send_response(407)
            self.send_header("Proxy-Authenticate", 'Basic realm="fixture"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        host, port = self.path.rsplit(":", 1)
        if host not in ("proxy-fixture.test", "localhost", "127.0.0.1", "wrong.test") or int(port) != self.server.origin_port:
            self.send_error(403)
            return
        self.server.hits += 1
        upstream = socket.create_connection(("127.0.0.1", self.server.origin_port), timeout=5)
        self.send_response(200, "Connection Established")
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        try:
            relay(self.connection, upstream)
        except (OSError, ssl.SSLError):
            upstream.close()


class Socks(socketserver.StreamRequestHandler):
    def exact(self, count):
        value = self.rfile.read(count)
        if len(value) != count:
            raise EOFError()
        return value

    def handle(self):
        self.connection.settimeout(5)
        try:
            version, count = self.exact(2)
            methods = self.exact(count)
            if version != 5 or 2 not in methods:
                self.connection.sendall(b"\x05\xff")
                return
            self.connection.sendall(b"\x05\x02")
            version, count = self.exact(2)
            user = self.exact(count)
            password = self.exact(self.exact(1)[0])
            if version != 1 or user != b"fixture-user" or password != b"fixture-password":
                self.connection.sendall(b"\x01\x01")
                return
            self.connection.sendall(b"\x01\x00")
            version, command, _, kind = self.exact(4)
            if kind == 3:
                host = self.exact(self.exact(1)[0]).decode("ascii")
                self.server.remote_dns += 1
            elif kind == 1:
                host = socket.inet_ntoa(self.exact(4))
            else:
                return
            port = struct.unpack("!H", self.exact(2))[0]
            if version != 5 or command != 1 or host not in ("proxy-fixture.test", "127.0.0.1") or port != self.server.origin_port:
                return
            upstream = socket.create_connection(("127.0.0.1", port), timeout=5)
            self.server.hits += 1
            self.connection.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
            relay(self.connection, upstream)
        except (OSError, EOFError):
            pass


class ProxyServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test-exe", required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    cert = root / "scripts/fixtures/proxy-cert.pem"
    origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    origin.leaked = False
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, root / "scripts/fixtures/proxy-key.pem")
    origin.socket = tls.wrap_socket(origin.socket, server_side=True)
    connect = ThreadingHTTPServer(("127.0.0.1", 0), Connect)
    secure_connect = ThreadingHTTPServer(("127.0.0.1", 0), Connect)
    secure_connect.socket = tls.wrap_socket(secure_connect.socket, server_side=True)
    socks = ProxyServer(("127.0.0.1", 0), Socks)
    for server in (connect, secure_connect, socks):
        server.origin_port = origin.server_port
        server.hits = server.challenges = server.remote_dns = 0
    servers = (origin, connect, secure_connect, socks)
    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
    for worker in threads:
        worker.start()
    env = os.environ.copy()
    env.update(VELA_PROXY_ORIGIN_PORT=str(origin.server_port), VELA_PROXY_HTTP_PORT=str(connect.server_port),
               VELA_PROXY_HTTPS_PORT=str(secure_connect.server_port), VELA_PROXY_SOCKS_PORT=str(socks.server_address[1]), VELA_PROXY_CA=str(cert))
    # Ambient values must never influence explicit direct/manual routing.
    env.update(http_proxy="http://127.0.0.1:1", https_proxy="http://127.0.0.1:1", ALL_PROXY="http://127.0.0.1:1", NO_PROXY="*")
    try:
        result = subprocess.call([os.path.abspath(options.test_exe)], cwd=root, env=env)
        assert not origin.leaked, "Proxy credentials reached origin"
        assert connect.hits >= 2 and connect.challenges >= 1, "HTTP authentication tunnel untested"
        assert secure_connect.hits >= 2, "HTTPS proxy TLS tunnel untested"
        assert socks.hits >= 2 and socks.remote_dns >= 2, "SOCKS5 authentication/remote DNS untested"
        print("Proxy fixture: authenticated CONNECT and SOCKS5 remote DNS verified; no origin credential leak", flush=True)
        return result
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
        for worker in threads:
            worker.join()


if __name__ == "__main__":
    raise SystemExit(main())
