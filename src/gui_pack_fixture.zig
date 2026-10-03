//! Hermetic acceptance data. Game bytes are inert; no Minecraft/JVM execution.
//! Context stays at its final heap address until every worker has JOINed.
const std = @import("std");
const packs = @import("core/pack_import.zig");
const paths = @import("core/instances.zig");
const metadata = @import("core/minecraft/metadata/root.zig");
const metadata_loader = @import("core/minecraft/metadata_loader.zig");
const content_install = @import("core/content_install.zig");
const http = @import("core/http_transport.zig");
const controller = @import("ui/pack_import_controller.zig");
const pack_view = @import("ui/pack_import_view.zig");
const builtin = @import("builtin");
const java = @import("ui/java_manager.zig");
const instances_manager = @import("ui/instances_manager.zig");
const loader_install = @import("core/minecraft/loader_install.zig");
const loaders = @import("core/minecraft/loaders.zig");
const install_plan = @import("core/minecraft/install_plan.zig");
const serde = @import("core/minecraft/loaders_json.zig");
const A = std.mem.Allocator;
const Io = std.Io;

pub const Scene = enum { layout, pack, @"pack-prepared" };
pub const Archive = enum { modrinth, curseforge };
pub const Hold = enum { none, inspection, content, installer };

pub const Context = struct {
    allocator: A,
    archive_path: []u8,
    curseforge_path: []u8,
    archive: Archive = .modrinth,
    inner_lease: ?content_install.Lease = null,
    hold_inspection: std.atomic.Value(bool) = .init(false),
    inspection_entered: std.atomic.Value(bool) = .init(false),
    inspection_exited: std.atomic.Value(bool) = .init(false),
    hold_content: std.atomic.Value(bool) = .init(false),
    content_entered: std.atomic.Value(bool) = .init(false),
    content_released: std.atomic.Value(bool) = .init(false),
    http_requests: std.atomic.Value(usize) = .init(0),
    content_release_observer: ?*std.atomic.Value(bool) = null,
    prepared: ?PreparedData = null,
    hold_installer: std.atomic.Value(bool) = .init(false),
    installer_entered: std.atomic.Value(bool) = .init(false),
    installer_exited: std.atomic.Value(bool) = .init(false),
    proof_borrowed: std.atomic.Value(bool) = .init(false),
    validated_roles: std.atomic.Value(bool) = .init(false),
    staged: std.atomic.Value(bool) = .init(false),
    rolled_back: std.atomic.Value(bool) = .init(false),
    fail_after_staging: std.atomic.Value(bool) = .init(false),
    synthetic_requests: std.atomic.Value(usize) = .init(0),
    jvm_invocations: std.atomic.Value(usize) = .init(0),
    installer_exit_observer: ?*std.atomic.Value(bool) = null,

    pub fn init(a: A, io: Io, root: []const u8) !Context {
        const archive_path = try std.fs.path.join(a, &.{ root, "fixture-pack.mrpack" });
        errdefer a.free(archive_path);
        const curseforge_path = try std.fs.path.join(a, &.{ root, "fixture-pack-curseforge.zip" });
        errdefer a.free(curseforge_path);
        var dir = try Io.Dir.cwd().openDir(io, root, .{});
        defer dir.close(io);
        const index = "{\"formatVersion\":1,\"game\":\"minecraft\",\"versionId\":\"fixture-v1\",\"name\":\"Fixture Pack\",\"files\":[],\"dependencies\":{\"minecraft\":\"1.21.4\"}}";
        try storedZip(a, io, dir, "fixture-pack.mrpack", &.{
            .{ .path = "modrinth.index.json", .bytes = index },
            .{ .path = "overrides/config/fixture-pack.cfg", .bytes = "hermetic pack settings\n" },
        });
        const cf_manifest = "{\"manifestType\":\"minecraftModpack\",\"manifestVersion\":1,\"name\":\"Fixture Pack\",\"version\":\"fixture-v1\",\"author\":\"Fixture\",\"overrides\":\"overrides\",\"minecraft\":{\"version\":\"1.21.4\",\"modLoaders\":[]},\"files\":[]}";
        try storedZip(a, io, dir, "fixture-pack-curseforge.zip", &.{
            .{ .path = "manifest.json", .bytes = cf_manifest },
            .{ .path = "overrides/config/fixture-pack.cfg", .bytes = "hermetic pack settings\n" },
        });
        return .{ .allocator = a, .archive_path = archive_path, .curseforge_path = curseforge_path };
    }

    pub fn path(self: *const Context) []const u8 {
        if (self.prepared) |data| return data.archive_path;
        return if (self.archive == .modrinth) self.archive_path else self.curseforge_path;
    }

    pub fn releaseHolds(self: *Context) void {
        self.hold_inspection.store(false, .release);
        self.hold_content.store(false, .release);
        self.hold_installer.store(false, .release);
    }

    /// Owner must JOIN Controller/Ui/Content before calling this.
    pub fn deinit(self: *Context) void {
        if (self.prepared) |*data| data.deinit();
        self.allocator.free(self.archive_path);
        self.allocator.free(self.curseforge_path);
        self.* = undefined;
    }

    pub fn runner(self: *Context) controller.Runner {
        if (self.prepared != null) return .{ .context = self, .inspect = inspect, .manifest = syntheticManifest, .fetcher = .{ .context = self, .fetch = syntheticMetadata }, .transport = .{ .context = self, .get = syntheticGet }, .probe = markerProbe };
        return .{ .context = self, .inspect = inspect, .manifest = denyManifest, .fetcher = .{ .context = self, .fetch = denyMetadata } };
    }

    pub fn uiRunner(self: *Context) pack_view.Runner {
        // Deterministic Browse selection; inspection and cleanup remain real.
        return .{ .context = self, .pick = pick, .inspect = inspectPreview };
    }

    pub fn contentLease(self: *Context, inner: content_install.Lease) content_install.Lease {
        self.inner_lease = inner;
        return .{ .context = self, .acquire = acquire, .recheck = recheck, .release = release };
    }

    fn from(raw: ?*anyopaque) !*Context {
        return @ptrCast(@alignCast(raw orelse return error.MissingFixtureContext));
    }

    fn pick(raw: ?*anyopaque, a: A) !?[:0]const u8 {
        const self = try from(raw);
        const owned = try a.dupeZ(u8, self.path());
        return owned;
    }

    fn inspectPreview(_: ?*anyopaque, a: A, io: Io, root: *const paths.Paths, archive: []const u8, cancel: ?*const packs.CancelToken) !packs.Inspection {
        // Preview completes before a held Controller preparation is admitted.
        return packs.inspect(a, io, root, archive, cancel);
    }

    fn inspect(raw: ?*anyopaque, a: A, io: Io, root: *const paths.Paths, archive: []const u8, cancel: ?*const packs.CancelToken) !packs.Inspection {
        const self = try from(raw);
        var inspection = try packs.inspect(a, io, root, archive, cancel);
        errdefer {
            inspection.cleanup(io) catch {};
            inspection.deinit();
        }
        self.inspection_entered.store(true, .release);
        defer self.inspection_exited.store(true, .release);
        while (self.hold_inspection.load(.acquire)) {
            if (cancel) |token| if (token.load(.acquire)) return error.Canceled;
            std.Thread.yield() catch {};
        }
        if (cancel) |token| if (token.load(.acquire)) return error.Canceled;
        return inspection;
    }

    fn denyManifest(_: ?*anyopaque, _: A, _: Io, _: ?*const packs.CancelToken) !metadata.Owned(metadata.manifest.Manifest) {
        return error.FixtureMetadataUnavailable;
    }

    fn denyMetadata(_: ?*anyopaque, _: A, _: Io, _: metadata_loader.Request) ![]u8 {
        return error.FixtureMetadataUnavailable;
    }

    pub fn denyHttp(raw: ?*anyopaque, _: A, _: Io, _: http.Request) !http.Response {
        const self = try from(raw);
        _ = self.http_requests.fetchAdd(1, .monotonic);
        return error.FixtureUnexpectedHttp;
    }

    fn acquire(raw: ?*anyopaque, id: []const u8) !void {
        const self = try from(raw);
        const inner = self.inner_lease orelse return error.MissingFixtureLease;
        try inner.acquire(inner.context, id);
        self.content_released.store(false, .release);
    }

    fn recheck(raw: ?*anyopaque, id: []const u8) !void {
        const self = try from(raw);
        const inner = self.inner_lease orelse return error.MissingFixtureLease;
        try inner.recheck(inner.context, id);
        self.content_entered.store(true, .release);
        // Tests hold the worker recheck after owner-thread lease admission.
        while (self.hold_content.load(.acquire)) std.Thread.yield() catch {};
    }

    fn release(raw: ?*anyopaque, id: []const u8) void {
        const self = from(raw) catch return;
        const inner = self.inner_lease orelse return;
        inner.release(inner.context, id);
        self.content_released.store(true, .release);
        if (self.content_release_observer) |observer| observer.store(true, .release);
    }
};

