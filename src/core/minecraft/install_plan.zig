//! Pure installation planning for resolved modern vanilla metadata. No IO.
const std = @import("std");
const m = @import("metadata/root.zig");
pub const NativeArch = enum { bits32, bits64 };
pub const Directories = struct { root: []const u8 = ".minecraft", natives: ?[]const u8 = null, native_arch: ?NativeArch = null };
pub const Kind = enum { client, library, native, asset_index, asset, logging };
pub const File = struct { kind: Kind, url: []const u8, path: []const u8, sha1: ?m.Sha1, size: ?u64 };
pub const NativeExtraction = struct { archive_path: []const u8, destination: []const u8, exclude: []const []const u8 };
pub const Plan = struct { files: []const File, native_extractions: []const NativeExtraction, classpath: []const []const u8, client_path: []const u8 };

/// Inputs must describe the same version. Paths are lexical: executor must also
/// prevent symlink escapes and validate archive members when performing IO.
pub fn build(allocator: std.mem.Allocator, version: m.version.Version, assets: m.asset_index.AssetIndex, environment: m.rules.Environment, directories: Directories) !m.Owned(Plan) {
    if (version.inherits_from != null) return error.UnresolvedInheritance;
    if (version.jar != null) return error.UnsupportedJarOverride;
    if ((assets.virtual orelse false) or (assets.map_to_resources orelse false)) return error.UnsupportedLegacyAssets;
    if (directories.root.len == 0 or std.mem.indexOfScalar(u8, directories.root, 0) != null) return error.InvalidDirectories;
    if (directories.natives) |path| if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidDirectories;
    try component(version.id);
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();
    const native_destination = if (directories.natives) |path| try a.dupe(u8, path) else try std.fs.path.join(a, &.{ directories.root, "versions", version.id, "natives" });
    var context: Context = .{ .a = a, .root = directories.root, .windows = std.mem.eql(u8, environment.os_name, "windows") };
    var cp: std.ArrayList([]const u8) = .empty;
    var cp_seen: std.StringHashMapUnmanaged(void) = .empty;
    var extractions: std.ArrayList(NativeExtraction) = .empty;
    var client: ?m.version.Download = null;
    for (version.downloads) |entry| if (std.mem.eql(u8, entry.name, "client")) {
        client = entry.download;
        break;
    };
    const jar = client orelse return error.MissingClientDownload;
    const jar_name = try std.fmt.allocPrint(a, "{s}.jar", .{version.id});
    const client_path = try context.add(.client, &.{ "versions", version.id, jar_name }, jar);
    const index = version.asset_index orelse return error.MissingAssetIndex;
    try component(index.id);
    const index_name = try std.fmt.allocPrint(a, "{s}.json", .{index.id});
    _ = try context.add(.asset_index, &.{ "assets", "indexes", index_name }, .{ .url = index.url, .sha1 = index.sha1, .size = index.size, .path = null });
    for (version.libraries orelse return error.MissingLibraries) |library| {
        if (!try m.rules.allows(library.rules, environment)) continue;
        const downloads = library.downloads orelse return error.UnsupportedLegacyLibrary;
        if (downloads.artifact == null and library.natives.len == 0) return error.MissingLibraryDownload;
        if (downloads.artifact) |artifact| {
            const path = artifact.path orelse return error.MissingLibraryPath;
            const installed = try context.add(.library, &.{ "libraries", path }, artifact);
            const key = try context.pathKey(installed);
            const result = try cp_seen.getOrPut(a, key);
            if (!result.found_existing) try cp.append(a, installed);
        }
        for (library.natives) |native| {
            if (!std.mem.eql(u8, native.key, environment.os_name)) continue;
            const classifier = try classifierName(a, native.value, directories.native_arch);
            var chosen: ?m.version.Download = null;
            for (downloads.classifiers) |candidate| if (std.mem.eql(u8, candidate.name, classifier)) {
                chosen = candidate.download;
                break;
            };
            const artifact = chosen orelse return error.MissingNativeClassifier;
            const path = artifact.path orelse return error.MissingLibraryPath;
            const installed = try context.add(.native, &.{ "libraries", path }, artifact);
            const excludes = library.extract_exclude orelse &.{};
            const copied = try a.alloc([]const u8, excludes.len);
            for (excludes, copied) |exclude, *out| {
                if (std.mem.indexOfScalar(u8, exclude, 0) != null) return error.UnsafePath;
                out.* = try a.dupe(u8, exclude);
            }
            try extractions.append(a, .{ .archive_path = installed, .destination = native_destination, .exclude = copied });
            break;
        }
    }
    try cp.append(a, client_path);
    for (assets.objects) |asset| {
        const hex = std.fmt.bytesToHex(asset.hash, .lower);
        const url = try std.fmt.allocPrint(a, "https://resources.download.minecraft.net/{s}/{s}", .{ hex[0..2], &hex });
        _ = try context.add(.asset, &.{ "assets", "objects", hex[0..2], &hex }, .{ .url = url, .sha1 = asset.hash, .size = asset.size, .path = null });
    }
    for (version.logging) |logging| {
        if (!std.mem.eql(u8, logging.name, "client")) continue;
        try component(logging.file.id);
        _ = try context.add(.logging, &.{ "assets", "log_configs", logging.file.id }, .{ .url = logging.file.url, .sha1 = logging.file.sha1, .size = logging.file.size, .path = null });
    }
    return .{ .value = .{ .files = try context.files.toOwnedSlice(a), .native_extractions = try extractions.toOwnedSlice(a), .classpath = try cp.toOwnedSlice(a), .client_path = client_path }, .arena = arena, .backing = allocator };
}
const Context = struct {
    a: std.mem.Allocator,
    root: []const u8,
    windows: bool,
    files: std.ArrayList(File) = .empty,
    paths: std.StringHashMapUnmanaged(usize) = .empty,
    directory_paths: std.StringHashMapUnmanaged(void) = .empty,
    fn pathKey(self: *Context, path: []const u8) ![]const u8 {
        const key = try self.a.dupe(u8, path);
        if (self.windows) for (key) |*c| {
            c.* = std.ascii.toLower(c.*);
        };
        return key;
    }
    fn add(self: *Context, kind: Kind, pieces: []const []const u8, download: m.version.Download) ![]const u8 {
        for (pieces) |piece| try relative(piece);
        if (download.path) |path| try relative(path);
        if (download.url.len == 0) return error.MissingDownloadUrl;
        const parts = try self.a.alloc([]const u8, pieces.len + 1);
        parts[0] = self.root;
        @memcpy(parts[1..], pieces);
        const path = try std.fs.path.join(self.a, parts);
        const key = try self.pathKey(path);
        if (self.paths.get(key)) |i| {
            const old = &self.files.items[i];
            if (old.sha1 != null and download.sha1 != null and !std.mem.eql(u8, &old.sha1.?, &download.sha1.?)) return error.PathConflict;
            if (old.size != null and download.size != null and old.size.? != download.size.?) return error.PathConflict;
            if (!(old.sha1 != null and download.sha1 != null) and !std.mem.eql(u8, old.url, download.url)) return error.PathConflict;
            if (old.sha1 == null) old.sha1 = download.sha1;
            if (old.size == null) old.size = download.size;
            return old.path;
        }
        if (self.directory_paths.contains(key)) return error.PathConflict;
        for (key, 0..) |c, i| {
            if (c != '/' and c != 92) continue;
            if (self.paths.contains(key[0..i])) return error.PathConflict;
            try self.directory_paths.put(self.a, key[0..i], {});
        }
        try self.paths.put(self.a, key, self.files.items.len);
        try self.files.append(self.a, .{ .kind = kind, .url = try self.a.dupe(u8, download.url), .path = path, .sha1 = download.sha1, .size = download.size });
        return path;
    }
};
fn component(name: []const u8) !void {
    try relative(name);
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.UnsafePath;
}
fn relative(path: []const u8) !void {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 92) != null or std.mem.indexOfScalar(u8, path, ':') != null) return error.UnsafePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.UnsafePath;
        for (part) |c| if (c < 32 or c >= 127 or c == 34 or std.mem.indexOfScalar(u8, "<>|?*", c) != null) return error.UnsafePath;
        const end = std.mem.indexOfScalar(u8, part, '.') orelse part.len;
        const base = part[0..end];
        if (std.ascii.eqlIgnoreCase(base, "con") or std.ascii.eqlIgnoreCase(base, "prn") or std.ascii.eqlIgnoreCase(base, "aux") or std.ascii.eqlIgnoreCase(base, "nul")) return error.UnsafePath;
        if (base.len == 4 and (std.ascii.eqlIgnoreCase(base[0..3], "com") or std.ascii.eqlIgnoreCase(base[0..3], "lpt")) and base[3] >= '0' and base[3] <= '9') return error.UnsafePath;
    }
}
fn classifierName(a: std.mem.Allocator, template: []const u8, arch: ?NativeArch) ![]const u8 {
    const marker = "$" ++ "{arch}";
    var result: std.ArrayList(u8) = .empty;
    var rest = template;
    while (std.mem.indexOf(u8, rest, marker)) |i| {
        try result.appendSlice(a, rest[0..i]);
        try result.appendSlice(a, switch (arch orelse return error.NativeArchRequired) {
            .bits32 => "32",
            .bits64 => "64",
        });
        rest = rest[i + marker.len ..];
    }
    try result.appendSlice(a, rest);
    if (std.mem.indexOf(u8, result.items, "$" ++ "{") != null) return error.UnsupportedNativeTemplate;
    return result.toOwnedSlice(a);
}

