#!/usr/bin/env python3
"""Verify the actual Zig manifest-filtered source package, not the checkout."""
import argparse
import os
import tarfile
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--pkg-dir", type=Path, help="Existing dependency package directory")
    parser.add_argument("--cache-dir", type=Path, help="Optional reusable build cache")
    parser.add_argument("--macos-sdk", type=Path, help="Existing macOS SDK (required on macOS)")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    dependencies = (args.pkg_dir or source / "zig-pkg").resolve()
    with tempfile.TemporaryDirectory(prefix="vela-source-package-") as directory:
        scratch = Path(directory)
        fetch_cache = scratch / "fetch-cache"
        fetch_env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(fetch_cache))
        # Zig 0.17 fetch writes a manifest-filtered tarball into its global cache.
        # Its --pkg-dir option does not materialize a directory for this command.
        fetched = subprocess.run([args.zig, "fetch", str(source)], check=True, text=True, stdout=subprocess.PIPE, env=fetch_env)
        package_hash = fetched.stdout.strip()
        if not package_hash or Path(package_hash).name != package_hash:
            raise RuntimeError("zig fetch returned an invalid package hash: " + repr(package_hash))
        package = scratch / package_hash
        package.mkdir()
        archive = fetch_cache / "p" / (package_hash + ".tar.gz")
        with tarfile.open(archive, "r:gz") as bundle:
            # Zig prefixes archive members with the package hash.
            bundle.extractall(scratch, filter="data")
        required = ["build.zig", "build.zig.zon", "ui_layout_test_build.zig", "BUILDING.md", "build-support/dependencies.zig", "build-support/test_suites.zig", "src/app.zig", "scripts/test-safe-archive.py", "scripts/test-downloader.py", "scripts/test-http-transport.py", "scripts/test-public-network.py"]
        missing = [name for name in required if not (package / name).is_file()]
        if missing:
            raise RuntimeError("Source package is incomplete: " + ", ".join(missing))
        forbidden = [name for name in (".git", ".envrc", ".zig-cache", "zig-out", "zig-pkg", "scripts/__pycache__") if (package / name).exists()]
        if forbidden:
            raise RuntimeError("Source package contains local state: " + ", ".join(forbidden))
        cache = args.cache_dir.resolve() if args.cache_dir else scratch / "build-cache"
        command = [args.zig, "build", "--pkg-dir", str(dependencies), "--cache-dir", str(cache), "--prefix", str(scratch / "install"), "-j2", "-Dpython=" + sys.executable]
        if args.macos_sdk is not None:
            command.append("-Dmacos-sdk=" + str(args.macos_sdk.resolve()))
        print("Checking fetched source package:", package_hash, flush=True)
        subprocess.run([*command, "--help"], cwd=package, check=True, stdout=subprocess.DEVNULL)
        subprocess.run([*command, "compile-app", "test-safe-archive", "--summary", "all"], cwd=package, check=True)
        print("Source package configuration, application build and archive fixtures passed.", flush=True)


if __name__ == "__main__":
    main()
