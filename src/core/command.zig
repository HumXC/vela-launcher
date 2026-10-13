//! Generic argv builder: identity, multiplicity and rendering are independent.
//! No shell parsing or Minecraft/Java-specific recognition is performed here.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Key = struct {
    namespace: []const u8 = "",
    name: []const u8,
    pub fn eql(a: Key, b: Key) bool {
        return std.mem.eql(u8, a.namespace, b.namespace) and std.mem.eql(u8, a.name, b.name);
    }
};
pub const Arity = enum { flag, value };
pub const Merge = enum { replace, append, unique };
pub const Layout = enum { flag, separate, joined, eq, colon };
pub const Spec = struct {
    key: Key,
    canonical: []const u8,
    aliases: []const []const u8 = &.{},
    arity: Arity,
    merge: Merge = .replace,
    layout: Layout = .separate,
};

/// One appearance in argv. Storage is owned by its private arena and never
/// references the caller's Spec, value or raw token. Treat fields as read-only.
pub const Occurrence = struct {
    key: ?Key,
    value: ?[]const u8,
    tokens: []const []const u8,
    arena: std.heap.ArenaAllocator,
    fn deinit(self: *Occurrence) void {
        self.arena.deinit();
    }
};

/// Fully independent argv snapshot; safe after Builder mutation or destruction.
pub const OwnedArgv = struct {
    argv: []const []const u8,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *OwnedArgv) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Builder = struct {
    allocator: Allocator,
    program: []const u8,
    occurrences: std.ArrayList(Occurrence) = .empty,

    /// Copies program. The allocator must outlive the Builder.
    pub fn init(allocator: Allocator, program: []const u8) !Builder {
        if (program.len == 0) return error.InvalidProgram;
        try validateToken(program);
        return .{ .allocator = allocator, .program = try allocator.dupe(u8, program) };
    }
    pub fn deinit(self: *Builder) void {
        self.clear();
        self.occurrences.deinit(self.allocator);
        self.allocator.free(self.program);
        self.* = undefined;
    }
    pub fn clear(self: *Builder) void {
        for (self.occurrences.items) |*entry| entry.deinit();
        self.occurrences.clearRetainingCapacity();
    }
    /// Number of appearances, not number of rendered tokens. Excludes program.
    pub fn count(self: *const Builder) usize {
        return self.occurrences.items.len;
    }

    /// null is a flag invocation; empty string is a valid value invocation.
    /// replace preserves the first occurrence's position and removes subsequent
    /// appearances of that key. append preserves global insertion order.
    /// unique skips only an identical key+token sequence, retaining distinct values.
    /// All fallible construction finishes before any existing entry is changed.
    pub fn add(self: *Builder, spec: Spec, value: ?[]const u8) !void {
        try validateSpec(spec, value);
        var entry = try makeOccurrence(self.allocator, spec, value);
        errdefer entry.deinit();
        var first: ?usize = null;
        for (self.occurrences.items, 0..) |old, i| {
            const key = old.key orelse continue;
            if (!key.eql(spec.key)) continue;
            if (first == null) first = i;
            if (spec.merge == .unique and sameTokens(old.tokens, entry.tokens)) {
                entry.deinit();
                return;
            }
        }
        if (spec.merge == .replace) if (first) |index| {
            // No allocation or other failure is possible after this commit point.
            self.occurrences.items[index].deinit();
            self.occurrences.items[index] = entry;
            var i = index + 1;
            while (i < self.occurrences.items.len) {
                if (self.occurrences.items[i].key) |key| {
                    if (key.eql(entry.key.?)) {
                        var old = self.occurrences.orderedRemove(i);
                        old.deinit();
                        continue;
                    }
                }
                i += 1;
            }
            return;
        };
        try self.occurrences.append(self.allocator, entry);
    }

    /// Exact canonical/explicit-alias lookup, never strips dashes or parses values.
    pub fn addNamed(self: *Builder, specs: []const Spec, name: []const u8, value: ?[]const u8) !void {
        var found: ?Spec = null;
        for (specs) |spec| {
            var matches = std.mem.eql(u8, spec.canonical, name);
            for (spec.aliases) |alias| matches = matches or std.mem.eql(u8, alias, name);
            if (matches) {
                if (found != null) return error.AmbiguousArgument;
                found = spec;
            }
        }
        return self.add(found orelse return error.UnknownArgument, value);
    }

    /// Copies one exact argv token. Raw tokens have no key and never merge.
    pub fn addRaw(self: *Builder, token: []const u8) !void {
        try validateToken(token);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const tokens = try a.alloc([]const u8, 1);
        tokens[0] = try a.dupe(u8, token);
        try self.occurrences.append(self.allocator, .{ .key = null, .value = null, .tokens = tokens, .arena = arena });
    }
    /// Deletes all structured appearances of a key. Raw tokens are untouched.
    pub fn remove(self: *Builder, key: Key) usize {
        // Partition first, free second: key may itself borrow a removed entry.
        var kept: usize = 0;
        for (0..self.occurrences.items.len) |i| {
            const existing = self.occurrences.items[i].key;
            if (existing != null and existing.?.eql(key)) continue;
            std.mem.swap(Occurrence, &self.occurrences.items[kept], &self.occurrences.items[i]);
            kept += 1;
        }
        const removed = self.occurrences.items.len - kept;
        for (self.occurrences.items[kept..]) |*entry| entry.deinit();
        self.occurrences.items.len = kept;
        return removed;
    }
    pub fn has(self: *const Builder, key: Key) bool {
        for (self.occurrences.items) |entry| if (entry.key) |existing| if (existing.eql(key)) return true;
        return false;
    }
    /// Latest value; null means absent or a flag (use has to distinguish).
    /// Borrowed until that occurrence is replaced/removed, clear or deinit.
    pub fn get(self: *const Builder, key: Key) ?[]const u8 {
        var i = self.occurrences.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.occurrences.items[i];
            if (entry.key) |existing| if (existing.eql(key)) return entry.value;
        }
        return null;
    }
    /// Caller frees outer slice. Strings borrow the Builder; mutation can
    /// invalidate affected strings. Use renderOwned for a stable snapshot.
    pub fn render(self: *const Builder, allocator: Allocator) ![]const []const u8 {
        var total: usize = 1;
        for (self.occurrences.items) |entry| total = try std.math.add(usize, total, entry.tokens.len);
        const result = try allocator.alloc([]const u8, total);
        result[0] = self.program;
        var i: usize = 1;
        for (self.occurrences.items) |entry| {
            @memcpy(result[i..][0..entry.tokens.len], entry.tokens);
            i += entry.tokens.len;
        }
        return result;
    }
    pub fn renderOwned(self: *const Builder, allocator: Allocator) !OwnedArgv {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const borrowed = try self.render(a);
        const result = try a.alloc([]const u8, borrowed.len);
        for (borrowed, result) |token, *out| out.* = try a.dupe(u8, token);
        return .{ .argv = result, .arena = arena };
    }
    /// POSIX quoting for display only; launch processes using argv instead.
    pub fn renderToString(self: *const Builder, allocator: Allocator) ![]u8 {
        const argv = try self.render(allocator);
        defer allocator.free(argv);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (argv, 0..) |token, i| {
            if (i != 0) try out.append(allocator, ' ');
            try appendQuoted(&out, allocator, token);
        }
        return out.toOwnedSlice(allocator);
    }
};