const fixture =
    "{\"id\":\"v1\",\"downloads\":{\"client\":{\"url\":\"https://example/client\",\"size\":10}},\"assetIndex\":{\"id\":\"a1\",\"url\":\"https://example/index\"},\"libraries\":[{\"name\":\"base\",\"downloads\":{\"artifact\":{\"path\":\"org/base.jar\",\"url\":\"https://example/base\",\"size\":20},\"classifiers\":{\"native-64\":{\"path\":\"org/native.jar\",\"url\":\"https://example/native\",\"size\":30},\"unused\":{\"path\":\"unused.jar\",\"url\":\"https://example/unused\"}}},\"natives\":{\"linux\":\"native-${arch}\"},\"extract\":{\"exclude\":[\"META-INF/\"]}},{\"name\":\"excluded\",\"rules\":[]}],\"logging\":{\"client\":{\"argument\":\"arg\",\"type\":\"xml\",\"file\":{\"id\":\"log.xml\",\"url\":\"https://example/log\"}},\"server\":{\"argument\":\"arg\",\"type\":\"xml\",\"file\":{\"id\":\"server.xml\",\"url\":\"https://example/server\"}}}}";
const asset_fixture =
    "{\"objects\":{\"中文:one\":{\"hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"size\":5},\"two\":{\"hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"size\":5}}}";
