const std = @import("std");
const java = @import("java_download.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const linux_x64: java.Platform = .{ .os = .linux, .arch = .x64 };
const digest_hex = "0000000000000000000000000000000000000000000000000000000000000000";
const fixture_uuid = "6dc442a7-dd4c-11ea-a8fe-fa163ed8e833";

fn azulFixture(allocator: std.mem.Allocator, major: u8, p: java.Platform) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .package_uuid = fixture_uuid,
        .name = "fixture.tar.gz",
        .product = "zulu",
        .availability_type = "CA",
        .java_version = [_]u16{ major, 0, 1 },
        .download_url = "https://cdn.azul.com/zulu/bin/fixture.tar.gz",
        .java_package_type = "jdk",
        .javafx_bundled = false,
        .crac_supported = false,
        .release_status = "ga",
        .os = @tagName(p.os),
        .lib_c_type = "glibc",
        .arch = if (p.arch == .x64) "x86" else "arm",
        .hw_bitness = @as(u8, 64),
        .archive_type = if (p.os == .windows) "zip" else "tar.gz",
        .sha256_hash = digest_hex,
        .size = @as(u64, 3),
    }, .{});
}

const Fixture = struct {
    metadata: []const u8 = "[]",
    archive_body: []const u8 = "abc",
    catalogue_major: u8 = 21,
    calls: usize = 0,
    extracts: usize = 0,
    canceled: bool = false,
    fail_extract: bool = false,
    bad_path: bool = false,
    not_executable: bool = false,
    cancel_at: ?java.Phase = null,
    progress_seen: bool = false,
    fn transport(self: *Fixture) java.Transport {
        return .{ .context = self, .get = get, .download = download };
    }
    fn extractor(self: *Fixture) java.Extractor {
        return .{ .context = self, .extract = extract };
    }
    fn callbacks(self: *Fixture) java.Hooks {
        return .{ .context = self, .canceled = canceledFn, .progress = progressFn };
    }
    fn canceledFn(context: ?*anyopaque) bool {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        return self.canceled;
    }
    fn progressFn(context: ?*anyopaque, progress: java.Progress) void {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        self.progress_seen = true;
        if (self.cancel_at == progress.phase) self.canceled = true;
    }
    fn get(context: *anyopaque, allocator: std.mem.Allocator, url: []const u8, limit: usize, hooks: java.Hooks) ![]u8 {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try hooks.check();
        self.calls += 1;
        if (std.mem.indexOf(u8, url, "?java_version=") != null) {
            try std.testing.expect(std.mem.indexOf(u8, url, "availability_types=CA") != null);
            try std.testing.expect(std.mem.indexOf(u8, url, "os=linux-glibc") != null);
            const expected_major = try std.fmt.allocPrint(allocator, "?java_version={d}&", .{self.catalogue_major});
            defer allocator.free(expected_major);
            try std.testing.expect(std.mem.startsWith(u8, url, "https://api.azul.com/metadata/v1/zulu/packages/"));
            try std.testing.expect(std.mem.indexOf(u8, url, expected_major) != null);
            const entry = .{
                .package_uuid = fixture_uuid,
                .product = "zulu",
                .availability_type = "CA",
                .java_version = [_]u16{ self.catalogue_major, 0, 1 },
                .download_url = "https://cdn.azul.com/zulu/bin/fixture.tar.gz",
            };
            return std.json.Stringify.valueAlloc(allocator, [_]@TypeOf(entry){entry}, .{});
        }
        if (self.metadata.len > limit) return error.MetadataTooLarge;
        return allocator.dupe(u8, self.metadata);
    }
    fn download(context: *anyopaque, use_io: std.Io, release: *const java.RuntimeRelease, path: []const u8, hooks: java.Hooks) !void {
        _ = release;
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.calls += 1;
        try hooks.check();
        const file = try std.Io.Dir.cwd().createFile(use_io, path, .{ .exclusive = true });
        defer file.close(use_io);
        try file.writeStreamingAll(use_io, self.archive_body);
    }
    fn extract(context: *anyopaque, allocator: std.mem.Allocator, use_io: std.Io, archive: java.Archive, source: []const u8, dest: []const u8, hooks: java.Hooks) ![]u8 {
        _ = archive;
        _ = source;
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.extracts += 1;
        try hooks.check();
        const dir = try std.Io.Dir.cwd().openDir(use_io, dest, .{});
        defer dir.close(use_io);
        try dir.createDir(use_io, "bin", .default_dir);
        const file = try dir.createFile(use_io, "bin/java", .{ .permissions = if (self.not_executable) .default_file else .executable_file });
        {
            defer file.close(use_io);
            try file.writeStreamingAll(use_io, "fixture java bytes, deliberately never executed");
        }
        if (self.fail_extract) return error.UnsafeArchive;
        return allocator.dupe(u8, if (self.bad_path) "../bin/java" else "bin/java");
    }
};

