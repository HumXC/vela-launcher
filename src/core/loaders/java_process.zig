//! Direct Java execution with bounded pipe draining and exclusive child ownership.
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const execute = @import("execute.zig");
const Allocator = std.mem.Allocator;
const Result = execute.ProcessResult;
const probe_limit = 64 * 1024;
// Linux needs libc declarations missing from std.c. Darwin uses std.c's spawn
// ABI and the small waitid surface below, avoiding unrelated Mach C translation.
const posix = if (builtin.os.tag == .linux) @import("linux_c") else DarwinWait;
const DarwinWait = struct {
    // sys/wait.h and sys/signal.h in the target Darwin libc headers.
    const P_PID = 1;
    const WEXITED = 0x00000004;
    const WNOHANG = 0x00000001;
    const WNOWAIT = 0x00000020;
    const CLD_EXITED = 1;
    const CLD_KILLED = 2;
    const CLD_DUMPED = 3;
    extern "c" fn waitid(id_type: c_uint, id: c_uint, info: *std.c.siginfo_t, flags: c_int) c_int;
};

pub fn probe(a: Allocator, io: std.Io, path: []const u8, control: common.Control) !u64 {
    try text(path, 4096);
    var capture: [2][probe_limit]u8 = undefined;
    var lengths: [2]usize = .{ 0, 0 };
    var result = try launch(a, io, &.{ path, "-version" }, .inherit, probe_limit, control, &capture, &lengths, false);
    if (result == .exited and result.exited != 0) {
        lengths = .{ 0, 0 };
        result = try launch(a, io, &.{ path, "--version" }, .inherit, probe_limit, control, &capture, &lengths, false);
    }
    switch (result) {
        .canceled => return error.Canceled,
        .deadline => return error.DeadlineExceeded,
        .output_limit => return error.JavaProbeOutputLimit,
        .signaled => return error.JavaProbeSignaled,
        .exited => |code| if (code != 0) return error.JavaProbeFailed,
    }
    try control.check();
    const first = parseMajor(capture[0][0..lengths[0]]);
    const second = parseMajor(capture[1][0..lengths[1]]);
    if (first != null and second != null and first.? != second.?) return error.InvalidJavaVersion;
    return first orelse second orelse error.InvalidJavaVersion;
}

/// Bounded tails of both processor pipes. These are diagnostics, not artifact proofs.
pub const Diagnostics = struct {
    bytes: [2][probe_limit]u8 = undefined,
    lengths: [2]usize = .{ 0, 0 },

    pub fn stdout(self: *const Diagnostics) []const u8 {
        return self.bytes[0][0..self.lengths[0]];
    }
    pub fn stderr(self: *const Diagnostics) []const u8 {
        return self.bytes[1][0..self.lengths[1]];
    }
};

pub fn run(a: Allocator, io: std.Io, invocation: execute.Invocation) !Result {
    var diagnostics: Diagnostics = .{};
    const result = runCaptured(a, io, invocation, &diagnostics) catch |err| {
        reportFailure(invocation.main_class, @errorName(err), &diagnostics);
        return err;
    };
    switch (result) {
        .exited => |code| if (code != 0) reportFailure(invocation.main_class, "nonzero exit", &diagnostics),
        .signaled, .output_limit => reportFailure(invocation.main_class, @tagName(result), &diagnostics),
        .canceled, .deadline => {},
    }
    return result;
}

