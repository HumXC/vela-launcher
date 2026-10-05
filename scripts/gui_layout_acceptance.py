#!/usr/bin/env python3
"""Unexecuted bounded layout harness; launch only after a separate runtime GO.

Manifest schema: executable={path,sha256}, sources=[{path,sha256}],
tools={cage,wayvnc,vncdotool,grim} (absolute approved paths), path (minimal
PATH), library_path (the exact approved ordered eight Nix lib directories),
allowed_log_regexes (reviewed full-line allowances). Both scripts
must be in sources. Root is an existing, empty, owned mktemp directory
/tmp/vela-gui-current.<suffix>. Only 1280x720 and 640x400 are supported.

Native close: --allow-native-quit enables the explicit native-quit operation
with stage=ordinary-deinit. stop uses forced closure, never JOIN evidence.
Resume requires --resume <prior closure> --previous-job-collected, plus an
independent absence check here. A new runtime subdirectory avoids deleting
or reusing old socket/FIFO identities. The parent must collect this helper
and prove its own final absence before deleting the six private homes.
"""
import argparse
import hashlib
import json
import logging
import math
import os
from pathlib import Path
import re
import runpy
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import threading
import time

APPROVED_GRIM = "/nix/store/x1zb4lfyibpvjzbmij7zn91rvv2fwify-grim-1.5.0/bin/grim"
# Exact ordered parent-approved direnv paths; no ambient discovery/substitution.
APPROVED_LIBRARY_DIRS = (
    "/nix/store/gvgz0nm1mwj50k0xd2pr78bx9m5mjxvj-alsa-lib-1.2.16.1/lib",
    "/nix/store/c7z4kv21nh2y5mvfyhj1ixkgxwc420z4-libdecor-0.2.5/lib",
    "/nix/store/6lxb0vhv7gxpdcdirbfmm75vi4idjjhq-libusb-1.0.30/lib",
    "/nix/store/yk95z4hjlzdk418px0fc797qszccfj5p-libxkbcommon-1.13.2/lib",
    "/nix/store/lk4614327cn1h9z3m6cvnls95n13m1cj-vulkan-loader-1.4.357.0/lib",
    "/nix/store/vjcwhp0milwa1jqy1inpjxrsh8hjrgwc-wayland-1.26.0/lib",
    "/nix/store/4hlgp6r4j5p6b2b9sxw01cba0x3fjxd6-systemd-minimal-libs-261.2/lib",
    "/nix/store/rarvfpm927fcbd6b9p0crg09w9r3ywb3-libglvnd-1.7.0/lib",
)
INITIAL_PANELS = ("home", "shutdown")
FIXTURE_SCENES = ("layout", "pack", "pack-prepared")
PACK_ARCHIVES = ("modrinth", "curseforge")
PACK_HOLDS = ("none", "inspection", "content", "installer")
PACK_SCENARIOS = ("default", "cf-restricted", "cf-manual", "update-keep",
                  "update-replace", "protected-reject")
FIXTURE_LIFECYCLE_LIMIT = (
    "Seeded fixture Registry cancellation and dialog rendering only; does not prove "
    "production close/hide/game or per-real-worker JOIN.")
MAX_JSON = 1024 * 1024
MAX_FRAME = 128 * 1024
MAX_COMMAND = 4096
MAX_FILE = 512 * 1024 * 1024
HOME_NAMES = ("runtime", "data", "config", "cache", "state", "fixture")
DIRECTORY_NAMES = (*HOME_NAMES, "artifacts")
BAD_LOG = re.compile(r"\b(error|panic|fatal|duplicate|assertion)\b|"
                     r"warn(?:ing)?.*dvui|dvui.*warn(?:ing)?", re.I)
NOFOLLOW = os.O_NOFOLLOW | os.O_CLOEXEC


class Drift(RuntimeError):
    """Unknown identities/races fail closed; private evidence is retained."""


def require(condition, message):
    if not condition:
        raise Drift(message)


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "Duplicate JSON key")
        result[key] = value
    return result


def reject_constant(value):
    raise Drift("Nonfinite JSON number: " + value)


def finite_float(value):
    result = float(value)
    require(math.isfinite(result), "Nonfinite JSON float: " + value)
    return result


def decode_json(data):
    return json.loads(data, object_pairs_hook=pairs, parse_constant=reject_constant,
                      parse_float=finite_float)


def canonical(path):
    require(isinstance(path, str) and os.path.isabs(path), "Path must be absolute")
    require(os.path.normpath(path) == path and os.path.realpath(path) == path,
            "Path must be canonical without symlinks")
    return path


def node(s):
    return {"dev": s.st_dev, "ino": s.st_ino, "uid": s.st_uid,
            "mode": stat.S_IMODE(s.st_mode), "type": stat.S_IFMT(s.st_mode)}


def signature(s):
    return (node(s), s.st_size, s.st_mtime_ns, s.st_ctime_ns)


def checked_open(path, flags, *, dir_fd=None, expected=None, mode=None, kind=None):
    before = os.stat(path, dir_fd=dir_fd, follow_symlinks=False)
    require(not stat.S_ISLNK(before.st_mode), "Refusing symlink")
    if expected is not None:
        require(node(before) == expected, "Path identity drift")
    if mode is not None:
        require(before.st_uid == os.getuid() and stat.S_IMODE(before.st_mode) == mode,
                "Ownership/mode drift")
    if kind is not None:
        require(kind(before.st_mode), "Node type drift")
    fd = os.open(path, flags | NOFOLLOW, dir_fd=dir_fd)
    try:
        require(node(os.fstat(fd)) == node(before), "Open raced with replacement")
        after = os.stat(path, dir_fd=dir_fd, follow_symlinks=False)
        require(node(after) == node(before), "Path replaced during open")
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_fd(fd, limit, *, context="regular file"):
    before = os.fstat(fd)
    require(stat.S_ISREG(before.st_mode) and before.st_size <= limit,
            "Expected bounded regular file")
    parts, total = [], 0
    while True:
        part = os.pread(fd, min(65536, limit + 1 - total), total)
        if not part:
            break
        parts.append(part)
        total += len(part)
        require(total <= limit, "File exceeded bound")
    if signature(os.fstat(fd)) != signature(before):
        try:
            path = os.readlink("/proc/self/fd/" + str(fd))
        except OSError:
            path = "unresolved fd " + str(fd)
        raise Drift(f"File changed during read (role={context!r}, path={path!r})")
    return b"".join(parts)


def read_regular(path, limit=MAX_JSON):
    canonical(path)
    fd = checked_open(path, os.O_RDONLY, kind=stat.S_ISREG)
    try:
        data = read_fd(fd, limit, context="regular path " + path)
        require(node(os.stat(path, follow_symlinks=False)) == node(os.fstat(fd)),
                "File replaced during read")
        return data, node(os.fstat(fd))
    finally:
        os.close(fd)


def file_digest(path):
    canonical(path)
    fd = checked_open(path, os.O_RDONLY, kind=stat.S_ISREG)
    try:
        before = os.fstat(fd)
        require(before.st_size <= MAX_FILE, "Frozen file exceeds bound")
        h = hashlib.sha256()
        total = 0
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            total += len(block)
            require(total <= MAX_FILE, "Frozen file grew beyond bound")
            h.update(block)
        require(signature(os.fstat(fd)) == signature(before), "Frozen file changed")
        require(node(os.stat(path, follow_symlinks=False)) == node(before),
                "Frozen file replaced while hashing")
        return h.hexdigest(), total
    finally:
        os.close(fd)


def normalized(value):
    return json.dumps(value, allow_nan=False, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True).encode("ascii")


def library_directory_node(s):
    require(stat.S_ISDIR(s.st_mode) and s.st_uid == 0 and
            not (stat.S_IMODE(s.st_mode) & 0o022),
            "Library directory must be root-owned without group/other writes")
    return node(s)


