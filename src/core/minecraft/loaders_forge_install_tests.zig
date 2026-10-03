const std = @import("std");
const builtin = @import("builtin");
const install = @import("loader_install.zig");
const loaders = @import("loaders.zig");
const files = @import("loaders_files.zig");
const m = @import("metadata/root.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const catalog_url = "https://files.minecraftforge.net/net/minecraftforge/forge/maven-metadata.json";
const installer_url = "https://maven.minecraftforge.net/net/minecraftforge/forge/1.20.1-47.2.0/forge-1.20.1-47.2.0-installer.jar";
const processor_path = "net/minecraftforge/fixture/1/fixture-1.jar";
const processor_url = "https://maven.minecraftforge.net/" ++ processor_path;
const generated_path = "libraries/net/minecraftforge/generated/1/generated-1.jar";
const fixture_id = "forge-fixture-id";
const fixture_name = "ForgeFixture";

const ZipEntry = struct { path: []const u8, bytes: []const u8 };

// Stored ZIPs keep installer/JAR fixtures independent of external binaries.
fn storedZip(allocator: std.mem.Allocator, entries: []const ZipEntry) ![]u8 {
    var storage: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    var offsets: [8]u32 = undefined;
    if (entries.len > offsets.len) return error.FixtureTooLarge;
    for (entries, 0..) |entry, index| {
        offsets[index] = @intCast(writer.end);
        var header = std.mem.zeroes(std.zip.LocalFileHeader);
        header.signature = std.zip.local_file_header_sig;
        header.version_needed_to_extract = 20;
        header.compression_method = .store;
        header.crc32 = std.hash.Crc32.hash(entry.bytes);
        header.compressed_size = @intCast(entry.bytes.len);
        header.uncompressed_size = @intCast(entry.bytes.len);
        header.filename_len = @intCast(entry.path.len);
        try writer.writeStruct(header, .little);
        try writer.writeAll(entry.path);
        try writer.writeAll(entry.bytes);
    }
    const central_offset = writer.end;
    for (entries, 0..) |entry, index| {
        var header = std.mem.zeroes(std.zip.CentralDirectoryFileHeader);
        header.signature = std.zip.central_file_header_sig;
        header.version_made_by = 0x0314;
        header.version_needed_to_extract = 20;
        header.compression_method = .store;
        header.crc32 = std.hash.Crc32.hash(entry.bytes);
        header.compressed_size = @intCast(entry.bytes.len);
        header.uncompressed_size = @intCast(entry.bytes.len);
        header.filename_len = @intCast(entry.path.len);
        header.external_file_attributes = 0o100644 << 16;
        header.local_file_header_offset = offsets[index];
        try writer.writeStruct(header, .little);
        try writer.writeAll(entry.path);
    }
    var end = std.mem.zeroes(std.zip.EndRecord);
    end.signature = std.zip.end_record_sig;
    end.record_count_disk = @intCast(entries.len);
    end.record_count_total = @intCast(entries.len);
    end.central_directory_offset = @intCast(central_offset);
    end.central_directory_size = @intCast(writer.end - central_offset);
    try writer.writeStruct(end, .little);
    return allocator.dupe(u8, writer.buffered());
}

fn now(_: ?*anyopaque) u64 {
    return @intCast(@divTrunc(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}

const Fixture = struct {
    installer: []const u8,
    installer_sha1: []const u8,
    processor: []const u8,
    processor_sha1: []const u8,
    calls: [5]usize = .{ 0, 0, 0, 0, 0 },
    acquired: bool = false,
    acquires: usize = 0,
    rechecks: usize = 0,
    releases: usize = 0,

    fn self(raw: ?*anyopaque) *Fixture {
        return @ptrCast(@alignCast(raw.?));
    }
    fn get(raw: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8, max: usize, control: loaders.Control) !loaders.Response {
        const fixture = self(raw);
        try control.check();
        if (!fixture.acquired) return error.FixtureLeaseNotHeld;
        const urls = [_][]const u8{ catalog_url, installer_url, installer_url ++ ".sha1", processor_url, processor_url ++ ".sha1" };
        const bodies = [_][]const u8{ "{\"1.20.1\":[\"1.20.1-47.2.0\"]}", fixture.installer, fixture.installer_sha1, fixture.processor, fixture.processor_sha1 };
        for (urls, bodies, 0..) |expected, body, index| {
            if (!std.mem.eql(u8, url, expected)) continue;
            if (body.len > max) return error.ResourceLimit;
            fixture.calls[index] += 1;
            const bytes = try allocator.dupe(u8, body);
            errdefer allocator.free(bytes);
            return .{ .status = 200, .bytes = bytes, .final_url = try allocator.dupe(u8, url) };
        }
        return error.UnexpectedFixtureUrl;
    }
    fn acquire(raw: ?*anyopaque, id: []const u8) !void {
        const fixture = self(raw);
        if (!std.mem.eql(u8, id, fixture_id) or fixture.acquired) return error.InvalidFixtureLease;
        fixture.acquired = true;
        fixture.acquires += 1;
    }
    fn recheck(raw: ?*anyopaque, id: []const u8) !void {
        const fixture = self(raw);
        if (!std.mem.eql(u8, id, fixture_id) or !fixture.acquired) return error.InvalidFixtureLease;
        fixture.rechecks += 1;
    }
    fn release(raw: ?*anyopaque, id: []const u8) void {
        const fixture = self(raw);
        std.debug.assert(fixture.acquired and std.mem.eql(u8, id, fixture_id));
        fixture.acquired = false;
        fixture.releases += 1;
    }
};

// Fixture-only receipt reader; this does not exercise packmanager integration.
fn fixtureArtifactBinding(receipt: std.json.Value, artifact_path: []const u8) !std.json.Value {
    if (receipt != .object) return error.InvalidArtifactBinding;
    const bindings = receipt.object.get("artifact_bindings") orelse return error.MissingArtifactBinding;
    if (bindings != .array) return error.InvalidArtifactBinding;
    var matching: ?std.json.Value = null;
    for (bindings.array.items) |binding| {
        if (binding != .object or binding.object.count() != 3) return error.InvalidArtifactBinding;
        const path = binding.object.get("path") orelse return error.InvalidArtifactBinding;
        const sha256 = binding.object.get("sha256") orelse return error.InvalidArtifactBinding;
        const size = binding.object.get("size") orelse return error.InvalidArtifactBinding;
        if (path != .string or sha256 != .string or size != .integer or size.integer < 0) return error.InvalidArtifactBinding;
        if (!std.mem.startsWith(u8, path.string, "libraries/") or std.mem.indexOfScalar(u8, path.string, '\\') != null) return error.InvalidArtifactBinding;
        var components = std.mem.splitScalar(u8, path.string, '/');
        while (components.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidArtifactBinding;
        }
        if (sha256.string.len != 64) return error.InvalidArtifactBinding;
        for (sha256.string) |digit| {
            if (!(digit >= '0' and digit <= '9') and !(digit >= 'a' and digit <= 'f')) return error.InvalidArtifactBinding;
        }
        if (!std.mem.eql(u8, path.string, artifact_path)) continue;
        if (matching != null) return error.DuplicateArtifactBinding;
        matching = binding;
    }
    return matching orelse error.MissingArtifactBinding;
}

fn fixtureCopiedArtifactMatches(receipt: std.json.Value, artifact_path: []const u8, copied_path: []const u8, control: loaders.Control) !void {
    const binding = try fixtureArtifactBinding(receipt, artifact_path);
    const bytes = try files.read(a, io, copied_path, 1024 * 1024, control);
    defer a.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const sha256 = std.fmt.bytesToHex(&digest, .lower);
    if (!std.mem.eql(u8, binding.object.get("sha256").?.string, &sha256) or
        @as(u64, @intCast(binding.object.get("size").?.integer)) != bytes.len) return error.ArtifactBindingMismatch;
}

const ProfileSha1 = enum { present, absent, explicit_null };

fn pipeline(bad_output_hash: bool, profile_sha1: ProfileSha1, bad_sidecar_hash: bool) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const java = std.mem.span(std.c.getenv("VELA_JAVA_PROCESS_FIXTURE") orelse return error.MissingNativeProcessFixture);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const g = arena.allocator();
    var path_buffer: [4096]u8 = undefined;
    const root = try g.dupe(u8, path_buffer[0..try tmp.dir.realPath(io, &path_buffer)]);
    const control: loaders.Control = .{ .deadline_ms = now(null) + 10_000, .now_ms = now };
    const client_hash = std.fmt.bytesToHex(&loaders.recipes.digest("abc"), .lower);
    const processor = try storedZip(g, &.{.{ .path = "META-INF/MANIFEST.MF", .bytes = "Manifest-Version: 1.0\r\nMain-Class: net.minecraftforge.fixture.Main\r\n\r\n" }});
    const processor_hash = std.fmt.bytesToHex(&loaders.recipes.digest(processor), .lower);
    const output_hash = std.fmt.bytesToHex(&loaders.recipes.digest(if (bad_output_hash) "bad" else "abc"), .lower);
    const quoted_output_hash = try std.fmt.allocPrint(g, "'{s}'", .{output_hash});
    const artifact_json = switch (profile_sha1) {
        .present => try std.json.Stringify.valueAlloc(g, .{ .path = processor_path, .url = processor_url, .sha1 = processor_hash, .size = processor.len }, .{}),
        .absent => try std.json.Stringify.valueAlloc(g, .{ .path = processor_path, .url = processor_url, .size = processor.len }, .{}),
        .explicit_null => try std.json.Stringify.valueAlloc(g, .{ .path = processor_path, .url = processor_url, .sha1 = @as(?[]const u8, null), .size = processor.len }, .{}),
    };
    var profile_artifact = try std.json.parseFromSlice(std.json.Value, g, artifact_json, .{});
    defer profile_artifact.deinit();
    const profile = try std.json.Stringify.valueAlloc(g, .{
        .minecraft = "1.20.1",
        .json = "/version.json",
        .libraries = .{.{ .name = "net.minecraftforge:fixture:1", .downloads = .{ .artifact = profile_artifact.value } }},
        .data = .{
            .OUTPUT = .{ .client = "[net.minecraftforge:generated:1]", .server = "[net.minecraftforge:generated:1]" },
            .HASH = .{ .client = quoted_output_hash, .server = quoted_output_hash },
        },
        .processors = .{.{ .sides = .{"client"}, .jar = "net.minecraftforge:fixture:1", .classpath = .{}, .args = .{ "--write-output", "{OUTPUT}" }, .outputs = .{ .@"{OUTPUT}" = "{HASH}" } }},
    }, .{});
    const version = try std.json.Stringify.valueAlloc(g, .{
        .id = "forge-fixture",
        .inheritsFrom = "1.20.1",
        .mainClass = "net.minecraftforge.fixture.Game",
        .libraries = .{.{ .name = "net.minecraftforge:generated:1", .downloads = .{ .artifact = .{ .path = generated_path["libraries/".len..], .url = "", .sha1 = client_hash, .size = 3 } } }},
    }, .{});
    const installer = try storedZip(g, &.{ .{ .path = "install_profile.json", .bytes = profile }, .{ .path = "version.json", .bytes = version } });
    const installer_hash = std.fmt.bytesToHex(&loaders.recipes.digest(installer), .lower);
    const sidecar_hash = std.fmt.bytesToHex(&loaders.recipes.digest(if (bad_sidecar_hash) "bad" else processor), .lower);
    var fixture: Fixture = .{ .installer = installer, .installer_sha1 = &installer_hash, .processor = processor, .processor_sha1 = &sidecar_hash };
    const base_json = try std.json.Stringify.valueAlloc(g, .{
        .id = "1.20.1",
        .mainClass = "vanilla.Main",
        .javaVersion = .{ .component = "java-runtime-gamma", .majorVersion = 17 },
        .libraries = .{},
        .downloads = .{ .client = .{ .url = "https://piston-data.mojang.com/client.jar", .sha1 = client_hash, .size = 3 } },
    }, .{});
    var base = try m.version.parseSlice(a, base_json);
    defer base.deinit();
    const base_directory = try std.fs.path.join(g, &.{ root, "private-base" });
    const client_path = try std.fs.path.join(g, &.{ base_directory, "1.20.1.jar" });
    try files.write(io, client_path, "abc", control);
    const options: install.Options = .{
        .root = root,
        .instance_id = fixture_id,
        .instance_name = fixture_name,
        .selection = .{ .kind = .forge, .base_id = "1.20.1", .loader_id = "1.20.1-47.2.0" },
        .base = base.value,
        .base_plan = .{ .files = &.{}, .native_extractions = &.{}, .classpath = &.{client_path}, .client_path = client_path },
        .base_directory = base_directory,
        .environment = .{ .os_name = "linux", .arch = "x86_64" },
        .java = java,
        .lease = .{ .context = &fixture, .acquire = Fixture.acquire, .recheck = Fixture.recheck, .release = Fixture.release },
        .transport = .{ .context = &fixture, .get = Fixture.get },
    };
    const final_directory = try std.fs.path.join(g, &.{ root, ".minecraft/versions", fixture_name });
    const shared_generated = try std.fs.path.join(g, &.{ root, ".minecraft", generated_path });
    if (bad_output_hash or bad_sidecar_hash) {
        try std.testing.expectError(error.ChecksumMismatch, install.install(a, io, options, control));
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, final_directory, .{ .follow_symlinks = false }));
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, shared_generated, .{ .follow_symlinks = false }));
        const shared_processor = try std.fs.path.join(g, &.{ root, ".minecraft/libraries", processor_path });
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, shared_processor, .{ .follow_symlinks = false }));
        try std.testing.expectEqual(@as(usize, 0), fixture.rechecks);
    } else {
        var installed = try install.install(a, io, options, control);
        defer installed.deinit();
        try std.testing.expectEqualStrings(fixture_id, installed.instance_id);
        try std.testing.expectEqualStrings(fixture_name, installed.instance_name);
        try std.testing.expectEqualStrings("1.20.1-47.2.0", installed.loader_version);
        try std.testing.expectEqual(@as(u64, 17), installed.game_java_major);
        const descriptor = try files.read(a, io, installed.version_document, 1024 * 1024, control);
        defer a.free(descriptor);
        var parsed = try m.version.parseSlice(a, descriptor);
        defer parsed.deinit();
        try std.testing.expectEqualStrings(fixture_name, parsed.value.id);
        try std.testing.expect(parsed.value.inherits_from == null);
        try std.testing.expectEqualStrings("net.minecraftforge.fixture.Game", parsed.value.main_class.?);
        try std.testing.expectEqual(@as(u64, 17), m.version.requiredJavaMajor(parsed.value));
        try std.testing.expectEqualStrings("net.minecraftforge:generated:1", parsed.value.libraries.?[0].name);
        const staged_generated = try std.fs.path.join(g, &.{ final_directory, generated_path });
        for ([_][]const u8{ staged_generated, shared_generated, try std.fs.path.join(g, &.{ final_directory, fixture_name ++ ".jar" }), client_path }) |path| {
            const bytes = try files.read(a, io, path, 1024, control);
            defer a.free(bytes);
            try std.testing.expectEqualStrings("abc", bytes);
        }
        const receipt = try files.read(a, io, try std.fs.path.join(g, &.{ final_directory, ".vela-loader.json" }), 4096, control);
        defer a.free(receipt);
        var parsed_receipt = try std.json.parseFromSlice(std.json.Value, a, receipt, .{});
        defer parsed_receipt.deinit();
        try std.testing.expectEqualStrings("forge", parsed_receipt.value.object.get("loader").?.string);
        try std.testing.expectEqualStrings(&installer_hash, parsed_receipt.value.object.get("source_sha1").?.string);
        var metadata_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(descriptor, &metadata_digest, .{});
        const metadata_sha256 = std.fmt.bytesToHex(&metadata_digest, .lower);
        var client_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("abc", &client_digest, .{});
        const client_sha256 = std.fmt.bytesToHex(&client_digest, .lower);
        try std.testing.expectEqualStrings(&metadata_sha256, parsed_receipt.value.object.get("metadata_sha256").?.string);
        try std.testing.expectEqualStrings(&client_sha256, parsed_receipt.value.object.get("client_sha256").?.string);
        try std.testing.expectEqual(@as(i64, 3), parsed_receipt.value.object.get("client_size").?.integer);
        try std.testing.expectEqualStrings(fixture_name ++ ".jar", parsed_receipt.value.object.get("client_jar").?.string);
        const bindings = parsed_receipt.value.object.get("artifact_bindings").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), bindings.len);
        // The generated runtime can only exist after the synthetic processor succeeds.
        try std.testing.expectEqualStrings(generated_path["libraries/".len..], parsed.value.libraries.?[0].downloads.?.artifact.?.path.?);
        const bound_processor_path = "libraries/" ++ processor_path;
        for ([_][]const u8{ bound_processor_path, generated_path }) |artifact_path| {
            for ([_][]const u8{ final_directory, try std.fs.path.join(g, &.{ root, ".minecraft" }) }) |library_root| {
                const physical_path = try std.fs.path.join(g, &.{ library_root, artifact_path });
                try fixtureCopiedArtifactMatches(parsed_receipt.value, artifact_path, physical_path, control);
                const bytes = try files.read(a, io, physical_path, 1024 * 1024, control);
                defer a.free(bytes);
                try std.testing.expectEqualStrings(if (std.mem.eql(u8, artifact_path, generated_path)) "abc" else processor, bytes);
            }
        }
        for (bindings) |binding| {
            const path = binding.object.get("path").?.string;
            try std.testing.expect(std.mem.eql(u8, path, bound_processor_path) or std.mem.eql(u8, path, generated_path));
            try std.testing.expect(!std.mem.endsWith(u8, path, ".sha1"));
            try std.testing.expect(std.mem.indexOf(u8, path, ".loader") == null);
        }
        const copied_library = try std.fs.path.join(g, &.{ root, "copied-library.jar" });
        try files.copy(io, try std.fs.path.join(g, &.{ root, ".minecraft", bound_processor_path }), copied_library, 1024 * 1024, control);
        try fixtureCopiedArtifactMatches(parsed_receipt.value, bound_processor_path, copied_library, control);
        const tampered = try g.dupe(u8, processor);
        tampered[0] ^= 1;
        try tmp.dir.deleteFile(io, "copied-library.jar");
        try files.write(io, copied_library, tampered, control);
        try std.testing.expectError(error.ArtifactBindingMismatch, fixtureCopiedArtifactMatches(parsed_receipt.value, bound_processor_path, copied_library, control));
        var missing_binding = try std.json.parseFromSlice(std.json.Value, a, receipt, .{});
        defer missing_binding.deinit();
        const copied_bindings = missing_binding.value.object.getPtr("artifact_bindings").?;
        for (copied_bindings.array.items, 0..) |binding, index| {
            if (!std.mem.eql(u8, binding.object.get("path").?.string, bound_processor_path)) continue;
            _ = copied_bindings.array.orderedRemove(index);
            break;
        }
        try tmp.dir.deleteFile(io, "copied-library.jar");
        try files.write(io, copied_library, processor, control);
        try std.testing.expectError(error.MissingArtifactBinding, fixtureCopiedArtifactMatches(missing_binding.value, bound_processor_path, copied_library, control));
        try std.testing.expectEqual(@as(usize, 1), fixture.rechecks);
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.acquires);
    try std.testing.expectEqual(@as(usize, 1), fixture.releases);
    try std.testing.expect(!fixture.acquired);
    for (fixture.calls[0..4]) |count| try std.testing.expect(count > 0);
    try std.testing.expectEqual(@as(usize, if (profile_sha1 == .present) 0 else 1), fixture.calls[4]);
    var versions = try std.Io.Dir.cwd().openDir(io, try std.fs.path.join(g, &.{ root, ".minecraft/versions" }), .{ .iterate = true });
    defer versions.close(io);
    var iterator = versions.iterate();
    while (try iterator.next(io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".loader-"));
}

test "production Forge pipeline uses synthetic direct Java and atomically publishes verified output" {
    try pipeline(false, .present, false);
}

test "production Forge pipeline rejects processor output checksum and removes private stage" {
    try pipeline(true, .present, false);
}

test "production Forge pipeline binds downloaded libraries with absent profile SHA1" {
    try pipeline(false, .absent, false);
}

test "production Forge pipeline binds downloaded libraries with null profile SHA1" {
    try pipeline(false, .explicit_null, false);
}

test "production Forge pipeline rejects library sidecar checksum before publication" {
    try pipeline(false, .absent, true);
}
