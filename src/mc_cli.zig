//! Headless vanilla Minecraft installation and offline launch entry point.
const std = @import("std");
const builtin = @import("builtin");
const curl = @import("curl");
const downloader = @import("core/downloader.zig");
const install = @import("core/minecraft/install.zig");
const launch = @import("core/minecraft/launch.zig");
const metadata = @import("core/minecraft/metadata/root.zig");
const java_process = @import("core/loaders/java_process.zig");

const usage =
    \\Usage: vela-mc <install|launch> <version> [options]
    \\  --root PATH          Game directory (default .minecraft)
    \\  --manifest-url URL   Version manifest (default Mojang)
    \\  --proxy URL          HTTP/SOCKS proxy (empty disables proxy)
    \\  --ca-bundle PATH     PEM CA bundle
    \\  --java PATH          Java executable (default java)
    \\  --username NAME      Offline player name (default Player)
    \\  --memory MB          Maximum Java heap (default 2048)
    \\  --jvm-arg ARG        Extra JVM token; repeat for each token
    \\  --game-arg ARG       Extra game token; repeat for each token
    \\  --dry-run            Validate Java and arguments without starting game
    \\Offline identity only; Microsoft login and Java installation are not implemented.
    \\
;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("vela-mc: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 1 or (args.len == 2 and std.mem.eql(u8, args[1], "--help"))) {
        std.debug.print("{s}", .{usage});
        return;
    }
    if (args.len < 3) return error.InvalidArguments;
    const do_launch = std.mem.eql(u8, args[1], "launch");
    if (!do_launch and !std.mem.eql(u8, args[1], "install")) return error.UnknownCommand;
    var root: []const u8 = ".minecraft";
    var manifest_url: []const u8 = metadata.version_manifest_url;
    var proxy: ?[]const u8 = null;
    var ca_bundle: ?[]const u8 = null;
    var java: []const u8 = "java";
    var username: []const u8 = "Player";
    var memory: u32 = 2048;
    var dry_run = false;
    var extra_jvm: std.ArrayList([]const u8) = .empty;
    defer extra_jvm.deinit(a);
    var extra_game: std.ArrayList([]const u8) = .empty;
    defer extra_game.deinit(a);
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const key = args[i];
        if (std.mem.eql(u8, key, "--dry-run")) {
            dry_run = true;
            continue;
        }
        i += 1;
        if (i == args.len) return error.MissingOptionValue;
        const value = args[i];
        if (std.mem.eql(u8, key, "--root")) root = value else if (std.mem.eql(u8, key, "--manifest-url")) manifest_url = value else if (std.mem.eql(u8, key, "--proxy")) proxy = value else if (std.mem.eql(u8, key, "--ca-bundle")) ca_bundle = value else if (std.mem.eql(u8, key, "--java")) java = value else if (std.mem.eql(u8, key, "--username")) username = value else if (std.mem.eql(u8, key, "--memory")) memory = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "--jvm-arg")) try extra_jvm.append(a, value) else if (std.mem.eql(u8, key, "--game-arg")) try extra_game.append(a, value) else return error.UnknownOption;
    }
    if (memory == 0 or username.len == 0 or username.len > 16) return error.InvalidArguments;
    for (username) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidUsername;
    const cwd = try std.process.currentPathAlloc(io, a);
    defer a.free(cwd);
    const absolute_root = try std.fs.path.resolve(a, &.{ cwd, root });
    defer a.free(absolute_root);
    // An executable containing a separator is relative to the caller, not the game cwd.
    const java_path = if (std.mem.indexOfAny(u8, java, "/\\") != null) try std.fs.path.resolve(a, &.{ cwd, java }) else try a.dupe(u8, java);
    defer a.free(java_path);
    const environment: metadata.rules.Environment = .{
        .os_name = switch (builtin.os.tag) {
            .linux => "linux",
            else => return error.UnsupportedOperatingSystem,
        },
        .arch = switch (builtin.cpu.arch) {
            .x86_64 => "amd64",
            .x86 => "x86",
            .aarch64 => "aarch64",
            else => return error.UnsupportedArchitecture,
        },
    };
    try curl.globalInit();
    defer curl.globalDeinit();
    const service = try downloader.Service.init(a, io, 16);
    defer service.deinit();
    std.debug.print("Installing {s} into {s}\n", .{ args[2], absolute_root });
    var installed = try install.run(a, io, service, .{
        .version_id = args[2],
        .target = .{ .directory_name = args[2], .name = args[2] },
        .root = absolute_root,
        .manifest_url = manifest_url,
        .environment = environment,
        .proxy = proxy,
        .ca_bundle = ca_bundle,
        .progress = reportProgress,
    });
    defer installed.deinit();
    std.debug.print("Ready: {d} downloaded, {d} reused\n", .{ installed.downloaded, installed.reused });
    if (!do_launch) return;
    const required_java = if (installed.version.value.java_version) |v| v.major_version else 8;
    try checkJava(a, io, java_path, required_java);
    const uuid = offlineUuid(username);
    var command = try launch.build(a, installed.version.value, installed.plan.value, environment, .{
        .root = absolute_root,
        .java_executable = java_path,
        .identity = .{ .name = username, .uuid = &uuid },
        .max_memory_mb = memory,
        .extra_jvm = extra_jvm.items,
        .extra_game = extra_game.items,
    });
    defer command.deinit();
    if (dry_run) {
        std.debug.print("Launch validated: {d} arguments, cwd={s}\n", .{ command.value.argv.len, command.value.cwd });
        return;
    }
    std.debug.print("Launching {s} as offline player {s}\n", .{ args[2], username });
    var child = try std.process.spawn(io, .{ .argv = command.value.argv, .cwd = .{ .path = command.value.cwd } });
    defer child.kill(io);
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) {
            std.debug.print("Java exited with code {d}\n", .{code});
            return error.GameProcessFailed;
        },
        else => return error.GameProcessTerminated,
    }
}

fn reportProgress(p: install.Progress) void {
    if (p.completed == p.total or p.completed % 100 == 0)
        std.debug.print("Files {d}/{d} ({d} downloaded, {d} reused)\n", .{ p.completed, p.total, p.downloaded, p.reused });
}

fn checkJava(a: std.mem.Allocator, io: std.Io, java: []const u8, required: u64) !void {
    var clock_io = io;
    const major = try java_process.probe(a, io, java, .{
        .deadline_ms = javaProbeNow(&clock_io) +| 10 * std.time.ms_per_s,
        .context = &clock_io,
        .now_ms = javaProbeNow,
    });
    if (major < required) {
        std.debug.print("Java {d} required; selected Java {d}\n", .{ required, major });
        return error.JavaTooOld;
    }
}

fn javaProbeNow(context: ?*anyopaque) u64 {
    const io: *const std.Io = @ptrCast(@alignCast(context.?));
    return @intCast(@max(0, @divFloor(std.Io.Clock.awake.now(io.*).nanoseconds, std.time.ns_per_ms)));
}

fn offlineUuid(name: []const u8) [32]u8 {
    var hash = std.crypto.hash.Md5.init(.{});
    hash.update("OfflinePlayer:");
    hash.update(name);
    var bytes: [16]u8 = undefined;
    hash.final(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x30;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.bytesToHex(bytes, .lower);
}

test {
    _ = @import("core/minecraft/root.zig");
    _ = @import("core/launch_test.zig");
}