const ZipEntry = struct { path: []const u8, bytes: []const u8 };
fn number(comptime T: type, a: A, bytes: *std.ArrayList(u8), value: T) !void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    try bytes.appendSlice(a, &encoded);
}
fn storedZip(a: A, io: Io, dir: Io.Dir, name: []const u8, entries: []const ZipEntry) !void {
    const bytes = try zipBytes(a, entries);
    defer a.free(bytes);
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
}
fn zipBytes(a: A, entries: []const ZipEntry) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    const offsets = try a.alloc(u32, entries.len);
    defer a.free(offsets);
    for (entries, offsets) |entry, *offset| {
        offset.* = @intCast(bytes.items.len);
        try number(u32, a, &bytes, 0x04034b50);
        for ([_]u16{ 20, 0, 0, 0, 0 }) |value| try number(u16, a, &bytes, value);
        try number(u32, a, &bytes, std.hash.Crc32.hash(entry.bytes));
        for (0..2) |_| try number(u32, a, &bytes, @intCast(entry.bytes.len));
        try number(u16, a, &bytes, @intCast(entry.path.len));
        try number(u16, a, &bytes, 0);
        try bytes.appendSlice(a, entry.path);
        try bytes.appendSlice(a, entry.bytes);
    }
    const central: u32 = @intCast(bytes.items.len);
    for (entries, offsets) |entry, offset| {
        try number(u32, a, &bytes, 0x02014b50);
        for ([_]u16{ 20, 20, 0, 0, 0, 0 }) |value| try number(u16, a, &bytes, value);
        try number(u32, a, &bytes, std.hash.Crc32.hash(entry.bytes));
        for (0..2) |_| try number(u32, a, &bytes, @intCast(entry.bytes.len));
        try number(u16, a, &bytes, @intCast(entry.path.len));
        for (0..4) |_| try number(u16, a, &bytes, 0);
        try number(u32, a, &bytes, 0);
        try number(u32, a, &bytes, offset);
        try bytes.appendSlice(a, entry.path);
    }
    const central_size: u32 = @intCast(bytes.items.len - central);
    try number(u32, a, &bytes, 0x06054b50);
    for (0..2) |_| try number(u16, a, &bytes, 0);
    for (0..2) |_| try number(u16, a, &bytes, @intCast(entries.len));
    try number(u32, a, &bytes, central_size);
    try number(u32, a, &bytes, central);
    try number(u16, a, &bytes, 0);
    return bytes.toOwnedSlice(a);
}