def pin_library_directory(path):
    canonical(path)
    require(re.fullmatch(
        r"/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._-]+/lib", path),
        "Only canonical immutable Nix store lib directories are allowed")
    before = library_directory_node(os.stat(path, follow_symlinks=False))
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
    try:
        require(library_directory_node(os.fstat(fd)) == before and
                library_directory_node(os.stat(path, follow_symlinks=False)) == before,
                "Library directory changed during open")
        return fd, before
    except BaseException:
        os.close(fd)
        raise


class Freeze:
    def __init__(self, path, script_path):
        self.library_fds = []
        self.library_pins = []
        try:
            self._initialize(path, script_path)
        except BaseException:
            self.close()
            raise

    def _initialize(self, path, script_path):
        self.path = canonical(path)
        raw, self.identity = read_regular(self.path)
        self.raw_hash = hashlib.sha256(raw).hexdigest()
        spec = decode_json(raw)
        require(isinstance(spec, dict) and set(spec) == {
            "executable", "sources", "tools", "path", "library_path", "allowed_log_regexes"},
            "Invalid manifest fields")
        require(isinstance(spec["sources"], list) and 2 <= len(spec["sources"]) <= 256,
                "Invalid frozen source count")
        entries = [spec["executable"], *spec["sources"]]
        for item in entries:
            require(isinstance(item, dict) and set(item) == {"path", "sha256"},
                    "Invalid frozen entry")
            canonical(item["path"])
            require(isinstance(item["sha256"], str) and
                    re.fullmatch(r"[0-9a-f]{64}", item["sha256"]), "Invalid SHA256")
        paths = [item["path"] for item in entries]
        require(len(paths) == len(set(paths)) and self.path not in paths,
                "Duplicate/circular frozen paths")
        folder = str(Path(canonical(script_path)).parent)
        require({folder + "/gui_layout_acceptance.py", folder + "/gui_layout_send.py"}
                <= set(item["path"] for item in spec["sources"]),
                "Both source consumers must be frozen")
        require(Path(spec["executable"]["path"]).name == "vela-gui-fixture",
                "Only the fixture executable is supported")
        require(isinstance(spec["tools"], dict) and set(spec["tools"]) ==
                {"cage", "wayvnc", "vncdotool", "grim"}, "Invalid tool set")
        self.tools = {}
        for name, path in spec["tools"].items():
            require(isinstance(path, str) and os.path.isabs(path), "Invalid tool path")
            resolved = canonical(os.path.realpath(path))
            require(os.access(resolved, os.X_OK), "Tool is not executable")
            self.tools[name] = resolved
        require(self.tools["grim"] == APPROVED_GRIM, "Grim differs from parent pin")
        require(isinstance(spec["path"], str) and 0 < len(spec["path"]) <= 8192,
                "Invalid approved PATH")
        for entry in spec["path"].split(":"):
            require(entry and os.path.isabs(entry), "PATH must contain absolute entries")
        require(isinstance(spec["library_path"], str) and
                0 < len(spec["library_path"]) <= 8192, "Invalid approved library path")
        directories = spec["library_path"].split(":")
        require(len(APPROVED_LIBRARY_DIRS) == 8 and len(directories) == 8 and
                tuple(directories) == APPROVED_LIBRARY_DIRS and
                len(set(directories)) == 8, "Library path differs from the exact approved eight")
        for directory in directories:
            fd, pin = pin_library_directory(directory)
            try:
                self.library_fds.append(fd)
            except BaseException:
                os.close(fd)
                raise
            self.library_pins.append({"path": directory, "node": pin})
        require(isinstance(spec["allowed_log_regexes"], list) and
                len(spec["allowed_log_regexes"]) <= 32, "Invalid log allowances")
        for pattern in spec["allowed_log_regexes"]:
            require(isinstance(pattern, str) and len(pattern) <= 2048,
                    "Invalid log allowance")
        self.allowances = [re.compile(x) for x in spec["allowed_log_regexes"]]
        spec["tools"] = self.tools.copy()
        spec["sources"] = sorted(spec["sources"], key=lambda x: x["path"])
        self.spec = spec
        self.normal_hash = hashlib.sha256(normalized({
            "manifest": spec, "library_directories": self.library_pins})).hexdigest()
        self.entries = [spec["executable"], *spec["sources"]]
        self.check()

    def check(self):
        raw, identity = read_regular(self.path)
        require(identity == self.identity and hashlib.sha256(raw).hexdigest() ==
                self.raw_hash, "Manifest identity/content drift")
        require(len(self.library_fds) == len(self.library_pins) == 8,
                "Library pins are incomplete or already closed")
        for fd, record in zip(self.library_fds, self.library_pins):
            canonical(record["path"])
            require(library_directory_node(os.fstat(fd)) == record["node"] and
                    library_directory_node(os.stat(record["path"], follow_symlinks=False)) ==
                    record["node"], "Library directory identity/mode drift")
        total = 0
        for item in self.entries:
            actual, size = file_digest(item["path"])
            total += size
            require(total <= 1024 * 1024 * 1024, "Frozen closure exceeds size bound")
            require(actual == item["sha256"], "Frozen hash drift: " + item["path"])

    def frame(self):
        return {"path": self.path, "node": self.identity,
                "raw_sha256": self.raw_hash, "normal_sha256": self.normal_hash,
                "library_directories": [{"path": p["path"], "node": dict(p["node"])}
                                        for p in self.library_pins]}

    def close(self):
        errors = []
        while self.library_fds:
            fd = self.library_fds.pop()
            try:
                os.close(fd)
            except OSError as error:
                errors.append(error)
        if errors:
            raise errors[0]


def proc_stat(pid):
    # Membership discovery reads ONLY stat; foreign UID/exe/status is never read.
    with open("/proc/" + str(pid) + "/stat", "rb") as stream:
        raw = stream.read(8193)
    require(len(raw) <= 8192, "Oversized proc stat")
    fields = raw.rsplit(b")", 1)[1].split()
    return {"pid": pid, "pgid": int(fields[2]), "sid": int(fields[3]),
            "start": fields[19].decode("ascii"), "state": fields[0].decode("ascii")}


def identity(pid):
    first = proc_stat(pid)
    base = "/proc/" + str(pid)
    with open(base + "/status", "r", encoding="ascii") as stream:
        text = stream.read(65537)
    require(len(text) <= 65536, "Oversized proc status")
    uid_lines = [line for line in text.splitlines() if line.startswith("Uid:")]
    require(len(uid_lines) == 1, "Missing process UIDs")
    uids = [int(x) for x in uid_lines[0].split()[1:]]
    require(uids == [os.getuid()] * 4 and os.stat(base).st_uid == os.getuid(),
            "Process UID drift")
    target = os.readlink(base + "/exe")
    require(not target.endswith(" (deleted)"), "Executable was deleted/replaced")
    target = canonical(target)
    executable = os.stat(base + "/exe")
    second = proc_stat(pid)
    require({k: first[k] for k in first if k != "state"} ==
            {k: second[k] for k in second if k != "state"}, "Process identity raced")
    return {k: first[k] for k in ("pid", "pgid", "sid", "start")} | {
        "uids": uids, "exe": target, "exe_dev": executable.st_dev,
        "exe_ino": executable.st_ino}


def members(group):
    result = []
    with os.scandir("/proc") as entries:
        for entry in entries:
            if not entry.name.isdecimal():
                continue
            try:
                row = proc_stat(int(entry.name))
            except (FileNotFoundError, ProcessLookupError):
                continue
            if row["pgid"] == group or row["sid"] == group:
                # Only a matching group/session receives the full identity read.
                if row["state"] == "Z":
                    result.append({k: row[k] for k in ("pid", "pgid", "sid", "start")} |
                                  {"zombie": True})
                    continue
                try:
                    result.append(identity(row["pid"]))
                except (FileNotFoundError, ProcessLookupError):
                    latest = wait_for_terminal_stat(row, allow_absent=True)
                    if latest is None:
                        continue
                    result.append({k: latest[k] for k in ("pid", "pgid", "sid", "start")} |
                                  {"zombie": True})
    return result


