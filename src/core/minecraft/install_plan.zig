//! Pure installation planning for resolved modern/legacy metadata. No IO.
const std = @import("std");
const m = @import("metadata/root.zig");
pub const NativeArch = enum { bits32, bits64 };
pub const Directories = struct {
    root: []const u8 = ".minecraft",
    natives: ?[]const u8 = null,
    native_arch: ?NativeArch = null,
    cpu_arch: ?[]const u8 = null,
    instance_name: ?[]const u8 = null,
    game_directory: ?[]const u8 = null,
};
pub const Kind = enum { client, library, native, asset_index, asset, logging };
pub const File = struct { kind: Kind, url: []const u8, path: []const u8, sha1: ?m.Sha1, size: ?u64 };
pub const NativeExtraction = struct { archive_path: []const u8, destination: []const u8, exclude: []const []const u8 };
pub const NativeSuitability = enum { compatible, inspection_required, incompatible };
pub const NativeCheck = struct { archive_path: []const u8, classifier: []const u8, suitability: NativeSuitability };
pub const AssetMaterialization = struct { source_path: []const u8, destination: []const u8, sha1: m.Sha1, size: u64 };
pub const Plan = struct {
    files: []const File,
    native_extractions: []const NativeExtraction,
    classpath: []const []const u8,
    client_path: []const u8,
    native_checks: []const NativeCheck = &.{},
    asset_materializations: []const AssetMaterialization = &.{},
    game_assets_directory: ?[]const u8 = null,
};

