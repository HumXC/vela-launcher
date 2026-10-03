const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const servers = @import("../core/servers.zig");
const server_manager = @import("server_manager.zig");
const theme = @import("theme.zig");
const R = dvui.Rect;
const Allocator = std.mem.Allocator;

const Action = enum { add, edit, select, clear_server, refresh, cancel_query, save, cancel_edit, ask_delete, delete, cancel_delete };
const Pending = struct { action: Action, id: ?[]u8 = null };
const Draft = struct {
    id: ?[]u8 = null,
    instance_id: ?[]u8 = null,
    name: [201]u8 = @splat(0),
    address: [4097]u8 = @splat(0),
    port: [6]u8 = .{ '2', '5', '5', '6', '5', 0 },
    show_on_home: bool = true,

    fn deinit(self: *Draft, a: Allocator) void {
        if (self.id) |id| a.free(id);
        if (self.instance_id) |id| a.free(id);
        self.* = .{};
    }
    fn fromServer(a: Allocator, server: config.Server) !Draft {
        var draft: Draft = .{};
        errdefer draft.deinit(a);
        draft.id = try a.dupe(u8, server.id);
        draft.instance_id = try a.dupe(u8, server.instance_id);
        @memcpy(draft.name[0..server.name.len], server.name);
        @memcpy(draft.address[0..server.address.len], server.address);
        @memset(&draft.port, 0);
        _ = try std.fmt.bufPrint(draft.port[0..5], "{d}", .{server.port});
        draft.show_on_home = server.show_on_home;
        return draft;
    }
    fn value(self: *const Draft) !config.Server {
        const port_text = text(&self.port);
        if (port_text.len == 0) return error.InvalidServerPort;
        for (port_text) |ch| if (ch < '0' or ch > '9') return error.InvalidServerPort;
        const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidServerPort;
        const address = std.mem.trim(u8, text(&self.address), " \t\r\n");
        _ = try servers.validateAddress(address, port);
        const name = std.mem.trim(u8, text(&self.name), " \t\r\n");
        if (name.len == 0) return error.InvalidServerName;
        return .{ .id = self.id orelse return error.InvalidId, .name = name, .address = address, .port = port, .instance_id = self.instance_id orelse return error.DanglingServerInstance, .show_on_home = self.show_on_home };
    }
};

pub const Ui = struct {
    allocator: Allocator,
    draft: Draft = .{},
    editor_open: bool = false,
    deleting_id: ?[]u8 = null,
    pending: ?Pending = null,
    failure: ?anyerror = null,

    pub fn init(a: Allocator) Ui {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Ui) void {
        self.draft.deinit(self.allocator);
        if (self.deleting_id) |id| self.allocator.free(id);
        if (self.pending) |pending| if (pending.id) |id| self.allocator.free(id);
        self.* = undefined;
    }
    fn queue(self: *Ui, action: Action, id: ?[]const u8) void {
        const owned = if (id) |value| self.allocator.dupe(u8, value) catch |err| {
            self.failure = err;
            return;
        } else null;
        if (self.pending) |old| if (old.id) |old_id| self.allocator.free(old_id);
        self.pending = .{ .action = action, .id = owned };
    }
};

fn text(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}
fn findServer(doc: *const config.Document, id: []const u8) ?config.Server {
    for (doc.servers) |server| if (std.mem.eql(u8, server.id, id)) return server;
    return null;
}
fn sameId(a: ?[]const u8, b: []const u8) bool {
    return if (a) |id| std.mem.eql(u8, id, b) else false;
}
const HomeChoices = struct {
    labels: [][]const u8,
    ids: []?[]const u8,
    choice: ?usize,

    fn deinit(self: HomeChoices, a: Allocator) void {
        a.free(self.labels);
        a.free(self.ids);
    }
};
fn homeChoices(a: Allocator, doc: *const config.Document) !HomeChoices {
    var count: usize = 1;
    for (doc.servers) |server| if (server.show_on_home) {
        count += 1;
    };
    const labels = try a.alloc([]const u8, count);
    errdefer a.free(labels);
    const ids = try a.alloc(?[]const u8, count);
    labels[0] = "仅启动实例";
    ids[0] = null;
    var choice: ?usize = if (doc.selected_server == null) 0 else null;
    var index: usize = 1;
    for (doc.servers) |server| if (server.show_on_home) {
        labels[index] = server.name;
        ids[index] = server.id;
        if (sameId(doc.selected_server, server.id)) choice = index;
        index += 1;
    };
    return .{ .labels = labels, .ids = ids, .choice = choice };
}
pub fn drawHome(ui: *Ui, doc: *const config.Document) void {
    drawHomeWithOptions(ui, doc, false);
}