def wait_for_terminal_stat(expected, allow_absent=False):
    # /proc/PID/exe can disappear before stat reports Z during native exit.
    # Accept only bounded, identity-matched terminal observation, never live drift.
    require(allow_absent, "Owned process exited unexpectedly")
    deadline = time.monotonic() + 0.25
    while True:
        try:
            latest = proc_stat(expected["pid"])
        except (FileNotFoundError, ProcessLookupError):
            return None
        require(all(latest[k] == expected[k] for k in ("pid", "pgid", "sid", "start")),
                "Original PID/start/group/session drift")
        if latest["state"] == "Z":
            return latest
        require(time.monotonic() < deadline, "Live original identity became unreadable")
        time.sleep(0.01)


def check_identity(expected, allow_absent=False):
    try:
        first = proc_stat(expected["pid"])
    except (FileNotFoundError, ProcessLookupError):
        require(allow_absent, "Owned process disappeared")
        return False
    require(all(first[k] == expected[k] for k in ("pid", "pgid", "sid", "start")),
            "Original PID/start/group/session drift")
    if first["state"] == "Z":
        require(allow_absent, "Owned process exited unexpectedly")
        return False
    try:
        actual = identity(expected["pid"])
    except (FileNotFoundError, ProcessLookupError):
        wait_for_terminal_stat(expected, allow_absent=allow_absent)
        return False
    require(actual == expected, "Original process identity drift")
    return True


def check_group(leader, approved, allow_absent=False):
    check_identity(leader, allow_absent=allow_absent)
    for approved_identity in approved:
        check_identity(approved_identity, allow_absent=True)
    current = members(leader["pgid"])
    by_pid = {p["pid"]: p for p in approved}
    live = []
    for row in current:
        require(row["pgid"] == leader["pid"] and row["sid"] == leader["pid"],
                "Group/session drift")
        require(row["pid"] in by_pid, "Unapproved group member")
        if row.get("zombie"):
            require(allow_absent and all(row[k] == by_pid[row["pid"]][k]
                    for k in ("pid", "pgid", "sid", "start")),
                    "Unapproved zombie/start drift or unexpected exit")
        else:
            require(row == by_pid[row["pid"]], "Executable/UID/start drift")
            live.append(row)
    if not allow_absent:
        require({p["pid"] for p in live} == set(by_pid), "Owned group incomplete")
    return live


def root_path(path):
    canonical(path)
    require(Path(path).parent == Path("/tmp") and
            re.fullmatch(r"vela-gui-current\.[A-Za-z0-9_-]{6,80}", Path(path).name),
            "Root must be an existing direct /tmp/vela-gui-current.<suffix> child")
    return path


class Tree:
    def __init__(self, root):
        self.root = root_path(root)
        self.fds = {}
        self.pins = {}
        self.bind(".")

    def bind(self, relative, expected=None):
        require(relative == "." or re.fullmatch(r"[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)*",
                                                relative), "Invalid directory path")
        require(relative == "." or all(x not in (".", "..", "")
                for x in relative.split("/")), "Path escape")
        if relative == ".":
            parent_fd, name = None, self.root
        else:
            parent, name = os.path.split(relative)
            parent_fd = self.fds[parent or "."]
        fd = checked_open(name, os.O_RDONLY | os.O_DIRECTORY, dir_fd=parent_fd,
                          expected=expected, mode=0o700, kind=stat.S_ISDIR)
        self.fds[relative] = fd
        self.pins[relative] = node(os.fstat(fd))
        return fd

    def mkdir(self, relative):
        parent, name = os.path.split(relative)
        os.mkdir(name, 0o700, dir_fd=self.fds[parent or "."])
        return self.bind(relative)

    def check(self):
        for relative, fd in self.fds.items():
            parent, name = os.path.split(relative)
            if relative == ".":
                s = os.stat(self.root, follow_symlinks=False)
            else:
                s = os.stat(name, dir_fd=self.fds[parent or "."], follow_symlinks=False)
            require(node(s) == self.pins[relative] == node(os.fstat(fd)),
                    "Pinned directory replaced/changed")

    def open_file(self, directory, name, flags, *, expected=None, kind=stat.S_ISREG):
        require(re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", name) and name not in (".", ".."),
                "Invalid file name")
        self.check()
        return checked_open(name, flags, dir_fd=self.fds[directory], expected=expected,
                            mode=0o600, kind=kind)

    def create(self, directory, name):
        self.check()
        require(re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", name), "Invalid output name")
        fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600,
                     dir_fd=self.fds[directory])
        require(node(os.fstat(fd))["mode"] == 0o600 and
                os.fstat(fd).st_uid == os.getuid(), "Created file identity invalid")
        return fd

    def check_file(self, directory, name, fd, expected):
        self.check()
        s = os.stat(name, dir_fd=self.fds[directory], follow_symlinks=False)
        require(node(s) == expected == node(os.fstat(fd)), "Pinned file replaced/changed")

    def json_file(self, directory, name, value, owner_frame=False):
        fd = self.create(directory, name)
        pin = node(os.fstat(fd))
        try:
            if owner_frame:
                value["owner_node"] = pin
            data = normalized(value) + b"\n"
            require(len(data) <= MAX_FRAME, "Output frame exceeds bound")
            write_all(fd, data)
            os.fsync(fd)
            self.check_file(directory, name, fd, pin)
            return pin
        finally:
            os.close(fd)

    def close(self):
        for fd in reversed(list(self.fds.values())):
            os.close(fd)


def bounded_call(call, timeout=6):
    done = threading.Event()
    failures = []
    def invoke():
        try:
            call()
        except BaseException as error:
            failures.append(error)
        finally:
            done.set()
    worker = threading.Thread(target=invoke, daemon=True)
    worker.start()
    require(done.wait(timeout), "Input API cleanup exceeded finite bound")
    if failures:
        raise failures[0]


def write_all(fd, data):
    while data:
        count = os.write(fd, data)
        require(count > 0, "Short file write")
        data = data[count:]


def rooted_frame(tree, path):
    canonical(path)
    relative = os.path.relpath(path, tree.root)
    require(re.fullmatch(r"artifacts/run-[0-9]{10,30}/(?:owner|closure)\.json", relative),
            "Frame escaped bounded artifact path")
    directory, name = os.path.split(relative)
    if "artifacts" not in tree.fds:
        tree.bind("artifacts")
    if directory not in tree.fds:
        tree.bind(directory)
    fd = tree.open_file(directory, name, os.O_RDONLY)
    try:
        raw = read_fd(fd, MAX_FRAME, context="retained " + name)
        tree.check_file(directory, name, fd, node(os.fstat(fd)))
        return decode_json(raw), node(os.fstat(fd)), fd, directory, name
    except BaseException:
        os.close(fd)
        raise


def unix_entries(root):
    with open("/proc/net/unix", "r", encoding="utf-8") as stream:
        lines = stream.read(8 * 1024 * 1024 + 1)
    require(len(lines) <= 8 * 1024 * 1024, "Unix socket table exceeds bound")
    return [line for line in lines.splitlines()[1:]
            if len(line.split(maxsplit=7)) == 8 and
            line.split(maxsplit=7)[7].startswith(root + "/")]


