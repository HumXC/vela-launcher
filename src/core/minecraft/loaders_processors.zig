const std = @import("std");
const c = @import("loaders_common.zig");
const r = @import("loaders_recipe.zig");
const j = c.j;
pub const Output = struct { path: []const u8, sha1: c.m.Sha1 };
pub const Processor = struct { jar: []const u8, classpath: []const []const u8, args: []const []const u8, outputs: []const Output };
const Data = std.StringHashMap([]const u8);
pub fn build(a: std.mem.Allocator, raw: std.json.Value, artifacts: []const r.Artifact, root: []const u8, base: []const u8, side: c.Side, members: *std.ArrayList(r.Member)) ![]const Processor {
    var data = Data.init(a);
    try data.put("SIDE", @tagName(side));
    try data.put("ROOT", root);
    try data.put("MINECRAFT_VERSION", base);
    try data.put("LIBRARY_DIR", try c.join(a, root, "libraries"));
    try data.put("INSTALLER", try c.join(a, root, ".loader/installer.jar"));
    try data.put("MINECRAFT_JAR", try std.fmt.allocPrint(a, "{s}/versions/{s}/{s}.jar", .{ root, base, base }));
    if (try j.optional(raw, "data")) |values| {
        var it = (try j.object(values)).iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            try c.id(key);
            if (data.contains(key)) return error.ReservedProcessorData;
            const value = try c.text(try j.required(entry.value_ptr.*, @tagName(side)));
            if (value.len == 0) return error.EmptyProcessorData;
            var resolved: []const u8 = undefined;
            if (value[0] == '[' and value[value.len - 1] == ']') {
                resolved = try library(a, root, value[1 .. value.len - 1]);
            } else if (value[0] == '\'' and value[value.len - 1] == '\'' and value.len >= 2) {
                resolved = try a.dupe(u8, value[1 .. value.len - 1]);
                if (std.mem.indexOfAny(u8, resolved, "{}\x00") != null) return error.InvalidProcessorLiteral;
            } else {
                const member = if (value[0] == '/') value[1..] else value;
                try c.relative(member);
                const destination = try std.fmt.allocPrint(a, ".loader/data/{s}", .{member});
                resolved = try c.join(a, root, destination);
                try members.append(a, .{ .source = try a.dupe(u8, member), .destination = destination });
            }
            try data.put(try a.dupe(u8, key), resolved);
        }
    }
    var result: std.ArrayList(Processor) = .empty;
    const values = if (try j.optional(raw, "processors")) |v| try j.array(v) else &.{};
    if (values.len > 256 or data.count() > 1024) return error.TooManyProcessors;
    for (values) |value| {
        if (try j.optional(value, "sides")) |sides| {
            var applies = false;
            for (try j.array(sides)) |s| {
                const name = try c.text(s);
                if (!std.mem.eql(u8, name, "client") and !std.mem.eql(u8, name, "server")) return error.InvalidProcessorSide;
                if (std.mem.eql(u8, name, @tagName(side))) applies = true;
            }
            if (!applies) continue;
        }
        const coordinate = try c.text(try j.required(value, "jar"));
        // The executable must itself belong to official Forge/NeoForge tooling,
        // not merely be an arbitrary third-party library mentioned by a profile.
        if (!std.mem.startsWith(u8, coordinate, "net.minecraftforge:") and !std.mem.startsWith(u8, coordinate, "net.neoforged:") and !std.mem.startsWith(u8, coordinate, "net.neoforged.installertools:")) return error.UntrustedProcessor;
        const jar = try listed(a, root, coordinate, artifacts);
        var classpath: std.ArrayList([]const u8) = .empty;
        try classpath.append(a, jar);
        for (try j.array(try j.required(value, "classpath"))) |cp| try classpath.append(a, try listed(a, root, try c.text(cp), artifacts));
        var args: std.ArrayList([]const u8) = .empty;
        for (try j.array(try j.required(value, "args"))) |arg| try args.append(a, try expand(a, try c.text(arg), data, root));
        if (args.items.len > 4096 or classpath.items.len > 1024) return error.ProcessorTooLarge;
        var outputs: std.ArrayList(Output) = .empty;
        if (try j.optional(value, "outputs")) |out| {
            var it = (try j.object(out)).iterator();
            while (it.next()) |entry| {
                const path = try expand(a, entry.key_ptr.*, data, root);
                try underRoot(root, path);
                const hash = try c.sha1(try expand(a, try c.text(entry.value_ptr.*), data, root));
                try outputs.append(a, .{ .path = path, .sha1 = hash });
            }
        }
        try result.append(a, .{ .jar = jar, .classpath = try classpath.toOwnedSlice(a), .args = try args.toOwnedSlice(a), .outputs = try outputs.toOwnedSlice(a) });
    }
    return result.toOwnedSlice(a);
}
fn listed(a: std.mem.Allocator, root: []const u8, coordinate: []const u8, artifacts: []const r.Artifact) ![]const u8 {
    for (artifacts) |artifact| if (std.mem.eql(u8, artifact.coordinate, coordinate)) {
        if (artifact.url == null or artifact.url.?.len == 0) return error.UntrustedProcessorDependency;
        try c.trusted(artifact.url.?);
        return c.join(a, root, artifact.path);
    };
    return error.MissingProcessorLibrary;
}
fn library(a: std.mem.Allocator, root: []const u8, coordinate: []const u8) ![]const u8 {
    const coordinate_parsed = try c.m.version.mavenCoordinate(coordinate);
    const path = try coordinate_parsed.path(a, null);
    return std.fmt.allocPrint(a, "{s}/libraries/{s}", .{ root, path });
}
/// Literal scanner: substitution produces exactly one argument, never shell input.
/// No recursive expansion; missing/nested tokens are errors rather than empty text.
pub fn expand(a: std.mem.Allocator, value: []const u8, data: Data, root: []const u8) ![]const u8 {
    if (value.len > 65536 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidProcessorArgument;
    if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') return library(a, root, value[1 .. value.len - 1]);
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '{') {
            const end = std.mem.indexOfScalarPos(u8, value, index + 1, '}') orelse return error.MalformedProcessorToken;
            const key = value[index + 1 .. end];
            try c.id(key);
            try out.appendSlice(a, data.get(key) orelse return error.MissingProcessorData);
            index = end + 1;
        } else {
            if (value[index] == '}') return error.MalformedProcessorToken;
            try out.append(a, value[index]);
            index += 1;
        }
        if (out.items.len > 65536) return error.ProcessorTooLarge;
    }
    return out.toOwnedSlice(a);
}
pub fn underRoot(root: []const u8, path: []const u8) !void {
    if (path.len <= root.len or !std.mem.startsWith(u8, path, root) or path[root.len] != '/') return error.OutputEscapesStage;
    try c.relative(path[root.len + 1 ..]);
}
