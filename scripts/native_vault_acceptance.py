#!/usr/bin/env python3
"""Opt-in, owned Linux SecretService acceptance. Does not build or use desktop buses.

Run only after a separate execution GO. No passwords/tokens in argv, environment,
logs or retained snapshots. The keyring dummy password travels only over stdin.
Failure to establish identity/teardown quarantines the private tree at 0700.
"""
import argparse
import errno
import select
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

DBUS_RUN = "/run/current-system/sw/bin/dbus-run-session"
KEYRING = "/run/wrappers/bin/gnome-keyring-daemon"
DUMMY_PASSWORD = b"owned-vault-acceptance-DUMMY-password\n"
CASES = ("rollback", "commit", "ambiguous", "valid", "auth")
LIMITS = ["No power-loss proof", "No UI or controller-worker-wide RAM wiping proof",
          "No libsecret/daemon RAM wiping proof", "No auth refresh/signout case",
          "Commit failure is synthesized after an actual native put"]

NATIVE_PHASES = frozenset(("seed", "recover", "cleanup"))
NATIVE_STAGES = {
    "seed": frozenset(("native_init", "crud", "cf_rollback", "cf_commit", "cf_ambiguous", "auth_seed", "report")),
    "recover": frozenset(("native_init", "crud", "cf_rollback", "cf_commit", "cf_ambiguous", "cf_valid_invalid", "auth_cleanup", "report")),
    "cleanup": frozenset(("native_init", "vault_cleanup", "report")),
}
NATIVE_CLASSES = frozenset(("backend_unavailable", "denied", "not_found", "invalid_reference",
    "invalid_secret", "too_large", "storage_failure", "out_of_memory", "isolation_failed",
    "assertion_failed", "io_failure", "unknown"))
PRE_GATE_STAGES = frozenset(("opt_in", "input", "json", "platform", "uid", "bus_env", "address", "root_path", "runtime_path", "socket_stat", "bus_stat", "bus_start", "bus_uids", "bus_exe", "owner_stat", "owner_start", "owner_uids", "owner_exe", "grant_shape", "nonce_path", "nonce_read", "capability_path", "capability_read", "references", "environment", "system_bus", "case_paths"))
DIAGNOSTIC_STATUSES = frozenset(("not_started", "empty", "valid", "invalid", "oversized", "incomplete", "unreadable"))
DIAGNOSTIC_ENV = "VELA_NATIVE_VAULT_DIAGNOSTIC"
HELPER_STAGES = frozenset(("root", "manifest", "barrier", "wrapper_identity", "wrapper_pin", "wrapper_ledger", "wrapper_grant", "wrapper_wait", "wrapper_stop", "wrapper_handle_close", "socket", "bus_query", "bus_identity", "bus_pin", "bus_ledger", "keyring_metadata", "keyring_spawn", "keyring_identity", "keyring_pin", "keyring_ledger", "password_feed", "service_wait", "owner_query", "owner_match", "native_spawn", "native_identity", "native_pin", "native_ledger", "native_wait", "result_check", "test_stdin_close", "keyring_stdin_close", "root_remove", "test_stop", "test_handle_close", "keyring_stop", "keyring_handle_close", "bus_handle_close", "cleanup_write", "record_retention", "artifact_check"))
HELPER_CLASSES = frozenset(("permission_denied", "uid_mismatch", "process_disappeared", "zombie", "exe_unreadable", "identity_changed", "pidfd_failed", "startup_exit", "readiness_timeout", "owner_mismatch", "ownership_unproved", "barrier_invalid", "barrier_timeout", "native_exit_nonzero", "native_signal", "native_timeout", "wrapper_timeout", "invariant_failed", "io_failure", "unknown"))
RECORD_LIMIT = 8192
BARRIER_LIMIT = 512
BARRIER_TIMEOUT = 10

class AcceptanceError(Exception):
    def __init__(self, label, code="invariant_failed"):
        super().__init__(label)
        self.code = code

def need(ok, label, code="invariant_failed"):
    if not ok:
        raise AcceptanceError(label, code)

def fixed_failure(stage, error):
    if isinstance(error, AcceptanceError):
        code = error.code if error.code in HELPER_CLASSES else "unknown"
    elif isinstance(error, PermissionError):
        code = "permission_denied"
    elif isinstance(error, (FileNotFoundError, ProcessLookupError)):
        code = "process_disappeared"
    elif isinstance(error, subprocess.TimeoutExpired):
        code = "readiness_timeout"
    elif isinstance(error, OSError):
        code = "pidfd_failed" if stage.endswith("_pin") else "io_failure"
    else:
        code = "unknown"
    return {"stage": stage, "class": code}

def executable(name):
    value = shutil.which(name)
    need(value is not None and os.path.isabs(value), "missing prerequisite: " + name)
    need(os.access(value, os.X_OK), "prerequisite not executable")
    return value

def private_path(path, directory=True):
    path = Path(path)
    need(path.is_absolute(), "absolute path required")
    current = Path("/")
    for part in path.parts[1:]:
        need(part not in (".", ".."), "unsafe path component")
        current /= part
        need(not stat.S_ISLNK(current.lstat().st_mode), "symlink rejected")
    info = path.lstat()
    need(info.st_uid == os.getuid(), "path owner mismatch")
    need(stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600), "private mode required")
    need(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode), "path kind mismatch")
    return info