fn validateToken(token: []const u8) !void {
    if (std.mem.indexOfScalar(u8, token, 0) != null) return error.EmbeddedNul;
}
fn validateSpec(spec: Spec, value: ?[]const u8) !void {
    if (spec.key.name.len == 0 or spec.canonical.len == 0) return error.InvalidSpec;
    if ((spec.arity == .flag) != (spec.layout == .flag)) return error.InvalidSpec;
    if (spec.arity == .flag and value != null) return error.UnexpectedValue;
    if (spec.arity == .value and value == null) return error.MissingValue;
    try validateToken(spec.canonical);
    if (value) |v| try validateToken(v);
}
fn makeOccurrence(allocator: Allocator, spec: Spec, value: ?[]const u8) !Occurrence {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const key: Key = .{ .namespace = try a.dupe(u8, spec.key.namespace), .name = try a.dupe(u8, spec.key.name) };
    const name = try a.dupe(u8, spec.canonical);
    const v: ?[]const u8 = if (value) |x| try a.dupe(u8, x) else null;
    const tokens = try a.alloc([]const u8, if (spec.layout == .separate) 2 else 1);
    switch (spec.layout) {
        .flag => tokens[0] = name,
        .separate => {
            tokens[0] = name;
            tokens[1] = v.?;
        },
        .joined => tokens[0] = try std.mem.concat(a, u8, &.{ name, v.? }),
        .eq => tokens[0] = try std.mem.concat(a, u8, &.{ name, "=", v.? }),
        .colon => tokens[0] = try std.mem.concat(a, u8, &.{ name, ":", v.? }),
    }
    return .{ .key = key, .value = v, .tokens = tokens, .arena = arena };
}
fn sameTokens(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}
fn needsQuote(s: []const u8) bool {
    if (s.len == 0) return true;
    for (s) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', ':', '=', '+', ',', '@' => {},
        else => return true,
    };
    return false;
}
fn appendQuoted(out: *std.ArrayList(u8), a: Allocator, token: []const u8) !void {
    if (!needsQuote(token)) return out.appendSlice(a, token);
    try out.append(a, 39);
    for (token) |ch| {
        if (ch == 39) try out.appendSlice(a, &.{ 39, 92, 39, 39 }) else try out.append(a, ch);
    }
    try out.append(a, 39);
}

