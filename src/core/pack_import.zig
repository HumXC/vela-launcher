//! Worker-only bounded local pack inspection and preparation. Inspection only
//! owns private staging; preparation requires the caller's instance reservation.
//! Neither phase installs game files. Execute Prepared through content_install
//! and clean owned stages on the worker before releasing the reservation.
const std = @import("std");
const config = @import("config.zig");
const instances = @import("instances.zig");
const manifest = @import("content_manifest.zig");
const providers = @import("content_providers.zig");
const content_install = @import("content_install.zig");
const archive = @import("safe_archive.zig");
const fs = @import("content_fs.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const CancelToken = std.atomic.Value(bool);
const stage_directory = "pack-imports";
const archive_limit = 2 * 1024 * 1024 * 1024;

pub const Inspection = struct {
    arena: std.heap.ArenaAllocator,
    parsed: providers.Owned(manifest.PackPlan),
    pack: manifest.PackPlan,
    provider: providers.Provider,
    source_sha256: [64]u8,
    archive_absolute_path: []const u8,
    stage_absolute_path: []const u8,

    pub fn deinit(self: *Inspection) void {
        self.parsed.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn cleanup(self: *const Inspection, io: Io) !void {
        try cleanupStage(io, self.stage_absolute_path);
    }
};

pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    parsed: providers.Owned(manifest.PackPlan),
    pack: manifest.PackPlan,
    files: []const manifest.InstallFile,
    manual_files: []const content_install.ManualFile,
    stage_absolute_path: []const u8,
    instance_id: []const u8,
    instance_name: []const u8,

    /// Memory only. Does not remove staging and may run after worker cleanup.
    pub fn deinit(self: *Prepared) void {
        self.parsed.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Filesystem only, on the owning worker while its reservation is held.
    pub fn cleanup(self: *const Prepared, io: Io) !void {
        try cleanupStage(io, self.stage_absolute_path);
    }
};

/// Can clean abandoned stages without retaining Prepared's arena. Only accepts
/// our private stage layout, never arbitrary supplied archive/game paths.
pub fn cleanup(io: Io, stage_absolute_path: []const u8) !void {
    try cleanupStage(io, stage_absolute_path);
}
fn cleanupStage(io: Io, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.UnsafeStagePath;
    const name = std.fs.path.basename(path);
    if (name.len != 39 or !std.mem.startsWith(u8, name, "import-")) return error.UnsafeStagePath;
    for (name[7..]) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.UnsafeStagePath;
    const parent_path = std.fs.path.dirname(path) orelse return error.UnsafeStagePath;
    if (!std.mem.eql(u8, std.fs.path.basename(parent_path), stage_directory)) return error.UnsafeStagePath;
    const vela_path = std.fs.path.dirname(parent_path) orelse return error.UnsafeStagePath;
    if (!std.mem.eql(u8, std.fs.path.basename(vela_path), ".vela")) return error.UnsafeStagePath;
    const parent = fs.openAbsolute(io, parent_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer parent.close(io);
    if (try fs.inspectEntry(parent, io, name) == null) return;
    const stage = try fs.child(parent, io, name, false, true);
    stage.close(io);
    try parent.deleteTree(io, name);
}

pub fn inspect(a: Allocator, io: Io, paths: *const instances.Paths, archive_absolute_path: []const u8, cancel: ?*const CancelToken) !Inspection {
    try fs.cancelled(io, cancel, null);
    if (!std.fs.path.isAbsolute(archive_absolute_path) or std.mem.indexOfScalar(u8, archive_absolute_path, 0) != null) return error.ArchivePathNotAbsolute;
    const ext = std.fs.path.extension(archive_absolute_path);
    const provider: providers.Provider = if (std.ascii.eqlIgnoreCase(ext, ".mrpack")) .modrinth else if (std.ascii.eqlIgnoreCase(ext, ".zip")) .curseforge else return error.UnsupportedPackArchive;
    return inspectArchive(a, io, paths, archive_absolute_path, provider, null, cancel);
}

pub fn prepare(a: Allocator, io: Io, paths: *const instances.Paths, instance: config.Instance, archive_absolute_path: []const u8, cancel: ?*const CancelToken) !Prepared {
    try fs.cancelled(io, cancel, null);
    if (!fs.safeComponent(instance.id) or !fs.safeComponent(instance.name)) return error.UnsafeInstance;
    var inspection = try inspect(a, io, paths, archive_absolute_path, cancel);
    var owned = true;
    defer if (owned) inspection.deinit();
    errdefer if (owned) inspection.cleanup(io) catch {};
    const prepared = try finishPrepare(io, instance, &inspection, cancel);
    owned = false;
    return prepared;
}

/// Reuses the inspected private copy, never the mutable original archive. The
/// caller retains the inspection and must clean it after the owning worker joins.
pub fn prepareInspected(a: Allocator, io: Io, paths: *const instances.Paths, instance: config.Instance, inspection: *const Inspection, cancel: ?*const CancelToken) !Prepared {
    try fs.cancelled(io, cancel, null);
    if (!fs.safeComponent(instance.id) or !fs.safeComponent(instance.name)) return error.UnsafeInstance;
    const extracted_path = try std.fs.path.join(a, &.{ inspection.stage_absolute_path, "extracted" });
    defer a.free(extracted_path);
    const extracted = try fs.openAbsolute(io, extracted_path);
    defer extracted.close(io);
    try validatePackTargets(a, io, extracted, inspection.pack, instance.name, cancel);
    try compatible(instance, inspection.pack);
    var next = try inspectArchive(a, io, paths, inspection.archive_absolute_path, inspection.provider, inspection.source_sha256, cancel);
    var owned = true;
    defer if (owned) next.deinit();
    errdefer if (owned) next.cleanup(io) catch {};
    const prepared = try finishPrepare(io, instance, &next, cancel);
    owned = false;
    return prepared;
}

fn inspectArchive(a: Allocator, io: Io, paths: *const instances.Paths, archive_absolute_path: []const u8, provider: providers.Provider, expected_hash: ?[64]u8, cancel: ?*const CancelToken) !Inspection {
    try fs.cancelled(io, cancel, null);
    if (!std.fs.path.isAbsolute(archive_absolute_path) or std.mem.indexOfScalar(u8, archive_absolute_path, 0) != null) return error.ArchivePathNotAbsolute;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const root = try fs.openAbsolute(io, paths.root);
    defer root.close(io);
    const vela = try fs.child(root, io, ".vela", true, false);
    defer vela.close(io);
    const stages = try fs.child(vela, io, stage_directory, true, true);
    defer stages.close(io);
    var random: [16]u8 = undefined;
    try Io.randomSecure(io, &random);
    const stage_name = try std.fmt.allocPrint(aa, "import-{s}", .{std.fmt.bytesToHex(random, .lower)});
    const stage_path = try std.fs.path.join(aa, &.{ paths.vela, stage_directory, stage_name });
    try stages.createDir(io, stage_name, fs.privatePermissions(true));
    errdefer stages.deleteTree(io, stage_name) catch {};
    const stage = try fs.child(stages, io, stage_name, false, true);
    defer stage.close(io);
    const source_parent = try fs.openAbsolute(io, std.fs.path.dirname(archive_absolute_path) orelse return error.UnsafePath);
    defer source_parent.close(io);
    const source = try fs.openRegular(source_parent, io, std.fs.path.basename(archive_absolute_path));
    defer source.close(io);
    if ((try source.stat(io)).size > archive_limit) return error.ArchiveLimitExceeded;
    // Public inspection detects the provider from this owned copy on reinspection.
    const archive_name = if (provider == .modrinth) "archive.mrpack" else "archive.zip";
    const source_hash = try fs.copy(source, stage, io, archive_name, archive_limit, cancel, null);
    if (expected_hash) |expected| {
        if (!std.mem.eql(u8, &source_hash.sha256, &expected)) return error.InspectedArchiveChanged;
    }
    const copied_path = try std.fs.path.join(aa, &.{ stage_path, archive_name });
    const extracted = try fs.child(stage, io, "extracted", true, true);
    defer extracted.close(io);
    var result = try archive.extract(aa, io, copied_path, extracted, .zip, .{
        .max_archive_bytes = archive_limit,
        .max_file_bytes = 1024 * 1024 * 1024,
        .max_entries = 16_384,
        .max_paths = 32_768,
        .max_path_bytes = manifest.max_path_bytes,
        .max_path_depth = 18,
    }, cancel);
    defer result.deinit(aa);
    try fs.cancelled(io, cancel, null);
    const index_name = if (provider == .modrinth) "modrinth.index.json" else "manifest.json";
    const other_index = if (provider == .modrinth) "manifest.json" else "modrinth.index.json";
    if (try fs.inspectEntry(extracted, io, other_index) != null) {
        if (try fs.inspectEntry(extracted, io, index_name) != null) return error.AmbiguousPackFormat;
        return error.PackFormatMismatch;
    }
    const bytes = try fs.read(aa, extracted, io, index_name, providers.max_json_bytes);
    // Local archive identities are content-addressed provenance, not provider IDs
    // resolved through an API. In particular they do not claim a CF operation.
    const identity: manifest.PackIdentity = .{
        .provider = provider,
        .project_id = try std.fmt.allocPrint(aa, "local-{s}", .{source_hash.sha256}),
        .version_id = try aa.dupe(u8, &source_hash.sha256),
    };
    // The nested owner must not retain an allocator pointing at our movable arena.
    var parsed = if (provider == .modrinth) try manifest.parseMrpack(a, bytes, identity, .client) else try manifest.parseCurseForgePack(a, bytes, identity);
    errdefer parsed.deinit();
    try validatePackTargets(aa, io, extracted, parsed.value, null, cancel);
    return .{
        .arena = arena,
        .parsed = parsed,
        .pack = parsed.value,
        .provider = provider,
        .source_sha256 = source_hash.sha256,
        .archive_absolute_path = copied_path,
        .stage_absolute_path = stage_path,
    };
}

fn finishPrepare(io: Io, instance: config.Instance, inspection: *Inspection, cancel: ?*const CancelToken) !Prepared {
    try fs.cancelled(io, cancel, null);
    const aa = inspection.arena.allocator();
    const parsed = inspection.parsed;
    const stage_path = inspection.stage_absolute_path;
    const extracted_path = try std.fs.path.join(aa, &.{ stage_path, "extracted" });
    const extracted = try fs.openAbsolute(io, extracted_path);
    defer extracted.close(io);
    try validatePackTargets(aa, io, extracted, inspection.pack, instance.name, cancel);
    try compatible(instance, inspection.pack);
    const identity = inspection.pack.identity;
    var files: std.ArrayList(manifest.InstallFile) = .empty;
    try files.appendSlice(aa, parsed.value.files);
    for (files.items, 0..) |file, i| {
        try safeTarget(file.record.path);
        for (files.items[0..i]) |other| if (targetCollision(file.record.path, other.record.path)) return error.PathCollision;
    }
    var manual: std.ArrayList(content_install.ManualFile) = .empty;
    var context: Walk = .{ .a = aa, .io = io, .cancel = cancel, .identity = identity, .files = &files, .manual = &manual };
    for (parsed.value.override_layers) |layer| {
        try fs.cancelled(io, cancel, null);
        try safeTarget(layer);
        const dir = fs.descend(extracted, io, layer, false) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        const absolute = try std.fs.path.join(aa, &.{ stage_path, "extracted", layer });
        try context.walk(dir, absolute, "", 0);
    }
    const merged = try files.toOwnedSlice(aa);
    var pack = parsed.value;
    pack.files = merged;
    const document: manifest.Manifest = .{ .instance_id = instance.id, .pack_version = pack.version, .files = try records(aa, merged) };
    try manifest.validatePathsForInstance(document, instance.name);
    try manifest.validate(document);
    return .{
        .arena = inspection.arena,
        .parsed = parsed,
        .pack = pack,
        .files = merged,
        .manual_files = try manual.toOwnedSlice(aa),
        .stage_absolute_path = stage_path,
        .instance_id = try aa.dupe(u8, instance.id),
        .instance_name = try aa.dupe(u8, instance.name),
    };
}

fn records(a: Allocator, files: []const manifest.InstallFile) ![]const manifest.ManagedFile {
    const result = try a.alloc(manifest.ManagedFile, files.len);
    for (files, result) |file, *record| record.* = file.record;
    return result;
}
fn compatible(instance: config.Instance, pack: manifest.PackPlan) !void {
    if (!std.mem.eql(u8, instance.minecraft_version, pack.minecraft_version)) return error.MinecraftVersionMismatch;
    if (instance.loader != pack.loader) return error.LoaderMismatch;
    if (instance.loader_version) |version| {
        if (pack.loader_version == null or !std.mem.eql(u8, version, pack.loader_version.?)) return error.LoaderVersionMismatch;
    } else if (pack.loader_version != null) return error.LoaderVersionMismatch;
}
fn safeTarget(path: []const u8) !void {
    try manifest.checkedPathForInstance(path, null);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (!fs.safeComponent(part)) return error.UnsafeRelativePath;
}
/// Inspect every override path before merging, compatibility checks, or publication.
fn validateOverrideTargets(a: Allocator, io: Io, dir: Io.Dir, prefix: []const u8, instance_name: ?[]const u8, cancel: ?*const CancelToken, visited: *usize) anyerror!void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        try fs.cancelled(io, cancel, null);
        visited.* += 1;
        if (visited.* > 32_768) return error.TooManyItems;
        const path = if (prefix.len == 0) try a.dupe(u8, entry.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, entry.name });
        defer a.free(path);
        try manifest.checkedPathForInstance(path, instance_name);
        try safeTarget(path);
        const stat = (try fs.inspectEntry(dir, io, entry.name)) orelse return error.MissingOverride;
        switch (stat.kind) {
            .directory => {
                const child = try fs.child(dir, io, entry.name, false, false);
                defer child.close(io);
                try validateOverrideTargets(a, io, child, path, instance_name, cancel, visited);
            },
            .file => {},
            else => return error.UnsafeFileType,
        }
    }
}
fn validatePackTargets(a: Allocator, io: Io, extracted: Io.Dir, pack: manifest.PackPlan, instance_name: ?[]const u8, cancel: ?*const CancelToken) !void {
    if (pack.files.len > providers.max_items or pack.unresolved.len > providers.max_items) return error.TooManyItems;
    for (pack.files) |file| {
        try manifest.checkedPathForInstance(file.record.path, instance_name);
        try safeTarget(file.record.path);
    }
    var visited: usize = 0;
    for (pack.override_layers) |layer| {
        try safeTarget(layer);
        const dir = fs.descend(extracted, io, layer, false) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        try validateOverrideTargets(a, io, dir, "", instance_name, cancel, &visited);
    }
}
const Walk = struct {
    a: Allocator,
    io: Io,
    cancel: ?*const CancelToken,
    identity: manifest.PackIdentity,
    files: *std.ArrayList(manifest.InstallFile),
    manual: *std.ArrayList(content_install.ManualFile),
    visited: usize = 0,

    fn walk(self: *Walk, dir: Io.Dir, absolute: []const u8, prefix: []const u8, depth: usize) anyerror!void {
        if (depth > 16) return error.UnsafeRelativePath;
        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            try fs.cancelled(self.io, self.cancel, null);
            self.visited += 1;
            if (self.visited > 32_768) return error.TooManyItems;
            const path = if (prefix.len == 0) try self.a.dupe(u8, entry.name) else try std.fmt.allocPrint(self.a, "{s}/{s}", .{ prefix, entry.name });
            try safeTarget(path);
            const stat = (try fs.inspectEntry(dir, self.io, entry.name)) orelse return error.MissingOverride;
            const source_path = try std.fs.path.join(self.a, &.{ absolute, entry.name });
            switch (stat.kind) {
                .directory => {
                    const child = try fs.child(dir, self.io, entry.name, false, false);
                    defer child.close(self.io);
                    try self.walk(child, source_path, path, depth + 1);
                },
                .file => {
                    const file = try fs.openRegular(dir, self.io, entry.name);
                    defer file.close(self.io);
                    const hash = try fs.stream(file, null, self.io, 1024 * 1024 * 1024, self.cancel, null);
                    const install: manifest.InstallFile = .{
                        .record = .{ .path = path, .provider = self.identity.provider, .project_id = self.identity.project_id, .version_id = self.identity.version_id, .hashes = .{ .sha256 = try self.a.dupe(u8, &hash.sha256) }, .size = hash.size, .role = .override },
                        .download = .{ .manual_required = .{ .official_page = "", .reason = .missing_url } },
                        .required = true,
                        .selected = true,
                    };
                    try self.merge(install, source_path);
                },
                else => return error.UnsafeFileType,
            }
        }
    }
    fn merge(self: *Walk, file: manifest.InstallFile, source_path: []const u8) !void {
        var replacement: ?usize = null;
        for (self.files.items, 0..) |other, i| {
            if (std.mem.eql(u8, other.record.path, file.record.path)) replacement = i else if (targetCollision(other.record.path, file.record.path)) return error.PathCollision;
        }
        if (replacement) |index| self.files.items[index] = file else {
            if (self.files.items.len >= providers.max_items) return error.TooManyItems;
            try self.files.append(self.a, file);
        }
        for (self.manual.items) |*old| if (std.mem.eql(u8, old.path, file.record.path)) {
            old.source_absolute_path = source_path;
            return;
        };
        try self.manual.append(self.a, .{ .path = file.record.path, .source_absolute_path = source_path });
    }
};

