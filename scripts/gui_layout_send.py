#!/usr/bin/env python3
"""Deliver one bounded command to a fresh pinned acceptance owner frame.

Usage: python gui_layout_send.py <freeze.json> <root> <owner.json> '<JSON>'
This sender never discovers a desktop or selects a fallback socket. The
verified acceptance module is loaded from exact hashed bytes without pycache
writes. Successful FIFO delivery is not native input or visual acceptance.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import sys
import types


def fail(message):
    raise RuntimeError(message)


def unique_pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            fail("Duplicate JSON key")
        result[key] = value
    return result


def no_constant(value):
    fail("Nonfinite JSON constant: " + value)


def finite_float(value):
    result = float(value)
    if not math.isfinite(result):
        fail("Nonfinite JSON float: " + value)
    return result


def bootstrap_read(path, limit, *, with_identity=False):
    if not os.path.isabs(path) or os.path.normpath(path) != path or os.path.realpath(path) != path:
        fail("Bootstrap path must be canonical without symlinks")
    before = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
        fail("Bootstrap file type/size rejected")
    def signature(s):
        return (s.st_dev, s.st_ino, s.st_uid, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        if signature(before) != signature(os.fstat(fd)):
            fail("Bootstrap open raced")
        parts, total = [], 0
        while True:
            part = os.read(fd, min(65536, limit + 1 - total))
            if not part:
                break
            parts.append(part)
            total += len(part)
            if total > limit:
                fail("Bootstrap file exceeded bound")
        if signature(before) != signature(os.fstat(fd)) or signature(before) != signature(
                os.stat(path, follow_symlinks=False)):
            fail("Bootstrap file changed/replaced")
        data = b"".join(parts)
        return (data, signature(before)) if with_identity else data
    finally:
        os.close(fd)


def main():
    if len(sys.argv) != 5:
        fail("Usage: gui_layout_send.py <freeze.json> <root> <owner.json> '<JSON>'")
    manifest_path, root, owner_path, command_text = sys.argv[1:]
    if len(command_text.encode("utf-8")) >= 4096:
        fail("Command exceeds bound")
    sys.dont_write_bytecode = True
    script = str(Path(__file__).absolute())
    library_path = str(Path(script).parent / "gui_layout_acceptance.py")
    raw_manifest, bootstrap_signature = bootstrap_read(
        manifest_path, 1024 * 1024, with_identity=True)
    bootstrap_raw_hash = hashlib.sha256(raw_manifest).hexdigest()
    initial = json.loads(raw_manifest, object_pairs_hook=unique_pairs,
                         parse_constant=no_constant, parse_float=finite_float)
    if not isinstance(initial, dict) or not isinstance(initial.get("sources"), list) or not (
            2 <= len(initial["sources"]) <= 256):
        fail("Invalid bootstrap manifest")
    expected = {}
    for item in initial["sources"]:
        if not isinstance(item, dict) or set(item) != {"path", "sha256"}:
            fail("Invalid source consumer entry")
        if not isinstance(item["path"], str) or item["path"] in expected:
            fail("Invalid/duplicate source path")
        expected[item["path"]] = item["sha256"]
    for path in (script, library_path):
        if path not in expected:
            fail("Both source consumers must be frozen")
    library_bytes = bootstrap_read(library_path, 2 * 1024 * 1024)
    self_bytes = bootstrap_read(script, 2 * 1024 * 1024)
    if hashlib.sha256(library_bytes).hexdigest() != expected[library_path] or hashlib.sha256(
            self_bytes).hexdigest() != expected[script]:
        fail("Source consumer hash drift")
    # Compile only the checked bytes; no import-path search and no pycache write.
    module = types.ModuleType("gui_layout_acceptance_checked")
    module.__file__ = library_path
    exec(compile(library_bytes, library_path, "exec"), module.__dict__)
    h = module
    freeze = h.Freeze(manifest_path, script)
    try:
        h.require(freeze.raw_hash == bootstrap_raw_hash and freeze.identity == {
            "dev": bootstrap_signature[0], "ino": bootstrap_signature[1],
            "uid": bootstrap_signature[2], "mode": stat.S_IMODE(bootstrap_signature[3]),
            "type": stat.S_IFMT(bootstrap_signature[3])},
            "Bootstrap/Freeze manifest snapshot mismatch")
        current_manifest = os.stat(manifest_path, follow_symlinks=False)
        h.require((current_manifest.st_dev, current_manifest.st_ino, current_manifest.st_uid,
                   current_manifest.st_mode, current_manifest.st_size,
                   current_manifest.st_mtime_ns, current_manifest.st_ctime_ns) == bootstrap_signature,
                  "Bootstrap manifest signature drift")
        tree = h.Tree(root)
        frame_fd = fifo_fd = None
        socket_fds = {}
        try:
            frame, frame_pin, frame_fd, directory, name = h.rooted_frame(tree, owner_path)
            roles = h.validate_frame(frame, tree, freeze, owner=True)
            h.require(frame.get("owner_node") == frame_pin, "Owner frame inode mismatch")
            frame_hash = hashlib.sha256(h.read_fd(frame_fd, h.MAX_FRAME)).hexdigest()
            runtime = frame.get("runtime_relative")
            artifacts = frame.get("artifact_relative")
            h.require(isinstance(runtime, str) and isinstance(artifacts, str) and
                      runtime in tree.pins and artifacts == directory and
                      runtime.startswith("runtime/session-") and
                      frame.get("fifo_relative") == runtime + "/commands.fifo",
                      "Runtime/FIFO/frame path mismatch")
            nodes = frame.get("nodes")
            h.require(isinstance(nodes, dict) and
                      {"commands.fifo", "rfb.sock", "control.sock"} <= set(nodes) and
                      len(nodes) == 4, "Incomplete socket/FIFO identity frame")
            wayland = [n for n in nodes if n.startswith("wayland-")]
            h.require(len(wayland) == 1 and h.re.fullmatch(r"wayland-[0-9]+", wayland[0]),
                      "Invalid Wayland identity")
            for node_name in ("rfb.sock", "control.sock", wayland[0]):
                expected_mode = 0o700 if node_name == wayland[0] else 0o600
                socket_fds[node_name] = h.checked_open(
                    node_name, os.O_PATH, dir_fd=tree.fds[runtime],
                    expected=nodes[node_name], mode=expected_mode, kind=stat.S_ISSOCK)
            command = h.decode_json(command_text)
            h.require(isinstance(command, dict), "Command must be an object")
            op = command.get("op")
            fields = {"move": {"x", "y"}, "drag": {"x", "y"}, "click": {"button"}, "key": {"key"},
                      "text": {"text"}, "capture": set(), "stop": set(),
                      "native-quit": {"stage"}}
            h.require(isinstance(op, str) and op in fields and
                      set(command) <= {"op", "label", "pause"} | fields[op],
                      "Unknown operation/command field")
            h.require(isinstance(command.get("label"), str) and
                      h.re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", command["label"]),
                      "Invalid artifact label")
            pause = command.get("pause", 0.35)
            h.require(type(pause) in (int, float) and 0.35 <= pause <= 2, "Invalid pause")
            if op == "native-quit":
                h.require(frame.get("native_quit_allowed") is True and
                          command.get("stage") == "ordinary-deinit",
                          "Native quit requires explicit ordinary-deinit stage")
            elif op in ("move", "drag"):
                width, height = map(int, frame["viewport"].split("x"))
                h.require(type(command.get("x")) is int and type(command.get("y")) is int and
                          0 <= command["x"] < width and 0 <= command["y"] < height,
                          "Coordinates outside logical viewport")
            elif op == "key":
                h.require(command.get("key") in ("tab", "esc", "ctrl-a", "backspace"),
                          "Unapproved key; alt-f4 requires native-quit")
            elif op == "click":
                h.require(type(command.get("button", 1)) is int and
                          command.get("button", 1) in (1, 4, 5), "Unapproved button")
            elif op == "text":
                h.require(command.get("text") in ("DraftAlpha42", "WorldDraftAlpha42"),
                          "Unapproved public draft")
            payload = h.normalized(command) + b"\n"
            h.require(len(payload) <= h.MAX_COMMAND, "Command exceeds atomic bound")

            def guard():
                freeze.check()
                tree.check_file(directory, name, frame_fd, frame_pin)
                h.require(hashlib.sha256(h.read_fd(frame_fd, h.MAX_FRAME)).hexdigest() == frame_hash,
                          "Owner frame content drift")
                for role in ("input", "cage", "gui", "wayvnc"):
                    h.check_identity(roles[role])
                h.check_group(roles["input"], [roles["input"]])
                h.check_group(roles["cage"], [roles["cage"], roles["gui"]])
                h.check_group(roles["wayvnc"], [roles["wayvnc"]])
                h.tcp_owned(list(roles.values()))
                for node_name, pin in nodes.items():
                    current = os.stat(node_name, dir_fd=tree.fds[runtime], follow_symlinks=False)
                    h.require(h.node(current) == pin, "Socket/FIFO identity drift")
                    if node_name in socket_fds:
                        h.require(h.node(os.fstat(socket_fds[node_name])) == pin,
                                  "Socket fstat identity drift")
                if fifo_fd is not None:
                    tree.check_file(runtime, "commands.fifo", fifo_fd, nodes["commands.fifo"])

            guard()
            fifo_fd = tree.open_file(runtime, "commands.fifo", os.O_WRONLY | os.O_NONBLOCK,
                                     expected=nodes["commands.fifo"], kind=stat.S_ISFIFO)
            h.require(len(payload) <= os.fpathconf(fifo_fd, "PC_PIPE_BUF"),
                      "Command exceeds kernel atomic FIFO bound")
            guard()  # Includes checked inode/fstat immediately before delivery.
            h.require(os.write(fifo_fd, payload) == len(payload), "Incomplete FIFO write")
            tree.check_file(runtime, "commands.fifo", fifo_fd, nodes["commands.fifo"])
            tree.check_file(directory, name, frame_fd, frame_pin)
            h.require(hashlib.sha256(h.read_fd(frame_fd, h.MAX_FRAME)).hexdigest() == frame_hash,
                      "Owner frame changed after delivery")
            freeze.check()
            # Native close may already have removed GUI/Cage/VNC after delivery.
            # No post-delivery liveness assertion disguises that expected transition.
            print(json.dumps({"delivered": command["label"], "op": op,
                              "initial_panel": frame["initial_panel"],
                              "fixture_lifecycle_evidence_limit":
                                  frame["fixture_lifecycle_evidence_limit"],
                              "qualification": "FIFO delivery only; await native evidence"},
                             allow_nan=False), flush=True)
        finally:
            if fifo_fd is not None:
                os.close(fifo_fd)
            if frame_fd is not None:
                os.close(frame_fd)
            for fd in socket_fds.values():
                os.close(fd)
            tree.close()

    finally:
        # Snapshot checks, owner/FIFO checks and final guard precede pin release.
        freeze.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"failure": str(error)}, allow_nan=False), file=sys.stderr, flush=True)
        raise SystemExit(1)
