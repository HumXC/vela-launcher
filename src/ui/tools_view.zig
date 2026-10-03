const std = @import("std");
const dvui = @import("dvui");
const state = @import("model.zig");
const games = @import("game_library.zig");
const theme = @import("theme.zig");
const java = @import("java_manager.zig");
const java_view = @import("java_view.zig");
const R = dvui.Rect;

pub const Command = union(enum) { load, install: state.GameName, cancel };

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
    return dvui.box(src, .{}, .{ .expand = .vertical, .min_size_content = .{ .w = 212 }, .max_size_content = .width(212), .padding = R.all(24), .margin = .{ .x = 16, .y = 16, .h = 16 }, .corners = .all(8), .background = true, .color_fill = .{ .color = theme.surface } });
}
fn iconCommand(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, disabled: bool, show_tooltip: bool, opts: dvui.Options) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = disabled }, (dvui.Options{ .min_size_content = .{ .w = 20, .h = 20 }, .padding = R.all(10), .margin = R.all(0), .corners = .all(8), .border = R.all(0), .label = .{ .text = name }, .tab_index = if (disabled) 0 else null }).override(opts));
    defer button.deinit();
    if (!disabled) button.processEvents();
    button.drawBackground();
    dvui.icon(@src(), name, asset, .{}, button.style().override(.{ .min_size_content = .{ .w = 20, .h = 20 }, .padding = R.all(0), .margin = R.all(0), .gravity_x = 0.5, .gravity_y = 0.5, .role = .none }));
    if (!disabled) button.drawFocus();
    if (show_tooltip) dvui.tooltip(@src(), .{ .active_rect = button.data().borderRectScale().r }, "{s}", .{name}, .{});
    return !disabled and button.clicked();
}
fn navItem(src: std.builtin.SourceLocation, id: usize, name: []const u8, asset: ?[]const u8, selected: bool) bool {
    const height = @max(24, dvui.themeGet().font_body.textSize(name).h);
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{}, .{ .id_extra = id, .expand = .horizontal, .min_size_content = .{ .h = height }, .padding = R.all(10), .margin = .{ .h = 8 }, .corners = .all(8), .border = R.all(0), .color_fill = if (selected) .{ .color = dvui.Color.fromHex("38483C") } else .{ .color = theme.surface }, .label = .{ .text = name } });
    defer button.deinit();
    button.processEvents();
    button.drawBackground();
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .h = height } });
    {
        defer row.deinit();
        if (asset) |bytes| {
            dvui.icon(@src(), name, bytes, .{}, button.style().override(.{ .min_size_content = .{ .w = 20, .h = 20 }, .gravity_y = 0.5, .margin = .{ .w = 12 }, .padding = R.all(0), .role = .none }));
        }
        dvui.labelNoFmt(@src(), name, .{ .align_y = 0.5 }, button.style().override(.{ .expand = .horizontal, .min_size_content = .{ .h = height }, .padding = R.all(0), .margin = R.all(0) }));
    }
    button.drawFocus();
    return button.clicked();
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
    if (dvui.button(@src(), model.labels.home, .{}, .{ .expand = .horizontal, .gravity_y = 0.5, .min_size_content = .{ .h = content_height }, .padding = R.all(10), .margin = R.all(0), .corners = .all(8), .border = R.all(0) })) pending.* = .back;
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
            if (managementCard(@src(), "版本目录", dvui.entypo.list)) pending.* = .open_library;
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

pub fn javaMenu(model: *const state.Model, pending: *?state.Msg) void {
    const side = menu(@src());
    defer side.deinit();
    footer(model, pending, true);
    title(@src(), "Java 管理");
}

pub fn libraryMenu(model: *const state.Model, snapshot: games.Snapshot, pending: *?state.Msg) void {
    const side = menu(@src());
    defer side.deinit();
    footer(model, pending, true);
    title(@src(), "版本管理");
    gap(@src(), 24);
    if (navItem(@src(), 0, "获取游戏", dvui.entypo.plus, model.getting_game)) pending.* = .get_game;
    gap(@src(), 12);
    muted(@src(), "已安装");
    gap(@src(), 12);
    const list = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0), .border = R.all(0), .background = false, .label = .{ .text = "已安装游戏" } });
    defer list.deinit();
    if (snapshot.installed.len == 0) muted(@src(), "暂无已安装版本");
    for (snapshot.installed, 0..) |entry, i| {
        if (navItem(@src(), i + 1, entry.id, null, !model.getting_game and std.mem.eql(u8, model.library_game.get(), entry.id))) pending.* = .{ .inspect_game = entry.id };
    }
}

