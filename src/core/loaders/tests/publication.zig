//! Local transaction fixtures for the actual production loader installer.
const std = @import("std");
const install = @import("../install.zig");
const loaders = @import("../root.zig");
const files = @import("../files.zig");
const m = @import("../../minecraft/metadata/root.zig");
const plan_module = @import("../../minecraft/install_plan.zig");
const namespace = @import("../../instance_namespace.zig");
const worlds = @import("../../worlds.zig");
const A = std.mem.Allocator;
const io = std.testing.io;
const base_id = "1.20.1";
const custom_name = "Custom world \u{4e16}\u{754c}";
const catalog_url = "https://meta.fabricmc.net/v2/versions/loader/1.20.1";
const profile_url = catalog_url ++ "/0.15.0/profile/json";
const artifact_url = "https://maven.fabricmc.net/fixture/loader/1.0/loader-1.0.jar";
const artifact_relative = "libraries/fixture/loader/1.0/loader-1.0.jar";
const catalog_json =
    \\[{"loader":{"version":"0.15.0","stable":true}}]
;
const profile_json =
    \\{"id":"fabric-loader-0.15.0-1.20.1","inheritsFrom":"1.20.1","mainClass":"net.fabricmc.loader.impl.launch.knot.KnotClient","libraries":[]}
;
const library_profile_json =
    \\{"id":"fabric-loader-0.15.0-1.20.1","inheritsFrom":"1.20.1","mainClass":"net.fabricmc.loader.impl.launch.knot.KnotClient","libraries":[{"name":"fixture:loader:1.0","downloads":{"artifact":{"path":"fixture/loader/1.0/loader-1.0.jar","url":"https://maven.fabricmc.net/fixture/loader/1.0/loader-1.0.jar","sha1":"a9993e364706816aba3e25717850c26c9cd0d89d","size":3}}}]}
;
const sidecar_profile_json =
    \\{"id":"fabric-loader-0.15.0-1.20.1","inheritsFrom":"1.20.1","mainClass":"net.fabricmc.loader.impl.launch.knot.KnotClient","libraries":[{"name":"fixture:loader:1.0","downloads":{"artifact":{"path":"fixture/loader/1.0/loader-1.0.jar","url":"https://maven.fabricmc.net/fixture/loader/1.0/loader-1.0.jar","size":3}}}]}
;
const null_sha1_profile_json =
    \\{"id":"fabric-loader-0.15.0-1.20.1","inheritsFrom":"1.20.1","mainClass":"net.fabricmc.loader.impl.launch.knot.KnotClient","libraries":[{"name":"fixture:loader:1.0","downloads":{"artifact":{"path":"fixture/loader/1.0/loader-1.0.jar","url":"https://maven.fabricmc.net/fixture/loader/1.0/loader-1.0.jar","sha1":null,"size":3}}}]}
;
const alias_artifact_url = "https://maven.fabricmc.net/Fixture/loader/1.0/loader-1.0.jar";
const alias_profile_json =
    \\{"id":"fabric-loader-0.15.0-1.20.1","inheritsFrom":"1.20.1","mainClass":"net.fabricmc.loader.impl.launch.knot.KnotClient","libraries":[{"name":"fixture:loader:1.0","downloads":{"artifact":{"path":"fixture/loader/1.0/loader-1.0.jar","url":"https://maven.fabricmc.net/fixture/loader/1.0/loader-1.0.jar","size":3}}},{"name":"Fixture:loader:1.0","downloads":{"artifact":{"path":"Fixture/loader/1.0/loader-1.0.jar","url":"https://maven.fabricmc.net/Fixture/loader/1.0/loader-1.0.jar","sha1":null,"size":3}}}]}
;
const trusted_sidecar_sha1 = "a9993e364706816aba3e25717850c26c9cd0d89d\n";
const abc_sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const base_json =
    \\{"id":"1.20.1","type":"release","mainClass":"net.minecraft.client.main.Main","time":"2023-06-12T12:00:00Z","releaseTime":"2023-06-12T12:00:00Z","minimumLauncherVersion":21,"complianceLevel":1,"javaVersion":{"component":"java-runtime-gamma","majorVersion":17},"downloads":{"client":{"url":"https://libraries.minecraft.net/client.jar","sha1":"a9993e364706816aba3e25717850c26c9cd0d89d","size":3}},"libraries":[],"arguments":{"game":["--base-argument"],"jvm":["-Dbase=true"]},"assetIndex":{"id":"fixture-assets","url":"https://libraries.minecraft.net/assets.json","sha1":"a9993e364706816aba3e25717850c26c9cd0d89d","size":3,"totalSize":3},"assets":"fixture-assets","logging":{"client":{"argument":"-Dlog.config=fixture","type":"log4j2-xml","file":{"id":"fixture.xml","url":"https://libraries.minecraft.net/fixture.xml","sha1":"a9993e364706816aba3e25717850c26c9cd0d89d","size":3}}}}
