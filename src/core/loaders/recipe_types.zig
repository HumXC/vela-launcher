//! Canonical recipe contracts and shared Maven/profile merge helpers.
const std = @import("std");
const c = @import("common.zig");
const l = @import("types.zig");
const p = @import("forge_installer/processors.zig");
const m = c.m;
const j = c.j;
/// producer indexes the side-filtered processor plan; generated files have no download URL.
pub const Artifact = struct { coordinate: []const u8, path: []const u8, url: ?[]const u8, sha1: ?m.Sha1, size: ?u64, member: ?[]const u8 = null, producer: ?usize = null };
pub const Member = struct { source: []const u8, destination: []const u8, sha1: ?m.Sha1 = null };
pub const Bundle = struct {
    source_url: []const u8,
    /// Official JSON profile, or install_profile.json extracted from verified ZIP.
    profile: []const u8,
    /// Required for modern Forge/NeoForge's referenced json member.
    version_json: ?[]const u8 = null,
    /// Required for installers. Obtained from official .sha1 metadata, never user input.
    installer_sha1: ?m.Sha1 = null,
};
pub const Options = struct { instance_name: []const u8, stage_root: []const u8, environment: m.rules.Environment, side: c.Side = .client };
pub const Recipe = struct {
    selection: l.Selection,
    instance_name: []const u8,
    stage_root: []const u8,
    version: m.version.Version,
    source_url: []const u8,
    source_sha1: m.Sha1,
    installer_sha1: ?m.Sha1,
    artifacts: []const Artifact,
    members: []const Member,
    processors: []const p.Processor,
    game_java_major: u64,
    installer_java_major: u64,
};
pub const JavaRequirements = struct { runtime_major: u64, installer_major: u64 };

pub fn javaRequirements(recipe: Recipe) JavaRequirements {
    return .{ .runtime_major = recipe.game_java_major, .installer_major = recipe.installer_java_major };
}

/// Resolve the loader profile against the verified vanilla base.
pub fn mergeVersion(a: std.mem.Allocator, child: m.version.Version, base: m.version.Version, instance_name: []const u8) !m.version.Version {
    if (child.jar) |jar| if (!std.mem.eql(u8, jar, base.id)) return error.BaseVersionMismatch;
    if (!std.mem.eql(u8, child.inherits_from orelse return error.LegacyForgeVanillaCopyRequired, base.id)) return error.BaseVersionMismatch;
    var merged = try m.version.inheritance.resolve(a, child.id, &.{ child, base }, .{});
    merged.value.id = try a.dupe(u8, instance_name);
    return merged.value;
}

/// Provider output whose allocations belong to the recipe arena.
pub const Prepared = struct {
    version: m.version.Version,
    artifacts: []const Artifact,
    members: []const Member = &.{},
    processors: []const p.Processor = &.{},
    installer_java_major: u64,
};

pub fn digest(bytes: []const u8) m.Sha1 {
    var result: m.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &result, .{});
    return result;
}
pub fn libraries(a: std.mem.Allocator, raw: std.json.Value, decoded: []const m.version.Library, options: Options, inherited_natives: bool, out: *std.ArrayList(Artifact)) !void {
    const raw_libraries = try j.array(try j.required(raw, "libraries"));
    for (decoded, 0..) |library, index| {
        const source = raw_libraries[index];
        if (try j.optional(source, if (options.side == .client) "clientreq" else "serverreq")) |required| if (!try j.boolean(required)) continue;
        if (!try m.rules.allows(library.rules, options.environment)) continue;
        if (library.natives.len != 0) {
            if (inherited_natives) continue; // Already reconciled against verified vanilla metadata.
            return error.LoaderNativeLibraryRequiresVanillaPlan;
        }
        const coordinate = try m.version.mavenCoordinate(library.name);
        const expected_path = try coordinate.path(a, null);
        const path = try std.fmt.allocPrint(a, "libraries/{s}", .{expected_path});
        try c.relative(path);
        var url: []const u8 = undefined;
        var hash: ?m.Sha1 = null;
        var size: ?u64 = null;
        if (library.downloads) |downloads| {
            const download = downloads.artifact orelse return error.MissingLibraryDownload;
            if (download.path) |download_path| if (!std.mem.eql(u8, download_path, expected_path)) return error.LibraryPathMismatch;
            url = download.url;
            hash = download.sha1;
            size = download.size;
        } else {
            const root = library.url orelse "https://libraries.minecraft.net/";
            url = try std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, root, "/"), expected_path });
            if (try j.optional(source, "checksums")) |checksums| {
                const list = try j.array(checksums);
                if (list.len > 0) hash = try c.sha1(try c.text(list[0]));
            }
        }
        if (url.len != 0) {
            url = try c.normalizeLibraryUrl(a, url);
            try c.trusted(url);
        }
        try mergeArtifact(a, out, .{ .coordinate = try a.dupe(u8, library.name), .path = path, .url = try a.dupe(u8, url), .sha1 = hash, .size = size });
    }
}
/// Missing proof can be enriched; two present declarations must agree.
pub fn mergeArtifact(a: std.mem.Allocator, out: *std.ArrayList(Artifact), incoming: Artifact) !void {
    for (out.items) |*old| {
        if (!std.mem.eql(u8, old.path, incoming.path)) continue;
        if (old.url != null and incoming.url != null and !std.mem.eql(u8, old.url.?, incoming.url.?)) return error.ConflictingArtifact;
        if (old.sha1 != null and incoming.sha1 != null and !std.meta.eql(old.sha1.?, incoming.sha1.?)) return error.ConflictingArtifact;
        if (old.size != null and incoming.size != null and old.size.? != incoming.size.?) return error.ConflictingArtifact;
        if (old.member != null and incoming.member != null and !std.mem.eql(u8, old.member.?, incoming.member.?)) return error.ConflictingArtifact;
        if (old.producer != null and incoming.producer != null and old.producer.? != incoming.producer.?) return error.ConflictingArtifact;
        if ((old.member != null or incoming.member != null) and (old.producer != null or incoming.producer != null)) return error.ConflictingArtifact;
        old.url = old.url orelse incoming.url;
        old.sha1 = old.sha1 orelse incoming.sha1;
        old.size = old.size orelse incoming.size;
        old.member = old.member orelse incoming.member;
        old.producer = old.producer orelse incoming.producer;
        return;
    }
    try out.append(a, incoming);
}
