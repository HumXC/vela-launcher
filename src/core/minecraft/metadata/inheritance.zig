//! Pure, bounded metadata resolution. Caller supplies already-read documents.
const std = @import("std");
const v = @import("version.zig");
const own = @import("owned.zig");

pub const Limits = struct {
    max_depth: usize = 32,
    max_documents: usize = 128,
    max_bytes: usize = 16 * 1024 * 1024,
    max_libraries: usize = 8192,
    max_arguments: usize = 16384,
};

/// Owns all merged data independently of documents. Missing parents/jar sources
/// are errors, never network requests. A non-null result.jar names the selected
/// client source; result.downloads contains that source's client download.
pub fn resolve(allocator: std.mem.Allocator, leaf_id: []const u8, documents: []const v.Version, limits: Limits) !own.Owned(v.Version) {
    if (limits.max_depth == 0 or limits.max_depth > 64 or limits.max_documents == 0 or limits.max_documents > 256 or limits.max_bytes == 0 or limits.max_bytes > 64 * 1024 * 1024) return error.InvalidInheritanceLimits;
    if (documents.len > limits.max_documents) return error.TooManyVersionDocuments;
    try v.validateId(leaf_id);
    var input_remaining = limits.max_bytes;
    for (documents, 0..) |doc, i| {
        try measure(v.Version, doc, &input_remaining);
        try v.validateId(doc.id);
        if (doc.inherits_from) |id| try v.validateId(id);
        if (doc.jar) |id| try v.validateId(id);
        try validate(doc, limits);
        for (documents[0..i]) |previous| if (std.mem.eql(u8, previous.id, doc.id)) return error.DuplicateVersionId;
    }
    var chain: [64]v.Version = undefined;
    var count: usize = 0;
    var id = leaf_id;
    while (true) {
        for (chain[0..count]) |doc| if (std.mem.eql(u8, doc.id, id)) return error.InheritanceCycle;
        if (count >= limits.max_depth) return error.InheritanceDepthExceeded;
        const doc = try lookup(documents, id);
        chain[count] = doc;
        count += 1;
        id = doc.inherits_from orelse break;
    }
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    var budget: Budget = .{ .a = arena.allocator(), .remaining = limits.max_bytes, .limits = limits };
    var merged = try budget.copy(v.Version, chain[count - 1]);
    try validate(merged, limits);
    try normalize(&budget, &merged);
    try validate(merged, limits);
    var index = count - 1;
    while (index > 0) {
        index -= 1;
        var child = try budget.copy(v.Version, chain[index]);
        try validate(child, limits);
        try normalize(&budget, &child);
        merged = try merge(&budget, merged, child);
        try validate(merged, limits);
    }
    // Resolve client provenance separately: inherited jar references must not
    // accidentally select a child's unrelated downloads entry.
    const source = try clientSource(documents, leaf_id, limits.max_depth);
    const download = clientDownload(source) orelse return error.MissingClientDownload;
    merged.downloads = try putClient(&budget, merged.downloads, try budget.copy(v.Download, download));
    merged.jar = if (count > 1 or chain[0].jar != null) try budget.copy([]const u8, source.id) else null;
    merged.inherits_from = null;
    return .{ .value = merged, .arena = arena, .backing = allocator };
}
fn lookup(documents: []const v.Version, id: []const u8) !v.Version {
    for (documents) |doc| if (std.mem.eql(u8, doc.id, id)) return doc;
    return error.MissingVersionDocument;
}
fn clientDownload(doc: v.Version) ?v.Download {
    for (doc.downloads) |entry| if (std.mem.eql(u8, entry.name, "client")) return entry.download;
    return null;
}
fn clientSource(documents: []const v.Version, leaf: []const u8, depth: usize) !v.Version {
    var seen: [64][]const u8 = undefined;
    var count: usize = 0;
    var id = leaf;
    while (true) {
        for (seen[0..count]) |previous| if (std.mem.eql(u8, previous, id)) return error.InheritanceCycle;
        if (count >= depth) return error.InheritanceDepthExceeded;
        seen[count] = id;
        count += 1;
        const doc = try lookup(documents, id);
        if (doc.jar) |jar| {
            id = jar;
            continue;
        }
        if (clientDownload(doc) != null) return doc;
        id = doc.inherits_from orelse return error.MissingClientDownload;
    }
}
const Budget = struct {
    a: std.mem.Allocator,
    remaining: usize,
    limits: Limits,
    fn consume(self: *Budget, amount: usize) !void {
        if (amount > self.remaining) return error.MetadataTooLarge;
        self.remaining -= amount;
    }
    fn alloc(self: *Budget, comptime T: type, len: usize) ![]T {
        const bytes = std.math.mul(usize, @sizeOf(T), len) catch return error.MetadataTooLarge;
        try self.consume(bytes);
        return self.a.alloc(T, len);
    }
    fn copy(self: *Budget, comptime T: type, value: T) !T {
        return switch (@typeInfo(T)) {
            .pointer => |p| blk: {
                if (p.size != .slice) @compileError("metadata clone supports slices only");
                const out = try self.alloc(p.child, value.len);
                for (value, out) |item, *dest| dest.* = try self.copy(p.child, item);
                break :blk out;
            },
            .optional => |o| if (value) |item| try self.copy(o.child, item) else null,
            .@"struct" => blk: {
                var out: T = undefined;
                inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, field_type| @field(out, field_name) = try self.copy(field_type, @field(value, field_name));
                break :blk out;
            },
            .@"union" => blk: {
                inline for (@typeInfo(T).@"union".field_names, @typeInfo(T).@"union".field_types) |field_name, field_type| if (std.meta.activeTag(value) == @field(std.meta.Tag(T), field_name)) break :blk @unionInit(T, field_name, try self.copy(field_type, @field(value, field_name)));
                unreachable;
            },
            else => value,
        };
    }
};
// Bound supplied data too, including documents outside the selected chain.
fn measure(comptime T: type, value: T, remaining: *usize) !void {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) @compileError("metadata accounting supports slices only");
            const bytes = std.math.mul(usize, @sizeOf(p.child), value.len) catch return error.MetadataTooLarge;
            if (bytes > remaining.*) return error.MetadataTooLarge;
            remaining.* -= bytes;
            if (p.child != u8) for (value) |item| try measure(p.child, item, remaining);
        },
        .optional => |o| if (value) |item| try measure(o.child, item, remaining),
        .@"struct" => inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, field_type| try measure(field_type, @field(value, field_name), remaining),
        .@"union" => inline for (@typeInfo(T).@"union".field_names, @typeInfo(T).@"union".field_types) |field_name, field_type| {
            if (std.meta.activeTag(value) == @field(std.meta.Tag(T), field_name)) {
                try measure(field_type, @field(value, field_name), remaining);
                break;
            }
        },
        else => {},
    }
}
fn validate(doc: v.Version, limits: Limits) !void {
    if (doc.libraries) |libs| {
        if (libs.len > limits.max_libraries) return error.TooManyLibraries;
        for (libs) |lib| {
            if (std.mem.indexOfScalar(u8, lib.name, ':') != null) _ = try v.mavenCoordinate(lib.name) else try v.validateId(lib.name);
        }
    }
    if (doc.arguments) |args| {
        const total = std.math.add(usize, try argumentCount(args.game), try argumentCount(args.jvm)) catch return error.TooManyArguments;
        if (total > limits.max_arguments) return error.TooManyArguments;
    }
}
fn argumentCount(args: ?[]const v.Argument) !usize {
    var count: usize = 0;
    for (args orelse return 0) |arg| {
        const n: usize = switch (arg) {
            .literal => 1,
            .conditional => |c| c.values.len,
        };
        count = std.math.add(usize, count, n) catch return error.TooManyArguments;
    }
    return count;
}
fn normalize(b: *Budget, doc: *v.Version) !void {
    if (doc.minecraft_arguments) |legacy| {
        var args = doc.arguments orelse v.Arguments{ .game = null, .jvm = null };
        if (args.game == null) {
            try b.consume(legacy.len * 2);
            const tokens = try v.tokenizeLegacy(b.a, legacy);
            const game = try b.alloc(v.Argument, tokens.len);
            for (tokens, game) |token, *arg| arg.* = .{ .literal = token };
            args.game = game;
        }
        doc.arguments = args;
    }
}
fn arguments(b: *Budget, parent: ?[]const v.Argument, child: ?[]const v.Argument) !?[]const v.Argument {
    if (child == null) return parent;
    if (parent == null) return child;
    if (parent.?.len + child.?.len > b.limits.max_arguments) return error.TooManyArguments;
    const out = try b.alloc(v.Argument, parent.?.len + child.?.len);
    @memcpy(out[0..parent.?.len], parent.?);
    @memcpy(out[parent.?.len..], child.?);
    return out;
}
fn sameLibrary(a: v.Library, b: v.Library) !bool {
    if (std.mem.indexOfScalar(u8, a.name, ':') == null or std.mem.indexOfScalar(u8, b.name, ':') == null) return std.mem.eql(u8, a.name, b.name);
    const x = try v.mavenCoordinate(a.name);
    const y = try v.mavenCoordinate(b.name);
    if (!std.mem.eql(u8, x.group, y.group) or !std.mem.eql(u8, x.artifact, y.artifact) or !std.mem.eql(u8, x.extension, y.extension)) return false;
    if ((x.classifier == null) != (y.classifier == null)) return false;
    if (x.classifier) |c| if (!std.mem.eql(u8, c, y.classifier.?)) return false;
    if (a.natives.len != b.natives.len) return false;
    for (a.natives) |native| {
        var found = false;
        for (b.natives) |other| if (std.mem.eql(u8, native.key, other.key)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}
fn libraries(b: *Budget, parent: ?[]const v.Library, child: ?[]const v.Library) !?[]const v.Library {
    if (child == null) return parent;
    if (parent == null) return child;
    const capacity = parent.?.len + child.?.len;
    const out = try b.alloc(v.Library, capacity);
    var n: usize = 0;
    for (parent.?) |lib| {
        var replaced = false;
        for (child.?) |overlay| if (try sameLibrary(lib, overlay)) {
            replaced = true;
            break;
        };
        if (!replaced) {
            out[n] = lib;
            n += 1;
        }
    }
    if (n + child.?.len > b.limits.max_libraries) return error.TooManyLibraries;
    // Rules are retained, including disallow/empty arrays. All child variants
    // survive; rule evaluation belongs to the platform-aware planner.
    @memcpy(out[n..][0..child.?.len], child.?);
    return out[0 .. n + child.?.len];
}
fn named(b: *Budget, comptime T: type, parent: []const T, child: []const T) ![]const T {
    const out = try b.alloc(T, parent.len + child.len);
    var n: usize = 0;
    for (parent) |entry| {
        var replaced = false;
        for (child) |overlay| if (std.mem.eql(u8, entry.name, overlay.name)) {
            replaced = true;
            break;
        };
        if (!replaced) {
            out[n] = entry;
            n += 1;
        }
    }
    @memcpy(out[n..][0..child.len], child);
    return out[0 .. n + child.len];
}
fn putClient(b: *Budget, downloads: []const v.DownloadEntry, client: v.Download) ![]const v.DownloadEntry {
    return named(b, v.DownloadEntry, downloads, &.{.{ .name = "client", .download = client }});
}
fn merge(b: *Budget, parent: v.Version, child: v.Version) !v.Version {
    var out = child;
    inline for (.{ "kind", "main_class", "time", "release_time", "minimum_launcher_version", "compliance_level", "java_version", "asset_index", "assets", "jar", "minecraft_arguments" }) |field| if (@field(out, field) == null) {
        @field(out, field) = @field(parent, field);
    };
    out.downloads = try named(b, v.DownloadEntry, parent.downloads, child.downloads);
    out.logging = try named(b, v.Logging, parent.logging, child.logging);
    out.libraries = try libraries(b, parent.libraries, child.libraries);
    const p = parent.arguments orelse v.Arguments{ .game = null, .jvm = null };
    const c = child.arguments orelse v.Arguments{ .game = null, .jvm = null };
    out.arguments = if (parent.arguments != null or child.arguments != null) .{
        .jvm = try arguments(b, p.jvm, c.jvm),
        .game = if (child.minecraft_arguments != null) c.game else try arguments(b, p.game, c.game),
    } else null;
    return out;
}

test "inheritance overlays preserve rules classifiers arguments and ownership" {
    const a = std.testing.allocator;
    var parent = try v.parseSlice(a,
        \\{"id":"1.7.10","mainClass":"net.minecraft.Main","minecraftArguments":"--username ${auth_player_name}","assets":"legacy","assetIndex":{"id":"legacy","url":"https://example/index"},"downloads":{"client":{"url":"https://example/client"}},"libraries":[{"name":"g:lib:1"},{"name":"g:lib:1:natives-linux"}]}
    );
    defer parent.deinit();
    var child = try v.parseSlice(a,
        \\{"id":"forge","inheritsFrom":"1.7.10","mainClass":"net.minecraft.launchwrapper.Launch","arguments":{"game":["--tweakClass","cpw.mods.fml.common.launcher.FMLTweaker"]},"libraries":[{"name":"g:lib:2","rules":[{"action":"disallow"}]}]}
    );
    defer child.deinit();
    var result = try resolve(a, "forge", &.{ parent.value, child.value }, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("forge", result.value.id);
    try std.testing.expectEqualStrings("net.minecraft.launchwrapper.Launch", result.value.main_class.?);
    try std.testing.expectEqualStrings("1.7.10", result.value.jar.?);
    try std.testing.expectEqual(@as(u64, 8), v.requiredJavaMajor(result.value));
    try std.testing.expectEqual(@as(usize, 2), result.value.libraries.?.len);
    try std.testing.expectEqual(v.rules.Action.disallow, result.value.libraries.?[1].rules.?[0].action);
    try std.testing.expectEqual(@as(usize, 4), result.value.arguments.?.game.?.len);
    try std.testing.expect(@intFromPtr(result.value.id.ptr) != @intFromPtr(child.value.id.ptr));
    try std.testing.expectError(error.InheritanceDepthExceeded, resolve(a, "forge", &.{ parent.value, child.value }, .{ .max_depth = 1 }));
    try std.testing.expectError(error.MetadataTooLarge, resolve(a, "forge", &.{ parent.value, child.value }, .{ .max_bytes = 8 }));
    parent.value.inherits_from = "forge";
    try std.testing.expectError(error.InheritanceCycle, resolve(a, "forge", &.{ parent.value, child.value }, .{}));
}

test "jar references require provided documents and reject cycles" {
    const a = std.testing.allocator;
    var source = try v.parseSlice(a, "{\"id\":\"base\",\"downloads\":{\"client\":{\"url\":\"https://example/client\"}},\"javaVersion\":{\"component\":\"java-runtime-delta\",\"majorVersion\":21}}");
    defer source.deinit();
    var leaf = try v.parseSlice(a, "{\"id\":\"overlay\",\"inheritsFrom\":\"base\",\"jar\":\"base\"}");
    defer leaf.deinit();
    var result = try resolve(a, "overlay", &.{ source.value, leaf.value }, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 21), v.requiredJavaMajor(result.value));
    try std.testing.expectError(error.MissingVersionDocument, resolve(a, "overlay", &.{leaf.value}, .{}));
    source.value.jar = "overlay";
    try std.testing.expectError(error.InheritanceCycle, resolve(a, "overlay", &.{ source.value, leaf.value }, .{}));
}

fn inheritanceAllocationCase(a: std.mem.Allocator) !void {
    var parent = try v.parseSlice(std.testing.allocator, "{\"id\":\"base\",\"mainClass\":\"net.minecraft.Main\",\"minecraftArguments\":\"--username ${auth_player_name} --version ${version_name}\",\"downloads\":{\"client\":{\"url\":\"https://example/client\"}},\"libraries\":[{\"name\":\"g:lib:1\"}],\"arguments\":{\"jvm\":[\"-cp\",\"${classpath}\"]}}");
    defer parent.deinit();
    var child = try v.parseSlice(std.testing.allocator, "{\"id\":\"forge\",\"inheritsFrom\":\"base\",\"minecraftArguments\":\"--tweakClass first.Tweaker --tweakClass second.Tweaker\",\"libraries\":[{\"name\":\"g:lib:2\",\"rules\":[{\"action\":\"disallow\"}]},{\"name\":\"g:lib:2\",\"rules\":[{\"action\":\"allow\",\"os\":{\"name\":\"linux\"}}]}]}");
    defer child.deinit();
    var resolved = try resolve(a, "forge", &.{ parent.value, child.value }, .{});
    defer resolved.deinit();
}

test "inheritance allocations clean up and legacy replacement retains rule variants" {
    const a = std.testing.allocator;
    try @import("test_allocations").checkAllAllocationFailures(a, inheritanceAllocationCase, .{});
    var resolved: own.Owned(v.Version) = undefined;
    {
        var parent = try v.parseSlice(a, "{\"id\":\"base\",\"mainClass\":\"net.minecraft.Main\",\"minecraftArguments\":\"--username ${auth_player_name} --version ${version_name}\",\"downloads\":{\"client\":{\"url\":\"https://example/client\"}},\"libraries\":[{\"name\":\"g:lib:1\"}],\"arguments\":{\"jvm\":[\"-cp\",\"${classpath}\"]}}");
        defer parent.deinit();
        var child = try v.parseSlice(a, "{\"id\":\"forge\",\"inheritsFrom\":\"base\",\"minecraftArguments\":\"--tweakClass first.Tweaker --tweakClass second.Tweaker\",\"libraries\":[{\"name\":\"g:lib:2\",\"rules\":[{\"action\":\"disallow\"}]},{\"name\":\"g:lib:2\",\"rules\":[{\"action\":\"allow\",\"os\":{\"name\":\"linux\"}}]}]}");
        defer child.deinit();
        resolved = try resolve(a, "forge", &.{ parent.value, child.value }, .{ .max_libraries = 2 });
        try std.testing.expectError(error.TooManyArguments, resolve(a, "forge", &.{ parent.value, child.value }, .{ .max_arguments = 3 }));
        try std.testing.expectError(error.TooManyVersionDocuments, resolve(a, "forge", &.{ parent.value, child.value }, .{ .max_documents = 1 }));
        try std.testing.expectError(error.DuplicateVersionId, resolve(a, "base", &.{ parent.value, parent.value }, .{}));
        try std.testing.expectError(error.MissingVersionDocument, resolve(a, "missing", &.{parent.value}, .{}));
    }
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 4), resolved.value.arguments.?.game.?.len);
    try std.testing.expectEqualStrings("first.Tweaker", resolved.value.arguments.?.game.?[1].literal);
    try std.testing.expectEqualStrings("second.Tweaker", resolved.value.arguments.?.game.?[3].literal);
    try std.testing.expectEqual(@as(usize, 2), resolved.value.libraries.?.len);
    try std.testing.expectEqual(v.rules.Action.disallow, resolved.value.libraries.?[0].rules.?[0].action);
    try std.testing.expectEqualStrings("https://example/client", resolved.value.downloads[0].download.url);
    try std.testing.expectEqual(@as(u64, 8), v.requiredJavaMajor(resolved.value));
}

