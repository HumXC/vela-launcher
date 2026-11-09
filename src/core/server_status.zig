//! Owned Minecraft status data; no UI or network dependency.
const std = @import("std");
const icons = @import("server_icon.zig");
const Allocator = std.mem.Allocator;
pub const max_json_bytes = 96 * 1024;
pub const max_motd_bytes = 16 * 1024;
pub const Connection = struct { host: []const u8, port: u16, used_srv: bool };
pub const OwnedStatus = struct {
    arena: std.heap.ArenaAllocator,
    version: []const u8,
    protocol: i32,
    players_online: ?u32,
    players_max: ?u32,
    motd: []const u8,
    /// Original owned component, including styles and translation arguments.
    description: std.json.Value,
    icon: ?icons.Icon = null,
    icon_issue: ?anyerror = null,
    motd_issue: ?anyerror = null,
    latency_ms: ?u64 = null,
    latency_issue: ?anyerror = null,
    connection: ?Connection = null,
    pub fn deinit(self: *OwnedStatus) void {
        if (self.icon) |*icon| icon.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};
fn object(value: std.json.Value) !std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidStatus;
}
fn string(value: std.json.Value) ![]const u8 {
    if (value != .string or !std.unicode.utf8ValidateSlice(value.string)) return error.InvalidStatus;
    return value.string;
}
fn count(value: std.json.Value) !u32 {
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return error.InvalidStatus;
    return @intCast(value.integer);
}
fn append(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidStatus;
    if (text.len > max_motd_bytes - out.items.len) return error.MotdTooLarge;
    try out.appendSlice(a, text);
}
fn flatten(a: Allocator, out: *std.ArrayList(u8), value: std.json.Value, depth: u8) anyerror!void {
    if (depth > 32) return error.InvalidStatus;
    switch (value) {
        .string => |text| try append(a, out, text),
        .array => |items| for (items.items) |item| try flatten(a, out, item, depth + 1),
        .object => |fields| {
            if (fields.get("text")) |text| {
                try append(a, out, try string(text));
            } else if (fields.get("translate")) |key| {
                const translation_key = try string(key);
                const arguments = if (fields.get("with")) |args| if (args == .array) args.array.items else return error.InvalidStatus else &.{};
                if (fields.get("fallback")) |fallback| {
                    try formatTranslation(a, out, try string(fallback), arguments, depth);
                } else {
                    // No language catalog in the network layer. Keep a readable
                    // projection without dropping arguments; original stays intact.
                    try append(a, out, translation_key);
                    for (arguments) |arg| {
                        try append(a, out, " ");
                        try flattenArgument(a, out, arg, depth + 1);
                    }
                }
            } else if (fields.get("keybind")) |key| {
                try append(a, out, try string(key));
            } else if (fields.get("selector")) |selector| {
                try append(a, out, try string(selector));
            } else if (fields.get("score")) |score| {
                const fields_score = try object(score);
                if (fields_score.get("value")) |v| try append(a, out, try string(v));
            }
            if (fields.get("extra")) |extra| {
                if (extra != .array) return error.InvalidStatus;
                try flatten(a, out, extra, depth + 1);
            }
        },
        else => return error.InvalidStatus,
    }
}
fn flattenArgument(a: Allocator, out: *std.ArrayList(u8), value: std.json.Value, depth: u8) anyerror!void {
    switch (value) {
        .integer, .float, .bool, .null => {
            const text = try std.json.Stringify.valueAlloc(a, value, .{});
            defer a.free(text);
            try append(a, out, text);
        },
        else => try flatten(a, out, value, depth),
    }
}
fn formatTranslation(a: Allocator, out: *std.ArrayList(u8), format: []const u8, args: []const std.json.Value, depth: u8) anyerror!void {
    var index: usize = 0;
    var next_arg: usize = 0;
    while (index < format.len) {
        if (format[index] != '%') {
            const end = std.mem.indexOfScalarPos(u8, format, index, '%') orelse format.len;
            try append(a, out, format[index..end]);
            index = end;
            continue;
        }
        const start = index;
        index += 1;
        if (index < format.len and format[index] == '%') {
            try append(a, out, "%");
            index += 1;
            continue;
        }
        const digits = index;
        while (index < format.len and std.ascii.isDigit(format[index])) : (index += 1) {}
        var arg_index = next_arg;
        const positional = index > digits;
        if (positional) {
            if (index == format.len or format[index] != '$') return error.InvalidStatus;
            const position = std.fmt.parseInt(usize, format[digits..index], 10) catch return error.InvalidStatus;
            if (position == 0) return error.InvalidStatus;
            arg_index = position - 1;
            index += 1;
        }
        if (index == format.len or format[index] != 's' or arg_index >= args.len) {
            try append(a, out, format[start..index]);
            continue;
        }
        index += 1;
        if (!positional) next_arg += 1;
        try flattenArgument(a, out, args[arg_index], depth + 1);
    }
}
/// Plain projection strips legacy formatting while preserving the source tree.
pub fn plainText(a: Allocator, component: std.json.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try flatten(a, &out, component, 0);
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < out.items.len) {
        if (read_index + 2 < out.items.len and out.items[read_index] == 0xc2 and out.items[read_index + 1] == 0xa7 and std.ascii.isAscii(out.items[read_index + 2])) {
            read_index += 3;
        } else {
            out.items[write_index] = out.items[read_index];
            read_index += 1;
            write_index += 1;
        }
    }
    out.items.len = write_index;
    return out.toOwnedSlice(a);
}
pub fn parseStatus(allocator: Allocator, json: []const u8) !OwnedStatus {
    if (json.len > max_json_bytes) return error.PacketTooLarge;
    if (!std.unicode.utf8ValidateSlice(json)) return error.InvalidJson;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{ .allocate = .alloc_always, .max_value_len = max_json_bytes }) catch |err| return if (err == error.OutOfMemory) err else error.InvalidJson;
    const root = try object(value);
    const version = try object(root.get("version") orelse return error.InvalidStatus);
    const name = try string(version.get("name") orelse return error.InvalidStatus);
    if (name.len > 1024) return error.InvalidStatus;
    const protocol = version.get("protocol") orelse return error.InvalidStatus;
    if (protocol != .integer or protocol.integer < std.math.minInt(i32) or protocol.integer > std.math.maxInt(i32)) return error.InvalidStatus;
    var online: ?u32 = null;
    var maximum: ?u32 = null;
    if (root.get("players")) |players_value| {
        const players = try object(players_value);
        if (players.get("online")) |v| online = try count(v);
        if (players.get("max")) |v| maximum = try count(v);
    }
    const description = root.get("description") orelse std.json.Value{ .string = "" };
    var motd_issue: ?anyerror = null;
    const motd = plainText(a, description) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        motd_issue = err;
        break :blk "";
    };
    var icon_issue: ?anyerror = null;
    const icon: ?icons.Icon = if (root.get("favicon")) |v| blk: {
        if (v != .string) {
            icon_issue = error.InvalidIcon;
            break :blk null;
        }
        break :blk icons.decode(allocator, v.string) catch |err| {
            if (err == error.OutOfMemory) return err;
            icon_issue = err;
            break :blk null;
        };
    } else null;
    return .{ .arena = arena, .version = name, .protocol = @intCast(protocol.integer), .players_online = online, .players_max = maximum, .motd = motd, .description = description, .icon = icon, .icon_issue = icon_issue, .motd_issue = motd_issue };
}
