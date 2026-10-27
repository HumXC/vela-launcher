const std = @import("std");
const controller_module = @import("ui/mods_controller.zig");
const content = @import("ui/content_manager.zig");
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const tasks = @import("core/tasks.zig");
const manifest = @import("core/content_manifest.zig");
const transport = @import("core/http_transport.zig");
const state = @import("ui/model.zig");
const first: config.Instance = .{ .id = "first", .name = "First", .minecraft_version = "1.21.4" };
const second: config.Instance = .{ .id = "second", .name = "Second", .minecraft_version = "1.21.4" };
const Lease = struct {
    fn acquire(_: ?*anyopaque, _: []const u8) !void {}
    fn recheck(_: ?*anyopaque, _: []const u8) !void {}
    fn release(_: ?*anyopaque, _: []const u8) void {}
    fn callbacks() @import("core/content_install.zig").Lease {
        return .{ .context = null, .acquire = acquire, .recheck = recheck, .release = release };
    }
};
fn noHttp(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: transport.Request) !transport.Response {
    return error.UnexpectedNetwork;
}
fn drainBackend(service: *content.Manager) !void {
    for (0..5000) |_| {
        service.tick();
        if (!service.isBusy()) return;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestWorkerTimeout;
}
fn drain(controller: *controller_module.Controller, service: *content.Manager) !void {
    for (0..5000) |_| {
        service.tick();
        controller.tick(service);
        if (!controller.busy() and !service.isBusy()) return;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestWorkerTimeout;
}
test "mods controller retires stale inventory and owns selected instance" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".minecraft/versions/First/mods");
    try tmp.dir.createDirPath(io, ".minecraft/versions/Second/mods");
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/First/mods/old.jar", .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Second/mods/new.jar", .data = "new" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var backend = try content.Manager.initOptions(a, io, &paths, &registry, .{ .lease = Lease.callbacks(), .transport_options = .{ .fixture_http = noHttp } });
    defer backend.deinit();
    var controller = controller_module.Controller.init(a, io, &paths);
    defer controller.deinit();
    var name = "First".*;
    var temporary = first;
    temporary.name = &name;
    try controller.select(temporary, .mod, &backend);
    name[0] = 'X';
    try std.testing.expectEqualStrings("First", controller.instance_name.?);
    try drainBackend(&backend);
    // The first worker has not been published by a controller tick.
    try controller.select(second, .mod, &backend);
    try std.testing.expect(controller.published == null);
    try drain(&controller, &backend);
    try std.testing.expect(controller.failure == null);
    try std.testing.expectEqual(@as(usize, 1), controller.published.?.entries.len);
    try std.testing.expectEqualStrings("mods/new.jar", controller.published.?.entries[0].path);
    const entries = controller.published.?.entries.ptr;
    const revision = controller.inventory_revision;
    try controller.toggle(&backend, "mods/new.jar", false);
    try drain(&controller, &backend);
    try std.testing.expect(controller.failure == null);
    try std.testing.expect(entries == controller.published.?.entries.ptr);
    try std.testing.expect(controller.inventory_revision != revision);
    try std.testing.expect(backend.local_job.?.request == .enabled_toggle);
    try std.testing.expectEqualStrings("mods/new.jar.disabled", controller.published.?.entries[0].path);
    try std.testing.expect(!controller.published.?.entries[0].enabled);
}
test "mods controller commits disabled managed jar then reenables physical path" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".minecraft/versions/First/mods");
    try tmp.dir.createDirPath(io, ".vela/instances/first");
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/First/mods/state.jar", .data = "old" });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("old", &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const record: manifest.ManagedFile = .{ .path = "mods/state.jar", .provider = .modrinth, .project_id = "fixture", .version_id = "1", .hashes = .{ .sha256 = &hash }, .size = 3, .identity_provenance = .pack_archive, .standalone = false };
    const receipt = try manifest.serialize(a, .{ .schema_version = manifest.schema_version, .instance_id = "first", .pack_version = "1", .files = &.{record}, .pack_membership = .{ .identity = .{ .provider = .modrinth, .project_id = "fixture", .version_id = "1" }, .paths = &.{record.path} } });
    defer a.free(receipt);
    try tmp.dir.writeFile(io, .{ .sub_path = ".vela/instances/first/content.json", .data = receipt });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var backend = try content.Manager.initOptions(a, io, &paths, &registry, .{ .lease = Lease.callbacks(), .transport_options = .{ .fixture_http = noHttp } });
    defer backend.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{});
    var controller = controller_module.Controller.init(failing.allocator(), io, &paths);
    defer controller.deinit();
    try controller.select(first, .mod, &backend);
    try drain(&controller, &backend);
    try std.testing.expect(controller.failure == null);
    const entries = controller.published.?.entries.ptr;
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/First/mods/unrelated.jar", .data = "unparsed unrelated bytes" });
    try controller.toggle(&backend, "mods/state.jar", false);
    try drain(&controller, &backend);
    try std.testing.expect(controller.failure == null);
    try std.testing.expectEqualStrings("mods/state.jar.disabled", controller.published.?.entries[0].path);
    try std.testing.expect(entries == controller.published.?.entries.ptr);
    try std.testing.expectEqual(@as(usize, 1), controller.published.?.entries.len);
    const disabled = try controller.viewSnapshot(&backend, true);
    try std.testing.expect(disabled.rows[0].managed);
    try std.testing.expectEqual(controller.inventory_revision, disabled.inventory.?.revision);
    try std.testing.expectEqual(@intFromPtr(&controller), disabled.inventory.?.source);
    try std.testing.checkAllAllocationFailures(a, snapshotAllocationFixture, .{ &controller, &backend });
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    for (0..100) |_| {
        const cached = try controller.viewSnapshot(&backend, false);
        try std.testing.expect(cached.rows.ptr == disabled.rows.ptr);
        try std.testing.expect(!cached.can_mutate);
    }
    try std.testing.expectEqual(allocations, failing.alloc_index);
    failing.fail_index = std.math.maxInt(usize);
    const installed_revision = backend.snapshot().installed_revision;
    try controller.toggle(&backend, "mods/state.jar.disabled", true);
    try drain(&controller, &backend);
    try std.testing.expect(controller.failure == null);
    try std.testing.expectEqualStrings("mods/state.jar", controller.published.?.entries[0].path);
    try std.testing.expect(backend.snapshot().installed_revision != installed_revision);
    // Failed rebuilding clears borrowed rows; retry must reconstruct current state.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, controller.viewSnapshot(&backend, true));
    try std.testing.expectEqual(@as(usize, 0), controller.view_rows.len);
    failing.fail_index = std.math.maxInt(usize);
    const enabled = try controller.viewSnapshot(&backend, true);
    try std.testing.expect(enabled.rows[0].managed and enabled.rows[0].entry.enabled);
    // Only the backend changes here: local entry pointers/revision are unchanged.
    try backend.select(null);
    const detached = try controller.viewSnapshot(&backend, true);
    try std.testing.expect(!detached.rows[0].managed and !detached.can_mutate);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/First/mods/state.jar.disabled", .{}));
    const bytes = try tmp.dir.readFileAlloc(io, ".minecraft/versions/First/mods/state.jar", a, .limited(64));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("old", bytes);
}
test "mods route preserves more and instance entry parents through owned selection" {
    for ([_]state.Panel{ .more, .instances }) |parent| {
        var model: state.Model = .{ .panel = parent, .category = .game };
        try std.testing.expect(model.mods_instance.set("first"));
        state.transition(&model, .open_mods);
        try std.testing.expectEqual(state.Panel.mods, model.panel);
        try std.testing.expectEqualStrings(if (parent == .more) "返回更多" else "返回实例管理", model.parentLabel());
        state.transition(&model, .utility_back);
        try std.testing.expectEqual(parent, model.panel);
        try std.testing.expectEqual(state.Category.game, model.category);
        try std.testing.expectEqualStrings("first", model.mods_instance.get());
    }
}

fn snapshotAllocationFixture(allocator: std.mem.Allocator, source: *controller_module.Controller, backend: *content.Manager) !void {
    var controller = controller_module.Controller.init(allocator, source.io, source.paths);
    defer controller.deinit();
    controller.instance_id = try allocator.dupe(u8, source.instance_id.?);
    // The fixture borrows immutable entries; its empty arena owns no source data.
    controller.published = .{ .arena = std.heap.ArenaAllocator.init(allocator), .entries = source.published.?.entries };
    const snapshot = try controller.viewSnapshot(backend, true);
    try std.testing.expectEqual(source.published.?.entries.len, snapshot.rows.len);
    try std.testing.expect(snapshot.rows[0].managed);
}
