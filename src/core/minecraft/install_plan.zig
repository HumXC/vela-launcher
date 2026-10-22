//! Pure installation planning for resolved modern/legacy metadata. No IO.
const std = @import("std");
const m = @import("metadata/root.zig");
pub const Directories = struct {
    root: []const u8 = ".minecraft",
    /// Explicit root-relative client destination; never inferred from source metadata.
    client_relative_path: []const u8,
    natives: ?[]const u8 = null,
    instance_name: ?[]const u8 = null,
    game_directory: ?[]const u8 = null,
};
pub const Kind = enum { client, library, native, asset_index, asset, logging };
pub const File = struct { kind: Kind, url: []const u8, path: []const u8, sha1: ?m.Sha1, size: ?u64 };
pub const ClassicFamily = @import("native_arch.zig").ClassicFamily;
pub const NativeExtraction = struct { archive_path: []const u8, destination: []const u8, exclude: []const []const u8, classic_family: ?ClassicFamily = null };
pub const NativeSuitability = enum { compatible, inspection_required, incompatible };
pub const NativeCheck = struct { archive_path: []const u8, classifier: []const u8, suitability: NativeSuitability, classic_family: ?ClassicFamily = null };
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
    return buildPlan(allocator, version, assets, environment, directories, false);
}

/// Read-only consumers must verify every planned file before using it. Libraries
/// without a remote URL remain in the plan and require a SHA-1 and nonzero size.
/// Download installation continues to use build, which requires remote URLs.
pub fn buildInstalled(allocator: std.mem.Allocator, version: m.version.Version, assets: m.asset_index.AssetIndex, environment: m.rules.Environment, directories: Directories) !m.Owned(Plan) {
    return buildPlan(allocator, version, assets, environment, directories, true);
}