;
fn now(_: ?*anyopaque) u64 {
    return 0;
}
const unrestricted: loaders.Control = .{ .now_ms = now, .deadline_ms = std.math.maxInt(u64) };
const Mode = enum { success, malformed, cancel_profile, running, cache_mismatch, sidecar, null_sha1, sidecar_mismatch, case_alias };

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    minecraft: []const u8,
    base_directory: []const u8,
    base_document: []const u8,
    client_path: []const u8,
    native_path: []const u8,
    asset_source: []const u8,
    asset_destination: []const u8,
    cache_path: []const u8,
    final_path: []const u8,
    base: m.Owned(m.version.Version),
    private_base: bool,
    mode: Mode = .success,
    acquired: usize = 0,
    rechecked: usize = 0,
    released: usize = 0,
    requests: usize = 0,
    sidecar_requests: usize = 0,
    artifact_requests: usize = 0,
    cancel: std.atomic.Value(bool) = .init(false),
    namespace_token: ?namespace.Token = null,
    probe_namespace: bool = false,
    gate_available_probes: usize = 0,

    fn init(private_base: bool) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const g = arena.allocator();
        const root = try tmp.dir.realPathFileAlloc(io, ".", g);
        const minecraft = try std.fmt.allocPrint(g, "{s}/.minecraft", .{root});
        const base_directory = try std.fmt.allocPrint(g, "{s}/{s}", .{ root, if (private_base) "private-base" else ".minecraft/versions/1.20.1" });
        const base_document = try std.fmt.allocPrint(g, "{s}/1.20.1.json", .{base_directory});
        const client_path = try std.fmt.allocPrint(g, "{s}/1.20.1.jar", .{base_directory});
        const native_path = try std.fmt.allocPrint(g, "{s}/natives", .{base_directory});
        const asset_source = try std.fmt.allocPrint(g, "{s}/assets/objects/a9/a9993e364706816aba3e25717850c26c9cd0d89d", .{minecraft});
        const asset_destination = try std.fmt.allocPrint(g, "{s}/resources/sound/fixture.ogg", .{base_directory});
        const cache_path = try std.fmt.allocPrint(g, "{s}/{s}", .{ minecraft, artifact_relative });
        const final_path = try std.fmt.allocPrint(g, "{s}/versions/{s}", .{ minecraft, custom_name });
        try files.write(io, base_document, base_json, unrestricted);
        try files.write(io, client_path, "abc", unrestricted);
        try files.write(io, try std.fmt.allocPrint(g, "{s}/nested/native.bin", .{native_path}), "native-state", unrestricted);
        try files.write(io, asset_source, "abc", unrestricted);
        try files.write(io, asset_destination, "abc", unrestricted);
        const base = try m.version.parseSlice(std.testing.allocator, base_json);
        return .{ .tmp = tmp, .arena = arena, .root = root, .minecraft = minecraft, .base_directory = base_directory, .base_document = base_document, .client_path = client_path, .native_path = native_path, .asset_source = asset_source, .asset_destination = asset_destination, .cache_path = cache_path, .final_path = final_path, .base = base, .private_base = private_base };
    }
    fn deinit(f: *Fixture) void {
        f.base.deinit();
        f.tmp.cleanup();
        f.arena.deinit();
    }
    fn self(raw: ?*anyopaque) *Fixture {
        return @ptrCast(@alignCast(raw.?));
    }
    fn probeNamespace(f: *Fixture) !void {
        if (!f.probe_namespace) return;
        try std.testing.expectError(error.InstanceNamespaceBusy, namespace.acquire(io));
        try std.testing.expect(worlds.transaction_gate.tryLock());
        worlds.transaction_gate.unlock(io);
        f.gate_available_probes += 1;
    }
    fn acquire(raw: ?*anyopaque, id: []const u8) !void {
        const f = self(raw);
        try f.probeNamespace();
        try std.testing.expectEqualStrings("fixture-instance", id);
        try std.testing.expectEqual(@as(usize, 0), f.acquired);
        f.acquired += 1;
    }
    fn recheck(raw: ?*anyopaque, id: []const u8) !void {
        const f = self(raw);
        try f.probeNamespace();
        try std.testing.expectEqualStrings("fixture-instance", id);
        try std.testing.expectEqual(@as(usize, 1), f.acquired);
        try std.testing.expectEqual(@as(usize, 0), f.released);
        try f.expectAbsent(f.final_path);
        f.rechecked += 1;
        if (f.mode == .running) return error.InstanceRunning;
    }
    fn release(raw: ?*anyopaque, _: []const u8) void {
        self(raw).probeNamespace() catch unreachable;
        self(raw).released += 1;
    }
    fn profile(f: *Fixture) []const u8 {
        return switch (f.mode) {
            .malformed => "{}",
            .cache_mismatch => library_profile_json,
            .sidecar, .sidecar_mismatch => sidecar_profile_json,
            .case_alias => alias_profile_json,
            .null_sha1 => null_sha1_profile_json,
            else => profile_json,
        };
    }
    fn get(raw: ?*anyopaque, a: A, url: []const u8, max: usize, request_control: loaders.Control) !loaders.Response {
        const f = self(raw);
        try f.probeNamespace();
        try request_control.check();
        f.requests += 1;
        const body: []const u8 = if (std.mem.eql(u8, url, catalog_url)) catalog_json else if (std.mem.eql(u8, url, profile_url)) f.profile() else if (std.mem.eql(u8, url, artifact_url ++ ".sha1") or std.mem.eql(u8, url, alias_artifact_url ++ ".sha1")) blk: {
            f.sidecar_requests += 1;
            break :blk if (f.mode == .sidecar_mismatch) "0000000000000000000000000000000000000000\n" else trusted_sidecar_sha1;
        } else if (std.mem.eql(u8, url, artifact_url) or std.mem.eql(u8, url, alias_artifact_url)) blk: {
            f.artifact_requests += 1;
            break :blk "abc";
        } else return error.UnexpectedFixtureUrl;
        try std.testing.expect(body.len <= max);
        const bytes = try a.dupe(u8, body);
        errdefer a.free(bytes);
        const final_url = try a.dupe(u8, url);
        if (f.mode == .cancel_profile and std.mem.eql(u8, url, profile_url)) f.cancel.store(true, .release);
        return .{ .bytes = bytes, .final_url = final_url, .status = 200 };
    }
    fn control(f: *Fixture) loaders.Control {
        return .{ .cancel = &f.cancel, .now_ms = now, .deadline_ms = std.math.maxInt(u64) };
    }
    fn run(f: *Fixture, a: A) !install.Installed {
        return f.runWithIo(a, io);
    }
    fn runWithIo(f: *Fixture, a: A, install_io: std.Io) !install.Installed {
        const hash = f.base.value.downloads[0].download.sha1.?;
        const assets = [_]plan_module.AssetMaterialization{.{ .source_path = f.asset_source, .destination = f.asset_destination, .sha1 = hash, .size = 3 }};
        const natives = [_]plan_module.NativeExtraction{.{ .archive_path = f.client_path, .destination = f.native_path, .exclude = &.{} }};
        const base_plan: plan_module.Plan = .{ .files = &.{}, .native_extractions = &natives, .classpath = &.{f.client_path}, .client_path = f.client_path, .asset_materializations = &assets };
        return install.install(a, install_io, .{
            .root = f.root,
            .instance_id = "fixture-instance",
            .instance_name = custom_name,
            .selection = .{ .kind = .fabric, .base_id = base_id, .loader_id = "0.15.0" },
            .base = f.base.value,
            .base_plan = base_plan,
            .base_directory = f.base_directory,
            .environment = .{ .os_name = "linux", .arch = "x86_64" },
            .namespace_token = f.namespace_token,
            .lease = .{ .context = f, .acquire = acquire, .recheck = recheck, .release = release },
            .transport = .{ .context = f, .get = get },
        }, f.control());
    }
    fn expectBytes(_: *Fixture, path: []const u8, expected: []const u8) !void {
        const bytes = try files.read(std.testing.allocator, io, path, 1024 * 1024, unrestricted);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
    }
    fn expectAbsent(_: *Fixture, path: []const u8) !void {
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }));
    }
    fn expectBasePreserved(f: *Fixture) !void {
        try f.expectBytes(f.base_document, base_json);
        try f.expectBytes(f.client_path, "abc");
        try f.expectBytes(f.asset_destination, "abc");
        try f.expectBytes(f.asset_source, "abc");
        try f.expectBytes(try std.fmt.allocPrint(f.arena.allocator(), "{s}/nested/native.bin", .{f.native_path}), "native-state");
    }
    fn expectNoStage(f: *Fixture) !void {
        const versions_path = try std.fmt.allocPrint(f.arena.allocator(), "{s}/versions", .{f.minecraft});
        var versions = std.Io.Dir.cwd().openDir(io, versions_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer versions.close(io);
        var iterator = versions.iterate();
        while (try iterator.next(io)) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".loader-"));
    }
    fn expectRollback(f: *Fixture) !void {
        try f.expectAbsent(f.final_path);
        try f.expectNoStage();
        try f.expectBasePreserved();
        try std.testing.expectEqual(f.acquired, f.released);
    }
    fn expectReceiptBinding(f: *Fixture, receipt: std.json.Value, descriptor: []const u8) !void {
        try std.testing.expectEqualStrings(base_id, receipt.object.get("minecraft_version").?.string);
        try std.testing.expectEqualStrings("fabric", receipt.object.get("loader").?.string);
        try std.testing.expectEqualStrings("0.15.0", receipt.object.get("loader_version").?.string);
        var metadata_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(descriptor, &metadata_hash, .{});
        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(&metadata_hash, .lower), receipt.object.get("metadata_sha256").?.string);
        const client_jar = try std.fmt.allocPrint(f.arena.allocator(), "{s}.jar", .{custom_name});
        try std.testing.expectEqualStrings(client_jar, receipt.object.get("client_jar").?.string);
        const client_path = try std.fmt.allocPrint(f.arena.allocator(), "{s}/{s}", .{ f.final_path, client_jar });
        const client = try files.read(std.testing.allocator, io, client_path, 1024 * 1024, unrestricted);
        defer std.testing.allocator.free(client);
        var client_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(client, &client_hash, .{});
        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(&client_hash, .lower), receipt.object.get("client_sha256").?.string);
        try std.testing.expectEqual(@as(i64, @intCast(client.len)), receipt.object.get("client_size").?.integer);
    }
    fn expectArtifactBindings(f: *Fixture, receipt: std.json.Value) !void {
        var catalog = try loaders.parseCatalog(std.testing.allocator, .fabric, base_id, catalog_json);
        defer catalog.deinit();
        var recipe = try loaders.recipes.prepare(std.testing.allocator, catalog.value, .{ .kind = .fabric, .base_id = base_id, .loader_id = "0.15.0" }, f.base.value, .{ .source_url = profile_url, .profile = f.profile() }, .{ .instance_name = custom_name, .stage_root = f.final_path, .environment = .{ .os_name = "linux", .arch = "x86_64" } });
        defer recipe.deinit();
        const bindings = receipt.object.get("artifact_bindings") orelse return error.MissingArtifactBinding;
        try std.testing.expect(bindings == .array);
        try std.testing.expectEqual(recipe.value.artifacts.len, bindings.array.items.len);
        for (recipe.value.artifacts, bindings.array.items) |artifact, binding| {
            try std.testing.expect(artifact.sha1 == null);
            try std.testing.expect(binding == .object);
            try std.testing.expectEqual(@as(usize, 6), binding.object.count());
            try std.testing.expect(binding.object.get("expected_sha1").? == .null);
            try std.testing.expect(binding.object.get("producer").? == .null);
            try std.testing.expect(binding.object.get("installer_member").? == .null);
            const relative = binding.object.get("path").?.string;
            try std.testing.expectEqualStrings(artifact.path, relative);
            try std.testing.expectEqualStrings(artifact_relative, relative);
            try expectCanonicalLibraryPath(relative);
            try std.testing.expect(!std.mem.endsWith(u8, relative, ".sha1"));
            const library = try std.fmt.allocPrint(f.arena.allocator(), "{s}/{s}", .{ f.final_path, relative });
            try f.expectBytes(library, "abc");
            try f.expectBytes(f.cache_path, "abc");
            const bytes = try files.read(std.testing.allocator, io, library, 1024 * 1024, unrestricted);
            defer std.testing.allocator.free(bytes);
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            const hash = binding.object.get("sha256").?.string;
            try expectLowerSha256(hash);
            try std.testing.expectEqualStrings(abc_sha256, hash);
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(&digest, .lower), hash);
            const stat = try std.Io.Dir.cwd().statFile(io, library, .{ .follow_symlinks = false });
            try std.testing.expectEqual(@as(u64, 3), stat.size);
            const size = binding.object.get("size").?;
            try std.testing.expect(size == .integer and size.integer >= 0);
            try std.testing.expectEqual(stat.size, @as(u64, @intCast(size.integer)));
            try std.testing.expectEqual(@as(u64, @intCast(bytes.len)), @as(u64, @intCast(size.integer)));
            try fixtureReaderExpectArtifact(receipt, relative, library);
        }
    }
    fn expectPublished(f: *Fixture, result: install.Installed) !void {
        try std.testing.expectEqualStrings("fixture-instance", result.instance_id);
        try std.testing.expectEqualStrings(custom_name, result.instance_name);
        try std.testing.expectEqualStrings(f.final_path, result.game_directory);
        try std.testing.expectEqualStrings("0.15.0", result.loader_version);
        try std.testing.expectEqual(@as(u64, 17), result.game_java_major);
        const g = f.arena.allocator();
        const expected_document = try std.fmt.allocPrint(g, "{s}/{s}.json", .{ f.final_path, custom_name });
        try std.testing.expectEqualStrings(expected_document, result.version_document);
        const bytes = try files.read(std.testing.allocator, io, result.version_document, 1024 * 1024, unrestricted);
        defer std.testing.allocator.free(bytes);
        var resolved = try m.version.parseSlice(std.testing.allocator, bytes);
        defer resolved.deinit();
        try std.testing.expectEqualStrings(custom_name, resolved.value.id);
        try std.testing.expectEqualStrings("net.fabricmc.loader.impl.launch.knot.KnotClient", resolved.value.main_class.?);
        try std.testing.expect(resolved.value.inherits_from == null);
        try std.testing.expectEqualStrings(custom_name, resolved.value.jar orelse resolved.value.id);
        try std.testing.expectEqualDeep(f.base.value.downloads, resolved.value.downloads);
        try std.testing.expectEqualDeep(f.base.value.arguments, resolved.value.arguments);
        try std.testing.expectEqualDeep(f.base.value.asset_index, resolved.value.asset_index);
        try std.testing.expectEqualDeep(f.base.value.logging, resolved.value.logging);
        try std.testing.expectEqualDeep(f.base.value.java_version, resolved.value.java_version);
        try std.testing.expectEqualDeep(f.base.value.release_time, resolved.value.release_time);
        try std.testing.expectEqualDeep(f.base.value.time, resolved.value.time);
        try std.testing.expectEqualDeep(f.base.value.kind, resolved.value.kind);
        try std.testing.expectEqualDeep(f.base.value.minimum_launcher_version, resolved.value.minimum_launcher_version);
        try std.testing.expectEqualDeep(f.base.value.compliance_level, resolved.value.compliance_level);
        try std.testing.expectEqualDeep(f.base.value.assets, resolved.value.assets);
        try f.expectBytes(try std.fmt.allocPrint(g, "{s}/{s}.jar", .{ f.final_path, custom_name }), "abc");
        try f.expectBytes(try std.fmt.allocPrint(g, "{s}/natives/nested/native.bin", .{f.final_path}), "native-state");
        try f.expectBytes(try std.fmt.allocPrint(g, "{s}/resources/sound/fixture.ogg", .{f.final_path}), "abc");
        const receipt = try files.read(std.testing.allocator, io, try std.fmt.allocPrint(g, "{s}/.vela-loader.json", .{f.final_path}), 64 * 1024, unrestricted);
        defer std.testing.allocator.free(receipt);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, receipt, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(profile_url, parsed.value.object.get("source_url").?.string);
        var profile_hash: m.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(f.profile(), &profile_hash, .{});
        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(&profile_hash, .lower), parsed.value.object.get("source_sha1").?.string);
        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(&profile_hash, .lower), parsed.value.object.get("profile_sha1").?.string);
        try f.expectReceiptBinding(parsed.value, bytes);
        try f.expectArtifactBindings(parsed.value);
        try std.testing.expectEqual(@as(usize, 1), f.acquired);
        try std.testing.expectEqual(@as(usize, 1), f.rechecked);
        try std.testing.expectEqual(@as(usize, 1), f.released);
        try std.testing.expectEqual(@as(usize, if (f.mode == .sidecar or f.mode == .null_sha1) 4 else 2), f.requests);
        try f.expectBasePreserved();
        try f.expectNoStage();
    }
};

