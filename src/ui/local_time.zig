const std = @import("std");
const builtin = @import("builtin");

// The native C tm layouts on Linux (glibc/musl), macOS, and Windows.
// POSIX includes the trailing timezone fields even though formatting uses only
// the calendar fields. Omitting them would let localtime_r overwrite the stack.
const PosixTm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

const WindowsTm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
};

extern "c" fn localtime_r(timer: *const std.c.time_t, result: *PosixTm) ?*PosixTm;
extern "c" fn _localtime64_s(result: *WindowsTm, timer: *const i64) c_int;

/// Format Unix milliseconds in the OS local timezone, including DST.
/// The returned YYYY-MM-DD HH:MM slice borrows buffer (at least 16 bytes).
/// Negative timestamps, unsupported dates/platforms, and short buffers return null.
/// Requires libc; conversion uses caller-owned storage and no environment mutation.
pub fn format(buffer: []u8, milliseconds: i64) ?[]const u8 {
    if (buffer.len < 16 or milliseconds < 0) return null;
    const seconds = @divTrunc(milliseconds, 1000);
    const Tm = if (builtin.os.tag == .windows) WindowsTm else PosixTm;
    var local: Tm = undefined;
    switch (builtin.os.tag) {
        .linux, .macos => {
            const timer = std.math.cast(std.c.time_t, seconds) orelse return null;
            _ = localtime_r(&timer, &local) orelse return null;
        },
        .windows => {
            // The CRT supports dates only through 3000-12-31 23:59:59 UTC.
            if (seconds > 32535215999) return null;
            if (_localtime64_s(&local, &seconds) != 0) return null;
        },
        else => return null,
    }
    const year = @as(i64, local.year) + 1900;
    if (year < 0 or year > 9999 or local.mon < 0 or local.mon > 11 or
        local.mday < 1 or local.mday > 31 or local.hour < 0 or local.hour > 23 or
        local.min < 0 or local.min > 59) return null;

    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        @as(u16, @intCast(year)),
        @as(u8, @intCast(local.mon + 1)),
        @as(u8, @intCast(local.mday)),
        @as(u8, @intCast(local.hour)),
        @as(u8, @intCast(local.min)),
    }) catch null;
}

test "invalid timestamps and short buffers are unknown" {
    var buffer: [16]u8 = undefined;
    try std.testing.expect(format(&buffer, -1) == null);
    try std.testing.expect(format(&buffer, std.math.minInt(i64)) == null);
    try std.testing.expect(format(&buffer, std.math.maxInt(i64)) == null);
    try std.testing.expect(format(buffer[0..15], 1705320000000) == null);
}

test "local timestamp fits exactly and ignores subsecond precision" {
    var buffer: [16]u8 = undefined;
    const result = format(&buffer, 1705320000000) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(@as(usize, 16), result.len);
    try std.testing.expect(result.ptr == buffer[0..].ptr);
    try std.testing.expectEqualStrings("2024-", result[0..5]);
    try std.testing.expectEqual(@as(u8, '-'), result[7]);
    try std.testing.expectEqual(@as(u8, ' '), result[10]);
    try std.testing.expectEqual(@as(u8, ':'), result[13]);
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15 }) |i| {
        try std.testing.expect(std.ascii.isDigit(result[i]));
    }
    var fractional: [16]u8 = undefined;
    try std.testing.expectEqualStrings(result, format(&fractional, 1705320000999) orelse return error.UnexpectedNull);
}