fn buildPlan(allocator: std.mem.Allocator, version: m.version.Version, assets: m.asset_index.AssetIndex, environment: m.rules.Environment, directories: Directories, installed_mode: bool) !m.Owned(Plan) {
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
    const cpu = environment.arch;
    const native_destination = if (directories.natives) |path| try a.dupe(u8, path) else try std.fs.path.join(a, &.{ directories.root, "versions", instance, "natives" });
    var native_checks: std.ArrayList(NativeCheck) = .empty;
    var context: Context = .{ .a = a, .root = directories.root, .windows = std.mem.eql(u8, environment.os_name, "windows"), .installed = installed_mode };
    var cp: std.ArrayList([]const u8) = .empty;
    var cp_seen: std.StringHashMapUnmanaged(void) = .empty;
    var extractions: std.ArrayList(NativeExtraction) = .empty;
    var client: ?m.version.Download = null;
    for (version.downloads) |entry| if (std.mem.eql(u8, entry.name, "client")) {
        client = entry.download;
        break;
    };
    const jar = client orelse return error.MissingClientDownload;
    const client_path = try context.add(.client, &.{directories.client_relative_path}, jar);
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
            if (suitability == .incompatible) {
                // Mojang lists CPU alternatives as separate artifact libraries with
                // OS-only rules. Skip an alternative only if this exact Maven
                // family also provides a native candidate for the selected host.
                if (modern_native and try hostNativeAlternative(version.libraries.?, coordinate.?, environment, cpu)) continue;
                return error.IncompatibleNativeArchitecture;
            }
            const installed = try context.add(if (modern_native) .native else .library, &.{ "libraries", path }, download);
            if (modern_native) try native_checks.append(a, .{ .archive_path = installed, .classifier = try a.dupe(u8, classifier.?), .suitability = suitability, .classic_family = classicFamily(coordinate, classifier.?, environment.os_name) });
            const key = try context.pathKey(installed);
            const result = try cp_seen.getOrPut(a, key);
            if (!result.found_existing) try cp.append(a, installed);
        }
        for (library.natives) |native| {
            if (!std.mem.eql(u8, native.key, environment.os_name)) continue;
            var classifier = try classifierName(a, native.value, cpu);
            if (downloads) |d| classifier = try hostClassifier(a, classifier, d.classifiers, cpu);
            const suitability = nativeSuitability(library.name, classifier, environment.os_name, cpu);
            if (suitability == .incompatible) return error.IncompatibleNativeArchitecture;
            const download = if (downloads) |d| blk: {
                for (d.classifiers) |candidate| if (std.mem.eql(u8, candidate.name, classifier)) break :blk candidate.download;
                return error.MissingNativeClassifier;
            } else try legacyDownload(a, library, coordinate, classifier);
            const path = download.path orelse if (coordinate) |c| try c.path(a, classifier) else return error.MissingLibraryPath;
            const installed = try context.add(.native, &.{ "libraries", path }, download);
            const classic_family = classicFamily(coordinate, classifier, environment.os_name);
            try native_checks.append(a, .{ .archive_path = installed, .classifier = try a.dupe(u8, classifier), .suitability = suitability, .classic_family = classic_family });
            const excludes = library.extract_exclude orelse &.{};
            const copied = try a.alloc([]const u8, excludes.len);
            for (excludes, copied) |exclude, *out| {
                if (std.mem.indexOfScalar(u8, exclude, 0) != null) return error.UnsafePath;
                out.* = try a.dupe(u8, exclude);
            }
            try extractions.append(a, .{ .archive_path = installed, .destination = native_destination, .exclude = copied, .classic_family = classic_family });
            break;
        }
    }
    try cp.append(a, client_path);
    for (assets.objects) |asset| {
        const hex = std.fmt.bytesToHex(asset.hash, .lower);
        const url = try std.fmt.allocPrint(a, "https://resources.download.minecraft.net/{s}/{s}", .{ hex[0..2], &hex });
        const source = try context.add(.asset, &.{ "assets", "objects", hex[0..2], &hex }, .{ .url = url, .sha1 = asset.hash, .size = asset.size, .path = null });
        if ((assets.virtual orelse false) or (assets.map_to_resources orelse false)) try context.relativeTarget(asset.name);
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
// A path or a native-looking filename alone never enables a mixed CPU layout.
fn classicFamily(coordinate: ?m.version.MavenCoordinate, classifier: []const u8, os_name: []const u8) ?ClassicFamily {
    const c = coordinate orelse return null;
    if (!std.mem.eql(u8, c.extension, "jar")) return null;
    if (c.classifier) |declared| if (!std.mem.eql(u8, declared, classifier)) return null;
    const linux = std.mem.eql(u8, os_name, "linux") and std.mem.eql(u8, classifier, "natives-linux");
    const windows = std.mem.eql(u8, os_name, "windows") and std.mem.eql(u8, classifier, "natives-windows");
    if (!linux and !windows) return null;
    if (std.mem.eql(u8, c.group, "org.lwjgl.lwjgl") and std.mem.eql(u8, c.artifact, "lwjgl-platform") and std.mem.startsWith(u8, c.version, "2.")) return if (linux) .lwjgl2_linux else .lwjgl2_windows;
    if (std.mem.eql(u8, c.group, "net.java.jinput") and std.mem.eql(u8, c.artifact, "jinput-platform") and std.mem.eql(u8, c.version, "2.0.5")) return if (linux) .jinput_linux else .jinput_windows;
    return null;
}

fn hostNativeAlternative(libraries: []const m.version.Library, target: m.version.MavenCoordinate, environment: m.rules.Environment, cpu: []const u8) !bool {
    for (libraries) |candidate| {
        if (!try m.rules.allows(candidate.rules, environment)) continue;
        if (candidate.downloads == null or candidate.downloads.?.artifact == null) continue;
        if (std.mem.indexOfScalar(u8, candidate.name, ':') == null) continue;
        const coordinate = try m.version.mavenCoordinate(candidate.name);
        if (!std.mem.eql(u8, coordinate.group, target.group) or
            !std.mem.eql(u8, coordinate.artifact, target.artifact) or
            !std.mem.eql(u8, coordinate.version, target.version) or
            !std.mem.eql(u8, coordinate.extension, target.extension)) continue;
        const classifier = coordinate.classifier orelse continue;
        if (!std.mem.startsWith(u8, classifier, "natives-")) continue;
        if (nativeSuitability(candidate.name, classifier, environment.os_name, cpu) != .incompatible) return true;
    }
    return false;
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
    installed: bool = false,
    files: std.ArrayList(File) = .empty,
    paths: std.StringHashMapUnmanaged(usize) = .empty,
    directory_paths: std.StringHashMapUnmanaged(void) = .empty,
    aliases: std.StringHashMapUnmanaged(usize) = .empty,
    materializations: std.ArrayList(AssetMaterialization) = .empty,
    fn pathKey(self: *Context, path: []const u8) ![]const u8 {
        if (!self.windows) return self.a.dupe(u8, path);
        const view = std.unicode.Utf8View.init(path) catch return error.UnsafePath;
        var codepoints = view.iterator();
        var key: std.ArrayList(u8) = .empty;
        // Full destinations include caller-owned Unicode ancestors. Match
        // Windows ordinal upcasing; supplementary scalars compare unchanged.
        while (codepoints.nextCodepoint()) |cp| {
            const upper: u21 = if (cp <= 0xffff) std.os.windows.toUpperWtf16(@intCast(cp)) else cp;
            var encoded: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(if (upper == 92) '/' else upper, &encoded);
            try key.appendSlice(self.a, encoded[0..len]);
        }
        return key.toOwnedSlice(self.a);
    }
    fn relativeTarget(self: *Context, path: []const u8) !void {
        try relative(path);
        if (!self.windows) return;
        // Restrict metadata children, not caller-owned ancestor directories.
        var codepoints = std.unicode.Utf8View.initUnchecked(path).iterator();
        while (codepoints.nextCodepoint()) |cp| {
            if (cp > 0xff and !(cp >= 0x3400 and cp <= 0x4dbf) and !(cp >= 0x4e00 and cp <= 0x9fff)) return error.UnsupportedWindowsPathCase;
        }
    }
    fn add(self: *Context, kind: Kind, pieces: []const []const u8, download: m.version.Download) ![]const u8 {
        for (pieces) |piece| try self.relativeTarget(piece);
        if (download.path) |path| try self.relativeTarget(path);
        if (download.url.len == 0) {
            if (!self.installed or kind != .library) return error.MissingDownloadUrl;
            if (download.sha1 == null or (download.size orelse 0) == 0) return error.UnverifiableLocalLibrary;
        }
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
    if (!std.unicode.utf8ValidateSlice(path) or path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 92) != null or std.mem.indexOfScalar(u8, path, ':') != null) return error.UnsafePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.UnsafePath;
        var codepoints = std.unicode.Utf8View.initUnchecked(part).iterator();
        while (codepoints.nextCodepoint()) |cp| {
            if (cp < 32 or (cp >= 127 and cp <= 159)) return error.UnsafePath;
            if (cp < 128 and std.mem.indexOfScalar(u8, "<>\"|?*", @intCast(cp)) != null) return error.UnsafePath;
        }
        const end = std.mem.indexOfScalar(u8, part, '.') orelse part.len;
        const base = std.mem.trimEnd(u8, part[0..end], " ");
        for ([_][]const u8{ "con", "prn", "aux", "nul", "clock$", "conin$", "conout$" }) |reserved|
            if (std.ascii.eqlIgnoreCase(base, reserved)) return error.UnsafePath;
        if (base.len >= 4 and (std.ascii.eqlIgnoreCase(base[0..3], "com") or std.ascii.eqlIgnoreCase(base[0..3], "lpt"))) {
            if (base.len == 4 and base[3] >= '0' and base[3] <= '9') return error.UnsafePath;
            if (base.len == 5 and base[3] == 0xc2 and (base[4] == 0xb9 or base[4] == 0xb2 or base[4] == 0xb3)) return error.UnsafePath;
        }
    }
}
fn classifierName(a: std.mem.Allocator, template: []const u8, cpu: []const u8) ![]const u8 {
    const marker = "$" ++ "{arch}";
    var result: std.ArrayList(u8) = .empty;
    var rest = template;
    while (std.mem.indexOf(u8, rest, marker)) |i| {
        try result.appendSlice(a, rest[0..i]);
        try result.appendSlice(a, switch (cpuKind(cpu)) {
            .x86, .arm => "32",
            .x86_64, .arm64 => "64",
            .unknown => return error.NativeArchRequired,
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
const dirs: Directories = .{ .client_relative_path = "versions/v1/v1.jar", .root = "/game", .natives = "/instance/natives" };
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
    try std.testing.expectError(error.NativeArchRequired, build(a, version.value, assets.value, .{ .os_name = "linux", .arch = "" }, .{ .client_relative_path = "versions/v1/v1.jar", .root = "/g", .natives = "/n" }));
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
    try std.testing.expectEqualStrings("/game/versions/v1/v1.jar", shared.value.client_path);
}
test "portable metadata paths reject traversal windows aliases and controls" {
    for ([_][]const u8{ "../escape", "/abs", "C:/abs", "a/../b", "a//b", "CON.txt", "nul", "path.", "path ", "a?b", "a/b/", "a/./b" }) |path| try std.testing.expectError(error.UnsafePath, relative(path));
    try std.testing.expectError(error.UnsafePath, relative(&.{ 'a', 92, 'b' }));
    try std.testing.expectError(error.UnsafePath, relative(&.{ 'a', 0, 'b' }));
    try relative("org/example/lib-1.0.jar");
    try relative("组织/中文版本/lib.jar");
    try component("中文实例");
    for ([_][]const u8{ "a\x1fb", "a\x7fb", "a\xc2\x80b", "a\xc2\x9fb", "\xff", "a:b", "a/../../b", "COM¹", "LPT².dll", "CON .json", "clock$.json", "CONIN$", "CONOUT$" }) |path| try std.testing.expectError(error.UnsafePath, relative(path));
}
test "same path dedup merges checksums but conflicts fail including windows case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: Context = .{ .a = arena.allocator(), .root = "/game", .windows = true };
    const d: m.version.Download = .{ .url = "https://example/a", .path = null, .sha1 = @as([20]u8, @splat(1)), .size = 1 };
    _ = try ctx.add(.library, &.{"libraries/A.jar"}, d);
    _ = try ctx.add(.library, &.{"libraries/a.jar"}, d);
    try std.testing.expectEqual(@as(usize, 1), ctx.files.items.len);
    var bad = d;
    bad.size = 2;
    try std.testing.expectError(error.PathConflict, ctx.add(.library, &.{"libraries/a.jar"}, bad));
    _ = try ctx.add(.library, &.{"libraries/other.jar"}, d);
    try std.testing.expectEqual(@as(usize, 2), ctx.files.items.len);
}
test "Windows Unicode download keys reject hash and ancestor collisions" {
    const download: m.version.Download = .{ .url = "https://example/a", .path = null, .sha1 = @as([20]u8, @splat(1)), .size = 1 };
    var different = download;
    different.sha1 = @as([20]u8, @splat(2));
    for ([_]bool{ false, true }) |reverse| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var ctx: Context = .{ .a = arena.allocator(), .root = "中文目录", .windows = true };
        const first = if (reverse) "libraries/ä.jar" else "libraries/Ä.jar";
        const second = if (reverse) "libraries/Ä.jar" else "libraries/ä.jar";
        const original = try ctx.add(.library, &.{first}, download);
        try std.testing.expectEqualStrings(original, try ctx.add(.library, &.{second}, download));
        try std.testing.expectEqual(@as(usize, 1), ctx.files.items.len);
        try std.testing.expectError(error.PathConflict, ctx.add(.library, &.{second}, different));

        var ancestors: Context = .{ .a = arena.allocator(), .root = "中文目录", .windows = true };
        _ = try ancestors.add(.library, &.{if (reverse) "libraries/ä/child.jar" else "libraries/Ä"}, download);
        try std.testing.expectError(error.PathConflict, ancestors.add(.library, &.{if (reverse) "libraries/Ä" else "libraries/ä/child.jar"}, download));
    }
}

test "Windows Unicode materializations conflict with files and ancestor aliases" {
    const hash: m.Sha1 = @splat(1);
    const other_hash: m.Sha1 = @splat(2);
    const download: m.version.Download = .{ .url = "https://example/a", .path = null, .sha1 = hash, .size = 1 };
    for ([_]bool{ false, true }) |reverse| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var ctx: Context = .{ .a = a, .root = "中文目录", .windows = true };
        const upper = try std.fs.path.join(a, &.{ ctx.root, "resources", "Ä.ogg" });
        const lower = try std.fs.path.join(a, &.{ ctx.root, "resources", "ä.ogg" });
        if (reverse) {
            try ctx.materialize("object", lower, hash, 1);
            try std.testing.expectError(error.PathConflict, ctx.add(.asset, &.{"resources/Ä.ogg"}, download));
        } else {
            _ = try ctx.add(.asset, &.{"resources/Ä.ogg"}, download);
            try std.testing.expectError(error.PathConflict, ctx.materialize("object", lower, hash, 1));
        }
        var aliases: Context = .{ .a = a, .root = ctx.root, .windows = true };
        try aliases.materialize("object", upper, hash, 1);
        try aliases.materialize("object", lower, hash, 1);
        try std.testing.expectEqual(@as(usize, 1), aliases.materializations.items.len);
        try std.testing.expectEqualStrings(upper, aliases.materializations.items[0].destination);
        try std.testing.expectError(error.PathConflict, aliases.materialize("other-object", lower, other_hash, 1));
        const parent = try std.fs.path.join(a, &.{ ctx.root, "resources", "Ä" });
        const child = try std.fs.path.join(a, &.{ ctx.root, "resources", "ä", "child.ogg" });
        try aliases.materialize("object", if (reverse) child else parent, hash, 1);
        try std.testing.expectError(error.PathConflict, aliases.materialize("object", if (reverse) parent else child, hash, 1));
    }
}

