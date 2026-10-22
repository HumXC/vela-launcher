//! UI-thread registry. Workers own private memory; tick publishes after joining.
const std = @import("std");
const builtin = @import("builtin");
const java_runtime = @import("../core/java_runtime.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const max_entries = 256;
const max_choices = 4096;
const max_path = 4096;
const max_json = 1024 * 1024;
const max_candidates = 64;
const max_nodes = 2048;
const max_depth = 5;
const probe_ms = 2000;
const operation_ms = 30000;
const java_name = if (builtin.os.tag == .windows) "java.exe" else "java";

pub const Runtime = struct { path: []const u8, major: u32, vendor: []const u8, architecture: java_runtime.Architecture };
pub fn compatible(major: u32, required: u32) bool {
    return major == required;
}
pub fn freeRuntime(a: Allocator, runtime: Runtime) void {
    a.free(runtime.path);
    a.free(runtime.vendor);
}
fn validText(s: []const u8, limit: usize) bool {
    return s.len > 0 and s.len <= limit and std.mem.indexOfScalar(u8, s, 0) == null and std.unicode.utf8ValidateSlice(s);
}
fn checkCanceled(canceled: ?*const std.atomic.Value(bool)) !void {
    if (canceled) |flag| if (flag.load(.acquire)) return error.Canceled;
}
fn elapsed(io: std.Io, start: std.Io.Timestamp) i96 {
    return start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
}
const Capture = struct {
    a: Allocator,
    io: std.Io,
    argv: []const []const u8,
    done: std.atomic.Value(bool) = .init(false),
    result: ?std.process.RunResult = null,
    failure: ?anyerror = null,

    fn run(self: *Capture) void {
        self.result = self.collect() catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        self.done.store(true, .release);
    }

    fn collect(self: *Capture) !std.process.RunResult {
        var child = try spawnOwned(self.a, self.io, self.argv);
        defer terminate(&child, self.io);
        var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(self.a, self.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();
        while (reader.fill(64, .none)) |_| {
            if (reader.reader(0).buffered().len > 32 * 1024 or reader.reader(1).buffered().len > 32 * 1024) return error.StreamTooLong;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
        try reader.checkAnyError();
        const term = try waitOwned(&child, self.io);
        const stdout = try reader.toOwnedSlice(0);
        errdefer self.a.free(stdout);
        const stderr = try reader.toOwnedSlice(1);
        return .{ .stdout = stdout, .stderr = stderr, .term = term };
    }
};

fn terminate(child: *std.process.Child, io: std.Io) void {
    if (child.id == null) return;
    // Only this task reaps. An unreaped POSIX child keeps its PID reserved;
    // Windows Child.kill terminates through the owned process HANDLE.
    if (builtin.os.tag != .windows) {
        while (true) switch (std.posix.errno(std.posix.system.kill(child.id.?, .KILL))) {
            .INTR => continue,
            else => break,
        };
    }
    child.kill(io);
}

fn waitOwned(child: *std.process.Child, io: std.Io) !std.process.Child.Term {
    if (builtin.os.tag == .windows) return child.wait(io);
    // std Child.wait currently clears POSIX ownership even on cancellation.
    // Poll instead, so cancellation leaves the child available to terminate/reap.
    while (true) {
        var status: if (builtin.link_libc) c_int else u32 = undefined;
        const result = std.posix.system.waitpid(child.id.?, &status, std.posix.W.NOHANG);
        switch (std.posix.errno(result)) {
            .SUCCESS => if (result != 0) {
                child.id = null;
                if (child.stdout) |file| file.close(io);
                if (child.stderr) |file| file.close(io);
                child.stdout = null;
                child.stderr = null;
                const bits: u32 = @bitCast(status);
                return if (std.posix.W.IFEXITED(bits))
                    .{ .exited = std.posix.W.EXITSTATUS(bits) }
                else if (std.posix.W.IFSIGNALED(bits))
                    .{ .signal = std.posix.W.TERMSIG(bits) }
                else
                    .{ .unknown = bits };
            },
            .INTR => {},
            .CHILD => {
                // Ownership was externally lost: never signal a potentially reused PID.
                child.id = null;
                if (child.stdout) |file| file.close(io);
                if (child.stderr) |file| file.close(io);
                child.stdout = null;
                child.stderr = null;
                return error.JavaProbeWaitFailed;
            },
            else => return error.JavaProbeWaitFailed,
        }
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
}

fn spawnOwned(a: Allocator, io: std.Io, argv: []const []const u8) !std.process.Child {
    if (builtin.os.tag == .windows) return std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
    // libc owns its spawn handshake and failure cleanup, unlike std's POSIX exec pipe.
    // Spawn's kernel/libc boundary is not interruptible; the deadline starts before it.
    const spawn = if (builtin.os.tag == .linux) @import("linux_c") else std.c;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const args = try scratch.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, args) |arg, *out| out.* = (try scratch.dupeSentinel(u8, arg, 0)).ptr;
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        try env.append(scratch, (try scratch.dupeSentinel(u8, std.mem.span(entry), 0)).ptr);
    }
    try env.append(scratch, null);
    const stdout = try probePipe();
    errdefer {
        for (stdout) |fd| {
            _ = std.c.close(fd);
        }
    }
    const stderr = try probePipe();
    errdefer {
        for (stderr) |fd| {
            _ = std.c.close(fd);
        }
    }
    var input = try Dir.cwd().openFile(io, "/dev/null", .{});
    defer input.close(io);
    input.handle = try aboveStdio(input.handle);
    var actions: spawn.posix_spawn_file_actions_t = undefined;
    if (spawn.posix_spawn_file_actions_init(&actions) != 0) return error.JavaProbeSpawnFailed;
    defer _ = spawn.posix_spawn_file_actions_destroy(&actions);
    for ([_]struct { source: c_int, destination: c_int }{
        .{ .source = input.handle, .destination = 0 },
        .{ .source = stdout[1], .destination = 1 },
        .{ .source = stderr[1], .destination = 2 },
    }) |action| {
        if (spawn.posix_spawn_file_actions_adddup2(&actions, action.source, action.destination) != 0) return error.JavaProbeSpawnFailed;
    }
    for ([_]c_int{ input.handle, stdout[0], stdout[1], stderr[0], stderr[1] }) |fd| {
        if (spawn.posix_spawn_file_actions_addclose(&actions, fd) != 0) return error.JavaProbeSpawnFailed;
    }
    var pid: std.posix.pid_t = undefined;
    if (spawn.posix_spawn(&pid, args[0].?, &actions, null, @ptrCast(args.ptr), @ptrCast(env.items.ptr)) != 0) return error.JavaProbeSpawnFailed;
    _ = std.c.close(stdout[1]);
    _ = std.c.close(stderr[1]);
    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = .{ .handle = stdout[0], .flags = .{ .nonblocking = false } },
        .stderr = .{ .handle = stderr[0], .flags = .{ .nonblocking = false } },
        .request_resource_usage_statistics = false,
    };
}

fn aboveStdio(fd: std.posix.fd_t) !std.posix.fd_t {
    if (fd >= 3) return fd;
    const moved = std.c.fcntl(fd, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (moved < 0) return error.JavaProbeSpawnFailed;
    _ = std.c.close(fd);
    return moved;
}

fn probePipe() ![2]std.posix.fd_t {
    var pipe = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    errdefer {
        for (pipe) |fd| {
            _ = std.c.close(fd);
        }
    }
    for (&pipe) |*fd| fd.* = try aboveStdio(fd.*);
    return pipe;
}

fn capture(a: Allocator, io: std.Io, argv: []const []const u8, canceled: ?*const std.atomic.Value(bool)) !std.process.RunResult {
    try checkCanceled(canceled);
    // Spawn, both pipes, and the final wait share one whole-process deadline.
    const start = std.Io.Clock.awake.now(io);
    var task: Capture = .{ .a = a, .io = io, .argv = argv };
    var future = try io.concurrent(Capture.run, .{&task});
    var failure: ?anyerror = null;
    while (!task.done.load(.acquire)) {
        checkCanceled(canceled) catch |err| {
            failure = err;
            break;
        };
        if (elapsed(io, start) >= probe_ms * std.time.ns_per_ms) {
            failure = error.JavaProbeTimedOut;
            break;
        }
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch |err| {
            failure = err;
            break;
        };
    }
    if (failure == null) {
        checkCanceled(canceled) catch |err| {
            failure = err;
        };
        if (failure == null and elapsed(io, start) >= probe_ms * std.time.ns_per_ms) failure = error.JavaProbeTimedOut;
    }
    if (failure != null) future.cancel(io) else future.await(io);
    if (failure) |err| {
        if (task.result) |result| {
            a.free(result.stdout);
            a.free(result.stderr);
        }
        return err;
    }
    if (task.failure) |err| return err;
    return task.result.?;
}
fn property(output: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t\r"), key))
            return std.mem.trim(u8, line[eq + 1 ..], " \t\r");
    }
    return null;
}
fn majorOf(version: []const u8) ?u32 {
    var v = version;
    if (std.mem.startsWith(u8, v, "1.")) v = v[2..];
    var n: usize = 0;
    while (n < v.len and std.ascii.isDigit(v[n])) : (n += 1) {}
    if (n == 0) return null;
    if (n < v.len and v[n] != '.' and v[n] != '-' and v[n] != '+' and v[n] != '_') return null;
    const major = std.fmt.parseInt(u32, v[0..n], 10) catch return null;
    return if (major > 0 and major <= 1000) major else null;
}
fn parseMajor(output: []const u8) ?u32 {
    if (property(output, "java.version")) |version| if (majorOf(version)) |major| return major;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "java version ") and !std.mem.startsWith(u8, line, "openjdk version ")) continue;
        const begin = std.mem.indexOfScalar(u8, line, '"') orelse continue;
        const end = std.mem.indexOfScalarPos(u8, line, begin + 1, '"') orelse continue;
        if (majorOf(line[begin + 1 .. end])) |major| return major;
    }
    return null;
}
fn containsIgnoreCase(text: []const u8, needle: []const u8) bool {
    if (text.len < needle.len) return false;
    for (0..text.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(text[i..][0..needle.len], needle)) return true;
    }
    return false;
}
fn parseVendor(output: []const u8) []const u8 {
    if (property(output, "java.vendor")) |vendor| if (validText(vendor, 256)) return vendor;
    if (containsIgnoreCase(output, "zulu") or containsIgnoreCase(output, "azul")) return "Azul Zulu";
    if (containsIgnoreCase(output, "temurin") or containsIgnoreCase(output, "adoptium")) return "Eclipse Adoptium";
    if (containsIgnoreCase(output, "corretto")) return "Amazon Corretto";
    if (containsIgnoreCase(output, "graalvm")) return "GraalVM";
    if (containsIgnoreCase(output, "openjdk")) return "OpenJDK";
    if (containsIgnoreCase(output, "java(tm)")) return "Oracle";
    return "Unknown";
}
/// Caller owns both returned strings. No shell is involved in probing.
pub fn probe(a: Allocator, io: std.Io, path: []const u8, canceled: ?*const std.atomic.Value(bool)) !Runtime {
    if (!validText(path, max_path)) return error.InvalidJavaPath;
    try checkCanceled(canceled);
    const canonical = try Dir.cwd().realPathFileAlloc(io, path, a);
    defer a.free(canonical);
    if (canonical.len > max_path) return error.InvalidJavaPath;
    const stat = try Dir.cwd().statFile(io, canonical, .{});
    if (stat.kind != .file) return error.InvalidJavaExecutable;
    const result = try capture(a, io, &.{ canonical, "-XshowSettings:properties", "-version" }, canceled);
    defer {
        a.free(result.stdout);
        a.free(result.stderr);
    }
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.InvalidJavaExecutable;
    const output = try std.mem.concat(a, u8, &.{ result.stderr, "\n", result.stdout });
    defer a.free(output);
    const major = parseMajor(output) orelse return error.InvalidJavaVersion;
    const architecture = try java_runtime.parse(output);
    const vendor = try a.dupe(u8, parseVendor(output));
    errdefer a.free(vendor);
    return .{ .path = try a.dupe(u8, canonical), .major = major, .vendor = vendor, .architecture = architecture };
}

