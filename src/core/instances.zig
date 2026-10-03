//! Shared game artifacts and isolated mutable directories below a launcher base.
const std = @import("std");
const config = @import("config.zig");
const Allocator = std.mem.Allocator;

pub const Paths = struct {
    allocator: Allocator,
    root: []const u8,
    minecraft: []const u8,
    vela: []const u8,
    assets: []const u8,
    libraries: []const u8,
    jdks: []const u8,
    cache: []const u8,
    logs: []const u8,

    /// root is explicit; resolving it does not create or migrate any data.
    pub fn init(a: Allocator, io: std.Io, root: []const u8) !Paths {
        if (root.len == 0 or std.mem.indexOfScalar(u8, root, 0) != null) return error.UnsafeDataRoot;
        const cwd = try std.process.currentPathAlloc(io, a);
        defer a.free(cwd);
        const base = try std.fs.path.resolve(a, &.{ cwd, root });
        errdefer a.free(base);
        const minecraft = try std.fs.path.join(a, &.{ base, ".minecraft" });
        errdefer a.free(minecraft);
        const vela = try std.fs.path.join(a, &.{ base, ".vela" });
        errdefer a.free(vela);
        const assets = try std.fs.path.join(a, &.{ minecraft, "assets" });
        errdefer a.free(assets);
        const libraries = try std.fs.path.join(a, &.{ minecraft, "libraries" });
        errdefer a.free(libraries);
        const jdks = try std.fs.path.join(a, &.{ vela, "jdks" });
        errdefer a.free(jdks);
        const cache = try std.fs.path.join(a, &.{ vela, "cache" });
        errdefer a.free(cache);
        const logs = try std.fs.path.join(a, &.{ vela, "logs" });
        errdefer a.free(logs);
        return .{ .allocator = a, .root = base, .minecraft = minecraft, .vela = vela, .assets = assets, .libraries = libraries, .jdks = jdks, .cache = cache, .logs = logs };
    }

    pub fn deinit(self: *Paths) void {
        inline for (.{ "logs", "cache", "jdks", "libraries", "assets", "vela", "minecraft", "root" }) |field| {
            self.allocator.free(@field(self, field));
        }
        self.* = undefined;
    }

    /// Instance.name is the directory name; Instance.id is a stable config key.
    /// Returned paths belong to the caller, using this allocator.
    pub fn instanceDirectory(self: *const Paths, name: []const u8) ![]u8 {
        if (!config.validId(name)) return error.UnsafeInstanceName;
        return std.fs.path.join(self.allocator, &.{ self.minecraft, "versions", name });
    }

    pub fn instancePath(self: *const Paths, instance: config.Instance, sub_path: []const u8) ![]u8 {
        if (!safeRelativePath(sub_path)) return error.UnsafeRelativePath;
        const directory = try self.instanceDirectory(instance.name);
        defer self.allocator.free(directory);
        return std.fs.path.join(self.allocator, &.{ directory, sub_path });
    }

    pub fn versionDocument(self: *const Paths, name: []const u8) ![]u8 {
        const directory = try self.instanceDirectory(name);
        defer self.allocator.free(directory);
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{name});
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ directory, filename });
    }

    pub fn instanceManifest(self: *const Paths, id: []const u8) ![]u8 {
        if (!config.validId(id)) return error.UnsafeInstanceId;
        return std.fs.path.join(self.allocator, &.{ self.vela, "instances", id, "content.json" });
    }
};

/// Archive and managed-file paths use forward slashes regardless of host OS.
/// This is lexical validation, not permission to follow untrusted symlinks.
pub fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096 or path[0] == '/' or path[path.len - 1] == '/') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (!config.validId(part)) return false;
    return true;
}

pub fn findById(document: *const config.Document, id: []const u8) ?*const config.Instance {
    for (document.instances) |*instance| if (std.mem.eql(u8, instance.id, id)) return instance;
    return null;
}

pub fn findByName(document: *const config.Document, name: []const u8) ?*const config.Instance {
    for (document.instances) |*instance| if (std.mem.eql(u8, instance.name, name)) return instance;
    return null;
}