test "Windows Unicode metadata targets fail closed without restricting caller roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var windows: Context = .{ .a = arena.allocator(), .root = "中文目录", .windows = true };
    var linux: Context = .{ .a = arena.allocator(), .root = "中文目录", .windows = false };
    // Only metadata-controlled child names have the bounded policy.
    for ([_][]const u8{ "ſ.ogg", "Σ.ogg", "σ.ogg", "ɐ.ogg", "Ɐ.ogg", "😀.ogg" }) |path| {
        try std.testing.expectError(error.UnsupportedWindowsPathCase, windows.relativeTarget(path));
        try std.testing.expectEqualStrings(path, try linux.pathKey(path));
    }
    try std.testing.expectEqualStrings("中文目录/Ä.OGG", try windows.pathKey("中文目录/ä.ogg"));
    try std.testing.expectEqualStrings("中文目录/A.OGG", try windows.pathKey("中文目录\\a.ogg"));
    try std.testing.expectError(error.UnsafePath, windows.pathKey("bad\xff"));
}

test "Windows Unicode ancestors survive full virtual and resources planning" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    const windows: m.rules.Environment = .{ .os_name = "windows", .arch = "x86_64" };
    const assets: m.asset_index.AssetIndex = .{
        .objects = &.{.{ .name = "sound/foo.ogg", .hash = @splat(1), .size = 5 }},
        .virtual = true,
        .map_to_resources = true,
    };
    for ([_][]const u8{ "C:/Users/Νίκος/.minecraft", "C:/Users/Иван/.minecraft", "C:/Users/😀/.minecraft" }) |ancestor| {
        for ([_]bool{ false, true }) |external| {
            const directories: Directories = .{
                .client_relative_path = "versions/v1/v1.jar",
                .root = if (external) "C:/launcher" else ancestor,
                .game_directory = ancestor,
            };
            for ([_]bool{ false, true }) |installed| {
                var plan = try buildPlan(a, version.value, assets, windows, directories, installed);
                defer plan.deinit();
                const expected = try std.fs.path.join(a, &.{ ancestor, "resources", "sound/foo.ogg" });
                defer a.free(expected);
                try std.testing.expectEqualStrings(expected, plan.value.asset_materializations[1].destination);
            }
        }
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var ctx: Context = .{ .a = arena.allocator(), .root = "C:/Users/Νίκος/.minecraft", .windows = true };
    _ = try ctx.add(.library, &.{ "resources", "Ä.ogg" }, .{ .url = "https://example/asset", .sha1 = @splat(1), .size = 5, .path = null });
    // Compare complete roots too: these are the same Windows ordinal prefix.
    try std.testing.expectError(error.PathConflict, ctx.materialize("object", "c:/users/νίκος/.MINECRAFT/resources/ä.ogg", @splat(2), 5));
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
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
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
    var first = try build(a, version.value, assets.value, env, .{ .client_relative_path = "versions/v1/v1.jar" });
    defer first.deinit();
    try std.testing.expectEqualStrings(".minecraft/versions/v1/v1.jar", first.value.client_path);
    try std.testing.expectEqualStrings(".minecraft/versions/v1/natives", first.value.native_extractions[0].destination);
    version.value.id = "v2";
    var second = try build(a, version.value, assets.value, env, .{ .client_relative_path = "versions/v1/v1.jar" });
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
    var planned = try build(a, version.value, assets.value, env, .{ .client_relative_path = "versions/v1/v1.jar", .root = "/game", .game_directory = "/game/versions/My Forge", .instance_name = "My Forge" });
    defer planned.deinit();
    try std.testing.expectEqual(@as(usize, 2), planned.value.asset_materializations.len);
}