// These bytes and the Java-17 vanilla declaration are synthetic acceptance data.
// Legacy 1.7.10 does not historically require Java 17; no playable install is claimed.
pub const label = "SyntheticMaterialization";
pub const base_id = "1.7.10";
pub const forge_id = "1.7.10-10.13.4.1614-1.7.10";
const vanilla_url = "https://piston-meta.mojang.com/v1/packages/fixture/1.7.10.json";
const catalog_url = "https://files.minecraftforge.net/net/minecraftforge/forge/maven-metadata.json";
const installer_url = "https://maven.minecraftforge.net/net/minecraftforge/forge/" ++ forge_id ++ "/forge-" ++ forge_id ++ "-installer.jar";
const index_url = "https://piston-meta.mojang.com/v1/packages/fixture/assets.json";
const index_bytes = "{\"objects\":{}}";
const profile_bytes =
    "{\"install\":{\"minecraft\":\"1.7.10\",\"path\":\"net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10\",\"filePath\":\"forge-universal.jar\"},\"versionInfo\":{\"id\":\"SyntheticMaterialization-Forge\",\"inheritsFrom\":\"1.7.10\",\"jar\":\"1.7.10\",\"mainClass\":\"net.minecraft.launchwrapper.Launch\",\"minecraftArguments\":\"--tweakClass cpw.mods.fml.common.launcher.FMLTweaker\",\"libraries\":[{\"name\":\"net.minecraftforge:forge:1.7.10-10.13.4.1614-1.7.10\",\"url\":\"https://maven.minecraftforge.net/\"}]}}";