pub fn drawHomeWithOptions(ui: *Ui, doc: *const config.Document, compact: bool) void {
    const font = if (compact) dvui.themeGet().font_body.withSize(14) else dvui.themeGet().font_body;
    const choices = homeChoices(ui.allocator, doc) catch |err| {
        ui.failure = err;
        return;
    };
    defer choices.deinit(ui.allocator);
    var choice = choices.choice;
    if (dvui.dropdown(@src(), choices.labels, .{ .choice_nullable = &choice }, .{ .placeholder = "当前服务器未显示在首页", .null_selectable = false }, .{ .tag = "home-server-target", .font = font, .expand = .horizontal, .max_size_content = .width(0), .min_size_content = .{ .h = 24 }, .padding = R.all(8), .margin = R.all(0), .corners = .all(4), .label = .{ .text = "启动目标" } })) {
        if (choice) |index| {
            if (choices.ids[index]) |id| ui.queue(.select, id) else ui.queue(.clear_server, null);
        }
    }
    if (doc.selected_server) |id| {
        if (findServer(doc, id)) |server| {
            const detail_font = if (compact) font.withSize(12) else font;
            const detail_options: dvui.Options = .{ .font = detail_font, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .y = 2, .h = if (compact) 0 else 6 }, .color_text = .{ .color = theme.accent } };
            const address = dvui.textLayout(@src(), .{}, detail_options.override(.{ .tag = "home-server-address" }));
            address.addText(fmt("{s}:{d}", .{ server.address, server.port }), .{});
            address.deinit();
            for (doc.instances) |instance| if (std.mem.eql(u8, instance.id, server.instance_id)) {
                const bound_instance = dvui.textLayout(@src(), .{}, detail_options.override(.{ .tag = "home-server-instance", .color_text = .{ .color = theme.muted } }));
                bound_instance.addText(instance.name, .{});
                bound_instance.deinit();
                break;
            };
        }
    }
}
fn wrapped(src: std.builtin.SourceLocation, value: []const u8, color: dvui.Color) void {
    const layout = dvui.textLayout(src, .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = 6 }, .color_text = .{ .color = color } });
    layout.addText(value, .{});
    layout.deinit();
}
fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}
fn iconButton(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{}, .{ .label = .{ .text = name }, .min_size_content = .{ .w = 18, .h = 18 }, .max_size_content = .{ .w = 18, .h = 18 }, .padding = R.all(8), .margin = .{ .x = 4 }, .corners = .all(4) });
    button.processEvents();
    button.drawBackground();
    dvui.icon(@src(), name, asset, .{}, button.style().override(.{ .padding = R.all(0), .margin = R.all(0), .min_size_content = .{ .w = 18, .h = 18 }, .max_size_content = .{ .w = 18, .h = 18 }, .role = .none }));
    button.drawFocus();
    const clicked = button.clicked();
    const hovered = button.hovered();
    const rect = button.data().rectScale().r;
    button.deinit();
    if (hovered) dvui.tooltip(src, .{ .active_rect = rect }, "{s}", .{name}, .{ .id_extra = 1 });
    return clicked;
}
fn entry(src: std.builtin.SourceLocation, name: []const u8, buffer: []u8, numeric: bool) void {
    dvui.labelNoFmt(src, name, .{}, .{ .padding = R.all(0), .margin = .{ .y = 8, .h = 4 } });
    const height = (dvui.Options{}).fontGet().sizeM(0, 1).h;
    const input = dvui.textEntry(src, .{ .text = .{ .buffer = buffer } }, .{ .id_extra = 1, .label = .{ .text = name }, .expand = .horizontal, .min_size_content = .{ .h = height }, .max_size_content = .height(height), .padding = R.all(8), .corners = .all(4), .margin = .{ .h = 6 } });
    if (numeric) input.filterIn("0123456789");
    input.deinit();
}
fn drawEditor(ui: *Ui, doc: *const config.Document) void {
    const editor = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = .{ .y = 12 }, .margin = .{ .h = 12 }, .border = .{ .y = 1 } });
    defer editor.deinit();
    dvui.labelNoFmt(@src(), if (ui.draft.id == null) "添加服务器" else "编辑服务器", .{}, .{ .padding = R.all(0), .margin = .{ .h = 6 } });
    entry(@src(), "名称", &ui.draft.name, false);
    entry(@src(), "地址", &ui.draft.address, false);
    entry(@src(), "端口", &ui.draft.port, true);
    dvui.labelNoFmt(@src(), "绑定实例", .{}, .{ .padding = R.all(0), .margin = .{ .y = 8, .h = 4 } });
    const labels = dvui.currentWindow().arena().alloc([]const u8, doc.instances.len) catch {
        ui.failure = error.OutOfMemory;
        return;
    };
    var choice: ?usize = null;
    for (doc.instances, 0..) |instance, index| {
        labels[index] = instance.name;
        if (sameId(ui.draft.instance_id, instance.id)) choice = index;
    }
    if (labels.len > 0) {
        if (dvui.dropdown(@src(), labels, .{ .choice_nullable = &choice }, .{ .placeholder = "选择实例", .null_selectable = false }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(8), .corners = .all(4) })) {
            if (choice) |index| {
                const owned = ui.allocator.dupe(u8, doc.instances[index].id) catch |err| {
                    ui.failure = err;
                    return;
                };
                if (ui.draft.instance_id) |old| ui.allocator.free(old);
                ui.draft.instance_id = owned;
            }
        }
    } else wrapped(@src(), "暂无实例", theme.muted);
    _ = dvui.checkbox(@src(), &ui.draft.show_on_home, "显示在首页", .{ .margin = .{ .y = 8, .h = 8 } });
    const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0) });
    if (iconButton(@src(), "保存", dvui.entypo.save)) ui.queue(.save, null);
    if (iconButton(@src(), "取消编辑", dvui.entypo.cross)) ui.queue(.cancel_edit, null);
    actions.deinit();
}