test "legacy Maven URLs and asset aliases share object storage" {
    const a = std.testing.allocator;
    try @import("test_allocations").checkAllAllocationFailures(a, legacyPlanAllocationCase, .{});
    var version = try m.version.parseSlice(a, legacy_fixture);
    defer version.deinit();
    var assets = try m.asset_index.parseSlice(a, legacy_assets_fixture);
    defer assets.deinit();
    var planned = try build(a, version.value, assets.value, env, .{ .client_relative_path = "versions/My Forge/My Forge.jar", .root = "/game", .instance_name = "My Forge", .game_directory = "/game/versions/My Forge" });
    defer planned.deinit();
    try std.testing.expectEqualStrings("https://libraries.minecraft.net/net/minecraft/launchwrapper/1.12/launchwrapper-1.12.jar", planned.value.files[2].url);
    try std.testing.expectEqualStrings("https://maven.minecraftforge.net/net/minecraftforge/forge/1.7.10-10.13.4.1614/forge-1.7.10-10.13.4.1614-universal.jar", planned.value.files[3].url);
    try std.testing.expectEqualStrings("/game/assets/virtual/legacy/sounds/test.ogg", planned.value.asset_materializations[0].destination);
    try std.testing.expectEqualStrings("/game/versions/My Forge/resources/sounds/test.ogg", planned.value.asset_materializations[1].destination);
    try std.testing.expectEqualStrings(planned.value.asset_materializations[0].source_path, planned.value.asset_materializations[1].source_path);
    try std.testing.expectEqualStrings("/game/assets/virtual/legacy", planned.value.game_assets_directory.?);
    try std.testing.expectEqualStrings("/game/versions/My Forge/My Forge.jar", planned.value.client_path);
    var bad = try m.asset_index.parseSlice(a, "{\"map_to_resources\":true,\"objects\":{\"a\":{\"hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"size\":5},\"a/b\":{\"hash\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"size\":5}}}");
    defer bad.deinit();
    try std.testing.expectError(error.PathConflict, build(a, version.value, bad.value, env, dirs));
    var windows = try m.asset_index.parseSlice(a, "{\"virtual\":true,\"objects\":{\"SOUND\":{\"hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"size\":5},\"sound\":{\"hash\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"size\":5}}}");
    defer windows.deinit();
    try std.testing.expectError(error.PathConflict, build(a, version.value, windows.value, .{ .os_name = "windows", .arch = "x86_64" }, dirs));
    assets.value.objects = &.{.{ .name = "../escape", .hash = @as([20]u8, @splat(0)), .size = 0 }};
    try std.testing.expectError(error.UnsafePath, build(a, version.value, assets.value, env, dirs));
}
test "Windows Unicode asset aliases fail before virtual or resources materialization" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(a, legacy_fixture);
    defer version.deinit();
    for ([_]bool{ false, true }) |virtual| {
        for ([_]bool{ false, true }) |reverse| {
            const names: [2][]const u8 = if (reverse) .{ "ä.ogg", "Ä.ogg" } else .{ "Ä.ogg", "ä.ogg" };
            const objects = [_]m.asset_index.Asset{
                .{ .name = names[0], .hash = @splat(1), .size = 5 },
                .{ .name = names[1], .hash = @splat(2), .size = 5 },
            };
            const assets: m.asset_index.AssetIndex = .{ .objects = &objects, .virtual = virtual, .map_to_resources = !virtual };
            const directories: Directories = .{ .client_relative_path = "versions/v1/v1.jar", .root = "中文目录", .instance_name = "中文实例", .game_directory = "中文目录/versions/中文实例" };
            const windows: m.rules.Environment = .{ .os_name = "windows", .arch = "x86_64" };
            try std.testing.expectError(error.PathConflict, build(a, version.value, assets, windows, directories));
            try std.testing.expectError(error.PathConflict, buildInstalled(a, version.value, assets, windows, directories));
            var linux = try build(a, version.value, assets, env, directories);
            defer linux.deinit();
            try std.testing.expectEqual(@as(usize, 2), linux.value.asset_materializations.len);
        }
    }
    version.value.id = "中文版本";
    version.value.asset_index.?.id = "资源索引";
    const chinese_assets: m.asset_index.AssetIndex = .{
        .objects = &.{.{ .name = "声音/中文.ogg", .hash = @splat(1), .size = 5 }},
        .virtual = true,
        .map_to_resources = true,
    };
    var chinese = try buildInstalled(a, version.value, chinese_assets, .{ .os_name = "windows", .arch = "x86_64" }, .{
        .client_relative_path = "versions/中文版本/中文版本.jar",
        .root = "中文目录",
        .instance_name = "中文实例",
        .game_directory = "中文目录/versions/中文实例",
    });
    defer chinese.deinit();
    const expected_client = try std.fs.path.join(a, &.{ "中文目录", "versions", "中文版本", "中文版本.jar" });
    defer a.free(expected_client);
    try std.testing.expectEqualStrings(expected_client, chinese.value.client_path);
    try std.testing.expectEqual(@as(usize, 2), chinese.value.asset_materializations.len);
    const expected_resource = try std.fs.path.join(a, &.{ "中文目录/versions/中文实例", "resources", "声音/中文.ogg" });
    defer a.free(expected_resource);
    try std.testing.expectEqualStrings(expected_resource, chinese.value.asset_materializations[1].destination);
}