fn targetCollision(a: []const u8, b: []const u8) bool {
    if (manifest.pathsCollide(a, b)) return true;
    var left = std.mem.splitScalar(u8, a, '/');
    var right = std.mem.splitScalar(u8, b, '/');
    while (left.next()) |part| {
        const other = right.next() orelse break;
        if (!std.ascii.eqlIgnoreCase(part, other)) break;
        if (!std.mem.eql(u8, part, other)) return true;
    }
    return false;
}

const TestEntry = struct { path: []const u8, bytes: []const u8 };
fn zipInt(comptime T: type, bytes: *std.ArrayList(u8), value: T) !void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    try bytes.appendSlice(std.testing.allocator, &encoded);
}
/// Stored ZIP fixtures are built in memory and written only under tmpDir.
fn testZip(dir: Io.Dir, name: []const u8, entries: []const TestEntry) !void {
    const a = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    const offsets = try a.alloc(u32, entries.len);
    defer a.free(offsets);
    for (entries, offsets) |entry, *offset| {
        offset.* = @intCast(bytes.items.len);
        try zipInt(u32, &bytes, 0x04034b50);
        for ([_]u16{ 20, 0, 0, 0, 0 }) |value| try zipInt(u16, &bytes, value);
        try zipInt(u32, &bytes, std.hash.Crc32.hash(entry.bytes));
        try zipInt(u32, &bytes, @intCast(entry.bytes.len));
        try zipInt(u32, &bytes, @intCast(entry.bytes.len));
        try zipInt(u16, &bytes, @intCast(entry.path.len));
        try zipInt(u16, &bytes, 0);
        try bytes.appendSlice(a, entry.path);
        try bytes.appendSlice(a, entry.bytes);
    }
    const central: u32 = @intCast(bytes.items.len);
    for (entries, offsets) |entry, offset| {
        try zipInt(u32, &bytes, 0x02014b50);
        for ([_]u16{ 20, 20, 0, 0, 0, 0 }) |value| try zipInt(u16, &bytes, value);
        try zipInt(u32, &bytes, std.hash.Crc32.hash(entry.bytes));
        try zipInt(u32, &bytes, @intCast(entry.bytes.len));
        try zipInt(u32, &bytes, @intCast(entry.bytes.len));
        try zipInt(u16, &bytes, @intCast(entry.path.len));
        for (0..4) |_| try zipInt(u16, &bytes, 0);
        try zipInt(u32, &bytes, 0);
        try zipInt(u32, &bytes, offset);
        try bytes.appendSlice(a, entry.path);
    }
    const central_size: u32 = @intCast(bytes.items.len - central);
    try zipInt(u32, &bytes, 0x06054b50);
    try zipInt(u16, &bytes, 0);
    try zipInt(u16, &bytes, 0);
    try zipInt(u16, &bytes, @intCast(entries.len));
    try zipInt(u16, &bytes, @intCast(entries.len));
    try zipInt(u32, &bytes, central_size);
    try zipInt(u32, &bytes, central);
    try zipInt(u16, &bytes, 0);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes.items });
}
const TestFixture = struct {
    tmp: std.testing.TmpDir,
    paths: instances.Paths,
    fn init() !TestFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const len = try tmp.dir.realPath(std.testing.io, &buffer);
        return .{ .tmp = tmp, .paths = try instances.Paths.init(std.testing.allocator, std.testing.io, buffer[0..len]) };
    }
    fn deinit(self: *TestFixture) void {
        self.paths.deinit();
        self.tmp.cleanup();
    }
    fn path(self: *const TestFixture, name: []const u8) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.paths.root, name });
    }
};
const test_instance: config.Instance = .{ .id = "target-id", .name = "Exact Name", .minecraft_version = "1.21.1", .loader = .fabric, .loader_version = "0.16.10" };
const test_mrpack =
    \\{"formatVersion":1,"game":"minecraft","versionId":"local-version","name":"Local Pack","dependencies":{"minecraft":"1.21.1","fabric-loader":"0.16.10"},"files":[]}