fn expectCanonicalLibraryPath(path: []const u8) !void {
    if (!std.mem.startsWith(u8, path, "libraries/") or path.len > 4096 or std.mem.indexOfAny(u8, path, "\\\x00:\r\n") != null) return error.InvalidArtifactPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidArtifactPath;
    }
}
fn expectLowerSha256(hash: []const u8) !void {
    if (hash.len != 64) return error.InvalidArtifactBinding;
    for (hash) |byte| if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) return error.InvalidArtifactBinding;
}
// Local reader expectations only; this is not the production packmanager reader.
fn fixtureReaderExpectArtifact(receipt: std.json.Value, relative: []const u8, candidate: []const u8) !void {
    try expectCanonicalLibraryPath(relative);
    if (receipt != .object) return error.InvalidArtifactBinding;
    const bindings = receipt.object.get("artifact_bindings") orelse return error.MissingArtifactBinding;
    if (bindings != .array) return error.InvalidArtifactBinding;
    var match: ?std.json.Value = null;
    for (bindings.array.items) |binding| {
        if (binding != .object) return error.InvalidArtifactBinding;
        const path = binding.object.get("path") orelse return error.InvalidArtifactBinding;
        if (path != .string) return error.InvalidArtifactBinding;
        try expectCanonicalLibraryPath(path.string);
        if (std.mem.eql(u8, path.string, relative)) {
            if (match != null) return error.DuplicateArtifactBinding;
            match = binding;
        }
    }
    const binding = match orelse return error.MissingArtifactBinding;
    const hash = binding.object.get("sha256") orelse return error.InvalidArtifactBinding;
    const size = binding.object.get("size") orelse return error.InvalidArtifactBinding;
    if (hash != .string or size != .integer or size.integer < 0) return error.InvalidArtifactBinding;
    try expectLowerSha256(hash.string);
    const stat = try std.Io.Dir.cwd().statFile(io, candidate, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size != @as(u64, @intCast(size.integer))) return error.ArtifactBindingMismatch;
    const bytes = try files.read(std.testing.allocator, io, candidate, 1024 * 1024, unrestricted);
    defer std.testing.allocator.free(bytes);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, hash.string, &std.fmt.bytesToHex(&digest, .lower))) return error.ArtifactBindingMismatch;
}