fn fixtureRelease() !java.RuntimeRelease {
    const checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  microsoft-jdk-21.0.1-linux-x64.tar.gz\n";
    return java.parseMicrosoft(a, checksum, 21, linux_x64);
}
fn rootPath(tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    return a.dupe(u8, buffer[0..n]);
}
fn expectEmpty(tmp: *std.testing.TmpDir) !void {
    var iter = tmp.dir.iterate();
    try std.testing.expect((try iter.next(io)) == null);
}

test "Azul literal size precision is scoped and nearest kilobyte boundaries are strict" {
    const bytes = try azulFixture(a, 21, linux_x64);
    defer a.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    parsed.value.object.getPtr("size").?.* = .{ .integer = 213089000 };
    const rounded_bytes = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    defer a.free(rounded_bytes);
    var release = try java.parseAzul(a, rounded_bytes, 21, linux_x64);
    defer release.deinit();
    try std.testing.expectEqual(@as(?u64, 213089000), release.size);
    try std.testing.expectEqual(.azul_rounded_kilobyte, release.size_precision);
    try std.testing.expect(release.acceptsSize(213089356));
    try std.testing.expect(release.acceptsSize(213088500));
    try std.testing.expect(release.acceptsSize(213089499));
    try std.testing.expect(!release.acceptsSize(213088499));
    try std.testing.expect(!release.acceptsSize(213089500));
    release.vendor = .microsoft;
    try std.testing.expect(!release.acceptsSize(213089356));
    release.vendor = .azul;
    release.size_precision = .exact;
    try std.testing.expect(!release.acceptsSize(213089356));
    try std.testing.expect(release.acceptsSize(213089000));
    var precise = try java.parseAzul(a, bytes, 21, linux_x64);
    defer precise.deinit();
    try std.testing.expectEqual(.exact, precise.size_precision);
    try std.testing.expect(!precise.acceptsSize(4));
}

test "rounded Azul archive still requires exact SHA256 and never publishes bad sizes" {
    const body: [501]u8 = @splat('x');
    for (0..4) |scenario| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try rootPath(&tmp);
        defer a.free(root);
        const metadata = try azulFixture(a, 21, linux_x64);
        defer a.free(metadata);
        var release = try java.parseAzul(a, metadata, 21, linux_x64);
        defer release.deinit();
        release.vendor = .azul;
        release.size = 1000;
        release.size_precision = .azul_rounded_kilobyte;
        std.crypto.hash.sha2.Sha256.hash(&body, &release.sha256, .{});
        var fixture: Fixture = .{ .archive_body = &body };
        switch (scenario) {
            1 => release.sha256 = @splat(0),
            2 => fixture.archive_body = body[0..499],
            3 => release.size_precision = .exact,
            else => {},
        }
        if (scenario == 0) {
            var installed = try java.install(a, io, fixture.transport(), &release, root, fixture.extractor(), fixture.callbacks());
            defer installed.deinit();
            try std.testing.expectEqual(@as(usize, 1), fixture.extracts);
        } else {
            try std.testing.expectError(if (scenario == 1) error.Sha256Mismatch else error.ArchiveSizeMismatch, java.install(a, io, fixture.transport(), &release, root, fixture.extractor(), fixture.callbacks()));
            try std.testing.expectEqual(@as(usize, 0), fixture.extracts);
            try expectEmpty(&tmp);
        }
    }
}

test "official providers cover supported majors and all six target platforms" {
    for ([_]java.Os{ .linux, .windows, .macos }) |os| {
        for ([_]java.Arch{ .x64, .aarch64 }) |arch| {
            const p: java.Platform = .{ .os = os, .arch = arch };
            for (java.majors) |major| {
                const json = try azulFixture(a, major, p);
                defer a.free(json);
                var azul = try java.parseAzul(a, json, major, p);
                defer azul.deinit();
                try std.testing.expectEqual(major, azul.major);
                try std.testing.expectEqual(p.archive(), azul.archive);
                if (!java.supported(.microsoft, major)) {
                    try std.testing.expectError(error.UnsupportedRelease, java.parseMicrosoft(a, "", major, p));
                    continue;
                }
                const checksum = try std.fmt.allocPrint(a, "{s}  microsoft-jdk-{d}.0.1-{s}-{s}.{s}\r\n", .{
                    digest_hex, major, @tagName(os), @tagName(arch), if (os == .windows) "zip" else "tar.gz",
                });
                defer a.free(checksum);
                var microsoft = try java.parseMicrosoft(a, checksum, major, p);
                defer microsoft.deinit();
                try std.testing.expectEqual(major, microsoft.major);
                try std.testing.expect(!std.mem.endsWith(u8, microsoft.url, ".sha256sum.txt"));
            }
        }
    }
}