const Choice = struct { game: []const u8, path: []const u8 };
const Document = struct { version: u32, runtimes: []const Runtime, choices: []const Choice, hidden: []const Runtime };
const State = struct {
    arena: std.heap.ArenaAllocator,
    runtimes: std.ArrayList(Runtime) = .empty,
    choices: std.ArrayList(Choice) = .empty,
    hidden: std.ArrayList(Runtime) = .empty,
    visible: std.ArrayList(Runtime) = .empty,
    search_visible: std.ArrayList(Runtime) = .empty,
    forgotten: std.ArrayList([]const u8) = .empty,
    fn create(a: Allocator) !*State {
        const state = try a.create(State);
        state.* = .{ .arena = .init(a) };
        return state;
    }
    fn destroy(self: *State, a: Allocator) void {
        self.arena.deinit();
        a.destroy(self);
    }
    fn copy(self: *State, runtime: Runtime) !void {
        const a = self.arena.allocator();
        try self.runtimes.append(a, .{ .path = try a.dupe(u8, runtime.path), .major = runtime.major, .vendor = try a.dupe(u8, runtime.vendor), .architecture = runtime.architecture });
    }
    fn clone(self: *const State, a: Allocator) !*State {
        const next = try State.create(a);
        errdefer next.destroy(a);
        for (self.runtimes.items) |r| try next.copy(r);
        const na = next.arena.allocator();
        for (self.choices.items) |c| try next.choices.append(na, .{ .game = try na.dupe(u8, c.game), .path = try na.dupe(u8, c.path) });
        for (self.hidden.items) |r| try next.copyHidden(r);
        for (self.forgotten.items) |path| try next.forgotten.append(na, try na.dupe(u8, path));
        return next;
    }
    fn copyHidden(self: *State, runtime: Runtime) !void {
        const a = self.arena.allocator();
        try self.hidden.append(a, .{ .path = try a.dupe(u8, runtime.path), .major = runtime.major, .vendor = try a.dupe(u8, runtime.vendor), .architecture = runtime.architecture });
    }
    fn hiddenIndex(self: *const State, path: []const u8) ?usize {
        for (self.hidden.items, 0..) |r, i| if (std.mem.eql(u8, r.path, path)) return i;
        return null;
    }
    fn isForgotten(self: *const State, path: []const u8) bool {
        for (self.forgotten.items) |old| if (std.mem.eql(u8, old, path)) return true;
        return false;
    }
    fn refresh(self: *State, results: []const Runtime) !void {
        const a = self.arena.allocator();
        self.visible = .empty;
        self.search_visible = .empty;
        for (self.runtimes.items) |r| if (self.hiddenIndex(r.path) == null) try self.visible.append(a, r);
        for (results) |r| if (self.hiddenIndex(r.path) == null and !self.isForgotten(r.path)) try self.search_visible.append(a, r);
    }
    fn clearReferences(self: *State, path: []const u8) void {
        var i: usize = 0;
        while (i < self.choices.items.len) {
            if (std.mem.eql(u8, self.choices.items[i].path, path)) {
                _ = self.choices.orderedRemove(i);
            } else i += 1;
        }
    }
    fn find(self: *const State, path: []const u8) ?usize {
        for (self.runtimes.items, 0..) |r, i| if (std.mem.eql(u8, r.path, path)) return i;
        return null;
    }
};
const Job = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    io: std.Io,
    path: []const u8,
    thread: ?std.Thread = null,
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    results: []const Runtime = &.{},
    failure: ?anyerror = null,
    fn destroy(self: *Job) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
    fn work(self: *Job) void {
        self.scan() catch |err| {
            self.failure = err;
            self.results = &.{};
        };
        self.done.store(true, .release);
    }
    fn scan(self: *Job) !void {
        const a = self.arena.allocator();
        var searcher: Searcher = .{ .job = self, .start = std.Io.Clock.awake.now(self.io) };
        if (self.path.len == 0) {
            const path = if (builtin.os.tag == .windows)
                try (std.process.Environ{ .block = .{ .use_global = true } }).getAlloc(a, "PATH")
            else
                std.mem.span(std.c.getenv("PATH") orelse return error.PathEnvironmentMissing);
            if (path.len > 64 * 1024) return error.SearchLimitExceeded;
            var dirs = std.mem.splitScalar(u8, path, if (builtin.os.tag == .windows) ';' else ':');
            while (dirs.next()) |dir| {
                try searcher.check();
                const candidate = try std.fs.path.join(a, &.{ if (dir.len == 0) "." else dir, java_name });
                try searcher.candidate(candidate);
            }
        } else {
            const stat = try Dir.cwd().statFile(self.io, self.path, .{});
            switch (stat.kind) {
                .file => try searcher.candidate(self.path),
                .directory => {
                    var dir = try Dir.cwd().openDir(self.io, self.path, .{ .iterate = true });
                    defer dir.close(self.io);
                    try searcher.walk(dir, self.path, 0);
                },
                else => return error.InvalidJavaSearchPath,
            }
        }
        self.results = try searcher.results.toOwnedSlice(a);
    }
};
const Searcher = struct {
    job: *Job,
    start: std.Io.Timestamp,
    nodes: usize = 0,
    candidates: usize = 0,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    results: std.ArrayList(Runtime) = .empty,
    fn check(self: *Searcher) !void {
        try checkCanceled(&self.job.canceled);
        if (elapsed(self.job.io, self.start) >= operation_ms * std.time.ns_per_ms) return error.SearchTimedOut;
    }
    fn candidate(self: *Searcher, path: []const u8) !void {
        try self.check();
        const a = self.job.arena.allocator();
        const canonical = Dir.cwd().realPathFileAlloc(self.job.io, path, a) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        };
        if (self.seen.contains(canonical)) return;
        try self.seen.put(a, canonical, {});
        self.candidates += 1;
        if (self.candidates > max_candidates) return error.SearchLimitExceeded;
        const r = probe(a, self.job.io, canonical, &self.job.canceled) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return,
        };
        try self.results.append(a, r);
    }
    fn walk(self: *Searcher, dir: Dir, path: []const u8, depth: usize) anyerror!void {
        try self.check();
        const a = self.job.arena.allocator();
        // Direct checks follow bin links; recursive traversal never follows directory symlinks.
        try self.candidate(try std.fs.path.join(a, &.{ path, java_name }));
        try self.candidate(try std.fs.path.join(a, &.{ path, "bin", java_name }));
        var it = dir.iterate();
        while (try it.next(self.job.io)) |entry| {
            try self.check();
            self.nodes += 1;
            if (self.nodes > max_nodes) return error.SearchLimitExceeded;
            if (entry.kind != .directory or depth >= max_depth) continue;
            const child_path = try std.fs.path.join(a, &.{ path, entry.name });
            var child = dir.openDir(self.job.io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
            defer child.close(self.job.io);
            try self.walk(child, child_path, depth + 1);
        }
    }
};
pub const Manager = struct {
    a: Allocator,
    io: std.Io,
    file: []const u8,
    state: *State,
    active: ?*Job = null,
    published: ?*Job = null,
    failure: ?anyerror = null,
    pub fn init(a: Allocator, io: std.Io, root: []const u8) !Manager {
        if (!validText(root, max_path)) return error.InvalidInstallRoot;
        const cwd = try std.process.currentPathAlloc(io, a);
        defer a.free(cwd);
        const absolute = try std.fs.path.resolve(a, &.{ cwd, root, ".vela", "java.json" });
        errdefer a.free(absolute);
        const state = try State.create(a);
        errdefer state.destroy(a);
        var manager: Manager = .{ .a = a, .io = io, .file = absolute, .state = state };
        try manager.load();
        try manager.state.refresh(&.{});
        return manager;
    }
    pub fn deinit(self: *Manager) void {
        if (self.active) |job| {
            job.canceled.store(true, .release);
            job.thread.?.join();
            job.destroy();
        }
        if (self.published) |job| job.destroy();
        self.state.destroy(self.a);
        self.a.free(self.file);
        self.* = undefined;
    }
    pub fn tick(self: *Manager) void {
        const job = self.active orelse return;
        if (!job.done.load(.acquire)) return;
        if (job.thread) |thread| thread.join();
        job.thread = null;
        var visible: std.ArrayList(Runtime) = .empty;
        for (job.results) |runtime| {
            if (self.isHidden(runtime.path)) continue;
            visible.append(job.arena.allocator(), runtime) catch |err| {
                self.active = null;
                self.failure = err;
                job.destroy();
                return;
            };
        }
        // Publish only after the complete filtered array exists; registry strings stay intact.
        self.state.search_visible = visible;
        self.state.forgotten = .empty;
        if (self.published) |old| old.destroy();
        self.active = null;
        self.published = job;
        self.failure = job.failure;
    }
    pub fn allEntries(self: *const Manager) []const Runtime {
        return self.state.runtimes.items;
    }
    pub fn hiddenEntries(self: *const Manager) []const Runtime {
        return self.state.hidden.items;
    }
    pub fn isHidden(self: *const Manager, path: []const u8) bool {
        return self.state.hiddenIndex(path) != null;
    }
    pub fn hide(self: *Manager, path: []const u8) !void {
        if (!validText(path, max_path)) return error.InvalidJavaPath;
        if (self.isHidden(path)) return;
        var runtime: ?Runtime = null;
        if (self.state.find(path)) |index| runtime = self.state.runtimes.items[index];
        if (runtime == null) {
            for (self.searchResults()) |r| {
                if (std.mem.eql(u8, path, r.path)) {
                    runtime = r;
                    break;
                }
            }
        }
        const r = runtime orelse return error.JavaNotRegistered;
        if (self.state.hidden.items.len >= max_entries) return error.TooManyHiddenRuntimes;
        const next = try self.state.clone(self.a);
        errdefer next.destroy(self.a);
        try next.copyHidden(r);
        next.clearReferences(path);
        try self.commit(next);
    }
    pub fn unhide(self: *Manager, path: []const u8) !void {
        const index = self.state.hiddenIndex(path) orelse return error.JavaNotHidden;
        const next = try self.state.clone(self.a);
        errdefer next.destroy(self.a);
        _ = next.hidden.orderedRemove(index);
        var forgotten_index: usize = 0;
        while (forgotten_index < next.forgotten.items.len) {
            if (std.mem.eql(u8, next.forgotten.items[forgotten_index], path)) {
                _ = next.forgotten.orderedRemove(forgotten_index);
            } else forgotten_index += 1;
        }
        try self.commit(next);
    }
    /// Forgets a registry/search entry, never Java files. Hidden suppression is preserved.
    pub fn forget(self: *Manager, path: []const u8) !void {
        if (self.state.find(path) != null) return self.remove(path);
        if (!validText(path, max_path)) return error.InvalidJavaPath;
        var known = self.isHidden(path);
        for (self.searchResults()) |r| {
            if (std.mem.eql(u8, path, r.path)) {
                known = true;
                break;
            }
        }
        if (!known) return error.JavaNotRegistered;
        const next = try self.state.clone(self.a);
        errdefer next.destroy(self.a);
        if (!next.isForgotten(path)) try next.forgotten.append(next.arena.allocator(), try next.arena.allocator().dupe(u8, path));
        next.clearReferences(path);
        try self.commit(next);
    }
    pub fn entries(self: *const Manager) []const Runtime {
        return self.state.visible.items;
    }
    pub fn searchResults(self: *const Manager) []const Runtime {
        return self.state.search_visible.items;
    }
    pub fn isSearching(self: *const Manager) bool {
        return self.active != null;
    }
    pub fn searchFailure(self: *const Manager) ?anyerror {
        return self.failure;
    }
    pub fn search(self: *Manager, path: []const u8) !void {
        if (self.active != null) return error.Busy;
        if (path.len > 0 and !validText(path, max_path)) return error.InvalidSearchPath;
        const job = try std.heap.page_allocator.create(Job);
        job.* = .{ .io = self.io, .path = "" };
        errdefer job.destroy();
        if (path.len > 0) {
            const cwd = try std.process.currentPathAlloc(self.io, job.arena.allocator());
            job.path = try std.fs.path.resolve(job.arena.allocator(), &.{ cwd, path });
        }
        job.thread = try std.Thread.spawn(.{}, Job.work, .{job});
        self.active = job;
        self.failure = null;
    }
    pub fn cancelSearch(self: *Manager) void {
        if (self.active) |job| job.canceled.store(true, .release);
    }
    /// Join the active search and publish its result without changing saved entries.
    pub fn cancelAndJoin(self: *Manager) void {
        const job = self.active orelse return;
        self.cancelSearch();
        if (job.thread) |thread| thread.join();
        job.thread = null;
        self.tick();
    }
    pub fn add(self: *Manager, paths: []const []const u8) !void {
        if (paths.len > max_candidates) return error.TooManyJavaPaths;
        const next = try self.state.clone(self.a);
        errdefer next.destroy(self.a);
        for (paths) |path| {
            if (self.isHidden(path)) return error.JavaHidden;
            var verified: ?Runtime = null;
            for (self.searchResults()) |r| {
                if (std.mem.eql(u8, path, r.path)) {
                    verified = r;
                    break;
                }
            }
            const r = verified orelse return error.JavaNotInSearchResults;
            if (next.find(r.path) != null) continue;
            if (next.runtimes.items.len >= max_entries) return error.TooManyRuntimes;
            try next.copy(r);
        }
        try self.commit(next);
    }
    /// Main-thread only. Copies an already-probed runtime; ownership stays with caller.
    /// The downloader validates expected major and publisher before calling this.
    pub fn addDownloaded(self: *Manager, runtime: Runtime) !void {
        if (self.isHidden(runtime.path)) return error.JavaHidden;
        if (!validText(runtime.path, max_path) or !std.fs.path.isAbsolute(runtime.path) or
            !validText(runtime.vendor, 256) or std.ascii.eqlIgnoreCase(runtime.vendor, "Unknown") or
            runtime.major == 0 or runtime.major > 1000) return error.InvalidJavaRuntime;
        const existing = self.state.find(runtime.path);
        if (existing) |i| {
            const old = self.state.runtimes.items[i];
            if (old.major == runtime.major and old.architecture == runtime.architecture and std.mem.eql(u8, old.vendor, runtime.vendor)) return;
        } else if (self.state.runtimes.items.len >= max_entries) return error.TooManyRuntimes;
        const next = try self.state.clone(self.a);
        errdefer next.destroy(self.a);
        if (existing) |i| {
            next.runtimes.items[i].major = runtime.major;
            next.runtimes.items[i].architecture = runtime.architecture;
            next.runtimes.items[i].vendor = try next.arena.allocator().dupe(u8, runtime.vendor);
        } else try next.copy(runtime);
        try self.commit(next);
    }
    pub fn remove(self: *Manager, path: []const u8) !void {
        const index = try self.lookup(path) orelse return error.JavaNotRegistered;
        const next = try self.state.clone(self.a);
        errdefer next.destroy(self.a);
        const removed = next.runtimes.orderedRemove(index);
        next.clearReferences(removed.path);
        if (!next.isForgotten(removed.path)) try next.forgotten.append(next.arena.allocator(), try next.arena.allocator().dupe(u8, removed.path));
        try self.commit(next);
    }
    pub fn choose(self: *Manager, game: []const u8, path: []const u8, required: u32) !void {
        if (!validText(game, 512)) return error.InvalidGameId;
        const index = try self.lookup(path) orelse return error.JavaNotRegistered;
        const r = self.state.runtimes.items[index];
        if (self.isHidden(path)) return error.JavaHidden;
        if (!compatible(r.major, required)) return error.IncompatibleJava;
        const next = try self.state.clone(self.a);
        errdefer next.destroy(self.a);
        const a = next.arena.allocator();
        var found = false;
        for (next.choices.items) |*c| {
            if (std.mem.eql(u8, c.game, game)) {
                c.path = next.runtimes.items[index].path;
                found = true;
                break;
            }
        }
        if (!found) {
            if (next.choices.items.len >= max_choices) return error.TooManyChoices;
            try next.choices.append(a, .{ .game = try a.dupe(u8, game), .path = next.runtimes.items[index].path });
        }
        try self.commit(next);
    }
    pub fn selectedPath(self: *const Manager, game: []const u8) ?[]const u8 {
        for (self.state.choices.items) |c| if (std.mem.eql(u8, c.game, game) and !self.isHidden(c.path)) return c.path;
        return null;
    }
    pub fn resolve(self: *const Manager, game: []const u8, required: u32) ?Runtime {
        if (self.selectedPath(game)) |path| {
            const index = self.state.find(path) orelse return null;
            const r = self.state.runtimes.items[index];
            return if (compatible(r.major, required)) r else null;
        }
        for (self.entries()) |r| if (compatible(r.major, required) and r.architecture == java_runtime.host()) return r;
        return null;
    }
    fn lookup(self: *const Manager, path: []const u8) !?usize {
        if (!validText(path, max_path)) return error.InvalidJavaPath;
        return self.state.find(path);
    }
    fn commit(self: *Manager, next: *State) !void {
        try next.refresh(if (self.published) |job| job.results else &.{});
        const json = try std.json.Stringify.valueAlloc(self.a, Document{ .version = 2, .runtimes = next.runtimes.items, .choices = next.choices.items, .hidden = next.hidden.items }, .{ .whitespace = .indent_2 });
        defer self.a.free(json);
        if (json.len > max_json) return error.RegistryTooLarge;
        var atomic = try Dir.cwd().createFileAtomic(self.io, self.file, .{ .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, json);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        self.state.destroy(self.a);
        self.state = next;
    }
    fn load(self: *Manager) !void {
        const stat = Dir.cwd().statFile(self.io, self.file, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (stat.kind != .file) return error.InvalidJavaRegistry;
        if (stat.size > max_json) return error.StreamTooLong;
        const bytes = Dir.cwd().readFileAlloc(self.io, self.file, self.a, .limited(max_json)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.a.free(bytes);
        const parsed = std.json.parseFromSlice(Document, self.a, bytes, .{ .allocate = .alloc_always, .max_value_len = max_path }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidJavaRegistry,
        };
        defer parsed.deinit();
        const doc = parsed.value;
        if (doc.version != 2 or doc.runtimes.len > max_entries or doc.choices.len > max_choices or doc.hidden.len > max_entries) return error.InvalidJavaRegistry;
        const a = self.state.arena.allocator();
        for (doc.runtimes) |r| {
            if (!validText(r.path, max_path) or !std.fs.path.isAbsolute(r.path) or !validText(r.vendor, 256) or r.major == 0 or r.major > 1000) return error.InvalidJavaRegistry;
            if (self.state.find(r.path) == null) try self.state.copy(r);
        }
        for (doc.hidden) |r| {
            if (!validText(r.path, max_path) or !std.fs.path.isAbsolute(r.path) or !validText(r.vendor, 256) or r.major == 0 or r.major > 1000) return error.InvalidJavaRegistry;
            if (self.state.hiddenIndex(r.path) != null) return error.InvalidJavaRegistry;
            try self.state.copyHidden(r);
        }
        for (doc.choices) |c| {
            if (!validText(c.game, 512) or !validText(c.path, max_path)) return error.InvalidJavaRegistry;
            const index = self.state.find(c.path) orelse continue;
            if (self.isHidden(c.path)) continue;
            for (self.state.choices.items) |old| if (std.mem.eql(u8, old.game, c.game)) return error.InvalidJavaRegistry;
            try self.state.choices.append(a, .{ .game = try a.dupe(u8, c.game), .path = self.state.runtimes.items[index].path });
        }
    }
};

test "major parsing and distinct vendors" {
    try std.testing.expectEqual(@as(?u32, 8), parseMajor("java version \"1.8.0_452\""));
    try std.testing.expectEqual(@as(?u32, 21), parseMajor("openjdk version \"21.0.7\" 2025-04-15"));
    try std.testing.expectEqual(@as(?u32, 25), parseMajor(" java.version = 25-ea\n"));
    try std.testing.expectEqual(@as(?u32, null), parseMajor("java.version = banana"));
    try std.testing.expectEqual(@as(?u32, null), majorOf("0"));
    try std.testing.expectEqualStrings("Azul Systems, Inc.", parseVendor("java.vendor = Azul Systems, Inc.\nopenjdk version \"25\""));
    try std.testing.expectEqualStrings("Azul Zulu", parseVendor("openjdk version \"25\"\nZulu25.28"));
    try std.testing.expectEqualStrings("OpenJDK", parseVendor("openjdk version \"25\""));
    try std.testing.expect(compatible(25, 25));
    try std.testing.expect(!compatible(25, 21));
}

fn fakeJava(dir: Dir, path: []const u8, script: []const u8) !void {
    const io = std.testing.io;
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, script);
    try file.setPermissions(io, .fromMode(0o755));
}
const openjdk25 = "#!/bin/sh\nprintf '%s\\n' 'java.version = 25.0.1' 'java.vendor = OpenJDK' 'os.arch = amd64' 'sun.arch.data.model = 64' >&2\n";
const zulu25 = "#!/bin/sh\nprintf '%s\\n' 'java.version = 25.0.1' 'java.vendor = Azul Systems, Inc.' 'os.arch = aarch64' 'sun.arch.data.model = 64' >&2\n";
const java21 = "#!/bin/sh\nprintf '%s\\n' 'openjdk version \"21.0.1\"' 'os.arch = i686' 'sun.arch.data.model = 32' >&2\n";
const hostile = "#!/bin/sh\ntrap '' TERM\nprintf '%s\\n' 'openjdk version \"25\"' 'os.arch = amd64' >&2\nexec 1>&- 2>&-\nwhile :; do :; done\n";
fn waitSearch(manager: *Manager) !void {
    const start = std.Io.Clock.awake.now(std.testing.io);
    while (manager.isSearching()) {
        manager.tick();
        if (elapsed(std.testing.io, start) > 5000 * std.time.ns_per_ms) return error.TestSearchTimedOut;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
}
test "explicit directory search stable publication no autoadd and canonical dedup" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeJava(tmp.dir, "runtimes/Open JDK/bin/java", openjdk25);
    try fakeJava(tmp.dir, "runtimes/Zulu JDK/Contents/Home/bin/java", zulu25);
    try tmp.dir.symLink(io, "Open JDK/bin/java", "runtimes/java", .{});
    var buf: [4096]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const search_root = try std.fs.path.join(a, &.{ root, "runtimes" });
    defer a.free(search_root);
    var manager = try Manager.init(a, io, root);
    defer manager.deinit();
    try std.testing.expect(!manager.isSearching());
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
    try manager.search(search_root);
    try std.testing.expectError(error.Busy, manager.search(search_root));
    try std.testing.expectEqual(@as(usize, 0), manager.searchResults().len);
    try waitSearch(&manager);
    try std.testing.expectEqual(@as(?anyerror, null), manager.searchFailure());
    try std.testing.expectEqual(@as(usize, 2), manager.searchResults().len);
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
    const old_results = manager.searchResults();
    const first_path = old_results[0].path;
    try manager.search(search_root);
    try std.testing.expectEqualStrings(first_path, manager.searchResults()[0].path);
    try waitSearch(&manager);
    var seen_openjdk = false;
    var seen_zulu = false;
    for (manager.searchResults()) |r| {
        try std.testing.expectEqual(@as(u32, 25), r.major);
        if (std.mem.eql(u8, r.vendor, "OpenJDK")) {
            seen_openjdk = true;
            try std.testing.expectEqual(java_runtime.Architecture.x86_64, r.architecture);
        }
        if (std.mem.eql(u8, r.vendor, "Azul Systems, Inc.")) {
            seen_zulu = true;
            try std.testing.expectEqual(java_runtime.Architecture.aarch64, r.architecture);
        }
    }
    try std.testing.expect(seen_openjdk and seen_zulu);
    try fakeJava(tmp.dir, "renamed Java executable", java21);
    try tmp.dir.symLink(io, "renamed Java executable", "Java executable alias", .{});
    const direct = try std.fs.path.join(a, &.{ root, "renamed Java executable" });
    defer a.free(direct);
    const alias = try std.fs.path.join(a, &.{ root, "Java executable alias" });
    defer a.free(alias);
    for ([_][]const u8{ direct, alias }) |path| {
        try manager.search(path);
        try waitSearch(&manager);
        try std.testing.expect(manager.searchFailure() == null);
        try std.testing.expectEqual(@as(usize, 1), manager.searchResults().len);
        try std.testing.expectEqualStrings(direct, manager.searchResults()[0].path);
        try std.testing.expectEqual(@as(u32, 21), manager.searchResults()[0].major);
        try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
    }
}
test "add choose persistence remove references and never delete executables" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeJava(tmp.dir, "Open JDK/bin/java", openjdk25);
    try fakeJava(tmp.dir, "Zulu JDK/bin/java", zulu25);
    try fakeJava(tmp.dir, "Java21/bin/java", java21);
    try tmp.dir.symLink(io, "Open JDK/bin/java", "alias", .{});
    var buf: [4096]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const p1 = try std.fs.path.join(a, &.{ root, "Open JDK/bin/java" });
    defer a.free(p1);
    const p2 = try std.fs.path.join(a, &.{ root, "Zulu JDK/bin/java" });
    defer a.free(p2);
    const p3 = try std.fs.path.join(a, &.{ root, "Java21/bin/java" });
    defer a.free(p3);
    const alias = try std.fs.path.join(a, &.{ root, "alias" });
    defer a.free(alias);
    var manager = try Manager.init(a, io, root);
    defer manager.deinit();
    try std.testing.expectError(error.JavaNotInSearchResults, manager.add(&.{p1}));
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
    try manager.search(root);
    try waitSearch(&manager);
    try std.testing.expectError(error.JavaNotInSearchResults, manager.add(&.{alias}));
    try manager.add(&.{ p1, p2, p3, p1 });
    try std.testing.expectEqual(@as(usize, 3), manager.entries().len);
    try std.testing.expectEqualStrings(p1, manager.resolve("unselected", 25).?.path);
    try manager.choose("game", p2, 25);
    try std.testing.expectEqualStrings(p2, manager.selectedPath("game").?);
    try std.testing.expect(manager.resolve("game", 21) == null);
    try std.testing.expectError(error.IncompatibleJava, manager.choose("game", p3, 25));
    try std.testing.expectEqualStrings(p2, manager.resolve("game", 25).?.path);
    {
        var loaded = try Manager.init(a, io, root);
        defer loaded.deinit();
        try std.testing.expectEqual(@as(usize, 3), loaded.entries().len);
        try std.testing.expectEqualStrings(p2, loaded.selectedPath("game").?);
        try std.testing.expect(!loaded.isSearching());
    }
    try manager.remove(p2);
    try std.testing.expect(manager.selectedPath("game") == null);
    try std.testing.expectEqualStrings(p1, manager.resolve("game", 25).?.path);
    _ = try tmp.dir.statFile(io, "Zulu JDK/bin/java", .{});
    var loaded = try Manager.init(a, io, root);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.entries().len);
    try std.testing.expect(loaded.selectedPath("game") == null);
    try std.testing.expectError(error.JavaNotRegistered, manager.remove(p2));
}
test "invalid probes reject version-only fallback timeout cancellation and shutdown" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeJava(tmp.dir, "hostile/java", hostile);
    try fakeJava(tmp.dir, "fallback/java", "#!/bin/sh\nif [ \"$1\" != '-version' ]; then exit 1; fi\nprintf '%s\\n' 'java version \"1.8.0_452\"' >&2\n");
    try fakeJava(tmp.dir, "invalid", "#!/bin/sh\nprintf '%s\\n' 'not a JVM'\n");
    var buf: [4096]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const bad = try std.fs.path.join(a, &.{ root, "hostile/java" });
    defer a.free(bad);
    const fallback = try std.fs.path.join(a, &.{ root, "fallback/java" });
    defer a.free(fallback);
    const invalid = try std.fs.path.join(a, &.{ root, "invalid" });
    defer a.free(invalid);
    try std.testing.expectError(error.InvalidJavaExecutable, probe(a, io, fallback, null));
    try std.testing.expectError(error.InvalidJavaVersion, probe(a, io, invalid, null));
    const start = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.JavaProbeTimedOut, probe(a, io, bad, null));
    try std.testing.expect(elapsed(io, start) < 4000 * std.time.ns_per_ms);
    var flag: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Canceled, probe(a, io, bad, &flag));
    var manager = try Manager.init(a, io, root);
    defer manager.deinit();
    const search_root = try std.fs.path.join(a, &.{ root, "hostile" });
    defer a.free(search_root);
    try manager.search(search_root);
    try std.Io.sleep(io, .fromMilliseconds(30), .awake);
    manager.cancelSearch();
    try waitSearch(&manager);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), manager.searchFailure());
    try std.testing.expectEqual(@as(usize, 0), manager.searchResults().len);
    var shutdown = try Manager.init(a, io, root);
    try shutdown.search(search_root);
    try std.Io.sleep(io, .fromMilliseconds(30), .awake);
    const shutdown_start = std.Io.Clock.awake.now(io);
    shutdown.deinit();
    try std.testing.expect(elapsed(io, shutdown_start) < 3000 * std.time.ns_per_ms);
}
test "failed search bounded malformed load and transactional save rollback" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeJava(tmp.dir, "bin/java", java21);
    var buf: [4096]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const java = try std.fs.path.join(a, &.{ root, "bin/java" });
    defer a.free(java);
    const missing = try std.fs.path.join(a, &.{ root, "missing" });
    defer a.free(missing);
    var manager = try Manager.init(a, io, root);
    defer manager.deinit();
    try manager.search(missing);
    try waitSearch(&manager);
    try std.testing.expect(manager.searchFailure() != null);
    try std.testing.expectEqual(@as(usize, 0), manager.searchResults().len);
    try std.testing.expectError(error.JavaNotInSearchResults, manager.add(&.{java}));
    try manager.search(root);
    try waitSearch(&manager);
    try manager.add(&.{java});
    try manager.choose("game", java, 21);
    const stable = manager.entries()[0].path;
    // A directory at the registry destination forces atomic replacement to fail.
    try tmp.dir.deleteFile(io, ".vela/java.json");
    try tmp.dir.createDir(io, ".vela/java.json", .default_dir);
    if (manager.remove(java)) |_| return error.ExpectedSaveFailure else |_| {}
    try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
    try std.testing.expectEqualStrings(stable, manager.selectedPath("game").?);
    if (manager.choose("other", java, 21)) |_| return error.ExpectedSaveFailure else |_| {}
    try std.testing.expect(manager.selectedPath("other") == null);
    if (manager.add(&.{java})) |_| return error.ExpectedSaveFailure else |_| {}
    try std.testing.expectEqualStrings(stable, manager.entries()[0].path);
    try tmp.dir.deleteDir(io, ".vela/java.json");
    try tmp.dir.writeFile(io, .{ .sub_path = ".vela/java.json", .data = "{\"version\":99}" });
    try std.testing.expectError(error.InvalidJavaRegistry, Manager.init(a, io, root));
    try tmp.dir.writeFile(io, .{ .sub_path = ".vela/java.json", .data = "not json" });
    if (Manager.init(a, io, root)) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.ExpectedLoadFailure;
    } else |_| {}
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "empty search path explicitly searches PATH without adding" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeJava(tmp.dir, "Open JDK/bin/java", openjdk25);
    try fakeJava(tmp.dir, "Zulu JDK/bin/java", zulu25);
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const old = if (std.c.getenv("PATH")) |value| try a.dupeSentinel(u8, std.mem.span(value), 0) else null;
    defer if (old) |value| a.free(value);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/Open JDK/bin:{s}/Zulu JDK/bin:{s}/Open JDK/bin", .{ root, root, root }, 0);
    defer a.free(path);
    try std.testing.expectEqual(@as(c_int, 0), setenv("PATH", path.ptr, 1));
    defer {
        _ = if (old) |value| setenv("PATH", value.ptr, 1) else unsetenv("PATH");
    }
    var manager = try Manager.init(a, io, root);
    defer manager.deinit();
    try std.testing.expect(!manager.isSearching());
    try std.testing.expectEqual(@as(usize, 0), manager.searchResults().len);
    try manager.search("");
    try waitSearch(&manager);
    try std.testing.expect(manager.searchFailure() == null);
    try std.testing.expectEqual(@as(usize, 2), manager.searchResults().len);
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
}