pub fn draw(ui: *Ui, store: *config.Store, manager: *server_manager.Manager) void {
    const doc = store.snapshot();
    const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .padding = R.all(0), .border = R.all(0) });
    defer scroll.deinit();
    const column = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = R.all(0) });
    defer column.deinit();
    const heading = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = 12 } });
    dvui.labelNoFmt(@src(), "服务器", .{}, .{ .expand = .horizontal, .padding = R.all(0), .gravity_y = 0.5 });
    if (iconButton(@src(), "添加服务器", dvui.entypo.plus)) ui.queue(.add, null);
    heading.deinit();
    if (ui.failure) |err| wrapped(@src(), fmt("操作失败：{s}", .{@errorName(err)}), dvui.Color.fromHex("F0A6A1"));
    if (ui.deleting_id) |id| {
        if (findServer(doc, id)) |server| wrapped(@src(), fmt("删除服务器「{s}」？", .{server.name}), theme.accent);
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = 8 } });
        if (iconButton(@src(), "确认删除", dvui.entypo.trash)) ui.queue(.delete, id);
        if (iconButton(@src(), "取消删除", dvui.entypo.cross)) ui.queue(.cancel_delete, null);
        actions.deinit();
    }
    if (ui.editor_open) drawEditor(ui, doc);
    if (doc.servers.len == 0) wrapped(@src(), "暂无服务器", theme.muted);
    for (doc.servers, 0..) |server, index| {
        const row = dvui.box(@src(), .{}, .{ .id_extra = index, .expand = .horizontal, .padding = .{ .y = 10, .h = 10 }, .border = .{ .h = 1 }, .margin = R.all(0) });
        const narrow = row.data().contentRect().w < 450;
        const top = dvui.box(@src(), .{ .dir = if (narrow) .vertical else .horizontal }, .{ .expand = .horizontal, .padding = R.all(0) });
        wrapped(@src(), fmt("{s}{s}", .{ server.name, if (sameId(doc.selected_server, server.id)) " · 当前" else "" }), if (sameId(doc.selected_server, server.id)) theme.accent else dvui.Color.fromHex("E8ECE9"));
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .padding = R.all(0) });
        if (iconButton(@src(), "选择服务器", dvui.entypo.check)) ui.queue(.select, server.id);
        if (iconButton(@src(), "刷新状态", dvui.entypo.cw)) ui.queue(.refresh, server.id);
        if (iconButton(@src(), "编辑服务器", dvui.entypo.pencil)) ui.queue(.edit, server.id);
        if (iconButton(@src(), "删除服务器", dvui.entypo.trash)) ui.queue(.ask_delete, server.id);
        actions.deinit();
        top.deinit();
        wrapped(@src(), fmt("{s}:{d}", .{ server.address, server.port }), theme.muted);
        var instance_name: []const u8 = "实例不存在";
        for (doc.instances) |instance| if (std.mem.eql(u8, instance.id, server.instance_id)) {
            instance_name = instance.name;
            break;
        };
        wrapped(@src(), fmt("{s}{s}", .{ instance_name, if (server.show_on_home) " · 首页" else "" }), theme.muted);
        if (manager.snapshot().server) |requested| {
            if (std.mem.eql(u8, requested.id, server.id)) {
                drawStatus(manager);
                if (manager.snapshot().state == .querying and iconButton(@src(), "取消查询", dvui.entypo.cross)) ui.queue(.cancel_query, null);
            }
        }
        row.deinit();
    }
}

