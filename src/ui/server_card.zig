const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const components = @import("components.zig");
const server_manager = @import("../application/server_manager.zig");
const style = @import("style.zig");

pub const Options = struct {
    selected: bool = false,
    enabled: bool = true,
    width: f32,
    tag: []const u8,
    in_grid: bool = false,
};

fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}

/// Shared server target presentation for Home, Choose Game and management.
pub fn draw(src: std.builtin.SourceLocation, server: config.Server, document: *const config.Document, query: server_manager.Snapshot, options: Options) bool {
    const instance = if (server.instance_id) |id| instances.findById(document, id) else null;
    var signal: components.Signal = .unknown;
    var status: []const u8 = "尚未查询";
    if (query.server) |queried| {
        if (std.mem.eql(u8, queried.id, server.id)) switch (query.state) {
            .idle => {},
            .querying => status = "正在查询…",
            .canceled => status = "查询已取消",
            .offline => {
                status = "无法连接";
                signal = .offline;
            },
            .online => if (query.status) |value| {
                if (value.latency_ms) |latency| {
                    signal = if (latency <= 100) .good else if (latency <= 250) .fair else .poor;
                    status = if (value.players_online) |online| if (value.players_max) |maximum| fmt("{d}/{d} · {d} ms", .{ online, maximum, latency }) else fmt("{d} · {d} ms", .{ online, latency }) else fmt("在线 · {d} ms", .{latency});
                } else {
                    status = if (value.players_online) |online| if (value.players_max) |maximum| fmt("{d}/{d} · 延迟未知", .{ online, maximum }) else fmt("{d} · 延迟未知", .{online}) else "在线 · 延迟未知";
                }
            },
        };
    }
    return components.selectionCard(src, server.id, server.name, .{
        .selected = options.selected,
        .enabled = options.enabled,
        .width = options.width,
        .height = if (options.in_grid) style.cards.server_height else 0,
        .compact = !options.in_grid,
        .bounded_text = true,
        .auto_tooltip = false,
        .stretch = options.in_grid,
        .description = if (instance) |value| value.name else "未绑定实例",
        .status = status,
        .signal = signal,
        .tag = options.tag,
    });
}
