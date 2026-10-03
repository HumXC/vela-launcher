const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and (std.mem.eql(u8, args[1], "-version") or std.mem.eql(u8, args[1], "--version"))) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "openjdk version \"17.0.1\"\n");
        return;
    }
    if (args.len < 5 or !std.mem.eql(u8, args[1], "-cp")) std.process.exit(90);
    const mode = args[3];
    if (std.mem.eql(u8, mode, "net.minecraftforge.fixture.Main")) {
        if (args.len != 6 or !std.mem.eql(u8, args[4], "--write-output")) std.process.exit(95);
        const cwd = try std.process.currentPathAlloc(init.io, init.arena.allocator());
        const expected = try std.fs.path.join(init.arena.allocator(), &.{ cwd, "libraries/net/minecraftforge/generated/1/generated-1.jar" });
        const expected_jar = try std.fs.path.join(init.arena.allocator(), &.{ cwd, "libraries/net/minecraftforge/fixture/1/fixture-1.jar" });
        if (!std.mem.eql(u8, args[5], expected) or !std.mem.eql(u8, args[2], expected_jar)) std.process.exit(96);
        try std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(expected).?);
        const output = try std.Io.Dir.cwd().createFile(init.io, expected, .{});
        defer output.close(init.io);
        try output.writeStreamingAll(init.io, "abc");
        try std.Io.File.stdout().writeStreamingAll(init.io, "synthetic Forge processor output\n");
        return;
    }
    const pid_file = try std.Io.Dir.cwd().createFile(init.io, args[4], .{});
    defer pid_file.close(init.io);
    var pid_buffer: [32]u8 = undefined;
    const pid = std.c.getpid();
    try pid_file.writeStreamingAll(init.io, try std.fmt.bufPrint(&pid_buffer, "{d}", .{pid}));
    if (std.mem.eql(u8, mode, "argsliteral")) {
        if (args.len != 10) std.process.exit(91);
        if (!std.mem.eql(u8, args[2], "lib one.jar:lib-two.jar")) std.process.exit(92);
        const expected = [_][]const u8{ "", "has space", "$(touch forbidden);&|*?", "\"quoted\"", "-leading" };
        for (args[5..], expected) |actual, want| if (!std.mem.eql(u8, actual, want)) std.process.exit(93);
        const cwd = try std.process.currentPathAlloc(init.io, init.arena.allocator());
        if (!std.mem.eql(u8, cwd, std.fs.path.dirname(args[4]).?)) std.process.exit(94);
        return;
    }
    if (std.mem.eql(u8, mode, "failedexit")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "stdout before failure\n");
        try std.Io.File.stderr().writeStreamingAll(init.io, "stderr before failure\n");
        std.process.exit(17);
    }
    if (std.mem.eql(u8, mode, "signal")) {
        _ = std.posix.system.kill(pid, .TERM);
        unreachable;
    }
    if (std.mem.eql(u8, mode, "floodboth")) {
        const bytes = [_]u8{'x'} ** 8192;
        for (0..128) |_| {
            try std.Io.File.stdout().writeStreamingAll(init.io, &bytes);
            try std.Io.File.stderr().writeStreamingAll(init.io, &bytes);
        }
        return;
    }
    if (std.mem.eql(u8, mode, "closedhang")) {
        _ = std.c.close(1);
        _ = std.c.close(2);
    }
    while (true) try std.Io.sleep(init.io, .fromMilliseconds(10), .awake);
}