test "OS-only native variants select a matching CPU without hiding missing architectures" {
    const a = std.testing.allocator;
    var assets = try m.asset_index.parseSlice(a, "{\"objects\":{}}");
    defer assets.deinit();
    const metadata =
        \\{"id":"modern","downloads":{"client":{"url":"https://example/client"}},"assetIndex":{"id":"modern","url":"https://example/index"},"libraries":[
        \\{"name":"org.lwjgl:lwjgl:3.3.3:natives-linux","rules":[{"action":"allow","os":{"name":"linux"}}],"downloads":{"artifact":{"url":"https://example/x64","path":"org/lwjgl/x64.jar"}}},
        \\{"name":"org.lwjgl:lwjgl:3.3.3:natives-linux-arm64","rules":[{"action":"allow","os":{"name":"linux"}}],"downloads":{"artifact":{"url":"https://example/arm","path":"org/lwjgl/arm.jar"}}}]}
    ;
    var version = try m.version.parseSlice(a, metadata);
    defer version.deinit();
    for ([_][]const u8{ "x86_64", "aarch64" }, [_][]const u8{ "natives-linux", "natives-linux-arm64" }) |cpu, classifier| {
        var plan = try build(a, version.value, assets.value, .{ .os_name = "linux", .arch = cpu }, .{ .client_relative_path = "versions/v1/v1.jar", .root = "/game" });
        defer plan.deinit();
        try std.testing.expectEqual(@as(usize, 1), plan.value.native_checks.len);
        try std.testing.expectEqualStrings(classifier, plan.value.native_checks[0].classifier);
        try std.testing.expectEqual(@as(usize, 2), plan.value.classpath.len);
    }
    version.value.libraries = version.value.libraries.?[1..];
    try std.testing.expectError(error.IncompatibleNativeArchitecture, build(a, version.value, assets.value, env, .{ .client_relative_path = "versions/v1/v1.jar", .root = "/game" }));
}