test "production Fabric hashless library persists canonical final-artifact SHA256 and size bindings" {
    for ([_]Mode{ .sidecar, .null_sha1 }) |mode| {
        var f = try Fixture.init(false);
        defer f.deinit();
        f.mode = mode;
        var trusted_sha1: m.Sha1 = undefined;
        std.crypto.hash.Sha1.hash("abc", &trusted_sha1, .{});
        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(&trusted_sha1, .lower), std.mem.trim(u8, trusted_sidecar_sha1, " \r\n\t"));
        var result = try f.run(std.testing.allocator);
        defer result.deinit();
        try f.expectPublished(result);
        try std.testing.expectEqual(@as(usize, 1), f.sidecar_requests);
        try std.testing.expectEqual(@as(usize, 1), f.artifact_requests);
        try f.expectAbsent(try std.fmt.allocPrint(f.arena.allocator(), "{s}.sha1", .{f.cache_path}));
    }
}

test "production Fabric artifact binding local reader expectations reject tampered copy and missing or legacy binding" {
    var f = try Fixture.init(false);
    defer f.deinit();
    f.mode = .sidecar;
    var result = try f.run(std.testing.allocator);
    defer result.deinit();
    try f.expectPublished(result);
    const g = f.arena.allocator();
    const receipt_bytes = try files.read(std.testing.allocator, io, try std.fmt.allocPrint(g, "{s}/.vela-loader.json", .{f.final_path}), 64 * 1024, unrestricted);
    defer std.testing.allocator.free(receipt_bytes);
    var receipt = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, receipt_bytes, .{});
    defer receipt.deinit();
    const library = try std.fmt.allocPrint(g, "{s}/{s}", .{ f.final_path, artifact_relative });
    const copied = try std.fmt.allocPrint(g, "{s}/reader-copy/{s}", .{ f.root, artifact_relative });
    try files.copy(io, library, copied, 1024 * 1024, unrestricted);
    try fixtureReaderExpectArtifact(receipt.value, artifact_relative, copied);
    try std.Io.Dir.cwd().deleteFile(io, copied);
    try files.write(io, copied, "abd", unrestricted);
    try std.testing.expectError(error.ArtifactBindingMismatch, fixtureReaderExpectArtifact(receipt.value, artifact_relative, copied));
    try std.Io.Dir.cwd().deleteFile(io, copied);
    try files.write(io, copied, "abcd", unrestricted);
    try std.testing.expectError(error.ArtifactBindingMismatch, fixtureReaderExpectArtifact(receipt.value, artifact_relative, copied));
    try std.Io.Dir.cwd().deleteFile(io, copied);
    try files.copy(io, library, copied, 1024 * 1024, unrestricted);
    const missing_receipts = [_][]const u8{
        "{\"artifact_bindings\":[]}",
        "{\"artifact_bindings\":[{\"path\":\"libraries/fixture/other/1.0/other-1.0.jar\",\"sha256\":\"" ++ abc_sha256 ++ "\",\"size\":3}]}",
        "{\"schema_version\":1,\"loader\":\"fabric\",\"loader_version\":\"0.15.0\"}",
    };
    for (missing_receipts) |bytes| {
        var missing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer missing.deinit();
        try std.testing.expectError(error.MissingArtifactBinding, fixtureReaderExpectArtifact(missing.value, artifact_relative, copied));
    }
    try fixtureReaderExpectArtifact(receipt.value, artifact_relative, library);
    try f.expectBasePreserved();
}