/// Inputs must describe the same version. Paths are lexical: executor must also
/// prevent symlink escapes and validate archive members when performing IO.
pub fn build(allocator: std.mem.Allocator, version: m.version.Version, assets: m.asset_index.AssetIndex, environment: m.rules.Environment, directories: Directories) !m.Owned(Plan) {
    if (version.inherits_from != null) return error.UnresolvedInheritance;
    if (version.jar) |id| try m.version.validateId(id);
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
    const instance = directories.instance_name orelse version.id;
    try component(instance);
    const game_directory = directories.game_directory orelse directories.root;
    if (game_directory.len == 0 or std.mem.indexOfScalar(u8, game_directory, 0) != null) return error.InvalidDirectories;
    const cpu = directories.cpu_arch orelse if (@hasField(m.rules.Environment, "cpu_arch")) environment.cpu_arch else environment.arch;
    const native_destination = if (directories.natives) |path| try a.dupe(u8, path) else try std.fs.path.join(a, &.{ directories.root, "versions", instance, "natives" });
    var native_checks: std.ArrayList(NativeCheck) = .empty;
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
    const jar_id = version.jar orelse version.id;
    const jar_name = try std.fmt.allocPrint(a, "{s}.jar", .{jar_id});
    const client_path = try context.add(.client, &.{ "versions", jar_id, jar_name }, jar);
    const index = version.asset_index orelse return error.MissingAssetIndex;
    try component(index.id);
    const index_name = try std.fmt.allocPrint(a, "{s}.json", .{index.id});
    _ = try context.add(.asset_index, &.{ "assets", "indexes", index_name }, .{ .url = index.url, .sha1 = index.sha1, .size = index.size, .path = null });
    for (version.libraries orelse return error.MissingLibraries) |library| {
        if (!try m.rules.allows(library.rules, environment)) continue;
        const coordinate: ?m.version.MavenCoordinate = if (std.mem.indexOfScalar(u8, library.name, ':') != null or library.downloads == null) try m.version.mavenCoordinate(library.name) else null;
        if (coordinate == null) try m.version.validateId(library.name);
        const downloads = library.downloads;
        if (downloads != null and downloads.?.artifact == null and library.natives.len == 0) return error.MissingLibraryDownload;
        const artifact: ?m.version.Download = if (downloads) |d| d.artifact else try legacyDownload(a, library, coordinate, null);
        if (artifact) |download| {
            const path = download.path orelse if (coordinate) |c| try c.path(a, null) else return error.MissingLibraryPath;
            const classifier = if (coordinate) |c| c.classifier else null;
            const modern_native = if (classifier) |c| std.mem.startsWith(u8, c, "natives-") else false;
            const suitability = if (modern_native) nativeSuitability(library.name, classifier.?, environment.os_name, cpu) else NativeSuitability.compatible;
            if (suitability == .incompatible) return error.IncompatibleNativeArchitecture;
            const installed = try context.add(if (modern_native) .native else .library, &.{ "libraries", path }, download);
            if (modern_native) try native_checks.append(a, .{ .archive_path = installed, .classifier = try a.dupe(u8, classifier.?), .suitability = suitability });
            const key = try context.pathKey(installed);
            const result = try cp_seen.getOrPut(a, key);
            if (!result.found_existing) try cp.append(a, installed);
        }
        for (library.natives) |native| {
            if (!std.mem.eql(u8, native.key, environment.os_name)) continue;
            var classifier = try classifierName(a, native.value, directories.native_arch);
            if (downloads) |d| classifier = try hostClassifier(a, classifier, d.classifiers, cpu);
            const suitability = nativeSuitability(library.name, classifier, environment.os_name, cpu);
            if (suitability == .incompatible) return error.IncompatibleNativeArchitecture;
            const download = if (downloads) |d| blk: {
                for (d.classifiers) |candidate| if (std.mem.eql(u8, candidate.name, classifier)) break :blk candidate.download;
                return error.MissingNativeClassifier;
            } else try legacyDownload(a, library, coordinate, classifier);
            const path = download.path orelse if (coordinate) |c| try c.path(a, classifier) else return error.MissingLibraryPath;
            const installed = try context.add(.native, &.{ "libraries", path }, download);
            try native_checks.append(a, .{ .archive_path = installed, .classifier = try a.dupe(u8, classifier), .suitability = suitability });
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
        const source = try context.add(.asset, &.{ "assets", "objects", hex[0..2], &hex }, .{ .url = url, .sha1 = asset.hash, .size = asset.size, .path = null });
        if ((assets.virtual orelse false) or (assets.map_to_resources orelse false)) try relative(asset.name);
        if (assets.virtual orelse false) try context.materialize(source, try std.fs.path.join(a, &.{ directories.root, "assets", "virtual", index.id, asset.name }), asset.hash, asset.size);
        if (assets.map_to_resources orelse false) try context.materialize(source, try std.fs.path.join(a, &.{ game_directory, "resources", asset.name }), asset.hash, asset.size);
    }
    for (version.logging) |logging| {
        if (!std.mem.eql(u8, logging.name, "client")) continue;
        try component(logging.file.id);
        _ = try context.add(.logging, &.{ "assets", "log_configs", logging.file.id }, .{ .url = logging.file.url, .sha1 = logging.file.sha1, .size = logging.file.size, .path = null });
    }
    const game_assets = if (assets.virtual orelse false) try std.fs.path.join(a, &.{ directories.root, "assets", "virtual", index.id }) else if (assets.map_to_resources orelse false) try std.fs.path.join(a, &.{ game_directory, "resources" }) else try std.fs.path.join(a, &.{ directories.root, "assets" });
    return .{ .value = .{ .files = try context.files.toOwnedSlice(a), .native_extractions = try extractions.toOwnedSlice(a), .classpath = try cp.toOwnedSlice(a), .client_path = client_path, .native_checks = try native_checks.toOwnedSlice(a), .asset_materializations = try context.materializations.toOwnedSlice(a), .game_assets_directory = game_assets }, .arena = arena, .backing = allocator };
}
fn legacyDownload(a: std.mem.Allocator, library: m.version.Library, coordinate: ?m.version.MavenCoordinate, classifier: ?[]const u8) !m.version.Download {
    const path = try (coordinate orelse return error.UnsafeMavenCoordinate).path(a, classifier);
    const repository = library.url orelse "https://libraries.minecraft.net/";
    if (!std.mem.startsWith(u8, repository, "https://") and !std.mem.startsWith(u8, repository, "http://")) return error.InvalidLibraryRepository;
    if (std.mem.indexOfAny(u8, repository, "?#") != null or std.mem.indexOfScalar(u8, repository, 0) != null) return error.InvalidLibraryRepository;
    const separator = if (std.mem.endsWith(u8, repository, "/")) "" else "/";
    return .{ .url = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ repository, separator, path }), .path = path, .sha1 = null, .size = null };
}
const Cpu = enum { x86, x86_64, arm, arm64, unknown };
fn cpuKind(arch: []const u8) Cpu {
    if (std.mem.eql(u8, arch, "aarch64") or std.mem.eql(u8, arch, "arm64")) return .arm64;
    if (std.mem.eql(u8, arch, "x86_64") or std.mem.eql(u8, arch, "amd64") or std.mem.eql(u8, arch, "x64")) return .x86_64;
    if (std.mem.eql(u8, arch, "x86") or std.mem.eql(u8, arch, "i386") or std.mem.eql(u8, arch, "i686")) return .x86;
    if (std.mem.startsWith(u8, arch, "arm")) return .arm;
    return .unknown;
}
/// Classifier evidence is not archive inspection. Generic unknown jars must be
/// inspected by the executor before extraction/launch; compatible means known
/// metadata architecture matches, not that archive contents have been trusted.
pub fn nativeSuitability(library_name: []const u8, classifier: []const u8, os_name: []const u8, cpu_arch: []const u8) NativeSuitability {
    if (std.mem.startsWith(u8, classifier, "natives-linux") and !std.mem.eql(u8, os_name, "linux")) return .incompatible;
    if (std.mem.startsWith(u8, classifier, "natives-windows") and !std.mem.eql(u8, os_name, "windows")) return .incompatible;
    if ((std.mem.startsWith(u8, classifier, "natives-osx") or std.mem.startsWith(u8, classifier, "natives-macos")) and !std.mem.eql(u8, os_name, "osx")) return .incompatible;
    const host = cpuKind(cpu_arch);
    if (host == .unknown) return .inspection_required;
    const x86_family = std.mem.startsWith(u8, library_name, "org.lwjgl.lwjgl:") or std.mem.startsWith(u8, library_name, "net.java.jinput:") or std.mem.startsWith(u8, library_name, "org.lwjgl:");
    const target: Cpu = if (std.mem.endsWith(u8, classifier, "-arm64") or std.mem.endsWith(u8, classifier, "-aarch64")) .arm64 else if (std.mem.endsWith(u8, classifier, "-arm32") or std.mem.endsWith(u8, classifier, "-arm")) .arm else if (std.mem.endsWith(u8, classifier, "-x86_64") or std.mem.endsWith(u8, classifier, "-x64") or std.mem.endsWith(u8, classifier, "-amd64") or (x86_family and std.mem.endsWith(u8, classifier, "-64"))) .x86_64 else if (std.mem.endsWith(u8, classifier, "-x86") or std.mem.endsWith(u8, classifier, "-i386") or (x86_family and std.mem.endsWith(u8, classifier, "-32"))) .x86 else .unknown;
    if (target != .unknown) return if (target == host) .compatible else .incompatible;
    const generic = std.mem.eql(u8, classifier, "natives-linux") or std.mem.eql(u8, classifier, "natives-windows") or std.mem.eql(u8, classifier, "natives-osx") or std.mem.eql(u8, classifier, "natives-macos");
    if (generic and (std.mem.startsWith(u8, library_name, "org.lwjgl.lwjgl:") or std.mem.startsWith(u8, library_name, "net.java.jinput:"))) return if (host == .x86 or host == .x86_64) .compatible else .incompatible;
    if (generic and std.mem.startsWith(u8, library_name, "org.lwjgl:")) return if (host == .x86_64) .compatible else .incompatible;
    return .inspection_required;
}
fn hostClassifier(a: std.mem.Allocator, base: []const u8, classifiers: []const m.version.DownloadEntry, cpu: []const u8) ![]const u8 {
    if (cpuKind(cpu) != .arm64) return base;
    var generic = base;
    for ([_][]const u8{ "-x86_64", "-amd64", "-x64", "-i386", "-x86", "-64", "-32" }) |suffix| {
        if (std.mem.endsWith(u8, base, suffix)) {
            generic = base[0 .. base.len - suffix.len];
            break;
        }
    }
    for ([_][]const u8{ base, generic }, 0..) |stem, i| {
        if (i == 1 and std.mem.eql(u8, stem, base)) break;
        for ([_][]const u8{ "-arm64", "-aarch64" }) |suffix| {
            const candidate = try std.fmt.allocPrint(a, "{s}{s}", .{ stem, suffix });
            for (classifiers) |entry| if (std.mem.eql(u8, entry.name, candidate)) return candidate;
        }
    }
    return base;
}
const Context = struct {
    a: std.mem.Allocator,
    root: []const u8,
    windows: bool,
    files: std.ArrayList(File) = .empty,
    paths: std.StringHashMapUnmanaged(usize) = .empty,
    directory_paths: std.StringHashMapUnmanaged(void) = .empty,
    aliases: std.StringHashMapUnmanaged(usize) = .empty,
    materializations: std.ArrayList(AssetMaterialization) = .empty,
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
        if (self.aliases.contains(key)) return error.PathConflict;
        try self.reservePath(key);
        try self.paths.put(self.a, key, self.files.items.len);
        try self.files.append(self.a, .{ .kind = kind, .url = try self.a.dupe(u8, download.url), .path = path, .sha1 = download.sha1, .size = download.size });
        return path;
    }
    fn reservePath(self: *Context, key: []const u8) !void {
        if (self.directory_paths.contains(key)) return error.PathConflict;
        for (key, 0..) |c, i| {
            if (c != '/' and c != 92) continue;
            if (self.paths.contains(key[0..i]) or self.aliases.contains(key[0..i])) return error.PathConflict;
            try self.directory_paths.put(self.a, key[0..i], {});
        }
    }
    fn materialize(self: *Context, source: []const u8, destination: []const u8, hash: m.Sha1, size: u64) !void {
        const key = try self.pathKey(destination);
        if (self.paths.contains(key)) return error.PathConflict;
        if (self.aliases.get(key)) |i| {
            const old = self.materializations.items[i];
            if (!std.mem.eql(u8, &old.sha1, &hash) or old.size != size) return error.PathConflict;
            return;
        }
        try self.reservePath(key);
        try self.aliases.put(self.a, key, self.materializations.items.len);
        try self.materializations.append(self.a, .{ .source_path = source, .destination = destination, .sha1 = hash, .size = size });
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
test "legacy layouts and jar overrides plan while unresolved inheritance fails" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    var assets = try m.asset_index.parseSlice(a, "{\"objects\":{\"sound/foo\":{\"hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"size\":5},\"sound/bar\":{\"hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"size\":5}}}");
    defer assets.deinit();
    try std.testing.expectError(error.NativeArchRequired, build(a, version.value, assets.value, env, .{ .root = "/g", .natives = "/n" }));
    assets.value.virtual = true;
    var virtual = try build(a, version.value, assets.value, env, dirs);
    defer virtual.deinit();
    try std.testing.expectEqual(@as(usize, 2), virtual.value.asset_materializations.len);
    try std.testing.expectEqualStrings("/game/assets/virtual/a1", virtual.value.game_assets_directory.?);
    assets.value.virtual = null;
    version.value.inherits_from = "parent";
    try std.testing.expectError(error.UnresolvedInheritance, build(a, version.value, assets.value, env, dirs));
    version.value.inherits_from = null;
    version.value.jar = "parent";
    var shared = try build(a, version.value, assets.value, env, dirs);
    defer shared.deinit();
    try std.testing.expectEqualStrings("/game/versions/parent/parent.jar", shared.value.client_path);
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

const legacy_fixture = "{\"id\":\"1.7.10\",\"downloads\":{\"client\":{\"url\":\"https://example/client\"}},\"assetIndex\":{\"id\":\"legacy\",\"url\":\"https://example/index\"},\"libraries\":[{\"name\":\"net.minecraft:launchwrapper:1.12\"},{\"name\":\"net.minecraftforge:forge:1.7.10-10.13.4.1614:universal\",\"url\":\"https://maven.minecraftforge.net\"}]}";
const legacy_assets_fixture = "{\"virtual\":true,\"map_to_resources\":true,\"objects\":{\"sounds/test.ogg\":{\"hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"size\":5}}}";
fn legacyPlanAllocationCase(a: std.mem.Allocator) !void {
    var version = try m.version.parseSlice(a, legacy_fixture);
    defer version.deinit();
    var assets = try m.asset_index.parseSlice(a, legacy_assets_fixture);
    defer assets.deinit();
    var planned = try build(a, version.value, assets.value, env, .{ .root = "/game", .game_directory = "/game/versions/My Forge", .instance_name = "My Forge" });
    defer planned.deinit();
    try std.testing.expectEqual(@as(usize, 2), planned.value.asset_materializations.len);
}

test "legacy Maven URLs and asset aliases share object storage" {
    const a = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(a, legacyPlanAllocationCase, .{});
    var version = try m.version.parseSlice(a, legacy_fixture);
    defer version.deinit();
    var assets = try m.asset_index.parseSlice(a, legacy_assets_fixture);
    defer assets.deinit();
    var planned = try build(a, version.value, assets.value, env, .{ .root = "/game", .instance_name = "My Forge", .game_directory = "/game/versions/My Forge" });
    defer planned.deinit();
    try std.testing.expectEqualStrings("https://libraries.minecraft.net/net/minecraft/launchwrapper/1.12/launchwrapper-1.12.jar", planned.value.files[2].url);
    try std.testing.expectEqualStrings("https://maven.minecraftforge.net/net/minecraftforge/forge/1.7.10-10.13.4.1614/forge-1.7.10-10.13.4.1614-universal.jar", planned.value.files[3].url);
    try std.testing.expectEqualStrings("/game/assets/virtual/legacy/sounds/test.ogg", planned.value.asset_materializations[0].destination);
    try std.testing.expectEqualStrings("/game/versions/My Forge/resources/sounds/test.ogg", planned.value.asset_materializations[1].destination);
    try std.testing.expectEqualStrings(planned.value.asset_materializations[0].source_path, planned.value.asset_materializations[1].source_path);
    try std.testing.expectEqualStrings("/game/assets/virtual/legacy", planned.value.game_assets_directory.?);
    try std.testing.expectEqualStrings("/game/versions/1.7.10/1.7.10.jar", planned.value.client_path);
    var bad = try m.asset_index.parseSlice(a, "{\"map_to_resources\":true,\"objects\":{\"a\":{\"hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"size\":5},\"a/b\":{\"hash\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"size\":5}}}");
    defer bad.deinit();
    try std.testing.expectError(error.PathConflict, build(a, version.value, bad.value, env, dirs));
    var windows = try m.asset_index.parseSlice(a, "{\"virtual\":true,\"objects\":{\"SOUND\":{\"hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"size\":5},\"sound\":{\"hash\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"size\":5}}}");
    defer windows.deinit();
    try std.testing.expectError(error.PathConflict, build(a, version.value, windows.value, .{ .os_name = "windows", .arch = "x86_64" }, dirs));
    assets.value.objects = &.{.{ .name = "../escape", .hash = [_]u8{0} ** 20, .size = 0 }};
    try std.testing.expectError(error.UnsafePath, build(a, version.value, assets.value, env, dirs));
}

test "ARM64 artifact natives and provided classifiers select accurate host archives" {
    const a = std.testing.allocator;
    var assets = try m.asset_index.parseSlice(a, "{\"objects\":{}}");
    defer assets.deinit();
    var version = try m.version.parseSlice(a, "{\"id\":\"modern\",\"downloads\":{\"client\":{\"url\":\"https://example/client\"}},\"assetIndex\":{\"id\":\"modern\",\"url\":\"https://example/index\"},\"libraries\":[{\"name\":\"org.lwjgl:lwjgl:3.3.3:natives-linux-arm64\",\"downloads\":{\"artifact\":{\"url\":\"https://example/arm\",\"path\":\"org/lwjgl/arm.jar\"}}}]}");
    defer version.deinit();
    const arm: m.rules.Environment = .{ .os_name = "linux", .arch = "aarch64" };
    var planned = try build(a, version.value, assets.value, arm, .{ .root = "/game", .cpu_arch = "aarch64" });
    defer planned.deinit();
    try std.testing.expectEqual(@as(usize, 0), planned.value.native_extractions.len);
    try std.testing.expectEqual(@as(usize, 2), planned.value.classpath.len);
    try std.testing.expectEqual(Kind.native, planned.value.files[2].kind);
    try std.testing.expectEqual(NativeSuitability.compatible, planned.value.native_checks[0].suitability);
    try std.testing.expectError(error.IncompatibleNativeArchitecture, build(a, version.value, assets.value, env, .{ .root = "/game", .cpu_arch = "x86_64" }));
    var mapped = try m.version.parseSlice(a, "{\"id\":\"modern\",\"downloads\":{\"client\":{\"url\":\"https://example/client\"}},\"assetIndex\":{\"id\":\"modern\",\"url\":\"https://example/index\"},\"libraries\":[{\"name\":\"org.lwjgl:lwjgl:3.3.3\",\"downloads\":{\"artifact\":{\"url\":\"https://example/library\",\"path\":\"org/lwjgl/library.jar\"},\"classifiers\":{\"natives-linux\":{\"url\":\"https://example/x86\",\"path\":\"org/lwjgl/x86.jar\"},\"natives-linux-arm64\":{\"url\":\"https://example/arm\",\"path\":\"org/lwjgl/arm.jar\"}}},\"natives\":{\"linux\":\"natives-linux\"}}]}");
    defer mapped.deinit();
    var selected = try build(a, mapped.value, assets.value, arm, .{ .root = "/game", .cpu_arch = "aarch64", .instance_name = "My Forge" });
    defer selected.deinit();
    try std.testing.expectEqualStrings("natives-linux-arm64", selected.value.native_checks[0].classifier);
    try std.testing.expectEqualStrings("/game/versions/My Forge/natives", selected.value.native_extractions[0].destination);
    try std.testing.expectEqualStrings("https://example/arm", selected.value.files[3].url);
    const original = mapped.value.libraries.?[0];
    var bitmapped = original;
    bitmapped.natives = &.{.{ .key = "linux", .value = "natives-linux-$" ++ "{arch}" }};
    mapped.value.libraries = &.{bitmapped};
    var from_bits = try build(a, mapped.value, assets.value, arm, .{ .cpu_arch = "aarch64", .native_arch = .bits64 });
    defer from_bits.deinit();
    try std.testing.expectEqualStrings("natives-linux-arm64", from_bits.value.native_checks[0].classifier);
    var lib = original;
    lib.downloads.?.classifiers = lib.downloads.?.classifiers[0..1];
    mapped.value.libraries = &.{lib};
    try std.testing.expectError(error.IncompatibleNativeArchitecture, build(a, mapped.value, assets.value, arm, .{ .cpu_arch = "aarch64" }));
}

test "generic unknown natives require inspection rather than inventing ARM mirrors" {
    try std.testing.expectEqual(NativeSuitability.incompatible, nativeSuitability("org.lwjgl.lwjgl:lwjgl-platform:2.9.1", "natives-linux", "linux", "aarch64"));
    try std.testing.expectEqual(NativeSuitability.incompatible, nativeSuitability("net.java.jinput:jinput-platform:2.0.5", "natives-windows-64", "windows", "arm64"));
    try std.testing.expectEqual(NativeSuitability.compatible, nativeSuitability("org.lwjgl:lwjgl:3.3.3", "natives-linux-arm64", "linux", "aarch64"));
    try std.testing.expectEqual(NativeSuitability.inspection_required, nativeSuitability("example:custom:1", "natives-linux", "linux", "aarch64"));
    try std.testing.expectEqual(NativeSuitability.incompatible, nativeSuitability("example:custom:1", "natives-osx-arm64", "linux", "aarch64"));
}