;
const test_cf =
    \\{"manifestVersion":1,"manifestType":"minecraftModpack","name":"CF Export","version":"v1","minecraft":{"version":"1.21.1","modLoaders":[{"id":"fabric-0.16.10","primary":true}]},"files":[{"projectID":123,"fileID":456,"required":true}],"overrides":"supplied"}
;

test "private pack archives preserve format through public reinspection and trusted preparation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    inline for (.{
        .{ .name = "local.mrpack", .index = "modrinth.index.json", .bytes = test_mrpack, .provider = providers.Provider.modrinth, .suffix = ".mrpack" },
        .{ .name = "local.zip", .index = "manifest.json", .bytes = test_cf, .provider = providers.Provider.curseforge, .suffix = ".zip" },
    }) |sample| {
        var fixture = try TestFixture.init();
        defer fixture.deinit();
        try testZip(fixture.tmp.dir, sample.name, &.{.{ .path = sample.index, .bytes = sample.bytes }});
        const path = try fixture.path(sample.name);
        defer a.free(path);
        var preview = try inspect(a, io, &fixture.paths, path, null);
        defer preview.deinit();
        defer preview.cleanup(io) catch {};
        try std.testing.expectEqual(sample.provider, preview.provider);
        try std.testing.expect(std.mem.eql(u8, sample.suffix, std.fs.path.extension(preview.archive_absolute_path)));
        try std.testing.expect(!std.mem.eql(u8, path, preview.archive_absolute_path));
        try std.testing.expect(std.mem.eql(u8, preview.stage_absolute_path, std.fs.path.dirname(preview.archive_absolute_path).?));
        // The public handoff must use the owned bytes even after the original is gone.
        try fixture.tmp.dir.deleteFile(io, sample.name);
        var reinspected = try inspect(a, io, &fixture.paths, preview.archive_absolute_path, null);
        defer reinspected.deinit();
        defer reinspected.cleanup(io) catch {};
        try std.testing.expectEqual(sample.provider, reinspected.provider);
        try std.testing.expect(std.mem.eql(u8, &preview.source_sha256, &reinspected.source_sha256));
        try std.testing.expect(std.mem.eql(u8, preview.pack.identity.project_id, reinspected.pack.identity.project_id));
        try std.testing.expect(std.mem.eql(u8, preview.pack.identity.version_id, reinspected.pack.identity.version_id));
        try std.testing.expect(!std.mem.eql(u8, preview.stage_absolute_path, reinspected.stage_absolute_path));
        var prepared = try prepareInspected(a, io, &fixture.paths, test_instance, &reinspected, null);
        defer prepared.deinit();
        defer prepared.cleanup(io) catch {};
        try std.testing.expect(std.mem.eql(u8, reinspected.pack.identity.project_id, prepared.pack.identity.project_id));
        try std.testing.expect(std.mem.eql(u8, &preview.source_sha256, prepared.pack.identity.version_id));
        try std.testing.expect(!std.mem.eql(u8, reinspected.stage_absolute_path, prepared.stage_absolute_path));
        try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft", .{}));
        try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".vela/config.json", .{}));
    }
}