pub fn runCaptured(a: Allocator, io: std.Io, invocation: execute.Invocation, diagnostics: *Diagnostics) !Result {
    diagnostics.lengths = .{ 0, 0 };
    try text(invocation.java, 4096);
    try text(invocation.main_class, 512);
    if (invocation.main_class[0] == '-') return error.InvalidProcessArgument;
    try text(invocation.working_directory, 4096);
    if (invocation.classpath.len == 0 or invocation.classpath.len > 4096 or invocation.args.len > 4096) return error.InvalidProcessArgument;
    const separator = if (builtin.os.tag == .windows) ";" else ":";
    var size: usize = invocation.classpath.len - 1;
    for (invocation.classpath) |entry| {
        try text(entry, 32768);
        if (std.mem.indexOf(u8, entry, separator) != null) return error.InvalidProcessArgument;
        size = std.math.add(usize, size, entry.len) catch return error.InvalidProcessArgument;
    }
    if (size > 1024 * 1024) return error.InvalidProcessArgument;
    var argument_bytes = size + invocation.java.len + invocation.main_class.len;
    for (invocation.args) |arg| {
        if (arg.len > 1024 * 1024 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidProcessArgument;
        argument_bytes = std.math.add(usize, argument_bytes, arg.len + 1) catch return error.InvalidProcessArgument;
    }
    if (argument_bytes > 1024 * 1024) return error.InvalidProcessArgument;
    const classpath = try std.mem.join(a, separator, invocation.classpath);
    defer a.free(classpath);
    const argv = try a.alloc([]const u8, 4 + invocation.args.len);
    defer a.free(argv);
    argv[0] = invocation.java;
    argv[1] = "-cp";
    argv[2] = classpath;
    argv[3] = invocation.main_class;
    @memcpy(argv[4..], invocation.args);
    return launch(a, io, argv, .{ .path = invocation.working_directory }, invocation.max_output_bytes, invocation.control, &diagnostics.bytes, &diagnostics.lengths, true);
}

fn text(value: []const u8, max: usize) !void {
    if (value.len == 0 or value.len > max or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidProcessArgument;
}

fn reportFailure(main_class: []const u8, reason: []const u8, diagnostics: *const Diagnostics) void {
    // Keep failure logs bounded and escape control characters from external tools.
    const stdout = diagnostics.stdout();
    const stderr = diagnostics.stderr();
    std.log.warn("Loader processor {f}: {s}; stdout={f}; stderr={f}", .{
        std.zig.fmtString(main_class),                   reason,
        std.zig.fmtString(stdout[stdout.len -| 8192..]), std.zig.fmtString(stderr[stderr.len -| 8192..]),
    });
}

fn keepOutput(output: []u8, length: *usize, bytes: []const u8, tail: bool) void {
    if (!tail) {
        const keep = @min(bytes.len, output.len - length.*);
        @memcpy(output[length.*..][0..keep], bytes[0..keep]);
        length.* += keep;
        return;
    }
    const keep = @min(bytes.len, output.len);
    const retained = @min(length.*, output.len - keep);
    std.mem.copyForwards(u8, output[0..retained], output[length.* - retained .. length.*]);
    @memcpy(output[retained..][0..keep], bytes[bytes.len - keep ..]);
    length.* = retained + keep;
}

const Budget = struct {
    remaining: std.atomic.Value(usize),
    exceeded: std.atomic.Value(bool) = .init(false),
    fn count(self: *Budget, n: usize) void {
        var left = self.remaining.load(.monotonic);
        while (true) {
            const next = left -| n;
            if (self.remaining.cmpxchgWeak(left, next, .monotonic, .monotonic)) |actual| {
                left = actual;
            } else {
                if (n > left) self.exceeded.store(true, .release);
                return;
            }
        }
    }
};
const Drain = struct {
    file: std.Io.File,
    budget: *Budget,
    output: ?[]u8,
    length: usize = 0,
    capture_tail: bool = false,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
    fn worker(self: *Drain, io: std.Io) void {
        defer self.done.store(true, .release);
        defer self.file.close(io);
        var buffer: [8192]u8 = undefined;
        while (true) {
            const n = self.file.readStreaming(io, &.{&buffer}) catch |err| {
                if (err != error.EndOfStream) self.failure = err;
                return;
            };
            if (n == 0) return;
            self.budget.count(n);
            if (self.output) |out| keepOutput(out, &self.length, buffer[0..n], self.capture_tail);
        }
    }
};
const Wait = struct {
    child: *std.process.Child,
    result: ?std.process.Child.Term = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
    fn worker(self: *Wait, io: std.Io) void {
        defer self.done.store(true, .release);
        self.result = waitOwned(self.child, io) catch |err| {
            self.failure = err;
            return;
        };
    }
};

fn launch(a: Allocator, io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd, limit: usize, control: common.Control, output: ?*[2][probe_limit]u8, lengths: ?*[2]usize, capture_tail: bool) !Result {
    if (stopped(control)) |result| return result;
    var child = try spawnOwned(a, io, argv, cwd);
    // Reap last: the unreaped group leader pins its PID/PGID until group cleanup
    // and pipe-reader joins are complete, including when the root exits first.
    defer reapOwned(&child, io);
    var budget: Budget = .{ .remaining = .init(limit) };
    var drains: [2]Drain = .{
        .{ .file = child.stdout.?, .budget = &budget, .output = if (output) |out| &out[0] else null, .capture_tail = capture_tail },
        .{ .file = child.stderr.?, .budget = &budget, .output = if (output) |out| &out[1] else null, .capture_tail = capture_tail },
    };
    child.stdout = null;
    child.stderr = null;
    var futures: [2]?std.Io.Future(void) = .{ null, null };
    // The reader tasks own the pipe handles. Kill/reap before canceling readers,
    // then allow bounded EOF draining even if one reader has already failed.
    defer {
        terminate(&child, io);
        const end = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(250));
        while (!drains[0].done.load(.acquire) or !drains[1].done.load(.acquire)) {
            if (futures[0] == null or futures[1] == null) break;
            if (std.Io.Clock.awake.now(io).nanoseconds >= end.nanoseconds) break;
            std.Io.sleep(io, .fromMilliseconds(5), .awake) catch break;
        }
        for (&futures, &drains) |*future, *drain| {
            if (future.*) |*f| {
                if (drain.done.load(.acquire)) f.await(io) else f.cancel(io);
            } else drain.file.close(io);
        }
        if (lengths) |out| out.* = .{ drains[0].length, drains[1].length };
    }
    futures[0] = try io.concurrent(Drain.worker, .{ &drains[0], io });
    futures[1] = try io.concurrent(Drain.worker, .{ &drains[1], io });
    var waiter: Wait = .{ .child = &child };
    var wait_future = try io.concurrent(Wait.worker, .{ &waiter, io });
    // Stop the observer before cleanup; it never reaps a POSIX group leader.
    defer if (waiter.done.load(.acquire)) wait_future.await(io) else wait_future.cancel(io);
    var drain_deadline: ?std.Io.Timestamp = null;
    while (true) {
        if (stopped(control)) |result| return result;
        if (budget.exceeded.load(.acquire)) return .output_limit;
        for (&drains) |*drain| if (drain.done.load(.acquire)) {
            if (drain.failure) |err| return err;
        };
        if (waiter.done.load(.acquire)) {
            if (waiter.failure) |err| return err;
            if (drain_deadline == null) drain_deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(250));
            if (drains[0].done.load(.acquire) and drains[1].done.load(.acquire)) break;
            if (std.Io.Clock.awake.now(io).nanoseconds >= drain_deadline.?.nanoseconds) return error.ProcessPipeDrainTimedOut;
        }
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    if (stopped(control)) |result| return result;
    if (budget.exceeded.load(.acquire)) return .output_limit;
    return switch (waiter.result.?) {
        .exited => |code| .{ .exited = code },
        .signal => |signal| .{ .signaled = @intCast(@backingInt(signal)) },
        .stopped, .unknown => return error.UnexpectedProcessTermination,
    };
}

fn stopped(control: common.Control) ?Result {
    control.check() catch |err| return switch (err) {
        error.Canceled => .canceled,
        error.DeadlineExceeded => .deadline,
    };
    return null;
}

fn terminate(child: *std.process.Child, io: std.Io) void {
    if (child.id == null) return;
    if (builtin.os.tag == .windows) {
        // Existing Windows adapter only owns the root; no Job Object guarantee.
        child.kill(io);
        return;
    }
    // SETSID made child.id the exclusive group ID. waitOwned uses WNOWAIT,
    // so even an exited leader still pins this identity against PID/PGID reuse.
    while (true) switch (std.posix.errno(std.posix.system.kill(-child.id.?, .KILL))) {
        .INTR => continue,
        else => break,
    };
}

fn reapOwned(child: *std.process.Child, io: std.Io) void {
    if (child.id == null) return;
    terminate(child, io);
    if (builtin.os.tag == .windows) return;
    // Cleanup cannot be canceled. This is the sole consuming wait, after all
    // group signals and reader joins; never signal this numeric ID afterwards.
    var status: c_int = undefined;
    while (true) switch (std.posix.errno(std.posix.system.waitpid(child.id.?, &status, 0))) {
        .INTR => continue,
        else => break,
    };
    child.id = null;
}

fn waitOwned(child: *std.process.Child, io: std.Io) !std.process.Child.Term {
    if (builtin.os.tag == .windows) return child.wait(io);
    while (true) {
        var info: std.c.siginfo_t = std.mem.zeroes(std.c.siginfo_t);
        const rc = posix.waitid(posix.P_PID, @intCast(child.id.?), @ptrCast(&info), posix.WEXITED | posix.WNOHANG | posix.WNOWAIT);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const pid = if (builtin.os.tag == .linux) info.fields.common.first.piduid.pid else info.pid;
                if (pid != 0) {
                    const status = if (builtin.os.tag == .linux) info.fields.common.second.sigchld.status else info.status;
                    return switch (info.code) {
                        posix.CLD_EXITED => .{ .exited = @intCast(status) },
                        posix.CLD_KILLED, posix.CLD_DUMPED => .{ .signal = @fromBackingInt(@intCast(status)) },
                        else => error.UnexpectedProcessTermination,
                    };
                }
            },
            .INTR => {},
            .CHILD => {
                // Another reaper violated exclusive ownership. Do not signal an
                // unpinned ID that may now name an unrelated process group.
                child.id = null;
                return error.ProcessWaitOwnershipLost;
            },
            else => return error.ProcessWaitFailed,
        }
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
}

