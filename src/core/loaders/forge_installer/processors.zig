const std = @import("std");
const c = @import("../common.zig");
const r = @import("../recipe_types.zig");
const j = c.j;
/// A null digest means upstream supplied no expected proof; observed integrity is separate.
pub const Output = struct { path: []const u8, sha1: ?c.m.Sha1, runtime: bool = false };
pub const Processor = struct { jar: []const u8, classpath: []const []const u8, args: []const []const u8, outputs: []const Output };
const Data = std.StringHashMap([]const u8);
/// External processors receive a private copy, never another instance or a cache file.
pub const client_relative_path = ".loader/minecraft.jar";
pub fn build(a: std.mem.Allocator, raw: std.json.Value, artifacts: *std.ArrayList(r.Artifact), root: []const u8, base: []const u8, side: c.Side, members: *std.ArrayList(r.Member)) ![]const Processor {
    var data = Data.init(a);
    try data.put("SIDE", @tagName(side));
    try data.put("ROOT", root);
    try data.put("MINECRAFT_VERSION", base);
    try data.put("LIBRARY_DIR", try c.join(a, root, "libraries"));
    try data.put("INSTALLER", try c.join(a, root, ".loader/installer.jar"));
    try data.put("MINECRAFT_JAR", try c.join(a, root, client_relative_path));
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
        const jar = try listed(a, root, coordinate, artifacts.items);
        var classpath: std.ArrayList([]const u8) = .empty;
        try classpath.append(a, jar);
        for (try j.array(try j.required(value, "classpath"))) |cp| try classpath.append(a, try listed(a, root, try c.text(cp), artifacts.items));
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
                var duplicate = false;
                for (outputs.items) |existing| {
                    if (!std.mem.eql(u8, existing.path, path)) continue;
                    if (!std.meta.eql(existing.sha1, @as(?c.m.Sha1, hash))) return error.ConflictingArtifact;
                    duplicate = true;
                }
                if (!duplicate) try outputs.append(a, .{ .path = path, .sha1 = hash });
            }
        }
        try inferOutputs(a, coordinate, args.items, data, root, &outputs);
        try bindArtifacts(a, raw, side, data, root, result.items.len, &outputs, artifacts);
        try result.append(a, .{ .jar = jar, .classpath = try classpath.toOwnedSlice(a), .args = try args.toOwnedSlice(a), .outputs = try outputs.toOwnedSlice(a) });
    }
    return result.toOwnedSlice(a);
}
// These contracts come from the official tools, not from a generic --output guess.
fn option(args: []const []const u8, name: []const u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    for (args, 0..) |arg, index| {
        var value: ?[]const u8 = null;
        if (std.mem.eql(u8, arg, name)) {
            if (index + 1 >= args.len or std.mem.startsWith(u8, args[index + 1], "--")) return error.MissingProcessorOption;
            value = args[index + 1];
        } else if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=') value = arg[name.len + 1 ..];
        if (value) |v| {
            if (v.len == 0 or found != null) return error.InvalidProcessorOption;
            found = v;
        }
    }
    return found;
}
fn flag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}
fn output(a: std.mem.Allocator, root: []const u8, path: []const u8, data: Data, runtime: bool, outputs: *std.ArrayList(Output)) !void {
    try underRoot(root, path);
    var hash: ?c.m.Sha1 = null;
    var it = data.iterator();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.value_ptr.*, path)) continue;
        const key = try std.fmt.allocPrint(a, "{s}_SHA", .{entry.key_ptr.*});
        if (data.get(key)) |proof| {
            const candidate = try c.sha1(proof);
            if (hash != null and !std.meta.eql(hash.?, candidate)) return error.ConflictingArtifact;
            hash = candidate;
        }
    }
    for (outputs.items) |*existing| {
        if (!std.mem.eql(u8, existing.path, path)) continue;
        if (existing.sha1 != null and hash != null and !std.meta.eql(existing.sha1.?, hash.?)) return error.ConflictingArtifact;
        existing.sha1 = existing.sha1 orelse hash;
        existing.runtime = existing.runtime or runtime;
        return;
    }
    try outputs.append(a, .{ .path = path, .sha1 = hash, .runtime = runtime });
}
fn inferOutputs(a: std.mem.Allocator, coordinate: []const u8, args: []const []const u8, data: Data, root: []const u8, outputs: *std.ArrayList(Output)) !void {
    var parts = std.mem.splitScalar(u8, coordinate, ':');
    _ = parts.next();
    const tool = parts.next() orelse return error.InvalidProcessor;
    if (std.mem.eql(u8, tool, "binarypatcher")) {
        if (try option(args, "--apply") == null) return;
        const path = (try option(args, "--output")) orelse return error.MissingProcessorOption;
        try output(a, root, path, data, true, outputs);
    } else if (std.mem.eql(u8, tool, "jarsplitter")) {
        if (try option(args, "--slim")) |path| try output(a, root, path, data, false, outputs);
        if (try option(args, "--extra")) |path| try output(a, root, path, data, true, outputs);
    } else if (std.mem.eql(u8, tool, "ForgeAutoRenamingTool") or std.mem.eql(u8, tool, "AutoRenamingTool")) {
        const path = (try option(args, "--output")) orelse return error.MissingProcessorOption;
        try output(a, root, path, data, true, outputs);
    } else if (std.mem.eql(u8, tool, "installertools")) {
        const task = (try option(args, "--task")) orelse return;
        const file_tasks = [_][]const u8{ "MCP_DATA", "DOWNLOAD_MOJMAPS", "MERGE_MAPPING", "CHAIN_MAPPING", "SRG_TO_MCP", "EXTRACT_INHERITANCE", "MAPPINGS_CSV" };
        for (file_tasks) |known| {
            if (!std.mem.eql(u8, task, known)) continue;
            const path = (try option(args, "--output")) orelse return error.MissingProcessorOption;
            try output(a, root, path, data, false, outputs);
            return;
        }
        if (std.mem.eql(u8, task, "PROCESS_MINECRAFT_JAR")) {
            // NeoForge InstallerTools 4 processes the client jar directly.
            // --extract-libraries-to concerns bundled dedicated servers only.
            const path = (try option(args, "--output")) orelse return error.MissingProcessorOption;
            try output(a, root, path, data, true, outputs);
            return;
        }
        if (std.mem.eql(u8, task, "BUNDLER_EXTRACT") and flag(args, "--jar-only")) {
            const path = (try option(args, "--output")) orelse return error.MissingProcessorOption;
            try output(a, root, path, data, false, outputs);
        }
    }
}
fn bindArtifacts(a: std.mem.Allocator, raw: std.json.Value, side: c.Side, data: Data, root: []const u8, producer: usize, outputs: *std.ArrayList(Output), artifacts: *std.ArrayList(r.Artifact)) !void {
    for (outputs.items) |*generated| {
        try underRoot(root, generated.path);
        const relative = generated.path[root.len + 1 ..];
        var listed_runtime = false;
        for (artifacts.items) |*artifact| {
            if (!std.mem.eql(u8, artifact.path, relative)) continue;
            if (artifact.member != null or (artifact.url != null and artifact.url.?.len != 0) or artifact.producer != null) return error.ConflictingArtifact;
            if (artifact.sha1 != null and generated.sha1 != null and !std.meta.eql(artifact.sha1.?, generated.sha1.?)) return error.ConflictingArtifact;
            artifact.sha1 = artifact.sha1 orelse generated.sha1;
            generated.sha1 = generated.sha1 orelse artifact.sha1;
            artifact.producer = producer;
            generated.runtime = true;
            listed_runtime = true;
        }
        if (listed_runtime or !generated.runtime) continue;
        // FML resolves the renamed clean jar, split extra jar, and patched jar
        // directly from libraryDirectory. Mappings and slim jars stay staged.
        const values = (try j.optional(raw, "data")) orelse continue;
        var it = (try j.object(values)).iterator();
        var coordinate: ?[]const u8 = null;
        while (it.next()) |entry| {
            const resolved = data.get(entry.key_ptr.*) orelse continue;
            if (!std.mem.eql(u8, resolved, generated.path)) continue;
            const value = try c.text(try j.required(entry.value_ptr.*, @tagName(side)));
            if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') continue;
            const candidate = value[1 .. value.len - 1];
            // Canonical path equality already proves Maven aliases such as @jar.
            coordinate = coordinate orelse candidate;
        }
        if (coordinate) |name| {
            try r.mergeArtifact(a, artifacts, .{ .coordinate = try a.dupe(u8, name), .path = try a.dupe(u8, relative), .url = "", .sha1 = generated.sha1, .size = null, .producer = producer });
        }
    }
}
fn listed(a: std.mem.Allocator, root: []const u8, coordinate: []const u8, artifacts: []const r.Artifact) ![]const u8 {
    const requested = try c.m.version.mavenCoordinate(coordinate);
    for (artifacts) |artifact| {
        const candidate = try c.m.version.mavenCoordinate(artifact.coordinate);
        const classifier_matches = if (requested.classifier) |classifier|
            candidate.classifier != null and std.mem.eql(u8, classifier, candidate.classifier.?)
        else
            candidate.classifier == null;
        if (!std.mem.eql(u8, requested.group, candidate.group) or
            !std.mem.eql(u8, requested.artifact, candidate.artifact) or
            !std.mem.eql(u8, requested.version, candidate.version) or
            !std.mem.eql(u8, requested.extension, candidate.extension) or !classifier_matches) continue;
        // An omitted extension and explicit @jar name the same Maven artifact.
        // Classifiers and non-jar extensions remain separate dependencies.
        if (artifact.url == null or artifact.url.?.len == 0) return error.UntrustedProcessorDependency;
        try c.trusted(artifact.url.?);
        return c.join(a, root, artifact.path);
    }
    return error.MissingProcessorLibrary;
}