test "production Fabric sidecar checksum mismatch rolls back without visible custom instance" {
    var f = try Fixture.init(false);
    defer f.deinit();
    f.mode = .sidecar_mismatch;
    try std.testing.expectError(error.ChecksumMismatch, f.run(std.testing.allocator));
    try f.expectRollback();
    try f.expectAbsent(f.cache_path);
    try std.testing.expectEqual(@as(usize, 1), f.sidecar_requests);
    try std.testing.expectEqual(@as(usize, 1), f.artifact_requests);
    try std.testing.expectEqual(@as(usize, 4), f.requests);
    try std.testing.expectEqual(@as(usize, 0), f.rechecked);
}

test "production Fabric case-aliased final artifact paths roll back before publication" {
    var f = try Fixture.init(false);
    defer f.deinit();
    f.mode = .case_alias;
    try std.testing.expectError(error.DuplicateArtifactPath, f.run(std.testing.allocator));
    try f.expectRollback();
    try f.expectAbsent(f.cache_path);
    try f.expectAbsent(try std.fmt.allocPrint(f.arena.allocator(), "{s}/libraries/Fixture/loader/1.0/loader-1.0.jar", .{f.minecraft}));
    try std.testing.expectEqual(@as(usize, 2), f.sidecar_requests);
    try std.testing.expectEqual(@as(usize, 2), f.artifact_requests);
    try std.testing.expectEqual(@as(usize, 6), f.requests);
    try std.testing.expectEqual(@as(usize, 0), f.rechecked);
}

