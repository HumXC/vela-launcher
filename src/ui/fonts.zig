const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
pub const family = "Vela UI";
const max_font_bytes = 32 * 1024 * 1024;
const windows_names = [_][]const u8{ "msyh.ttc", "msyhl.ttc", "msjh.ttc", "simsun.ttc", "simhei.ttf", "deng.ttf" };
const mac_paths = [_][]const u8{
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/Library/Fonts/Arial Unicode.ttf",
};

/// DVUI owns successful registrations and releases their bytes with the window.
pub fn install(win: *dvui.Window) !void {
    const init = dvui.App.main_init orelse return error.MissingAppInit;
    const explicit = init.environ_map.get("VELA_FONT_PATH");
    const loaded = if (explicit) |path|
        try load(init.gpa, init.io, path)
    else
        discover(init.gpa, init.io, init.environ_map) catch |err| {
            std.log.warn("No automatic CJK UI font available ({t}); keeping DVUI default font. VELA_FONT_PATH can select a font", .{err});
            return;
        };
    defer init.gpa.free(loaded.path);
    win.addFont(family, loaded.bytes, init.gpa) catch |err| {
        init.gpa.free(loaded.bytes);
        if (explicit != null) return err;
        std.log.warn("Cannot register CJK UI font {s} ({t}); keeping DVUI default font", .{ loaded.path, err });
        return;
    };
    std.log.info("Loaded CJK UI font {s}", .{loaded.path});
}

const Loaded = struct { path: []u8, bytes: []u8 };
fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !Loaded {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_font_bytes));
    errdefer a.free(bytes);
    if (bytes.len == 0) return error.EmptyFont;
    return .{ .path = try a.dupe(u8, path), .bytes = bytes };
}

fn firstReadable(a: std.mem.Allocator, io: std.Io, paths: []const []const u8) !Loaded {
    for (paths) |path| {
        return load(a, io, path) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => continue,
        };
    }
    return error.ChineseFontNotFound;
}

fn discover(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !Loaded {
    switch (builtin.os.tag) {
        .windows => {
            const root = try windowsRoot(a, environ);
            defer a.free(root);
            var paths: [windows_names.len][]u8 = undefined;
            var count: usize = 0;
            defer for (paths[0..count]) |path| a.free(path);
            for (windows_names, &paths) |name, *path| {
                path.* = try std.fs.path.join(a, &.{ root, "Fonts", name });
                count += 1;
            }
            return firstReadable(a, io, &paths);
        },
        .macos => return firstReadable(a, io, &mac_paths),
        .linux => {
            const result = try std.process.run(a, io, .{
                .argv = &.{ "fc-match", "-f", "%{file}", ":lang=zh-cn" },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(4096),
            });
            defer a.free(result.stdout);
            defer a.free(result.stderr);
            switch (result.term) {
                .exited => |code| if (code != 0) return error.ChineseFontNotFound,
                else => return error.ChineseFontNotFound,
            }
            const path = std.mem.trim(u8, result.stdout, " \r\n\t");
            if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.ChineseFontNotFound;
            return load(a, io, path);
        },
        else => return error.ChineseFontNotFound,
    }
}

fn windowsEnvironmentRoot(environ: *const std.process.Environ.Map) ?[]const u8 {
    for ([_][]const u8{ "WINDIR", "SystemRoot" }) |key| {
        if (environ.get(key)) |root| {
            if (root.len <= 32767 and std.mem.indexOfScalar(u8, root, 0) == null and std.fs.path.isAbsoluteWindows(root)) return root;
        }
    }
    return null;
}

extern "kernel32" fn GetWindowsDirectoryW(buffer: [*]u16, size: u32) callconv(.winapi) u32;
fn windowsRoot(a: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (windowsEnvironmentRoot(environ)) |root| return a.dupe(u8, root);
    if (builtin.os.tag != .windows) return error.ChineseFontNotFound;
    var buffer: [32768]u16 = undefined;
    const length = GetWindowsDirectoryW(&buffer, buffer.len);
    if (length == 0 or length >= buffer.len) return error.ChineseFontNotFound;
    const root = try std.unicode.utf16LeToUtf8Alloc(a, buffer[0..length]);
    errdefer a.free(root);
    if (!std.fs.path.isAbsoluteWindows(root)) return error.ChineseFontNotFound;
    return root;
}

test "Windows font root accepts absolute environment paths only" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try std.testing.expect(windowsEnvironmentRoot(&environ) == null);
    try environ.put("WINDIR", "relative");
    try environ.put("SystemRoot", "D:\\Windows");
    try std.testing.expectEqualStrings("D:\\Windows", windowsEnvironmentRoot(&environ).?);
    try environ.put("WINDIR", "C:\\Windows");
    try std.testing.expectEqualStrings("C:\\Windows", windowsEnvironmentRoot(&environ).?);
}

test "font probing skips missing and empty candidates but explicit loading fails" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.ttf", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "font.ttf", .data = "font fixture bytes" });
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const missing = try std.fs.path.join(a, &.{ root, "missing.ttf" });
    defer a.free(missing);
    const empty = try std.fs.path.join(a, &.{ root, "empty.ttf" });
    defer a.free(empty);
    const font = try std.fs.path.join(a, &.{ root, "font.ttf" });
    defer a.free(font);
    try std.testing.expectError(error.FileNotFound, load(a, io, missing));
    try std.testing.expectError(error.EmptyFont, load(a, io, empty));
    try std.testing.expectError(error.ChineseFontNotFound, firstReadable(a, io, &.{ missing, empty }));
    const loaded = try firstReadable(a, io, &.{ missing, empty, font });
    defer a.free(loaded.path);
    defer a.free(loaded.bytes);
    try std.testing.expectEqualStrings(font, loaded.path);
    try std.testing.expectEqualStrings("font fixture bytes", loaded.bytes);
}
