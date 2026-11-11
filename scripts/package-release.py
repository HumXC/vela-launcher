#!/usr/bin/env python3
"""Validate and package Linux, Windows and macOS releases."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import tarfile
import tempfile
import zipfile


def version_tag(value):
    version = value.removeprefix("v")
    number = r"(?:0|[1-9][0-9]*)"
    match = re.fullmatch(rf"{number}[.]{number}[.]{number}(?:-([0-9A-Za-z-]+(?:[.][0-9A-Za-z-]+)*))?", version)
    if not match:
        raise ValueError("Use MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-prerelease")
    if match[1] and any(p.isdigit() and len(p) > 1 and p.startswith("0") for p in match[1].split(".")):
        raise ValueError("Numeric prerelease identifiers must not contain leading zeroes")
    return "v" + version


def output(*args):
    return subprocess.check_output(args, text=True)


def inspect_elf(binary, arch):
    headers = output("readelf", "-h", "-l", "-d", "-W", str(binary))
    versions = output("readelf", "--version-info", "-W", str(binary))
    machine, interpreter = {
        "x86_64": ("Advanced Micro Devices X86-64", "/lib64/ld-linux-x86-64.so.2"),
        "aarch64": ("AArch64", "/lib/ld-linux-aarch64.so.1"),
    }[arch]
    if machine not in headers or "ELF64" not in headers:
        raise ValueError(f"Expected a 64-bit {arch} ELF executable")
    if f"[Requesting program interpreter: {interpreter}]" not in headers:
        raise ValueError("Expected the standard Linux glibc interpreter")
    if "/nix/store/" in headers or "(RPATH)" in headers or "(RUNPATH)" in headers:
        raise ValueError("Release ELF contains a build-specific library path")
    required = {tuple(map(int, v.split("."))) for v in re.findall(r"GLIBC_([0-9]+(?:[.][0-9]+)+)", versions)}
    if not required or max(required) > (2, 35):
        raise ValueError(f"Expected glibc <= 2.35, found {sorted(required)}")
    return {"required_glibc": ".".join(map(str, max(required)))}


def inspect_pe(binary, arch):
    data = binary.read_bytes()
    if data[:2] != b"MZ" or len(data) < 64:
        raise ValueError("Expected a Windows executable")
    pe = struct.unpack_from("<I", data, 60)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("Invalid PE signature")
    machine, sections = struct.unpack_from("<HH", data, pe + 4)
    if machine != {"x86_64": 0x8664, "aarch64": 0xAA64}[arch]:
        raise ValueError(f"Wrong PE architecture for {arch}")
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    if struct.unpack_from("<H", data, optional)[0] != 0x20B:
        raise ValueError("Expected PE32+")
    section_table = optional + optional_size

    def file_offset(rva):
        for index in range(sections):
            size, address, raw_size, pointer = struct.unpack_from("<IIII", data, section_table + index * 40 + 8)
            if address <= rva < address + max(size, raw_size):
                return pointer + rva - address
        raise ValueError(f"Unmapped PE RVA {rva:x}")

    imports = []
    import_rva = struct.unpack_from("<I", data, optional + 120)[0]
    if import_rva:
        descriptor = file_offset(import_rva)
        while any(data[descriptor:descriptor + 20]):
            start = file_offset(struct.unpack_from("<I", data, descriptor + 12)[0])
            imports.append(data[start:data.index(b"\0", start)].decode("ascii").lower())
            descriptor += 20
    system = set("advapi32 bcrypt cfgmgr32 comctl32 comdlg32 crypt32 d3d11 d3d12 d3dcompiler_47 dbghelp dwmapi dxgi gdi32 hid imm32 iphlpapi kernel32 msvcrt ntdll ole32 oleaut32 opengl32 powrprof propsys psapi rpcrt4 secur32 setupapi shell32 shlwapi user32 userenv uxtheme version winhttp winmm winspool ws2_32 wtsapi32 normaliz uuid".split())
    unexpected = [n for n in imports if n.removesuffix(".dll") not in system and not n.startswith(("api-ms-win-", "ext-ms-win-"))]
    if unexpected:
        raise ValueError(f"Non-system DLL dependencies must be bundled explicitly: {unexpected}")
    return {"dll_dependencies": sorted(imports)}


def inspect_macho(binary, arch):
    actual = output("lipo", "-archs", str(binary)).strip()
    if actual != {"x86_64": "x86_64", "aarch64": "arm64"}[arch]:
        raise ValueError(f"Wrong Mach-O architecture: {actual}")
    libraries = [line.strip().split(" (", 1)[0] for line in output("otool", "-L", str(binary)).splitlines()[1:]]
    if any(not name.startswith(("/usr/lib/", "/System/Library/")) for name in libraries):
        raise ValueError(f"Non-system macOS libraries must be bundled explicitly: {libraries}")
    commands = output("otool", "-l", str(binary))
    minimum = re.findall(r"\bminos\s+([0-9.]+)", commands)
    if not minimum:
        minimum = re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)", commands)
    if len(minimum) != 1 or tuple(map(int, minimum[0].split("."))) > (12, 0, 0):
        raise ValueError(f"Expected macOS deployment target <= 12.0: {minimum}")
    return {"minimum_macos": minimum[0], "system_libraries": libraries}


def package(binary, destination, tag, platform, arch):
    binary = binary.resolve(strict=True)
    details = {"linux": inspect_elf, "windows": inspect_pe, "macos": inspect_macho}[platform](binary, arch)
    target = {"linux": f"{arch}-linux-gnu.2.35", "windows": f"{arch}-windows-gnu", "macos": f"{arch}-macos.12.0"}[platform]
    metadata = {"version": tag, "commit": output("git", "rev-parse", "HEAD").strip(),
                "zig": output("zig", "version").strip(), "target": target,
                "cpu": "baseline", "optimize": "ReleaseSmall", **details}
    name = f"vela-{tag}-{platform}-{arch}"
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / (name + (".zip" if platform == "windows" else ".tar.gz"))
    checksum = destination / (archive.name + ".sha256")
    if archive.exists() or checksum.exists():
        raise ValueError("Refusing to overwrite an existing package")
    with tempfile.TemporaryDirectory(prefix="vela-package-") as temporary:
        directory = Path(temporary) / name
        directory.mkdir()
        if platform == "macos":
            app = directory / "Vela.app"
            executable = app / "Contents/MacOS/vela"
            executable.parent.mkdir(parents=True)
            (app / "Contents/Resources").mkdir()
            plist = {"CFBundleName": "Vela", "CFBundleDisplayName": "Vela Launcher",
                     "CFBundleIdentifier": "io.github.HumXC.vela-launcher",
                     "CFBundleExecutable": "vela", "CFBundlePackageType": "APPL",
                     "CFBundleShortVersionString": tag[1:].split("-", 1)[0],
                     "CFBundleVersion": tag[1:].split("-", 1)[0],
                     "LSMinimumSystemVersion": "12.0", "NSHighResolutionCapable": True}
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
        else:
            executable = directory / ("vela.exe" if platform == "windows" else "vela")
        shutil.copy2(binary, executable)
        executable.chmod(0o755)
        if platform == "macos":
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)], check=True)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        (directory / "VERSION").write_text(tag + "\n", encoding="utf-8")
        (directory / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        if platform == "windows":
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as zipped:
                for entry in sorted(directory.rglob("*")):
                    if entry.is_file():
                        zipped.write(entry, entry.relative_to(directory.parent))
        else:
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(directory, arcname=name)
    checksum.write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n", encoding="utf-8")
    print(archive)
    print(checksum)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--platform", choices=("linux", "windows", "macos"))
    parser.add_argument("--arch", choices=("x86_64", "aarch64"))
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--output", type=Path, default=Path("dist"))
    args = parser.parse_args()
    try:
        tag = version_tag(args.version)
        if args.validate_only:
            print(tag)
        else:
            if not args.platform or not args.arch:
                parser.error("--platform and --arch are required for packaging")
            binary = args.binary or Path("zig-out/bin/vela" + (".exe" if args.platform == "windows" else ""))
            package(binary, args.output, tag, args.platform, args.arch)
    except (ValueError, OSError, struct.error, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release packaging failed: {error}\n")


if __name__ == "__main__":
    main()