pub const PreparedData = struct {
    arena: *std.heap.ArenaAllocator,
    backing: A,
    root: []const u8,
    archive_path: []const u8,
    java17_path: []const u8,
    java8_path: []const u8,
    vanilla_bytes: []const u8,
    manifest_bytes: []const u8,
    installer_bytes: []const u8,
    installer_hex: [40]u8,
    client_bytes: []const u8,
    library_bytes: []const u8,
    client_url: []const u8,

    fn deinit(self: *PreparedData) void {
        self.arena.deinit();
        self.backing.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn initPrepared(self: *Context, a: A, io: Io, root: []const u8) !void {
    if (self.prepared != null) return error.FixturePreparedAlreadyInitialized;
    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = .init(a);
    errdefer {
        arena.deinit();
        a.destroy(arena);
    }
    const g = arena.allocator();
    var p = try paths.Paths.init(g, io, root);
    defer p.deinit();
    const client = try zipBytes(g, &.{});
    const library = try zipBytes(g, &.{});
    const client_hex = std.fmt.bytesToHex(&sha1(client), .lower);
    const index_hex = std.fmt.bytesToHex(&sha1(index_bytes), .lower);
    const client_url = try std.fmt.allocPrint(g, "https://piston-data.mojang.com/v1/objects/{s}/client.jar", .{client_hex});
    const vanilla_bytes = try std.json.Stringify.valueAlloc(g, .{
        .id = base_id,
        .type = "release",
        .mainClass = "net.minecraft.client.main.Main",
        .minecraftArguments = "--username fixture",
        .javaVersion = .{ .majorVersion = @as(u32, 17), .component = label },
        .downloads = .{ .client = .{ .url = client_url, .sha1 = client_hex[0..], .size = client.len } },
        .assetIndex = .{ .id = "fixture-synthetic", .url = index_url, .sha1 = index_hex[0..], .size = index_bytes.len, .totalSize = @as(u64, 0) },
        .assets = "fixture-synthetic",
        .libraries = .{},
    }, .{});
    const vanilla_document = vanilla_bytes;
    const vanilla_hex = std.fmt.bytesToHex(&sha1(vanilla_document), .lower);
    const manifest_bytes = try std.json.Stringify.valueAlloc(g, .{
        .latest = .{ .release = base_id, .snapshot = base_id },
        .versions = .{.{ .id = base_id, .type = "release", .url = vanilla_url, .sha1 = vanilla_hex[0..], .time = "2024-01-01T00:00:00+00:00", .releaseTime = "2024-01-01T00:00:00+00:00", .complianceLevel = @as(u32, 1) }},
    }, .{});
    const installer = try zipBytes(g, &.{ .{ .path = "install_profile.json", .bytes = profile_bytes }, .{ .path = "forge-universal.jar", .bytes = library } });
    const java_name = if (builtin.os.tag == .windows) "java.exe" else "java";
    const java17 = try std.fs.path.join(g, &.{ p.jdks, "SyntheticMaterialization-17", "bin", java_name });
    const java8 = try std.fs.path.join(g, &.{ p.jdks, "SyntheticMaterialization-8", "bin", java_name });
    try writeBytes(io, java17, "SyntheticMaterialization Java marker 17\n");
    try writeBytes(io, java8, "SyntheticMaterialization Java marker 8\n");
    const archive_path = try std.fs.path.join(g, &.{ p.root, "fixture-pack-prepared.mrpack" });
    const index = "{\"formatVersion\":1,\"game\":\"minecraft\",\"versionId\":\"synthetic-v1\",\"name\":\"SyntheticMaterialization\",\"files\":[],\"dependencies\":{\"minecraft\":\"1.7.10\",\"forge\":\"1.7.10-10.13.4.1614-1.7.10\"}}";
    const archive_bytes = try zipBytes(g, &.{ .{ .path = "modrinth.index.json", .bytes = index }, .{ .path = "overrides/config/fixture-pack.cfg", .bytes = "SyntheticMaterialization settings\n" } });
    try writeBytes(io, archive_path, archive_bytes);
    // Publish only after every allocation/write succeeds; callbacks borrow this owner.
    self.prepared = .{ .arena = arena, .backing = a, .root = try g.dupe(u8, p.root), .archive_path = archive_path, .java17_path = java17, .java8_path = java8, .vanilla_bytes = vanilla_document, .manifest_bytes = manifest_bytes, .installer_bytes = installer, .installer_hex = std.fmt.bytesToHex(&sha1(installer), .lower), .client_bytes = client, .library_bytes = library, .client_url = client_url };
}

pub fn registerMarkers(self: *Context, manager: *java.Manager) !void {
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    try manager.addDownloaded(.{ .path = data.java17_path, .major = 17, .vendor = label });
    try manager.addDownloaded(.{ .path = data.java8_path, .major = 8, .vendor = label });
}

fn checkCancel(cancel: ?*const packs.CancelToken) !void {
    if (cancel) |token| if (token.load(.acquire)) return error.Canceled;
}
fn syntheticManifest(raw: ?*anyopaque, a: A, _: Io, cancel: ?*const packs.CancelToken) !metadata.Owned(metadata.manifest.Manifest) {
    try checkCancel(cancel);
    const self = try Context.from(raw);
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    _ = self.synthetic_requests.fetchAdd(1, .monotonic);
    return metadata.manifest.parseSlice(a, data.manifest_bytes);
}
fn syntheticMetadata(raw: ?*anyopaque, a: A, _: Io, request: metadata_loader.Request) ![]u8 {
    const self = try Context.from(raw);
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    if (!std.mem.eql(u8, request.id, base_id) or !std.mem.eql(u8, request.url, vanilla_url)) return error.FixtureUnexpectedMetadata;
    const expected = request.sha1 orelse return error.MissingHash;
    const actual = sha1(data.vanilla_bytes);
    if (!std.mem.eql(u8, &expected, &actual)) return error.HashMismatch;
    if (request.size) |size| if (size != data.vanilla_bytes.len) return error.SizeMismatch;
    if (data.vanilla_bytes.len > request.max_bytes) return error.MetadataTooLarge;
    _ = self.synthetic_requests.fetchAdd(1, .monotonic);
    return a.dupe(u8, data.vanilla_bytes);
}
fn syntheticGet(raw: ?*anyopaque, a: A, url: []const u8, max_bytes: usize, control: loaders.Control) !loaders.Response {
    try control.check();
    const self = try Context.from(raw);
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    const body: []const u8 = if (std.mem.eql(u8, url, catalog_url)) "{\"1.7.10\":[\"1.7.10-10.13.4.1614-1.7.10\"]}" else if (std.mem.eql(u8, url, installer_url)) data.installer_bytes else if (std.mem.eql(u8, url, installer_url ++ ".sha1")) &data.installer_hex else return error.FixtureUnexpectedMetadata;
    if (body.len > max_bytes) return error.MetadataTooLarge;
    _ = self.synthetic_requests.fetchAdd(1, .monotonic);
    const bytes = try a.dupe(u8, body);
    errdefer a.free(bytes);
    const final_url = try a.dupe(u8, url);
    errdefer a.free(final_url);
    try control.check();
    return .{ .bytes = bytes, .final_url = final_url, .status = 200 };
}
fn markerProbe(raw: ?*anyopaque, a: A, io: Io, path: []const u8, cancel: ?*const packs.CancelToken) !java.Runtime {
    try checkCancel(cancel);
    const self = try Context.from(raw);
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    const major: u32 = if (std.mem.eql(u8, path, data.java17_path)) 17 else if (std.mem.eql(u8, path, data.java8_path)) 8 else return error.FixtureUnexpectedJavaPath;
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(128));
    defer a.free(bytes);
    const expected = if (major == 17) "SyntheticMaterialization Java marker 17\n" else "SyntheticMaterialization Java marker 8\n";
    if (!std.mem.eql(u8, bytes, expected)) return error.FixtureJavaMarkerChanged;
    try checkCancel(cancel);
    const owned_path = try a.dupe(u8, path);
    errdefer a.free(owned_path);
    return .{ .path = owned_path, .major = major, .vendor = try a.dupe(u8, label) };
}

pub fn environment() !metadata.rules.Environment {
    return .{ .os_name = switch (builtin.os.tag) {
        .linux => "linux",
        .windows => "windows",
        .macos => "osx",
        else => return error.UnsupportedPlatform,
    }, .arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "x86",
        else => return error.UnsupportedArchitecture,
    } };
}
fn nowMs(raw: ?*anyopaque) u64 {
    const io: *const Io = @ptrCast(@alignCast(raw.?));
    return @intCast(@divTrunc(Io.Clock.awake.now(io.*).nanoseconds, std.time.ns_per_ms));
}
fn loaderControl(io: *const Io, cancel: *const std.atomic.Value(bool)) loaders.Control {
    return .{ .cancel = cancel, .context = @constCast(io), .now_ms = nowMs, .deadline_ms = nowMs(@constCast(io)) + 10_000 };
}
pub fn prepareProof(self: *Context, a: A, io: Io, target: loader_install.MetadataTarget, cancel: *const std.atomic.Value(bool)) !loader_install.PreparedMetadata {
    var manifest = try syntheticManifest(self, a, io, cancel);
    defer manifest.deinit();
    var p = try paths.Paths.init(a, io, target.root);
    defer p.deinit();
    return loader_install.prepareMetadata(a, io, .{ .root = target.root, .instance_id = target.instance_id, .instance_name = target.instance_name, .generation = target.generation, .selection = target.selection, .environment = target.environment, .vanilla = .{ .root = p.minecraft, .version_id = target.selection.base_id, .manifest = manifest.value, .cancel = cancel }, .fetcher = .{ .context = self, .fetch = syntheticMetadata }, .transport = .{ .context = self, .get = syntheticGet } }, loaderControl(&io, cancel));
}