test "ARM64 artifact natives and provided classifiers select accurate host archives" {
    const a = std.testing.allocator;
    var assets = try m.asset_index.parseSlice(a, "{\"objects\":{}}");
    defer assets.deinit();
    var version = try m.version.parseSlice(a, "{\"id\":\"modern\",\"downloads\":{\"client\":{\"url\":\"https://example/client\"}},\"assetIndex\":{\"id\":\"modern\",\"url\":\"https://example/index\"},\"libraries\":[{\"name\":\"org.lwjgl:lwjgl:3.3.3:natives-linux-arm64\",\"downloads\":{\"artifact\":{\"url\":\"https://example/arm\",\"path\":\"org/lwjgl/arm.jar\"}}}]}");
    defer version.deinit();
    const arm: m.rules.Environment = .{ .os_name = "linux", .arch = "aarch64" };
    var planned = try build(a, version.value, assets.value, arm, .{ .client_relative_path = "versions/v1/v1.jar", .root = "/game" });
    defer planned.deinit();
    try std.testing.expectEqual(@as(usize, 0), planned.value.native_extractions.len);
    try std.testing.expectEqual(@as(usize, 2), planned.value.classpath.len);
    try std.testing.expectEqual(Kind.native, planned.value.files[2].kind);
    try std.testing.expectEqual(NativeSuitability.compatible, planned.value.native_checks[0].suitability);
    try std.testing.expectError(error.IncompatibleNativeArchitecture, build(a, version.value, assets.value, env, .{ .client_relative_path = "versions/v1/v1.jar", .root = "/game" }));
    var mapped = try m.version.parseSlice(a, "{\"id\":\"modern\",\"downloads\":{\"client\":{\"url\":\"https://example/client\"}},\"assetIndex\":{\"id\":\"modern\",\"url\":\"https://example/index\"},\"libraries\":[{\"name\":\"org.lwjgl:lwjgl:3.3.3\",\"downloads\":{\"artifact\":{\"url\":\"https://example/library\",\"path\":\"org/lwjgl/library.jar\"},\"classifiers\":{\"natives-linux\":{\"url\":\"https://example/x86\",\"path\":\"org/lwjgl/x86.jar\"},\"natives-linux-arm64\":{\"url\":\"https://example/arm\",\"path\":\"org/lwjgl/arm.jar\"}}},\"natives\":{\"linux\":\"natives-linux\"}}]}");
    defer mapped.deinit();
    var selected = try build(a, mapped.value, assets.value, arm, .{ .client_relative_path = "versions/v1/v1.jar", .root = "/game", .instance_name = "My Forge" });
    defer selected.deinit();
    try std.testing.expectEqualStrings("natives-linux-arm64", selected.value.native_checks[0].classifier);
    try std.testing.expectEqualStrings("/game/versions/My Forge/natives", selected.value.native_extractions[0].destination);
    try std.testing.expectEqualStrings("https://example/arm", selected.value.files[3].url);
    const original = mapped.value.libraries.?[0];
    var bitmapped = original;
    bitmapped.natives = &.{.{ .key = "linux", .value = "natives-linux-$" ++ "{arch}" }};
    mapped.value.libraries = &.{bitmapped};
    var from_bits = try build(a, mapped.value, assets.value, arm, .{ .client_relative_path = "versions/v1/v1.jar" });
    defer from_bits.deinit();
    try std.testing.expectEqualStrings("natives-linux-arm64", from_bits.value.native_checks[0].classifier);
    var lib = original;
    lib.downloads.?.classifiers = lib.downloads.?.classifiers[0..1];
    mapped.value.libraries = &.{lib};
    try std.testing.expectError(error.IncompatibleNativeArchitecture, build(a, mapped.value, assets.value, arm, .{ .client_relative_path = "versions/v1/v1.jar" }));
}

