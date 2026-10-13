const std = @import("std");
const config = @import("core/config.zig");
const servers = @import("core/servers.zig");
const server_manager = @import("ui/server_manager.zig");
const game_selection_view = @import("ui/game_selection_view.zig");
const servers_view = @import("ui/servers_view.zig");

const testing = std.testing;

// Both instances use the same Minecraft version. Names, stable IDs, and server
// order intentionally differ so a version/name/index based selection fails.
const fixture_instances: []const config.Instance = &.{
    .{ .id = "instance-alpha", .name = "Alpha Home", .minecraft_version = "1.21" },
    .{ .id = "instance-beta", .name = "Beta Home", .minecraft_version = "1.21" },
};
const fixture_servers: []const config.Server = &.{
    .{ .id = "server-alpha", .name = "Alpha Server", .address = "127.0.0.1", .port = 25566, .instance_id = "instance-beta", .show_on_home = true },
    .{ .id = "server-beta", .name = "Beta Server", .address = "127.0.0.1", .instance_id = "instance-alpha", .show_on_home = true },
};

fn offlineQuery(_: std.mem.Allocator, _: std.Io, _: config.Server, _: servers.Options) anyerror!servers.OwnedStatus {
    return error.ConnectionRefused;
}

fn fixtureStore(tmp: *testing.TmpDir) !config.Store {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &buffer);
    var store = try config.Store.init(testing.allocator, testing.io, buffer[0..length]);
    errdefer store.deinit();
    try store.update(.{
        .instances = fixture_instances,
        .servers = fixture_servers,
        .selected_instance = "instance-alpha",
        .selected_server = "server-beta",
    });
    return store;
}

fn expectSelection(document: *const config.Document, instance_id: []const u8, server_id: ?[]const u8) !void {
    try testing.expectEqualStrings(instance_id, document.selected_instance orelse return error.MissingSelectedInstance);
    if (server_id) |id| {
        try testing.expectEqualStrings(id, document.selected_server orelse return error.MissingSelectedServer);
    } else {
        try testing.expect(document.selected_server == null);
    }
}

fn expectReload(store: *const config.Store, instance_id: []const u8, server_id: ?[]const u8) !void {
    try testing.expectError(error.LauncherRootInUse, config.Store.init(testing.allocator, testing.io, store.root));
    // Read the persisted document while the sole writer remains owned.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, store.file, testing.allocator, .limited(16 * 1024 * 1024));
    defer testing.allocator.free(bytes);
    const reloaded = try std.json.parseFromSlice(config.Document, testing.allocator, bytes, .{});
    defer reloaded.deinit();
    try expectSelection(&reloaded.value, instance_id, server_id);
    try testing.expectEqual(@as(usize, 2), reloaded.value.instances.len);
    try testing.expectEqual(@as(usize, 2), reloaded.value.servers.len);
}

fn awaitSettled(manager: *server_manager.Manager) !void {
    const start = std.Io.Clock.now(.awake, testing.io);
    while (manager.isBusy()) {
        manager.tick();
        if (start.durationTo(std.Io.Clock.now(.awake, testing.io)).toMilliseconds() > 2000) return error.FixtureTimeout;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn expectOfflineTarget(manager: *const server_manager.Manager, server_id: []const u8, instance_id: []const u8) !void {
    const snapshot = manager.snapshot();
    try testing.expectEqual(servers.State.offline, snapshot.state);
    try testing.expectEqual(error.ConnectionRefused, snapshot.failure.?);
    try testing.expectEqualStrings(server_id, snapshot.server.?.id);
    try testing.expectEqualStrings(instance_id, snapshot.server.?.instance_id);
}

test "game selector persists exact instance IDs with shared Minecraft versions and clears server selection" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try fixtureStore(&tmp);
    defer store.deinit();
    var manager = server_manager.Manager.initWithQuery(testing.allocator, testing.io, offlineQuery);
    defer manager.deinit();

    try testing.expectEqualStrings(store.snapshot().instances[0].minecraft_version, store.snapshot().instances[1].minecraft_version);
    try game_selection_view.selectServer(&store, &manager, "server-beta");
    try awaitSettled(&manager);
    try expectOfflineTarget(&manager, "server-beta", "instance-alpha");

    for ([_][]const u8{ "instance-beta", "instance-alpha", "instance-beta" }) |id| {
        try game_selection_view.selectInstance(&store, &manager, id);
        try expectSelection(store.snapshot(), id, null);
        try expectReload(&store, id, null);
        const query = manager.snapshot();
        try testing.expectEqual(servers.State.idle, query.state);
        try testing.expect(query.server == null and query.status == null and query.failure == null);
    }
}

test "game selector commits each server exact bound instance rather than matching version or list order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try fixtureStore(&tmp);
    defer store.deinit();
    var manager = server_manager.Manager.initWithQuery(testing.allocator, testing.io, offlineQuery);
    defer manager.deinit();

    for (fixture_servers) |server| {
        try game_selection_view.selectServer(&store, &manager, server.id);
        try expectSelection(store.snapshot(), server.instance_id, server.id);
        try expectReload(&store, server.instance_id, server.id);
        try awaitSettled(&manager);
        try expectOfflineTarget(&manager, server.id, server.instance_id);
    }
}

