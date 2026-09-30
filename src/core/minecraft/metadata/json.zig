//! Strict field helpers. Unknown members are ignored by each schema decoder.
const std = @import("std");
pub const A = std.mem.Allocator;
pub const V = std.json.Value;
pub const Sha1 = [20]u8;
pub fn object(v: V) !std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.ExpectedObject,
    };
}
pub fn array(v: V) ![]const V {
    return switch (v) {
        .array => |a| a.items,
        else => error.ExpectedArray,
    };
}
pub fn required(v: V, name: []const u8) !V {
    return (try object(v)).get(name) orelse error.MissingField;
}
pub fn optional(v: V, name: []const u8) !?V {
    return (try object(v)).get(name);
}
pub fn string(a: A, v: V) ![]const u8 {
    return switch (v) {
        .string => |s| a.dupe(u8, s),
        else => error.ExpectedString,
    };
}
pub fn text(a: A, v: V, name: []const u8) ![]const u8 {
    return string(a, try required(v, name));
}
pub fn maybeText(a: A, v: V, name: []const u8) !?[]const u8 {
    return if (try optional(v, name)) |x| try string(a, x) else null;
}
pub fn boolean(v: V) !bool {
    return switch (v) {
        .bool => |b| b,
        else => error.ExpectedBoolean,
    };
}
pub fn uint(v: V) !u64 {
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else error.InvalidInteger,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch error.InvalidInteger,
        else => error.ExpectedInteger,
    };
}
pub fn maybeUint(v: V, name: []const u8) !?u64 {
    return if (try optional(v, name)) |x| try uint(x) else null;
}
pub fn sha1(v: V) !Sha1 {
    const s = switch (v) {
        .string => |s| s,
        else => return error.ExpectedString,
    };
    if (s.len != 40) return error.InvalidSha1;
    var result: Sha1 = undefined;
    _ = std.fmt.hexToBytes(&result, s) catch return error.InvalidSha1;
    return result;
}
pub fn maybeSha1(v: V, name: []const u8) !?Sha1 {
    return if (try optional(v, name)) |x| try sha1(x) else null;
}
pub fn strings(a: A, v: V) ![]const []const u8 {
    const input = try array(v);
    const result = try a.alloc([]const u8, input.len);
    for (input, result) |x, *out| out.* = try string(a, x);
    return result;
}
pub fn list(comptime T: type, a: A, v: V, comptime decode: anytype) ![]const T {
    const input = try array(v);
    const result = try a.alloc(T, input.len);
    for (input, result) |x, *out| out.* = try decode(a, x);
    return result;
}
pub const StringEntry = struct { key: []const u8, value: []const u8 };
pub fn stringMap(a: A, v: V) ![]const StringEntry {
    const map = try object(v);
    const out = try a.alloc(StringEntry, map.count());
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) out[i] = .{ .key = try a.dupe(u8, e.key_ptr.*), .value = try string(a, e.value_ptr.*) };
    return out;
}