test "import mrpack owns merged overrides and staging remains after memory deinit" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try testZip(fixture.tmp.dir, "local.mrpack", &.{
        .{ .path = "modrinth.index.json", .bytes = test_mrpack },
        .{ .path = "overrides/config/example.txt", .bytes = "common" },
        .{ .path = "client-overrides/config/example.txt", .bytes = "client" },
        .{ .path = "overrides/options.txt", .bytes = "options" },
        .{ .path = "server-overrides/server.properties", .bytes = "ignored" },
    });
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    var prepared = try prepare(a, io, &fixture.paths, test_instance, path, null);
    errdefer prepared.deinit();
    try std.testing.expectEqualStrings(test_instance.id, prepared.instance_id);
    try std.testing.expectEqualStrings(test_instance.name, prepared.instance_name);
    try std.testing.expectEqual(@as(usize, 2), prepared.files.len);
    try std.testing.expectEqual(prepared.files.len, prepared.pack.files.len);
    try std.testing.expectEqual(@as(usize, 2), prepared.manual_files.len);
    for (prepared.files) |file| {
        try std.testing.expectEqual(manifest.FileRole.override, file.record.role);
        try std.testing.expectEqualStrings("", file.download.manual_required.official_page);
        if (std.mem.eql(u8, file.record.path, "config/example.txt")) {
            var expected: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash("client", &expected, .{});
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(expected, .lower), file.record.hashes.sha256.?);
            try std.testing.expectEqual(@as(?u64, 6), file.record.size);
        }
    }
    const stage_path = try a.dupe(u8, prepared.stage_absolute_path);
    defer a.free(stage_path);
    const manual_source = try a.dupe(u8, prepared.manual_files[0].source_absolute_path);
    defer a.free(manual_source);
    prepared.deinit();
    const staged = try fs.openAbsolute(io, stage_path);
    staged.close(io);
    try std.testing.expect(std.mem.startsWith(u8, manual_source, stage_path));
    try std.testing.expectError(error.FileNotFound, fs.openAbsolute(io, fixture.paths.minecraft));
    try cleanup(io, stage_path);
    try cleanup(io, stage_path);
    try std.testing.expectError(error.FileNotFound, fs.openAbsolute(io, stage_path));
}

