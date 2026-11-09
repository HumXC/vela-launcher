//! Explicit diagnostic command; never reads or changes launcher configuration.
const std = @import("std");
const servers = @import("core/servers.zig");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len % 2 != 1) return error.ExpectedHostPortPairs;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        const host = args[index];
        const port = try std.fmt.parseInt(u16, args[index + 1], 10);
        var diagnostics: servers.Diagnostics = .{};
        var status = servers.query(init.gpa, init.io, .{ .id = "probe", .name = "Probe", .address = host, .port = port }, .{ .diagnostics = &diagnostics }) catch |err| {
            try output(init, .{ .host = host, .port = port, .ok = false, .error_name = @errorName(err), .phase = @tagName(diagnostics.phase), .elapsed_ms = diagnostics.elapsed_ms });
            continue;
        };
        defer status.deinit();
        try output(init, .{ .host = host, .port = port, .ok = true, .connection = status.connection, .version = status.version, .protocol = status.protocol, .online = status.players_online, .maximum = status.players_max, .latency_ms = status.latency_ms, .motd_bytes = status.motd.len, .has_icon = status.icon != null, .icon_issue = if (status.icon_issue) |err| @errorName(err) else null, .motd_issue = if (status.motd_issue) |err| @errorName(err) else null, .latency_issue = if (status.latency_issue) |err| @errorName(err) else null, .elapsed_ms = diagnostics.elapsed_ms });
    }
}
fn output(init: std.process.Init, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(init.gpa, value, .{});
    defer init.gpa.free(json);
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
    try std.Io.File.stdout().writeStreamingAll(init.io, &.{10});
}