test "processor dependencies accept default jar aliases but retain classifier extension and origin boundaries" {
    const a = std.testing.allocator;
    const artifacts = [_]r.Artifact{.{
        .coordinate = "net.neoforged:tool:1.0:all@jar",
        .path = "libraries/net/neoforged/tool/1.0/tool-1.0-all.jar",
        .url = "https://maven.neoforged.net/releases/net/neoforged/tool/1.0/tool-1.0-all.jar",
        .sha1 = null,
        .size = null,
    }};
    for ([_][]const u8{ "net.neoforged:tool:1.0:all", "net.neoforged:tool:1.0:all@jar" }) |coordinate| {
        const path = try listed(a, "/stage", coordinate, &artifacts);
        defer a.free(path);
        try std.testing.expectEqualStrings("/stage/libraries/net/neoforged/tool/1.0/tool-1.0-all.jar", path);
    }
    for ([_][]const u8{ "net.neoforged:tool:1.0", "net.neoforged:tool:1.0:all@zip", "net.neoforged:tool:2.0:all" }) |coordinate|
        try std.testing.expectError(error.MissingProcessorLibrary, listed(a, "/stage", coordinate, &artifacts));
    var untrusted = artifacts;
    untrusted[0].url = "";
    try std.testing.expectError(error.UntrustedProcessorDependency, listed(a, "/stage", "net.neoforged:tool:1.0:all", &untrusted));
    untrusted[0].url = "https://example.com/tool.jar";
    try std.testing.expectError(error.UntrustedUrl, listed(a, "/stage", "net.neoforged:tool:1.0:all", &untrusted));
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
