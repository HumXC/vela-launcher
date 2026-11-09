//! Deterministic picker regressions: injected workers only, no network access.
const std = @import("std");
const config = @import("core/config.zig");
const servers = @import("core/servers.zig");
const server_manager = @import("application/server_manager.zig");
const testing = std.testing;
const Manager = server_manager.Manager;
const AtomicCount = std.atomic.Value(u32);
const AtomicFlag = std.atomic.Value(bool);

// Each test joins its manager before resetting this fixture. Per-ID counters
// avoid assumptions about the order in which concurrent workers start.
const Fixture = struct {
    const ids = [_][]const u8{ "alpha", "beta", "offline", "hidden", "selected" };
    var calls: [ids.len]AtomicCount = @splat(.init(0));
    var canceled: [ids.len]AtomicCount = @splat(.init(0));
    var blocked: [ids.len]AtomicFlag = @splat(.init(false));

    fn index(id: []const u8) !usize {
        for (ids, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, id)) return i;
        }
        return error.UnexpectedFixtureServer;
    }

    fn reset() void {
        for (&calls, &canceled, &blocked) |*call_count, *cancel_count, *gate| {
            call_count.store(0, .release);
            cancel_count.store(0, .release);
            gate.store(false, .release);
        }
    }

    fn count(id: []const u8) u32 {
        return calls[index(id) catch unreachable].load(.acquire);
    }

    fn block(id: []const u8, value: bool) void {
        blocked[index(id) catch unreachable].store(value, .release);
    }

    fn query(a: std.mem.Allocator, io: std.Io, server: config.Server, options: servers.Options) anyerror!servers.OwnedStatus {
        const i = try index(server.id);
        _ = calls[i].fetchAdd(1, .acq_rel);
        const cancellation = options.cancellation orelse return error.MissingCancellationToken;
        while (blocked[i].load(.acquire)) {
            if (cancellation.load(.acquire)) {
                _ = canceled[i].fetchAdd(1, .acq_rel);
                return error.Canceled;
            }
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        if (cancellation.load(.acquire)) {
            _ = canceled[i].fetchAdd(1, .acq_rel);
            return error.Canceled;
        }
        // Re-read the ID after the gate too: mutable source storage must never
        // change the job's target while its worker is in flight.
        if (!std.mem.eql(u8, server.id, ids[i])) return error.BorrowedConfig;
        if (std.mem.eql(u8, server.id, "offline")) return error.ConnectionRefused;
        const json = if (std.mem.eql(u8, server.id, "beta"))
            "{\"version\":{\"name\":\"fixture\",\"protocol\":1},\"players\":{\"online\":0,\"max\":12},\"description\":\"fixture\"}"
        else
            "{\"version\":{\"name\":\"fixture\",\"protocol\":1},\"players\":{\"online\":7,\"max\":40},\"description\":\"fixture\"}";
        var status = try servers.parseStatus(a, json);
        errdefer status.deinit();
        const owned = status.arena.allocator();
        // Echo every borrowed input into owned status after the gate, so the
        // ownership test checks worker inputs as well as snapshot metadata.
        status.motd = try owned.dupe(u8, server.name);
        status.version = try owned.dupe(u8, server.address);
        status.description = .{ .string = try owned.dupe(u8, server.instance_id orelse "unbound") };
        status.latency_ms = server.port;
        return status;
    }
};

fn fixtureServer(id: []const u8) config.Server {
    return .{ .id = id, .name = "Original", .address = "127.0.0.1", .instance_id = "instance" };
}

fn expired(start: std.Io.Timestamp) bool {
    return start.durationTo(std.Io.Clock.now(.awake, testing.io)).toMilliseconds() > 2000;
}

