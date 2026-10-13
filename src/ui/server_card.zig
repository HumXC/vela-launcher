const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const components = @import("components.zig");
const server_manager = @import("server_manager.zig");
const style = @import("style.zig");

pub const Options = struct {
    selected: bool = false,
    enabled: bool = true,
    width: f32,
    tag: []const u8,
    in_grid: bool = false,
    require_instance: bool = true,
};

fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}

/// Shared server target presentation for Home, Choose Game and management.
pub fn draw(src: std.builtin.SourceLocation, server: config.Server, document: *const config.Document, query: server_manager.Snapshot, options: Options) bool {
    const instance = instances.findById(document, server.instance_id);
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
                signal = if (value.latency_ms <= 100) .good else if (value.latency_ms <= 250) .fair else .poor;
                status = if (value.players_online) |online| if (value.players_max) |maximum| fmt("{d}/{d} · {d} ms", .{ online, maximum, value.latency_ms }) else fmt("{d} · {d} ms", .{ online, value.latency_ms }) else fmt("在线 · {d} ms", .{value.latency_ms});
            },
        };
    }
    return components.selectionCard(src, server.id, server.name, .{
        .selected = options.selected,
        .enabled = options.enabled and (!options.require_instance or instance != null),
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