test "production Fabric adapter atomically publishes custom Unicode instance and snapshots vanilla state" {
    var f = try Fixture.init(false);
    defer f.deinit();
    var result = try f.run(std.testing.allocator);
    defer result.deinit();
    try f.expectPublished(result);
}

test "production Fabric adapter accepts private unpublished vanilla base" {
    var f = try Fixture.init(true);
    defer f.deinit();
    var result = try f.run(std.testing.allocator);
    defer result.deinit();
    try f.expectPublished(result);
}

test "production Fabric adapter rolls back malformed profile cancellation and running lease" {
    const cases = [_]struct { mode: Mode, err: anyerror, rechecks: usize }{
        .{ .mode = .malformed, .err = error.MissingField, .rechecks = 0 },
        .{ .mode = .cancel_profile, .err = error.Canceled, .rechecks = 0 },
        .{ .mode = .running, .err = error.InstanceRunning, .rechecks = 1 },
    };
    for (cases) |case| {
        var f = try Fixture.init(false);
        defer f.deinit();
        f.mode = case.mode;
        try std.testing.expectError(case.err, f.run(std.testing.allocator));
        try f.expectRollback();
        try std.testing.expectEqual(@as(usize, 1), f.acquired);
        try std.testing.expectEqual(case.rechecks, f.rechecked);
        try std.testing.expectEqual(@as(usize, 2), f.requests);
    }
}

