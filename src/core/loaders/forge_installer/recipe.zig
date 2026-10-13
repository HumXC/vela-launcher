//! Shared legacy and modern Forge/NeoForge installer-format composition.
const std = @import("std");
const c = @import("../common.zig");
const r = @import("../recipe_types.zig");
const p = @import("processors.zig");
const profile = @import("profile.zig");
const m = c.m;
const j = c.j;
const Artifact = r.Artifact;

pub fn build(a: std.mem.Allocator, base: m.version.Version, raw: std.json.Value, bundle: r.Bundle, options: r.Options) !r.Prepared {
    const parsed = try profile.decode(a, raw, base, bundle);
    const profile_raw = parsed.raw;
    const flat_legacy = parsed.flat_legacy;
    const embedded_coordinate = parsed.embedded_coordinate;
    const embedded_member = parsed.embedded_member;
    const modern = parsed.modern;
    var members = parsed.members;
    const merged = try r.mergeVersion(a, parsed.child, base, options.instance_name);
    var artifacts: std.ArrayList(Artifact) = .empty;
    try r.libraries(a, profile_raw, parsed.child.libraries orelse &.{}, options, flat_legacy, &artifacts);
    if (embedded_coordinate) |coordinate| {
        var found = false;
        for (artifacts.items) |*artifact| if (std.mem.eql(u8, coordinate, artifact.coordinate)) {
            artifact.url = null;
            artifact.member = try a.dupe(u8, embedded_member.?);
            found = true;
        };
        if (!found) return error.MissingUniversalLibrary;
    }
    var root_libraries: []const m.version.Library = &.{};
    if (modern) {
        // Reuse structured decoder for installer library descriptors.
        var object: std.json.ObjectMap = .empty;
        try object.put(a, "id", .{ .string = "installer-libraries" });
        try object.put(a, "libraries", try j.required(raw, "libraries"));
        const holder: std.json.Value = .{ .object = object };
        const install_libraries = try m.version.parseValue(a, holder);
        root_libraries = install_libraries.value.libraries orelse &.{};
        try r.libraries(a, holder, root_libraries, options, false, &artifacts);
    }
    var processors: []const p.Processor = &.{};
    if (modern) {
        processors = try p.build(a, raw, &artifacts, options.stage_root, base.id, options.side, &members);
        try profile.bindModernEmbedded(a, raw, root_libraries, artifacts.items, processors, options.stage_root);
    }
    const game_java = m.version.requiredJavaMajor(merged);
    return .{
        .version = merged,
        .artifacts = try artifacts.toOwnedSlice(a),
        .members = try members.toOwnedSlice(a),
        .processors = processors,
        .installer_java_major = if (modern) @max(@as(u64, 8), game_java) else 8,
    };
}