/// Inline and read-only. Untrusted PNGs must pass both backend checks and stb.
pub fn drawStatus(manager: *server_manager.Manager) void {
    const snapshot = manager.snapshot();
    const band = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .y = 4 } });
    defer band.deinit();
    switch (snapshot.state) {
        .idle => wrapped(@src(), "尚未查询", theme.muted),
        .querying => wrapped(@src(), "查询中…", theme.muted),
        .canceled => wrapped(@src(), "已取消", theme.muted),
        .offline => {
            const reason: []const u8 = if (snapshot.failure) |err| switch (servers.classifyFailure(err)) {
                .timeout => "查询超时",
                .canceled => "已取消",
                .invalid_response => "服务器响应无效",
                .invalid_configuration => "服务器配置无效",
                .resource => "查询资源不足",
                .offline => "无法连接",
            } else "无法连接";
            wrapped(@src(), reason, dvui.Color.fromHex("F0A6A1"));
        },
        .online => if (snapshot.status) |status| {
            if (status.icon_png) |png| {
                const decoded = dvui.Color.PMAImage.fromImageFile("server-icon", dvui.currentWindow().arena(), png) catch null;
                if (decoded) |image| {
                    if (image.width == 64 and image.height == 64) _ = dvui.image(@src(), .{ .source = .{ .pixelsPMA = .{ .rgba = image.pma, .width = image.width, .height = image.height, .invalidation = .bytes } } }, .{ .label = .{ .text = "服务器图标" }, .min_size_content = .{ .w = 32, .h = 32 }, .max_size_content = .{ .w = 32, .h = 32 }, .margin = .{ .h = 6 }, .padding = R.all(0) });
                }
            }
            wrapped(@src(), fmt("在线 · {s} · {d} ms", .{ status.version, status.latency_ms }), theme.accent);
            if (status.players_online) |online| {
                if (status.players_max) |max| wrapped(@src(), fmt("玩家 {d} / {d}", .{ online, max }), theme.muted) else wrapped(@src(), fmt("玩家 {d}", .{online}), theme.muted);
            }
            if (status.motd.len > 0) wrapped(@src(), status.motd, theme.muted);
        },
    }
}

