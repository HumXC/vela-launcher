const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const state = @import("model.zig");
const components = @import("components.zig");
const card_grid = @import("card_grid.zig");
const theme = @import("theme.zig");
const server_manager = @import("../application/server_manager.zig");
const servers_view = @import("servers_view.zig");
const server_card = @import("server_card.zig");
const R = dvui.Rect;

fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}

fn sameId(selected: ?[]const u8, id: []const u8) bool {
    return if (selected) |value| std.mem.eql(u8, value, id) else false;
}

pub fn selectInstance(store: *config.Store, manager: *server_manager.Manager, id: []const u8) !void {
    var document = store.snapshot().*;
    const instance = instances.findById(&document, id) orelse return error.InstanceNotConfigured;
    document.selected_instance = instance.id;
    document.selected_server = null;
    try store.update(document);
    manager.clear();
}

pub fn selectServer(store: *config.Store, manager: *server_manager.Manager, id: []const u8) !void {
    try servers_view.selectLaunchTarget(store, manager, id);
}

pub fn draw(model: *state.Model, pending: *?state.Msg, document: *const config.Document, manager: *server_manager.Manager, enabled: bool, failure: ?anyerror) void {
    components.title(@src(), "选择游戏");
    if (failure) |err| components.hint(@src(), fmt("选择失败：{s}", .{@errorName(err)}));
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = theme.spacing.page_title_gap } });
    const scroll = components.scrollBody(@src());
    defer scroll.deinit();
    const minimum_width = theme.style.layout.picker_min_width;
    {
        const panel = components.disclosurePanel(@src(), "game-instances", "游戏实例", &model.game_instances_expanded, .{ .tag = "game-instances-panel" });
        defer panel.deinit();
        if (model.game_instances_expanded) {
            if (document.instances.len == 0) components.emptyState(@src(), "暂无游戏实例，可在实例管理中新建或导入。");
            var cards = card_grid.init(@src(), document.instances.len, .{ .min_width = minimum_width, .max_columns = theme.style.layout.picker_columns, .gap = theme.style.cards.picker_gap, .tag = "game-instance-cards" });
            for (document.instances, 0..) |instance, index| {
                const cell = cards.cell(@src(), index, instance.id);
                defer cell.deinit();
                if (components.selectionCard(@src(), instance.id, instance.name, .{
                    .selected = document.selected_server == null and sameId(document.selected_instance, instance.id),
                    .enabled = enabled,
                    .width = cards.cardWidth(index),
                    .height = theme.style.cards.game_height,
                    .stretch = true,
                    .bounded_text = true,
                    .description = instanceDescription(&instance),
                    .tag = fmt("game-instance-{s}", .{instance.id}),
                })) pending.* = .{ .select_instance = instance.id };
            }
            cards.deinit();
        }
    }
    {
        const panel = components.disclosurePanel(@src(), "game-servers", "服务器", &model.game_servers_expanded, .{ .tag = "game-servers-panel" });
        defer panel.deinit();
        if (model.game_servers_expanded) {
            const count = document.servers.len;
            var cards = card_grid.init(@src(), count, .{ .min_width = minimum_width, .max_columns = theme.style.layout.picker_columns, .gap = theme.style.cards.picker_gap, .tag = "game-server-cards" });
            for (document.servers, 0..) |server, index| {
                const cell = cards.cell(@src(), index, server.id);
                defer cell.deinit();
                if (serverCardInGrid(@src(), server, document, manager.pickerSnapshot(server.id), sameId(document.selected_server, server.id), enabled, cards.cardWidth(index), fmt("game-server-{s}", .{server.id}))) pending.* = .{ .select_server = server.id };
            }
            cards.deinit();
            if (count == 0) components.emptyState(@src(), "暂无服务器");
        }
    }
    if (!enabled) components.hint(@src(), "当前任务暂时锁定游戏选择，请稍后重试。");
}

pub fn instanceDescription(instance: *const config.Instance) []const u8 {
    return if (instance.loader == .vanilla) fmt("Minecraft {s}", .{instance.minecraft_version}) else fmt("Minecraft {s} · {s}", .{ instance.minecraft_version, @tagName(instance.loader) });
}

/// Shared target presentation for the picker and the current sidebar target.
pub fn serverCard(src: std.builtin.SourceLocation, server: config.Server, document: *const config.Document, query: server_manager.Snapshot, selected: bool, enabled: bool, width: f32, tag: []const u8) bool {
    return server_card.draw(src, server, document, query, .{ .selected = selected, .enabled = enabled, .width = width, .tag = tag });
}

fn serverCardInGrid(src: std.builtin.SourceLocation, server: config.Server, document: *const config.Document, query: server_manager.Snapshot, selected: bool, enabled: bool, width: f32, tag: []const u8) bool {
    return server_card.draw(src, server, document, query, .{ .selected = selected, .enabled = enabled, .width = width, .tag = tag, .in_grid = true });
}
