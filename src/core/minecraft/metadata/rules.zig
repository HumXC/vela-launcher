//! Ordered Minecraft rules. OS version regex requires an explicit matcher.
const std = @import("std");
const j = @import("json.zig");
const owned = @import("owned.zig");
pub const Action = enum { allow, disallow };
pub const Os = struct { name: ?[]const u8 = null, arch: ?[]const u8 = null, version: ?[]const u8 = null };
pub const Feature = struct { name: []const u8, enabled: bool };
pub const Rule = struct { action: Action, os: ?Os, features: []const Feature };
pub const Matcher = struct {
    context: ?*anyopaque = null,
    /// Must implement Minecraft/Java regex matching semantics; errors propagate.
    matches: *const fn (?*anyopaque, []const u8, []const u8) anyerror!bool,
};
pub const Environment = struct {
    os_name: []const u8,
    arch: []const u8,
    os_version: []const u8 = "",
    features: []const Feature = &.{},
    version_matcher: ?Matcher = null,
};
pub fn decode(a: j.A, v: j.V) !Rule {
    const action_text = try j.text(a, v, "action");
    const action = std.meta.stringToEnum(Action, action_text) orelse return error.InvalidRuleAction;
    var os: ?Os = null;
    if (try j.optional(v, "os")) |o| os = .{ .name = try j.maybeText(a, o, "name"), .arch = try j.maybeText(a, o, "arch"), .version = try j.maybeText(a, o, "version") };
    var features: []const Feature = &.{};
    if (try j.optional(v, "features")) |f| {
        const map = try j.object(f);
        const out = try a.alloc(Feature, map.count());
        var it = map.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) out[i] = .{ .name = try a.dupe(u8, entry.key_ptr.*), .enabled = try j.boolean(entry.value_ptr.*) };
        features = out;
    }
    return .{ .action = action, .os = os, .features = features };
}
pub fn decodeList(a: j.A, v: j.V) ![]const Rule {
    return j.list(Rule, a, v, decode);
}
pub fn parseSlice(a: j.A, bytes: []const u8) !owned.Owned([]const Rule) {
    return owned.fromSlice([]const Rule, a, bytes, decodeList);
}
pub fn parseValue(a: j.A, value: j.V) !owned.Owned([]const Rule) {
    return owned.fromValue([]const Rule, a, value, decodeList);
}
/// null (absent rules) allows; a present empty array denies.
pub fn allows(rules: ?[]const Rule, env: Environment) !bool {
    const list = rules orelse return true;
    var allowed = false;
    for (list) |rule| if (try matches(rule, env)) {
        allowed = rule.action == .allow;
    };
    return allowed;
}
fn matches(rule: Rule, env: Environment) !bool {
    if (rule.os) |os| {
        if (os.name) |s| if (!std.mem.eql(u8, s, env.os_name)) return false;
        if (os.arch) |s| if (!std.mem.eql(u8, s, env.arch)) return false;
    }
    for (rule.features) |feature| {
        var actual = false;
        for (env.features) |f| if (std.mem.eql(u8, f.name, feature.name)) {
            actual = f.enabled;
            break;
        };
        if (actual != feature.enabled) return false;
    }
    if (rule.os) |os| if (os.version) |pattern| {
        const matcher = env.version_matcher orelse return error.RegexMatcherRequired;
        if (!try matcher.matches(matcher.context, pattern, env.os_version)) return false;
    };
    return true;
}
test "ordered rules, absent vs empty, missing features and regex injection" {
    const a = std.testing.allocator;
    var parsed = try parseSlice(a, "[{\"action\":\"allow\"},{\"action\":\"disallow\",\"os\":{\"name\":\"windows\"}},{\"action\":\"allow\",\"features\":{\"unknown\":false}}]");
    defer parsed.deinit();
    const env: Environment = .{ .os_name = "windows", .arch = "x86_64" };
    try std.testing.expect(try allows(null, env));
    try std.testing.expect(!try allows(&.{}, env));
    try std.testing.expect(!try allows(parsed.value[0..2], env));
    try std.testing.expect(try allows(parsed.value, env));
    var regex = try parseSlice(a, "[{\"action\":\"allow\",\"os\":{\"version\":\"^10.*\"}}]");
    defer regex.deinit();
    try std.testing.expectError(error.RegexMatcherRequired, allows(regex.value, env));
    const M = struct {
        fn check(_: ?*anyopaque, p: []const u8, value: []const u8) !bool {
            try std.testing.expectEqualStrings("^10.*", p);
            return std.mem.eql(u8, value, "10.0");
        }
    };
    try std.testing.expect(try allows(regex.value, .{ .os_name = "windows", .arch = "x86_64", .os_version = "10.0", .version_matcher = .{ .matches = M.check } }));
    try std.testing.expectError(error.ExpectedBoolean, parseSlice(a, "[{\"action\":\"allow\",\"features\":{\"demo\":1}}]"));
    try std.testing.expectError(error.InvalidRuleAction, parseSlice(a, "[{\"action\":\"maybe\"}]"));
}