pub fn hasInstalled(snapshot: games.Snapshot, id: []const u8) bool {
    for (snapshot.installed) |entry| if (std.mem.eql(u8, entry.id, id)) return true;
    return false;
}
fn busy(snapshot: games.Snapshot) bool {
    return snapshot.phase == .loading or snapshot.phase == .installing;
}
fn status(model: *const state.Model, snapshot: games.Snapshot, command: *?Command) void {
    const failure: ?anyerror = if (model.library_error != null) model.library_error else snapshot.failure;
    if (failure) |err| {
        if (err == error.Canceled) {
            muted(@src(), "已取消");
        } else {
            dvui.label(@src(), "操作失败：{s}", .{@errorName(err)}, .{ .padding = R.all(0), .margin = R.all(0), .expand = .horizontal });
        }
        gap(@src(), 8);
    }
    if (snapshot.phase == .installing) {
        dvui.label(@src(), "正在下载：{s}", .{snapshot.installing_version orelse ""}, .{ .padding = R.all(0), .margin = R.all(0), .expand = .horizontal });
        gap(@src(), 8);
        dvui.progress(@src(), .{ .percent = if (snapshot.total == 0) 0 else @as(f32, @floatFromInt(snapshot.completed)) / @as(f32, @floatFromInt(snapshot.total)) }, .{ .expand = .horizontal, .min_size_content = .{ .h = 6 }, .margin = R.all(0) });
        dvui.label(@src(), "{d} / {d} 文件", .{ snapshot.completed, snapshot.total }, .{ .font = dvui.themeGet().font_body.withSize(14), .padding = R.all(0), .margin = .{ .y = 8 } });
        if (dvui.button(@src(), "取消下载", .{}, .{ .padding = R.all(8), .margin = .{ .y = 8 }, .corners = .all(8) })) command.* = .cancel;
        gap(@src(), 12);
    } else if (snapshot.phase == .loading) {
        muted(@src(), "正在获取版本列表…");
        if (dvui.button(@src(), "取消", .{}, .{ .padding = R.all(8), .margin = .{ .y = 8 }, .corners = .all(8) })) command.* = .cancel;
        gap(@src(), 12);
    } else if (snapshot.phase == .complete and snapshot.installing_version != null) {
        dvui.label(@src(), "下载完成：{s}", .{snapshot.installing_version.?}, .{ .padding = R.all(0), .margin = .{ .h = 12 }, .expand = .horizontal, .color_text = .{ .color = theme.accent } });
    }
}

pub fn libraryContent(model: *state.Model, snapshot: games.Snapshot, pending: *?state.Msg, command: *?Command, java_ui: *java_view.Ui, manager: *java.Manager) void {
    if (!model.getting_game) {
        title(@src(), model.library_game.get());
        gap(@src(), 16);
        const exists = hasInstalled(snapshot, model.library_game.get());
        muted(@src(), if (exists) "原版 · 已安装" else "版本已不可用");
        gap(@src(), 24);
        status(model, snapshot, command);
        for (snapshot.installed) |entry| {
            if (std.mem.eql(u8, entry.id, model.library_game.get())) {
                gap(@src(), 16);
                java_view.versionChoice(java_ui, manager, entry.id, entry.java_major);
                gap(@src(), 16);
                break;
            }
        }
        if (exists and dvui.button(@src(), "使用此版本", .{}, .{ .padding = R.all(12), .margin = R.all(0), .corners = .all(8), .style = .highlight })) pending.* = .{ .use_game = model.library_game.get() };
        return;
    }
    title(@src(), "获取游戏");
    gap(@src(), 16);
    // Reserve the bottom action row before the scroll area consumes remaining space.
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 1, .min_size_content = .{ .h = 48 }, .margin = .{ .y = 16 } });
        defer row.deinit();
        const selected = model.download_game.get();
        const allowed = !busy(snapshot) and selected.len != 0;
        var download: dvui.ButtonWidget = undefined;
        download.init(@src(), .{ .grayed = !allowed }, .{ .gravity_x = 1, .min_size_content = .{ .w = 76, .h = 24 }, .padding = R.all(12), .margin = R.all(0), .corners = .all(8), .style = .highlight, .tab_index = if (allowed) null else 0 });
        {
            defer download.deinit();
            if (allowed) download.processEvents();
            download.drawBackground();
            dvui.labelNoFmt(@src(), if (hasInstalled(snapshot, selected)) "重新下载" else "下载游戏", .{ .align_x = 0.5, .align_y = 0.5 }, download.style().override(.{ .gravity_x = 0.5, .gravity_y = 0.5, .padding = R.all(0), .margin = R.all(0) }));
            if (allowed) download.drawFocus();
            if (allowed and download.clicked()) command.* = .{ .install = model.download_game };
        }
        dvui.labelNoFmt(@src(), selected, .{ .align_y = 0.5 }, .{ .expand = .horizontal, .min_size_content = .{ .h = 48 }, .margin = .{ .w = 12 }, .padding = R.all(0) });
    }
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .h = 40 } });
        defer row.deinit();
        if (iconCommand(@src(), "刷新版本列表", dvui.entypo.cycle, busy(snapshot), true, .{ .gravity_x = 1 })) command.* = .load;
        if (filterChoice(@src(), model.version_filter == .release, "正式版", 8)) pending.* = .{ .filter_versions = .release };
        if (filterChoice(@src(), model.version_filter == .snapshot, "快照", 8)) pending.* = .{ .filter_versions = .snapshot };
        if (filterChoice(@src(), model.version_filter == .all, "全部", 0)) pending.* = .{ .filter_versions = .all };
    }
    gap(@src(), 12);
    const query = blk: {
        const search = dvui.textEntry(@src(), .{ .text = .{ .buffer = &model.search }, .placeholder = "搜索版本" }, .{ .expand = .horizontal, .margin = R.all(0), .corners = .all(8), .label = .{ .text = "搜索版本" } });
        defer search.deinit();
        break :blk search.textGet();
    };
    gap(@src(), 16);
    status(model, snapshot, command);
    const list = dvui.scrollArea(@src(), .{}, .{ .id_extra = @intFromEnum(model.version_filter), .expand = .both, .background = false, .padding = R.all(0), .margin = R.all(0), .border = R.all(0), .label = .{ .text = "可下载版本" } });
    defer list.deinit();
    var count: usize = 0;
    for (snapshot.available, 0..) |entry, i| {
        const matches = switch (model.version_filter) {
            .release => std.mem.eql(u8, entry.kind, "release"),
            .snapshot => std.mem.eql(u8, entry.kind, "snapshot"),
            .all => true,
        };
        if (!matches or std.mem.indexOf(u8, entry.id, query) == null) continue;
        count += 1;
        if (versionItem(@src(), i, entry.id, if (hasInstalled(snapshot, entry.id)) "已安装" else kindName(entry.kind), std.mem.eql(u8, model.download_game.get(), entry.id))) pending.* = .{ .choose_download = entry.id };
    }
    if (count == 0 and snapshot.phase != .loading) muted(@src(), if (snapshot.available.len == 0) "暂无可下载版本" else "没有匹配的版本");
}