test "Microsoft checksums pin immutable filename and reject malformed or wrong targets" {
    var release = try java.parseMicrosoft(a, digest_hex ++ " *microsoft-jdk-21.0.1-macOS-aarch64.tar.gz", 21, .{ .os = .macos, .arch = .aarch64 });
    defer release.deinit();
    try std.testing.expectEqualStrings("https://aka.ms/download-jdk/microsoft-jdk-21.0.1-macOS-aarch64.tar.gz", release.url);
    try std.testing.expectError(error.ReleaseMismatch, java.parseMicrosoft(a, digest_hex ++ " microsoft-jdk-17.0.1-linux-x64.tar.gz", 21, linux_x64));
    try std.testing.expectError(error.ReleaseMismatch, java.parseMicrosoft(a, digest_hex ++ " microsoft-jdk-21.0.1-linux-aarch64.tar.gz", 21, linux_x64));
    try std.testing.expectError(error.InvalidChecksum, java.parseMicrosoft(a, "not-a-digest file.zip", 21, linux_x64));
    try std.testing.expectError(error.InvalidChecksum, java.parseMicrosoft(a, digest_hex ++ " file.zip another-line", 21, linux_x64));
    try std.testing.expectError(error.InvalidArtifactUrl, java.parseMicrosoft(a, digest_hex ++ " ../microsoft-jdk-21.0.1-linux-x64.tar.gz", 21, linux_x64));
    try std.testing.expectError(error.InvalidMetadata, java.parseMicrosoft(a, digest_hex ++ " microsoft-jdk-21-linux-x64.tar.gz", 21, linux_x64));
}

test "Azul discovery uses list then free CA target-validated details" {
    const json = try azulFixture(a, 21, linux_x64);
    defer a.free(json);
    var fixture: Fixture = .{ .metadata = json };
    var release = try java.resolve(a, fixture.transport(), .azul, 21, linux_x64, fixture.callbacks());
    defer release.deinit();
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqualStrings("21.0.1", release.version);
    try std.testing.expectError(error.ReleaseMismatch, java.parseAzul(a, json, 17, linux_x64));
    try std.testing.expectError(error.ReleaseMismatch, java.parseAzul(a, json, 21, .{ .os = .windows, .arch = .x64 }));
    fixture.canceled = true;
    try std.testing.expectError(error.Canceled, java.resolve(a, fixture.transport(), .azul, 21, linux_x64, fixture.callbacks()));
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "Zulu Java 16 resolves official metadata with exact target and Microsoft remains unavailable" {
    const json = try azulFixture(a, 16, linux_x64);
    defer a.free(json);
    var fixture: Fixture = .{ .metadata = json, .catalogue_major = 16 };
    var release = try java.resolve(a, fixture.transport(), .azul, 16, linux_x64, fixture.callbacks());
    defer release.deinit();
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(u8, 16), release.major);
    try std.testing.expectEqualStrings("16.0.1", release.version);
    try std.testing.expectEqualStrings("https://cdn.azul.com/zulu/bin/fixture.tar.gz", release.url);
    try std.testing.expectEqual(@as([32]u8, @splat(0)), release.sha256);
    try std.testing.expectEqual(@as(?u64, 3), release.size);
    try std.testing.expectError(error.ReleaseMismatch, java.parseAzul(a, json, 17, linux_x64));
    try std.testing.expectError(error.ReleaseMismatch, java.parseAzul(a, json, 16, .{ .os = .linux, .arch = .aarch64 }));
    try std.testing.expectError(error.ReleaseMismatch, java.parseAzul(a, json, 16, .{ .os = .windows, .arch = .x64 }));
    try std.testing.expectError(error.UnsupportedRelease, java.resolve(a, fixture.transport(), .microsoft, 16, linux_x64, fixture.callbacks()));
    try std.testing.expectError(error.UnsupportedRelease, java.parseMicrosoft(a, digest_hex ++ " microsoft-jdk-16.0.1-linux-x64.tar.gz", 16, linux_x64));
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    fixture.canceled = true;
    try std.testing.expectError(error.Canceled, java.resolve(a, fixture.transport(), .azul, 16, linux_x64, fixture.callbacks()));
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expect(!java.supported(.azul, 26));
}