fn awaitCalls(manager: *Manager, id: []const u8, expected: u32) !void {
    const start = std.Io.Clock.now(.awake, testing.io);
    while (Fixture.count(id) < expected) {
        manager.tick();
        if (expired(start)) return error.FixtureTimeout;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(expected, Fixture.count(id));
}

fn awaitCardState(manager: *Manager, id: []const u8, state: servers.State) !void {
    const start = std.Io.Clock.now(.awake, testing.io);
    while (manager.pickerSnapshot(id).state != state) {
        manager.tick();
        if (expired(start)) return error.FixtureTimeout;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn awaitSettled(manager: *Manager) !void {
    const start = std.Io.Clock.now(.awake, testing.io);
    while (manager.isBusy()) {
        manager.tick();
        if (expired(start)) return error.FixtureTimeout;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn expectMainIdle(manager: *const Manager) !void {
    const snapshot = manager.snapshot();
    try testing.expectEqual(servers.State.idle, snapshot.state);
    try testing.expect(snapshot.server == null);
    try testing.expect(snapshot.status == null);
    try testing.expect(snapshot.failure == null);
}

fn expectTarget(snapshot: server_manager.Snapshot, id: []const u8, name: []const u8, address: []const u8, port: u16, instance: []const u8) !void {
    try testing.expectEqual(servers.State.online, snapshot.state);
    const server = snapshot.server orelse return error.MissingFixtureServer;
    const status = snapshot.status orelse return error.MissingFixtureStatus;
    try testing.expectEqualStrings(id, server.id);
    try testing.expectEqualStrings(name, server.name);
    try testing.expectEqualStrings(address, server.address);
    try testing.expectEqual(port, server.port);
    try testing.expectEqualStrings(instance, server.instance_id.?);
    try testing.expectEqualStrings(name, status.motd);
    try testing.expectEqualStrings(address, status.version);
    try testing.expectEqual(@as(u64, port), status.latency_ms);
    try testing.expectEqualStrings(instance, status.description.string);
}

test "picker entry immediately queries every configured card without a main selection" {
    Fixture.reset();
    Fixture.block("alpha", true);
    Fixture.block("beta", true);
    Fixture.block("offline", true);
    Fixture.block("hidden", true);
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    const configured = [_]config.Server{
        fixtureServer("alpha"),
        fixtureServer("hidden"),
        fixtureServer("offline"),
        fixtureServer("beta"),
    };
    try manager.updatePicker(&configured, true);
    try awaitCalls(&manager, "alpha", 1);
    try awaitCalls(&manager, "beta", 1);
    try awaitCalls(&manager, "offline", 1);
    try awaitCalls(&manager, "hidden", 1);
    try testing.expect(manager.isBusy());
    try expectMainIdle(&manager);
    for ([_][]const u8{ "alpha", "beta", "offline", "hidden" }) |id| {
        try testing.expectEqual(servers.State.querying, manager.pickerSnapshot(id).state);
    }
    Fixture.block("alpha", false);
    Fixture.block("beta", false);
    Fixture.block("offline", false);
    Fixture.block("hidden", false);
    try awaitSettled(&manager);
    try expectMainIdle(&manager);
    try expectTarget(manager.pickerSnapshot("alpha"), "alpha", "Original", "127.0.0.1", 25565, "instance");
    const alpha = manager.pickerSnapshot("alpha").status.?;
    const beta = manager.pickerSnapshot("beta").status.?;
    try testing.expectEqual(servers.State.online, manager.pickerSnapshot("beta").state);
    try testing.expectEqual(@as(?u32, 7), alpha.players_online);
    try testing.expectEqual(@as(?u32, 40), alpha.players_max);
    try testing.expectEqual(@as(?u32, 0), beta.players_online);
    try testing.expectEqual(@as(?u32, 12), beta.players_max);
    const offline = manager.pickerSnapshot("offline");
    try testing.expectEqual(servers.State.offline, offline.state);
    try testing.expectEqual(error.ConnectionRefused, offline.failure.?);
    try testing.expect(offline.status == null);
    try testing.expectEqual(@as(u32, 1), Fixture.count("hidden"));
    try expectTarget(manager.pickerSnapshot("hidden"), "hidden", "Original", "127.0.0.1", 25565, "instance");
}

test "picker statuses and main refresh and clear remain independent" {
    Fixture.reset();
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    try manager.refreshConfigured(fixtureServer("selected"));
    try awaitSettled(&manager);
    const configured = [_]config.Server{ fixtureServer("alpha"), fixtureServer("offline") };
    try manager.updatePicker(&configured, true);
    try awaitSettled(&manager);
    try expectTarget(manager.snapshot(), "selected", "Original", "127.0.0.1", 25565, "instance");
    try testing.expectEqual(@as(u32, 1), Fixture.count("selected"));
    var selected = fixtureServer("selected");
    selected.name = "Selected again";
    selected.address = "127.0.0.2";
    selected.port = 25570;
    try manager.refreshConfigured(selected);
    try awaitSettled(&manager);
    try expectTarget(manager.snapshot(), "selected", "Selected again", "127.0.0.2", 25570, "instance");
    manager.clear();
    try expectMainIdle(&manager);
    try expectTarget(manager.pickerSnapshot("alpha"), "alpha", "Original", "127.0.0.1", 25565, "instance");
    try testing.expectEqual(servers.State.offline, manager.pickerSnapshot("offline").state);
    try testing.expectEqual(@as(u32, 1), Fixture.count("alpha"));
    try testing.expectEqual(@as(u32, 1), Fixture.count("offline"));
}

test "picker unchanged page polls again only when due after the previous round settles" {
    Fixture.reset();
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    manager.picker_poll_interval_ms = std.math.maxInt(u32);
    const configured = [_]config.Server{ fixtureServer("alpha"), fixtureServer("beta") };
    try manager.updatePicker(&configured, true);
    try awaitSettled(&manager);
    for (0..3) |_| {
        try manager.updatePicker(&configured, true);
        manager.tick();
    }
    try testing.expectEqual(@as(u32, 1), Fixture.count("alpha"));
    try testing.expectEqual(@as(u32, 1), Fixture.count("beta"));
    manager.picker_poll_interval_ms = 0;
    // Changing the interval does not rewrite the already scheduled deadline.
    try manager.updatePicker(&configured, false);
    try manager.updatePicker(&configured, true);
    for ([_]u32{ 2, 3 }) |round| {
        try manager.updatePicker(&configured, true);
        try awaitSettled(&manager);
        try testing.expectEqual(round, Fixture.count("alpha"));
        try testing.expectEqual(round, Fixture.count("beta"));
    }
    try expectMainIdle(&manager);
}

test "picker busy card is not superseded and leaving cancels before fresh reentry" {
    Fixture.reset();
    Fixture.block("alpha", true);
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    manager.picker_poll_interval_ms = 0;
    const configured = [_]config.Server{ fixtureServer("alpha"), fixtureServer("beta") };
    try manager.updatePicker(&configured, true);
    try awaitCalls(&manager, "alpha", 1);
    // A slow card must not prevent a different card from completing.
    try awaitCardState(&manager, "beta", .online);
    for (0..10) |_| {
        try manager.updatePicker(&configured, true);
        manager.tick();
    }
    try testing.expect(manager.isBusy());
    try testing.expectEqual(@as(u32, 1), Fixture.count("alpha"));
    try testing.expectEqual(@as(u32, 0), Fixture.canceled[try Fixture.index("alpha")].load(.acquire));
    try manager.updatePicker(&configured, false);
    try awaitSettled(&manager);
    try testing.expectEqual(@as(u32, 1), Fixture.canceled[try Fixture.index("alpha")].load(.acquire));
    try testing.expectEqual(@as(u32, 1), Fixture.count("alpha"));
    const beta_rounds = Fixture.count("beta");
    try manager.updatePicker(&configured, false);
    manager.tick();
    try testing.expect(!manager.isBusy());
    try testing.expectEqual(beta_rounds, Fixture.count("beta"));
    Fixture.block("alpha", false);
    try manager.updatePicker(&configured, true);
    try awaitSettled(&manager);
    try testing.expectEqual(@as(u32, 2), Fixture.count("alpha"));
    try testing.expectEqual(beta_rounds + 1, Fixture.count("beta"));
    try testing.expectEqual(servers.State.online, manager.pickerSnapshot("alpha").state);
    try expectMainIdle(&manager);
}

test "picker config edits refresh endpoints and membership by stable server ID" {
    Fixture.reset();
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    manager.picker_poll_interval_ms = std.math.maxInt(u32);
    const initial = [_]config.Server{ fixtureServer("alpha"), fixtureServer("beta"), fixtureServer("hidden") };
    try manager.updatePicker(&initial, true);
    try awaitSettled(&manager);
    try manager.updatePicker(&initial, true);
    try awaitSettled(&manager);
    for ([_][]const u8{ "alpha", "beta", "hidden" }) |id| {
        try testing.expectEqual(@as(u32, 1), Fixture.count(id));
        try expectTarget(manager.pickerSnapshot(id), id, "Original", "127.0.0.1", 25565, "instance");
    }
    var alpha = fixtureServer("alpha");
    alpha.name = "Edited";
    alpha.address = "127.0.0.2";
    alpha.port = 25570;
    alpha.instance_id = "other-instance";
    const edited = [_]config.Server{ fixtureServer("hidden"), fixtureServer("selected"), alpha };
    try manager.updatePicker(&edited, true);
    try awaitSettled(&manager);
    try testing.expectEqual(@as(u32, 2), Fixture.count("alpha"));
    try testing.expectEqual(@as(u32, 1), Fixture.count("beta"));
    // Membership and another endpoint changed; this unchanged card stays cached.
    try testing.expectEqual(@as(u32, 1), Fixture.count("hidden"));
    try testing.expectEqual(@as(u32, 1), Fixture.count("selected"));
    try testing.expectEqual(servers.State.idle, manager.pickerSnapshot("beta").state);
    try expectTarget(manager.pickerSnapshot("alpha"), "alpha", "Edited", "127.0.0.2", 25570, "other-instance");
    try expectTarget(manager.pickerSnapshot("hidden"), "hidden", "Original", "127.0.0.1", 25565, "instance");
    try expectTarget(manager.pickerSnapshot("selected"), "selected", "Original", "127.0.0.1", 25565, "instance");
    try expectMainIdle(&manager);
}

test "picker jobs own mutable config strings on entry and after target edits" {
    Fixture.reset();
    Fixture.block("alpha", true);
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    manager.picker_poll_interval_ms = std.math.maxInt(u32);
    var id = "alpha".*;
    var name = "Original".*;
    var address = "127.0.0.1".*;
    var instance = "instance".*;
    var configured = [_]config.Server{.{ .id = &id, .name = &name, .address = &address, .port = 25566, .instance_id = &instance }};
    try manager.updatePicker(&configured, true);
    try awaitCalls(&manager, "alpha", 1);
    @memset(&id, 'x');
    @memset(&name, 'x');
    @memset(&address, 'x');
    @memset(&instance, 'x');
    Fixture.block("alpha", false);
    try awaitSettled(&manager);
    try expectTarget(manager.pickerSnapshot("alpha"), "alpha", "Original", "127.0.0.1", 25566, "instance");
    id = "alpha".*;
    name = "Modified".*;
    address = "127.0.0.2".*;
    instance = "new-inst".*;
    configured[0].port = 25570;
    Fixture.block("alpha", true);
    try manager.updatePicker(&configured, true);
    try awaitCalls(&manager, "alpha", 2);
    @memset(&id, 'y');
    @memset(&name, 'y');
    @memset(&address, 'y');
    @memset(&instance, 'y');
    Fixture.block("alpha", false);
    try awaitSettled(&manager);
    try expectTarget(manager.pickerSnapshot("alpha"), "alpha", "Modified", "127.0.0.2", 25570, "new-inst");
    try expectMainIdle(&manager);
}

test "picker tick progresses while main query is busy and main clear preserves a busy card" {
    Fixture.reset();
    Fixture.block("selected", true);
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    manager.picker_poll_interval_ms = 0;
    try manager.refreshConfigured(fixtureServer("selected"));
    try awaitCalls(&manager, "selected", 1);
    const configured = [_]config.Server{fixtureServer("alpha")};
    try manager.updatePicker(&configured, true);
    try awaitCardState(&manager, "alpha", .online);
    try testing.expectEqual(servers.State.querying, manager.snapshot().state);
    try testing.expectEqualStrings("selected", manager.snapshot().server.?.id);
    Fixture.block("alpha", true);
    try manager.updatePicker(&configured, true);
    try awaitCalls(&manager, "alpha", 2);
    manager.clear();
    try expectMainIdle(&manager);
    try testing.expectEqual(servers.State.online, manager.pickerSnapshot("alpha").state);
    try testing.expect(manager.pickerSnapshot("alpha").worker_active);
    Fixture.block("alpha", false);
    try awaitSettled(&manager);
    try testing.expectEqual(@as(u32, 0), Fixture.canceled[try Fixture.index("alpha")].load(.acquire));
    try testing.expectEqual(@as(u32, 2), Fixture.count("alpha"));
    try expectTarget(manager.pickerSnapshot("alpha"), "alpha", "Original", "127.0.0.1", 25565, "instance");
    try expectMainIdle(&manager);
}

test "picker invalid configured address fails only its own card without calling the query" {
    for ([_][]const u8{ "example.com:25565", "999.999.999.999" }) |invalid_address| {
        Fixture.reset();
        var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
        defer manager.deinit();
        manager.picker_poll_interval_ms = 0;
        var invalid = fixtureServer("beta");
        invalid.address = invalid_address;
        const expected_failure = error.InvalidAddress;
        const configured = [_]config.Server{ invalid, fixtureServer("alpha") };
        for ([_]u32{ 1, 2 }) |round| {
            try manager.updatePicker(&configured, true);
            try awaitSettled(&manager);
            try expectTarget(manager.pickerSnapshot("alpha"), "alpha", "Original", "127.0.0.1", 25565, "instance");
            try testing.expectEqual(round, Fixture.count("alpha"));
            try testing.expectEqual(@as(u32, 0), Fixture.count("beta"));
            const beta = manager.pickerSnapshot("beta");
            try testing.expectEqual(servers.State.offline, beta.state);
            try testing.expectEqual(expected_failure, beta.failure.?);
            try testing.expect(beta.status == null);
            try testing.expectEqualStrings("beta", beta.server.?.id);
            try testing.expectEqualStrings(invalid_address, beta.server.?.address);
            try expectMainIdle(&manager);
        }
    }
}

test "selected server polling is independent of navigation and repeated frames keep in-flight work" {
    Fixture.reset();
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    const configured = [_]config.Server{ fixtureServer("alpha"), fixtureServer("hidden") };
    const document: config.Document = .{ .servers = &configured, .selected_server = "hidden" };
    Fixture.block("hidden", true);
    try manager.updateSelected(&document, true);
    try awaitCalls(&manager, "hidden", 1);
    for (0..5) |_| try manager.updateSelected(&document, true);
    try testing.expectEqual(servers.State.querying, manager.snapshot().state);
    try testing.expectEqual(@as(u32, 1), Fixture.count("hidden"));
    try testing.expectEqual(@as(u32, 0), Fixture.count("alpha"));
    try testing.expectEqual(@as(u32, 0), Fixture.canceled[try Fixture.index("hidden")].load(.acquire));
    Fixture.block("hidden", false);
    try awaitSettled(&manager);
    try manager.updateSelected(&document, true);
    try expectTarget(manager.snapshot(), "hidden", "Original", "127.0.0.1", 25565, "instance");
    try testing.expectEqual(@as(u32, 1), Fixture.count("hidden"));

    // Picker navigation changes only its other queries, not the selected target.
    for (0..3) |_| {
        try manager.updateSelected(&document, true);
        try manager.updatePicker(&configured, true);
        try awaitSettled(&manager);
        try manager.updatePicker(&configured, false);
        try manager.updateSelected(&document, true);
        try awaitSettled(&manager);
        try expectTarget(manager.snapshot(), "hidden", "Original", "127.0.0.1", 25565, "instance");
        try testing.expectEqual(@as(u32, 1), Fixture.count("hidden"));
    }
}

test "selected worker activity excludes busy and canceled retired picker cards" {
    const GatedQuery = struct {
        var other_started: std.Io.Event = .unset;
        var other_release: std.Io.Event = .unset;

        fn query(a: std.mem.Allocator, io: std.Io, server: config.Server, options: servers.Options) anyerror!servers.OwnedStatus {
            if (std.mem.eql(u8, server.id, "beta")) {
                other_started.set(io);
                other_release.waitUncancelable(io);
            }
            return Fixture.query(a, io, server, options);
        }

        fn finishSelected(manager: *Manager) !void {
            const job = manager.active orelse return error.MissingFixtureWorker;
            const future = if (job.future) |*value| value else return error.MissingFixtureFuture;
            future.await(manager.io);
            manager.tick();
        }
    };
    Fixture.reset();
    GatedQuery.other_started = .unset;
    GatedQuery.other_release = .unset;
    var manager = Manager.initWithQuery(testing.allocator, testing.io, GatedQuery.query);
    defer manager.deinit();
    // Always release the real worker before shutdown, including on assertion failure.
    defer GatedQuery.other_release.set(testing.io);
    manager.picker_poll_interval_ms = std.math.maxInt(u32);
    const configured = [_]config.Server{ fixtureServer("alpha"), fixtureServer("beta") };
    const document: config.Document = .{ .servers = &configured, .selected_server = "alpha" };
    try manager.updateSelected(&document, true);
    try GatedQuery.finishSelected(&manager);
    try manager.updatePicker(&configured, true);
    GatedQuery.other_started.waitUncancelable(testing.io);
    try expectTarget(manager.snapshot(), "alpha", "Original", "127.0.0.1", 25565, "instance");
    try testing.expect(!manager.snapshot().worker_active);
    try testing.expect(!manager.pickerSnapshot("alpha").worker_active);
    try testing.expect(manager.pickerSnapshot("beta").worker_active);
    try testing.expect(manager.isBusy());

    // Selected-only cancellation must preserve both the published result and peer work.
    const settled = manager.snapshot();
    const live_picker = manager.picker orelse return error.MissingFixturePicker;
    try testing.expectEqual(@as(usize, 1), live_picker.entries.items.len);
    const peer_entry = live_picker.entries.items[0];
    const peer_job = peer_entry.active orelse return error.MissingFixtureWorker;
    try testing.expect(!peer_job.cancellation.load(.acquire));
    manager.cancelSelected();
    try testing.expectEqual(settled.state, manager.snapshot().state);
    try testing.expectEqual(settled.status, manager.snapshot().status);
    try testing.expectEqual(settled.failure, manager.snapshot().failure);
    try testing.expect(!manager.snapshot().worker_active);
    try testing.expect(manager.isBusy());
    try testing.expect(live_picker.open);
    try testing.expectEqual(@as(usize, 0), live_picker.retired.items.len);
    try testing.expect(peer_entry.active == peer_job);
    try testing.expect(!peer_job.cancellation.load(.acquire));
    try testing.expect(manager.pickerSnapshot("beta").worker_active);
    try testing.expectEqual(@as(u32, 0), Fixture.canceled[try Fixture.index("beta")].load(.acquire));
    try manager.updatePicker(&configured, true);
    try testing.expectEqual(@as(usize, 1), live_picker.entries.items.len);
    try testing.expect(live_picker.entries.items[0] == peer_entry);
    try testing.expect(peer_entry.active == peer_job);
    try testing.expect(!peer_job.cancellation.load(.acquire));
    try testing.expectEqual(settled.status, manager.snapshot().status);
    try testing.expectEqual(@as(u32, 1), Fixture.count("alpha"));

    // A busy peer must leave the selected server available for its own refresh.
    try manager.refreshConfigured(configured[0]);
    try testing.expect(manager.snapshot().worker_active);
    try GatedQuery.finishSelected(&manager);
    try testing.expectEqual(@as(u32, 2), Fixture.count("alpha"));
    try testing.expect(!manager.snapshot().worker_active);
    try testing.expect(manager.isBusy());

    // Removing the blocked peer cancels and retires its job without joining it.
    try manager.updatePicker(configured[0..1], true);
    const picker = manager.picker orelse return error.MissingFixturePicker;
    try testing.expectEqual(@as(usize, 1), picker.retired.items.len);
    const retired = picker.retired.items[0].active orelse return error.MissingFixtureWorker;
    try testing.expect(retired.cancellation.load(.acquire));
    try testing.expectEqual(servers.State.idle, manager.pickerSnapshot("beta").state);
    try testing.expect(!manager.snapshot().worker_active);
    try testing.expect(manager.isBusy());
    manager.cancel();
    try testing.expect(!manager.snapshot().worker_active);
    try testing.expect(manager.isBusy());
    try expectTarget(manager.snapshot(), "alpha", "Original", "127.0.0.1", 25565, "instance");

    GatedQuery.other_release.set(testing.io);
    const retired_future = if (retired.future) |*value| value else return error.MissingFixtureFuture;
    retired_future.await(testing.io);
    manager.tick();
    try testing.expectEqual(@as(u32, 1), Fixture.count("beta"));
    try testing.expectEqual(@as(u32, 1), Fixture.canceled[try Fixture.index("beta")].load(.acquire));
    try testing.expect(!manager.snapshot().worker_active);
    try testing.expect(!manager.isBusy());
}

test "selected server status is shared with the picker and polls automatically only when due" {
    Fixture.reset();
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    const configured = [_]config.Server{ fixtureServer("alpha"), fixtureServer("beta") };
    const document: config.Document = .{ .servers = &configured, .selected_server = "alpha" };
    try manager.updateSelected(&document, false);
    try expectMainIdle(&manager);
    try manager.updateSelected(&document, true);
    try awaitSettled(&manager);
    try testing.expect(manager.selectedRefreshDelay() > 0);
    for (0..3) |_| {
        try manager.updatePicker(&configured, true);
        try awaitSettled(&manager);
        try expectTarget(manager.pickerSnapshot("alpha"), "alpha", "Original", "127.0.0.1", 25565, "instance");
        try manager.updatePicker(&configured, false);
        try manager.updateSelected(&document, true);
        try testing.expectEqual(@as(u32, 1), Fixture.count("alpha"));
    }

    // Move the deadline to now without relying on a wall-clock sleep.
    manager.selected_next_poll_ms = 0;
    Fixture.block("alpha", true);
    try manager.updateSelected(&document, true);
    try awaitCalls(&manager, "alpha", 2);
    try testing.expectEqual(servers.State.online, manager.snapshot().state);
    try testing.expectEqual(servers.State.online, manager.pickerSnapshot("alpha").state);
    try testing.expect(manager.snapshot().worker_active);
    try testing.expectEqual(@as(u32, 7), manager.snapshot().status.?.players_online.?);
    for (0..3) |_| {
        manager.selected_next_poll_ms = 0;
        try manager.updateSelected(&document, true);
        try manager.updatePicker(&configured, true);
        try manager.updatePicker(&configured, false);
    }
    try testing.expectEqual(@as(u32, 2), Fixture.count("alpha"));
    try testing.expectEqual(@as(u32, 0), Fixture.canceled[try Fixture.index("alpha")].load(.acquire));
    Fixture.block("alpha", false);
    try awaitSettled(&manager);
    try expectTarget(manager.pickerSnapshot("alpha"), "alpha", "Original", "127.0.0.1", 25565, "instance");
    try manager.updateSelected(&document, true);
    try testing.expectEqual(@as(u32, 2), Fixture.count("alpha"));
}

test "selected polling handles target changes and configuration edits without a page transition" {
    Fixture.reset();
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    var configured = [_]config.Server{ fixtureServer("alpha"), fixtureServer("beta") };
    var document: config.Document = .{ .servers = &configured, .selected_server = "alpha" };
    try manager.updateSelected(&document, true);
    try awaitSettled(&manager);
    document.selected_server = "beta";
    try manager.updateSelected(&document, true);
    try awaitSettled(&manager);
    try expectTarget(manager.snapshot(), "beta", "Original", "127.0.0.1", 25565, "instance");
    configured[1].address = "127.0.0.2";
    configured[1].port = 25570;
    try manager.updateSelected(&document, true);
    try awaitSettled(&manager);
    try expectTarget(manager.snapshot(), "beta", "Original", "127.0.0.2", 25570, "instance");
    try testing.expectEqual(@as(u32, 1), Fixture.count("alpha"));
    try testing.expectEqual(@as(u32, 2), Fixture.count("beta"));
    manager.selected_next_poll_ms = 0;
    try manager.updateSelected(&document, false);
    try testing.expectEqual(@as(u32, 2), Fixture.count("beta"));
    document.selected_server = null;
    try manager.updateSelected(&document, true);
    try expectMainIdle(&manager);
    try manager.updatePicker(&configured, true);
    try awaitSettled(&manager);
    try testing.expectEqual(@as(u32, 2), Fixture.count("alpha"));
    try testing.expectEqual(@as(u32, 3), Fixture.count("beta"));
    try expectTarget(manager.pickerSnapshot("beta"), "beta", "Original", "127.0.0.2", 25570, "instance");
}

test "an instance alone does not query and malformed selections fail inside their worker" {
    Fixture.reset();
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    var invalid = fixtureServer("alpha");
    invalid.address = "999.999.999.999";
    const configured = [_]config.Server{invalid};
    var document: config.Document = .{ .servers = &configured };
    try manager.updateSelected(&document, true);
    try expectMainIdle(&manager);
    try testing.expectEqual(@as(u32, 0), Fixture.count("alpha"));
    document.selected_server = "alpha";
    try manager.updateSelected(&document, true);
    try awaitSettled(&manager);
    try testing.expectEqual(servers.State.offline, manager.snapshot().state);
    try testing.expectEqual(error.InvalidAddress, manager.snapshot().failure.?);
    try testing.expectEqualStrings("alpha", manager.snapshot().server.?.id);
    try testing.expectEqual(@as(u32, 0), Fixture.count("alpha"));
}

test "refresh keeps the last result until completion and publishes success or failure directly" {
    const ChangingQuery = struct {
        fn query(a: std.mem.Allocator, io: std.Io, server: config.Server, options: servers.Options) anyerror!servers.OwnedStatus {
            var result = try Fixture.query(a, io, server, options);
            const round = Fixture.count(server.id);
            if (round == 3) {
                result.deinit();
                return error.ConnectionRefused;
            }
            result.players_online = round;
            return result;
        }
    };
    Fixture.reset();
    var manager = Manager.initWithQuery(testing.allocator, testing.io, ChangingQuery.query);
    defer manager.deinit();
    const configured = [_]config.Server{fixtureServer("alpha")};
    const document: config.Document = .{ .servers = &configured, .selected_server = "alpha" };
    Fixture.block("alpha", true);
    try manager.updateSelected(&document, true);
    try awaitCalls(&manager, "alpha", 1);
    try testing.expectEqual(servers.State.querying, manager.snapshot().state);
    try testing.expect(manager.snapshot().status == null);
    Fixture.block("alpha", false);
    try awaitSettled(&manager);
    try testing.expectEqual(@as(?u32, 1), manager.snapshot().status.?.players_online);
    for (2..5) |round| {
        const previous = manager.snapshot();
        manager.selected_next_poll_ms = 0;
        Fixture.block("alpha", true);
        try manager.updateSelected(&document, true);
        try awaitCalls(&manager, "alpha", @intCast(round));
        const refreshing = manager.snapshot();
        try testing.expectEqual(previous.state, refreshing.state);
        try testing.expectEqual(previous.status, refreshing.status);
        try testing.expectEqual(previous.failure, refreshing.failure);
        try testing.expect(refreshing.worker_active);
        try testing.expectEqual(previous.state, manager.pickerSnapshot("alpha").state);
        Fixture.block("alpha", false);
        try awaitSettled(&manager);
        const completed = manager.snapshot();
        try testing.expect(!completed.worker_active);
        if (round == 3) {
            try testing.expectEqual(servers.State.offline, completed.state);
            try testing.expectEqual(error.ConnectionRefused, completed.failure.?);
            try testing.expect(completed.status == null);
        } else {
            try testing.expectEqual(servers.State.online, completed.state);
            try testing.expectEqual(@as(?u32, @intCast(round)), completed.status.?.players_online);
            try testing.expect(completed.failure == null);
        }
    }
}

test "selection promotes cached cards without querying or changing their polling deadlines" {
    Fixture.reset();
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    const configured = [_]config.Server{ fixtureServer("alpha"), fixtureServer("beta"), fixtureServer("offline"), fixtureServer("hidden") };
    try manager.updatePicker(&configured, true);
    try awaitSettled(&manager);
    const picker = manager.picker.?;
    var deadlines: [configured.len]i64 = undefined;
    var statuses: [configured.len]?*const servers.OwnedStatus = undefined;
    for (picker.entries.items, 0..) |entry, i| {
        deadlines[i] = entry.selected_next_poll_ms;
        statuses[i] = entry.snapshot().status;
        try testing.expect(deadlines[i] > @as(i64, @intCast(std.Io.Clock.awake.now(testing.io).toMilliseconds())));
    }
    // Neither the previous selected deadline nor a due aggregate picker timer
    // may force a newly selected card to repeat its already completed first query.
    manager.selected_next_poll_ms = 0;
    for ([_]usize{ 0, 1, 2, 0, 1, 2, 0 }) |i| {
        try manager.selectConfigured(configured[i]);
        const selected = manager.snapshot();
        try testing.expectEqual(statuses[i], selected.status);
        try testing.expectEqual(deadlines[i], manager.selected_next_poll_ms);
        if (i == 2) {
            try testing.expectEqual(servers.State.offline, selected.state);
            try testing.expectEqual(error.ConnectionRefused, selected.failure.?);
        } else try testing.expectEqual(servers.State.online, selected.state);
        const document: config.Document = .{ .servers = &configured, .selected_server = configured[i].id };
        for (0..3) |_| {
            picker.next_poll_ms = 0;
            try manager.updateSelected(&document, true);
            try manager.updatePicker(&configured, true);
            try manager.selectConfigured(configured[i]);
        }
        try testing.expectEqual(statuses[i], manager.snapshot().status);
        try testing.expectEqual(deadlines[i], manager.selected_next_poll_ms);
        for (configured) |server| try testing.expectEqual(@as(u32, 1), Fixture.count(server.id));
    }
    const selected_status = manager.snapshot().status;
    manager.selected_next_poll_ms = 0;
    Fixture.block("alpha", true);
    try manager.updateSelected(&.{ .servers = &configured, .selected_server = "alpha" }, true);
    try awaitCalls(&manager, "alpha", 2);
    try testing.expectEqual(selected_status, manager.snapshot().status);
    try manager.selectConfigured(configured[0]);
    try testing.expectEqual(@as(u32, 2), Fixture.count("alpha"));
    Fixture.block("alpha", false);
    try awaitSettled(&manager);
}

test "selection transfers an in-flight card across owners without cancellation and page leave keeps it running" {
    Fixture.reset();
    Fixture.block("alpha", true);
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    const configured = [_]config.Server{ fixtureServer("alpha"), fixtureServer("beta") };
    try manager.updatePicker(&configured, true);
    try awaitCalls(&manager, "alpha", 1);
    try awaitCardState(&manager, "beta", .online);
    const picker = manager.picker.?;
    const original = picker.entries.items[0].active.?;
    const deadline = picker.entries.items[0].selected_next_poll_ms;
    for ([_]usize{ 0, 0, 1, 0, 1, 0 }) |i| {
        try manager.selectConfigured(configured[i]);
        const document: config.Document = .{ .servers = &configured, .selected_server = configured[i].id };
        try manager.updateSelected(&document, true);
        try manager.updatePicker(&configured, true);
        try testing.expectEqual(@as(u32, 1), Fixture.count("alpha"));
        try testing.expectEqual(@as(u32, 1), Fixture.count("beta"));
        try testing.expect(!original.cancellation.load(.acquire));
        try testing.expect(manager.pickerSnapshot("alpha").worker_active);
        if (i == 0) {
            try testing.expect(manager.active == original);
            try testing.expectEqual(deadline, manager.selected_next_poll_ms);
        }
    }
    try manager.updatePicker(&configured, false);
    try testing.expect(manager.active == original);
    try testing.expect(!original.cancellation.load(.acquire));
    Fixture.block("alpha", false);
    try awaitSettled(&manager);
    try testing.expectEqual(servers.State.online, manager.snapshot().state);
    try testing.expectEqual(@as(u32, 1), Fixture.count("alpha"));
    try testing.expectEqual(@as(u32, 0), Fixture.canceled[try Fixture.index("alpha")].load(.acquire));
}

test "switching selected cards preserves published status and its in-flight refresh together" {
    Fixture.reset();
    var manager = Manager.initWithQuery(testing.allocator, testing.io, Fixture.query);
    defer manager.deinit();
    const configured = [_]config.Server{ fixtureServer("alpha"), fixtureServer("beta") };
    try manager.updateSelected(&.{ .servers = &configured, .selected_server = "alpha" }, true);
    try manager.updatePicker(&configured, true);
    try awaitSettled(&manager);
    const status = manager.snapshot().status.?;
    Fixture.block("alpha", true);
    try manager.refreshConfigured(configured[0]);
    try awaitCalls(&manager, "alpha", 2);
    const original = manager.active.?;
    const deadline = manager.selected_next_poll_ms;
    for ([_]usize{ 1, 0, 1, 0, 0 }) |i| {
        try manager.selectConfigured(configured[i]);
        try manager.updatePicker(&configured, true);
        const alpha = manager.pickerSnapshot("alpha");
        try testing.expectEqual(status, alpha.status.?);
        try testing.expectEqual(servers.State.online, alpha.state);
        try testing.expect(alpha.worker_active);
        try testing.expect(!original.cancellation.load(.acquire));
        if (i == 0) {
            try testing.expect(manager.active == original);
            try testing.expectEqual(deadline, manager.selected_next_poll_ms);
        }
    }
    Fixture.block("alpha", false);
    try awaitSettled(&manager);
    try testing.expectEqual(@as(u32, 2), Fixture.count("alpha"));
    try testing.expectEqual(@as(u32, 1), Fixture.count("beta"));
    try testing.expectEqual(@as(u32, 0), Fixture.canceled[try Fixture.index("alpha")].load(.acquire));
}