test "game selector unknown IDs preserve configured selection and existing server query" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try fixtureStore(&tmp);
    defer store.deinit();
    var manager = server_manager.Manager.initWithQuery(testing.allocator, testing.io, offlineQuery);
    defer manager.deinit();

    try game_selection_view.selectServer(&store, &manager, "server-alpha");
    try awaitSettled(&manager);
    try testing.expectError(error.InstanceNotConfigured, game_selection_view.selectInstance(&store, &manager, "missing-instance"));
    try expectSelection(store.snapshot(), "instance-beta", "server-alpha");
    try expectReload(&store, "instance-beta", "server-alpha");
    try expectOfflineTarget(&manager, "server-alpha", "instance-beta");

    try testing.expectError(error.ServerNotFound, game_selection_view.selectServer(&store, &manager, "missing-server"));
    try expectSelection(store.snapshot(), "instance-beta", "server-alpha");
    try expectReload(&store, "instance-beta", "server-alpha");
    try expectOfflineTarget(&manager, "server-alpha", "instance-beta");

    // Missing targets must also preserve ordinary instance-only launch mode.
    try game_selection_view.selectInstance(&store, &manager, "instance-alpha");
    try testing.expectError(error.InstanceNotConfigured, game_selection_view.selectInstance(&store, &manager, "missing-instance"));
    try testing.expectError(error.ServerNotFound, game_selection_view.selectServer(&store, &manager, "missing-server"));
    try expectSelection(store.snapshot(), "instance-alpha", null);
    try expectReload(&store, "instance-alpha", null);
    try testing.expectEqual(servers.State.idle, manager.snapshot().state);
}

test "game selector accepts instance IDs borrowed from snapshots across repeated config updates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try fixtureStore(&tmp);
    defer store.deinit();
    var manager = server_manager.Manager.initWithQuery(testing.allocator, testing.io, offlineQuery);
    defer manager.deinit();

    // Each call retires the Store arena that owns its argument. Never use the
    // borrowed argument after that call; assert against fresh snapshots instead.
    try game_selection_view.selectInstance(&store, &manager, store.snapshot().instances[1].id);
    try expectSelection(store.snapshot(), "instance-beta", null);
    try expectReload(&store, "instance-beta", null);
    try game_selection_view.selectInstance(&store, &manager, store.snapshot().selected_instance.?);
    try expectSelection(store.snapshot(), "instance-beta", null);
    try expectReload(&store, "instance-beta", null);
    try game_selection_view.selectInstance(&store, &manager, store.snapshot().instances[0].id);
    try expectSelection(store.snapshot(), "instance-alpha", null);
    try expectReload(&store, "instance-alpha", null);
}