test "generic unknown natives require inspection rather than inventing ARM mirrors" {
    try std.testing.expectEqual(NativeSuitability.incompatible, nativeSuitability("org.lwjgl.lwjgl:lwjgl-platform:2.9.1", "natives-linux", "linux", "aarch64"));
    try std.testing.expectEqual(NativeSuitability.incompatible, nativeSuitability("net.java.jinput:jinput-platform:2.0.5", "natives-windows-64", "windows", "arm64"));
    try std.testing.expectEqual(NativeSuitability.compatible, nativeSuitability("org.lwjgl:lwjgl:3.3.3", "natives-linux-arm64", "linux", "aarch64"));
    try std.testing.expectEqual(NativeSuitability.inspection_required, nativeSuitability("example:custom:1", "natives-linux", "linux", "aarch64"));
    try std.testing.expectEqual(NativeSuitability.incompatible, nativeSuitability("example:custom:1", "natives-osx-arm64", "linux", "aarch64"));
}

test "authentic classic metadata binds mixed CPU families across platforms and excludes impersonated coordinates" {
    const a = std.testing.allocator;
    var assets = try m.asset_index.parseSlice(a, "{\"objects\":{}}");
    defer assets.deinit();
    const fixtures = [_][]const u8{
        @embedFile("../launch_fixtures/vanilla_1_7_10_version.json"),
        @embedFile("../launch_fixtures/vanilla_1_12_2_version.json"),
    };
    for (fixtures, 0..) |bytes, fixture_index| {
        var version = try m.version.parseSlice(a, bytes);
        defer version.deinit();
        for ([_][]const u8{ "linux", "windows", "osx" }) |os| {
            var plan = try build(a, version.value, assets.value, .{ .os_name = os, .arch = "x86_64" }, .{ .client_relative_path = "versions/v1/v1.jar", .root = "/classic" });
            defer plan.deinit();
            try std.testing.expect(plan.value.native_checks.len >= 2);
            try std.testing.expectEqual(plan.value.native_checks.len, plan.value.native_extractions.len);
            var seen_lwjgl = false;
            var seen_jinput = false;
            var classic_count: usize = 0;
            for (plan.value.native_checks) |check| {
                const is_lwjgl = std.mem.indexOf(u8, check.archive_path, "/org/lwjgl/lwjgl/lwjgl-platform/") != null;
                const is_jinput = std.mem.indexOf(u8, check.archive_path, "/net/java/jinput/jinput-platform/2.0.5/") != null;
                if (!is_lwjgl and !is_jinput) {
                    try std.testing.expectEqual(@as(?ClassicFamily, null), check.classic_family);
                    continue;
                }
                classic_count += 1;
                seen_lwjgl = seen_lwjgl or is_lwjgl;
                seen_jinput = seen_jinput or is_jinput;
                const expected: ?ClassicFamily = if (std.mem.eql(u8, os, "osx")) null else if (std.mem.eql(u8, os, "linux")) (if (is_lwjgl) .lwjgl2_linux else .jinput_linux) else (if (is_lwjgl) .lwjgl2_windows else .jinput_windows);
                try std.testing.expectEqual(expected, check.classic_family);
                for (plan.value.native_extractions) |task| {
                    if (std.mem.eql(u8, task.archive_path, check.archive_path)) try std.testing.expectEqual(expected, task.classic_family);
                }
                if (fixture_index == 1 and is_lwjgl) {
                    const selected = if (std.mem.eql(u8, os, "osx")) "/2.9.2-nightly-20140822/" else "/2.9.4-nightly-20150209/";
                    try std.testing.expect(std.mem.indexOf(u8, check.archive_path, selected) != null);
                }
            }
            try std.testing.expect(seen_lwjgl and seen_jinput);
            try std.testing.expectEqual(@as(usize, 2), classic_count);
        }
        const libraries = try a.dupe(m.version.Library, version.value.libraries.?);
        defer a.free(libraries);
        for (libraries) |*library| {
            if (std.mem.eql(u8, library.name, "net.java.jinput:jinput-platform:2.0.5")) library.name = "net.java.jinput.imitator:jinput-platform:2.0.5";
        }
        var spoofed = version.value;
        spoofed.libraries = libraries;
        var untrusted_family = try build(a, spoofed, assets.value, .{ .os_name = "linux", .arch = "x86_64" }, .{ .client_relative_path = "versions/v1/v1.jar", .root = "/classic" });
        defer untrusted_family.deinit();
        var found_impostor = false;
        for (untrusted_family.value.native_checks) |check| {
            if (std.mem.indexOf(u8, check.archive_path, "/net/java/jinput/jinput-platform/2.0.5/") != null) {
                found_impostor = true;
                try std.testing.expectEqual(@as(?ClassicFamily, null), check.classic_family);
            }
        }
        try std.testing.expect(found_impostor);
    }
}

