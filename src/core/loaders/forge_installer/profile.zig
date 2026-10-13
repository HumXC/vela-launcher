//! Forge spec: https://github.com/MinecraftForge/Installer/blob/2.0/src/main/java/net/minecraftforge/installer/actions/PostProcessors.java
//! Legacy runtime patches: https://github.com/MinecraftForge/FML/blob/1.7.10/src/main/java/cpw/mods/fml/common/asm/transformers/PatchingTransformer.java
const std = @import("std");
const c = @import("../common.zig");
const r = @import("../recipe_types.zig");
const p = @import("processors.zig");
const m = c.m;
const j = c.j;
const Member = r.Member;
const Artifact = r.Artifact;
const digest = r.digest;

pub const Profile = struct {
    raw: std.json.Value,
    child: m.version.Version,
    members: std.ArrayList(Member),
    embedded_coordinate: ?[]const u8,
    embedded_member: ?[]const u8,
    modern: bool,
    flat_legacy: bool,
};

pub fn decode(a: std.mem.Allocator, raw: std.json.Value, base: m.version.Version, bundle: r.Bundle) !Profile {
    var profile_raw = raw;
    var members: std.ArrayList(Member) = .empty;
    var embedded_coordinate: ?[]const u8 = null;
    var embedded_member: ?[]const u8 = null;
    var modern = false;
    if (bundle.installer_sha1 == null) return error.MissingInstallerChecksum;
    try members.append(a, .{ .source = "install_profile.json", .destination = ".loader/profile.json", .sha1 = digest(bundle.profile) });
    if (try j.optional(raw, "versionInfo")) |old| {
        const install = try j.required(raw, "install");
        if (!std.mem.eql(u8, try c.text(try j.required(install, "minecraft")), base.id)) return error.BaseVersionMismatch;
        // Ordinary inherited 1.7.10 uses FML runtime binpatching. Explicitly
        // reject installer-side transforms instead of skipping them.
        if (try j.optional(install, "transforms")) |v| if ((try j.array(v)).len != 0) return error.LegacyForgeTransformsRequired;
        if (try j.optional(raw, "transforms")) |v| if ((try j.array(v)).len != 0) return error.LegacyForgeTransformsRequired;
        profile_raw = old;
        embedded_coordinate = try c.text(try j.required(install, "path"));
        embedded_member = try c.text(try j.required(install, "filePath"));
        try c.relative(embedded_member.?);
    } else {
        modern = true;
        if (!std.mem.eql(u8, try c.text(try j.required(raw, "minecraft")), base.id)) return error.BaseVersionMismatch;
        const member = try c.text(try j.required(raw, "json"));
        const normalized = std.mem.trimStart(u8, member, "/");
        try c.relative(normalized);
        const bytes = bundle.version_json orelse return error.MissingInstallerVersionJson;
        if (bytes.len > 8 * 1024 * 1024) return error.MetadataTooLarge;
        const version_parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always, .parse_numbers = false });
        profile_raw = version_parsed.value;
        try members.append(a, .{ .source = try a.dupe(u8, normalized), .destination = ".loader/version.json", .sha1 = digest(bytes) });
    }
    var child = try m.version.parseValue(a, profile_raw);
    if (child.value.jar) |jar| if (!std.mem.eql(u8, jar, base.id)) return error.BaseVersionMismatch;
    const flat_legacy = child.value.inherits_from == null and embedded_coordinate != null;
    if (flat_legacy) {
        // Early Forge installers flatten vanilla metadata and copy its jar.
        // install.minecraft above binds that operation to this verified base.
        child.value.inherits_from = try a.dupe(u8, base.id);
        child.value.jar = try a.dupe(u8, base.id);
        child.value.libraries = try inheritFlatNatives(a, profile_raw, child.value.libraries orelse &.{}, base.libraries orelse &.{});
    }
    return .{ .raw = profile_raw, .child = child.value, .members = members, .embedded_coordinate = embedded_coordinate, .embedded_member = embedded_member, .modern = modern, .flat_legacy = flat_legacy };
}
// A flattened legacy profile may repeat vanilla native declarations without its
// newer classifier downloads. Validate every repeat before side/OS filtering,
// then retain the complete base descriptor rather than replacing its proofs.
fn inheritFlatNatives(a: std.mem.Allocator, raw: std.json.Value, child: []const m.version.Library, base: []const m.version.Library) ![]const m.version.Library {
    if (child.len > 8192 or base.len > 8192) return error.TooManyLibraries;
    const sources = try j.array(try j.required(raw, "libraries"));
    const out = try a.dupe(m.version.Library, child);
    for (out, sources) |*library, source| {
        var inherited: ?m.version.Library = null;
        for (base) |candidate| {
            if (candidate.natives.len == 0 or !std.mem.eql(u8, candidate.name, library.name)) continue;
            if (inherited != null) return error.LoaderNativeLibraryMismatch;
            inherited = candidate;
        }
        if (library.natives.len == 0 and inherited == null) continue;
        const vanilla = inherited orelse return error.LoaderNativeLibraryRequiresVanillaPlan;
        if (!sameNativeMap(library.natives, vanilla.natives) or
            !sameMetadata(@TypeOf(library.rules), library.rules, vanilla.rules) or
            !sameMetadata(@TypeOf(library.extract_exclude), library.extract_exclude, vanilla.extract_exclude)) return error.LoaderNativeLibraryMismatch;
        for ([_][]const u8{ "clientreq", "serverreq" }) |key| {
            if (try j.optional(source, key)) |required| if (!try j.boolean(required)) return error.LoaderNativeLibraryMismatch;
        }
        // These legacy hashes do not identify a classifier; never discard them
        // as if they proved equivalence with the vanilla classifier downloads.
        if (try j.optional(source, "checksums")) |checksums| if ((try j.array(checksums)).len != 0) return error.LoaderNativeLibraryMismatch;
        const downloads = vanilla.downloads orelse return error.LoaderNativeLibraryRequiresVanillaPlan;
        if (downloads.classifiers.len == 0) return error.LoaderNativeLibraryRequiresVanillaPlan;
        if (library.downloads != null and !sameMetadata(@TypeOf(library.downloads), library.downloads, vanilla.downloads)) return error.LoaderNativeLibraryMismatch;
        const coordinate = try m.version.mavenCoordinate(vanilla.name);
        // Every inherited classifier carries canonical vanilla download authority.
        // An explicit legacy repository must resolve to these same exact URLs.
        for (downloads.classifiers) |entry| {
            const download = entry.download;
            const path = try coordinate.path(a, entry.name);
            if (download.sha1 == null or download.size == null or download.size.? == 0 or download.path == null) return error.LoaderNativeLibraryRequiresVanillaPlan;
            if (!std.mem.eql(u8, path, download.path.?)) return error.LoaderNativeLibraryMismatch;
            const root = library.url orelse vanilla.url orelse "https://libraries.minecraft.net/";
            const url = try std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, root, "/"), path });
            const normalized = try c.normalizeLibraryUrl(a, url);
            try c.trusted(download.url);
            if (!std.mem.eql(u8, normalized, download.url)) return error.LoaderNativeLibraryMismatch;
        }
        library.* = vanilla;
    }
    return out;
}
fn sameNativeMap(left: []const j.StringEntry, right: []const j.StringEntry) bool {
    if (left.len != right.len) return false;
    for (left) |entry| {
        var found = false;
        for (right) |other| {
            if (std.mem.eql(u8, entry.key, other.key) and std.mem.eql(u8, entry.value, other.value)) found = true;
        }
        if (!found) return false;
    }
    return true;
}
// Compare decoded metadata by content, including optional/ordered rule fields;
// std.meta.eql alone compares slice addresses rather than their contents.
fn sameMetadata(comptime T: type, left: T, right: T) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| blk: {
            if (info.size != .slice) @compileError("metadata comparison requires slices");
            if (left.len != right.len) break :blk false;
            for (left, right) |x, y| if (!sameMetadata(info.child, x, y)) break :blk false;
            break :blk true;
        },
        .optional => |info| if (left) |x| if (right) |y| sameMetadata(info.child, x, y) else false else right == null,
        .@"struct" => blk: {
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, field_type| if (!sameMetadata(field_type, @field(left, field_name), @field(right, field_name))) break :blk false;
            break :blk true;
        },
        else => std.meta.eql(left, right),
    };
}
// Only the installer's named artifact is eligible for embedded Maven authority.
// Empty URLs for other coordinates retain their processor-output semantics.
pub fn bindModernEmbedded(a: std.mem.Allocator, raw: std.json.Value, root_libraries: []const m.version.Library, artifacts: []Artifact, processors: []const p.Processor, stage_root: []const u8) !void {
    const value = (try j.optional(raw, "path")) orelse return;
    if (value == .null) return;
    const coordinate = try c.text(value);
    for (artifacts) |*artifact| {
        if (!std.mem.eql(u8, coordinate, artifact.coordinate)) continue;
        const url = artifact.url orelse continue;
        if (url.len != 0) continue;
        // A declared processor output retains its existing generated authority,
        // even when it is the installer's named coordinate.
        const destination = try c.join(a, stage_root, artifact.path);
        var generated = false;
        for (processors) |processor| {
            for (processor.outputs) |output| {
                if (std.mem.eql(u8, output.path, destination)) generated = true;
            }
        }
        if (generated) continue;
        if (artifact.sha1 == null or artifact.size == null) return error.MissingEmbeddedArtifactProof;
        // Root and linked-version declarations must agree, including size.
        // The shared library merge already rejects differing URLs and hashes.
        for (root_libraries) |library| {
            if (!std.mem.eql(u8, coordinate, library.name)) continue;
            const downloads = library.downloads orelse return error.MissingEmbeddedArtifactProof;
            const download = downloads.artifact orelse return error.MissingEmbeddedArtifactProof;
            if (download.sha1 != null and !std.meta.eql(download.sha1, artifact.sha1)) return error.ConflictingArtifact;
            if (download.size != null and !std.meta.eql(download.size, artifact.size)) return error.ConflictingArtifact;
        }
        const parsed = try m.version.mavenCoordinate(coordinate);
        const canonical = try parsed.path(a, null);
        const path = try std.fmt.allocPrint(a, "libraries/{s}", .{canonical});
        try c.relative(path);
        if (!std.mem.eql(u8, path, artifact.path)) return error.LibraryPathMismatch;
        const member = try std.fmt.allocPrint(a, "maven/{s}", .{canonical});
        try c.relative(member);
        artifact.member = member;
    }
}