const dirs: Directories = .{ .root = "/game", .natives = "/instance/natives", .native_arch = .bits64 };
const env: m.rules.Environment = .{ .os_name = "linux", .arch = "x86_64" };

test "plan owns sources and selects artifacts natives assets logging and ordered classpath" {
    const a = std.testing.allocator;
    var plan: m.Owned(Plan) = undefined;
    {
        var version = try m.version.parseSlice(a, fixture);
        defer version.deinit();
        var assets = try m.asset_index.parseSlice(a, asset_fixture);
        defer assets.deinit();
        plan = try build(a, version.value, assets.value, env, dirs);
    }
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 6), plan.value.files.len);
    try std.testing.expectEqual(@as(usize, 2), plan.value.classpath.len);
    try std.testing.expectEqualStrings("/game/libraries/org/base.jar", plan.value.classpath[0]);
    try std.testing.expectEqualStrings("/game/versions/v1/v1.jar", plan.value.classpath[1]);
    try std.testing.expectEqualStrings("/game/assets/indexes/a1.json", plan.value.files[1].path);
    try std.testing.expectEqualStrings("https://resources.download.minecraft.net/aa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", plan.value.files[4].url);
    try std.testing.expectEqualStrings("/instance/natives", plan.value.native_extractions[0].destination);
    try std.testing.expectEqualStrings("META-INF/", plan.value.native_extractions[0].exclude[0]);
}
test "unsupported layouts and native architecture are explicit errors" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    var assets = try m.asset_index.parseSlice(a, asset_fixture);
    defer assets.deinit();
    try std.testing.expectError(error.NativeArchRequired, build(a, version.value, assets.value, env, .{ .root = "/g", .natives = "/n" }));
    assets.value.virtual = true;
    try std.testing.expectError(error.UnsupportedLegacyAssets, build(a, version.value, assets.value, env, dirs));
    assets.value.virtual = null;
    version.value.inherits_from = "parent";
    try std.testing.expectError(error.UnresolvedInheritance, build(a, version.value, assets.value, env, dirs));
    version.value.inherits_from = null;
    version.value.jar = "parent";
    try std.testing.expectError(error.UnsupportedJarOverride, build(a, version.value, assets.value, env, dirs));
}
test "portable metadata paths reject traversal windows aliases and controls" {
    for ([_][]const u8{ "../escape", "/abs", "C:/abs", "a/../b", "a//b", "CON.txt", "nul", "path.", "path ", "a?b", "a/b/", "a/./b" }) |path| try std.testing.expectError(error.UnsafePath, relative(path));
    try std.testing.expectError(error.UnsafePath, relative(&.{ 'a', 92, 'b' }));
    try std.testing.expectError(error.UnsafePath, relative(&.{ 'a', 0, 'b' }));
    try relative("org/example/lib-1.0.jar");
}
test "same path dedup merges checksums but conflicts fail including windows case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: Context = .{ .a = arena.allocator(), .root = "/game", .windows = true };
    const d: m.version.Download = .{ .url = "https://example/a", .path = null, .sha1 = .{1} ** 20, .size = 1 };
    _ = try ctx.add(.library, &.{"libraries/A.jar"}, d);
    _ = try ctx.add(.library, &.{"libraries/a.jar"}, d);
    try std.testing.expectEqual(@as(usize, 1), ctx.files.items.len);
    var bad = d;
    bad.size = 2;
    try std.testing.expectError(error.PathConflict, ctx.add(.library, &.{"libraries/a.jar"}, bad));
    _ = try ctx.add(.library, &.{"libraries/other.jar"}, d);
    try std.testing.expectEqual(@as(usize, 2), ctx.files.items.len);
}
fn allocationCase(a: std.mem.Allocator) !void {
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    var assets = try m.asset_index.parseSlice(a, asset_fixture);
    defer assets.deinit();
    var plan = try build(a, version.value, assets.value, env, dirs);
    defer plan.deinit();
}
test "all planner allocations clean up on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
test "modern native artifacts stay on classpath and incomplete libraries fail" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    var assets = try m.asset_index.parseSlice(a, asset_fixture);
    defer assets.deinit();
    var library = version.value.libraries.?[0];
    library.name = "org.lwjgl:lwjgl:3:natives-linux";
    library.natives = &.{};
    var libraries = [_]m.version.Library{library};
    version.value.libraries = &libraries;
    var plan = try build(a, version.value, assets.value, env, dirs);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 0), plan.value.native_extractions.len);
    try std.testing.expectEqual(@as(usize, 2), plan.value.classpath.len);
    try std.testing.expectEqualStrings("/game/libraries/org/base.jar", plan.value.classpath[0]);
    var count: usize = 0;
    for (plan.value.files) |file| if (file.kind == .asset) {
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), count);
    libraries[0].downloads.?.artifact = null;
    try std.testing.expectError(error.MissingLibraryDownload, build(a, version.value, assets.value, env, dirs));
}
test "file directory conflicts are rejected in either insertion order" {
    for ([_]bool{ false, true }) |reverse| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ctx: Context = .{ .a = arena.allocator(), .root = "/game", .windows = false };
        const d: m.version.Download = .{ .url = "https://example/a", .path = null, .sha1 = null, .size = null };
        const first = if (reverse) "libraries/x/y.jar" else "libraries/x";
        const second = if (reverse) "libraries/x" else "libraries/x/y.jar";
        _ = try ctx.add(.library, &.{first}, d);
        try std.testing.expectError(error.PathConflict, ctx.add(.library, &.{second}, d));
    }
}
test "default root is local minecraft with version isolated natives" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    var assets = try m.asset_index.parseSlice(a, asset_fixture);
    defer assets.deinit();
    var library = version.value.libraries.?[0];
    const names = [_]@import("metadata/json.zig").StringEntry{.{ .key = "linux", .value = "native-64" }};
    library.natives = &names;
    const libraries = [_]m.version.Library{library};
    version.value.libraries = &libraries;
    var first = try build(a, version.value, assets.value, env, .{});
    defer first.deinit();
    try std.testing.expectEqualStrings(".minecraft/versions/v1/v1.jar", first.value.client_path);
    try std.testing.expectEqualStrings(".minecraft/versions/v1/natives", first.value.native_extractions[0].destination);
    version.value.id = "v2";
    var second = try build(a, version.value, assets.value, env, .{});
    defer second.deinit();
    try std.testing.expectEqualStrings(".minecraft/versions/v2/natives", second.value.native_extractions[0].destination);
}
