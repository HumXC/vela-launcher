//! Fabric inherited version-profile recipes.
const std = @import("std");
const c = @import("../loaders/common.zig");
const r = @import("../loaders/recipe_types.zig");
const m = c.m;

pub fn build(a: std.mem.Allocator, base: m.version.Version, raw: std.json.Value, bundle: r.Bundle, options: r.Options) !r.Prepared {
    _ = bundle;
    const child = try m.version.parseValue(a, raw);
    const version = try r.mergeVersion(a, child.value, base, options.instance_name);
    var artifacts: std.ArrayList(r.Artifact) = .empty;
    try r.libraries(a, raw, child.value.libraries orelse &.{}, options, false, &artifacts);
    // Profile installation only writes metadata and artifacts; no installer JVM is run.
    return .{ .version = version, .artifacts = try artifacts.toOwnedSlice(a), .installer_java_major = 0 };
}