fn select(ui: *Ui, store: *config.Store, manager: *server_manager.Manager, id: []const u8) !void {
    _ = ui;
    var document = store.snapshot().*;
    const server = findServer(&document, id) orelse return error.ServerNotFound;
    _ = try servers.selectLaunch(server, document.instances);
    document.selected_server = server.id;
    document.selected_instance = server.instance_id;
    try store.update(document);
    manager.refreshConfigured(findServer(store.snapshot(), id).?) catch |err| {
        manager.clear();
        return err;
    };
}
fn save(ui: *Ui, store: *config.Store, manager: *server_manager.Manager) !void {
    if (ui.draft.id == null) {
        var random: [16]u8 = undefined;
        try store.io.randomSecure(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        ui.draft.id = try std.fmt.allocPrint(ui.allocator, "server-{s}", .{hex});
    }
    const server = try ui.draft.value();
    if (store.publicationUncertain()) try store.reconcile();
    var document = store.snapshot().*;
    _ = try servers.selectLaunch(server, document.instances);
    const existing = findServer(&document, server.id) != null;
    const items = try ui.allocator.alloc(config.Server, document.servers.len + @as(usize, if (existing) 0 else 1));
    defer ui.allocator.free(items);
    @memcpy(items[0..document.servers.len], document.servers);
    if (existing) {
        for (items) |*item| if (std.mem.eql(u8, item.id, server.id)) {
            item.* = server;
            break;
        };
    } else items[items.len - 1] = server;
    document.servers = items;
    const selected = sameId(document.selected_server, server.id);
    if (selected) document.selected_instance = server.instance_id;
    try store.update(document);
    if (selected) manager.clear();
    ui.editor_open = false;
    ui.draft.deinit(ui.allocator);
}
fn delete(ui: *Ui, store: *config.Store, manager: *server_manager.Manager, id: []const u8) !void {
    var document = store.snapshot().*;
    _ = findServer(&document, id) orelse return error.ServerNotFound;
    const items = try ui.allocator.alloc(config.Server, document.servers.len - 1);
    defer ui.allocator.free(items);
    var index: usize = 0;
    for (document.servers) |server| if (!std.mem.eql(u8, server.id, id)) {
        items[index] = server;
        index += 1;
    };
    document.servers = items;
    if (sameId(document.selected_server, id)) document.selected_server = null;
    try store.update(document);
    if (manager.snapshot().server) |server| if (std.mem.eql(u8, server.id, id)) {
        manager.clear();
    };
    if (sameId(ui.draft.id, id)) {
        ui.editor_open = false;
        ui.draft.deinit(ui.allocator);
    }
    if (ui.deleting_id) |owned| ui.allocator.free(owned);
    ui.deleting_id = null;
}

/// Must run after ALL parent/root/floating widgets have been closed.
pub fn finish(ui: *Ui, store: *config.Store, manager: *server_manager.Manager) void {
    const pending = ui.pending orelse return;
    ui.pending = null;
    defer if (pending.id) |id| ui.allocator.free(id);
    ui.failure = null;
    apply(ui, store, manager, pending) catch |err| {
        ui.failure = err;
    };
}
fn apply(ui: *Ui, store: *config.Store, manager: *server_manager.Manager, pending: Pending) !void {
    switch (pending.action) {
        .add => {
            ui.draft.deinit(ui.allocator);
            ui.editor_open = true;
        },
        .edit => {
            const server = findServer(store.snapshot(), pending.id.?) orelse return error.ServerNotFound;
            const draft = try Draft.fromServer(ui.allocator, server);
            ui.draft.deinit(ui.allocator);
            ui.draft = draft;
            ui.editor_open = true;
        },
        .select, .refresh => try select(ui, store, manager, pending.id.?),
        .clear_server => {
            var document = store.snapshot().*;
            document.selected_server = null;
            try store.update(document);
            manager.clear();
        },
        .cancel_query => manager.cancel(),
        .save => try save(ui, store, manager),
        .cancel_edit => {
            ui.draft.deinit(ui.allocator);
            ui.editor_open = false;
        },
        .ask_delete => {
            const owned = try ui.allocator.dupe(u8, pending.id.?);
            if (ui.deleting_id) |id| ui.allocator.free(id);
            ui.deleting_id = owned;
        },
        .delete => try delete(ui, store, manager, pending.id.?),
        .cancel_delete => {
            if (ui.deleting_id) |id| ui.allocator.free(id);
            ui.deleting_id = null;
        },
    }
}

test "server drafts own strings preserve exact bindings and validate numeric ports" {
    var draft = try Draft.fromServer(std.testing.allocator, .{ .id = "server", .name = "Example", .address = "[::1]", .port = 25565, .instance_id = "Instance", .show_on_home = false });
    defer draft.deinit(std.testing.allocator);
    const server = try draft.value();
    try std.testing.expectEqualStrings("Instance", server.instance_id);
    try std.testing.expectEqualStrings("[::1]", server.address);
    try std.testing.expect(!server.show_on_home);
    draft.port = .{ '0', 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidPort, draft.value());
    draft.port = .{ 'a', 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidServerPort, draft.value());
    draft.port = .{ '6', '5', '5', '3', '6', 0 };
    try std.testing.expectError(error.InvalidServerPort, draft.value());
}
test "server pending actions own IDs and replace prior requests" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    var id = [_]u8{ 's', 'r', 'v' };
    ui.queue(.edit, &id);
    @memset(&id, 'x');
    try std.testing.expectEqualStrings("srv", ui.pending.?.id.?);
    ui.queue(.ask_delete, "next");
    try std.testing.expectEqualStrings("next", ui.pending.?.id.?);
}

