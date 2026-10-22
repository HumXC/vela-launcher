//! Controlled native process, not a JVM. Only exact Java probe forms or the
//! fixture main class are admitted; game Ready cannot be emitted by a probe.
const std = @import("std");
const Io = std.Io;
const Case = enum { restore, close_preparing, close_running, debug, abnormal, exit_together, idle_keep, idle_wait, idle_cancel, ordinary_destroy };

fn required(env: *const std.process.Environ.Map, key: []const u8) ![]const u8 {
    const value = env.get(key) orelse return error.MissingOwnedEnvironment;
    if (value.len == 0 or value.len > 4096) return error.InvalidOwnedEnvironment;
    return value;
}
fn openOwned(io: Io, root: []const u8) !Io.Dir {
    if (!std.fs.path.isAbsolute(root)) return error.InvalidOwnedRoot;
    var current = try Io.Dir.openDirAbsolute(io, "/", .{ .follow_symlinks = false });
    errdefer current.close(io);
    var parts = std.mem.tokenizeScalar(u8, root, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidOwnedRoot;
        const next = try current.openDir(io, part, .{ .follow_symlinks = false });
        current.close(io);
        current = next;
    }
    return current;
}
fn readOwned(a: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8) ![]u8 {
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > 4096) return error.InvalidOwnedNode;
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(a, .limited(4096));
}
fn released(a: std.mem.Allocator, io: Io, ipc: Io.Dir, name: []const u8, nonce: []const u8) !bool {
    const bytes = try readOwned(a, io, ipc, name);
    defer a.free(bytes);
    return std.mem.eql(u8, bytes, nonce);
}
fn marker(a: std.mem.Allocator, io: Io, ipc: Io.Dir, name: []const u8, value: anytype) !void {
    // Existing inode only, never replace a driver's pinned node.
    const probe = try ipc.openFile(io, name, .{ .mode = .read_write, .follow_symlinks = false });
    defer probe.close(io);
    if ((try probe.stat(io)).kind != .file) return error.InvalidOwnedNode;
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(bytes);
    var padded: [16 * 1024]u8 = @splat(' ');
    if (bytes.len > padded.len) return error.OwnedMarkerTooLarge;
    @memcpy(padded[0..bytes.len], bytes);
    try probe.writePositionalAll(io, &padded, 0);
}
pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .linux) return error.LinuxOnly;
    const a = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const root = try required(init.environ_map, "VELA_LIFECYCLE_ROOT");
    const nonce = try required(init.environ_map, "VELA_LIFECYCLE_NONCE");
    if (nonce.len != 64) return error.InvalidOwnedNonce;
    for (nonce) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.InvalidOwnedNonce;
    if (!std.mem.eql(u8, root, try required(init.environ_map, "VELA_DATA_DIR"))) return error.ForeignOwnedRoot;
    const case = std.meta.stringToEnum(Case, try required(init.environ_map, "VELA_LIFECYCLE_CASE")) orelse return error.InvalidOwnedCase;
    if (!std.mem.eql(u8, args[0], try required(init.environ_map, "VELA_LIFECYCLE_HELPER"))) return error.ForeignExecutable;
    var directory = try openOwned(io, root);
    defer directory.close(io);
    const owner_bytes = try readOwned(a, io, directory, "owner.json");
    defer a.free(owner_bytes);
    const owner = try std.json.parseFromSlice(struct { root: []const u8, nonce: []const u8, case: Case }, a, owner_bytes, .{});
    defer owner.deinit();
    if (!std.mem.eql(u8, owner.value.root, root) or !std.mem.eql(u8, owner.value.nonce, nonce) or owner.value.case != case) return error.ForeignOwnedOwner;
    var ipc = try directory.openDir(io, "ipc", .{ .follow_symlinks = false });
    defer ipc.close(io);
    const probe = (args.len == 3 and std.mem.eql(u8, args[1], "-XshowSettings:properties") and std.mem.eql(u8, args[2], "-version")) or (args.len == 2 and std.mem.eql(u8, args[1], "-version"));
    const pid = std.os.linux.getpid();
    if (probe) {
        try marker(a, io, ipc, "probe.json", .{ .nonce = nonce, .pid = pid, .role = "probe", .ready = false, .held = true, .argv = args });
        // Always retain identity until the driver owns a pidfd; close_preparing
        // additionally keeps this real probe held across compositor close.
        while (!(try released(a, io, ipc, "probe-release", nonce))) try io.sleep(.fromMilliseconds(10), .awake);
        try Io.File.stderr().writeStreamingAll(io, "openjdk version \"21\"\n    java.version = 21\n    java.vendor = Vela Lifecycle Fixture\n    os.arch = " ++ @tagName(builtin.cpu.arch) ++ "\n");
        return;
    }
    const main_index = for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "vela.lifecycle.ControlledGame")) break index;
    } else return error.InvalidGameArguments;
    const extra = args[main_index + 1 ..];
    if (extra.len != 4 or !std.mem.eql(u8, extra[0], "--vela-lifecycle-root") or !std.mem.eql(u8, extra[1], root) or !std.mem.eql(u8, extra[2], "--vela-lifecycle-nonce") or !std.mem.eql(u8, extra[3], nonce)) return error.InvalidGameArguments;
    const cwd = try std.process.currentPathAlloc(io, a);
    defer a.free(cwd);
    const expected = try std.fs.path.join(a, &.{ root, ".minecraft", "versions", "ControlledGame" });
    defer a.free(expected);
    if (!std.mem.eql(u8, cwd, expected)) return error.ForeignGameDirectory;
    const exit_code: u8 = if (case == .abnormal) 7 else 0;
    var ticks: u64 = 0;
    while (true) : (ticks += 1) {
        try marker(a, io, ipc, "game.json", .{ .nonce = nonce, .pid = pid, .role = "game", .ready = true, .ticks = ticks, .cwd = cwd, .argv = args, .exit_code = exit_code, .released = false });
        const stdout_line = try std.fmt.allocPrint(a, "LIFECYCLE_GAME_READY {s} pid={d} tick={d}\n", .{ nonce, pid, ticks });
        defer a.free(stdout_line);
        const stderr_line = try std.fmt.allocPrint(a, "LIFECYCLE_GAME_STDERR {s} tick={d}\n", .{ nonce, ticks });
        defer a.free(stderr_line);
        try Io.File.stdout().writeStreamingAll(io, stdout_line);
        try Io.File.stderr().writeStreamingAll(io, stderr_line);
        if (try released(a, io, ipc, "game-release", nonce)) break;
        try io.sleep(.fromMilliseconds(80), .awake);
    }
    try marker(a, io, ipc, "game.json", .{ .nonce = nonce, .pid = pid, .role = "game", .ready = true, .ticks = ticks, .cwd = cwd, .argv = args, .exit_code = exit_code, .released = true });
    std.process.exit(exit_code);
}