test "CF import preserves unresolved references and supplied override root" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try testZip(fixture.tmp.dir, "local.zip", &.{ .{ .path = "manifest.json", .bytes = test_cf }, .{ .path = "supplied/config/cf.txt", .bytes = "local" } });
    const path = try fixture.path("local.zip");
    defer a.free(path);
    var prepared = try prepare(a, io, &fixture.paths, test_instance, path, null);
    defer prepared.deinit();
    defer prepared.cleanup(io) catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), prepared.pack.unresolved.len);
    try std.testing.expectEqualStrings("123", prepared.pack.unresolved[0].project_id);
    try std.testing.expectEqualStrings("456", prepared.pack.unresolved[0].file_id);
    try std.testing.expectEqualStrings("config/cf.txt", prepared.files[0].record.path);
    try std.testing.expectEqualStrings("", prepared.files[0].download.manual_required.official_page);
}

test "pack import refuses mismatched prerequisites and cancellation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try testZip(fixture.tmp.dir, "local.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = test_mrpack }});
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    var target = test_instance;
    target.minecraft_version = "1.20.1";
    try std.testing.expectError(error.MinecraftVersionMismatch, prepare(a, io, &fixture.paths, target, path, null));
    target = test_instance;
    target.loader = .forge;
    try std.testing.expectError(error.LoaderMismatch, prepare(a, io, &fixture.paths, target, path, null));
    target = test_instance;
    target.loader_version = null;
    try std.testing.expectError(error.LoaderVersionMismatch, prepare(a, io, &fixture.paths, target, path, null));
    var cancel = CancelToken.init(true);
    try std.testing.expectError(error.Canceled, prepare(a, io, &fixture.paths, test_instance, path, &cancel));
    try std.testing.expectError(error.ArchivePathNotAbsolute, prepare(a, io, &fixture.paths, test_instance, "local.mrpack", null));
    const stages_path = try fixture.path(".vela/pack-imports");
    defer a.free(stages_path);
    const stages = try fs.openAbsolute(io, stages_path);
    defer stages.close(io);
    var it = stages.iterate();
    try std.testing.expect(try it.next(io) == null);
}

