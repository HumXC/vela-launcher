//! Production binding between local intent-only widgets and guarded services.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const instances = @import("../core/instances.zig");
const model_module = @import("model.zig");
const resource_menu = @import("resource_type_menu.zig");
const controller_module = @import("mods_controller.zig");
const content = @import("content_manager.zig");
const presentation = @import("mods_view.zig");
const components = @import("components.zig");
const theme = @import("theme.zig");
const download_view = @import("resource_download_view.zig");

fn selected(model: *const model_module.Model, doc: *const config.Document) ?config.Instance {
    // A resource-page override may outlive deletion from the configuration.
    if (model.mods_instance.len > 0) if (instances.findById(doc, model.mods_instance.get())) |instance| return instance.*;
    if (doc.selected_instance) |id| if (instances.findById(doc, id)) |instance| return instance.*;
    return if (doc.instances.len > 0) doc.instances[0] else null;
}

pub fn sidebar(model: *model_module.Model, pending: *?model_module.Msg, doc: *const config.Document, controller: *controller_module.Controller, ui: *presentation.Ui, allowed: bool) void {
    const side = components.sidebarPanel(@src());
    defer side.deinit();
    const enabled = allowed and controller.mutation == .idle and !ui.acquisition.locked() and !ui.info_open;
    if (ui.resource_menu_route != ui.acquisition.route) ui.resource_menu.close();
    ui.resource_menu_route = ui.acquisition.route;
    if (enabled) {
        switch (components.navigationFooter(@src(), model.parentLabel(), true)) {
            .back => pending.* = model.parentMessage(),
            .home => pending.* = .back,
            .none => {},
        }
    } else {
        const footer = dvui.box(@src(), .{}, .{ .expand = .horizontal, .gravity_y = 1, .padding = .all(0), .margin = .all(0), .background = false });
        defer footer.deinit();
        _ = components.button(@src(), model.parentLabel(), .{ .enabled = false, .expand = true, .tag = "mods-sidebar-back-locked" });
    }
    // Reserve one fixed-height selector above return navigation in every state.
    {
        const management = dvui.box(@src(), .{}, .{ .tag = "mods-management", .expand = .horizontal, .gravity_y = 1, .padding = .all(0), .margin = .{ .h = 16 }, .background = false });
        defer management.deinit();
        if (resource_menu.draw(@src(), &ui.resource_menu, ui.kind, enabled and pending.* == null)) |kind| ui.kind = kind;
    }
    components.title(@src(), "资源管理");
    _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.sidebar_header_gap) });
    const scroll = components.scrollBody(@src());
    defer scroll.deinit();
    const current = selected(model, doc);
    for (doc.instances) |instance| {
        if (components.sidebarItem(@src(), instance.id, instance.name, .{
            .subtitle = instance.minecraft_version,
            .selected = if (current) |value| std.mem.eql(u8, value.id, instance.id) else false,
            .enabled = enabled,
        })) {
            ui.resource_menu.close();
            _ = model.mods_instance.set(instance.id);
        }
    }
}

fn boundSnapshot(model: *const model_module.Model, doc: *const config.Document, controller: *controller_module.Controller, ui: *presentation.Ui, backend: *content.Manager, allow_mutations: bool) !presentation.Snapshot {
    const instance = selected(model, doc) orelse {
        ui.acquisition.cancelPageLoads(backend);
        if (!ui.acquisition.locked()) ui.acquisition.reset();
        return .{ .failure = error.NoSelectedInstance };
    };
    if (!controller.matches(instance, ui.kind)) {
        ui.acquisition.cancelPageLoads(backend);
        controller.select(instance, ui.kind, backend) catch |err| return .{ .failure = err, .busy = backend.isBusy() };
        ui.clearIntent();
        try ui.selectPath(null);
        ui.info_open = false;
    }
    try ui.acquisition.bind(instance, ui.kind);
    ui.acquisition.provider = backend.snapshot().provider;
    var snapshot = try controller.viewSnapshot(backend, allow_mutations);
    snapshot.title = switch (ui.kind) {
        .mod => instance.name,
        .resourcepack => "资源包",
        .shader => "光影",
    };
    snapshot.subtitle = try std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} · Minecraft {s} · {s}", .{ instance.name, instance.minecraft_version, @tagName(instance.loader) });
    if (controller.busy() or backend.isBusy()) dvui.timer(dvui.parentGet().data().id.update("mods-worker-poll"), 50_000);
    return snapshot;
}

fn persistListView(store: *config.Store, list: bool) !void {
    if (store.publicationUncertain()) try store.reconcile();
    var document = store.snapshot().*;
    if (document.settings.resource_list_view == list) return;
    document.settings.resource_list_view = list;
    try store.update(document);
}