test "registered Java 16 resolves exactly and retains its explicit registry choice" {
    const registry = @import("../ui/java_manager.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const java16_path = try std.fs.path.join(a, &.{ root, "registered-java16" });
    defer a.free(java16_path);
    const java17_path = try std.fs.path.join(a, &.{ root, "registered-java17" });
    defer a.free(java17_path);
    var manager = try registry.Manager.init(a, io, root);
    defer manager.deinit();
    // Already-probed fixture records exercise registry publication, never execution.
    try manager.addDownloaded(.{ .path = java17_path, .major = 17, .vendor = "Azul Systems, Inc." });
    try manager.addDownloaded(.{ .path = java16_path, .major = 16, .vendor = "Azul Systems, Inc." });
    try std.testing.expectEqualStrings(java16_path, manager.resolve("minecraft-1.17", 16).?.path);
    try std.testing.expectError(error.IncompatibleJava, manager.choose("minecraft-1.17", java17_path, 16));
    try manager.choose("minecraft-1.17", java16_path, 16);
    try std.testing.expect(manager.resolve("minecraft-1.17", 17) == null);
    var reloaded = try registry.Manager.init(a, io, root);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings(java16_path, reloaded.resolve("minecraft-1.17", 16).?.path);
    try std.testing.expectEqual(@as(u32, 16), reloaded.resolve("minecraft-1.17", 16).?.major);
}

test "staged install publishes manifest and Java together without probing" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var release = try fixtureRelease();
    defer release.deinit();
    var fixture: Fixture = .{};
    var installed = try java.install(a, io, fixture.transport(), &release, root, fixture.extractor(), fixture.callbacks());
    defer installed.deinit();
    try std.testing.expect(fixture.progress_seen);
    const file = try std.Io.Dir.cwd().openFile(io, installed.java_path, .{});
    file.close(io);
    try std.testing.expectEqual(.installed_unverified, installed.status);
    const dir = try std.Io.Dir.cwd().openDir(io, installed.directory, .{});
    defer dir.close(io);
    const manifest = try dir.openFile(io, ".vela-runtime.json", .{});
    manifest.close(io);
    try std.testing.expectError(error.PathAlreadyExists, java.install(a, io, fixture.transport(), &release, root, fixture.extractor(), fixture.callbacks()));
    var iter = tmp.dir.iterate();
    const entry = (try iter.next(io)).?;
    try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".stage-"));
    try std.testing.expect((try iter.next(io)) == null);
}

test "checksum, extraction, path, and precommit cancellation failures never publish" {
    for (0..6) |scenario| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try rootPath(&tmp);
        defer a.free(root);
        var release = try fixtureRelease();
        defer release.deinit();
        var fixture: Fixture = .{};
        switch (scenario) {
            0 => release.sha256 = @splat(0),
            1 => fixture.fail_extract = true,
            2 => fixture.bad_path = true,
            3 => fixture.cancel_at = .downloading,
            4 => fixture.cancel_at = .extracting,
            5 => fixture.cancel_at = .publishing,
            else => unreachable,
        }
        const expected = switch (scenario) {
            0 => error.Sha256Mismatch,
            1 => error.UnsafeArchive,
            2 => error.InvalidJavaPath,
            else => error.Canceled,
        };
        try std.testing.expectError(expected, java.install(a, io, fixture.transport(), &release, root, fixture.extractor(), fixture.callbacks()));
        try expectEmpty(&tmp);
        if (scenario == 0) try std.testing.expectEqual(@as(usize, 0), fixture.extracts);
    }
}

test "non-executable POSIX Java is rejected without running downloaded code" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var release = try fixtureRelease();
    defer release.deinit();
    var fixture: Fixture = .{ .not_executable = true };
    try std.testing.expectError(error.InvalidJavaExecutable, java.install(a, io, fixture.transport(), &release, root, fixture.extractor(), fixture.callbacks()));
    try expectEmpty(&tmp);
}

test "postcommit cancellation leaves successful published installation" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var release = try fixtureRelease();
    defer release.deinit();
    var fixture: Fixture = .{ .cancel_at = .complete };
    var installed = try java.install(a, io, fixture.transport(), &release, root, fixture.extractor(), fixture.callbacks());
    defer installed.deinit();
    try std.testing.expect(fixture.canceled);
}

fn allocationCatalog(allocator: std.mem.Allocator) !void {
    const json = try azulFixture(allocator, 21, linux_x64);
    defer allocator.free(json);
    var fixture: Fixture = .{ .metadata = json };
    var azul = try java.resolve(allocator, fixture.transport(), .azul, 21, linux_x64, .{});
    defer azul.deinit();
    var microsoft = try java.parseMicrosoft(allocator, digest_hex ++ " microsoft-jdk-21.0.1-linux-x64.tar.gz", 21, linux_x64);
    defer microsoft.deinit();
}
fn allocationInstall(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    var release = try fixtureRelease();
    defer release.deinit();
    var fixture: Fixture = .{};
    var installed = try java.install(allocator, io, fixture.transport(), &release, root, fixture.extractor(), .{});
    defer installed.deinit();
}

test "provider parsing and installation ownership survive every allocation failure" {
    try @import("test_allocations").checkAllAllocationFailures(a, allocationCatalog, .{});
    try @import("test_allocations").checkAllAllocationFailures(a, allocationInstall, .{});
}
