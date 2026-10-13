#!/usr/bin/env python3
"""Render Vela's real Zig/DVUI views in a disposable Linux Wayland session."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parent.parent
SCENES = {
    "home": ("home", "主页"),
    "game-selection": ("versions", "游戏选择"),
    "more": ("more", "更多"),
    "accounts": ("player", "账户选择"),
    "account-add": ("account-add", "添加账户弹窗"),
    "instances": ("instances", "实例管理"),
    "worlds": ("worlds", "存档管理"),
    "java": ("java", "Java 下载入口"),
    "servers": ("servers", "服务器管理"),
    "logs": ("logs", "日志"),
    "settings": ("settings", "设置"),
    "shutdown": ("shutdown", "退出确认弹窗"),
}
MOCK_SCENES = {
    "account-add": "添加账户", "account-offline": "编辑离线账户",
    "account-microsoft": "编辑微软账户", "account-delete": "删除账户",
    "account-signout": "退出登录", "account-code": "微软登录验证码", "account-wait": "微软登录等待授权",
    "instance-delete": "永久删除实例", "instance-unsaved": "实例未保存更改确认",
    "instance-task": "实例任务详情", "dialog": "自定义文本弹窗",
    "controls": "表单与通用控件", "selection-card": "选择卡片",
}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def group_members(pgid):
    result = subprocess.run(["ps", "-eo", "pid=,pgid="], capture_output=True, text=True, check=True)
    return [int(row.split()[0]) for row in result.stdout.splitlines()
            if len(row.split()) == 2 and int(row.split()[1]) == pgid]


class Pointer:
    """One virtual pointer, always bound to the newly created private socket."""
    def __init__(self, endpoint):
        if not stat.S_ISSOCK(endpoint.stat().st_mode):
            raise RuntimeError("Private Wayland endpoint is not a socket")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(3)
        self.sock.connect(str(endpoint))
        self.request(1, 1, self.uints(2))  # wl_display.get_registry
        self.request(1, 0, self.uints(3))  # wl_display.sync
        manager = None
        while True:
            obj, opcode, data = self.receive()
            if obj == 2 and opcode == 0:
                name, length = struct.unpack_from("<II", data)
                interface = data[8:8 + length - 1].decode()
                version = struct.unpack_from("<I", data, 8 + ((length + 3) // 4) * 4)[0]
                if interface == "zwlr_virtual_pointer_manager_v1":
                    manager = (name, version)
            if obj == 3 and opcode == 0:
                break
        if manager is None:
            self.sock.close()
            raise RuntimeError("Private compositor lacks virtual pointer support")
        interface = b"zwlr_virtual_pointer_manager_v1\0"
        encoded = self.uints(len(interface)) + interface + b"\0" * (-len(interface) % 4)
        self.request(2, 0, self.uints(manager[0]) + encoded + self.uints(min(2, manager[1]), 4))
        self.request(4, 0, self.uints(0, 5))

    @staticmethod
    def uints(*values):
        return struct.pack("<" + "I" * len(values), *values)

    def request(self, obj, opcode, data=b""):
        self.sock.sendall(self.uints(obj, ((len(data) + 8) << 16) | opcode) + data)

    def read_exact(self, length):
        result = b""
        while len(result) < length:
            chunk = self.sock.recv(length - len(result))
            if not chunk:
                raise RuntimeError("Private Wayland connection closed")
            result += chunk
        return result

    def receive(self):
        obj, word = struct.unpack("<II", self.read_exact(8))
        size = word >> 16
        if not 8 <= size <= 65535:
            raise RuntimeError("Invalid Wayland event size")
        return obj, word & 65535, self.read_exact(size - 8)

    def event(self, opcode, *values):
        stamp = int(time.monotonic() * 1000) & 0xffffffff
        self.request(5, opcode, self.uints(stamp, *values))
        self.request(5, 4)  # frame

    def move(self, x, y):
        # The compositor output is 1280x720; compact fixture bounds are cropped.
        self.event(1, x, y, 1280, 720)

    def click(self, x, y):
        self.move(x, y)
        time.sleep(0.15)
        self.event(2, 272, 1)
        time.sleep(0.1)
        self.event(2, 272, 0)

    def scroll(self, x, y, delta):
        self.move(x, y)
        self.event(3, 0, int(delta * 256) & 0xffffffff)

    def close(self):
        self.sock.close()


def validated_actions(path, width, height):
    actions = json.loads(path.read_text()) if path else []
    if not isinstance(actions, list) or len(actions) > 64:
        raise ValueError("Actions must be a JSON array with at most 64 steps")
    for action in actions:
        if not isinstance(action, dict):
            raise ValueError("Each action must be an object")
        op = action.get("op")
        fields = {"click": {"op", "x", "y"}, "scroll": {"op", "x", "y", "delta"},
                  "key": {"op", "key"}, "wait": {"op", "seconds"}}
        if op not in fields or set(action) != fields[op]:
            raise ValueError("Invalid action fields: " + str(op))
        if op in ("click", "scroll"):
            if (type(action["x"]) is not int or type(action["y"]) is not int or
                    not 0 <= action["x"] < width or not 0 <= action["y"] < height):
                raise ValueError("Action coordinates are outside fixture bounds")
        if op == "scroll" and (type(action["delta"]) not in (int, float) or
                                not math.isfinite(action["delta"]) or abs(action["delta"]) > 2000):
            raise ValueError("Invalid scroll delta")
        if op == "key" and (not isinstance(action["key"], str) or
                             not action["key"].isalnum() or len(action["key"]) > 32):
            raise ValueError("Key must be a single keysym such as Tab, Return or Escape")
        if op == "wait" and (type(action["seconds"]) not in (int, float) or
                              not math.isfinite(action["seconds"]) or not 0 <= action["seconds"] <= 10):
            raise ValueError("Wait must be between 0 and 10 seconds")
    return actions


def capture(args):
    width, height = map(int, args.size.split("x"))
    actions = validated_actions(args.actions, width, height)
    if args.output and (args.output.exists() or args.output.is_symlink()):
        raise ValueError("Output already exists; choose a new filename")
    tools = {name: shutil.which(name) for name in ("zig", "cage", "grim", "wtype", "fc-match", "ps")}
    missing = [name for name, path in tools.items() if not path]
    if missing:
        raise RuntimeError("Missing tools in prepared environment: " + ", ".join(missing))
    root = Path(tempfile.mkdtemp(prefix="vela-ui-shot.", dir="/tmp"))
    for name in ("runtime", "data", "config", "cache", "state", "fixture", "artifacts"):
        (root / name).mkdir(mode=0o700)
    artifacts = root / "artifacts"
    print("截图目录：" + str(artifacts), file=sys.stderr, flush=True)
    if not args.no_build:
        with (artifacts / "build.log").open("w") as log:
            subprocess.run([tools["zig"], "build", "build-ui-preview" if args.mock else "build-gui-fixture", "-Doptimize=ReleaseSafe", "--summary", "failures"],
                           cwd=REPO, stdout=log, stderr=log, check=True, timeout=600)
    binary = REPO / ("zig-out/bin/vela-ui-preview" if args.mock else "zig-out/bin/vela-gui-fixture")
    if not binary.is_file():
        raise RuntimeError("Build the requested UI executable first")
    font = args.font or (Path(os.environ["VELA_FONT_PATH"]) if os.environ.get("VELA_FONT_PATH") else
                        Path(subprocess.check_output([tools["fc-match"], "-f", "%{file}", ":lang=zh-cn:weight=regular"], text=True)))
    font = font.resolve(strict=True)
    env = os.environ.copy()
    # No inherited production fixture profiles, portals or display connections.
    for key in list(env):
        if key.startswith(("VELA_FIXTURE_", "VELA_PREVIEW_")) or key in ("DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS"):
            env.pop(key)
    for key, name in (("XDG_RUNTIME_DIR", "runtime"), ("XDG_DATA_HOME", "data"),
                      ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state")):
        env[key] = str(root / name)
    env.update(WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER="pixman",
               SDL_VIDEODRIVER="wayland", SDL_AUDIODRIVER="dummy", VELA_FONT_PATH=str(font))
    if args.mock:
        env.update(VELA_PREVIEW_SCENE=args.scene, VELA_PREVIEW_STATE=args.state,
                   VELA_PREVIEW_VIEWPORT=args.size, VELA_PREVIEW_RECEIPT=str(artifacts / "mock-receipt.json"))
        if args.data:
            env["VELA_PREVIEW_DATA"] = str(args.data)
    else:
        env.update(VELA_FIXTURE_ROOT=str(root / "fixture"), VELA_FIXTURE_PANEL=SCENES[args.scene][0],
                   VELA_FIXTURE_VIEWPORT=args.size, VELA_FIXTURE_SCENE="layout")
    metadata = {"scene": args.scene, "state": args.state, "mock": args.mock, "viewport": args.size, "built": not args.no_build,
                "binary": str(binary), "binary_sha256": digest(binary), "font": str(font),
                "font_sha256": digest(font), "tools": tools, "actions": actions, "root": str(root),
                "sources": {str(path.relative_to(REPO)): digest(path) for path in
                            [*sorted((REPO / "src/ui").glob("*.zig")),
                             REPO / ("src/ui_preview.zig" if args.mock else "src/gui_acceptance.zig")]}}
    if args.data:
        metadata["data_file"] = str(args.data)
        metadata["data_sha256"] = digest(args.data)
    proc = None
    pointer = None
    remaining = []
    succeeded = False
    with (artifacts / "cage.log").open("w") as log:
        try:
            proc = subprocess.Popen([tools["cage"], "-d", "--", str(binary)], cwd=REPO,
                                    env=env, stdout=log, stderr=log, start_new_session=True)
            metadata.update(pid=proc.pid, pgid=proc.pid)
            deadline = time.monotonic() + 15
            endpoint = None
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError("Cage exited before UI was ready; inspect cage.log")
                candidates = [p for p in (root / "runtime").glob("wayland-*") if stat.S_ISSOCK(p.stat().st_mode)]
                if candidates:
                    endpoint = candidates[0]
                    break
                time.sleep(0.1)
            if endpoint is None or os.getpgid(proc.pid) != proc.pid:
                raise RuntimeError("Cannot confirm isolated Wayland session")
            env["WAYLAND_DISPLAY"] = endpoint.name
            metadata["display"] = endpoint.name
            time.sleep(args.settle)
            pointer = Pointer(endpoint)
            for action in actions:
                if proc.poll() is not None:
                    raise RuntimeError("UI exited during actions")
                op = action["op"]
                if op == "click":
                    pointer.click(action["x"], action["y"])
                elif op == "scroll":
                    pointer.scroll(action["x"], action["y"], action["delta"])
                elif op == "key":
                    subprocess.run([tools["wtype"], "-k", action["key"]], env=env, check=True, timeout=5)
                elif op == "wait":
                    time.sleep(action["seconds"])
                time.sleep(0.3)
            pointer.move(1, 1)
            time.sleep(0.5)
            image = artifacts / "screenshot.png"
            subprocess.run([tools["grim"], "-g", "0,0 " + args.size, str(image)], env=env, check=True, timeout=10)
            header = image.read_bytes()[:24]
            if (len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or
                    struct.unpack(">II", header[16:24]) != (width, height)):
                raise RuntimeError("Screenshot dimensions differ from fixture bounds")
            metadata.update(image=str(image), image_sha256=digest(image))
            if args.mock:
                receipt = json.loads((artifacts / "mock-receipt.json").read_text())
                if (receipt.get("mock") is not True or receipt.get("scene") != args.scene or
                        receipt.get("state") != args.state or receipt.get("business_services") != 0):
                    raise RuntimeError("Mock component receipt does not match requested scene")
                metadata["mock_receipt"] = receipt
            succeeded = True
        except Exception as error:
            metadata["error"] = str(error)
            raise
        finally:
            if pointer:
                pointer.close()
            if proc:
                pgid = proc.pid
                if pgid == os.getpgrp():
                    raise RuntimeError("Refusing to stop caller's process group")
                if group_members(pgid):
                    os.killpg(pgid, signal.SIGTERM)
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        pass
                    if group_members(pgid):
                        os.killpg(pgid, signal.SIGKILL)
                proc.wait(timeout=5)
                deadline = time.monotonic() + 3
                remaining = group_members(pgid)
                while remaining and time.monotonic() < deadline:
                    time.sleep(0.1)
                    remaining = group_members(pgid)
                metadata.update(returncode=proc.returncode, remaining_pids=remaining)
            metadata["captured"] = succeeded
            (artifacts / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    if remaining:
        raise RuntimeError("Capture completed but isolated processes remain: " + str(remaining))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("xb") as dest, image.open("rb") as source:
            shutil.copyfileobj(source, dest)
        metadata["copied_image"] = str(args.output.resolve())
        (artifacts / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"image": metadata.get("copied_image", str(image)), "evidence": str(artifacts),
                      "remaining_pids": remaining}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scene", nargs="?", choices=sorted(set(SCENES) | set(MOCK_SCENES)))
    parser.add_argument("--mock", action="store_true", help="Render a standalone Zig component with mock data")
    parser.add_argument("--state", default="default", help="Mock state such as long-text, disabled or failed")
    parser.add_argument("--data", type=Path, help="Read-only JSON mock component data")
    parser.add_argument("--list", action="store_true", help="List supported scenes without compiling")
    parser.add_argument("--size", choices=("1280x720", "640x400"), default="1280x720")
    parser.add_argument("--actions", type=Path, help="JSON steps: click, scroll, key, wait")
    parser.add_argument("--font", type=Path, help="Use a specific Chinese font for repeatable captures")
    parser.add_argument("--output", type=Path, help="Copy PNG to a new filename; existing files are preserved")
    parser.add_argument("--no-build", action="store_true", help="Use existing fixture binary; may show older code")
    parser.add_argument("--settle", type=float, default=2, help="Wait for initial rendering (0.5–10 seconds)")
    parser.add_argument("--_prepared", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    args.scene = args.scene or ("account-add" if args.mock else "home")
    if args.list:
        for scene, label in (MOCK_SCENES.items() if args.mock else ((scene, value[1]) for scene, value in SCENES.items())):
            print(scene + "\t" + label)
        return 0
    if args.scene not in (MOCK_SCENES if args.mock else SCENES):
        parser.error("Scene does not belong to the selected preview mode")
    if not args.mock and (args.state != "default" or args.data):
        parser.error("--state and --data require --mock")
    if not math.isfinite(args.settle) or not 0.5 <= args.settle <= 10:
        parser.error("--settle must be between 0.5 and 10 seconds")
    if sys.platform != "linux":
        parser.error("This native screenshot entry currently supports Linux only")
    for field in ("actions", "font", "output", "data"):
        path = getattr(args, field)
        if path is not None:
            setattr(args, field, path.resolve())
    if not args._prepared:
        forwarded = [args.scene, "--size", args.size, "--settle", str(args.settle), "--state", args.state]
        if args.mock:
            forwarded.append("--mock")
        for field in ("actions", "font", "output", "data"):
            if getattr(args, field) is not None:
                forwarded.extend(["--" + field, str(getattr(args, field))])
        if args.no_build:
            forwarded.append("--no-build")
        command = ["nix", "develop", "--command", "nix", "shell", "nixpkgs#cage", "nixpkgs#grim",
                   "nixpkgs#wtype", "nixpkgs#fontconfig", "nixpkgs#procps", "--command", "python3",
                   str(Path(__file__).resolve()), *forwarded, "--_prepared"]
        return subprocess.run(command, cwd=REPO).returncode
    try:
        capture(args)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("截图失败：" + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