def fresh_artifacts(path):
    raw_path = os.fspath(path)
    need(type(raw_path) is str and len(os.fsencode(raw_path)) <= 4096 and
         all(part not in (".", "..") for part in raw_path.split("/")),
         "artifact path rejected")
    path = Path(raw_path)
    parts = path.parts[1:]
    need(path.is_absolute() and 0 < len(parts) <= 64 and len(os.fsencode(path)) <= 4096 and
         all(part not in (".", "..") and 0 < len(os.fsencode(part)) <= 255 for part in parts),
         "artifact path rejected")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    parent_fd = os.open("/", flags)
    try:
        missing = None
        # Validate every existing ancestor before creating any directory.
        for index, part in enumerate(parts):
            try:
                before = os.stat(part, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                missing = index
                break
            need(stat.S_ISDIR(before.st_mode), "artifact ancestor rejected")
            child_fd = os.open(part, flags, dir_fd=parent_fd)
            try:
                observed = os.fstat(child_fd)
                need(stat.S_ISDIR(observed.st_mode) and
                     (observed.st_dev, observed.st_ino) == (before.st_dev, before.st_ino),
                     "artifact ancestor changed", "identity_changed")
            except BaseException:
                os.close(child_fd)
                raise
            os.close(parent_fd)
            parent_fd = child_fd
        need(missing is not None, "artifact destination already exists")
        # Held nofollow parents prevent mkdir from traversing replacement symlinks.
        for part in parts[missing:]:
            os.mkdir(part, mode=0o700, dir_fd=parent_fd)
            before = os.stat(part, dir_fd=parent_fd, follow_symlinks=False)
            child_fd = os.open(part, flags, dir_fd=parent_fd)
            try:
                observed = os.fstat(child_fd)
                need(stat.S_ISDIR(observed.st_mode) and observed.st_uid == os.getuid() and
                     stat.S_IMODE(observed.st_mode) == 0o700 and
                     (observed.st_dev, observed.st_ino) == (before.st_dev, before.st_ino),
                     "created artifact directory rejected", "identity_changed")
            except BaseException:
                os.close(child_fd)
                raise
            os.close(parent_fd)
            parent_fd = child_fd
        before = private_path(path)
        observed = os.fstat(parent_fd)
        need((observed.st_dev, observed.st_ino) == (before.st_dev, before.st_ino),
             "artifact destination changed", "identity_changed")
    finally:
        os.close(parent_fd)

def write_private(path, data):
    path = Path(path)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        need(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1,
             "private writer metadata rejected")
        os.fchmod(fd, 0o600)
        os.ftruncate(fd, 0)
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(fd)
    finally:
        os.close(fd)

def write_record(path, record):
    data = json.dumps(record, separators=(",", ":"), allow_nan=False).encode()
    need(0 < len(data) < RECORD_LIMIT, "record exceeds bound")
    write_private(path, data)

def process_identity(pid, allow_zombie=False):
    base = Path("/proc") / str(pid)
    text = (base / "stat").read_text()
    fields = text[text.rfind(")") + 2:].split()
    need(allow_zombie or fields[0] != "Z", "process is zombie", "zombie")
    uid_line = next(line for line in (base / "status").read_text().splitlines() if line.startswith("Uid:"))
    uids = [int(value) for value in uid_line[4:].split()]
    need(uids == [os.getuid()] * 4, "process UID mismatch", "uid_mismatch")
    try:
        exe = "<zombie>" if fields[0] == "Z" else os.readlink(base / "exe")
    except PermissionError:
        raise AcceptanceError("process executable unreadable", "exe_unreadable") from None
    return {"pid": pid, "start": int(fields[19]), "exe": exe, "uid": os.getuid(), "uids": uids,
            "ppid": int(fields[1]), "pgid": int(fields[2]), "sid": int(fields[3])}

def identical(identity):
    try:
        actual = process_identity(identity["pid"])
        return all(actual[key] == identity[key] for key in ("pid", "start", "exe"))
    except (FileNotFoundError, ProcessLookupError):
        return False

def descendant(pid, ancestor):
    seen = set()
    while pid > 1 and pid not in seen:
        if pid == ancestor:
            return True
        seen.add(pid)
        pid = process_identity(pid)["ppid"]
    return False

def group_members(pgid, sid):
    """Check membership before any UID/executable policy; zombies count."""
    result = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal():
            continue
        pid = int(entry.name)
        try:
            member_pgid = os.getpgid(pid)
            member_sid = os.getsid(pid)
        except (FileNotFoundError, ProcessLookupError):
            # Only kernel-confirmed disappearance is an ignorable race.
            continue
        if member_pgid == pgid or member_sid == sid:
            try:
                # Include zombies and validate matching metadata before declaring emptiness.
                observed = process_identity(pid, allow_zombie=True)
                need(integer(observed["start"], 1), "matching process start rejected", "identity_changed")
            except (FileNotFoundError, ProcessLookupError):
                continue
            result.append(pid)
    if not result:
        # Signal 0 only probes existence; it never terminates or signals a job.
        # This catches a surviving group hidden from the /proc enumeration.
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return result
        # PermissionError and any other uncertainty propagate to quarantine.
        raise AcceptanceError("owned process group still exists or is unobservable")
    return result

def pid_handle(identity):
    need(identical(identity), "process identity changed before pin", "identity_changed")
    fd = os.pidfd_open(identity["pid"], 0)
    try:
        need(identical(identity), "process identity changed after pin", "identity_changed")
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        raise
    return fd

def gone(identity):
    try:
        now = process_identity(identity["pid"])
        return now["start"] != identity["start"]
    except (FileNotFoundError, ProcessLookupError):
        return True
    except AcceptanceError:
        # Zombies must be reaped; they are not cleanup proof.
        return False

def stop_child(proc, identity, handle):
    if proc.poll() is None:
        need(identical(identity), "refuse signal: identity changed")
        signal.pidfd_send_signal(handle, signal.SIGTERM)
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            signal.pidfd_send_signal(handle, signal.SIGKILL)
            proc.wait(timeout=5)
    else:
        proc.wait()
    need(gone(identity), "child not reaped")

def clean_env(root, library_path):
    value = {"PATH": "/run/current-system/sw/bin", "LANG": "C.UTF-8",
             "VELA_NATIVE_VAULT_ACCEPTANCE": "owned-only", "GIO_USE_VFS": "local"}
    for name, sub in (("HOME", "home"), ("XDG_DATA_HOME", "data"),
                      ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"),
                      ("XDG_RUNTIME_DIR", "runtime")):
        value[name] = str(root / sub)
    value["DBUS_SYSTEM_BUS_ADDRESS"] = "unix:path=" + str(root / "runtime/no-system-bus")
    if library_path:
        value["LD_LIBRARY_PATH"] = library_path
    return value

def dbus(send, address, method, argument=None):
    command = [send, "--bus=" + address, "--print-reply", "--reply-timeout=3000",
               "--dest=org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus." + method]
    if argument is not None:
        command.append("string:" + argument)
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
    need(result.returncode == 0, "private bus query failed")
    text = result.stdout.decode("ascii", "strict")
    pattern = r'string "([A-Za-z0-9:._-]+)"' if method in ("GetId", "GetNameOwner") else r'uint32 ([0-9]+)'
    match = re.search(pattern, text)
    need(match is not None, "private bus reply malformed")
    return match.group(1) if method in ("GetId", "GetNameOwner") else int(match.group(1))

def socket_proof(root, address):
    sock = root / "runtime/bus"
    need(re.fullmatch(r"unix:path=" + re.escape(str(sock)) + r"(?:,guid=[0-9a-f]{32})?", address) is not None,
         "bus address not owned")
    info = sock.lstat()
    need(stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid(), "bus socket mismatch")
    private_path(root / "runtime")
    return info.st_ino

def snapshot(root, destination):
    """Copy only strict reference-only launcher JSON, never keyring contents."""
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    for case in CASES:
        source = root / "launcher" / case / ".vela"
        if not source.exists():
            continue
        private_path(source)
        for filename in ("config.json", "auth-cleanup.json", "curseforge-credentials.json"):
            file = source / filename
            if not file.exists():
                continue
            need(not file.is_symlink() and file.is_file(), "snapshot symlink rejected")
            raw = file.read_bytes()
            need(len(raw) <= 4 * 1024 * 1024, "snapshot exceeds bound")
            document = json.loads(raw)
            # A leak is reported by category only, never content.
            need(not any(value in raw for value in (b"owned-refresh-fixture", b"owned-cf-", b"owned-orphan-fixture",
                     b"owned-minecraft-fixture", b"owned-device-fixture", DUMMY_PASSWORD.strip())), "secret in launcher file")
            def inspect(value):
                if isinstance(value, dict):
                    for key, item in value.items():
                        need(key not in ("access_token", "refresh_token", "api_key", "password", "device_code", "secret"),
                             "secret field in launcher file")
                        inspect(item)
                elif isinstance(value, list):
                    for item in value:
                        inspect(item)
            inspect(document)
            write_private(destination / (case + "-" + filename), raw)

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate diagnostic field")
        result[key] = value
    return result

def bounded_json(file, limit=RECORD_LIMIT):
    before = private_path(file, False)
    fd = os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        need(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and
             stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1 and
             (info.st_dev, info.st_ino) == (before.st_dev, before.st_ino) and
             0 < info.st_size < limit, "record metadata rejected")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            raw = stream.read(limit)
        need(len(raw) == info.st_size and len(raw) < limit, "record size rejected")
    finally:
        os.close(fd)
    return json.loads(raw.decode("utf-8", "strict"), object_pairs_hook=unique_object)

def exact_keys(value, keys):
    need(type(value) is dict and set(value) == set(keys), "record keys rejected")

def integer(value, minimum=0):
    return type(value) is int and value >= minimum

def identity_schema(value):
    exact_keys(value, ("pid", "start", "exe", "uid", "uids", "ppid", "pgid", "sid"))
    need(integer(value["pid"], 2) and integer(value["start"], 1) and
         integer(value["ppid"]) and integer(value["pgid"], 2) and integer(value["sid"], 2) and
         type(value["uid"]) is int and value["uid"] == os.getuid() and
         type(value["uids"]) is list and len(value["uids"]) == 4 and
         all(type(uid) is int and uid == os.getuid() for uid in value["uids"]) and
         type(value["exe"]) is str and len(value["exe"]) <= 2048 and os.path.isabs(value["exe"]),
         "identity schema rejected")

def failure_schema(value):
    exact_keys(value, ("stage", "class"))
    need(type(value["stage"]) is str and value["stage"] in HELPER_STAGES and
         type(value["class"]) is str and value["class"] in HELPER_CLASSES, "failure enum rejected")

def manifest_schema(value):
    exact_keys(value, ("nonce", "prefix", "refs", "dbus_send", "executable", "executable_sha256", "keyring"))
    need(type(value["nonce"]) is str and re.fullmatch(r"[0-9a-f]{32}", value["nonce"]) is not None and
         type(value["prefix"]) is str and re.fullmatch(r"[0-9a-f]{8}", value["prefix"]) is not None and
         type(value["refs"]) is list and len(value["refs"]) == 11 and
         all(type(ref) is str and re.fullmatch(r"[0-9a-f]{32}", ref) is not None and
             ref.startswith(value["prefix"]) for ref in value["refs"]) and len(set(value["refs"])) == 11,
         "manifest references rejected")
    for key in ("dbus_send", "executable"):
        need(type(value[key]) is str and os.path.isabs(value[key]) and len(value[key]) <= 2048,
             "manifest executable rejected")
    need(type(value["executable_sha256"]) is str and re.fullmatch(r"[0-9a-f]{64}", value["executable_sha256"]) is not None,
         "manifest hash rejected")
    keyring_schema(value["keyring"])

def keyring_schema(value):
    exact_keys(value, ("path", "resolved", "dev", "ino", "uid", "mode", "size", "sha256", "override"))
    need(type(value["override"]) is bool and type(value["path"]) is str and os.path.isabs(value["path"]) and
         type(value["resolved"]) is str and os.path.isabs(value["resolved"]) and
         len(value["path"]) <= 2048 and len(value["resolved"]) <= 2048 and
         all(integer(value[key]) for key in ("dev", "ino", "uid", "mode", "size")) and
         type(value["sha256"]) is str and re.fullmatch(r"[0-9a-f]{64}", value["sha256"]) is not None and
         (value["override"] or value["path"] == KEYRING), "keyring metadata schema rejected")
    if value["override"]:
        need(value["path"] == value["resolved"] and value["path"].startswith("/nix/store/") and
             value["uid"] == 0 and value["mode"] & 0o6222 == 0, "keyring provenance rejected")

def ledger_schema(value, phase, kind, root, binary_hash):
    common = ("version", "phase", "ready")
    if kind == "wrapper":
        exact_keys(value, common + ("direct_popen", "child_pid", "parent_pid", "wrapper", "observed", "pinned", "expected_socket", "executable_sha256"))
        need(value["ready"] is False and value["direct_popen"] is True and
             integer(value["child_pid"], 2) and integer(value["parent_pid"], 2) and
             type(value["observed"]) is bool and type(value["pinned"]) is bool and
             value["observed"] == (value["wrapper"] is not None) and
             value["expected_socket"] == str(root / "runtime/bus") and
             type(value["executable_sha256"]) is str and value["executable_sha256"] == binary_hash,
             "wrapper ledger rejected")
        if value["observed"]:
            identity_schema(value["wrapper"])
            need(value["wrapper"]["pid"] == value["child_pid"], "wrapper observed PID rejected")
        need(not value["pinned"] or value["observed"], "wrapper pin rejected")
        if value["pinned"]:
            need(value["wrapper"]["ppid"] == value["parent_pid"] and
                 value["wrapper"]["pgid"] == value["child_pid"] and value["wrapper"]["sid"] == value["child_pid"],
                 "pinned wrapper lineage rejected")
    elif kind == "partial":
        exact_keys(value, common + ("helper", "bus", "bus_observed", "bus_pinned", "bus_id", "socket_inode", "socket_uid", "keyring_pid", "keyring", "keyring_observed", "keyring_pinned", "test_pid", "test", "test_observed", "test_pinned"))
        need(value["ready"] is False, "partial ledger cannot be ready")
        for key in ("helper", "bus", "keyring", "test"):
            if value[key] is not None:
                identity_schema(value[key])
        for name in ("bus", "keyring", "test"):
            need(type(value[name + "_observed"]) is bool and type(value[name + "_pinned"]) is bool and
                 value[name + "_observed"] == (value[name] is not None) and
                 (not value[name + "_pinned"] or value[name + "_observed"]), "partial observation/pin rejected")
        need(value["bus_id"] is None or (type(value["bus_id"]) is str and re.fullmatch(r"[0-9a-f]{32}", value["bus_id"]) is not None), "partial bus id rejected")
        need(value["socket_inode"] is None or integer(value["socket_inode"], 1), "partial inode rejected")
        need(value["socket_uid"] is None or (type(value["socket_uid"]) is int and value["socket_uid"] == os.getuid()), "partial socket UID rejected")
        for name in ("keyring", "test"):
            need(value[name + "_pid"] is None or integer(value[name + "_pid"], 2), "partial child PID rejected")
            if value[name + "_observed"]:
                need(value[name]["pid"] == value[name + "_pid"], "partial observed PID rejected")
            if value[name + "_pinned"]:
                need(value["helper"] is not None and value[name]["ppid"] == value["helper"]["pid"],
                     "pinned child lineage rejected")
    elif kind == "complete":
        exact_keys(value, common + ("bus", "owner", "bus_id", "owner_name", "socket_inode", "socket_uid", "helper", "test"))
        need(value["ready"] is True and type(value["bus_id"]) is str and re.fullmatch(r"[0-9a-f]{32}", value["bus_id"]) is not None and
             type(value["owner_name"]) is str and re.fullmatch(r":[0-9]+[.][0-9]+", value["owner_name"]) is not None and
             integer(value["socket_inode"], 1) and type(value["socket_uid"]) is int and value["socket_uid"] == os.getuid(), "complete ledger rejected")
        for name in ("bus", "owner", "helper"):
            identity_schema(value[name])
        need(value["owner"]["ppid"] == value["helper"]["pid"], "complete owner lineage rejected")
        if value["test"] is not None:
            identity_schema(value["test"])
            need(value["test"]["ppid"] == value["helper"]["pid"], "complete test lineage rejected")
    else:
        raise AcceptanceError("unknown ledger kind")
    need(type(value["version"]) is int and value["version"] == 1 and value["phase"] == phase and phase in NATIVE_PHASES,
         "ledger version rejected")

def diagnostic_event_schema(value, phase):
    exact_keys(value, ("version", "kind", "stage", "class", "secondary"))
    need(type(value["version"]) is int and value["version"] == 1 and
         type(value["kind"]) is str and value["kind"] in ("pregate_failure", "native_failure", "report_write_failure") and
         type(value["stage"]) is str and type(value["class"]) is str and value["class"] in NATIVE_CLASSES,
         "native diagnostic event rejected")
    need(value["stage"] in (PRE_GATE_STAGES if value["kind"] == "pregate_failure" else NATIVE_STAGES[phase]),
         "native diagnostic stage rejected")
    if value["kind"] == "report_write_failure":
        need(type(value["secondary"]) is str and value["secondary"] in NATIVE_CLASSES, "diagnostic secondary rejected")
    else:
        need(value["secondary"] is None, "unexpected diagnostic secondary")


def native_diagnostic_schema(value, phase):
    exact_keys(value, ("status", "record"))
    need(type(value["status"]) is str and value["status"] in DIAGNOSTIC_STATUSES, "diagnostic status rejected")
    if value["status"] == "valid":
        diagnostic_event_schema(value["record"], phase)
    else:
        need(value["record"] is None, "invalid diagnostic bytes must not be retained")


class NativeDiagnostic:
    def __init__(self):
        self.reader = self.writer = None

    def open(self):
        self.reader, self.writer = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
        reader_info, writer_info = os.fstat(self.reader), os.fstat(self.writer)
        need(self.reader > 2 and self.writer > 2 and stat.S_ISFIFO(reader_info.st_mode) and
             stat.S_ISFIFO(writer_info.st_mode) and reader_info.st_uid == writer_info.st_uid == os.geteuid() and
             reader_info.st_ino == writer_info.st_ino and writer_info.st_ino > 0, "diagnostic pipe identity rejected")
        need(fcntl.fcntl(self.writer, fcntl.F_GETFL) & os.O_ACCMODE == os.O_WRONLY and
             fcntl.fcntl(self.writer, fcntl.F_GETFL) & os.O_NONBLOCK and
             fcntl.fcntl(self.reader, fcntl.F_GETFL) & os.O_NONBLOCK and
             fcntl.fcntl(self.reader, fcntl.F_GETFD) & fcntl.FD_CLOEXEC and
             fcntl.fcntl(self.writer, fcntl.F_GETFD) & fcntl.FD_CLOEXEC, "diagnostic pipe flags rejected")
        proof = str(self.writer) + ":" + str(writer_info.st_ino)
        need(len(proof) <= 31 and self.writer <= 2147483647 and writer_info.st_ino <= 18446744073709551615,
             "diagnostic pipe proof rejected")
        return proof

    def close_writer(self):
        fd, self.writer = self.writer, None
        if fd is not None:
            os.close(fd)

    def close(self):
        fds = (self.writer, self.reader)
        self.writer = self.reader = None
        failure = None
        for fd in fds:
            if fd is not None:
                try:
                    os.close(fd)
                except BaseException as error:
                    if failure is None:
                        failure = error
        if failure is not None:
            raise failure

    def collect(self, phase, exit_status):
        result = {"status": "not_started", "record": None}
        if self.reader is None:
            return result
        if exit_status is None:
            result["status"] = "incomplete"
            return result
        raw = bytearray()
        try:
            while len(raw) <= 1024:
                block = os.read(self.reader, 1025 - len(raw))
                if not block:
                    break
                raw.extend(block)
                if len(raw) > 512:
                    result["status"] = "oversized"
                    return result
        except BlockingIOError:
            result["status"] = "incomplete"
            return result
        except Exception:
            result["status"] = "unreadable"
            return result
        if not raw:
            result["status"] = "empty"
            return result
        try:
            event = json.loads(raw.decode("utf-8", "strict"), object_pairs_hook=unique_object)
            diagnostic_event_schema(event, phase)
            need(exit_status != 0, "non-success diagnostic on successful exit")
        except Exception:
            result["status"] = "invalid"
            return result
        result.update(status="valid", record=event)
        return result


def helper_record_schema(value, phase):
    keys = ("version", "phase", "passed", "primary", "teardown", "facts", "native_exit_status")
    if type(value) is dict and "native_diagnostic" in value:
        keys += ("native_diagnostic",)
    exact_keys(value, keys)
    need(type(value["version"]) is int and value["version"] == 2 and value["phase"] == phase and
         phase in NATIVE_PHASES and value["passed"] is False, "helper record rejected")
    if value["primary"] is not None:
        failure_schema(value["primary"])
    need(type(value["teardown"]) is list and len(value["teardown"]) <= 8, "teardown record rejected")
    seen = set()
    for item in value["teardown"]:
        failure_schema(item)
        need(item["stage"] not in seen, "duplicate teardown stage")
        seen.add(item["stage"])
    exact_keys(value["facts"], ("test_reaped", "keyring_reaped", "bus_handle_closed"))
    need(all(item is None or type(item) is bool for item in value["facts"].values()), "teardown facts rejected")
    status = value["native_exit_status"]
    need(status is None or (type(status) is int and -64 <= status <= 255), "native exit status rejected")
    if "native_diagnostic" in value:
        native_diagnostic_schema(value["native_diagnostic"], phase)
        if value["native_diagnostic"]["status"] == "valid":
            need(status is not None and status != 0, "diagnostic without joined failure rejected")
    need(value["primary"] is not None or bool(value["teardown"]), "failure record without failure")

def native_record_schema(value, phase):
    exact_keys(value, ("version", "phase", "stage", "class", "passed"))
    need(type(value["version"]) is int and value["version"] == 1 and value["phase"] == phase and
         value["passed"] is False and type(value["stage"]) is str and value["stage"] in NATIVE_STAGES[phase] and
         type(value["class"]) is str and value["class"] in NATIVE_CLASSES, "native failure record rejected")

def collect_record(root, phase, kind, binary_hash):
    names = {"wrapper": "wrapper-", "partial": "ledger-", "complete": "identities-", "native": "failure-", "helper": "helper-failure-"}
    entry = {"origin": kind, "phase": phase, "record_status": "absent"}
    try:
        value = bounded_json(root / (names[kind] + phase + ".json"), 1024 if kind == "native" else RECORD_LIMIT)
        if kind == "native":
            native_record_schema(value, phase)
        elif kind == "helper":
            helper_record_schema(value, phase)
        else:
            ledger_schema(value, phase, kind, root, binary_hash)
        entry.update(record_status="valid", record=value)
    except FileNotFoundError:
        pass
    except Exception:
        entry["record_status"] = "rejected"
    return entry

def barrier(manifest, root, phase):
    deadline = time.monotonic() + BARRIER_TIMEOUT
    data = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        need(remaining > 0, "launch barrier timeout", "barrier_timeout")
        readable, _, _ = select.select([0], [], [], remaining)
        need(bool(readable), "launch barrier timeout", "barrier_timeout")
        chunk = os.read(0, BARRIER_LIMIT - len(data))
        if not chunk:
            break
        data.extend(chunk)
        need(len(data) < BARRIER_LIMIT, "launch barrier exceeds bound", "barrier_invalid")
    try:
        token = json.loads(data.decode("ascii", "strict"), object_pairs_hook=unique_object)
        exact_keys(token, ("version", "phase", "nonce", "wrapper_pid"))
        need(type(token["version"]) is int and token["version"] == 1 and token["phase"] == phase and
             token["nonce"] == manifest["nonce"] and type(token["wrapper_pid"]) is int and token["wrapper_pid"] == os.getppid(),
             "launch barrier rejected", "barrier_invalid")
        record = bounded_json(root / ("wrapper-" + phase + ".json"))
        ledger_schema(record, phase, "wrapper", root, manifest["executable_sha256"])
        need(record["pinned"] is True and record["wrapper"]["pid"] == os.getppid() and
             identical(record["wrapper"]) and os.getpgid(0) == record["wrapper"]["pgid"] and
             os.getsid(0) == record["wrapper"]["sid"], "launch ownership rejected", "identity_changed")
    except AcceptanceError:
        raise
    except Exception:
        raise AcceptanceError("launch barrier rejected", "barrier_invalid") from None

def keyring_metadata(path, override):
    chosen = Path(path)
    need(chosen.is_absolute(), "absolute keyring executable required")
    resolved = chosen.resolve(strict=True)
    if override:
        need(str(chosen) == str(resolved) and str(resolved).startswith("/nix/store/"), "immutable Nix keyring required")
        current = Path("/nix/store")
        store_info = current.lstat()
        need(stat.S_ISDIR(store_info.st_mode) and store_info.st_uid == 0, "root-trusted Nix store required")
        parts = resolved.relative_to(current).parts
        need(len(parts) >= 2, "Nix package executable required")
        for part in parts:
            current /= part
            component = current.lstat()
            need(not stat.S_ISLNK(component.st_mode) and component.st_uid == 0 and
                 component.st_mode & 0o222 == 0 and
                 (current == resolved or stat.S_ISDIR(component.st_mode)), "read-only root-trusted Nix component required")
    fd = os.open(resolved, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        need(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= 64 * 1024 * 1024 and os.access(resolved, os.X_OK), "keyring ELF metadata rejected")
        if override:
            need(info.st_uid == 0 and info.st_mode & 0o6222 == 0, "unprivileged immutable keyring required")
            try:
                capability = os.getxattr(resolved, "security.capability", follow_symlinks=False)
            except OSError as error:
                need(error.errno in (errno.ENODATA, errno.ENOTSUP), "keyring capability metadata unavailable")
            else:
                need(not capability, "keyring file capability rejected")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            need(stream.read(4) == b"\x7fELF", "keyring must be raw ELF")
            stream.seek(0)
            digest = hashlib.sha256()
            remaining = info.st_size
            while remaining:
                chunk = stream.read(min(65536, remaining))
                need(bool(chunk), "keyring file shortened", "identity_changed")
                digest.update(chunk)
                remaining -= len(chunk)
            need(stream.read(1) == b"", "keyring file grew", "identity_changed")
        signature = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns,
                                   value.st_ctime_ns, value.st_mode, value.st_uid)
        need(signature(info) == signature(os.fstat(fd)) == signature(resolved.lstat()) and
             chosen.resolve(strict=True) == resolved, "keyring metadata changed", "identity_changed")
        direct = "/nix/store/ahw2bsrb432la1q00vsvlx27ivpkmb95-gnome-keyring-50.0/bin/.gnome-keyring-daemon-wrapped"
        if override and str(resolved) == direct:
            need(digest.hexdigest() == "1964892456014d55ffef141fd09083122752373e5f23d131ab00266ec5e6cbe0",
                 "verified direct keyring hash changed", "identity_changed")
    finally:
        os.close(fd)
    return {"path": str(chosen), "resolved": str(resolved), "dev": info.st_dev, "ino": info.st_ino,
            "uid": info.st_uid, "mode": info.st_mode, "size": info.st_size,
            "sha256": digest.hexdigest(), "override": override}


def inside(args):
    root = Path(args.owned_root)
    phase = args.phase
    stage = "root"
    trusted = False
    primary_error = None
    primary = None
    teardown = []
    facts = {"test_reaped": None, "keyring_reaped": None, "bus_handle_closed": None}
    daemon = test = None
    keyring = test_identity = bus = None
    keyring_handle = test_handle = bus_handle = None
    phase_passed = False
    native_diagnostic = NativeDiagnostic()
    partial = {"version": 1, "phase": phase, "ready": False, "helper": None, "bus": None,
               "bus_observed": False, "bus_pinned": False,
               "bus_id": None, "socket_inode": None, "socket_uid": None,
               "keyring_pid": None, "keyring": None, "keyring_observed": False, "keyring_pinned": False,
               "test_pid": None, "test": None, "test_observed": False, "test_pinned": False}

    def save_partial():
        ledger_schema(partial, phase, "partial", root, manifest["executable_sha256"])
        write_record(root / ("ledger-" + phase + ".json"), partial)

    def cleanup_attempt(cleanup_stage, action):
        try:
            action()
        except Exception as error:
            teardown.append(fixed_failure(cleanup_stage, error))

    def stop_owned(proc, identity, handle, fact):
        if proc is None:
            facts[fact] = True
            return
        if identity is None or handle is None:
            # Reap an already-exited direct Popen child, but never signal by PID.
            if proc.poll() is not None:
                proc.wait()
            raise AcceptanceError("child ownership not pinned", "ownership_unproved")
        stop_child(proc, identity, handle)
        facts[fact] = True

    try:
        private_path(root)
        need(phase in NATIVE_PHASES, "unknown phase")
        stage = "manifest"
        manifest = bounded_json(root / "manifest.json")
        manifest_schema(manifest)
        nonce_info = private_path(root / "nonce", False)
        need(nonce_info.st_nlink == 1 and nonce_info.st_size == 32 and
             (root / "nonce").read_bytes() == manifest["nonce"].encode(), "nonce mismatch")
        need(os.getuid() != 0 and os.getuid() == os.geteuid() and
             os.environ.get("VELA_NATIVE_VAULT_ACCEPTANCE") == "owned-only", "helper opt-in required")
        for name, sub in (("HOME", "home"), ("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                          ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "runtime")):
            need(os.environ.get(name) == str(root / sub), "helper environment mismatch")
            private_path(root / sub)
        trusted = True
        stage = "barrier"
        barrier(manifest, root, phase)
        partial["helper"] = process_identity(os.getpid())
        stage = "socket"
        address = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
        inode = socket_proof(root, address)
        partial["socket_inode"], partial["socket_uid"] = inode, os.getuid()
        stage = "bus_query"
        send = manifest["dbus_send"]
        bus_id = dbus(send, address, "GetId")
        bus_pid = dbus(send, address, "GetConnectionUnixProcessID", "org.freedesktop.DBus")
        partial["bus_id"] = bus_id
        stage = "bus_identity"
        bus = process_identity(bus_pid)
        partial["bus"] = bus
        partial["bus_observed"] = True
        stage = "bus_ledger"
        save_partial()
        stage = "bus_identity"
        need(descendant(bus_pid, os.getppid()), "bus not owned runner child", "identity_changed")
        stage = "bus_pin"
        bus_handle = pid_handle(bus)
        partial["bus_pinned"] = True
        stage = "bus_ledger"
        save_partial()
        stage = "keyring_metadata"
        need(keyring_metadata(manifest["keyring"]["path"], manifest["keyring"]["override"]) == manifest["keyring"],
             "keyring executable changed", "identity_changed")
        stage = "keyring_spawn"
        daemon = subprocess.Popen([manifest["keyring"]["path"], "--foreground", "--components=secrets",
                   "--control-directory=" + str(root / "runtime/control"), "--unlock"],
                   stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        partial["keyring_pid"] = daemon.pid
        stage = "keyring_ledger"
        save_partial()
        stage = "keyring_identity"
        keyring = process_identity(daemon.pid)
        partial["keyring"] = keyring
        partial["keyring_observed"] = True
        stage = "keyring_ledger"
        save_partial()
        stage = "keyring_identity"
        need(keyring["ppid"] == os.getpid(), "keyring direct child mismatch", "identity_changed")
        if manifest["keyring"]["override"]:
            need(keyring["exe"] == manifest["keyring"]["resolved"], "keyring executable mismatch", "identity_changed")
        stage = "keyring_pin"
        keyring_handle = pid_handle(keyring)
        partial["keyring_pinned"] = True
        stage = "keyring_ledger"
        save_partial()
        # No password or service readiness work before full child identity/pinning.
        stage = "password_feed"
        daemon.stdin.write(DUMMY_PASSWORD)
        daemon.stdin.close()
        stage = "service_wait"
        deadline = time.monotonic() + 20
        owner_name = None
        while time.monotonic() < deadline:
            need(daemon.poll() is None, "keyring exited during startup", "startup_exit")
            try:
                owner_name = dbus(send, address, "GetNameOwner", "org.freedesktop.secrets")
                break
            except AcceptanceError:
                time.sleep(0.05)
        need(owner_name is not None, "keyring readiness deadline", "readiness_timeout")
        stage = "owner_query"
        owner_pid = dbus(send, address, "GetConnectionUnixProcessID", owner_name)
        owner_uid = dbus(send, address, "GetConnectionUnixUser", owner_name)
        stage = "owner_match"
        need(owner_pid == daemon.pid and owner_uid == os.getuid() and identical(keyring) and
             descendant(owner_pid, os.getpid()), "keyring owner differs from exact foreground child", "owner_mismatch")
        owner = keyring
        identities = {"version": 1, "phase": phase, "ready": True, "bus": bus, "owner": owner,
                      "bus_id": bus_id, "owner_name": owner_name, "socket_inode": inode,
                      "socket_uid": os.getuid(), "helper": partial["helper"], "test": None}
        ledger_schema(identities, phase, "complete", root, manifest["executable_sha256"])
        stage = "native_ledger"
        write_record(root / ("identities-" + phase + ".json"), identities)
        grant = {"nonce": manifest["nonce"], "root": str(root), "prefix": manifest["prefix"],
                 "refs": manifest["refs"], "phase": phase, "address": address,
                 "bus_id": bus_id, "socket": str(root / "runtime/bus"), "socket_inode": inode,
                 "bus_pid": bus_pid, "bus_start": bus["start"], "bus_exe": bus["exe"],
                 "owner": owner_name, "owner_pid": owner_pid, "owner_start": owner["start"],
                 "owner_exe": owner["exe"], "uid": os.getuid()}
        payload = json.dumps(grant, separators=(",", ":")).encode()
        write_private(root / "capability.json", payload)
        need(dbus(send, address, "GetId") == bus_id and
             dbus(send, address, "GetNameOwner", "org.freedesktop.secrets") == owner_name and
             dbus(send, address, "GetConnectionUnixProcessID", owner_name) == daemon.pid and
             dbus(send, address, "GetConnectionUnixUser", owner_name) == os.getuid() and
             identical(owner) and identical(bus) and socket_proof(root, address) == inode,
             "identity changed before native grant", "identity_changed")
        need(hashlib.sha256(Path(manifest["executable"]).read_bytes()).hexdigest() == manifest["executable_sha256"],
             "acceptance executable changed", "identity_changed")
        stage = "native_spawn"
        proof = native_diagnostic.open()
        native_env = dict(os.environ)
        native_env[DIAGNOSTIC_ENV] = proof
        test = subprocess.Popen([manifest["executable"]], stdin=subprocess.PIPE,
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                 env=native_env, pass_fds=(native_diagnostic.writer,))
        partial["test_pid"] = test.pid
        native_diagnostic.close_writer()
        stage = "native_ledger"
        save_partial()
        stage = "native_identity"
        test_identity = process_identity(test.pid)
        partial["test"] = test_identity
        partial["test_observed"] = True
        stage = "native_ledger"
        save_partial()
        stage = "native_identity"
        need(test_identity["ppid"] == os.getpid(), "test direct child mismatch", "identity_changed")
        stage = "native_pin"
        test_handle = pid_handle(test_identity)
        partial["test_pinned"] = True
        stage = "native_ledger"
        save_partial()
        identities["test"] = test_identity
        ledger_schema(identities, phase, "complete", root, manifest["executable_sha256"])
        write_record(root / ("identities-" + phase + ".json"), identities)
        stage = "native_wait"
        try:
            test.communicate(input=payload, timeout=100)
        except subprocess.TimeoutExpired:
            raise AcceptanceError("acceptance phase deadline", "native_timeout") from None
        need(test.returncode == 0, "acceptance test failed",
             "native_signal" if test.returncode < 0 else "native_exit_nonzero")
        need(gone(test_identity), "acceptance child not reaped")
        stage = "result_check"
        report = bounded_json(root / ("report-" + phase + ".json"))
        need(type(report) is dict and report.get("passed") is True and report.get("phase") == phase,
             "missing phase proof")
        need(dbus(send, address, "GetId") == bus_id and
             dbus(send, address, "GetNameOwner", "org.freedesktop.secrets") == owner_name and
             dbus(send, address, "GetConnectionUnixProcessID", owner_name) == daemon.pid and
             dbus(send, address, "GetConnectionUnixUser", owner_name) == os.getuid() and
             identical(owner) and identical(bus) and socket_proof(root, address) == inode,
             "bus ownership changed during native phase", "identity_changed")
        phase_passed = True
    except Exception as error:
        primary_error = error
        primary = fixed_failure(stage, error)
    finally:
        # Close owned pipes independently before any ownership-gated stop attempt.
        if test is not None and test.stdin is not None:
            cleanup_attempt("test_stdin_close", test.stdin.close)
        if daemon is not None and daemon.stdin is not None:
            cleanup_attempt("keyring_stdin_close", daemon.stdin.close)
        # Each cleanup action is independent; cleanup never overwrites the primary error.
        cleanup_attempt("test_stop", lambda: stop_owned(test, test_identity, test_handle, "test_reaped"))
        def close_test_handles():
            failure = None
            try:
                native_diagnostic.close()
            except BaseException as error:
                failure = error
            if test_handle is not None:
                try:
                    os.close(test_handle)
                except BaseException as error:
                    if failure is None:
                        failure = error
            if failure is not None:
                raise failure
        try:
            native_diagnostic_result = native_diagnostic.collect(phase, test.returncode if test is not None else None)
        except Exception:
            native_diagnostic_result = {"status": "unreadable", "record": None}
        finally:
            cleanup_attempt("test_handle_close", close_test_handles)
        cleanup_attempt("keyring_stop", lambda: stop_owned(daemon, keyring, keyring_handle, "keyring_reaped"))
        if keyring_handle is not None:
            cleanup_attempt("keyring_handle_close", lambda: os.close(keyring_handle))
        def close_bus():
            if bus_handle is not None:
                os.close(bus_handle)
            facts["bus_handle_closed"] = True
        cleanup_attempt("bus_handle_close", close_bus)
        if trusted:
            # Retry evidence persistence only; do not reacquire identity or signal an unpinned PID.
            try:
                save_partial()
            except Exception:
                pass
            cleanup_attempt("cleanup_write", lambda: write_record(root / ("inside-cleanup-" + phase + ".json"),
                {"version": 1, "phase": phase, "phase_passed": phase_passed,
                 "test_reaped": facts["test_reaped"] is True,
                 "keyring_reaped": facts["keyring_reaped"] is True,
                 "bus_handle_closed": facts["bus_handle_closed"] is True}))
            if primary is not None or teardown:
                record = {"version": 2, "phase": phase, "passed": False, "primary": primary,
                          "teardown": teardown, "facts": facts,
                          "native_exit_status": test.returncode if test is not None else None,
                          "native_diagnostic": native_diagnostic_result}
                try:
                    helper_record_schema(record, phase)
                    write_record(root / ("helper-failure-" + phase + ".json"), record)
                except Exception:
                    pass
    if primary_error is not None:
        raise primary_error
    need(not teardown, "helper teardown failed")


def preflight(args):
    need(sys.platform.startswith("linux") and os.getuid() != 0 and os.getuid() == os.geteuid(),
         "Linux unprivileged same-UID runner required")
    need(hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"), "pidfd support required")
    need(Path(DBUS_RUN).is_file() and os.access(DBUS_RUN, os.X_OK), "missing confirmed executable")
    keyring = keyring_metadata(args.keyring_executable or KEYRING, args.keyring_executable is not None)
    keyring_schema(keyring)
    daemon = executable("dbus-daemon")
    send = executable("dbus-send")
    binary = Path(args.executable)
    need(binary.is_absolute() and binary.is_file() and not binary.is_symlink() and os.access(binary, os.X_OK),
         "absolute pinned acceptance executable required")
    # Flags are checked only by the parent after execution GO, in a scrubbed environment.
    help_env = {"PATH": "/run/current-system/sw/bin", "LANG": "C", "HOME": "/nonexistent",
                "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent/owned-help-bus",
                "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=/nonexistent/owned-help-system-bus"}
    help_text = subprocess.run([keyring["path"], "--help"], env=help_env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=5)
    flags = help_text.stdout + help_text.stderr
    need(help_text.returncode == 0 and all(option in flags for option in
         (b"--foreground", b"--components", b"--control-directory", b"--unlock")), "keyring flags unavailable")
    need(keyring_metadata(keyring["path"], keyring["override"]) == keyring, "keyring changed during preflight", "identity_changed")
    if args.library_path:
        for value in args.library_path.split(":"):
            directory = Path(value).resolve(strict=True)
            need(str(directory) == value and str(directory).startswith("/nix/store/") and directory.is_dir() and
                 directory.stat().st_uid == 0 and directory.stat().st_mode & 0o022 == 0,
                 "only immutable canonical Nix library directories allowed")
    return daemon, send, str(binary), keyring


def outside(args):
    os.umask(0o077)
    destination = Path(args.artifacts)
    destination_ready = False
    root = None
    artifact = {"limits": LIMITS, "phases": [], "diagnostics": [], "ledgers": [],
                "outcomes": [], "cleanup_proved": False, "passed": False}
    outer_failure = reported_primary = terminal = None
    stage = "artifact_check"
    try:
        daemon, send, binary, keyring = preflight(args)
        need(destination.is_absolute(), "absolute artifacts directory required")
        fresh_artifacts(args.artifacts)
        destination_ready = True
        pinned = destination / "vela-native-vault-acceptance"
        write_private(pinned, Path(binary).read_bytes())
        pinned.chmod(0o700)
        binary = str(pinned)
        binary_hash = hashlib.sha256(pinned.read_bytes()).hexdigest()
        artifact.update(executable_sha256=binary_hash, keyring=keyring)
        stage = "root"
        root = Path(tempfile.mkdtemp(prefix="vela-owned-vault-", dir="/tmp"))
        artifact["owned_root"] = str(root)
        private_path(root)
        for sub in ("home", "data", "config", "cache", "runtime", "launcher", "runtime/control"):
            (root / sub).mkdir(mode=0o700)
        for case in CASES:
            (root / "launcher" / case).mkdir(mode=0o700)
        stage = "manifest"
        nonce = secrets.token_hex(16)
        prefix = secrets.token_hex(4)
        refs = [prefix + secrets.token_hex(12) for _ in range(11)]
        manifest = {"nonce": nonce, "prefix": prefix, "refs": refs, "dbus_send": send,
                    "executable": binary, "executable_sha256": binary_hash, "keyring": keyring}
        manifest_schema(manifest)
        write_private(root / "nonce", nonce.encode())
        write_record(root / "manifest.json", manifest)
        # No includes/service directories: no desktop or user service activation.
        bus_config = ('<busconfig><type>session</type><listen>unix:path=' + str(root / "runtime/bus") +
                      '</listen><auth>EXTERNAL</auth><policy context="default">'
                      '<allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/>'
                      '</policy></busconfig>')
        write_private(root / "bus.conf", bus_config.encode())
        clean = clean_env(root, args.library_path)
        last_bus_id = None
        stage = "artifact_check"
        for phase in ("seed", "recover", "cleanup"):
            terminal = {"phase": phase, "outcome": "runner_failed", "wrapper_exit_status": None,
                        "phase_passed": False, "teardown_proved": False, "primary": None, "teardown": []}
            artifact["outcomes"].append(terminal)
            proc = identity = handle = None
            code = None
            primary_error = None
            wrapper_record = None

            def save_wrapper():
                ledger_schema(wrapper_record, phase, "wrapper", root, binary_hash)
                write_record(root / ("wrapper-" + phase + ".json"), wrapper_record)

            try:
                stage = "keyring_metadata"
                need(keyring_metadata(keyring["path"], keyring["override"]) == keyring,
                     "keyring changed before owned phase", "identity_changed")
                need(hashlib.sha256(pinned.read_bytes()).hexdigest() == binary_hash,
                     "acceptance executable changed", "identity_changed")
                command = [DBUS_RUN, "--dbus-daemon=" + daemon, "--config-file=" + str(root / "bus.conf"),
                           "--", sys.executable, str(Path(__file__).resolve()), "--inside-bus",
                           "--owned-root", str(root), "--phase", phase]
                stage = "wrapper_identity"
                proc = subprocess.Popen(command, env=clean, start_new_session=True,
                                        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                wrapper_record = {"version": 1, "phase": phase, "ready": False, "direct_popen": True,
                                  "child_pid": proc.pid, "parent_pid": os.getpid(), "wrapper": None,
                                  "observed": False, "pinned": False, "expected_socket": str(root / "runtime/bus"),
                                  "executable_sha256": binary_hash}
                stage = "wrapper_ledger"
                save_wrapper()
                stage = "wrapper_identity"
                identity = process_identity(proc.pid)
                wrapper_record["wrapper"] = identity
                wrapper_record["observed"] = True
                stage = "wrapper_ledger"
                save_wrapper()
                stage = "wrapper_identity"
                need(identity["ppid"] == os.getpid() and identity["pgid"] == proc.pid and identity["sid"] == proc.pid,
                     "owned wrapper lineage mismatch", "identity_changed")
                stage = "wrapper_pin"
                handle = pid_handle(identity)
                wrapper_record["pinned"] = True
                stage = "wrapper_ledger"
                save_wrapper()
                stage = "wrapper_grant"
                need(identical(identity), "owned wrapper changed before grant", "identity_changed")
                token = json.dumps({"version": 1, "phase": phase, "nonce": nonce, "wrapper_pid": proc.pid},
                                   separators=(",", ":")).encode()
                need(len(token) < BARRIER_LIMIT, "barrier exceeds bound", "barrier_invalid")
                proc.stdin.write(token)
                proc.stdin.close()
                stage = "wrapper_wait"
                try:
                    code = proc.wait(timeout=140)
                except subprocess.TimeoutExpired:
                    raise AcceptanceError("owned bus phase deadline", "wrapper_timeout") from None
                terminal["wrapper_exit_status"] = code
                need(gone(identity), "dbus-run-session not reaped")
            except Exception as error:
                primary_error = error
                terminal["primary"] = fixed_failure(stage, error)
            finally:
                # Close an ungranted barrier; the helper must reject EOF/malformed input.
                if proc is not None and proc.stdin is not None and not proc.stdin.closed:
                    try:
                        proc.stdin.close()
                    except Exception:
                        pass
                if proc is not None:
                    try:
                        need(identity is not None and handle is not None, "wrapper ownership not pinned", "ownership_unproved")
                        stop_child(proc, identity, handle)
                        terminal["wrapper_exit_status"] = proc.returncode
                    except Exception as error:
                        terminal["teardown"].append(fixed_failure("wrapper_stop", error))
                if handle is not None:
                    try:
                        os.close(handle)
                    except Exception as error:
                        terminal["teardown"].append(fixed_failure("wrapper_handle_close", error))
                if wrapper_record is not None:
                    try:
                        save_wrapper()
                    except Exception:
                        pass
                # Retain validated partial evidence before requiring complete readiness.
                records = [collect_record(root, phase, kind, binary_hash)
                           for kind in ("wrapper", "partial", "complete", "native", "helper")]
                for entry in records:
                    artifact["diagnostics" if entry["origin"] in ("native", "helper") else "ledgers"].append(entry)
                    if entry["record_status"] == "valid":
                        prefix_name = {"wrapper": "wrapper-", "partial": "ledger-", "complete": "identities-",
                                       "native": "failure-", "helper": "helper-failure-"}[entry["origin"]]
                        entry["retained"] = False
                        try:
                            write_record(destination / (prefix_name + phase + ".json"), entry["record"])
                            entry["retained"] = True
                        except Exception as error:
                            entry["retention_failure"] = fixed_failure("record_retention", error)
            stage = "artifact_check"
            helper_entry = next(entry for entry in records if entry["origin"] == "helper")
            native_entry = next(entry for entry in records if entry["origin"] == "native")
            reported_primary = None
            if helper_entry["record_status"] == "valid":
                helper_primary = helper_entry["record"]["primary"]
                if helper_primary is not None:
                    reported_primary = dict(helper_primary)
            if native_entry["record_status"] == "valid" and (
                    reported_primary is None or reported_primary["stage"] in ("native_wait", "result_check")):
                native_primary = native_entry["record"]
                reported_primary = {"stage": native_primary["stage"], "class": native_primary["class"]}
            if reported_primary is None and helper_entry["record_status"] == "valid" and helper_entry["record"]["teardown"]:
                reported_primary = dict(helper_entry["record"]["teardown"][0])
            if reported_primary is not None:
                original_primary = terminal["primary"]
                if original_primary is not None and original_primary != reported_primary:
                    terminal["teardown"].append(original_primary)
                terminal["primary"] = dict(reported_primary)
                terminal["outcome"] = reported_primary["class"]
            if primary_error is not None:
                if reported_primary is None:
                    terminal["outcome"] = terminal["primary"]["class"]
                    stage = terminal["primary"]["stage"]
                raise primary_error
            need(not terminal["teardown"], "wrapper teardown failed")
            proof_entry = next(entry for entry in records if entry["origin"] == "complete")
            need(proof_entry["record_status"] == "valid", "missing complete owned process proof", "ownership_unproved")
            proof = proof_entry["record"]
            need(identity is not None and proof["helper"]["ppid"] == identity["pid"] and
                 proof["helper"]["pgid"] == identity["pgid"] and proof["helper"]["sid"] == identity["sid"],
                 "helper lineage proof mismatch", "identity_changed")
            need(gone(proof["owner"]) and gone(proof["bus"]) and gone(proof["helper"]), "service process still present")
            if proof["test"] is not None:
                need(gone(proof["test"]), "native process still present")
            need(proof["bus_id"] != last_bus_id, "bus was not restarted")
            last_bus_id = proof["bus_id"]
            inside_proof = bounded_json(root / ("inside-cleanup-" + phase + ".json"))
            exact_keys(inside_proof, ("version", "phase", "phase_passed", "test_reaped", "keyring_reaped", "bus_handle_closed"))
            need(type(inside_proof["version"]) is int and inside_proof["version"] == 1 and inside_proof["phase"] == phase and
                 all(type(inside_proof[name]) is bool for name in ("phase_passed", "test_reaped", "keyring_reaped", "bus_handle_closed")),
                 "cleanup proof schema rejected")
            need(inside_proof["keyring_reaped"] and inside_proof["test_reaped"] and inside_proof["bus_handle_closed"],
                 "child teardown incomplete")
            need(not group_members(identity["pgid"], identity["sid"]), "owned process group still populated")
            socket_path = root / "runtime/bus"
            need(not socket_path.exists(), "bus socket still present")
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                probe.settimeout(1)
                try:
                    probe.connect(str(socket_path))
                except (FileNotFoundError, ConnectionRefusedError):
                    pass
                else:
                    raise AcceptanceError("bus socket still accepts connections")
            finally:
                probe.close()
            terminal["teardown_proved"] = True
            write_record(destination / ("cleanup-" + phase + ".json"),
                         {"wrapper_reaped": True, "owned_group_empty": True, "child_proof": inside_proof})
            need(reported_primary is None, "reported phase failure", "native_exit_nonzero")
            need(code == 0 and inside_proof["phase_passed"], "native phase failed")
            # Partial ledgers never contribute a passed phase or cleanup proof.
            phase_report = bounded_json(root / ("report-" + phase + ".json"))
            need(type(phase_report) is dict and phase_report.get("phase") == phase and phase_report.get("passed") is True,
                 "phase report rejected")
            terminal["phase_passed"] = True
            artifact["phases"].append(phase_report)
            snapshot(root, destination / phase)
            terminal["outcome"] = "passed"
        artifact["cleanup_proved"] = True
        artifact["passed"] = True
    except Exception as error:
        # Finite labels only; never exception messages, child output or environment.
        outer_failure = error
        observed_failure = fixed_failure(stage, error)
        artifact["failure"] = dict(reported_primary) if reported_primary is not None else observed_failure
        if terminal is not None:
            if reported_primary is not None and observed_failure != reported_primary and observed_failure not in terminal["teardown"]:
                terminal["teardown"].append(observed_failure)
            terminal["primary"] = dict(artifact["failure"])
            terminal["outcome"] = artifact["failure"]["class"]
    finally:
        if root is not None:
            if artifact["passed"] and artifact["cleanup_proved"]:
                try:
                    shutil.rmtree(root)
                    need(not root.exists(), "owned home removal unproved", "ownership_unproved")
                    artifact["owned_home_removed"] = True
                except Exception as error:
                    artifact["cleanup_failure"] = fixed_failure("root_remove", error)
                    artifact["passed"] = False
                    artifact["owned_home_removed"] = False
                    artifact["quarantined"] = True
                    if "failure" not in artifact:
                        artifact["failure"] = dict(artifact["cleanup_failure"])
                    if outer_failure is None:
                        outer_failure = error
            else:
                artifact["quarantined"] = True
        if not destination_ready:
            try:
                print("FAIL", artifact["failure"]["stage"], artifact["failure"]["class"])
            except Exception:
                pass
            return 1
        try:
            write_private(destination / "result.json", json.dumps(artifact, indent=2).encode())
        except Exception as error:
            artifact["retention_failure"] = fixed_failure("record_retention", error)
            artifact["passed"] = False
            owned_root = None
            if root is not None:
                candidate = str(root)
                if len(candidate) <= 64 and re.fullmatch(r"/tmp/vela-owned-vault-[a-z0-9_]{8}", candidate) is not None:
                    owned_root = candidate
            fallback = {"version": 1, "owned_root": owned_root,
                        "quarantined": artifact.get("quarantined") is True,
                        "cleanup_proved": artifact.get("cleanup_proved") is True,
                        "owned_home_removed": artifact.get("owned_home_removed") is True,
                        "passed": False,
                        "primary": dict(artifact["failure"]) if "failure" in artifact else None,
                        "retention_failure": dict(artifact["retention_failure"])}
            try:
                print("FAIL", json.dumps(fallback, separators=(",", ":"), allow_nan=False))
            except Exception:
                pass
            if outer_failure is not None:
                raise outer_failure
            return 1
    print("PASS" if artifact["passed"] else "FAIL")
    return 0 if artifact["passed"] else 1


def main():
    class FiniteParser(argparse.ArgumentParser):
        def error(self, message):
            raise AcceptanceError("command line rejected")
    parser = FiniteParser(description=__doc__)
    parser.add_argument("--executable")
    parser.add_argument("--artifacts")
    parser.add_argument("--library-path", default="")
    parser.add_argument("--keyring-executable", help="Explicit immutable Nix ELF keyring executable; default is the installed wrapper")
    parser.add_argument("--inside-bus", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--owned-root", help=argparse.SUPPRESS)
    parser.add_argument("--phase", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.inside_bus:
        try:
            inside(args)
            return 0
        except Exception:
            return 1
    need(args.executable is not None and args.artifacts is not None, "explicit executable/artifacts required")
    return outside(args)

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except BaseException as error:
        try:
            print("FAIL", fixed_failure("artifact_check", error)["class"])
        except Exception:
            pass
        raise SystemExit(1)