test "production Fabric adapter never overwrites mismatching shared artifact" {
    var f = try Fixture.init(false);
    defer f.deinit();
    f.mode = .cache_mismatch;
    try files.write(io, f.cache_path, "bad", unrestricted);
    try std.testing.expectError(error.ChecksumMismatch, f.run(std.testing.allocator));
    try f.expectRollback();
    try f.expectBytes(f.cache_path, "bad");
    try std.testing.expectEqual(@as(usize, 3), f.requests);
    try std.testing.expectEqual(@as(usize, 0), f.rechecked);
}

fn allocationCase(a: A) !void {
    var f = try Fixture.init(false);
    defer f.deinit();
    var result = f.run(a) catch |err| {
        try f.expectRollback();
        return err;
    };
    defer result.deinit();
    try f.expectPublished(result);
}

test "production Fabric adapter allocation failures leave no published instance" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

const RenameFault = enum { before_move, after_move };
var rename_fault: RenameFault = .before_move;
var final_rename_calls: usize = 0;

fn faultRenamePreserve(userdata: ?*anyopaque, old_dir: std.Io.Dir, old_path: []const u8, new_dir: std.Io.Dir, new_path: []const u8) std.Io.Dir.RenamePreserveError!void {
    if (std.mem.startsWith(u8, old_path, ".loader-") and std.mem.eql(u8, new_path, custom_name)) {
        final_rename_calls += 1;
        if (rename_fault == .after_move) try io.vtable.dirRenamePreserve(userdata, old_dir, old_path, new_dir, new_path);
        return error.Unexpected;
    }
    return io.vtable.dirRenamePreserve(userdata, old_dir, old_path, new_dir, new_path);
}

test "production rename error with surviving stage rolls back and releases lease" {
    var f = try Fixture.init(false);
    defer f.deinit();
    var vtable = io.vtable.*;
    vtable.dirRenamePreserve = faultRenamePreserve;
    const fault_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    rename_fault = .before_move;
    final_rename_calls = 0;
    try std.testing.expectError(error.Unexpected, f.runWithIo(std.testing.allocator, fault_io));
    try std.testing.expectEqual(@as(usize, 1), final_rename_calls);
    try std.testing.expectEqual(@as(usize, 1), f.acquired);
    try std.testing.expectEqual(@as(usize, 1), f.rechecked);
    try std.testing.expectEqual(@as(usize, 1), f.released);
    try f.expectRollback();
}

test "production rename error after actual move preserves publication and keeps lease for recovery" {
    var f = try Fixture.init(false);
    defer f.deinit();
    var vtable = io.vtable.*;
    vtable.dirRenamePreserve = faultRenamePreserve;
    const fault_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    rename_fault = .after_move;
    final_rename_calls = 0;
    try std.testing.expectError(error.RecoveryRequired, f.runWithIo(std.testing.allocator, fault_io));
    try std.testing.expectEqual(@as(usize, 1), final_rename_calls);
    try std.testing.expectEqual(@as(usize, 1), f.acquired);
    try std.testing.expectEqual(@as(usize, 1), f.rechecked);
    try std.testing.expectEqual(@as(usize, 0), f.released);
    try std.testing.expectEqual(@as(usize, 2), f.requests);
    const g = f.arena.allocator();
    const document = try std.fmt.allocPrint(g, "{s}/{s}.json", .{ f.final_path, custom_name });
    const bytes = try files.read(std.testing.allocator, io, document, 1024 * 1024, unrestricted);
    defer std.testing.allocator.free(bytes);
    var resolved = try m.version.parseSlice(std.testing.allocator, bytes);
    defer resolved.deinit();
    try std.testing.expectEqualStrings(custom_name, resolved.value.id);
    try std.testing.expectEqualStrings(custom_name, resolved.value.jar orelse resolved.value.id);
    try std.testing.expectEqualStrings("net.fabricmc.loader.impl.launch.knot.KnotClient", resolved.value.main_class.?);
    try std.testing.expectEqualDeep(f.base.value.downloads, resolved.value.downloads);
    try f.expectBytes(try std.fmt.allocPrint(g, "{s}/{s}.jar", .{ f.final_path, custom_name }), "abc");
    try f.expectBytes(try std.fmt.allocPrint(g, "{s}/natives/nested/native.bin", .{f.final_path}), "native-state");
    try f.expectBytes(try std.fmt.allocPrint(g, "{s}/resources/sound/fixture.ogg", .{f.final_path}), "abc");
    const receipt = try files.read(std.testing.allocator, io, try std.fmt.allocPrint(g, "{s}/.vela-loader.json", .{f.final_path}), 64 * 1024, unrestricted);
    defer std.testing.allocator.free(receipt);
    var parsed_receipt = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, receipt, .{});
    defer parsed_receipt.deinit();
    try f.expectReceiptBinding(parsed_receipt.value, bytes);
    try f.expectBasePreserved();
    try f.expectNoStage();
}