test "override targets refuse protected paths case aliases and ancestor collisions" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const cases = [_]struct { first: []const u8, second: []const u8, wanted: anyerror }{
        .{ .first = "overrides/config/a.txt", .second = "client-overrides/Config/b.txt", .wanted = error.PathCollision },
        .{ .first = "overrides/config/a.txt", .second = "client-overrides/config/A.txt", .wanted = error.PathCollision },
        .{ .first = "overrides/config/a.txt", .second = "client-overrides/config/a.txt/nested", .wanted = error.PathCollision },
        .{ .first = "overrides/assets/a.txt", .second = "client-overrides/ok.txt", .wanted = error.ProtectedPath },
        .{ .first = "overrides/.vela-content/journal.json", .second = "client-overrides/ok.txt", .wanted = error.ProtectedPath },
    };
    for (cases) |case| {
        try testZip(fixture.tmp.dir, "local.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = test_mrpack }, .{ .path = case.first, .bytes = "a" }, .{ .path = case.second, .bytes = "b" } });
        const path = try fixture.path("local.mrpack");
        defer a.free(path);
        try std.testing.expectError(case.wanted, prepare(a, io, &fixture.paths, test_instance, path, null));
    }
    try std.testing.expectError(error.UnsafeStagePath, cleanup(io, fixture.paths.root));
}

fn testRemoteIndex(a: Allocator, paths: []const []const u8) ![]u8 {
    const Remote = struct { path: []const u8, hashes: struct { sha1: []const u8 = &@as([40]u8, @splat('0')), sha512: []const u8 = &@as([128]u8, @splat('0')) } = .{}, fileSize: u64 = 3, downloads: []const []const u8 = &.{"https://cdn.modrinth.com/a.jar"} };
    const files = try a.alloc(Remote, paths.len);
    defer a.free(files);
    for (paths, files) |path, *file| file.* = .{ .path = path };
    return std.json.Stringify.valueAlloc(a, .{ .formatVersion = @as(u32, 1), .game = "minecraft", .versionId = "v1", .name = "remote pack", .dependencies = .{ .minecraft = "1.21.1", .@"fabric-loader" = "0.16.10" }, .files = files }, .{});
}

