const std = @import("std");
const dvui = @import("dvui");
const state = @import("model.zig");
const games = @import("game_library.zig");
const components = @import("components.zig");
const card_grid = @import("card_grid.zig");
const theme = @import("theme.zig");
const R = dvui.Rect;

pub const Command = union(enum) { load, cancel };

fn gap(src: std.builtin.SourceLocation, height: f32) void {
    _ = dvui.spacer(src, .{ .min_size_content = .{ .h = height } });
}

fn footer(model: *const state.Model, pending: *?state.Msg, with_back: bool) void {
    switch (components.navigationFooter(@src(), model.parentLabel(), with_back)) {
        .back => pending.* = model.parentMessage(),
        .home => pending.* = .back,
        .none => {},
    }
}

pub fn moreMenu(model: *const state.Model, pending: *?state.Msg) void {
    const side = components.sidebarPanel(@src());
    defer side.deinit();
    footer(model, pending, false);
    components.title(@src(), "更多");
    gap(@src(), theme.spacing.sidebar_header_gap);
    if (components.sidebarItem(@src(), "game", "游戏", .{ .icon = dvui.entypo.game_controller, .selected = model.category == .game })) pending.* = .{ .select_category = .game };
    if (components.sidebarItem(@src(), "settings", "设置", .{ .icon = dvui.entypo.cog, .selected = model.category == .settings })) pending.* = .{ .select_category = .settings };
    if (components.sidebarItem(@src(), "theme", "主题", .{ .icon = dvui.entypo.brush, .selected = model.category == .theme })) pending.* = .{ .select_category = .theme };
}

pub fn moreContent(model: *const state.Model, pending: *?state.Msg) void {
    switch (model.category) {
        .game => {
            components.title(@src(), "游戏");
            gap(@src(), theme.spacing.page_title_gap);
            const scroll = components.scrollBody(@src());
            defer scroll.deinit();
            const entries = .{
                .{ "实例管理", dvui.entypo.box, state.Msg.open_instances },
                .{ "资源管理", dvui.entypo.layers, state.Msg.open_mods },
                .{ "存档管理", dvui.entypo.folder, state.Msg.open_worlds },
                .{ "Java 管理", dvui.entypo.cog, state.Msg.open_java },
                .{ "服务器", dvui.entypo.network, state.Msg.open_servers },
            };
            var cards = card_grid.init(@src(), entries.len, .{ .min_width = 240, .tag = "game-tool-cards" });
            defer cards.deinit();
            inline for (entries, 0..) |entry, index| {
                const cell = cards.cell(@src(), index, entry[0]);
                defer cell.deinit();
                if (components.managementCard(@src(), entry[0], entry[1])) pending.* = entry[2];
            }
        },
        .theme => {},
        .settings => {
            components.title(@src(), "设置");
            gap(@src(), theme.spacing.page_title_gap);
            components.emptyState(@src(), "暂无功能");
        },
    }
}

pub fn beginUtilityMenu(name: []const u8) *dvui.BoxWidget {
    const side = components.sidebarPanel(@src());
    components.title(@src(), name);
    gap(@src(), theme.spacing.sidebar_header_gap);
    return side;
}

pub fn utilityMenuFooter(model: *const state.Model, pending: *?state.Msg) void {
    footer(model, pending, true);
}

pub fn utilityMenu(model: *const state.Model, pending: *?state.Msg, name: []const u8) void {
    const side = beginUtilityMenu(name);
    defer side.deinit();
    utilityMenuFooter(model, pending);
}

pub fn hasInstalled(snapshot: games.Snapshot, id: []const u8) bool {
    for (snapshot.installed) |entry| if (std.mem.eql(u8, entry.id, id)) return true;
    return false;
}
