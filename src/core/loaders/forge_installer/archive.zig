//! Shared archive implementation is passed as a comptime module so standalone
//! loader checks don't change the application's build/import graph. Production:
//! extractInstaller(@import("../../safe_archive.zig"), a, io, path, empty_dir, .{}, ctl).
const std = @import("std");
const c = @import("../common.zig");
pub fn extractInstaller(comptime archive: type, a: std.mem.Allocator, io: std.Io, path: []const u8, destination: std.Io.Dir, limits: archive.Limits, control: c.Control) !archive.Result {
    try control.check();
    var result = try archive.extract(a, io, path, destination, .zip, limits, control.cancel);
    errdefer result.deinit(a);
    try control.check();
    return result;
}