test "production successful publication reports native directory durability support" {
    var f = try Fixture.init(false);
    defer f.deinit();
    var result = try f.run(std.testing.allocator);
    defer result.deinit();
    try std.testing.expectEqual(!@import("../../worlds_tree.zig").directory_sync_supported, result.durability_uncertain);
    try f.expectPublished(result);
}

test "namespace blocker rejects direct loader before versions creation or callbacks" {
    var f = try Fixture.init(true);
    defer f.deinit();
    const token = try namespace.acquire(io);
    defer token.release();
    try std.testing.expectError(error.InstanceNamespaceBusy, f.run(std.testing.allocator));
    try f.expectAbsent(try std.fmt.allocPrint(f.arena.allocator(), "{s}/versions", .{f.minecraft}));
    try std.testing.expectEqual(@as(usize, 0), f.acquired);
    try std.testing.expectEqual(@as(usize, 0), f.requests);
    try token.recheck();
}

test "borrowed loader namespace survives publication and stale stamps fail before IO" {
    var f = try Fixture.init(true);
    defer f.deinit();
    const token = try namespace.acquire(io);
    defer token.release();
    f.namespace_token = token;
    f.probe_namespace = true;
    var result = try f.run(std.testing.allocator);
    defer result.deinit();
    try f.expectPublished(result);
    try std.testing.expect(f.gate_available_probes > 0);
    try token.recheck();
    try std.testing.expectError(error.InstanceNamespaceBusy, namespace.acquire(io));
    token.release();
    const current = try namespace.acquire(io);
    defer current.release();
    var stale = try Fixture.init(true);
    defer stale.deinit();
    stale.namespace_token = token;
    try std.testing.expectError(error.InstanceNamespaceLeaseLost, stale.run(std.testing.allocator));
    try stale.expectAbsent(try std.fmt.allocPrint(stale.arena.allocator(), "{s}/versions", .{stale.minecraft}));
    try std.testing.expectEqual(@as(usize, 0), stale.acquired);
    try std.testing.expectEqual(@as(usize, 0), stale.requests);
    try current.recheck();
}

test "direct loader reservation survives rollback callbacks then releases" {
    var f = try Fixture.init(true);
    defer f.deinit();
    f.probe_namespace = true;
    f.mode = .malformed;
    try std.testing.expectError(error.MissingField, f.run(std.testing.allocator));
    try f.expectRollback();
    try std.testing.expect(f.gate_available_probes > 0);
    const next = try namespace.acquire(io);
    defer next.release();
}

const StageFault = @import("stage_owner.zig").FaultIo;

test "production loader stage acquisition rolls back native cancel and open sync faults" {
    for ([_]StageFault.Mode{ .cancel_create, .fail_open, .fail_sync }) |mode| {
        if (mode == .fail_sync and !@import("../../worlds_tree.zig").directory_sync_supported) continue;
        var f = try Fixture.init(true);
        defer f.deinit();
        var fault: StageFault = .{ .mode = mode, .prefix = ".loader-" };
        const fault_io = fault.start();
        defer fault.stop();
        const expected = switch (mode) {
            .cancel_create => error.Canceled,
            .fail_open => error.AccessDenied,
            .fail_sync => error.InputOutput,
            else => unreachable,
        };
        try std.testing.expectError(expected, f.runWithIo(std.testing.allocator, fault_io));
        try std.testing.expect(fault.created and fault.removed);
        try f.expectRollback();
    }
}

test "production loader does not swallow private stage cleanup errors" {
    var f = try Fixture.init(true);
    defer f.deinit();
    f.mode = .malformed;
    var fault: StageFault = .{ .mode = .fail_cleanup, .prefix = ".loader-" };
    const fault_io = fault.start();
    defer fault.stop();
    try std.testing.expectError(error.RecoveryRequired, f.runWithIo(std.testing.allocator, fault_io));
    try f.expectAbsent(f.final_path);
    try f.expectBasePreserved();
    try std.testing.expect(fault.created and !fault.removed);
    try std.testing.expectEqual(@as(usize, 0), f.released);
}

test "production loader completes publication after native cancellation at rename" {
    var f = try Fixture.init(true);
    defer f.deinit();
    var fault: StageFault = .{ .mode = .cancel_commit, .prefix = ".loader-" };
    const fault_io = fault.start();
    defer fault.stop();
    var result = try f.runWithIo(std.testing.allocator, fault_io);
    defer result.deinit();
    try std.testing.expect(fault.committed and fault.pending);
    try f.expectPublished(result);
    try std.testing.expectError(error.Canceled, fault_io.checkCancel());
}