test "game selector accepts borrowed server IDs and query strings survive subsequent config updates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try fixtureStore(&tmp);
    defer store.deinit();
    var manager = server_manager.Manager.initWithQuery(testing.allocator, testing.io, offlineQuery);
    defer manager.deinit();

    try game_selection_view.selectServer(&store, &manager, store.snapshot().servers[0].id);
    try expectSelection(store.snapshot(), "instance-beta", "server-alpha");
    try expectReload(&store, "instance-beta", "server-alpha");
    try awaitSettled(&manager);
    try expectOfflineTarget(&manager, "server-alpha", "instance-beta");

    try game_selection_view.selectServer(&store, &manager, store.snapshot().selected_server.?);
    try expectSelection(store.snapshot(), "instance-beta", "server-alpha");
    try expectReload(&store, "instance-beta", "server-alpha");

    // Retire the new config arena too: manager owns all queued/published strings.
    var document = store.snapshot().*;
    document.settings.default_memory_mb = 4096;
    try store.update(document);
    try awaitSettled(&manager);
    try expectOfflineTarget(&manager, "server-alpha", "instance-beta");
    const queried = manager.snapshot().server.?;
    try testing.expectEqualStrings("Alpha Server", queried.name);
    try testing.expectEqualStrings("127.0.0.1", queried.address);
    try testing.expectEqual(@as(u16, 25566), queried.port);
    try expectReload(&store, "instance-beta", "server-alpha");

    try game_selection_view.selectServer(&store, &manager, store.snapshot().servers[1].id);
    try expectSelection(store.snapshot(), "instance-alpha", "server-beta");
    try awaitSettled(&manager);
    try expectOfflineTarget(&manager, "server-beta", "instance-alpha");
    try expectReload(&store, "instance-alpha", "server-beta");
}