// Request fields are checked against the genuine owner, not a rewritten proof.
pub fn validateRequest(self: *Context, a: A, io: Io, request: instances_manager.CreateRequest, control: instances_manager.Control) !metadata.Owned(loaders.recipes.Recipe) {
    try control.check();
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    const proof = request.prepared orelse return error.MissingPreparedMetadata;
    const loader_id = request.instance.loader_version orelse return error.PreparedMetadataMismatch;
    if (request.instance.loader != .forge or !std.mem.eql(u8, request.root, data.root)) return error.PreparedMetadataMismatch;
    const target: loader_install.MetadataTarget = .{ .root = request.root, .instance_id = request.instance.id, .instance_name = request.instance.name, .generation = request.prepared_generation, .selection = .{ .kind = .forge, .base_id = request.instance.minecraft_version, .loader_id = loader_id }, .environment = try environment() };
    try proof.validateBinding(a, io, target);
    const expected_installer = try zipBytes(a, &.{ .{ .path = "install_profile.json", .bytes = profile_bytes }, .{ .path = "forge-universal.jar", .bytes = data.library_bytes } });
    defer a.free(expected_installer);
    if (!std.mem.eql(u8, proof.source_bytes, expected_installer)) return error.FixturePreparedSourceChanged;
    var replay = try proof.replayBase(a, io, target, loaderControl(&io, control.cancel));
    defer replay.deinit();
    var p = try paths.Paths.init(a, io, request.root);
    defer p.deinit();
    const stage = try std.fmt.allocPrint(a, "{s}/versions/.fixture-prepared-{s}", .{ p.minecraft, request.instance.id });
    defer a.free(stage);
    var recipe = try loaders.prepare(a, proof.catalog.value, target.selection, replay.version.value, proof.bundle, .{ .instance_name = request.instance.name, .stage_root = stage, .environment = target.environment });
    errdefer recipe.deinit();
    const requirements = loaders.recipes.javaRequirements(recipe.value);
    if (requirements.runtime_major != proof.requirements.runtime_major or requirements.installer_major != proof.requirements.installer_major or requirements.runtime_major != 17 or requirements.installer_major != 8) return error.FixtureJavaRequirementsChanged;
    const runtime = try markerProbe(self, a, io, request.instance.java_path orelse return error.FixtureWrongJavaRole, control.cancel);
    defer java.freeRuntime(a, runtime);
    const installer = try markerProbe(self, a, io, request.installer_java orelse return error.FixtureWrongJavaRole, control.cancel);
    defer java.freeRuntime(a, installer);
    if (runtime.major != requirements.runtime_major or installer.major != requirements.installer_major or std.mem.eql(u8, runtime.path, installer.path)) return error.FixtureWrongJavaRole;
    try control.check();
    return recipe;
}