fn fixturePid(a: Allocator, io: std.Io, executable: []const u8) !std.posix.pid_t {
    const path = try std.mem.concat(a, u8, &.{ executable, ".pid" });
    defer a.free(path);
    const bytes = try Dir.cwd().readFileAlloc(io, path, a, .limited(32));
    defer a.free(bytes);
    return std.fmt.parseInt(std.posix.pid_t, bytes, 10);
}

fn expectReaped(pid: std.posix.pid_t) !void {
    var status: c_int = undefined;
    const result = std.c.waitpid(pid, &status, std.posix.W.NOHANG);
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(result));
}

test "capture bounds stdout and stderr and reaps overflowing children" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const path = try std.fs.path.join(a, &.{ root, "flood" });
    defer a.free(path);
    for ([_][]const u8{ "", " >&2" }) |redirect| {
        const script = try std.fmt.allocPrint(a, "#!/bin/sh\nprintf '%s' \"$$\" > \"$0.pid\"\ntrap '' TERM\nwhile :; do printf '%s' '0123456789012345678901234567890123456789012345678901234567890123456789'{s}; done\n", .{redirect});
        defer a.free(script);
        try fakeJava(tmp.dir, "flood", script);
        const start = std.Io.Clock.awake.now(io);
        try std.testing.expectError(error.StreamTooLong, capture(a, io, &.{path}, null));
        try std.testing.expect(elapsed(io, start) < 1500 * std.time.ns_per_ms);
        try expectReaped(try fixturePid(a, io, path));
    }
}

