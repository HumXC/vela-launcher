const std = @import("std");
const dvui = @import("dvui");
const state = @import("model.zig");
const games = @import("game_library.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const R = dvui.Rect;

pub const Command = union(enum) { load, cancel };

fn title(src: std.builtin.SourceLocation, name: []const u8) void {
    dvui.labelNoFmt(src, name, .{}, .{ .font = dvui.themeGet().font_title, .margin = R.all(0), .padding = R.all(0), .expand = .horizontal });
}
fn muted(src: std.builtin.SourceLocation, text: []const u8) void {
    dvui.labelNoFmt(src, text, .{}, .{ .font = dvui.themeGet().font_body.withSize(14), .color_text = .{ .color = theme.muted }, .margin = R.all(0), .padding = R.all(0), .expand = .horizontal });
}
fn gap(src: std.builtin.SourceLocation, height: f32) void {
    _ = dvui.spacer(src, .{ .min_size_content = .{ .h = height } });
}
fn menu(src: std.builtin.SourceLocation) *dvui.BoxWidget {
    return dvui.box(src, .{}, .{ .expand = .both, .padding = R.all(24), .margin = .{ .x = 16, .y = 16, .h = 16 }, .corners = .all(8), .background = true, .color_fill = .{ .color = theme.surface } });
}
fn iconCommand(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, disabled: bool, show_tooltip: bool, opts: dvui.Options) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = disabled }, (dvui.Options{ .min_size_content = .{ .w = 20, .h = 20 }, .padding = R.all(10), .margin = R.all(0), .corners = .all(8), .border = R.all(0), .label = .{ .text = name }, .tab_index = if (disabled) 0 else null }).override(opts));
    defer button.deinit();
    if (!disabled) button.processEvents();
    button.drawBackground();
    dvui.icon(@src(), name, asset, .{}, button.style().override(.{ .min_size_content = .{ .w = 20, .h = 20 }, .padding = R.all(0), .margin = R.all(0), .gravity_x = 0.5, .gravity_y = 0.5, .role = .none }));
    if (!disabled) button.drawFocus();
    if (show_tooltip) components.tooltip(src, button.data().id, button.data().borderRectScale().r, name);
    return !disabled and button.clicked();
}
fn navItem(src: std.builtin.SourceLocation, id: usize, name: []const u8, asset: ?[]const u8, selected: bool) bool {
    const key = std.fmt.allocPrint(dvui.currentWindow().arena(), "navigation-{d}", .{id}) catch name;
    return components.sidebarItem(src, key, name, .{ .icon = asset, .selected = selected });
}
fn footer(model: *const state.Model, pending: *?state.Msg, with_back: bool) void {
    const content_height = @max(24, dvui.themeGet().font_body.textSize(model.labels.home).h);
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 1, .min_size_content = .{ .h = content_height + 20 }, .margin = .{ .y = 16 } });
    defer row.deinit();
    if (with_back) {
        if (iconCommand(@src(), "返回更多", dvui.entypo.arrow_left, false, false, .{ .min_size_content = .{ .w = 20, .h = content_height }, .gravity_y = 0.5, .margin = .{ .w = 8 } })) pending.* = switch (model.panel) {
            .java => .java_back,
            .servers, .logs, .instances, .content, .worlds => .utility_back,
            else => .library_back,
        };
    }
    if (components.sidebarItem(@src(), "home", model.labels.home, .{})) pending.* = .back;
}

pub fn moreMenu(model: *const state.Model, pending: *?state.Msg) void {
    const side = menu(@src());
    defer side.deinit();
    footer(model, pending, false);
    title(@src(), "更多");
    gap(@src(), 24);
    if (navItem(@src(), 0, "游戏", dvui.entypo.game_controller, model.category == .game)) pending.* = .{ .select_category = .game };
    if (navItem(@src(), 2, "设置", dvui.entypo.cog, model.category == .settings)) pending.* = .{ .select_category = .settings };
}

pub fn moreContent(model: *const state.Model, pending: *?state.Msg) void {
    switch (model.category) {
        .game => {
            title(@src(), "游戏");
            gap(@src(), 24);
            const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .padding = R.all(0), .margin = R.all(0), .border = R.all(0) });
            defer scroll.deinit();
            const cards = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .padding = R.all(0), .margin = R.all(0) });
            defer cards.deinit();
            if (managementCard(@src(), "实例管理", dvui.entypo.box)) pending.* = .open_instances;
            if (managementCard(@src(), "存档管理", dvui.entypo.folder)) pending.* = .open_worlds;
            if (managementCard(@src(), "模组与整合包", dvui.entypo.download)) pending.* = .open_content;
            if (managementCard(@src(), "Java 管理", dvui.entypo.cog)) pending.* = .open_java;
            if (managementCard(@src(), "服务器", dvui.entypo.network)) pending.* = .open_servers;
            if (managementCard(@src(), "游戏日志", dvui.entypo.text_document)) pending.* = .open_logs;
        },
        .settings => {
            title(@src(), "设置");
            gap(@src(), 24);
            muted(@src(), "暂无功能");
        },
    }
}

fn managementCard(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8) bool {
    var card: dvui.ButtonWidget = undefined;
    card.init(src, .{}, .{ .min_size_content = .{ .w = 200, .h = 112 }, .max_size_content = .width(240), .padding = R.all(20), .margin = .{ .w = 16, .h = 16 }, .corners = .all(8), .border = R.all(1), .label = .{ .text = name } });
    defer card.deinit();
    card.processEvents();
    card.drawBackground();
    {
        const contents = dvui.box(@src(), .{}, .{ .expand = .both, .min_size_content = .{ .w = 200, .h = 112 } });
        defer contents.deinit();
        dvui.icon(@src(), name, asset, .{}, card.style().override(.{ .min_size_content = .{ .w = 32, .h = 32 }, .color_text = .{ .color = theme.accent }, .role = .none, .padding = R.all(0), .margin = .{ .h = 20 } }));
        dvui.labelNoFmt(@src(), name, .{}, card.style().override(.{ .font = dvui.themeGet().font_heading, .padding = R.all(0), .margin = R.all(0) }));
    }
    card.drawFocus();
    return card.clicked();
}
pub fn beginUtilityMenu(name: []const u8) *dvui.BoxWidget {
    const side = menu(@src());
    title(@src(), name);
    gap(@src(), 16);
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
