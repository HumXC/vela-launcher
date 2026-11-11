#!/usr/bin/env python3
"""Verify and launch an extracted release using isolated data and software rendering."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--platform", required=True, choices=("linux", "windows", "macos"))
    parser.add_argument("--arch", required=True, choices=("x86_64", "aarch64"))
    args = parser.parse_args()
    name = f"vela-{args.version}-{args.platform}-{args.arch}"
    archive = Path("dist") / (name + (".zip" if args.platform == "windows" else ".tar.gz"))
    checksum = Path(str(archive) + ".sha256").read_text().split()
    if checksum != [hashlib.sha256(archive.read_bytes()).hexdigest(), archive.name]:
        raise RuntimeError("Archive checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="vela-smoke-") as temporary:
        # macOS temporary paths can contain /var aliases; pass the canonical root.
        root = Path(temporary).resolve()
        if args.platform == "windows":
            with zipfile.ZipFile(archive) as zipped:
                for member in zipped.namelist():
                    if not (root / member).resolve().is_relative_to(root.resolve()):
                        raise RuntimeError("Unsafe ZIP member")
                zipped.extractall(root)
        else:
            with tarfile.open(archive) as tar:
                for member in tar.getmembers():
                    if not (member.isfile() or member.isdir()) or not (root / member.name).resolve().is_relative_to(root.resolve()):
                        raise RuntimeError("Unsafe tar member")
                tar.extractall(root)
        directory = root / name
        metadata = json.loads((directory / "build-info.json").read_text())
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        if metadata["version"] != args.version or metadata["commit"] != commit:
            raise RuntimeError("Packaged version or commit mismatch")
        if (directory / "VERSION").read_text().strip() != args.version:
            raise RuntimeError("VERSION mismatch")
        executable = directory / ("vela.exe" if args.platform == "windows" else "vela")
        if args.platform == "macos":
            executable = directory / "Vela.app/Contents/MacOS/vela"
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(directory / "Vela.app")], check=True)
        fonts = {
            "linux": [Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")],
            "windows": [Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts/arial.ttf"],
            "macos": [Path("/System/Library/Fonts/Supplemental/Arial.ttf"), Path("/System/Library/Fonts/Helvetica.ttc")],
        }[args.platform]
        font = next((path for path in fonts if path.is_file()), None)
        if font is None:
            raise RuntimeError("No smoke-test font found")
        env = os.environ.copy()
        for key in ("VELA_DATA_DIR", "LD_LIBRARY_PATH", "LD_PRELOAD"):
            env.pop(key, None)
        env.update(SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy", SDL_RENDER_DRIVER="software", VELA_FONT_PATH=str(font))
        data = root / "user data"
        with subprocess.Popen([str(executable), "--data-dir", str(data)], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
            try:
                log, _ = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                log, _ = process.communicate(timeout=10)
                print(log.decode("utf-8", errors="replace"))
                if not data.is_dir():
                    raise RuntimeError("Launcher did not create its isolated data directory")
            else:
                print(log.decode("utf-8", errors="replace"))
                raise RuntimeError(f"Launcher exited before smoke timeout: {process.returncode}")
        print(f"Packaged {args.platform}/{args.arch} startup passed")


if __name__ == "__main__":
    main()