const CancelFixture = struct {
    path: []const u8,
    canceled: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    fn run(self: *CancelFixture) void {
        const result = capture(std.testing.allocator, std.testing.io, &.{self.path}, &self.canceled) catch |err| {
            self.failure = err;
            return;
        };
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
};

test "mid-probe cancellation after pipe EOF terminates and reaps" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeJava(tmp.dir, "hang", "#!/bin/sh\ntrap '' TERM\nprintf '%s' \"$$\" > \"$0.pid\"\nexec 1>&- 2>&-\nwhile :; do :; done\n");
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const path = try std.fs.path.join(a, &.{ root, "hang" });
    defer a.free(path);
    var task: CancelFixture = .{ .path = path };
    const thread = try std.Thread.spawn(.{}, CancelFixture.run, .{&task});
    var joined = false;
    defer if (!joined) {
        task.canceled.store(true, .release);
        thread.join();
    };
    const start = std.Io.Clock.awake.now(io);
    const pid = while (elapsed(io, start) < 1500 * std.time.ns_per_ms) {
        if (fixturePid(a, io, path)) |pid| break pid else |_| {}
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    } else return error.FixtureDidNotStart;
    task.canceled.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), task.failure);
    try std.testing.expect(elapsed(io, start) < 1500 * std.time.ns_per_ms);
    try expectReaped(pid);
}