pub fn replayProof(proof: *const loader_install.PreparedMetadata, a: A, io: Io, target: loader_install.MetadataTarget, cancel: *const std.atomic.Value(bool)) !void {
    var replay = try proof.replayBase(a, io, target, loaderControl(&io, cancel));
    defer replay.deinit();
}

fn sha1(bytes: []const u8) metadata.Sha1 {
    var result: metadata.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &result, .{});
    return result;
}
fn sha256(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
fn writeBytes(io: Io, path: []const u8, bytes: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse return error.FixtureUnsafePath);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn preparedInstaller(self: *Context) instances_manager.Installer {
    return .{ .context = self, .run = syntheticInstall };
}
const ArtifactBinding = struct { path: []const u8, sha256: [64]u8, size: u64 };
const Materialized = struct { destination: []const u8, staged_path: []const u8, bytes: []const u8 };

fn verifyBytes(bytes: []const u8, expected_hash: ?metadata.Sha1, expected_size: ?u64) !void {
    if (expected_size) |size| if (bytes.len != size) return error.SizeMismatch;
    if (expected_hash) |expected| {
        const actual = sha1(bytes);
        if (!std.mem.eql(u8, &actual, &expected)) return error.HashMismatch;
    }
}
fn verifyWritten(a: A, io: Io, path: []const u8, bytes: []const u8) !void {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size != bytes.len) return error.FixtureMaterializedFileChanged;
    const actual = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8 * 1024 * 1024));
    defer a.free(actual);
    const expected_hash = sha256(bytes);
    const actual_hash = sha256(actual);
    if (!std.mem.eql(u8, &expected_hash, &actual_hash)) return error.HashMismatch;
}
// Existing verified caches are borrowed. Only files created here are rolled back.
fn publishCache(a: A, io: Io, path: []const u8, bytes: []const u8) !bool {
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse return error.FixtureUnsafePath);
    const file = Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try verifyWritten(a, io, path, bytes);
            return false;
        },
        else => return err,
    };
    defer file.close(io);
    errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
    try verifyWritten(a, io, path, bytes);
    return true;
}