def tcp_owned(identities):
    # Read fd links only for the exact pinned own processes, never foreign ones.
    socket_inodes = set()
    for p in identities:
        if not check_identity(p, allow_absent=True):
            continue
        try:
            for entry in os.scandir("/proc/" + str(p["pid"]) + "/fd"):
                try:
                    link = os.readlink(entry.path)
                except FileNotFoundError:
                    continue
                match = re.fullmatch(r"socket:\[([0-9]+)\]", link)
                if match:
                    socket_inodes.add(match[1])
        except FileNotFoundError:
            continue
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        with open(table, "r", encoding="ascii") as stream:
            text = stream.read(8 * 1024 * 1024 + 1)
        require(len(text) <= 8 * 1024 * 1024, "TCP table exceeds bound")
        for line in text.splitlines()[1:]:
            fields = line.split()
            require(len(fields) >= 10, "Malformed TCP table")
            require(fields[9] not in socket_inodes, "Owned process acquired TCP socket")


def validate_fixture_profile(profile):
    base_fields = {"scene", "archive", "hold", "adoption_retry"}
    require(type(profile) is dict and
            set(profile) in (base_fields, base_fields | {"scenario"}),
            "Missing or invalid fixture profile fields")
    scenario = profile.get("scenario", "default")
    require(type(scenario) is str and scenario in PACK_SCENARIOS and
            ("scenario" not in profile or scenario != "default"),
            "Default fixture profile must retain exactly four fields")
    require(type(profile["scene"]) is str and profile["scene"] in FIXTURE_SCENES and
            type(profile["archive"]) is str and profile["archive"] in PACK_ARCHIVES and
            type(profile["hold"]) is str and profile["hold"] in PACK_HOLDS and
            type(profile["adoption_retry"]) is bool, "Invalid fixture profile values")
    require(profile["scene"] != "layout" or
            (profile["archive"] == "modrinth" and profile["hold"] == "none" and
             profile["adoption_retry"] is False), "Layout requires default fixture profile")
    require(profile["scene"] != "pack-prepared" or profile["archive"] == "modrinth",
            "Prepared fixture requires Modrinth archive")
    require(profile["hold"] != "installer" or profile["scene"] == "pack-prepared",
            "Installer hold requires prepared fixture")
    result = {key: profile[key] for key in ("scene", "archive", "hold", "adoption_retry")}
    if scenario != "default":
        require(profile["scene"] == "pack" and profile["hold"] == "none" and
                profile["adoption_retry"] is False,
                "Deep scenarios require pack scene without holds or adoption retry")
        expected_archive = "curseforge" if scenario.startswith("cf-") else "modrinth"
        require(profile["archive"] == expected_archive, "Scenario/archive mismatch")
        result["scenario"] = scenario
    return result


def validate_frame(frame, tree, freeze, owner=False):
    require(isinstance(frame, dict) and frame.get("schema") == 1 and
            frame.get("root") == tree.root and frame.get("freeze") == freeze.frame(),
            "Frame/root/manifest mismatch")
    require(frame.get("initial_panel") in INITIAL_PANELS and
            frame.get("fixture_lifecycle_evidence_limit") == FIXTURE_LIFECYCLE_LIMIT,
            "Invalid initial panel or fixture lifecycle evidence frame")
    validate_fixture_profile(frame.get("fixture_profile"))
    dirs = frame.get("directories")
    require(isinstance(dirs, dict) and {".", *DIRECTORY_NAMES} <= set(dirs),
            "Missing directory identities")
    for relative in sorted(dirs, key=lambda x: (x.count("/"), x)):
        if relative in tree.pins:
            require(tree.pins[relative] == dirs[relative], "Directory identity mismatch")
        else:
            tree.bind(relative, dirs[relative])
    processes = frame.get("identities")
    require(isinstance(processes, list) and len(processes) == 4 and
            {p.get("role") for p in processes} == {"input", "cage", "gui", "wayvnc"},
            "Expected exactly four pinned process roles")
    expected_exes = {"input": os.path.realpath(sys.executable),
                     "cage": freeze.tools["cage"], "gui": freeze.spec["executable"]["path"],
                     "wayvnc": freeze.tools["wayvnc"]}
    for p in processes:
        require(set(p) == {"role", "process"}, "Invalid process record")
        row = p["process"]
        require(set(row) == {"pid", "pgid", "sid", "start", "uids", "exe", "exe_dev", "exe_ino"}
                and row["exe"] == expected_exes[p["role"]]
                and row["uids"] == [os.getuid()] * 4, "Unapproved process frame")
        for key in ("pid", "pgid", "sid", "exe_dev", "exe_ino"):
            require(type(row[key]) is int and row[key] > 0, "Invalid process number")
        require(isinstance(row["start"], str) and row["start"].isdecimal(), "Invalid start")
        if p["role"] != "gui":
            require(row["pid"] == row["pgid"] == row["sid"], "Nonisolated process frame")
    cage = next(p["process"] for p in processes if p["role"] == "cage")
    gui = next(p["process"] for p in processes if p["role"] == "gui")
    require(gui["pgid"] == cage["pid"] == gui["sid"], "GUI outside Cage session")
    require(frame.get("viewport") in ("1280x720", "640x400"), "Invalid viewport frame")
    if owner:
        require(frame.get("state") == "ready", "Input frame is not ready")
    return {p["role"]: p["process"] for p in processes}