test "failed POSIX exec leaves no waitable child" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeJava(tmp.dir, "broken", "#!/vela-test-nonexistent-interpreter\n");
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const path = try std.fs.path.join(a, &.{ root, "broken" });
    defer a.free(path);
    try expectReaped(-1);
    try std.testing.expectError(error.JavaProbeSpawnFailed, capture(a, io, &.{path}, null));
    try expectReaped(-1);
}

const JoinSearchFixture = struct {
    fn work(job: *Job, late_result: bool) void {
        defer job.done.store(true, .release);
        if (late_result) return;
        while (!job.canceled.load(.acquire)) {
            job.io.sleep(.fromMilliseconds(1), .awake) catch |err| {
                job.failure = err;
                return;
            };
        }
        job.results = &.{};
        job.failure = error.Canceled;
    }

    fn start(manager: *Manager, late_result: bool) !*Job {
        const job = try std.heap.page_allocator.create(Job);
        job.* = .{ .io = manager.io, .path = "" };
        errdefer job.destroy();
        if (late_result) job.results = &.{.{ .path = "fixture/java", .major = 21, .vendor = "Fixture", .architecture = .x86_64 }};
        job.thread = try std.Thread.spawn(.{}, work, .{ job, late_result });
        manager.active = job;
        return job;
    }
};