const ClickQuery = struct {
    var calls: [2]std.atomic.Value(u32) = @splat(.init(0));
    var blocked: [2]std.atomic.Value(bool) = @splat(.init(false));
    var canceled: [2]std.atomic.Value(u32) = @splat(.init(0));

    fn reset() void {
        for (&calls, &blocked, &canceled) |*count, *gate, *cancel_count| {
            count.store(0, .release);
            gate.store(false, .release);
            cancel_count.store(0, .release);
        }
    }
    fn query(a: std.mem.Allocator, io: std.Io, server: config.Server, options: servers.Options) anyerror!servers.OwnedStatus {
        const i: usize = if (std.mem.eql(u8, server.id, "server-alpha")) 0 else if (std.mem.eql(u8, server.id, "server-beta")) 1 else return error.UnexpectedFixtureServer;
        _ = calls[i].fetchAdd(1, .acq_rel);
        while (blocked[i].load(.acquire)) {
            if (options.cancellation.?.load(.acquire)) {
                _ = canceled[i].fetchAdd(1, .acq_rel);
                return error.Canceled;
            }
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        return servers.parseStatus(a, "{\"version\":{\"name\":\"fixture\",\"protocol\":1},\"description\":\"fixture\"}");
    }
    fn awaitCount(manager: *server_manager.Manager, i: usize, expected: u32) !void {
        const start = std.Io.Clock.now(.awake, testing.io);
        while (calls[i].load(.acquire) < expected) {
            manager.tick();
            if (start.durationTo(std.Io.Clock.now(.awake, testing.io)).toMilliseconds() > 2000) return error.FixtureTimeout;
            try testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        try testing.expectEqual(expected, calls[i].load(.acquire));
    }
};

test "server card clicks bind exact instance and retain the same first query and completed status" {
    ClickQuery.reset();
    ClickQuery.blocked[0].store(true, .release);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try fixtureStore(&tmp);
    defer store.deinit();
    var manager = server_manager.Manager.initWithQuery(testing.allocator, testing.io, ClickQuery.query);
    defer manager.deinit();
    try game_selection_view.selectServer(&store, &manager, store.snapshot().servers[0].id);
    try ClickQuery.awaitCount(&manager, 0, 1);
    const original = manager.active.?;
    const deadline = manager.selected_next_poll_ms;
    for (0..5) |_| {
        try game_selection_view.selectServer(&store, &manager, store.snapshot().selected_server.?);
        try manager.updateSelected(store.snapshot(), true);
        try manager.updatePicker(store.snapshot().servers, true);
        try testing.expect(manager.active == original);
        try testing.expect(!original.cancellation.load(.acquire));
        try testing.expectEqual(deadline, manager.selected_next_poll_ms);
        try expectSelection(store.snapshot(), "instance-beta", "server-alpha");
    }
    ClickQuery.blocked[0].store(false, .release);
    try awaitSettled(&manager);
    const status = manager.snapshot().status.?;
    for (0..5) |_| {
        try game_selection_view.selectServer(&store, &manager, store.snapshot().selected_server.?);
        try manager.updateSelected(store.snapshot(), true);
        try manager.updatePicker(store.snapshot().servers, true);
        try testing.expectEqual(status, manager.snapshot().status.?);
        try testing.expectEqual(deadline, manager.selected_next_poll_ms);
        try testing.expect(!manager.snapshot().worker_active);
    }
    // Repair an inconsistent saved binding even when the same server is clicked.
    var document = store.snapshot().*;
    document.selected_instance = "instance-alpha";
    try store.update(document);
    try game_selection_view.selectServer(&store, &manager, store.snapshot().selected_server.?);
    try expectSelection(store.snapshot(), "instance-beta", "server-alpha");
    try expectReload(&store, "instance-beta", "server-alpha");
    try testing.expectEqual(status, manager.snapshot().status.?);
    try testing.expectEqual(@as(u32, 1), ClickQuery.calls[0].load(.acquire));
    try testing.expectEqual(@as(u32, 1), ClickQuery.calls[1].load(.acquire));
    try testing.expectEqual(@as(u32, 0), ClickQuery.canceled[0].load(.acquire));
}

test "switching cached server cards and management selections reuse queries while explicit refresh forces one" {
    ClickQuery.reset();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try fixtureStore(&tmp);
    defer store.deinit();
    var manager = server_manager.Manager.initWithQuery(testing.allocator, testing.io, ClickQuery.query);
    defer manager.deinit();
    var ui = servers_view.Ui.init(testing.allocator);
    defer ui.deinit();
    try manager.updatePicker(store.snapshot().servers, true);
    try awaitSettled(&manager);
    const statuses = [_]*const servers.OwnedStatus{ manager.pickerSnapshot("server-alpha").status.?, manager.pickerSnapshot("server-beta").status.? };
    for ([_]usize{ 0, 1, 0, 1, 0 }) |i| {
        try game_selection_view.selectServer(&store, &manager, store.snapshot().servers[i].id);
        try manager.updateSelected(store.snapshot(), true);
        try manager.updatePicker(store.snapshot().servers, true);
        try testing.expectEqual(statuses[i], manager.snapshot().status.?);
        try expectSelection(store.snapshot(), fixture_servers[i].instance_id, fixture_servers[i].id);
    }
    // Management/sidebar selection follows the same selection contract.
    ui.pending = .{ .action = .select_sidebar, .id = try testing.allocator.dupe(u8, "server-beta") };
    servers_view.finish(&ui, &store, &manager);
    try testing.expect(ui.failure == null);
    try manager.updateSelected(store.snapshot(), true);
    try manager.updatePicker(store.snapshot().servers, true);
    try testing.expectEqual(statuses[1], manager.snapshot().status.?);
    for (&ClickQuery.calls) |*count| try testing.expectEqual(@as(u32, 1), count.load(.acquire));
    // Refresh a nonselected card: select its binding, keep its cached status while
    // refreshing, and preserve the other card's completed query.
    ClickQuery.blocked[0].store(true, .release);
    ui.pending = .{ .action = .refresh, .id = try testing.allocator.dupe(u8, "server-alpha") };
    servers_view.finish(&ui, &store, &manager);
    try testing.expect(ui.failure == null);
    try ClickQuery.awaitCount(&manager, 0, 2);
    try expectSelection(store.snapshot(), "instance-beta", "server-alpha");
    try manager.updateSelected(store.snapshot(), true);
    try manager.updatePicker(store.snapshot().servers, true);
    try testing.expectEqual(statuses[0], manager.snapshot().status.?);
    try testing.expect(manager.snapshot().worker_active);
    try testing.expectEqual(statuses[1], manager.pickerSnapshot("server-beta").status.?);
    try testing.expectEqual(@as(u32, 1), ClickQuery.calls[1].load(.acquire));
    // Clicking the refreshing card must leave that forced refresh running.
    const refresh = manager.active.?;
    try game_selection_view.selectServer(&store, &manager, store.snapshot().selected_server.?);
    try testing.expect(manager.active == refresh);
    try testing.expect(!refresh.cancellation.load(.acquire));
    ClickQuery.blocked[0].store(false, .release);
    try awaitSettled(&manager);
    try testing.expectEqual(@as(u32, 2), ClickQuery.calls[0].load(.acquire));
    try testing.expectEqual(@as(u32, 0), ClickQuery.canceled[0].load(.acquire));
}

test "sidebar selection of a legacy invalid endpoint preserves binding and rejects queries synchronously" {
    ClickQuery.reset();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try fixtureStore(&tmp);
    defer store.deinit();
    var configured = [_]config.Server{ fixture_servers[0], fixture_servers[1] };
    configured[1].address = "localhost:25565";
    var document = store.snapshot().*;
    document.servers = &configured;
    try store.update(document);
    var manager = server_manager.Manager.initWithQuery(testing.allocator, testing.io, ClickQuery.query);
    defer manager.deinit();
    var ui = servers_view.Ui.init(testing.allocator);
    defer ui.deinit();
    try game_selection_view.selectServer(&store, &manager, "server-alpha");
    try awaitSettled(&manager);
    try testing.expect(manager.snapshot().status != null);
    try testing.expectEqual(@as(u32, 1), ClickQuery.calls[0].load(.acquire));

    for (0..5) |_| {
        ui.pending = .{ .action = .select_sidebar, .id = try testing.allocator.dupe(u8, store.snapshot().servers[1].id) };
        servers_view.finish(&ui, &store, &manager);
        try testing.expectEqual(error.InvalidAddress, ui.failure.?);
        try expectSelection(store.snapshot(), "instance-alpha", "server-beta");
        try expectReload(&store, "instance-alpha", "server-beta");
        // Clear the old valid status immediately: it cannot describe this target.
        const query = manager.snapshot();
        try testing.expectEqual(servers.State.idle, query.state);
        try testing.expect(query.server == null and query.status == null and query.failure == null);
        try testing.expect(manager.active == null and manager.pending == null);
        try testing.expect(!query.worker_active);
        try awaitSettled(&manager);
        try testing.expectEqual(@as(u32, 1), ClickQuery.calls[0].load(.acquire));
        try testing.expectEqual(@as(u32, 0), ClickQuery.calls[1].load(.acquire));
        try testing.expectEqual(@as(u32, 0), ClickQuery.canceled[0].load(.acquire));
    }
}

test "manual refresh of an uncached server starts exactly one owned query in every picker state" {
    const PickerState = enum { absent, closed, open };
    for ([_]PickerState{ .absent, .closed, .open }) |picker_state| {
        ClickQuery.reset();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var store = try fixtureStore(&tmp);
        defer store.deinit();
        var manager = server_manager.Manager.initWithQuery(testing.allocator, testing.io, ClickQuery.query);
        defer manager.deinit();
        var ui = servers_view.Ui.init(testing.allocator);
        defer ui.deinit();
        try game_selection_view.selectServer(&store, &manager, "server-alpha");
        try awaitSettled(&manager);
        const alpha_status = manager.snapshot().status.?;
        if (picker_state != .absent) {
            // Beta is configured but has never had a card query in this picker.
            try manager.updatePicker(store.snapshot().servers[0..1], true);
            if (picker_state == .closed) try manager.updatePicker(store.snapshot().servers[0..1], false);
        }
        ClickQuery.blocked[1].store(true, .release);
        ui.pending = .{ .action = .refresh, .id = try testing.allocator.dupe(u8, "server-beta") };
        servers_view.finish(&ui, &store, &manager);
        try testing.expect(ui.failure == null);
        try expectSelection(store.snapshot(), "instance-alpha", "server-beta");
        // These synchronous invariants catch an unwanted first job even when its
        // adapter callback has not run yet: a double-start cancels/supersedes it.
        try testing.expect(manager.active_current);
        try testing.expect(manager.pending == null);
        const original = manager.active.?;
        try testing.expect(!original.cancellation.load(.acquire));
        try ClickQuery.awaitCount(&manager, 1, 1);
        for (0..3) |_| try manager.updateSelected(store.snapshot(), true);
        try testing.expect(manager.active == original);
        try testing.expect(!original.cancellation.load(.acquire));
        if (picker_state == .open) {
            try manager.updatePicker(store.snapshot().servers, true);
            try testing.expectEqual(alpha_status, manager.pickerSnapshot("server-alpha").status.?);
            try testing.expectEqual(@as(u32, 1), ClickQuery.calls[0].load(.acquire));
        }
        ClickQuery.blocked[1].store(false, .release);
        try awaitSettled(&manager);
        try testing.expectEqual(servers.State.online, manager.snapshot().state);
        try testing.expectEqual(@as(u32, 1), ClickQuery.calls[1].load(.acquire));
        try testing.expectEqual(@as(u32, 0), ClickQuery.canceled[1].load(.acquire));
    }
}