/// Running-instance mutations are rejected even when initiated from another view.
pub fn requireMutable(instance_id: []const u8, running_id: ?[]const u8) !void {
    if (running_id) |running| {
        if (std.mem.eql(u8, instance_id, running)) return error.InstanceRunning;
    }
}

test "isolated game directories and shared launcher artifacts" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var paths = try Paths.init(a, io, ".");
    defer paths.deinit();
    try std.testing.expect(std.fs.path.isAbsolute(paths.root));
    const first = try paths.instanceDirectory("First");
    defer a.free(first);
    const second = try paths.instanceDirectory("Second");
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const expected = try std.fs.path.join(a, &.{ paths.minecraft, "versions", "First" });
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, first);
    const document = try paths.versionDocument("First");
    defer a.free(document);
    const expected_document = try std.fs.path.join(a, &.{ first, "First.json" });
    defer a.free(expected_document);
    try std.testing.expectEqualStrings(expected_document, document);
    const manifest = try paths.instanceManifest("stable-key");
    defer a.free(manifest);
    const expected_manifest = try std.fs.path.join(a, &.{ paths.vela, "instances", "stable-key", "content.json" });
    defer a.free(expected_manifest);
    try std.testing.expectEqualStrings(expected_manifest, manifest);
    const instance: config.Instance = .{ .id = "stable-key", .name = "First", .minecraft_version = "1.21.1" };
    const saves = try paths.instancePath(instance, "saves/World/level.dat");
    defer a.free(saves);
    const expected_saves = try std.fs.path.join(a, &.{ first, "saves", "World", "level.dat" });
    defer a.free(expected_saves);
    try std.testing.expectEqualStrings(expected_saves, saves);
}

test "portable instance and managed paths reject escape forms" {
    var paths = try Paths.init(std.testing.allocator, std.testing.io, ".");
    defer paths.deinit();
    for ([_][]const u8{ "", ".", "..", "../Other", "C:drive", "CON", "trailing.", "a/b", "a\\b" }) |name| {
        try std.testing.expectError(error.UnsafeInstanceName, paths.instanceDirectory(name));
    }
    for ([_][]const u8{ "", "../evil", "config/../evil", "./evil", "/etc/passwd", "C:/evil", "saves//world", "saves/world/", "saves\\world", "mods/NUL.jar", "config/bad:name" }) |path| {
        try std.testing.expect(!safeRelativePath(path));
    }
    for ([_][]const u8{ "mods/example.jar", "config/client.toml", "saves/World/level.dat" }) |path| {
        try std.testing.expect(safeRelativePath(path));
    }
    try std.testing.expectError(error.UnsafeDataRoot, Paths.init(std.testing.allocator, std.testing.io, ""));
    try std.testing.expectError(error.UnsafeDataRoot, Paths.init(std.testing.allocator, std.testing.io, "bad\x00root"));
}

test "instance IDs remain stable independently from directory names" {
    const document: config.Document = .{ .instances = &.{.{ .id = "stable", .name = "Display Name", .minecraft_version = "1.21.1" }} };
    try std.testing.expectEqualStrings("Display Name", findById(&document, "stable").?.name);
    try std.testing.expectEqualStrings("stable", findByName(&document, "Display Name").?.id);
    try std.testing.expect(findById(&document, "Display Name") == null);
    try requireMutable("stable", null);
    try requireMutable("other", "stable");
    try std.testing.expectError(error.InstanceRunning, requireMutable("stable", "stable"));
}

fn checkPathsAllocations(a: Allocator) !void {
    var paths = try Paths.init(a, std.testing.io, ".");
    defer paths.deinit();
    const directory = try paths.instanceDirectory("Instance");
    defer a.free(directory);
    const document = try paths.versionDocument("Instance");
    defer a.free(document);
    const manifest = try paths.instanceManifest("stable-id");
    defer a.free(manifest);
}

test "path construction cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkPathsAllocations, .{});
}