test "search cancelAndJoin is synchronous idempotent and leaves manager reusable" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var manager = try Manager.init(a, io, root);
    defer manager.deinit();
    const state = manager.state;
    manager.cancelAndJoin();
    try std.testing.expect(manager.active == null and manager.published == null);
    const job = try JoinSearchFixture.start(&manager, false);
    manager.cancelAndJoin();
    try std.testing.expect(job.done.load(.acquire) and job.canceled.load(.acquire));
    try std.testing.expect(job.thread == null and manager.active == null);
    try std.testing.expectEqual(job, manager.published.?);
    try std.testing.expect(manager.failure.? == error.Canceled);
    try std.testing.expectEqual(@as(usize, 0), manager.searchResults().len);
    manager.cancelAndJoin();
    manager.tick();
    try std.testing.expectEqual(job, manager.published.?);
    try std.testing.expectEqual(state, manager.state);
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
    _ = try JoinSearchFixture.start(&manager, false);
    manager.cancelAndJoin();
    try std.testing.expect(manager.active == null and manager.published.?.thread == null);
    try std.testing.expectEqual(state, manager.state);
}

test "search cancelAndJoin consumes late results without rewriting successful discovery" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var manager = try Manager.init(a, io, root);
    defer manager.deinit();
    const state = manager.state;
    const job = try JoinSearchFixture.start(&manager, true);
    for (0..1500) |_| {
        if (job.done.load(.acquire)) break;
        try io.sleep(.fromMilliseconds(2), .awake);
    } else return error.FixtureTimedOut;
    manager.cancelAndJoin();
    try std.testing.expect(job.canceled.load(.acquire) and job.thread == null);
    try std.testing.expect(manager.active == null and manager.failure == null);
    try std.testing.expectEqual(job, manager.published.?);
    try std.testing.expectEqual(@as(usize, 1), manager.searchResults().len);
    try std.testing.expectEqualStrings("fixture/java", manager.searchResults()[0].path);
    manager.cancelAndJoin();
    manager.tick();
    try std.testing.expectEqual(job, manager.published.?);
    try std.testing.expectEqual(state, manager.state);
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
}