pub fn draw(model: *const model_module.Model, doc: *const config.Document, controller: *controller_module.Controller, ui: *presentation.Ui, backend: *content.Manager, allow_mutations: bool) !void {
    ui.list = doc.settings.resource_list_view;
    const snapshot = try boundSnapshot(model, doc, controller, ui, backend, allow_mutations);
    ui.acquisition.tick(backend, allow_mutations);
    if (ui.acquisition.changed) {
        ui.acquisition.changed = false;
        controller.refresh();
    }
    if (ui.acquisition.route == .local) presentation.draw(ui, snapshot) else download_view.draw(&ui.acquisition, backend.snapshot(), allow_mutations, if (controller.published) |published| published.entries else &.{});
}
pub fn dialogs(model: *const model_module.Model, doc: *const config.Document, controller: *controller_module.Controller, ui: *presentation.Ui, backend: *content.Manager, allow_mutations: bool) !void {
    const snapshot = try boundSnapshot(model, doc, controller, ui, backend, allow_mutations);
    if (ui.acquisition.route == .local) presentation.drawDialogs(ui, snapshot) else download_view.drawDialogs(&ui.acquisition, backend.snapshot(), allow_mutations);
}
/// Called after the entire widget tree (including floating windows) closes.
pub fn finish(model: *model_module.Model, store: *config.Store, controller: *controller_module.Controller, ui: *presentation.Ui, backend: *content.Manager, allowed: bool) void {
    ui.acquisition.finish(backend, allowed, model.panel == .mods);
    if (!allowed or model.panel != .mods or controller.mutation != .idle or ui.acquisition.locked() or ui.info_open or ui.resource_menu_route != ui.acquisition.route) ui.resource_menu.close();
    ui.resource_menu_route = ui.acquisition.route;
    if (model.panel != .mods) {
        ui.acquisition.cancelPageLoads(backend);
        ui.acquisition.discardPicker();
        if (!ui.acquisition.locked()) ui.acquisition.reset();
    }
    const intent = ui.takeIntent() orelse return;
    defer ui.deinitIntent(intent);
    switch (intent) {
        .back => model_module.transition(model, .utility_back),
        .refresh => controller.refresh(),
        .list_view => |list| {
            persistListView(store, list) catch |err| {
                ui.failure = err;
                return;
            };
            ui.list = list;
        },
        .toggle => |value| {
            if (!allowed or model.panel != .mods) {
                ui.failure = error.ContentControlsLocked;
                return;
            }
            controller.toggle(backend, value.path, value.enabled) catch |err| {
                ui.failure = err;
                return;
            };
            ui.filter_after_toggle = if (ui.filter == .all) .all else if (value.enabled) .enabled else .disabled;
        },
    }
}

test "mods page selection skips missing saved IDs and preserves valid overrides" {
    const first: config.Instance = .{ .id = "a", .name = "A", .minecraft_version = "1.21.4" };
    const second: config.Instance = .{ .id = "b", .name = "B", .minecraft_version = "1.21.4" };
    var model: model_module.Model = .{};
    var doc: config.Document = .{ .instances = &.{ first, second }, .selected_instance = second.id };
    try std.testing.expect(model.mods_instance.set(first.id));
    try std.testing.expectEqualStrings(first.id, selected(&model, &doc).?.id);
    try std.testing.expect(model.mods_instance.set("deleted-override"));
    // The saved home selection wins over the first remaining instance.
    try std.testing.expectEqualStrings(second.id, selected(&model, &doc).?.id);
    try std.testing.expect(model.mods_instance.set(first.id));
    // A was visited, then deleted; the home selection now points to B.
    doc.instances = &.{second};
    try std.testing.expectEqualStrings(second.id, selected(&model, &doc).?.id);
    doc.selected_instance = "deleted-selected";
    try std.testing.expectEqualStrings(second.id, selected(&model, &doc).?.id);
    doc.selected_instance = null;
    try std.testing.expectEqualStrings(second.id, selected(&model, &doc).?.id);
    model.mods_instance = .{};
    try std.testing.expectEqualStrings(second.id, selected(&model, &doc).?.id);
    // Neither stale ID can manufacture a selection when no instances remain.
    try std.testing.expect(model.mods_instance.set("deleted-override"));
    doc.instances = &.{};
    doc.selected_instance = "deleted-selected";
    try std.testing.expect(selected(&model, &doc) == null);
    model.mods_instance = .{};
    doc.selected_instance = null;
    try std.testing.expect(selected(&model, &doc) == null);
}

