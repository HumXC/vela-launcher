//! Version documents only: no inheritance resolution, IO or host filtering.
const std = @import("std");
const j = @import("json.zig");
const own = @import("owned.zig");
pub const rules = @import("rules.zig");
pub const Download = struct { url: []const u8, sha1: ?j.Sha1, size: ?u64, path: ?[]const u8 };
pub const DownloadEntry = struct { name: []const u8, download: Download };
pub const LibraryDownloads = struct { artifact: ?Download, classifiers: []const DownloadEntry };
pub const Library = struct {
    name: []const u8,
    url: ?[]const u8,
    downloads: ?LibraryDownloads,
    rules: ?[]const rules.Rule,
    natives: []const j.StringEntry,
    extract_exclude: ?[]const []const u8,
};
pub const Argument = union(enum) {
    literal: []const u8,
    conditional: struct { rules: []const rules.Rule, values: []const []const u8 },
};
pub const Arguments = struct { game: ?[]const Argument, jvm: ?[]const Argument };
pub const AssetIndexReference = struct { id: []const u8, url: []const u8, sha1: ?j.Sha1, size: ?u64, total_size: ?u64 };
pub const JavaVersion = struct { component: []const u8, major_version: u64 };
pub const Logging = struct { name: []const u8, argument: []const u8, kind: []const u8, file: struct { id: []const u8, url: []const u8, sha1: ?j.Sha1, size: ?u64 } };
pub const Version = struct {
    id: []const u8,
    kind: ?[]const u8,
    main_class: ?[]const u8,
    inherits_from: ?[]const u8,
    jar: ?[]const u8,
    time: ?[]const u8,
    release_time: ?[]const u8,
    minimum_launcher_version: ?u64,
    compliance_level: ?u64,
    java_version: ?JavaVersion,
    downloads: []const DownloadEntry,
    libraries: ?[]const Library,
    arguments: ?Arguments,
    minecraft_arguments: ?[]const u8,
    asset_index: ?AssetIndexReference,
    assets: ?[]const u8,
    logging: []const Logging,
};
pub fn parseSlice(a: j.A, bytes: []const u8) !own.Owned(Version) {
    return own.fromSlice(Version, a, bytes, decode);
}
pub fn parseValue(a: j.A, v: j.V) !own.Owned(Version) {
    return own.fromValue(Version, a, v, decode);
}
fn download(a: j.A, v: j.V) !Download {
    return .{ .url = try j.text(a, v, "url"), .sha1 = try j.maybeSha1(v, "sha1"), .size = try j.maybeUint(v, "size"), .path = try j.maybeText(a, v, "path") };
}
fn downloadMap(a: j.A, v: j.V) ![]const DownloadEntry {
    const map = try j.object(v);
    const out = try a.alloc(DownloadEntry, map.count());
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) out[i] = .{ .name = try a.dupe(u8, e.key_ptr.*), .download = try download(a, e.value_ptr.*) };
    return out;
}
fn library(a: j.A, v: j.V) !Library {
    var downloads: ?LibraryDownloads = null;
    if (try j.optional(v, "downloads")) |d| downloads = .{ .artifact = if (try j.optional(d, "artifact")) |x| try download(a, x) else null, .classifiers = if (try j.optional(d, "classifiers")) |x| try downloadMap(a, x) else &.{} };
    var exclude: ?[]const []const u8 = null;
    if (try j.optional(v, "extract")) |e| if (try j.optional(e, "exclude")) |x| {
        exclude = try j.strings(a, x);
    };
    return .{ .name = try j.text(a, v, "name"), .url = try j.maybeText(a, v, "url"), .downloads = downloads, .rules = if (try j.optional(v, "rules")) |r| try rules.decodeList(a, r) else null, .natives = if (try j.optional(v, "natives")) |n| try j.stringMap(a, n) else &.{}, .extract_exclude = exclude };
}
fn argument(a: j.A, v: j.V) !Argument {
    if (v == .string) return .{ .literal = try j.string(a, v) };
    const value = try j.required(v, "value");
    const values = if (value == .string) blk: {
        const result = try a.alloc([]const u8, 1);
        result[0] = try j.string(a, value);
        break :blk result;
    } else try j.strings(a, value);
    return .{ .conditional = .{ .rules = try rules.decodeList(a, try j.required(v, "rules")), .values = values } };
}
fn logging(a: j.A, v: j.V) ![]const Logging {
    const map = try j.object(v);
    const out = try a.alloc(Logging, map.count());
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        const file = try j.required(e.value_ptr.*, "file");
        out[i] = .{ .name = try a.dupe(u8, e.key_ptr.*), .argument = try j.text(a, e.value_ptr.*, "argument"), .kind = try j.text(a, e.value_ptr.*, "type"), .file = .{ .id = try j.text(a, file, "id"), .url = try j.text(a, file, "url"), .sha1 = try j.maybeSha1(file, "sha1"), .size = try j.maybeUint(file, "size") } };
    }
    return out;
}
fn decode(a: j.A, v: j.V) !Version {
    var java: ?JavaVersion = null;
    if (try j.optional(v, "javaVersion")) |x| {
        const major = try j.uint(try j.required(x, "majorVersion"));
        if (major == 0) return error.InvalidJavaVersion;
        java = .{ .component = try j.text(a, x, "component"), .major_version = major };
    }
    var args: ?Arguments = null;
    if (try j.optional(v, "arguments")) |x| args = .{ .game = if (try j.optional(x, "game")) |g| try j.list(Argument, a, g, argument) else null, .jvm = if (try j.optional(x, "jvm")) |g| try j.list(Argument, a, g, argument) else null };
    var index: ?AssetIndexReference = null;
    if (try j.optional(v, "assetIndex")) |x| index = .{ .id = try j.text(a, x, "id"), .url = try j.text(a, x, "url"), .sha1 = try j.maybeSha1(x, "sha1"), .size = try j.maybeUint(x, "size"), .total_size = try j.maybeUint(x, "totalSize") };
    return .{
        .id = try j.text(a, v, "id"),
        .kind = try j.maybeText(a, v, "type"),
        .main_class = try j.maybeText(a, v, "mainClass"),
        .inherits_from = try j.maybeText(a, v, "inheritsFrom"),
        .jar = try j.maybeText(a, v, "jar"),
        .time = try j.maybeText(a, v, "time"),
        .release_time = try j.maybeText(a, v, "releaseTime"),
        .minimum_launcher_version = try j.maybeUint(v, "minimumLauncherVersion"),
        .compliance_level = try j.maybeUint(v, "complianceLevel"),
        .java_version = java,
        .downloads = if (try j.optional(v, "downloads")) |x| try downloadMap(a, x) else &.{},
        .libraries = if (try j.optional(v, "libraries")) |x| try j.list(Library, a, x, library) else null,
        .arguments = args,
        .minecraft_arguments = try j.maybeText(a, v, "minecraftArguments"),
        .asset_index = index,
        .assets = try j.maybeText(a, v, "assets"),
        .logging = if (try j.optional(v, "logging")) |x| try logging(a, x) else &.{},
    };
}