fn syntheticInstall(raw: ?*anyopaque, a: A, io: Io, request: instances_manager.CreateRequest, control: instances_manager.Control) !instances_manager.Installed {
    const self = try Context.from(raw);
    self.proof_borrowed.store(request.prepared != null, .release);
    defer {
        self.proof_borrowed.store(false, .release);
        self.installer_exited.store(true, .release);
        if (self.installer_exit_observer) |observer| observer.store(true, .release);
    }
    var recipe = try validateRequest(self, a, io, request, control);
    defer recipe.deinit();
    try request.lease.recheck(request.lease.context, request.instance.id);
    self.validated_roles.store(true, .release);
    self.installer_entered.store(true, .release);
    while (self.hold_installer.load(.acquire)) {
        try control.check();
        std.Thread.yield() catch {};
    }
    try control.check();
    const data = self.prepared orelse return error.FixtureMetadataUnavailable;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const g = arena.allocator();
    var p = try paths.Paths.init(g, io, request.root);
    defer p.deinit();
    const stage = recipe.value.stage_root;
    const versions = try std.fs.path.join(g, &.{ p.minecraft, "versions" });
    const final = try p.instanceDirectory(request.instance.name);
    const cache_stage = try std.fs.path.join(g, &.{ stage, ".cache" });
    try Io.Dir.cwd().createDirPath(io, versions);
    // Exclusive ownership precedes any staged write; a collision is never removed.
    try Io.Dir.cwd().createDir(io, stage, .fromMode(0o700));
    var committed = false;
    var created: std.ArrayList([]const u8) = .empty;
    defer {
        if (!committed) {
            var rollback_complete = true;
            for (created.items) |path| Io.Dir.cwd().deleteFile(io, path) catch {
                rollback_complete = false;
            };
            Io.Dir.cwd().deleteTree(io, stage) catch {
                rollback_complete = false;
            };
            self.rolled_back.store(rollback_complete, .release);
        }
    }
    const staged_client = try std.fmt.allocPrint(g, "{s}/{s}.jar", .{ stage, request.instance.name });
    try writeBytes(io, staged_client, data.client_bytes);
    try verifyWritten(g, io, staged_client, data.client_bytes);
    self.staged.store(true, .release);
    if (self.fail_after_staging.load(.acquire)) return error.FixtureSyntheticStagingFailure;
    var assets = try metadata.asset_index.parseSlice(g, index_bytes);
    defer assets.deinit();
    var plan = try install_plan.build(g, recipe.value.version, assets.value, try environment(), .{ .root = p.minecraft, .instance_name = request.instance.name, .game_directory = final, .cpu_arch = @tagName(builtin.cpu.arch), .native_arch = if (@bitSizeOf(usize) == 64) .bits64 else .bits32 });
    defer plan.deinit();
    // The declared synthetic metadata has no processors, natives, logging or assets.
    // Reject a changed plan instead of silently skipping any required artifact.
    if (recipe.value.processors.len != 0 or plan.value.native_extractions.len != 0 or plan.value.native_checks.len != 0 or plan.value.asset_materializations.len != 0) return error.FixtureUnexpectedGamePlan;
    var materialized: std.ArrayList(Materialized) = .empty;
    for (plan.value.files) |file| {
        try control.check();
        const bytes: []const u8 = switch (file.kind) {
            .client => if (std.mem.eql(u8, file.url, data.client_url)) data.client_bytes else return error.FixtureUnexpectedGamePlan,
            .asset_index => if (std.mem.eql(u8, file.url, index_url)) index_bytes else return error.FixtureUnexpectedGamePlan,
            .library => blk: {
                if (recipe.value.artifacts.len != 1) return error.FixtureUnexpectedGamePlan;
                const library_path = try std.fs.path.join(g, &.{ p.minecraft, recipe.value.artifacts[0].path });
                if (!std.mem.eql(u8, file.path, library_path)) return error.FixtureUnexpectedGamePlan;
                break :blk data.library_bytes;
            },
            .native, .asset, .logging => return error.FixtureUnexpectedGamePlan,
        };
        try verifyBytes(bytes, file.sha1, file.size);
        const relative = try std.fs.path.relative(g, p.root, null, p.minecraft, file.path);
        if (std.mem.startsWith(u8, relative, "..") or std.fs.path.isAbsolute(relative)) return error.FixtureUnsafePath;
        const staged_path = try std.fs.path.join(g, &.{ cache_stage, relative });
        try writeBytes(io, staged_path, bytes);
        try verifyWritten(g, io, staged_path, bytes);
        try materialized.append(g, .{ .destination = file.path, .staged_path = staged_path, .bytes = bytes });
    }
    if (materialized.items.len != 3 or recipe.value.artifacts.len != 1) return error.FixtureUnexpectedGamePlan;
    const bindings = try g.alloc(ArtifactBinding, recipe.value.artifacts.len);
    for (recipe.value.artifacts, bindings) |artifact, *binding| {
        try verifyBytes(data.library_bytes, artifact.sha1, artifact.size);
        binding.* = .{ .path = artifact.path, .sha256 = std.fmt.bytesToHex(&sha256(data.library_bytes), .lower), .size = data.library_bytes.len };
    }
    var resolved = recipe.value.version;
    resolved.jar = null;
    resolved.inherits_from = null;
    const document = try serde.serialize(g, resolved);
    const descriptor = try std.fmt.allocPrint(g, "{s}/{s}.json", .{ stage, request.instance.name });
    try writeBytes(io, descriptor, document);
    try verifyWritten(g, io, descriptor, document);
    const source_hash = recipe.value.installer_sha1 orelse return error.MissingInstallerChecksum;
    const receipt = try std.json.Stringify.valueAlloc(g, .{ .schema_version = @as(u32, 1), .instance_id = request.instance.id, .instance_name = request.instance.name, .minecraft_version = request.instance.minecraft_version, .loader = @tagName(request.instance.loader), .loader_version = request.instance.loader_version.?, .source_url = recipe.value.source_url, .source_sha1 = std.fmt.bytesToHex(&source_hash, .lower), .profile_sha1 = std.fmt.bytesToHex(&recipe.value.source_sha1, .lower), .metadata_sha256 = std.fmt.bytesToHex(&sha256(document), .lower), .client_sha256 = std.fmt.bytesToHex(&sha256(data.client_bytes), .lower), .client_size = data.client_bytes.len, .client_jar = try std.fmt.allocPrint(g, "{s}.jar", .{request.instance.name}), .artifact_bindings = bindings }, .{});
    const receipt_path = try std.fs.path.join(g, &.{ stage, ".vela-loader.json" });
    try writeBytes(io, receipt_path, receipt);
    try verifyWritten(g, io, receipt_path, receipt);
    var installed = try instances_manager.Installed.init(a, request.instance);
    errdefer installed.deinit();
    try created.ensureTotalCapacity(g, materialized.items.len);
    for (materialized.items) |file| {
        try control.check();
        try request.lease.recheck(request.lease.context, request.instance.id);
        try verifyWritten(g, io, file.staged_path, file.bytes);
        if (try publishCache(g, io, file.destination, file.bytes)) created.appendAssumeCapacity(file.destination);
    }
    try Io.Dir.cwd().deleteTree(io, cache_stage);
    try control.check();
    try request.lease.recheck(request.lease.context, request.instance.id);
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    // Result allocation and all verification precede this atomic directory publication.
    Io.Dir.cwd().renamePreserve(stage, Io.Dir.cwd(), final, io) catch |err| {
        // Do not guess whether an uncertain move published a directory.
        if (Io.Dir.cwd().statFile(io, stage, .{ .follow_symlinks = false })) |_| return err else |_| {
            installed.durability_uncertain = true;
            committed = true;
            return installed;
        }
    };
    committed = true;
    return installed;
}
