const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const servers = @import("../core/servers.zig");
const server_manager = @import("server_manager.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const server_card = @import("server_card.zig");
const R = dvui.Rect;
const Allocator = std.mem.Allocator;

const Action = enum { add, edit, select, select_sidebar, clear_server, refresh, cancel_query, save, cancel_edit, ask_delete, delete, cancel_delete };
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
    adding: bool = false,
    dirty: bool = false,
    save_timer: ?dvui.Id = null,
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
    const count = doc.servers.len + 1;
    const labels = try a.alloc([]const u8, count);
    errdefer a.free(labels);
    const ids = try a.alloc(?[]const u8, count);
    labels[0] = "仅启动实例";
    ids[0] = null;
    var choice: ?usize = if (doc.selected_server == null) 0 else null;
    var index: usize = 1;
    for (doc.servers) |server| {
        labels[index] = server.name;
        ids[index] = server.id;
        if (sameId(doc.selected_server, server.id)) choice = index;
        index += 1;
    }
    return .{ .labels = labels, .ids = ids, .choice = choice };
}
pub fn drawHome(ui: *Ui, doc: *const config.Document) void {
    drawHomeWithOptions(ui, doc, false);
}

pub fn drawHomeWithOptions(ui: *Ui, doc: *const config.Document, compact: bool) void {
    const choices = homeChoices(ui.allocator, doc) catch |err| {
        ui.failure = err;
        return;
    };
    defer choices.deinit(ui.allocator);
    var choice = choices.choice;
    if (components.dropdownTagged(@src(), "启动目标", choices.labels, .{ .choice_nullable = &choice }, .{ .placeholder = "当前服务器不可用", .null_selectable = false }, "home-server-target")) {
        if (choice) |index| {
            if (choices.ids[index]) |id| ui.queue(.select, id) else ui.queue(.clear_server, null);
        }
    }
    drawHomeSummary(ui, doc, compact);
}

pub fn drawHomeSummary(ui: *Ui, doc: *const config.Document, compact: bool) void {
    _ = ui;
    const font = theme.headingFont();
    if (doc.selected_server) |id| {
        if (findServer(doc, id)) |server| {
            const detail_font = theme.captionFont();
            dvui.labelNoFmt(@src(), server.name, .{}, .{ .tag = "home-server-target", .font = font, .padding = R.all(0), .margin = R.all(0), .expand = .horizontal, .max_size_content = .width(0) });
            const detail_options: dvui.Options = .{ .font = detail_font, .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .y = theme.spacing.detail_gap, .h = if (compact) 0 else theme.spacing.row_gap }, .color_text = .{ .color = theme.accent } };
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
fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}
fn gap(src: std.builtin.SourceLocation, height: f32) void {
    _ = dvui.spacer(src, .{ .min_size_content = .{ .h = height } });
}

fn changed(ui: *Ui) void {
    ui.dirty = true;
    ui.failure = null;
    if (!ui.adding) {
        const id = dvui.parentGet().data().id.update("server-autosave");
        ui.save_timer = id;
        dvui.timer(id, 500_000);
    }
}

fn drawEditor(ui: *Ui, doc: *const config.Document) void {
    components.title(@src(), if (ui.adding) "添加服务器" else text(&ui.draft.name));
    if (ui.adding) switch (components.formActions(@src(), .{ .save_label = "完成" })) {
        .save => ui.queue(.save, null),
        .cancel => ui.queue(.cancel_edit, null),
        .none => {},
    };
    gap(@src(), theme.spacing.page_title_gap);
    const scroll = components.scrollBody(@src());
    defer scroll.deinit();
    if (ui.failure) |err| {
        components.text(@src(), fmt("操作失败：{s}", .{@errorName(err)}), theme.danger);
        if (ui.dirty and !ui.adding and components.button(@src(), "重试", .{})) ui.queue(.save, null);
    }
    {
        const panel = components.formPanel(@src(), .{ .tag = "server-editor" });
        defer panel.deinit();
        if (components.field(@src(), "名称", &ui.draft.name, .{ .gap_after = 0 })) changed(ui);
    }
    {
        const panel = components.formPanel(@src(), .{ .tag = "server-address" });
        defer panel.deinit();
        if (components.field(@src(), "地址", &ui.draft.address, .{ .gap_after = 0 })) changed(ui);
    }
    {
        const panel = components.formPanel(@src(), .{ .tag = "server-connection" });
        defer panel.deinit();
        const fields = components.formRow(@src());
        defer fields.deinit();
        {
            const cell = fields.cell(@src(), 0);
            defer cell.deinit();
            if (components.field(@src(), "端口", &ui.draft.port, .{ .gap_after = 0, .digits_only = true })) changed(ui);
        }
        const cell = fields.cell(@src(), 1);
        defer cell.deinit();
        components.fieldLabel(@src(), "绑定实例");
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
            if (components.dropdownStyled(@src(), "绑定实例", labels, .{ .choice_nullable = &choice }, .{ .placeholder = "选择实例", .null_selectable = false }, .{ .margin = R.all(0) })) {
                if (choice) |index| {
                    const owned = ui.allocator.dupe(u8, doc.instances[index].id) catch |err| {
                        ui.failure = err;
                        return;
                    };
                    if (ui.draft.instance_id) |old| ui.allocator.free(old);
                    ui.draft.instance_id = owned;
                    changed(ui);
                }
            }
        } else components.emptyState(@src(), "暂无实例");
    }
    if (!ui.adding) {
        if (ui.draft.id) |id| if (components.button(@src(), "删除", .{ .tag = "server-delete", .destructive = true, .expand = true, .enabled = ui.deleting_id == null })) ui.queue(.ask_delete, id);
    }
}