fn filterChoice(src: std.builtin.SourceLocation, active: bool, name: []const u8, right_margin: f32) bool {
    const font = dvui.themeGet().font_body;
    const size = font.textSize(name);
    const circle = font.textHeight();
    return dvui.radio(src, active, name, .{ .min_size_content = .{ .w = circle + dvui.radio_defaults.paddingGet().w + size.w, .h = @max(circle, size.h) }, .margin = .{ .w = right_margin }, .padding = R.all(0), .gravity_y = 0.5 });
}

fn kindName(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "release")) return "正式版";
    if (std.mem.eql(u8, kind, "snapshot")) return "快照";
    if (std.mem.eql(u8, kind, "old_alpha")) return "Alpha";
    if (std.mem.eql(u8, kind, "old_beta")) return "Beta";
    return kind;
}

fn versionItem(src: std.builtin.SourceLocation, id: usize, name: []const u8, detail: []const u8, current: bool) bool {
    const height = @max(dvui.themeGet().font_body.textSize(name).h, 24);
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{}, .{ .id_extra = id, .expand = .horizontal, .min_size_content = .{ .h = height }, .padding = R.all(12), .margin = .{ .h = 8 }, .corners = .all(8), .border = R.all(1), .color_border = if (current) .{ .color = theme.accent } else null, .label = .{ .text = name } });
    defer button.deinit();
    button.processEvents();
    button.drawBackground();
    const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .h = height } });
    {
        defer row.deinit();
        dvui.labelNoFmt(@src(), detail, .{ .align_y = 0.5 }, button.style().override(.{ .gravity_x = 1, .min_size_content = .{ .h = height }, .font = dvui.themeGet().font_body.withSize(14), .color_text = .{ .color = theme.muted }, .padding = R.all(0), .margin = .{ .x = 12 } }));
        dvui.labelNoFmt(@src(), name, .{ .align_y = 0.5 }, button.style().override(.{ .expand = .horizontal, .min_size_content = .{ .h = height }, .padding = R.all(0), .margin = R.all(0) }));
    }
    button.drawFocus();
    return button.clicked();
}

test "queued download owns its name across subsequent selection and filter transitions" {
    var model: state.Model = .{ .panel = .library };
    state.transition(&model, .{ .choose_download = "1.21.1" });
    const command: Command = .{ .install = model.download_game };
    state.transition(&model, .{ .choose_download = "24w14a" });
    try std.testing.expectEqualStrings("1.21.1", command.install.get());
    state.transition(&model, .{ .filter_versions = .release });
    try std.testing.expectEqualStrings("1.21.1", command.install.get());
}