fn fixtureRoot(tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    return std.testing.allocator.dupe(u8, buffer[0..length]);
}
fn offlineFixture(_: Allocator, _: std.Io, _: config.Server, _: servers.Options) anyerror!servers.OwnedStatus {
    return error.ConnectionRefused;
}
const fixtureInstances: []const config.Instance = &.{
    .{ .id = "One", .name = "One", .minecraft_version = "1.21" },
    .{ .id = "Two", .name = "Two", .minecraft_version = "1.20" },
};
test "home choices filter visibility and instance mode clears only server selection" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    try store.update(.{ .instances = fixtureInstances, .servers = &.{
        .{ .id = "visible", .name = "Visible", .address = "127.0.0.1", .instance_id = "One", .show_on_home = true },
        .{ .id = "hidden", .name = "Hidden", .address = "127.0.0.1", .instance_id = "Two", .show_on_home = false },
    }, .selected_server = "hidden", .selected_instance = "Two" });
    var choices = try homeChoices(a, store.snapshot());
    try std.testing.expectEqual(@as(usize, 2), choices.labels.len);
    try std.testing.expect(choices.ids[0] == null);
    try std.testing.expectEqualStrings("visible", choices.ids[1].?);
    try std.testing.expect(choices.choice == null);
    choices.deinit(a);
    var manager = server_manager.Manager.initWithQuery(a, std.testing.io, offlineFixture);
    defer manager.deinit();
    var ui = Ui.init(a);
    defer ui.deinit();
    ui.queue(.clear_server, null);
    try std.testing.expectEqualStrings("hidden", store.snapshot().selected_server.?);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.failure == null);
    try std.testing.expect(store.snapshot().selected_server == null);
    try std.testing.expectEqualStrings("Two", store.snapshot().selected_instance.?);
    try std.testing.expectEqual(@as(usize, 2), store.snapshot().servers.len);
    try std.testing.expectEqual(servers.State.idle, manager.snapshot().state);
    choices = try homeChoices(a, store.snapshot());
    defer choices.deinit(a);
    try std.testing.expectEqual(@as(?usize, 0), choices.choice);
    var persisted = try config.Store.init(a, std.testing.io, root);
    defer persisted.deinit();
    try std.testing.expect(persisted.snapshot().selected_server == null);
    try std.testing.expectEqualStrings("Two", persisted.snapshot().selected_instance.?);
}