test "installed planning retains verified local libraries while download planning stays strict" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    var assets = try m.asset_index.parseSlice(a, "{\"objects\":{}}");
    defer assets.deinit();
    var libraries = [_]m.version.Library{version.value.libraries.?[0]};
    libraries[0].natives = &.{};
    libraries[0].name = "fixture:embedded:1";
    libraries[0].downloads.?.artifact.?.url = "";
    libraries[0].downloads.?.artifact.?.sha1 = @as([20]u8, @splat(1));
    version.value.libraries = &libraries;
    try std.testing.expectError(error.MissingDownloadUrl, build(a, version.value, assets.value, env, dirs));
    {
        var plan = try buildInstalled(a, version.value, assets.value, env, dirs);
        defer plan.deinit();
        try std.testing.expectEqual(@as(usize, 4), plan.value.files.len);
        try std.testing.expectEqualStrings("/game/libraries/org/base.jar", plan.value.classpath[0]);
        try std.testing.expectEqualStrings("", plan.value.files[2].url);
        try std.testing.expectEqual(@as(?u64, 20), plan.value.files[2].size);
        try std.testing.expectEqualSlices(u8, &@as([20]u8, @splat(1)), &plan.value.files[2].sha1.?);
    }
    libraries[0].downloads.?.artifact.?.sha1 = null;
    try std.testing.expectError(error.UnverifiableLocalLibrary, buildInstalled(a, version.value, assets.value, env, dirs));
    libraries[0].downloads.?.artifact.?.sha1 = @as([20]u8, @splat(1));
    libraries[0].downloads.?.artifact.?.size = null;
    try std.testing.expectError(error.UnverifiableLocalLibrary, buildInstalled(a, version.value, assets.value, env, dirs));
    libraries[0].downloads.?.artifact.?.size = 0;
    try std.testing.expectError(error.UnverifiableLocalLibrary, buildInstalled(a, version.value, assets.value, env, dirs));
    libraries[0].downloads.?.artifact.?.size = 20;
    libraries[0].name = "org.lwjgl:lwjgl:3:natives-linux";
    try std.testing.expectError(error.MissingDownloadUrl, buildInstalled(a, version.value, assets.value, env, dirs));
    libraries[0].name = "fixture:embedded:1";
    libraries[0].downloads.?.artifact.?.path = "../outside.jar";
    try std.testing.expectError(error.UnsafePath, buildInstalled(a, version.value, assets.value, env, dirs));
}

test "path contract Unicode version instance asset index and metadata paths" {
    const a = std.testing.allocator;
    var version = try m.version.parseSlice(a, fixture);
    defer version.deinit();
    version.value.id = "中文版本";
    version.value.asset_index.?.id = "资源索引";
    var assets = try m.asset_index.parseSlice(a, "{\"objects\":{}}");
    defer assets.deinit();
    var plan = try buildInstalled(a, version.value, assets.value, env, .{ .client_relative_path = "versions/中文版本/中文版本.jar", .root = "game", .instance_name = "中文实例" });
    defer plan.deinit();
    const client = try std.fs.path.join(a, &.{ "game", "versions", "中文版本", "中文版本.jar" });
    defer a.free(client);
    const natives = try std.fs.path.join(a, &.{ "game", "versions", "中文实例", "natives" });
    defer a.free(natives);
    try std.testing.expectEqualStrings(client, plan.value.client_path);
    try std.testing.expectEqualStrings(natives, plan.value.native_extractions[0].destination);
    version.value.id = "bad\xc2\x80id";
    try std.testing.expectError(error.UnsafePath, buildInstalled(a, version.value, assets.value, env, dirs));
}
