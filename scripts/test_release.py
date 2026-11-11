import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("package-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseValidation(unittest.TestCase):
    def test_versions_reject_unsafe_or_ambiguous_tags(self):
        self.assertEqual(release.version_tag("1.2.3-rc.1"), "v1.2.3-rc.1")
        for value in ("../1.2.3", "1.2", "01.2.3", "1.2.3-01", "1.2.3;echo injected"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.version_tag(value)

    def test_linux_machine_loader_and_glibc_floor(self):
        header = "ELF64 AArch64 [Requesting program interpreter: /lib/ld-linux-aarch64.so.1]"
        with patch.object(release, "output", side_effect=[header, "GLIBC_2.34 GLIBC_2.17"]):
            self.assertEqual(release.inspect_elf(Path("vela"), "aarch64"), {"required_glibc": "2.34"})
        for headers, versions, arch in ((header, "GLIBC_2.34", "x86_64"),
                                        (header, "GLIBC_2.36", "aarch64"),
                                        (header + " (RUNPATH) /tmp/build", "GLIBC_2.34", "aarch64")):
            with patch.object(release, "output", side_effect=[headers, versions]), self.assertRaises(ValueError):
                release.inspect_elf(Path("vela"), arch)

    def test_pe_machine_and_unbundled_dll_rejection(self):
        data = bytearray(1024)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 60, 128)
        data[128:132] = b"PE\0\0"
        struct.pack_into("<HH", data, 132, 0xAA64, 1)
        struct.pack_into("<H", data, 148, 240)
        struct.pack_into("<H", data, 152, 0x20B)
        struct.pack_into("<I", data, 272, 0x1000)
        struct.pack_into("<IIII", data, 400, 512, 0x1000, 512, 512)
        struct.pack_into("<I", data, 524, 0x1040)
        with tempfile.TemporaryDirectory() as root:
            binary = Path(root) / "vela.exe"
            data[576:589] = b"KERNEL32.dll\0"
            binary.write_bytes(data)
            self.assertEqual(release.inspect_pe(binary, "aarch64")["dll_dependencies"], ["kernel32.dll"])
            with self.assertRaises(ValueError):
                release.inspect_pe(binary, "x86_64")
            data[576:589] = b"missing1.dll\0"
            binary.write_bytes(data)
            with self.assertRaisesRegex(ValueError, "Non-system DLL"):
                release.inspect_pe(binary, "aarch64")

    def test_macos_rejects_wrong_arch_and_build_machine_libraries(self):
        with patch.object(release, "output", return_value="arm64\n"), self.assertRaises(ValueError):
            release.inspect_macho(Path("vela"), "x86_64")
        with patch.object(release, "output", side_effect=["arm64\n", "vela:\n /opt/homebrew/lib/libfoo.dylib (version 1)\n"]), self.assertRaises(ValueError):
            release.inspect_macho(Path("vela"), "aarch64")
        with patch.object(release, "output", side_effect=["arm64\n", "vela:\n /usr/lib/libSystem.B.dylib (version 1)\n", "cmd LC_BUILD_VERSION\n minos 12.0\n"]):
            self.assertEqual(release.inspect_macho(Path("vela"), "aarch64")["minimum_macos"], "12.0")


if __name__ == "__main__":
    unittest.main()