test "hidden metadata persists filters choices and survives forgetting until explicit restore" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const first_path = try std.fs.path.join(a, &.{ root, "first", "bin", java_name });
    defer a.free(first_path);
    const second_path = try std.fs.path.join(a, &.{ root, "second", "bin", java_name });
    defer a.free(second_path);
    const first: Runtime = .{ .path = first_path, .major = 21, .vendor = "OpenJDK", .architecture = .x86 };
    const second: Runtime = .{ .path = second_path, .major = 21, .vendor = "Zulu", .architecture = java_runtime.host() };
    var manager = try Manager.init(a, io, root);
    defer manager.deinit();
    try manager.addDownloaded(first);
    try manager.addDownloaded(second);
    try manager.choose("game", first_path, 21);
    try manager.hide(first_path);
    try std.testing.expect(manager.isHidden(first_path));
    try std.testing.expectEqual(@as(usize, 2), manager.allEntries().len);
    try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
    try std.testing.expect(manager.selectedPath("game") == null);
    try std.testing.expectEqualStrings(second_path, manager.resolve("game", 21).?.path);
    try std.testing.expectError(error.JavaHidden, manager.choose("game", first_path, 21));
    try std.testing.expectError(error.JavaHidden, manager.add(&.{first_path}));
    try std.testing.expectError(error.JavaHidden, manager.addDownloaded(first));
    {
        var loaded = try Manager.init(a, io, root);
        defer loaded.deinit();
        try std.testing.expect(loaded.isHidden(first_path));
        try std.testing.expectEqual(java_runtime.Architecture.x86, loaded.hiddenEntries()[0].architecture);
        try std.testing.expectEqual(@as(usize, 1), loaded.entries().len);
        try std.testing.expectEqual(java_runtime.host(), loaded.entries()[0].architecture);
        try std.testing.expect(loaded.selectedPath("game") == null);
        try std.testing.expectEqualStrings(second_path, loaded.resolve("game", 21).?.path);
    }
    try manager.forget(first_path);
    try std.testing.expect(manager.isHidden(first_path));
    try std.testing.expectEqual(@as(usize, 1), manager.allEntries().len);
    {
        var loaded = try Manager.init(a, io, root);
        defer loaded.deinit();
        try std.testing.expect(loaded.isHidden(first_path));
        try std.testing.expectEqual(@as(usize, 1), loaded.allEntries().len);
    }
    try manager.unhide(first_path);
    try std.testing.expect(!manager.isHidden(first_path));
    try std.testing.expectEqual(@as(usize, 0), manager.hiddenEntries().len);
    try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
    try std.testing.expectError(error.JavaNotRegistered, manager.choose("game", first_path, 21));
}

