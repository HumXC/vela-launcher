const std = @import("std");
const builtin = @import("builtin");
const process = @import("loaders_java_process.zig");
const common = @import("loaders_common.zig");
const execute = @import("loaders_execute.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn now(_: ?*anyopaque) u64 {
    return @intCast(@divTrunc(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}
fn control(ms: u64) common.Control {
    return .{ .deadline_ms = now(null) + ms, .now_ms = now };
}
fn nativeOnly() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
}
fn fixture() ![]const u8 {
    const path = std.c.getenv("VELA_JAVA_PROCESS_FIXTURE") orelse return error.MissingNativeProcessFixture;
    return std.mem.span(path);
}
fn rootPath(tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [4096]u8 = undefined;
    return a.dupe(u8, buffer[0..try tmp.dir.realPath(io, &buffer)]);
}
fn invocation(java: []const u8, root: []const u8, mode: []const u8, args: []const []const u8) execute.Invocation {
    return .{ .java = java, .main_class = mode, .classpath = &.{ "lib one.jar", "lib-two.jar" }, .args = args, .working_directory = root, .control = control(3000) };
}
fn pidAt(path: []const u8) !std.posix.pid_t {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(32));
    defer a.free(bytes);
    return std.fmt.parseInt(std.posix.pid_t, bytes, 10);
}
fn expectReaped(pid: std.posix.pid_t) !void {
    var status: c_int = undefined;
    const rc = std.c.waitpid(pid, &status, std.posix.W.NOHANG);
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(rc));
}
fn script(dir: std.Io.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
    try file.setPermissions(io, .fromMode(0o755));
}

test "direct argv classpath and cwd remain literal" {
    try nativeOnly();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const pid_path = try std.fs.path.join(a, &.{ root, "literal.pid" });
    defer a.free(pid_path);
    const args = [_][]const u8{ pid_path, "", "has space", "$(touch forbidden);&|*?", "\"quoted\"", "-leading" };
    const result = try process.run(a, io, invocation(try fixture(), root, "argsliteral", &args));
    try std.testing.expectEqual(@as(u8, 0), result.exited);
    try expectReaped(try pidAt(pid_path));
}

test "concurrent stdout stderr flood is bounded and children reaped" {
    try nativeOnly();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const pid_path = try std.fs.path.join(a, &.{ root, "flood.pid" });
    defer a.free(pid_path);
    var call = invocation(try fixture(), root, "floodboth", &.{pid_path});
    try std.testing.expectEqual(@as(u8, 0), (try process.run(a, io, call)).exited);
    try expectReaped(try pidAt(pid_path));
    call.max_output_bytes = 16384;
    try std.testing.expectEqual(execute.ProcessResult.output_limit, try process.run(a, io, call));
    try expectReaped(try pidAt(pid_path));
}

test "failed exit and signal results preserve terminal status" {
    try nativeOnly();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const pid_path = try std.fs.path.join(a, &.{ root, "failed.pid" });
    defer a.free(pid_path);
    const failed = try process.run(a, io, invocation(try fixture(), root, "failedexit", &.{pid_path}));
    try std.testing.expectEqual(@as(u8, 17), failed.exited);
    try expectReaped(try pidAt(pid_path));
    const signaled = try process.run(a, io, invocation(try fixture(), root, "signal", &.{pid_path}));
    try std.testing.expectEqual(@as(u32, @intFromEnum(std.posix.SIG.TERM)), signaled.signaled);
    try expectReaped(try pidAt(pid_path));
}

test "deadline kills and reaps with open and closed output pipes" {
    try nativeOnly();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const pid_path = try std.fs.path.join(a, &.{ root, "deadline.pid" });
    defer a.free(pid_path);
    for ([_][]const u8{ "hang", "closedhang" }) |mode| {
        var call = invocation(try fixture(), root, mode, &.{pid_path});
        call.control = control(120);
        const start = now(null);
        try std.testing.expectEqual(execute.ProcessResult.deadline, try process.run(a, io, call));
        try std.testing.expect(now(null) - start < 1500);
        try expectReaped(try pidAt(pid_path));
    }
}
const Cancel = struct {
    flag: *std.atomic.Value(bool),
    fn worker(self: Cancel) void {
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch return;
        self.flag.store(true, .release);
    }
};
test "midrun cancellation kills and reaps" {
    try nativeOnly();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const pid_path = try std.fs.path.join(a, &.{ root, "cancel.pid" });
    defer a.free(pid_path);
    var flag: std.atomic.Value(bool) = .init(false);
    var call = invocation(try fixture(), root, "closedhang", &.{pid_path});
    call.control.cancel = &flag;
    var future = try io.concurrent(Cancel.worker, .{Cancel{ .flag = &flag }});
    defer future.cancel(io);
    try std.testing.expectEqual(execute.ProcessResult.canceled, try process.run(a, io, call));
    try expectReaped(try pidAt(pid_path));
}