/// The caller owns the utility menu shell and footer; actions remain deferred.
pub fn drawSidebar(ui: *Ui, store: *config.Store, manager: *server_manager.Manager) void {
    const doc = store.snapshot();
    const enabled = ui.deleting_id == null;
    if (components.sidebarAction(@src(), "add-server", "添加服务器", .{ .icon = dvui.entypo.plus, .selected = ui.editor_open and ui.draft.id == null, .enabled = enabled, .gap_after = 0 })) ui.queue(.add, null);
    const list = components.scrollBody(@src());
    defer list.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = theme.spacing.sidebar_action_gap } });
    if (doc.servers.len == 0) components.emptyState(@src(), "暂无服务器");
    for (doc.servers, 0..) |server, index| {
        const row = dvui.box(@src(), .{}, .{ .id_extra = @as(usize, @truncate(std.hash.Wyhash.hash(0, server.id))), .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = if (index + 1 == doc.servers.len) 0 else theme.spacing.card_gap } });
        defer row.deinit();
        const selected = if (ui.editor_open) sameId(ui.draft.id, server.id) else sameId(doc.selected_server, server.id);
        if (server_card.draw(@src(), server, doc, manager.pickerSnapshot(server.id), .{ .selected = selected, .enabled = enabled, .require_instance = false, .width = row.data().contentRect().w, .tag = fmt("server-option-{s}", .{server.id}) })) ui.queue(.select_sidebar, server.id);
    }
}