test "import keeps remote records and replaces an exact target with actual override bytes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const index = try testRemoteIndex(a, &.{ "mods/keep.jar", "config/replaced.txt" });
    defer a.free(index);
    try testZip(fixture.tmp.dir, "local.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = index }, .{ .path = "overrides/config/replaced.txt", .bytes = "real bytes" } });
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    var prepared = try prepare(a, io, &fixture.paths, test_instance, path, null);
    defer prepared.deinit();
    defer prepared.cleanup(io) catch unreachable;
    try std.testing.expectEqual(@as(usize, 2), prepared.files.len);
    try std.testing.expectEqual(@as(usize, 1), prepared.manual_files.len);
    try std.testing.expect(prepared.files[0].download == .remote);
    try std.testing.expect(prepared.files[1].download == .manual_required);
    try std.testing.expectEqual(@as(?u64, 10), prepared.files[1].record.size);
    try std.testing.expectEqualStrings("config/replaced.txt", prepared.manual_files[0].path);
    const alias_index = try testRemoteIndex(a, &.{ "mods/a.jar", "Mods/b.jar" });
    defer a.free(alias_index);
    try testZip(fixture.tmp.dir, "alias.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = alias_index }});
    const alias_path = try fixture.path("alias.mrpack");
    defer a.free(alias_path);
    try std.testing.expectError(error.PathCollision, prepare(a, io, &fixture.paths, test_instance, alias_path, null));
}

test "import rejects malformed unsupported ambiguous and unsafe archives" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    try testZip(fixture.tmp.dir, "local.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = "{}" }});
    try std.testing.expectError(error.MissingField, prepare(a, io, &fixture.paths, test_instance, path, null));
    try testZip(fixture.tmp.dir, "local.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = "{\"formatVersion\":2}" }});
    try std.testing.expectError(error.UnsupportedSchema, prepare(a, io, &fixture.paths, test_instance, path, null));
    try testZip(fixture.tmp.dir, "local.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = test_mrpack }, .{ .path = "manifest.json", .bytes = test_cf } });
    try std.testing.expectError(error.AmbiguousPackFormat, prepare(a, io, &fixture.paths, test_instance, path, null));
    try testZip(fixture.tmp.dir, "local.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = test_mrpack }, .{ .path = "../escape.txt", .bytes = "bad" } });
    try std.testing.expectError(error.UnsafeArchivePath, prepare(a, io, &fixture.paths, test_instance, path, null));
    try testZip(fixture.tmp.dir, "local.mrpack", &.{.{ .path = "manifest.json", .bytes = test_cf }});
    try std.testing.expectError(error.PackFormatMismatch, prepare(a, io, &fixture.paths, test_instance, path, null));
}

test "import index is bounded and unknown loader prerequisite fails truthfully" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    const large = try a.alloc(u8, providers.max_json_bytes + 1);
    defer a.free(large);
    @memset(large, ' ');
    try testZip(fixture.tmp.dir, "local.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = large }});
    try std.testing.expectError(error.StreamTooLong, prepare(a, io, &fixture.paths, test_instance, path, null));
    const unknown = try std.json.Stringify.valueAlloc(a, .{ .formatVersion = @as(u32, 1), .game = "minecraft", .versionId = "v1", .name = "unknown", .dependencies = .{ .minecraft = "1.21.1", .@"unknown-loader" = "1" }, .files = @as([]const u8, &.{}) }, .{});
    defer a.free(unknown);
    try testZip(fixture.tmp.dir, "local.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = unknown }});
    try std.testing.expectError(error.UnknownRequiredDependency, prepare(a, io, &fixture.paths, test_instance, path, null));
}

fn testAllocationFailure(a: Allocator, paths: *const instances.Paths, path: []const u8) !void {
    var prepared = try prepare(a, std.testing.io, paths, test_instance, path, null);
    defer prepared.deinit();
    try prepared.cleanup(std.testing.io);
}
test "import allocation failures free owned plans and remove partial private stages" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try testZip(fixture.tmp.dir, "local.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = test_mrpack }, .{ .path = "overrides/config/a.txt", .bytes = "a" }, .{ .path = "client-overrides/config/a.txt", .bytes = "client" } });
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    try @import("test_allocations").checkAllAllocationFailures(a, testAllocationFailure, .{ &fixture.paths, path });
    const stage_root = try fixture.path(".vela/pack-imports");
    defer a.free(stage_root);
    const stages = try fs.openAbsolute(io, stage_root);
    defer stages.close(io);
    var iterator = stages.iterate();
    try std.testing.expect(try iterator.next(io) == null);
}

test "pack inspection exposes exact prerequisites without target or game publication" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try testZip(fixture.tmp.dir, "local.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = test_mrpack }});
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    var inspected = try inspect(a, io, &fixture.paths, path, null);
    defer inspected.deinit();
    defer inspected.cleanup(io) catch {};
    try std.testing.expectEqualStrings("1.21.1", inspected.pack.minecraft_version);
    try std.testing.expectEqual(config.Loader.fabric, inspected.pack.loader);
    try std.testing.expectEqualStrings("0.16.10", inspected.pack.loader_version.?);
    try std.testing.expectEqualStrings(&inspected.source_sha256, inspected.pack.identity.version_id);
    var wrong = test_instance;
    wrong.minecraft_version = "1.20.1";
    try std.testing.expectError(error.MinecraftVersionMismatch, prepareInspected(a, io, &fixture.paths, wrong, &inspected, null));
    try std.testing.expectError(error.MinecraftVersionMismatch, prepare(a, io, &fixture.paths, wrong, path, null));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft", .{}));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".vela/config.json", .{}));
    try testZip(fixture.tmp.dir, "local.zip", &.{.{ .path = "manifest.json", .bytes = test_cf }});
    const cf_path = try fixture.path("local.zip");
    defer a.free(cf_path);
    var cf = try inspect(a, io, &fixture.paths, cf_path, null);
    defer cf.deinit();
    defer cf.cleanup(io) catch {};
    try std.testing.expectEqual(providers.Provider.curseforge, cf.provider);
    try std.testing.expectEqualStrings("1.21.1", cf.pack.minecraft_version);
    try std.testing.expectEqualStrings("0.16.10", cf.pack.loader_version.?);
    try std.testing.expectEqual(@as(usize, 1), cf.pack.unresolved.len);
    try std.testing.expectEqualStrings("123", cf.pack.unresolved[0].project_id);
    try std.testing.expectEqualStrings("456", cf.pack.unresolved[0].file_id);
}

test "pack preparation reuses inspected bytes after original archive changes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try testZip(fixture.tmp.dir, "local.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = test_mrpack }, .{ .path = "overrides/config/keep.txt", .bytes = "inspected" } });
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    var inspected = try inspect(a, io, &fixture.paths, path, null);
    defer inspected.deinit();
    defer inspected.cleanup(io) catch {};
    try testZip(fixture.tmp.dir, "local.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = test_mrpack }, .{ .path = "overrides/config/keep.txt", .bytes = "different" } });
    var prepared = try prepareInspected(a, io, &fixture.paths, test_instance, &inspected, null);
    defer prepared.deinit();
    defer prepared.cleanup(io) catch {};
    try std.testing.expectEqual(providers.Provider.modrinth, prepared.pack.identity.provider);
    try std.testing.expectEqualStrings(&inspected.source_sha256, prepared.pack.identity.version_id);
    try std.testing.expectEqual(@as(usize, 1), prepared.manual_files.len);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, prepared.manual_files[0].source_absolute_path, a, .limited(64));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("inspected", bytes);
    try std.testing.expect(!std.mem.eql(u8, inspected.stage_absolute_path, prepared.stage_absolute_path));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft", .{}));
}

test "pack preparation rejects tampered inspected copy before extraction" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try testZip(fixture.tmp.dir, "local.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = test_mrpack }});
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    var inspected = try inspect(a, io, &fixture.paths, path, null);
    defer inspected.deinit();
    defer inspected.cleanup(io) catch {};
    const stage = try fs.openAbsolute(io, inspected.stage_absolute_path);
    defer stage.close(io);
    try testZip(stage, std.fs.path.basename(inspected.archive_absolute_path), &.{ .{ .path = "modrinth.index.json", .bytes = test_mrpack }, .{ .path = "overrides/config/injected.txt", .bytes = "injected" } });
    try std.testing.expectError(error.InspectedArchiveChanged, prepareInspected(a, io, &fixture.paths, test_instance, &inspected, null));
    const stages_path = try fixture.path(".vela/pack-imports");
    defer a.free(stages_path);
    const stages = try fs.openAbsolute(io, stages_path);
    defer stages.close(io);
    var iterator = stages.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft", .{}));
}