class Harness:
    def __init__(self, args):
        self.args = args
        self.freeze = Freeze(args.manifest, __file__)
        try:
            self._initialize(args)
        except BaseException:
            try:
                for name in ("fifo_fd", "owner_fd"):
                    fd = getattr(self, name, None)
                    if fd is not None:
                        os.close(fd)
                for fd in getattr(self, "socket_fds", {}).values():
                    os.close(fd)
                for _, fd, _ in getattr(self, "logs", []):
                    os.close(fd)
                tree = getattr(self, "tree", None)
                if tree is not None:
                    tree.close()
            finally:
                self.freeze.close()
            raise

    def _initialize(self, args):
        self.initial_panel = args.initial_panel
        require(self.initial_panel in INITIAL_PANELS, "Invalid initial fixture panel")
        # Immutable canonical pairs; every evidence frame receives its own dictionary.
        profile = {"scene": args.fixture_scene, "archive": args.pack_archive,
                   "hold": args.pack_hold, "adoption_retry": args.pack_adoption_retry}
        if args.pack_scenario != "default":
            profile["scenario"] = args.pack_scenario
        self.fixture_profile = tuple(validate_fixture_profile(profile).items())
        self.tree = Tree(args.root)
        self.children = []
        self.spawn_serial = 0
        self.roles = {"input": identity(os.getpid())}
        require(os.getpid() == os.getpgrp() == os.getsid(0), "Launch with setsid")
        self.api = self.client = None
        self.fifo_fd = None
        self.nodes = {}
        self.socket_fds = {}
        self.owner_fd = None
        self.owner_hash = None
        self.logs = []
        self.log_prefixes = {}
        self.sequence = 0
        self.input_sequence = 0
        self.pointer = None
        self.last_input = None
        self.outcome = "failure"
        self.native_close = False
        self.disconnect_note = None
        self.deadline = time.monotonic() + args.session_timeout
        self.prepare()

    def prepare(self):
        t = self.tree
        if self.args.resume:
            require(self.args.previous_job_collected,
                    "Resume requires external previous-job collection acknowledgment")
            frame, _, fd, _, _ = rooted_frame(t, self.args.resume)
            try:
                previous = validate_frame(frame, t, self.freeze)
                require(frame["fixture_profile"] == dict(self.fixture_profile),
                        "Resume fixture profile mismatch")
                require(frame.get("child_groups_absent") is True,
                        "Previous child closure incomplete")
                for p in previous.values():
                    check_identity(p, allow_absent=True)
                    require(not members(p["pgid"]), "Previous group/session still exists")
                    try:
                        proc_stat(p["pid"])
                    except (FileNotFoundError, ProcessLookupError):
                        pass
                    else:
                        raise Drift("Previous PID still exists or was reused")
                require(not unix_entries(t.root), "Previous owned Unix socket remains")
            finally:
                os.close(fd)
        else:
            require(not self.args.previous_job_collected, "Collection flag needs resume")
            require(not os.listdir(t.fds["."]), "Initial mktemp root must be empty")
            for name in DIRECTORY_NAMES:
                t.mkdir(name)
        stamp = str(time.time_ns())
        self.art = "artifacts/run-" + stamp
        self.run = "runtime/session-" + stamp
        t.mkdir(self.art)
        t.mkdir(self.run)
        self.runtime = t.root + "/" + self.run
        self.fixture = t.root + "/fixture"
        profile = dict(self.fixture_profile)
        self.env = {
            "PATH": self.freeze.spec["path"], "LANG": "C.UTF-8", "HOME": self.fixture,
            "LD_LIBRARY_PATH": self.freeze.spec["library_path"],
            "XDG_RUNTIME_DIR": self.runtime,
            "XDG_DATA_HOME": t.root + "/data", "XDG_CONFIG_HOME": t.root + "/config",
            "XDG_CACHE_HOME": t.root + "/cache", "XDG_STATE_HOME": t.root + "/state",
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + self.runtime + "/no-session-bus",
            "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=" + self.runtime + "/no-system-bus",
            "AT_SPI_BUS_ADDRESS": "unix:path=" + self.runtime + "/no-atspi-bus",
            "NO_AT_BRIDGE": "1", "GTK_USE_PORTAL": "0", "GIO_USE_VFS": "local",
            "WLR_BACKENDS": "headless", "WLR_RENDERER": "pixman", "WLR_HEADLESS_OUTPUTS": "1",
            "LIBGL_ALWAYS_SOFTWARE": "1", "SDL_VIDEO_DRIVER": "wayland",
            "SDL_RENDER_DRIVER": "opengl", "VELA_DATA_DIR": self.fixture,
            "VELA_FIXTURE_ROOT": self.fixture, "VELA_FIXTURE_PANEL": self.initial_panel,
            "VELA_FIXTURE_SCENE": profile["scene"], "VELA_FIXTURE_VIEWPORT": self.args.viewport,
            "VELA_FIXTURE_PACK_ARCHIVE": profile["archive"],
            "VELA_FIXTURE_PACK_HOLD": profile["hold"],
            "VELA_FIXTURE_PACK_ADOPTION_RETRY": "1" if profile["adoption_retry"] else "0",
        }
        if "scenario" in profile:
            self.env["VELA_FIXTURE_PACK_SCENARIO"] = profile["scenario"]
        os.environ.clear()
        os.environ.update(self.env)
        os.mkfifo("commands.fifo", 0o600, dir_fd=t.fds[self.run])
        s = os.stat("commands.fifo", dir_fd=t.fds[self.run], follow_symlinks=False)
        require(stat.S_ISFIFO(s.st_mode), "Unexpected FIFO")
        self.nodes["commands.fifo"] = node(s)
        self.fifo_fd = t.open_file(self.run, "commands.fifo", os.O_RDWR | os.O_NONBLOCK,
                                   expected=node(s), kind=stat.S_ISFIFO)
        fd = t.create(self.run, "wayvnc.conf")
        self.vnc_config_pin = node(os.fstat(fd))
        os.close(fd)

    def pin_socket(self, name, change_mode=False):
        s = os.stat(name, dir_fd=self.tree.fds[self.run], follow_symlinks=False)
        mode = stat.S_IMODE(s.st_mode)
        require(stat.S_ISSOCK(s.st_mode) and s.st_uid == os.getuid() and
                mode in (0o600, 0o700), "Unexpected owned socket")
        fd = checked_open(name, os.O_PATH, dir_fd=self.tree.fds[self.run],
                          expected=node(s), mode=mode, kind=stat.S_ISSOCK)
        try:
            if change_mode:
                # The proc-fd alias targets the checked inode, even if the name races.
                os.chmod("/proc/self/fd/" + str(fd), 0o600)
            actual = os.stat(name, dir_fd=self.tree.fds[self.run], follow_symlinks=False)
            require(node(actual) == node(os.fstat(fd)), "Socket replaced during pinning")
            require(all(node(actual)[k] == node(s)[k] for k in node(s) if k != "mode")
                    and stat.S_IMODE(actual.st_mode) == (0o600 if change_mode else mode),
                    "Socket identity/mode drift")
            self.nodes[name] = node(actual)
            self.socket_fds[name] = fd
        except BaseException:
            os.close(fd)
            raise

    @staticmethod
    def native_log_prefix(fd, pin, verified):
        # Logs may append, but each snapshot reads exactly the initial size.
        limit = 8 * 1024 * 1024
        verified_size, verified_sha256 = verified

        def bounded_size(minimum):
            s = os.fstat(fd)
            require(stat.S_ISREG(s.st_mode) and node(s) == pin,
                    "Native log descriptor identity/mode drift")
            require(minimum <= s.st_size <= limit, "Native log truncated or exceeded bound")
            return s.st_size

        size = bounded_size(verified_size)

        def prefix():
            parts, total = [], 0
            while total < size:
                part = os.pread(fd, min(65536, size - total), total)
                require(part, "Native log truncated during prefix read")
                parts.append(part)
                total += len(part)
            return b"".join(parts)

        data = prefix()
        observed_size = bounded_size(size)
        repeat = prefix()
        bounded_size(observed_size)
        require(data == repeat, "Native log prefix changed during read")
        require(hashlib.sha256(data[:verified_size]).hexdigest() == verified_sha256,
                "Previously verified native log prefix changed")
        return data

    def log_file(self, name):
        fd = self.tree.create(self.art, name)
        self.logs.append((name, fd, node(os.fstat(fd))))
        self.log_prefixes[name] = (0, hashlib.sha256(b"").hexdigest())
        return fd

    def check_logs(self, final=False):
        failures = []
        for name, fd, pin in self.logs:
            context = f"role={'native log ' + name!r}, path={self.tree.root + '/' + self.art + '/' + name!r}"
            try:
                self.tree.check_file(self.art, name, fd, pin)
                data = self.native_log_prefix(fd, pin, self.log_prefixes[name])
                self.tree.check_file(self.art, name, fd, pin)
                self.log_prefixes[name] = (len(data), hashlib.sha256(data).hexdigest())
                # A live writer may be partway through a line or UTF-8 sequence.
                complete = data if final else data[:data.rfind(b"\n") + 1]
                for line in complete.decode("utf-8", errors="replace").splitlines():
                    require(not BAD_LOG.search(line) or any(r.fullmatch(line) for r in
                            self.freeze.allowances), "Unexpected log: " + line)
            except Exception as error:
                problem = f"{error} ({context})"
                if not final:
                    raise Drift(problem) from error
                failures.append(problem)
        require(not failures, "Final native log check failed: " + "; ".join(failures))

    def launch(self, role, argv, executable, pass_fds=()):
        self.freeze.check()
        self.tree.check()
        # One Cage + one WayVNC + at most 512 captures, including baseline.
        require(self.spawn_serial < 514, "Launch count exceeded")
        serial = self.spawn_serial
        self.spawn_serial += 1
        fd = self.log_file(role + "-" + str(serial) + ".log")
        p = subprocess.Popen(argv, env=self.env, cwd=self.fixture,
                             start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=fd, stderr=fd, close_fds=True, pass_fds=pass_fds)
        # Register immediately so setup failures cannot lose a started child.
        record = {"role": role, "popen": p, "leader": None, "approved": [], "signal": None}
        self.children.append(record)
        try:
            row = identity(p.pid)
        except (FileNotFoundError, ProcessLookupError):
            # A bounded trusted capture can finish before /proc inspection. It
            # must already have succeeded, been reaped, and have no group left.
            if role == "grim" and p.poll() == 0 and not members(p.pid):
                self.children.remove(record)
                record["already_reaped"] = True
                return record
            raise
        require(row["exe"] == executable and row["pid"] == row["pgid"] == row["sid"],
                "Launched executable/session drift")
        record["leader"] = row
        record["approved"] = [row]
        if role in ("cage", "wayvnc"):
            self.roles[role] = row
        return record

    def setup_wait(self, predicate):
        deadline = min(self.deadline, time.monotonic() + 10)
        while not predicate():
            self.freeze.check()
            self.tree.check()
            self.check_logs()
            require(all(r["popen"].poll() is None for r in self.children),
                    "Child exited during setup")
            require(time.monotonic() < deadline, "Setup timeout")
            time.sleep(0.05)

    def setup(self):
        cage = self.launch("cage", [self.freeze.tools["cage"], "-D", "--",
                           self.freeze.spec["executable"]["path"]], self.freeze.tools["cage"])
        def find_gui():
            rows = members(cage["leader"]["pid"])
            gui = [p for p in rows if p["exe"] == self.freeze.spec["executable"]["path"]]
            require(all(p["exe"] in (self.freeze.tools["cage"],
                        self.freeze.spec["executable"]["path"]) for p in rows),
                    "Unapproved Cage startup member")
            require(len(gui) <= 1, "Duplicate GUI process")
            if gui:
                require(gui[0]["pgid"] == gui[0]["sid"] == cage["leader"]["pid"],
                        "GUI session drift")
                cage["approved"] = [cage["leader"], gui[0]]
                self.roles["gui"] = gui[0]
            return bool(gui)
        self.setup_wait(find_gui)
        def wayland_ready():
            names = []
            for name in os.listdir(self.tree.fds[self.run]):
                if re.fullmatch(r"wayland-[0-9]+", name):
                    s = os.stat(name, dir_fd=self.tree.fds[self.run], follow_symlinks=False)
                    require(stat.S_ISSOCK(s.st_mode) and s.st_uid == os.getuid(),
                            "Unexpected Wayland node")
                    names.append((name, s))
            require(len(names) <= 1, "Multiple Wayland sockets")
            if names:
                name, s = names[0]
                require(stat.S_IMODE(s.st_mode) == 0o700, "Wayland socket mode drift")
                self.wayland = name
                self.nodes[name] = node(s)
            return bool(names)
        self.setup_wait(wayland_ready)
        self.pin_socket(self.wayland)
        self.env["WAYLAND_DISPLAY"] = self.wayland
        os.environ["WAYLAND_DISPLAY"] = self.wayland
        config_fd = self.tree.open_file(self.run, "wayvnc.conf", os.O_RDONLY,
                                        expected=self.vnc_config_pin)
        try:
            vnc = self.launch("wayvnc", [self.freeze.tools["wayvnc"], "-u",
                              self.runtime + "/rfb.sock", "-S", self.runtime + "/control.sock",
                              "-o", "HEADLESS-1", "-C", "/proc/self/fd/" + str(config_fd)],
                              self.freeze.tools["wayvnc"], pass_fds=(config_fd,))
        finally:
            os.close(config_fd)
        self.setup_wait(lambda: all(os.path.lexists(self.runtime + "/" + n)
                                   for n in ("rfb.sock", "control.sock")))
        for name in ("rfb.sock", "control.sock"):
            self.pin_socket(name, change_mode=True)
        check_group(vnc["leader"], vnc["approved"])
        self.guard()
        logging.disable(logging.CRITICAL)
        sys.dont_write_bytecode = True
        runpy.run_path(self.freeze.tools["vncdotool"], run_name="standard_bootstrap")
        from vncdotool import api
        from vncdotool.command import parse_server
        self.api = api
        address = self.runtime + "/rfb.sock"
        require(parse_server(address)[0] == socket.AF_UNIX, "Input must use AF_UNIX")
        self.guard()
        self.client = api.connect(address, timeout=5)
        self.guard()
        owner = self.frame("ready")
        owner["nodes"] = self.nodes
        owner["fifo_relative"] = self.run + "/commands.fifo"
        owner["runtime_relative"] = self.run
        owner["artifact_relative"] = self.art
        owner["native_quit_allowed"] = self.args.allow_native_quit
        self.owner_pin = self.tree.json_file(self.art, "owner.json", owner, owner_frame=True)
        self.owner_path = self.tree.root + "/" + self.art + "/owner.json"
        self.owner_fd = self.tree.open_file(self.art, "owner.json", os.O_RDONLY,
                                            expected=self.owner_pin)
        self.owner_hash = hashlib.sha256(read_fd(self.owner_fd, MAX_FRAME, context="owner frame")).hexdigest()
        self.capture("baseline")
        print(json.dumps({"ready": self.owner_path, "root": self.tree.root,
                          "initial_panel": self.initial_panel,
                          "fixture_profile": dict(self.fixture_profile),
                          "fixture_lifecycle_evidence_limit": FIXTURE_LIFECYCLE_LIMIT},
                         allow_nan=False), flush=True)

    def frame(self, state):
        return {"schema": 1, "root": self.tree.root, "freeze": self.freeze.frame(),
                "directories": self.tree.pins.copy(), "state": state,
                "viewport": self.args.viewport, "initial_panel": self.initial_panel,
                "fixture_profile": dict(self.fixture_profile),
                "fixture_lifecycle_evidence_limit": FIXTURE_LIFECYCLE_LIMIT,
                "identities": [{"role": role, "process": p} for role, p in self.roles.items()]}

    def guard(self, expected_exit=False):
        self.freeze.check()
        self.tree.check()
        check_identity(self.roles["input"])
        check_group(self.roles["input"], [self.roles["input"]])
        if self.owner_fd is not None:
            self.tree.check_file(self.art, "owner.json", self.owner_fd, self.owner_pin)
            require(hashlib.sha256(read_fd(self.owner_fd, MAX_FRAME, context="owner guard")).hexdigest() ==
                    self.owner_hash, "Owner frame content drift")
        for record in self.children:
            require(record["leader"] is not None, "Unpinned started child")
            if expected_exit:
                record["popen"].poll()  # Reap expected child exits before absence checks.
            check_group(record["leader"], record["approved"], allow_absent=expected_exit)
            if not expected_exit:
                require(record["popen"].poll() is None, "Child exited unexpectedly")
        for name, pin in self.nodes.items():
            try:
                s = os.stat(name, dir_fd=self.tree.fds[self.run], follow_symlinks=False)
            except FileNotFoundError:
                require(expected_exit and name != "commands.fifo", "Pinned socket disappeared")
                continue
            require(node(s) == pin, "FIFO/socket identity drift")
            if name in self.socket_fds:
                require(node(os.fstat(self.socket_fds[name])) == pin,
                        "Socket descriptor identity drift")
        self.tree.check_file(self.run, "commands.fifo", self.fifo_fd,
                             self.nodes["commands.fifo"])
        self.check_logs(final=expected_exit)
        tcp_owned(list(self.roles.values()))
        require(time.monotonic() < self.deadline, "Bounded session expired")

    def capture(self, label):
        self.guard()
        self.sequence += 1
        require(self.sequence <= 512, "Capture count exceeded")
        stem = str(self.sequence).zfill(3) + "-" + label
        name = stem + ".png"
        fd = self.tree.create(self.art, name)
        pin = node(os.fstat(fd))
        width, height = map(int, self.args.viewport.split("x"))
        try:
            record = self.launch("grim", [self.freeze.tools["grim"],
                                 "-g", f"0,0 {width}x{height}", "/proc/self/fd/" + str(fd)],
                                 self.freeze.tools["grim"], pass_fds=(fd,))
            if not record.get("already_reaped"):
                check_group(record["leader"], record["approved"], allow_absent=True)
                tcp_owned(record["approved"])
            record["popen"].wait(timeout=10)
            require(record["popen"].returncode == 0, "Capture failed")
            require(not members(record["popen"].pid), "Capture group remains")
            if record in self.children:
                self.children.remove(record)
            self.tree.check_file(self.art, name, fd, pin)
            image = read_fd(fd, 64 * 1024 * 1024, context="capture " + name)
            require(len(image) >= 24 and image[:8] == b"\x89PNG\r\n\x1a\n" and
                    image[12:16] == b"IHDR" and struct.unpack(">II", image[16:24]) ==
                    (width, height), "Unexpected capture geometry")
            state = self.public_config()
            state.update({"input_frame": self.last_input, "capture_label": label,
                          "initial_panel": self.initial_panel,
                          "fixture_profile": dict(self.fixture_profile),
                          "fixture_lifecycle_evidence_limit": FIXTURE_LIFECYCLE_LIMIT,
                          "pointer_pixels": self.pointer,
                          "image_sha256": hashlib.sha256(image).hexdigest(),
                          "viewport": self.args.viewport,
                          "geometry_limit": "logical crop, not physical resize/DPI evidence",
                          "http_limit": "counter not externally observable; no zero-count claim"})
            self.tree.json_file(self.art, stem + ".json", state)
            self.guard()
            print(json.dumps({"capture": self.tree.root + "/" + self.art + "/" + name,
                              "state": state, "initial_panel": self.initial_panel,
                              "fixture_profile": dict(self.fixture_profile),
                              "fixture_lifecycle_evidence_limit": FIXTURE_LIFECYCLE_LIMIT},
                             allow_nan=False), flush=True)
        finally:
            os.close(fd)

    def public_config(self):
        vela = self.fixture + "/.vela"
        if not os.path.lexists(vela):
            return {"selected_instance": None, "selected_server": None,
                    "instances": [], "config_sha256": None}
        if "fixture/.vela" not in self.tree.fds:
            self.tree.bind("fixture/.vela")
        self.tree.check()
        try:
            fd = self.tree.open_file("fixture/.vela", "config.json", os.O_RDONLY)
        except FileNotFoundError:
            return {"selected_instance": None, "selected_server": None,
                    "instances": [], "config_sha256": None}
        try:
            raw = read_fd(fd, MAX_JSON, context="public fixture configuration")
            pin = node(os.fstat(fd))
            self.tree.check_file("fixture/.vela", "config.json", fd, pin)
            document = decode_json(raw)
            require(isinstance(document, dict), "Invalid fixture config")
            rows = document.get("instances", [])
            require(isinstance(rows, list) and len(rows) <= 1000, "Invalid instance rows")
            return {"selected_instance": document.get("selected_instance"),
                    "selected_server": document.get("selected_server"),
                    "instances": [{k: item.get(k) for k in ("id", "name", "minecraft_version")}
                                  for item in rows],
                    "config_sha256": hashlib.sha256(raw).hexdigest()}
        finally:
            os.close(fd)

    def input_request(self, command, details):
        self.input_sequence += 1
        require(self.input_sequence <= 512, "Input action count exceeded")
        event = {"sequence": self.input_sequence, "operation": command["op"],
                 "label": command["label"], "pointer_before_pixels": self.pointer,
                 "initial_panel": self.initial_panel,
                 "fixture_profile": dict(self.fixture_profile),
                 "fixture_lifecycle_evidence_limit": FIXTURE_LIFECYCLE_LIMIT,
                 "details": details, "api": "standard vncdotool / AF_UNIX",
                 "coordinate_limit": "RFB framebuffer pixels inside requested crop; "
                     "scale is subject to separate native log review",
                 "api_completed": False,
                 "visual_limit": "delivery does not establish focus or visible acceptance"}
        stem = "input-" + str(self.input_sequence).zfill(3) + "-" + command["label"]
        self.tree.json_file(self.art, stem + "-request.json", event)
        return event, stem

    def input_delivered(self, request, completed=True, note=None):
        event, stem = request
        event = dict(event)
        event.update({"api_completed": completed, "pointer_after_pixels": self.pointer,
                      "delivery_note": note})
        self.tree.json_file(self.art, stem + "-delivered.json", event)
        self.last_input = event

    def expected_disconnect(self, error):
        if isinstance(error, (EOFError, BrokenPipeError, ConnectionResetError)):
            return True
        if self.api is not None:
            from twisted.internet.error import ConnectionDone, ConnectionLost
            return isinstance(error, (ConnectionDone, ConnectionLost))
        return False

    def native_quit(self, command):
        require(self.args.allow_native_quit and command.get("stage") == "ordinary-deinit",
                "Native quit requires explicit allowed ordinary-deinit stage")
        self.guard()  # Verify before delivery; following disconnects are expected here only.
        request = self.input_request(command, {"key": "alt-f4", "stage": "ordinary-deinit"})
        try:
            self.client.keyPress("alt-f4")
        except Exception as error:
            require(self.expected_disconnect(error), "Unexpected native-quit input error")
            self.disconnect_note = str(error)
            self.input_delivered(request, completed=False,
                                 note="Recognized disconnect during call; delivery unconfirmed")
        else:
            self.input_delivered(request)
        deadline = min(self.deadline, time.monotonic() + 15)
        while True:
            self.guard(expected_exit=True)
            gone = all(not members(r["leader"]["pid"]) for r in self.children)
            if gone:
                break
            require(time.monotonic() < deadline, "Native close timeout; no ordinary-deinit claim")
            time.sleep(0.05)
        for record in self.children:
            record["popen"].wait(timeout=1)
            require(record["popen"].returncode == 0, "Native close child exited nonzero")
        require(not check_identity(self.roles["gui"], allow_absent=True), "GUI still alive")
        self.freeze.check()
        require(not unix_entries(self.tree.root), "Owned Unix socket remains after close")
        self.native_close = True
        self.outcome = "native-quit-complete"

    def commands(self):
        pending = b""
        while True:
            self.guard()
            if not select.select([self.fifo_fd], [], [], 0.5)[0]:
                continue
            self.tree.check_file(self.run, "commands.fifo", self.fifo_fd,
                                 self.nodes["commands.fifo"])
            pending += os.read(self.fifo_fd, MAX_COMMAND)
            require(len(pending) <= MAX_COMMAND * 2, "FIFO buffer exceeds bound")
            while b"\n" in pending:
                raw, pending = pending.split(b"\n", 1)
                require(0 < len(raw) < MAX_COMMAND, "Command exceeds bound")
                command = decode_json(raw)
                require(isinstance(command, dict), "Command must be an object")
                op, label = command.get("op"), command.get("label")
                require(isinstance(label, str) and re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", label),
                        "Invalid capture label")
                fields = {"move": {"x", "y"}, "drag": {"x", "y"}, "click": {"button"}, "key": {"key"},
                          "text": {"text"}, "capture": set(), "stop": set(),
                          "native-quit": {"stage"}}
                require(op in fields and set(command) <= {"op", "label", "pause"} | fields[op],
                        "Unknown operation/command field")
                self.guard()
                if op == "native-quit":
                    self.native_quit(command)
                    return
                if op == "stop":
                    self.outcome = "requested-forced-stop"
                    return
                limit = time.monotonic() + 20
                if op == "move":
                    x, y = command.get("x"), command.get("y")
                    width, height = map(int, self.args.viewport.split("x"))
                    require(type(x) is int and type(y) is int and 0 <= x < width and
                            0 <= y < height, "Coordinates outside logical viewport")
                    request = self.input_request(command, {"x_pixels": x, "y_pixels": y})
                    self.client.mouseMove(x, y)
                    self.pointer = {"x": x, "y": y}
                    self.input_delivered(request)
                elif op == "drag":
                    x, y = command.get("x"), command.get("y")
                    width, height = map(int, self.args.viewport.split("x"))
                    require(type(x) is int and type(y) is int and 0 <= x < width and
                            0 <= y < height, "Coordinates outside logical viewport")
                    require(self.pointer is not None, "Move explicitly before any drag input")
                    request = self.input_request(command, {"button": 1,
                                                         "from_pixels": dict(self.pointer),
                                                         "to_pixels": {"x": x, "y": y}})
                    self.guard()
                    self.client.mouseDown(1)
                    try:
                        self.client.pause(0.35)
                        self.guard()
                        self.client.mouseMove(x, y)
                        self.pointer = {"x": x, "y": y}
                        self.client.pause(0.35)
                    finally:
                        self.guard()
                        self.client.mouseUp(1)
                    self.input_delivered(request)
                elif op == "click":
                    button = command.get("button", 1)
                    require(type(button) is int and button in (1, 4, 5), "Unapproved button")
                    require(self.pointer is not None, "Move explicitly before any click/wheel input")
                    request = self.input_request(command, {"button": button,
                                                         "position_pixels": self.pointer})
                    self.client.mousePress(button)
                    self.input_delivered(request)
                elif op == "key":
                    require(command.get("key") in ("tab", "esc", "ctrl-a", "backspace"),
                            "Unapproved key; alt-f4 belongs to native-quit stage")
                    request = self.input_request(command, {"key": command["key"]})
                    self.client.keyPress("bsp" if command["key"] == "backspace" else command["key"])
                    self.input_delivered(request)
                elif op == "text":
                    require(command.get("text") in ("DraftAlpha42", "WorldDraftAlpha42"),
                            "Unapproved public draft")
                    request = self.input_request(command, {"public_draft": command["text"],
                                                         "character_count": len(command["text"])})
                    for char in command["text"]:
                        require(time.monotonic() < limit, "Text command timed out")
                        self.guard()
                        self.client.keyPress(char)
                    self.input_delivered(request)
                pause = command.get("pause", 0.35)
                require(type(pause) in (int, float) and 0.35 <= pause <= 2, "Invalid pause")
                self.client.pause(pause)
                self.capture(label)

    def signal_group(self, record, sig):
        require(record["leader"] is not None, "Cannot signal unpinned child")
        leader = record["leader"]
        require(leader["pgid"] != os.getpgrp(), "Cannot signal input helper group")
        # Each signal separately rechecks original start, executable inode, all
        # four UIDs, and every member against the exact known process records.
        rows = check_group(leader, record["approved"], allow_absent=True)
        if rows:
            os.killpg(leader["pid"], sig)
            record["signal"] = signal.Signals(sig).name + "; forced, not native JOIN evidence"

    def close(self):
        try:
            return self._close()
        finally:
            # Every normal/error exit releases only library descriptors, after
            # the final guard and any safely writable closure report below.
            self.freeze.close()

    def _close(self):
        problems = []
        if self.client is not None:
            try:
                bounded_call(self.client.disconnect)
            except Exception as error:
                if not (self.native_close and self.expected_disconnect(error)):
                    problems.append("Input disconnect: " + str(error))
        if self.api is not None:
            try:
                bounded_call(self.api.shutdown)
            except Exception as error:
                if not (self.native_close and self.expected_disconnect(error)):
                    problems.append("Input API shutdown: " + str(error))
        for record in reversed(self.children):
            try:
                self.signal_group(record, signal.SIGTERM)
                deadline = time.monotonic() + 5
                while True:
                    record["popen"].poll()
                    if not members(record["popen"].pid) or time.monotonic() >= deadline:
                        break
                    time.sleep(0.05)
                if members(record["popen"].pid):
                    self.signal_group(record, signal.SIGKILL)
                record["popen"].wait(timeout=5)
                require(not members(record["popen"].pid), "Owned group/session remains")
            except Exception as error:
                problems.append(record["role"] + " closure refused/incomplete: " + str(error))
        absent = True
        for record in self.children:
            try:
                require(not members(record["popen"].pid), "Owned group/session remains")
                try:
                    proc_stat(record["popen"].pid)
                except (FileNotFoundError, ProcessLookupError):
                    pass
                else:
                    raise Drift("Original child PID remains or was reused")
            except Exception as error:
                absent = False
                problems.append(record["role"] + " absence check: " + str(error))
        if len(self.roles) != 4:
            problems.append("Setup did not establish all four original identities")
        try:
            self.check_logs(final=True)
        except Exception as error:
            problems.append("Final log guard: " + str(error))
        try:
            self.freeze.check()
            self.tree.check()
            require(not unix_entries(self.tree.root), "Owned Unix socket remains")
            tcp_owned(list(self.roles.values()))
        except Exception as error:
            problems.append("Final guard: " + str(error))
        state = self.frame("closed" if absent and not problems else "closure-incomplete")
        state.update({"outcome": self.outcome, "child_groups_absent": absent,
                      "ordinary_native_close": self.native_close and not problems,
                      "expected_disconnect_note": self.disconnect_note,
                      "last_input_frame": self.last_input,
                      "native_evidence_limit": "ordinary close/source deinit path only; "
                          "no instrumented per-manager JOIN or zeroization proof",
                      "termination": [{"role": r["role"], "exit": r["popen"].poll(),
                                       "signal": r["signal"]} for r in self.children],
                      "problems": problems,
                      "external_collection_required": True,
                      "private_homes": "retained; parent must collect helper and prove all "
                          "recorded PID/group/session/listener absence before deletion"})
        try:
            self.tree.json_file(self.art, "closure.json", state)
            print(json.dumps({"closure": self.tree.root + "/" + self.art + "/closure.json",
                              "problems": problems, "initial_panel": self.initial_panel,
                              "fixture_profile": dict(self.fixture_profile),
                              "fixture_lifecycle_evidence_limit": FIXTURE_LIFECYCLE_LIMIT},
                             allow_nan=False), flush=True)
        finally:
            if self.fifo_fd is not None:
                os.close(self.fifo_fd)
            if self.owner_fd is not None:
                os.close(self.owner_fd)
            for fd in self.socket_fds.values():
                os.close(fd)
            for _, fd, _ in self.logs:
                os.close(fd)
            self.tree.close()
        return absent and not problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest")
    parser.add_argument("root")
    parser.add_argument("viewport", choices=("1280x720", "640x400"))
    parser.add_argument("--initial-panel", choices=INITIAL_PANELS, default="home")
    parser.add_argument("--fixture-scene", choices=FIXTURE_SCENES, default="layout")
    parser.add_argument("--pack-archive", choices=PACK_ARCHIVES, default="modrinth")
    parser.add_argument("--pack-hold", choices=PACK_HOLDS, default="none")
    parser.add_argument("--pack-adoption-retry", action="store_true")
    parser.add_argument("--pack-scenario", choices=PACK_SCENARIOS, default="default")
    parser.add_argument("--resume", metavar="PRIOR_CLOSURE")
    parser.add_argument("--previous-job-collected", action="store_true")
    parser.add_argument("--allow-native-quit", action="store_true")
    parser.add_argument("--session-timeout", type=int, default=900)
    args = parser.parse_args()
    require(30 <= args.session_timeout <= 3600, "Session timeout outside finite bounds")
    os.umask(0o077)
    sys.dont_write_bytecode = True
    harness = Harness(args)
    try:
        harness.setup()
        harness.commands()
    except Exception as error:
        print(json.dumps({"failure": str(error), "private_homes": "retained"}, allow_nan=False), flush=True)
    finally:
        try:
            closed = harness.close()
        finally:
            # Final guards and closure reporting above precede release of pins.
            harness.freeze.close()
    return 0 if closed and harness.outcome != "failure" else 1


if __name__ == "__main__":
    raise SystemExit(main())