const test_allocator = std.testing.allocator;
const heap: Spec = .{ .key = .{ .name = "heap" }, .canonical = "-Xmx", .arity = .value, .layout = .joined };
const agent: Spec = .{ .key = .{ .name = "agent" }, .canonical = "-javaagent", .arity = .value, .merge = .append, .layout = .colon };
fn expectArgv(b: *const Builder, expected: []const []const u8) !void {
    const argv = try b.render(test_allocator);
    defer test_allocator.free(argv);
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "append occurrences retain interleaved order; replacement keeps first position" {
    var b = try Builder.init(test_allocator, "java");
    defer b.deinit();
    try b.add(agent, "a.jar");
    try b.add(heap, "2G");
    try b.add(agent, "b.jar");
    try expectArgv(&b, &.{ "java", "-javaagent:a.jar", "-Xmx2G", "-javaagent:b.jar" });
    try b.add(heap, "4G");
    try expectArgv(&b, &.{ "java", "-javaagent:a.jar", "-Xmx4G", "-javaagent:b.jar" });
    var replacing = agent;
    replacing.merge = .replace;
    try b.add(replacing, "c.jar");
    try expectArgv(&b, &.{ "java", "-javaagent:c.jar", "-Xmx4G" });
    try std.testing.expectEqual(@as(usize, 1), b.remove(agent.key));
}
test "canonical spelling and explicit aliases only" {
    var b = try Builder.init(test_allocator, "java");
    defer b.deinit();
    const cp: Spec = .{ .key = .{ .name = "classpath" }, .canonical = "-cp", .aliases = &.{ "-classpath", "--class-path" }, .arity = .value };
    try b.addNamed(&.{cp}, "--class-path", "a:b");
    try b.addNamed(&.{cp}, "-classpath", "c:d");
    try expectArgv(&b, &.{ "java", "-cp", "c:d" });
    try std.testing.expectError(error.UnknownArgument, b.addNamed(&.{cp}, "cp", "x"));
    try std.testing.expectError(error.UnknownArgument, b.addNamed(&.{cp}, "---cp", "x"));
    try std.testing.expectError(error.AmbiguousArgument, b.addNamed(&.{ cp, cp }, "-cp", "x"));
}
test "dynamic keys are owned and namespaces isolate identity" {
    var b = try Builder.init(test_allocator, "java");
    defer b.deinit();
    {
        const name = try test_allocator.dupe(u8, "foo");
        defer test_allocator.free(name);
        const canonical = try test_allocator.dupe(u8, "-Dfoo");
        defer test_allocator.free(canonical);
        try b.add(.{ .key = .{ .namespace = "java.property", .name = name }, .canonical = canonical, .arity = .value, .layout = .eq }, "one");
    }
    try b.add(.{ .key = .{ .namespace = "java.property", .name = "bar" }, .canonical = "-Dbar", .arity = .value, .layout = .eq }, "two");
    try b.add(.{ .key = .{ .namespace = "java.property", .name = "foo" }, .canonical = "-Dfoo", .arity = .value, .layout = .eq }, "new");
    try b.add(.{ .key = .{ .namespace = "java.xx", .name = "UseG1GC" }, .canonical = "-XX:", .arity = .value, .layout = .joined }, "+UseG1GC");
    try b.add(.{ .key = .{ .namespace = "java.xx", .name = "UseG1GC" }, .canonical = "-XX:", .arity = .value, .layout = .joined }, "-UseG1GC");
    try expectArgv(&b, &.{ "java", "-Dfoo=new", "-Dbar=two", "-XX:-UseG1GC" });
    try std.testing.expectEqualStrings("new", b.get(.{ .namespace = "java.property", .name = "foo" }).?);
}
test "unique means exact structured occurrence; raw never recognized" {
    var b = try Builder.init(test_allocator, "java");
    defer b.deinit();
    var unique = agent;
    unique.merge = .unique;
    try b.add(unique, "a.jar");
    try b.add(heap, "2G");
    try b.add(unique, "a.jar");
    try b.add(unique, "b.jar");
    try b.addRaw("-Xmx1G");
    try b.add(heap, "4G");
    try expectArgv(&b, &.{ "java", "-javaagent:a.jar", "-Xmx4G", "-javaagent:b.jar", "-Xmx1G" });
    try std.testing.expectEqual(@as(usize, 2), b.remove(agent.key));
    try std.testing.expectEqual(@as(usize, 1), b.remove(heap.key));
    try expectArgv(&b, &.{ "java", "-Xmx1G" });
}
test "strict arity empty values and state unchanged on invalid calls" {
    var b = try Builder.init(test_allocator, "java");
    defer b.deinit();
    const flag: Spec = .{ .key = .{ .name = "flag" }, .canonical = "--flag", .arity = .flag, .layout = .flag };
    try b.add(flag, null);
    try b.add(flag, null);
    try b.add(heap, "");
    try std.testing.expectError(error.UnexpectedValue, b.add(flag, "yes"));
    try std.testing.expectError(error.MissingValue, b.add(heap, null));
    var invalid = heap;
    invalid.layout = .flag;
    try std.testing.expectError(error.InvalidSpec, b.add(invalid, "4G"));
    try std.testing.expect(b.has(flag.key));
    try std.testing.expect(b.get(flag.key) == null);
    try std.testing.expectEqualStrings("", b.get(heap.key).?);
    try expectArgv(&b, &.{ "java", "--flag", "-Xmx" });
    b.clear();
    try expectArgv(&b, &.{"java"});
}
test "owned argv survives mutation and destruction; display is POSIX quoted" {
    var snapshot: OwnedArgv = undefined;
    {
        var b = try Builder.init(test_allocator, "java");
        defer b.deinit();
        try b.addRaw("Steve Jobs");
        try b.addRaw("");
        snapshot = try b.renderOwned(test_allocator);
        const display = try b.renderToString(test_allocator);
        defer test_allocator.free(display);
        try std.testing.expectEqualStrings("java 'Steve Jobs' ''", display);
        b.clear();
    }
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("Steve Jobs", snapshot.argv[1]);
    try std.testing.expectEqualStrings("", snapshot.argv[2]);
}
test "failed replacement preserves existing argv and value at every allocation" {
    var succeeded = false;
    for (0..32) |failure_offset| {
        var failing = std.testing.FailingAllocator.init(test_allocator, .{});
        var b = try Builder.init(failing.allocator(), "java");
        defer b.deinit();
        try b.add(heap, "2G");
        failing.fail_index = failing.alloc_index + failure_offset;
        const big: [8192]u8 = @splat('4');
        b.add(heap, &big) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqualStrings("2G", b.get(heap.key).?);
            try expectArgv(&b, &.{ "java", "-Xmx2G" });
            continue;
        };
        succeeded = true;
        break;
    }
    try std.testing.expect(succeeded);
}
fn allocationCase(a: Allocator) !void {
    var b = try Builder.init(a, "java");
    defer b.deinit();
    try b.add(heap, "2G");
    try b.add(agent, "agent.jar");
    try b.addRaw("main.Class");
    try b.add(heap, "4G");
    var argv = try b.renderOwned(a);
    defer argv.deinit();
    const display = try b.renderToString(a);
    defer a.free(display);
}
test "removal accepts borrowed key and preserves remaining order" {
    var b = try Builder.init(test_allocator, "java");
    defer b.deinit();
    try b.add(agent, "a.jar");
    try b.add(heap, "2G");
    try b.add(agent, "b.jar");
    try b.addRaw("main.Class");
    const borrowed = b.occurrences.items[0].key.?;
    try std.testing.expectEqual(@as(usize, 2), b.remove(borrowed));
    try expectArgv(&b, &.{ "java", "-Xmx2G", "main.Class" });
}

test "all allocation failure paths clean up" {
    try @import("test_allocations").checkAllAllocationFailures(test_allocator, allocationCase, .{});
}