fn testInspectionAllocationFailure(a: Allocator, paths: *const instances.Paths, path: []const u8) !void {
    var inspected = try inspect(a, std.testing.io, paths, path, null);
    defer inspected.deinit();
    try inspected.cleanup(std.testing.io);
}

test "pack inspection cancellation and allocation failure leave no private stages" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try testZip(fixture.tmp.dir, "local.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = test_mrpack }});
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    var cancel = CancelToken.init(true);
    try std.testing.expectError(error.Canceled, inspect(a, io, &fixture.paths, path, &cancel));
    try @import("test_allocations").checkAllAllocationFailures(a, testInspectionAllocationFailure, .{ &fixture.paths, path });
    const stages_path = try fixture.path(".vela/pack-imports");
    defer a.free(stages_path);
    const stages = try fs.openAbsolute(io, stages_path);
    defer stages.close(io);
    var iterator = stages.iterate();
    try std.testing.expect(try iterator.next(io) == null);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft", .{}));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".vela/config.json", .{}));
}

test "target-free inspection rejects launcher receipts in indexes and override layers" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    for ([_][]const u8{ ".vela-instance.json", ".VeLa-InStAnCe.JsOn/child", ".vela-loader.json", ".VELA-LOADER.JSON/child" }) |target| {
        const index = try testRemoteIndex(a, &.{target});
        defer a.free(index);
        try testZip(fixture.tmp.dir, "local.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = index }});
        try std.testing.expectError(error.ProtectedPath, inspect(a, io, &fixture.paths, path, null));
        const override_path = try std.fmt.allocPrint(a, "overrides/{s}", .{target});
        defer a.free(override_path);
        try testZip(fixture.tmp.dir, "local.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = test_mrpack }, .{ .path = override_path, .bytes = "receipt" } });
        try std.testing.expectError(error.ProtectedPath, inspect(a, io, &fixture.paths, path, null));
    }
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft", .{}));
}

test "preparation protects exact target JSON and JAR before compatibility in indexes and overrides" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    var incompatible = test_instance;
    incompatible.minecraft_version = "wrong-version";
    for ([_][]const u8{ "Exact Name.json", "eXaCt NaMe.JsOn/child", "Exact Name.jar", "EXACT NAME.JAR/child" }) |target| {
        for ([_]bool{ false, true }) |override| {
            const index = if (override) try a.dupe(u8, test_mrpack) else try testRemoteIndex(a, &.{target});
            defer a.free(index);
            const override_path = try std.fmt.allocPrint(a, "client-overrides/{s}", .{target});
            defer a.free(override_path);
            const entries = [_]TestEntry{ .{ .path = "modrinth.index.json", .bytes = index }, .{ .path = override_path, .bytes = "launcher-owned" } };
            try testZip(fixture.tmp.dir, "local.mrpack", entries[0..if (override) @as(usize, 2) else 1]);
            // Target-free inspection intentionally permits an otherwise ordinary root JSON/JAR.
            var inspected = try inspect(a, io, &fixture.paths, path, null);
            defer inspected.deinit();
            defer inspected.cleanup(io) catch {};
            try std.testing.expectError(error.ProtectedPath, prepareInspected(a, io, &fixture.paths, incompatible, &inspected, null));
            try std.testing.expectError(error.ProtectedPath, prepare(a, io, &fixture.paths, incompatible, path, null));
        }
    }
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft", .{}));
}

test "inspection and preparation retain ordinary root configuration JSON" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    try testZip(fixture.tmp.dir, "local.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = test_mrpack }, .{ .path = "overrides/settings.json", .bytes = "settings" }, .{ .path = "client-overrides/Other.json", .bytes = "other" } });
    const path = try fixture.path("local.mrpack");
    defer a.free(path);
    var inspected = try inspect(a, io, &fixture.paths, path, null);
    defer inspected.deinit();
    defer inspected.cleanup(io) catch {};
    var prepared = try prepareInspected(a, io, &fixture.paths, test_instance, &inspected, null);
    defer prepared.deinit();
    defer prepared.cleanup(io) catch {};
    try std.testing.expectEqual(@as(usize, 2), prepared.files.len);
    for (prepared.files) |file| {
        try manifest.checkedPathForInstance(file.record.path, test_instance.name);
        try std.testing.expect(std.mem.eql(u8, file.record.path, "settings.json") or std.mem.eql(u8, file.record.path, "Other.json"));
    }
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft", .{}));
}
test "pack target preflight bounds precede uninitialized inspection collections" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = try a.alloc(manifest.InstallFile, providers.max_items + 1);
    defer a.free(files);
    const references = try a.alloc(manifest.PackReference, providers.max_items + 1);
    defer a.free(references);
    var pack: manifest.PackPlan = .{ .identity = .{ .provider = .modrinth, .project_id = "project", .version_id = "v1" }, .name = "Pack", .version = "v1", .minecraft_version = "1.20.1", .files = files };
    try std.testing.expectError(error.TooManyItems, validatePackTargets(a, io, tmp.dir, pack, "Test", null));
    pack.files = &.{};
    pack.unresolved = references;
    try std.testing.expectError(error.TooManyItems, validatePackTargets(a, io, tmp.dir, pack, "Test", null));
}