test "missing executable and cwd leave no waitable child" {
    try nativeOnly();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const missing = try std.fs.path.join(a, &.{ root, "missing" });
    defer a.free(missing);
    try std.testing.expectError(error.FileNotFound, process.run(a, io, invocation(missing, root, "missing", &.{})));
    try std.testing.expectError(error.FileNotFound, process.run(a, io, invocation(try fixture(), missing, "missing", &.{})));
    var status: c_int = undefined;
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(std.c.waitpid(-1, &status, std.posix.W.NOHANG)));
    try std.testing.expectError(error.FileNotFound, process.probe(a, io, missing, control(3000)));
}

test "actual Java major reprobe handles legacy modern and fallback fixtures" {
    try nativeOnly();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "fake java" });
    defer a.free(path);
    const scripts = [_][]const u8{
        "#!/bin/sh\nprintf '%s\\n' 'java version \"1.8.0_402\"' >&2\n",
        "#!/bin/sh\nprintf '%s\\n' 'openjdk version \"21.0.2\" 2024-01-16' >&2\n",
        "#!/bin/sh\nif [ \"$1\" = -version ]; then exit 2; fi\nprintf '%s\\n' 'openjdk 25-ea 2025-09-16'\n",
    };
    for (scripts, [_]u64{ 8, 21, 25 }) |content, want| {
        try script(tmp.dir, "fake java", content);
        try std.testing.expectEqual(want, try process.probe(a, io, path, control(3000)));
    }
    try script(tmp.dir, "fake java", "#!/bin/sh\nprintf '%s\\n' 'openjdk version \"not-java\"' >&2\n");
    try std.testing.expectError(error.InvalidJavaVersion, process.probe(a, io, path, control(3000)));
    try script(tmp.dir, "fake java", "#!/bin/sh\nexit 5\n");
    try std.testing.expectError(error.JavaProbeFailed, process.probe(a, io, path, control(3000)));
}

test "preflight cancellation deadline and NUL validation do not spawn" {
    try nativeOnly();
    var flag: std.atomic.Value(bool) = .init(true);
    var c = control(3000);
    c.cancel = &flag;
    try std.testing.expectError(error.Canceled, process.probe(a, io, "/does-not-exist", c));
    c = control(0);
    try std.testing.expectError(error.DeadlineExceeded, process.probe(a, io, "/does-not-exist", c));
    try std.testing.expectError(error.InvalidProcessArgument, process.probe(a, io, "path\x00suffix", control(3000)));
}

test "cross target adapter semantic references" {
    // Kept outside the runtime platform guard so -fno-emit-bin checks both APIs.
    var flag: std.atomic.Value(bool) = .init(true);
    var c = control(1);
    c.cancel = &flag;
    _ = process.probe(a, io, "synthetic-never-spawned", c) catch {};
    _ = process.run(a, io, .{ .java = "synthetic-never-spawned", .main_class = "Main", .classpath = &.{"library.jar"}, .args = &.{}, .working_directory = ".", .control = c }) catch {};
}

test "Java reprobe bounds both pipes and terminates stubborn children" {
    try nativeOnly();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "fake java" });
    defer a.free(path);
    const pid_path = try std.mem.concat(a, u8, &.{ path, ".pid" });
    defer a.free(pid_path);
    try script(tmp.dir, "fake java", "#!/bin/sh\nprintf '%s' \"$$\" > \"$0.pid\"\ntrap '' TERM\nwhile :; do printf '%s' 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; printf '%s' 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy' >&2; done\n");
    try std.testing.expectError(error.JavaProbeOutputLimit, process.probe(a, io, path, control(3000)));
    try expectReaped(try pidAt(pid_path));
    try script(tmp.dir, "fake java", "#!/bin/sh\nprintf '%s' \"$$\" > \"$0.pid\"\ntrap '' TERM\nprintf '%s\\n' 'openjdk version \"21.0.2\"' >&2\nexec 1>&- 2>&-\nwhile :; do :; done\n");
    try std.testing.expectError(error.DeadlineExceeded, process.probe(a, io, path, control(120)));
    try expectReaped(try pidAt(pid_path));
    var flag: std.atomic.Value(bool) = .init(false);
    var c = control(3000);
    c.cancel = &flag;
    var future = try io.concurrent(Cancel.worker, .{Cancel{ .flag = &flag }});
    defer future.cancel(io);
    try std.testing.expectError(error.Canceled, process.probe(a, io, path, c));
    try expectReaped(try pidAt(pid_path));
}

fn allocationFailureCase(allocator: std.mem.Allocator, root: []const u8, missing: []const u8) !void {
    _ = process.run(allocator, io, invocation(missing, root, "Main", &.{})) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.UnexpectedSpawnSuccess;
}

test "allocation failures clean up argv environment and prepared pipes" {
    try nativeOnly();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootPath(&tmp);
    defer a.free(root);
    const missing = try std.fs.path.join(a, &.{ root, "missing" });
    defer a.free(missing);
    try std.testing.checkAllAllocationFailures(a, allocationFailureCase, .{ root, missing });
    var status: c_int = undefined;
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(std.c.waitpid(-1, &status, std.posix.W.NOHANG)));
}
