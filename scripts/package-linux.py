#!/usr/bin/env python3
"""Validate release versions and package an Ubuntu-built Linux executable."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile


def version_tag(value):
    version = value.removeprefix("v")
    number = r"(?:0|[1-9][0-9]*)"
    pattern = rf"{number}[.]{number}[.]{number}(?:-([0-9A-Za-z-]+(?:[.][0-9A-Za-z-]+)*))?"
    match = re.fullmatch(pattern, version)
    if not match:
        raise ValueError("Use MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-prerelease, optionally prefixed with v")
    if match[1] and any(part.isdigit() and len(part) > 1 and part.startswith("0") for part in match[1].split(".")):
        raise ValueError("Numeric prerelease identifiers must not contain leading zeroes")
    return "v" + version


def inspect_elf(binary):
    headers = subprocess.check_output(["readelf", "-h", "-l", "-d", "-W", str(binary)], text=True)
    versions = subprocess.check_output(["readelf", "--version-info", "-W", str(binary)], text=True)
    if "Advanced Micro Devices X86-64" not in headers:
        raise ValueError("Expected an x86_64 ELF executable")
    if "[Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]" not in headers:
        raise ValueError("Expected the standard Linux glibc interpreter")
    if "/nix/store/" in headers:
        raise ValueError("ELF loader or dynamic paths reference the Nix store")
    required = {tuple(map(int, value.split("."))) for value in re.findall(r"GLIBC_([0-9]+(?:[.][0-9]+)+)", versions)}
    if not required or max(required) > (2, 35):
        raise ValueError(f"Expected glibc <= 2.35, found {sorted(required)}")
    return ".".join(map(str, max(required)))


def package(binary, output, tag):
    binary = binary.resolve(strict=True)
    glibc = inspect_elf(binary)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    zig_version = subprocess.check_output(["zig", "version"], text=True).strip()
    name = f"vela-{tag}-linux-x86_64"
    output.mkdir(parents=True, exist_ok=True)
    archive = output / (name + ".tar.gz")
    checksum = output / (name + ".tar.gz.sha256")
    if archive.exists() or checksum.exists():
        raise ValueError("Refusing to overwrite an existing package")
    with tempfile.TemporaryDirectory(prefix="vela-package-") as temporary:
        directory = Path(temporary) / name
        directory.mkdir()
        shutil.copy2(binary, directory / "vela")
        (directory / "vela").chmod(0o755)
        (directory / "VERSION").write_text(tag + "\n", encoding="utf-8")
        metadata = {"version": tag, "commit": commit, "zig": zig_version,
                    "target": "x86_64-linux-gnu.2.35", "cpu": "baseline",
                    "optimize": "ReleaseSmall", "required_glibc": glibc}
        (directory / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(directory, arcname=name)
    checksum.write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n", encoding="utf-8")
    print(archive)
    print(checksum)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--binary", type=Path, default=Path("zig-out/bin/vela"))
    parser.add_argument("--output", type=Path, default=Path("dist"))
    args = parser.parse_args()
    try:
        tag = version_tag(args.version)
        if args.validate_only:
            print(tag)
        else:
            package(args.binary, args.output, tag)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release packaging failed: {error}\n")


if __name__ == "__main__":
    main()