fn spawnOwned(a: Allocator, io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd) !std.process.Child {
    if (builtin.os.tag == .windows) return std.process.spawn(io, .{ .argv = argv, .cwd = cwd, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
    const spawn = if (builtin.os.tag == .linux) posix else std.c;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const args = try scratch.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, args) |arg, *out| out.* = (try scratch.dupeSentinel(u8, arg, 0)).ptr;
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) try env.append(scratch, (try scratch.dupeSentinel(u8, std.mem.span(entry), 0)).ptr);
    try env.append(scratch, null);
    const stdout = try pipe();
    errdefer for (stdout) |fd| {
        _ = std.c.close(fd);
    };
    const stderr = try pipe();
    errdefer for (stderr) |fd| {
        _ = std.c.close(fd);
    };
    var input = try std.Io.Dir.cwd().openFile(io, "/dev/null", .{});
    defer input.close(io);
    input.handle = try aboveStdio(input.handle);
    var actions: spawn.posix_spawn_file_actions_t = undefined;
    if (spawn.posix_spawn_file_actions_init(&actions) != 0) return error.ProcessSpawnFailed;
    defer _ = spawn.posix_spawn_file_actions_destroy(&actions);
    for ([_]struct { source: c_int, destination: c_int }{
        .{ .source = input.handle, .destination = 0 },
        .{ .source = stdout[1], .destination = 1 },
        .{ .source = stderr[1], .destination = 2 },
    }) |action| if (spawn.posix_spawn_file_actions_adddup2(&actions, action.source, action.destination) != 0) return error.ProcessSpawnFailed;
    for ([_]c_int{ input.handle, stdout[0], stdout[1], stderr[0], stderr[1] }) |fd| if (spawn.posix_spawn_file_actions_addclose(&actions, fd) != 0) return error.ProcessSpawnFailed;
    switch (cwd) {
        .inherit => {},
        .path => |path| {
            const path_z = try scratch.dupeSentinel(u8, path, 0);
            if (spawn.posix_spawn_file_actions_addchdir_np(&actions, path_z.ptr) != 0) return error.ProcessSpawnFailed;
        },
        .dir => return error.InvalidProcessArgument,
    }
    var attributes: spawn.posix_spawnattr_t = undefined;
    if (spawn.posix_spawnattr_init(&attributes) != 0) return error.ProcessSpawnFailed;
    defer _ = spawn.posix_spawnattr_destroy(&attributes);
    // SETSID creates both a new session and a group led by this child before
    // exec. Unrelated processes in the launcher's session cannot join it.
    const flags = if (builtin.os.tag == .linux) spawn.POSIX_SPAWN_SETSID else std.c.POSIX_SPAWN{ .SETSID = true };
    if (spawn.posix_spawnattr_setflags(&attributes, flags) != 0) return error.ProcessSpawnFailed;
    var pid: std.posix.pid_t = undefined;
    // spawnp preserves command-name PATH lookup; paths containing a slash are
    // executed directly by the same API, with the owned session attributes.
    const rc = spawn.posix_spawnp(&pid, args[0].?, &actions, &attributes, @ptrCast(args.ptr), @ptrCast(env.items.ptr));
    if (rc != 0) return if (rc == @backingInt(std.posix.E.NOENT)) error.FileNotFound else error.ProcessSpawnFailed;
    _ = std.c.close(stdout[1]);
    _ = std.c.close(stderr[1]);
    return .{ .id = pid, .thread_handle = {}, .stdin = null, .stdout = .{ .handle = stdout[0], .flags = .{ .nonblocking = false } }, .stderr = .{ .handle = stderr[0], .flags = .{ .nonblocking = false } }, .request_resource_usage_statistics = false };
}