test "deferred CRUD uses secure stable IDs exact selections and only removes config" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    try store.update(.{ .instances = fixtureInstances });
    var manager = server_manager.Manager.initWithQuery(a, std.testing.io, offlineFixture);
    defer manager.deinit();
    var ui = Ui.init(a);
    defer ui.deinit();
    ui.queue(.add, null);
    finish(&ui, &store, &manager);
    @memcpy(ui.draft.name[0..7], "Example");
    @memcpy(ui.draft.address[0..9], "127.0.0.1");
    ui.draft.instance_id = try a.dupe(u8, "One");
    ui.queue(.save, null);
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().servers.len);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.failure == null);
    try std.testing.expectEqual(@as(usize, 1), store.snapshot().servers.len);
    const id = try a.dupe(u8, store.snapshot().servers[0].id);
    defer a.free(id);
    try std.testing.expect(std.mem.startsWith(u8, id, "server-"));
    try std.testing.expectEqual(@as(usize, 39), id.len);
    try std.testing.expectEqual(servers.State.idle, manager.snapshot().state);
    ui.queue(.select, id);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.failure == null);
    try std.testing.expectEqualStrings(id, store.snapshot().selected_server.?);
    try std.testing.expectEqualStrings("One", store.snapshot().selected_instance.?);
    ui.queue(.edit, id);
    finish(&ui, &store, &manager);
    a.free(ui.draft.instance_id.?);
    ui.draft.instance_id = try a.dupe(u8, "Two");
    ui.draft.show_on_home = false;
    ui.queue(.save, null);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.failure == null);
    try std.testing.expectEqualStrings(id, store.snapshot().servers[0].id);
    try std.testing.expectEqualStrings("Two", store.snapshot().selected_instance.?);
    try std.testing.expect(!store.snapshot().servers[0].show_on_home);
    try std.testing.expectEqual(servers.State.idle, manager.snapshot().state);
    ui.queue(.ask_delete, id);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), store.snapshot().servers.len);
    try std.testing.expectEqualStrings(id, ui.deleting_id.?);
    ui.queue(.delete, id);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.failure == null);
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().servers.len);
    try std.testing.expect(store.snapshot().selected_server == null);
    try std.testing.expectEqualStrings("Two", store.snapshot().selected_instance.?);
    try std.testing.expectEqual(@as(usize, 2), store.snapshot().instances.len);
    try std.testing.expectEqualStrings("1.21", store.snapshot().instances[0].minecraft_version);
}
test "draft remains owned and retryable after validation or atomic persistence failure" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    try store.update(.{ .instances = fixtureInstances });
    var manager = server_manager.Manager.initWithQuery(a, std.testing.io, offlineFixture);
    defer manager.deinit();
    var ui = Ui.init(a);
    defer ui.deinit();
    ui.queue(.add, null);
    finish(&ui, &store, &manager);
    @memcpy(ui.draft.name[0..5], "Draft");
    @memcpy(ui.draft.address[0..9], "127.0.0.1");
    ui.draft.instance_id = try a.dupe(u8, "missing");
    ui.queue(.save, null);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.UnboundInstance, ui.failure.?);
    try std.testing.expect(ui.editor_open);
    try std.testing.expectEqualStrings("Draft", text(&ui.draft.name));
    const id = try a.dupe(u8, ui.draft.id.?);
    defer a.free(id);
    a.free(ui.draft.instance_id.?);
    ui.draft.instance_id = try a.dupe(u8, "One");
    try tmp.dir.rename(".vela/config.json", tmp.dir, ".vela/previous.json", std.testing.io);
    try tmp.dir.createDir(std.testing.io, ".vela/config.json", .default_dir);
    ui.queue(.save, null);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.failure != null);
    try std.testing.expect(ui.editor_open);
    try std.testing.expectEqualStrings("Draft", text(&ui.draft.name));
    try std.testing.expectEqualStrings(id, ui.draft.id.?);
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().servers.len);
    try tmp.dir.deleteDir(std.testing.io, ".vela/config.json");
    ui.queue(.save, null);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.FileNotFound, ui.failure.?);
    try std.testing.expect(store.publicationUncertain());
    try std.testing.expect(ui.editor_open);
    try std.testing.expectEqualStrings("Draft", text(&ui.draft.name));
    try std.testing.expectEqualStrings(id, ui.draft.id.?);
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().servers.len);
    try tmp.dir.rename(".vela/previous.json", tmp.dir, ".vela/config.json", std.testing.io);
    ui.queue(.save, null);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.failure == null);
    try std.testing.expect(!ui.editor_open);
    try std.testing.expectEqualStrings(id, store.snapshot().servers[0].id);
}
fn oomDraft(a: Allocator) !void {
    var draft = try Draft.fromServer(a, .{ .id = "server", .name = "Example", .address = "127.0.0.1", .instance_id = "One" });
    defer draft.deinit(a);
}
test "server editor cloning frees allocations at every failure point" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, oomDraft, .{});
}