/// Right-hand content. Store and manager snapshots stay borrowed until finish.
pub fn draw(ui: *Ui, store: *config.Store, manager: *server_manager.Manager) void {
    _ = manager;
    const doc = store.snapshot();
    const page = dvui.box(@src(), .{}, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer page.deinit();
    if (ui.editor_open) {
        drawEditor(ui, doc);
    } else if (doc.selected_server) |id| {
        if (findServer(doc, id) != null) ui.queue(.edit, id);
    } else components.emptyState(@src(), if (doc.servers.len == 0) "暂无服务器" else "从左侧选择服务器");
}

pub fn drawModal(ui: *Ui, doc: *const config.Document) void {
    const id = ui.deleting_id orelse return;
    const server = findServer(doc, id) orelse return;
    const window = components.modal(@src(), "删除服务器", theme.style.dialogs.server_delete_height);
    defer window.deinit();
    {
        const actions = components.modalActions(@src(), 2);
        defer actions.deinit();
        if (components.button(@src(), "取消", .{ .placement = .footer, .min_width = 120 })) ui.queue(.cancel_delete, null);
        if (components.button(@src(), "确认删除", .{ .placement = .footer, .min_width = 152, .gravity_x = 1, .primary = true })) ui.queue(.delete, id);
    }
    const body = components.scrollBody(@src());
    defer body.deinit();
    components.text(@src(), fmt("删除服务器「{s}」？", .{server.name}), theme.foreground);
    if (ui.failure) |err| components.text(@src(), fmt("操作失败：{s}", .{@errorName(err)}), theme.danger);
}

pub fn selectLaunchTarget(store: *config.Store, manager: *server_manager.Manager, id: []const u8) !void {
    try selectTarget(store, id, true);
    try syncSelectedTarget(store, manager);
}

fn selectTarget(store: *config.Store, id: []const u8, validate_launch: bool) !void {
    var document = store.snapshot().*;
    const server = findServer(&document, id) orelse return error.ServerNotFound;
    // Management must remain accessible when a stored endpoint needs repair.
    if (validate_launch) _ = try servers.selectLaunch(server, document.instances);
    if (sameId(document.selected_server, server.id) and sameId(document.selected_instance, server.instance_id)) return;
    document.selected_server = server.id;
    document.selected_instance = server.instance_id;
    try store.update(document);
}

fn syncSelectedTarget(store: *config.Store, manager: *server_manager.Manager) !void {
    const document = store.snapshot();
    const server = findServer(document, document.selected_server.?).?;
    // Management selection must report invalid stored endpoints synchronously.
    _ = servers.validateAddress(server.address, server.port) catch |err| {
        manager.clear();
        return err;
    };
    try manager.selectConfigured(server);
}

fn refreshSelectedTarget(store: *config.Store, manager: *server_manager.Manager) !void {
    const selected_document = store.snapshot();
    manager.refreshConfigured(findServer(selected_document, selected_document.selected_server.?).?) catch |err| {
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
    ui.dirty = false;
    ui.save_timer = null;
    if (ui.adding) {
        ui.editor_open = false;
        ui.adding = false;
        ui.draft.deinit(ui.allocator);
    }
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
        ui.adding = false;
        ui.dirty = false;
        ui.save_timer = null;
        ui.draft.deinit(ui.allocator);
    }
    if (ui.deleting_id) |owned| ui.allocator.free(owned);
    ui.deleting_id = null;
}

/// Must run after ALL parent/root/floating widgets have been closed.
pub fn finish(ui: *Ui, store: *config.Store, manager: *server_manager.Manager) void {
    const pending = ui.pending orelse {
        if (ui.dirty and !ui.adding) {
            if (ui.save_timer) |id| if (dvui.timerDone(id)) {
                ui.save_timer = null;
                save(ui, store, manager) catch |err| {
                    ui.failure = err;
                    return;
                };
                ui.failure = null;
            };
        }
        return;
    };
    ui.pending = null;
    defer if (pending.id) |id| ui.allocator.free(id);
    ui.failure = null;
    apply(ui, store, manager, pending) catch |err| {
        ui.failure = err;
    };
}
fn apply(ui: *Ui, store: *config.Store, manager: *server_manager.Manager, pending: Pending) !void {
    // Persist an existing draft before navigation; on failure keep it editable.
    switch (pending.action) {
        .add, .edit, .select_sidebar => if (ui.dirty and !ui.adding) try save(ui, store, manager),
        else => {},
    }
    switch (pending.action) {
        .add => {
            ui.draft.deinit(ui.allocator);
            ui.editor_open = true;
            ui.adding = true;
            ui.dirty = false;
            ui.save_timer = null;
        },
        .edit => {
            const server = findServer(store.snapshot(), pending.id.?) orelse return error.ServerNotFound;
            const draft = try Draft.fromServer(ui.allocator, server);
            ui.draft.deinit(ui.allocator);
            ui.draft = draft;
            ui.editor_open = true;
            ui.adding = false;
            ui.dirty = false;
            ui.save_timer = null;
        },
        .select => try selectLaunchTarget(store, manager, pending.id.?),
        .refresh => {
            try selectTarget(store, pending.id.?, true);
            try refreshSelectedTarget(store, manager);
        },
        .select_sidebar => {
            // Select first, so even a failed query leaves Edit/Delete reachable.
            try selectTarget(store, pending.id.?, false);
            syncSelectedTarget(store, manager) catch |err| {
                ui.failure = err;
            };
            const server = findServer(store.snapshot(), pending.id.?) orelse return error.ServerNotFound;
            const draft = try Draft.fromServer(ui.allocator, server);
            ui.draft.deinit(ui.allocator);
            ui.draft = draft;
            ui.editor_open = true;
            ui.adding = false;
            ui.dirty = false;
            ui.save_timer = null;
            if (ui.deleting_id) |id| ui.allocator.free(id);
            ui.deleting_id = null;
        },
        .clear_server => {
            var document = store.snapshot().*;
            document.selected_server = null;
            try store.update(document);
            manager.clear();
        },
        .cancel_query => manager.cancelSelected(),
        .save => try save(ui, store, manager),
        .cancel_edit => {
            ui.draft.deinit(ui.allocator);
            ui.editor_open = false;
            ui.adding = false;
            ui.dirty = false;
            ui.save_timer = null;
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
test "home choices include every server and instance mode clears only server selection" {
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
    try std.testing.expectEqual(@as(usize, 3), choices.labels.len);
    try std.testing.expect(choices.ids[0] == null);
    try std.testing.expectEqualStrings("visible", choices.ids[1].?);
    try std.testing.expectEqualStrings("hidden", choices.ids[2].?);
    try std.testing.expectEqual(@as(?usize, 2), choices.choice);
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
    try store.reconcile();
    const persisted = &store;
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
test "existing server edits persist before navigation and preserve invalid drafts" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    try store.update(.{ .instances = fixtureInstances, .servers = &.{.{ .id = "existing", .name = "Before", .address = "127.0.0.1", .instance_id = "One" }} });
    var manager = server_manager.Manager.initWithQuery(a, std.testing.io, offlineFixture);
    defer manager.deinit();
    var ui = Ui.init(a);
    defer ui.deinit();
    ui.queue(.edit, "existing");
    finish(&ui, &store, &manager);
    @memset(&ui.draft.name, 0);
    @memcpy(ui.draft.name[0..5], "After");
    ui.dirty = true;
    ui.queue(.save, null);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.failure == null and ui.editor_open and !ui.adding and !ui.dirty);
    try std.testing.expectEqualStrings("After", store.snapshot().servers[0].name);
    try std.testing.expectEqualStrings("existing", ui.draft.id.?);
    @memset(&ui.draft.port, 0);
    @memcpy(ui.draft.port[0..3], "bad");
    ui.dirty = true;
    ui.queue(.add, null);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.InvalidServerPort, ui.failure.?);
    try std.testing.expect(ui.editor_open and !ui.adding and ui.dirty);
    try std.testing.expectEqualStrings("bad", text(&ui.draft.port));
    @memset(&ui.draft.port, 0);
    @memcpy(ui.draft.port[0..5], "25566");
    ui.queue(.add, null);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.failure == null and ui.editor_open and ui.adding and !ui.dirty);
    try std.testing.expectEqual(@as(u16, 25566), store.snapshot().servers[0].port);
    try std.testing.expect(ui.draft.id == null);
}

fn oomDraft(a: Allocator) !void {
    var draft = try Draft.fromServer(a, .{ .id = "server", .name = "Example", .address = "127.0.0.1", .instance_id = "One" });
    defer draft.deinit(a);
}
test "server editor cloning frees allocations at every failure point" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, oomDraft, .{});
}
