#!/usr/bin/env python3
"""Generate local hostile archive fixtures and exercise safe_archive in Zig 0.17."""
import gzip
import io
import os
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def zip_bytes(entries, compression=zipfile.ZIP_DEFLATED):
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", compression=compression) as archive:
        for name, content, mode in entries:
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = mode << 16
            info.compress_type = compression
            archive.writestr(info, content)
    return out.getvalue()


def tar_bytes(entries, fmt=tarfile.USTAR_FORMAT):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w", format=fmt) as archive:
        for name, data, kind, mode in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.mode = mode
            info.size = len(data) if kind == tarfile.REGTYPE else 0
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                info.linkname = data.decode("utf-8") if data else "../outside"
            archive.addfile(info, io.BytesIO(data))
    return out.getvalue()


def main():
    with tempfile.TemporaryDirectory(prefix="vela-safe-archive-") as directory:
        root = Path(directory)
        def put(name, data):
            (root / name).write_bytes(data)
        regular = [("jdk/bin/java", b"java executable", 0o100755), ("jdk/release", b"JAVA_VERSION=21", 0o100644)]
        good_zip = zip_bytes(regular)
        put("good.zip", good_zip)
        put("stored.zip", zip_bytes(regular, zipfile.ZIP_STORED))
        for label, path in {
            "traversal": "../outside", "absolute": "/outside", "drive": "C:/outside", "mixed": "a\\../outside",
            "reserved": "con.txt", "reservedspace": "con .txt", "trailing": "a/file. ", "unicode": "世界/save.dat", "empty-component": "a//b", "ads": "a:b",
        }.items():
            put(label + ".zip", zip_bytes([(path, b"bad", 0o100644)]))
        put("collision.zip", zip_bytes([("Dir/a", b"a", 0o100644), ("dir/b", b"b", 0o100644)]))
        put("duplicate.zip", zip_bytes([("same", b"a", 0o100644), ("same", b"b", 0o100644)]))
        put("conflict.zip", zip_bytes([("a", b"a", 0o100644), ("a/b", b"b", 0o100644)]))
        put("symlink.zip", zip_bytes([("link", b"../outside", 0o120777)]))
        put("device.zip", zip_bytes([("dev", b"", 0o020644)]))
        put("setuid.zip", zip_bytes([("bin", b"bad", 0o104755)]))
        bad_crc = bytearray(good_zip)
        local_crc = struct.unpack_from("<I", bad_crc, 14)[0] ^ 0x12345678
        struct.pack_into("<I", bad_crc, 14, local_crc)
        central = bad_crc.index(b"PK\x01\x02")
        struct.pack_into("<I", bad_crc, central + 16, local_crc)
        put("crc.zip", bad_crc)
        put("truncated.zip", good_zip[:-12])
        mismatch = bytearray(good_zip)
        mismatch[30] = ord("x")
        put("mismatch.zip", mismatch)
        put("bomb.zip", zip_bytes([("bomb", b"0" * 1024 * 1024, 0o100644)]))
        # Stored data allows deterministic multi-chunk cancellation and writes.
        put("large.zip", zip_bytes([("large", bytes(range(256)) * 1024, 0o100644)], zipfile.ZIP_STORED))
        regular_tar = [("jdk/bin/java", b"java executable", tarfile.REGTYPE, 0o755), ("jdk/release", b"JAVA_VERSION=21", tarfile.REGTYPE, 0o644)]
        good_tar = tar_bytes(regular_tar)
        put("good.tgz", gzip.compress(good_tar, mtime=0))
        for label, kind in [("symlink", tarfile.SYMTYPE), ("hardlink", tarfile.LNKTYPE), ("device", tarfile.CHRTYPE), ("fifo", tarfile.FIFOTYPE)]:
            put(label + ".tgz", gzip.compress(tar_bytes([("link", b"", kind, 0o644)]), mtime=0))
        for label, path in [("traversal", "../outside"), ("absolute", "/outside")]:
            put(label + ".tgz", gzip.compress(tar_bytes([(path, b"bad", tarfile.REGTYPE, 0o644)]), mtime=0))
        put("collision.tgz", gzip.compress(tar_bytes([("Dir/a", b"a", tarfile.REGTYPE, 0o644), ("dir/b", b"b", tarfile.REGTYPE, 0o644)]), mtime=0))
        put("pax.tgz", gzip.compress(tar_bytes([("a/" + "long-" * 30 + "/file", b"pax", tarfile.REGTYPE, 0o644)], tarfile.PAX_FORMAT), mtime=0))
        put("gnu.tgz", gzip.compress(tar_bytes([("a/" + "long-" * 30 + "/file", b"gnu", tarfile.REGTYPE, 0o644)], tarfile.GNU_FORMAT), mtime=0))
        bad = bytearray(good_tar)
        bad[0] ^= 1
        put("checksum.tgz", gzip.compress(bad, mtime=0))
        bad = bytearray(gzip.compress(good_tar, mtime=0))
        bad[-8] ^= 1
        put("crc.tgz", bad)
        put("truncated.tgz", gzip.compress(good_tar, mtime=0)[:-6])
        put("trailing.tgz", gzip.compress(good_tar, mtime=0) + b"junk")
        put("tartrailing.tgz", gzip.compress(good_tar + b"junk", mtime=0))
        put("tartruncated.tgz", gzip.compress(good_tar[:512], mtime=0))
        bad = bytearray(good_tar)
        bad[124:136] = b"\x80\x00\x00\x00" + b"\xff" * 8
        # Valid checksum but absurd binary size would overflow std tar's alignment.
        bad[148:156] = b"        "
        bad[148:156] = ("%06o\0 " % sum(bad[:512])).encode()
        put("sizeoverflow.tgz", gzip.compress(bad, mtime=0))
        put("bomb.tgz", gzip.compress(tar_bytes([("bomb", b"0" * 1024 * 1024, tarfile.REGTYPE, 0o644)]), mtime=0))
        # Two valid entries share a long zero-output deflate suffix. Output
        # limits alone cannot bound repeated compressed decoding work.
        import zlib
        tail = b"\x00\x00\x00\xff\xff" * 20000 + b"\x01\x00\x00\xff\xff"
        def local(name, crc, compressed, expanded):
            return struct.pack("<4s5H3I2H", b"PK\x03\x04", 20, 0, 8, 0, 0, crc, compressed, expanded, len(name), 0) + name
        def central(name, crc, compressed, expanded, offset):
            return struct.pack("<4s6H3I5H2I", b"PK\x01\x02", 0x314, 20, 0, 8, 0, 0, crc, compressed, expanded, len(name), 0, 0, 0, 0, 0o100644 << 16, offset) + name
        inner = local(b"inner", 0, len(tail), 0)
        outer_data = b"\x00" + struct.pack("<HH", len(inner), 0xffff - len(inner)) + inner + tail
        outer = local(b"outer", zlib.crc32(inner), len(outer_data), len(inner))
        body = outer + outer_data
        cd = central(b"outer", zlib.crc32(inner), len(outer_data), len(inner), 0) + central(b"inner", 0, len(tail), 0, len(outer) + 5)
        end = struct.pack("<4s4H2IH", b"PK\x05\x06", 0, 0, 2, 2, len(cd), len(body), 0)
        put("overlap.zip", body + cd + end)
        bad = bytearray(gzip.compress(good_tar, mtime=0))
        bad[3] |= 0x02
        put("hcrc.tgz", bad)
        bad[3] = 0x20
        put("gzipreserved.tgz", bad)
        # Phase 2: the same link graph in ZIP and tar, with targets on either side.
        links = [("before", b"bin/java", 0o120777),
                 ("chain", b"before", 0o120777),
                 ("bin/java", b"java executable", 0o100755),
                 ("other/after", b"../bin/java", 0o120777),
                 ("世界/数据", b"UTF-8 data", 0o100644)]
        put("links.zip", zip_bytes(links))
        tar_links = [(name, data, tarfile.SYMTYPE if mode == 0o120777 else tarfile.REGTYPE, mode & 0o777) for name, data, mode in links]
        tar_links.insert(0, ("other/hard-before", b"bin/java", tarfile.LNKTYPE, 0o644))
        tar_links.append(("other/hard-after", b"bin/java", tarfile.LNKTYPE, 0o644))
        put("links.tgz", gzip.compress(tar_bytes(tar_links, tarfile.PAX_FORMAT), mtime=0))
        for label, target in [("missing-link", b"missing"), ("absolute-link", b"/outside"),
                              ("escape-link", b"../../outside"), ("drive-link", b"C:/outside")]:
            put(label + ".zip", zip_bytes([("link", target, 0o120777)]))
            put(label + ".tgz", gzip.compress(tar_bytes([("link", target, tarfile.SYMTYPE, 0o777)]), mtime=0))
        for label, graph in [("cycle", [("a", b"b"), ("b", b"a")]), ("self-link", [("a", b"a")])]:
            put(label + ".zip", zip_bytes([(name, target, 0o120777) for name, target in graph]))
            put(label + ".tgz", gzip.compress(tar_bytes([(name, target, tarfile.SYMTYPE, 0o777) for name, target in graph]), mtime=0))
        put("directory-link.zip", zip_bytes([("dir/", b"", 0o040755), ("link", b"dir", 0o120777)]))
        put("directory-link.tgz", gzip.compress(tar_bytes([("dir", b"", tarfile.DIRTYPE, 0o755), ("link", b"dir", tarfile.SYMTYPE, 0o777)]), mtime=0))
        long_target = "世界/" + "long-" * 30 + "/java"
        for label, fmt in [("gnu-link", tarfile.GNU_FORMAT), ("pax-link", tarfile.PAX_FORMAT)]:
            put(label + ".tgz", gzip.compress(tar_bytes([("link", long_target.encode(), tarfile.SYMTYPE, 0o777), (long_target, b"java executable", tarfile.REGTYPE, 0o755)], fmt), mtime=0))
        for label, name in [("c0", "a\x01b"), ("del", "a\x7fb"), ("c1", "a\x85b"),
                            ("com-super", "COM¹.txt"), ("lpt-super", "lPt²"), ("com-super3", "com³")]:
            put(label + ".zip", zip_bytes([(name, b"bad", 0o100644)]))
            put(label + ".tgz", gzip.compress(tar_bytes([(name, b"bad", tarfile.REGTYPE, 0o644)], tarfile.PAX_FORMAT), mtime=0))
        for label, invalid in [("invalid-utf8", b"\xffbad"), ("overlong-utf8", b"\xc0\xafxx"), ("surrogate-utf8", b"\xed\xa0\x80x")]:
            put(label + ".zip", zip_bytes([("NAME", b"bad", 0o100644)]).replace(b"NAME", invalid))
        put("unicode-alias.zip", zip_bytes([("é", b"first", 0o100644), ("e\u0301", b"second", 0o100644)]))
        put("unicode-directory-alias.zip", zip_bytes([("é/a", b"first", 0o100644), ("e\u0301/b", b"second", 0o100644)]))
        put("unicode-near-device.zip", zip_bytes([("COM¹x", b"ok", 0o100644), ("COM⁴", b"ok", 0o100644)]))
        large = bytes(range(256)) * 1024
        put("large-link.zip", zip_bytes([("large", large, 0o100644), ("copy", b"large", 0o120777)], zipfile.ZIP_STORED))
        corrupt = bytearray(zip_bytes([("copy", b"large", 0o120777), ("large", large, 0o100644)], zipfile.ZIP_STORED))
        corrupt[30 + len("copy")] ^= 1
        put("link-crc.zip", corrupt)
        depth = [(f"link{i}", f"link{i + 1}".encode(), 0o120777) for i in range(65)]
        depth.append(("link65", b"data", 0o100644))
        put("deep-links.zip", zip_bytes(depth))
        hard_bad = bytearray(tar_bytes([("link", b"target", tarfile.LNKTYPE, 0o644), ("target", b"data", tarfile.REGTYPE, 0o644)]))
        hard_bad[0] ^= 1  # Must validate original header before hardlink adaptation.
        put("hardlink-checksum.tgz", gzip.compress(hard_bad, mtime=0))
        target_bad = bytearray(zip_bytes([("copy", b"target", 0o120777), ("target", b"data", 0o100644)], zipfile.ZIP_STORED))
        second = target_bad.index(b"PK\x03\x04", 4)
        target_bad[second + 30 + len("target")] ^= 1
        put("link-target-crc.zip", target_bad)
        gzip_bad = bytearray(gzip.compress(tar_bytes([("copy", b"target", tarfile.SYMTYPE, 0o777), ("target", b"data", tarfile.REGTYPE, 0o644)]), mtime=0))
        gzip_bad[-8] ^= 1
        put("link-gzip-crc.tgz", gzip_bad)
        # JDK license aliases: implicit directories, nested links, forward chains,
        # and a target reached through a directory alias in its parent path.
        directory_graph = [
            ("jdk/legal/java.desktop", b"java.base", 0o120777),
            ("jdk/legal/chain", b"java.desktop", 0o120777),
            ("jdk/legal/java.base/LICENSE", b"license", 0o100644),
            ("jdk/legal/java.base/nested/NOTICE", b"notice", 0o100644),
            ("jdk/legal/java.base/COPY", b"LICENSE", 0o120777),
            ("jdk/legal/notice", b"java.desktop/nested/NOTICE", 0o120777),
            ("jdk/legal/empty/", b"", 0o040755),
            ("jdk/legal/empty-copy", b"empty", 0o120777),
        ]
        def directory_fixtures(label, graph):
            put(label + ".zip", zip_bytes(graph))
            kinds = {0o120000: tarfile.SYMTYPE, 0o040000: tarfile.DIRTYPE, 0o100000: tarfile.REGTYPE}
            put(label + ".tgz", gzip.compress(tar_bytes([(name, data, kinds[mode & 0o170000], mode & 0o777) for name, data, mode in graph], tarfile.PAX_FORMAT), mtime=0))
        directory_fixtures("jdk-directories", directory_graph)
        directory_fixtures("jdk-install", directory_graph + [("jdk/bin/java", b"java executable", 0o100755)])
        directory_fixtures("jdk8-install", directory_graph + [("jdk/jre/bin/java", b"embedded java", 0o100755), ("jdk/bin/java", b"java executable", 0o100755)])
        directory_fixtures("directory-ancestor", [("dir/data", b"x", 0o100644), ("dir/loop", b".", 0o120777)])
        directory_fixtures("directory-quota", [("dir/a", b"x", 0o100644), ("longer-alias", b"dir", 0o120777)])
        directory_fixtures("directory-depth", [("dir/a", b"x", 0o100644), ("extra/alias", b"../dir", 0o120777)])
        directory_fixtures("directory-reentrant-file", [("real/file", b"x", 0o100644), ("real/ref", b"../alias/file", 0o120777), ("alias", b"real", 0o120777)])
        directory_fixtures("directory-alias-collision", [("é/a", b"first", 0o100644), ("e\u0301", "é".encode(), 0o120777)])
        directory_fixtures("directory-indirect-cycle", [("a/next", b"../b", 0o120777), ("b/next", b"../a", 0o120777)])
        directory_fixtures("directory-root", [("jdk/root", b"..", 0o120777)])
        directory_fixtures("directory-case", [("Dir/a", b"x", 0o100644), ("copy", b"dir", 0o120777)])
        directory_fixtures("directory-conflict", [("dir/a", b"x", 0o100644), ("copy", b"dir", 0o120777), ("copy/a", b"y", 0o100644)])
        directory_fixtures("directory-self-descendant", [("alias", b"alias/sub", 0o120777)])
        put("directory-hardlink.tgz", gzip.compress(tar_bytes([("dir/a", b"x", tarfile.REGTYPE, 0o644), ("copy", b"dir", tarfile.LNKTYPE, 0o644)]), mtime=0))
        put("directory-hardchain.tgz", gzip.compress(tar_bytes([("dir/a", b"x", tarfile.REGTYPE, 0o644), ("alias", b"dir", tarfile.SYMTYPE, 0o777), ("copy", b"alias", tarfile.LNKTYPE, 0o644)]), mtime=0))
        put("large-directory.zip", zip_bytes([("dir/large", large, 0o100644), ("copy", b"dir", 0o120777)], zipfile.ZIP_STORED))
        bad_directory_crc = bytearray(zip_bytes(directory_graph, zipfile.ZIP_STORED))
        bad_directory_crc[30 + len(directory_graph[0][0])] ^= 1
        put("directory-crc.zip", bad_directory_crc)
        env = dict(os.environ, SAFE_ARCHIVE_FIXTURES=directory)
        if len(os.sys.argv) == 3 and os.sys.argv[1] == "--test-exe":
            return subprocess.call([os.sys.argv[2]], cwd=ROOT, env=env)
        return subprocess.call(["zig", "test", "src/core/safe_archive_test.zig", "--cache-dir", ".zig-cache", "--global-cache-dir", ".zig-global-cache", *os.sys.argv[1:]], cwd=ROOT, env=env)


if __name__ == "__main__":
    raise SystemExit(main())