test "mods page rebinding after deletion cancels stale page loads and global block closes menu" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const first: config.Instance = .{ .id = "a", .name = "A", .minecraft_version = "1.21.4" };
    const second: config.Instance = .{ .id = "b", .name = "B", .minecraft_version = "1.21.4" };
    const Fixture = struct {
        fn noHttp(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: @import("../core/http_transport.zig").Request) !@import("../core/http_transport.zig").Response {
            return error.UnexpectedNetwork;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".minecraft/versions/A/mods");
    try tmp.dir.createDirPath(io, ".minecraft/versions/B/mods");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var configuration = try config.Store.init(a, io, root);
    defer configuration.deinit();
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = @import("../core/tasks.zig").Registry.init(a);
    defer registry.deinit();
    var backend = try content.Manager.initOptions(a, io, &paths, &registry, .{ .lease = @import("resource_download_fixture.zig").Lease.callbacks(), .transport_options = .{ .fixture_http = Fixture.noHttp } });
    defer backend.deinit();
    var controller = controller_module.Controller.init(a, io, &paths);
    defer controller.deinit();
    var ui = try presentation.Ui.init(a);
    defer ui.deinit();
    var test_ui = try dvui.testing.init(.{});
    defer test_ui.deinit();
    var model: model_module.Model = .{ .panel = .mods };
    try std.testing.expect(model.mods_instance.set(first.id));
    var doc: config.Document = .{ .instances = &.{first}, .selected_instance = first.id };
    _ = try boundSnapshot(&model, &doc, &controller, &ui, &backend, true);
    for (0..5000) |_| {
        backend.tick();
        if (!backend.isBusy()) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(!backend.isBusy());
    try backend.search("stale A", .mod, 0);
    ui.acquisition.job = .search;
    ui.acquisition.route = .catalog;
    ui.acquisition.needs_prepare = true;
    doc = .{ .instances = &.{second}, .selected_instance = second.id };
    const snapshot = try boundSnapshot(&model, &doc, &controller, &ui, &backend, true);
    try std.testing.expect(snapshot.failure == null);
    try std.testing.expectEqualStrings(second.id, controller.instance_id.?);
    try std.testing.expectEqualStrings(second.id, ui.acquisition.instance.?.id);
    try std.testing.expectEqualStrings(second.id, backend.snapshot().instance.?.id);
    try std.testing.expectEqual(.idle, ui.acquisition.job);
    try std.testing.expect(!ui.acquisition.needs_prepare);
    try std.testing.expectEqual(.local, ui.acquisition.route);
    try std.testing.expect(!backend.active.?.current);
    ui.resource_menu.mode = .pinned;
    var pending: ?model_module.Msg = null;
    sidebar(&model, &pending, &doc, &controller, &ui, false);
    try std.testing.expectEqual(resource_menu.Mode.closed, ui.resource_menu.mode);
    try std.testing.expect(pending == null);
    ui.resource_menu.mode = .pinned;
    finish(&model, &configuration, &controller, &ui, &backend, false);
    try std.testing.expectEqual(resource_menu.Mode.closed, ui.resource_menu.mode);
    // Layout is a UI preference and remains available while content writes are gated.
    try ui.queue(.{ .list_view = true });
    finish(&model, &configuration, &controller, &ui, &backend, false);
    try std.testing.expect(ui.list);
    try std.testing.expect(configuration.snapshot().settings.resource_list_view);
    // Removing every instance also retires page-owned discovery state.
    ui.acquisition.job = .search;
    ui.acquisition.needs_prepare = true;
    doc.instances = &.{};
    const empty = try boundSnapshot(&model, &doc, &controller, &ui, &backend, true);
    try std.testing.expectEqual(error.NoSelectedInstance, empty.failure.?);
    try std.testing.expectEqual(.idle, ui.acquisition.job);
    try std.testing.expect(ui.acquisition.instance == null);
}

test "resource list preference survives restart and preserves other settings" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    {
        var store = try config.Store.init(a, io, root);
        defer store.deinit();
        try std.testing.expect(!store.snapshot().settings.resource_list_view);
        var document = store.snapshot().*;
        document.settings.default_memory_mb = 4096;
        document.settings.download_connections = 12;
        try store.update(document);
        try persistListView(&store, true);
    }
    {
        var store = try config.Store.init(a, io, root);
        defer store.deinit();
        try std.testing.expect(store.snapshot().settings.resource_list_view);
        try std.testing.expectEqual(@as(u32, 4096), store.snapshot().settings.default_memory_mb);
        try std.testing.expectEqual(@as(u16, 12), store.snapshot().settings.download_connections);
        try persistListView(&store, false);
    }
    {
        var store = try config.Store.init(a, io, root);
        defer store.deinit();
        try std.testing.expect(!store.snapshot().settings.resource_list_view);
        try std.testing.expectEqual(@as(u32, 4096), store.snapshot().settings.default_memory_mb);
        try std.testing.expectEqual(@as(u16, 12), store.snapshot().settings.download_connections);
    }
}