test "normalized legacy and conditional values obey argument limits" {
    const a = std.testing.allocator;
    var legacy = try v.parseSlice(a, "{\"id\":\"legacy\",\"minecraftArguments\":\"one two\",\"downloads\":{\"client\":{\"url\":\"https://example/client\"}}}");
    defer legacy.deinit();
    try std.testing.expectError(error.TooManyArguments, resolve(a, "legacy", &.{legacy.value}, .{ .max_arguments = 1 }));
    var modern = try v.parseSlice(a, "{\"id\":\"modern\",\"arguments\":{\"game\":[{\"rules\":[],\"value\":[\"one\",\"two\"]}]},\"downloads\":{\"client\":{\"url\":\"https://example/client\"}}}");
    defer modern.deinit();
    try std.testing.expectError(error.TooManyArguments, resolve(a, "modern", &.{modern.value}, .{ .max_arguments = 1 }));
}

test "supplied documents outside the chain obey aggregate byte limits" {
    const a = std.testing.allocator;
    var base = try v.parseSlice(a, "{\"id\":\"base\",\"downloads\":{\"client\":{\"url\":\"https://example/client\"}}}");
    defer base.deinit();
    const excessive = try a.alloc(u8, 4096);
    defer a.free(excessive);
    @memset(excessive, 'x');
    var other = base.value;
    other.id = "unused";
    other.main_class = excessive;
    try std.testing.expectError(error.MetadataTooLarge, resolve(a, "base", &.{ base.value, other }, .{ .max_bytes = 2048 }));
}