fn aboveStdio(fd: std.posix.fd_t) !std.posix.fd_t {
    if (fd >= 3) return fd;
    const moved = std.c.fcntl(fd, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (moved < 0) return error.ProcessSpawnFailed;
    _ = std.c.close(fd);
    return moved;
}
fn pipe() ![2]std.posix.fd_t {
    var fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    errdefer for (fds) |fd| {
        _ = std.c.close(fd);
    };
    for (&fds) |*fd| fd.* = try aboveStdio(fd.*);
    return fds;
}

fn parseMajor(output: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    var major: ?u64 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        var version: []const u8 = undefined;
        if (std.mem.startsWith(u8, line, "java version ")) version = line[13..] else if (std.mem.startsWith(u8, line, "openjdk version ")) version = line[16..] else if (std.mem.startsWith(u8, line, "openjdk ")) version = line[8..] else if (std.mem.startsWith(u8, line, "java ")) version = line[5..] else continue;
        if (version.len != 0 and version[0] == '"') version = version[1..];
        if (std.mem.startsWith(u8, version, "1.")) version = version[2..];
        var n: usize = 0;
        while (n < version.len and std.ascii.isDigit(version[n])) : (n += 1) {}
        if (n == 0 or (n < version.len and std.mem.indexOfScalar(u8, ".-+_\" \t\r", version[n]) == null)) return null;
        const parsed = std.fmt.parseInt(u64, version[0..n], 10) catch return null;
        if (parsed == 0) return null;
        if (major) |old| if (old != parsed) return null;
        major = parsed;
    }
    return major;
}