test "scanned hidden paths stay suppressed on fresh publication without auto registration" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const path = try std.fs.path.join(a, &.{ root, "scanned", java_name });
    defer a.free(path);
    const runtime: Runtime = .{ .path = path, .major = 25, .vendor = "Zulu", .architecture = .aarch64 };
    var manager = try Manager.init(a, io, root);
    defer manager.deinit();
    const results = [_]Runtime{runtime};
    const first = try std.heap.page_allocator.create(Job);
    first.* = .{ .io = io, .path = "", .results = &results };
    first.done.store(true, .release);
    manager.active = first;
    manager.tick();
    try std.testing.expectEqual(@as(usize, 1), manager.searchResults().len);
    try manager.hide(path);
    try std.testing.expectEqual(@as(usize, 0), manager.searchResults().len);
    try std.testing.expect(manager.resolve("unselected", 25) == null);
    try manager.forget(path);
    const next = try std.heap.page_allocator.create(Job);
    next.* = .{ .io = io, .path = "", .results = &results };
    next.done.store(true, .release);
    manager.active = next;
    manager.tick();
    try std.testing.expectEqual(@as(usize, 0), manager.searchResults().len);
    try std.testing.expectEqual(@as(usize, 0), manager.allEntries().len);
    try manager.unhide(path);
    try std.testing.expectEqual(@as(usize, 1), manager.searchResults().len);
    try std.testing.expectEqual(@as(usize, 0), manager.entries().len);
    try manager.add(&.{path});
    try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
}

test "failed hidden save leaves registry choices and visible snapshots intact" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const path = try std.fs.path.join(a, &.{ root, "bin", java_name });
    defer a.free(path);
    var manager = try Manager.init(a, io, root);
    defer manager.deinit();
    try manager.addDownloaded(.{ .path = path, .major = 21, .vendor = "OpenJDK", .architecture = .x86_64 });
    try manager.choose("game", path, 21);
    try tmp.dir.createDir(io, "blocked", .default_dir);
    const original_file = manager.file;
    manager.file = try std.fs.path.join(a, &.{ root, "blocked" });
    defer {
        a.free(manager.file);
        manager.file = original_file;
    }
    const original_state = manager.state;
    if (manager.hide(path)) |_| return error.ExpectedSaveFailure else |_| {}
    try std.testing.expectEqual(original_state, manager.state);
    try std.testing.expect(!manager.isHidden(path));
    try std.testing.expectEqual(@as(usize, 1), manager.entries().len);
    try std.testing.expectEqualStrings(path, manager.selectedPath("game").?);
}

test "probe rejects missing unknown and contradictory architecture properties" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const path = try std.fs.path.join(a, &.{ root, "java" });
    defer a.free(path);
    const cases = [_]struct { properties: []const u8, failure: anyerror }{
        .{ .properties = "sun.arch.data.model = 64", .failure = error.MissingJavaArchitecture },
        .{ .properties = "os.arch = riscv64", .failure = error.UnsupportedJavaArchitecture },
        .{ .properties = "os.arch = amd64\nsun.arch.data.model = 32", .failure = error.JavaArchitectureDataModelMismatch },
    };
    for (cases) |case| {
        const script = try std.fmt.allocPrint(a, "#!/bin/sh\nprintf '%s\\n' 'java.version = 21' 'java.vendor = Test JVM' '{s}' >&2\n", .{case.properties});
        defer a.free(script);
        try fakeJava(tmp.dir, "java", script);
        try std.testing.expectError(case.failure, probe(a, io, path, null));
    }
    try fakeJava(tmp.dir, "java", zulu25);
    const runtime = try probe(a, io, path, null);
    defer freeRuntime(a, runtime);
    try std.testing.expectEqual(java_runtime.Architecture.aarch64, runtime.architecture);
}

test "registry v2 rejects old schemas and missing or unknown architecture" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try tmp.dir.createDirPath(io, ".vela");
    for ([_][]const u8{
        "{\"version\":1,\"runtimes\":[],\"choices\":[],\"hidden\":[]}",
        "{\"runtimes\":[],\"choices\":[],\"hidden\":[]}",
    }) |json| {
        try tmp.dir.writeFile(io, .{ .sub_path = ".vela/java.json", .data = json });
        try std.testing.expectError(error.InvalidJavaRegistry, Manager.init(a, io, root));
    }
    const path = try std.fs.path.join(a, &.{ root, "java" });
    defer a.free(path);
    const json_path = try std.json.Stringify.valueAlloc(a, path, .{});
    defer a.free(json_path);
    for ([_][]const u8{ "", ",\"architecture\":\"amd64\"", ",\"architecture\":\"riscv64\"" }) |field| {
        const json = try std.fmt.allocPrint(a, "{{\"version\":2,\"runtimes\":[{{\"path\":{s},\"major\":21,\"vendor\":\"Test JVM\"{s}}}],\"choices\":[],\"hidden\":[]}}", .{ json_path, field });
        defer a.free(json);
        try tmp.dir.writeFile(io, .{ .sub_path = ".vela/java.json", .data = json });
        try std.testing.expectError(error.InvalidJavaRegistry, Manager.init(a, io, root));
    }
}

test "architecture-only registration updates survive cloning hiding and reload" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const path = try std.fs.path.join(a, &.{ root, "java" });
    defer a.free(path);
    var runtime: Runtime = .{ .path = path, .major = 21, .vendor = "Test JVM", .architecture = .x86 };
    var manager = try Manager.init(a, io, root);
    defer manager.deinit();
    try manager.addDownloaded(runtime);
    try manager.choose("game", path, 21);
    try std.testing.expectEqual(java_runtime.Architecture.x86, manager.resolve("game", 21).?.architecture);
    runtime.architecture = .aarch64;
    try manager.addDownloaded(runtime);
    try std.testing.expectEqual(java_runtime.Architecture.aarch64, manager.resolve("game", 21).?.architecture);
    {
        var loaded = try Manager.init(a, io, root);
        defer loaded.deinit();
        try std.testing.expectEqual(java_runtime.Architecture.aarch64, loaded.resolve("game", 21).?.architecture);
    }
    try manager.hide(path);
    var loaded = try Manager.init(a, io, root);
    defer loaded.deinit();
    try std.testing.expectEqual(java_runtime.Architecture.aarch64, loaded.hiddenEntries()[0].architecture);
    try std.testing.expectEqual(java_runtime.Architecture.aarch64, loaded.allEntries()[0].architecture);
    try loaded.unhide(path);
    try std.testing.expectEqual(java_runtime.Architecture.aarch64, loaded.entries()[0].architecture);
}
