const std = @import("std");
const builtin = @import("builtin");
const instance_preparation = @import("application/instance_preparation.zig");
const metadata_loader = @import("core/minecraft/metadata_loader.zig");
const game_metadata = @import("core/minecraft/metadata/root.zig");
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const tasks = @import("core/tasks.zig");
const install = @import("core/content_install.zig");
const providers = @import("core/content_providers.zig");
const manifest = @import("core/content_manifest.zig");
const http = @import("core/http_transport.zig");
const credentials = @import("core/credentials.zig");
const manager = @import("application/content_manager.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const selected: config.Instance = .{ .id = "stable-id", .name = "Display Name", .minecraft_version = "1.20.1" };
const LeaseState = struct {
    held: bool = false,
    held_id: ?[]const u8 = null,
    allow_other: bool = false,
    blocked: bool = false,
    acquired: usize = 0,
    released: usize = 0,
    rechecked: std.atomic.Value(usize) = .init(0),
    fn acquire(context: ?*anyopaque, id: []const u8) anyerror!void {
        const self: *LeaseState = @ptrCast(@alignCast(context.?));
        if (!std.mem.eql(u8, id, "stable-id") and !(self.allow_other and std.mem.eql(u8, id, "other-id"))) return error.WrongStableId;
        if (self.blocked) return error.InstanceRunning;
        if (self.held) return error.DoubleAcquire;
        self.held = true;
        self.held_id = id;
        self.acquired += 1;
    }
    fn recheck(context: ?*anyopaque, id: []const u8) anyerror!void {
        const self: *LeaseState = @ptrCast(@alignCast(context.?));
        if (!self.held or !std.mem.eql(u8, id, self.held_id orelse return error.LeaseNotHeld)) return error.LeaseNotHeld;
        _ = self.rechecked.fetchAdd(1, .monotonic);
    }
    fn release(context: ?*anyopaque, _: []const u8) void {
        const self: *LeaseState = @ptrCast(@alignCast(context.?));
        std.debug.assert(self.held);
        self.held = false;
        self.held_id = null;
        self.released += 1;
    }
    fn lease(self: *LeaseState) install.Lease {
        return .{ .context = self, .acquire = acquire, .recheck = recheck, .release = release };
    }
};
fn drain(service: *manager.Manager) !void {
    var remaining: usize = 10000;
    while (service.isBusy()) {
        service.tick();
        if (remaining == 0) return error.WorkerDidNotFinish;
        remaining -= 1;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}
test "content manager requires stable real lease and retains owned selection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease() });
    defer service.deinit();
    try std.testing.expectError(error.InvalidConnections, service.setDownloadConnections(0));
    try service.setDownloadConnections(64);
    try std.testing.expectError(error.InvalidConnections, service.setDownloadConnections(65));
    var owned_name = try a.dupe(u8, selected.name);
    var instance = selected;
    instance.name = owned_name;
    try service.select(instance);
    owned_name[0] = 'X';
    a.free(owned_name);
    try std.testing.expect(leases.held);
    try std.testing.expect(registry.hasActive());
    try drain(&service);
    try std.testing.expectEqualStrings(selected.name, service.snapshot().instance.?.name);
    try std.testing.expect(service.snapshot().failure == null);
    try std.testing.expectEqual(@as(usize, 1), leases.acquired);
    try std.testing.expectEqual(leases.acquired, leases.released);
    try std.testing.expect(!registry.hasActive());
    leases.blocked = true;
    try std.testing.expectError(error.InstanceRunning, service.refresh());
    try std.testing.expect(!service.isBusy());
}

fn versionFixture(allocator: std.mem.Allocator, provider: config.SourceKind, project: []const u8, id: []const u8, filename: []const u8, bytes: []const u8) !providers.Owned(providers.Version) {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const g = arena.allocator();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const files = try g.alloc(providers.File, 1);
    files[0] = .{ .filename = try g.dupe(u8, filename), .hashes = .{ .sha256 = try g.dupe(u8, &hash) }, .size = bytes.len, .primary = true, .download = .{ .manual_required = .{ .official_page = "https://www.curseforge.com/minecraft/mc-mods/example/files/2", .reason = .provider_disabled } } };
    const value: providers.Version = .{ .provider = provider, .project_id = try g.dupe(u8, project), .id = try g.dupe(u8, id), .name = "Fixture", .minecraft_versions = &.{"1.20.1"}, .loaders = &.{"minecraft"}, .files = files, .dependencies = &.{} };
    return .{ .arena = arena, .value = value };
}
test "content manager manual hash validation commit backups conflict keep and removal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".minecraft/versions/Display Name");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease() });
    defer service.deinit();
    try service.select(selected);
    try drain(&service);
    var version = try versionFixture(a, .modrinth, "1", "2", "sample.jar", "payload");
    defer version.deinit();
    try service.prepareVersion(version.value, .mod, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    const missing = service.snapshot().proposal.?;
    try std.testing.expectEqual(@as(usize, 1), missing.missing_manual);
    const missing_status = manualStatus(missing, "mods/sample.jar").?;
    try std.testing.expect(!missing_status.verified and missing_status.source_absolute_path == null);
    try std.testing.expect(!missing.ready);
    try std.testing.expectError(error.IncompleteContent, service.commit());
    try tmp.dir.writeFile(io, .{ .sub_path = "supplied.jar", .data = "wrong" });
    const supplied = try std.fs.path.join(a, &.{ root, "supplied.jar" });
    defer a.free(supplied);
    const mapping: install.ManualFile = .{ .path = "mods/sample.jar", .source_absolute_path = supplied };
    try service.resolve(&.{}, &.{}, &.{mapping}, &.{});
    try drain(&service);
    try std.testing.expectEqual(error.SizeMismatch, service.snapshot().failure.?);
    try std.testing.expect(service.snapshot().proposal.? == missing);
    try std.testing.expect(!manualStatus(service.snapshot().proposal.?, "mods/sample.jar").?.verified);
    try tmp.dir.writeFile(io, .{ .sub_path = "supplied.jar", .data = "payload" });
    try service.resolve(&.{}, &.{}, &.{mapping}, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().proposal.?.ready);
    const checked_status = manualStatus(service.snapshot().proposal.?, "mods/sample.jar").?;
    try std.testing.expect(checked_status.verified);
    try std.testing.expectEqualStrings(supplied, checked_status.source_absolute_path.?);
    const acquired = leases.acquired;
    try service.commit();
    try std.testing.expect(leases.held and registry.hasActive());
    try drain(&service);
    try std.testing.expectEqual(@as(usize, acquired + 2), leases.acquired);
    try std.testing.expectEqual(leases.acquired, leases.released);
    try std.testing.expect(service.snapshot().failure == null);
    try std.testing.expect(service.snapshot().report.?.committed);
    try std.testing.expectEqual(@as(usize, 1), service.snapshot().installed.len);
    // Full transaction history retains committed backups without requiring recovery.
    try std.testing.expectEqual(@as(usize, 1), service.snapshot().transactions.len);
    try std.testing.expect(!service.snapshot().recovery_required);
    const actual = try tmp.dir.readFileAlloc(io, ".minecraft/versions/Display Name/mods/sample.jar", a, .limited(1024));
    defer a.free(actual);
    try std.testing.expectEqualStrings("payload", actual);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Display Name/mods/sample.jar", .data = "local edit" });
    try service.prepareRemove("mods/sample.jar");
    try drain(&service);
    try std.testing.expect(!service.snapshot().proposal.?.ready);
    try std.testing.expectEqual(@as(usize, 1), service.snapshot().proposal.?.plan.conflicts.len);
    try service.resolve(&.{}, &.{.{ .path = "mods/sample.jar", .choice = .keep_local }}, &.{}, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().proposal.?.ready);
    try std.testing.expect(!service.snapshot().proposal.?.plan.fully_applied);
    try service.commit();
    try drain(&service);
    try std.testing.expect(!service.snapshot().report.?.fully_applied);
    try std.testing.expectEqual(@as(usize, 1), service.snapshot().installed.len);
    try service.prepareRemove("mods/sample.jar");
    try drain(&service);
    try service.resolve(&.{}, &.{.{ .path = "mods/sample.jar", .choice = .replace }}, &.{}, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().proposal.?.ready);
    const review = service.snapshot().proposal.?;
    try std.testing.expectEqual(manifest.ActionKind.backup, review.plan.actions[0].kind);
    try std.testing.expectEqual(manifest.ActionKind.remove, review.plan.actions[1].kind);
    try service.commit();
    try drain(&service);
    try std.testing.expectEqual(@as(usize, 0), service.snapshot().installed.len);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/Display Name/mods/sample.jar", .{}));
    const backup = try std.fs.path.join(a, &.{ service.snapshot().report.?.backup_directory, "before-0" });
    defer a.free(backup);
    const backup_bytes = try std.Io.Dir.cwd().readFileAlloc(io, backup, a, .limited(1024));
    defer a.free(backup_bytes);
    try std.testing.expectEqualStrings("local edit", backup_bytes);
}
const HttpFixture = struct {
    status: u16 = 200,
    body: []const u8,
    url_buffer: [8192]u8 = undefined,
    url_len: usize = 0,
    entered: std.atomic.Value(bool) = .init(false),
    wait_for_cancel: bool = false,
    fn execute(context: ?*anyopaque, allocator: std.mem.Allocator, worker_io: std.Io, request: http.Request) !http.Response {
        const self: *HttpFixture = @ptrCast(@alignCast(context.?));
        try std.testing.expect(request.require_public_address and !request.follow_redirects);
        if (request.url.len > self.url_buffer.len) return error.UrlTooLong;
        @memcpy(self.url_buffer[0..request.url.len], request.url);
        self.url_len = request.url.len;
        self.entered.store(true, .release);
        if (self.wait_for_cancel) {
            while (!request.cancel.?.load(.acquire)) try worker_io.sleep(.fromMilliseconds(1), .awake);
            return error.Canceled;
        }
        const body = try allocator.dupe(u8, self.body);
        return .{ .allocator = allocator, .status = self.status, .body = body, .allocation = body };
    }
};
const catalog_fixture =
    \\{"hits":[{"project_id":"project","project_type":"shader","title":"Shader","description":"Fixture"}],"total_hits":1}
;
test "content manager real Modrinth request retained failure and worker cancellation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var fixture: HttpFixture = .{ .body = catalog_fixture };
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .transport_options = .{ .fixture_http = HttpFixture.execute, .fixture_context = &fixture } });
    defer service.deinit();
    try service.select(selected);
    try drain(&service);
    try service.search("a & b", .shader, 40);
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    try std.testing.expectEqualStrings("Shader", service.snapshot().catalog[0].name);
    const catalog_ptr = service.snapshot().catalog.ptr;
    const url = fixture.url_buffer[0..fixture.url_len];
    try std.testing.expect(std.mem.indexOf(u8, url, "a%20%26%20b") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "project_type%3Ashader") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "categories%3A") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "offset=40") != null);
    fixture.status = 429;
    try service.search("retry", .shader, 0);
    try drain(&service);
    try std.testing.expectEqual(error.RateLimited, service.snapshot().failure.?);
    try std.testing.expect(service.snapshot().catalog.ptr == catalog_ptr);
    fixture.status = 200;
    fixture.wait_for_cancel = true;
    fixture.entered.store(false, .release);
    try service.search("cancel", .mod, 0);
    while (!fixture.entered.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    service.cancel();
    try std.testing.expect(service.isBusy() and registry.hasActive());
    try drain(&service);
    try std.testing.expectEqual(error.Canceled, service.snapshot().failure.?);
    try std.testing.expect(service.snapshot().catalog.ptr == catalog_ptr);
    try std.testing.expect(!registry.hasActive());
}
fn selectionAllocations(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(allocator);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var fixture: HttpFixture = .{ .body = catalog_fixture };
    var service = try manager.Manager.initOptions(allocator, io, &paths, &registry, .{ .lease = leases.lease(), .transport_options = .{ .fixture_http = HttpFixture.execute, .fixture_context = &fixture } });
    defer service.deinit();
    try service.select(selected);
    try drain(&service);
    if (service.snapshot().failure) |failure| return failure;
    try service.search("owned query", .mod, 0);
    service.cancel();
    try drain(&service);
    if (service.snapshot().failure) |failure| if (failure == error.OutOfMemory) return error.OutOfMemory;
}
test "content manager selection request registry allocation failures clean up" {
    try @import("test_allocations").checkAllAllocationFailures(a, selectionAllocations, .{});
}

const CrashFixture = struct {
    interrupt: bool = true,
    fn boundary(context: ?*anyopaque, point: install.FaultPoint, _: usize) !void {
        const self: *CrashFixture = @ptrCast(@alignCast(context.?));
        if (!self.interrupt) return;
        if (point == .after_mutation) return error.FixtureInterrupted;
        if (point == .rollback_mutation) return error.FixtureRollbackFailure;
    }
};
fn readyManual(service: *manager.Manager, version: providers.Version, supplied: []const u8) !void {
    try service.prepareVersion(version, .mod, &.{});
    try drain(service);
    try service.resolve(&.{}, &.{}, &.{.{ .path = "mods/sample.jar", .source_absolute_path = supplied }}, &.{});
    try drain(service);
    try std.testing.expect(service.snapshot().proposal.?.ready);
}
test "content manager crash pin survives selection cancel failed repair and restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".minecraft/versions/Display Name");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var crash: CrashFixture = .{};
    const options: manager.Options = .{ .lease = leases.lease(), .fixture_fault = .{ .context = &crash, .boundary = CrashFixture.boundary } };
    var version = try versionFixture(a, .modrinth, "1", "2", "sample.jar", "payload");
    defer version.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "supplied.jar", .data = "payload" });
    const supplied = try std.fs.path.join(a, &.{ root, "supplied.jar" });
    defer a.free(supplied);
    {
        var service = try manager.Manager.initOptions(a, io, &paths, &registry, options);
        defer service.deinit();
        try service.select(selected);
        try drain(&service);
        try readyManual(&service, version.value, supplied);
        const released = leases.released;
        try service.commit();
        try drain(&service);
        try std.testing.expectEqual(error.RecoveryRequired, service.snapshot().failure.?);
        try std.testing.expect(service.snapshot().recovery_required and leases.held);
        try std.testing.expectEqual(released, leases.released);
        try std.testing.expect(!registry.hasActive());
        try std.testing.expectEqual(@as(usize, 1), service.snapshot().transactions.len);
        const transaction = try a.dupe(u8, service.snapshot().transactions[0]);
        defer a.free(transaction);
        try std.testing.expectError(error.RecoveryRequired, service.select(null));
        try std.testing.expectError(error.RecoveryRequired, service.select(.{ .id = "other", .name = "Other", .minecraft_version = "1.20.1" }));
        try std.testing.expectError(error.RecoveryRequired, service.refresh());
        service.cancel();
        try std.testing.expect(service.snapshot().recovery_required and leases.held);
        try std.testing.expectEqualStrings(selected.id, service.snapshot().instance.?.id);
        const acquired = leases.acquired;
        try service.recover("txn-00000000000000000000000000000000");
        try drain(&service);
        try std.testing.expect(service.snapshot().recovery_required and leases.held);
        try std.testing.expectEqual(acquired, leases.acquired);
        try std.testing.expectEqual(released, leases.released);
        try service.recover(transaction);
        try drain(&service);
        try std.testing.expect(service.snapshot().recovery_required and leases.held);
        try std.testing.expectEqual(released, leases.released);
        crash.interrupt = false;
        try service.recover(transaction);
        try drain(&service);
        try std.testing.expect(service.snapshot().failure == null);
        try std.testing.expect(!service.snapshot().recovery_required and !leases.held);
        try std.testing.expect(service.snapshot().report.?.recovered);
        try std.testing.expect(!service.snapshot().report.?.committed);
        try std.testing.expectEqual(@as(usize, 0), service.snapshot().installed.len);
        // An actual second interrupted transaction is left for a fresh manager.
        crash.interrupt = true;
        try readyManual(&service, version.value, supplied);
        try service.commit();
        try drain(&service);
        try std.testing.expect(service.snapshot().recovery_required and leases.held);
    }
    try std.testing.expect(!leases.held);
    crash.interrupt = false;
    var restarted = try manager.Manager.initOptions(a, io, &paths, &registry, options);
    defer restarted.deinit();
    try restarted.select(selected);
    try drain(&restarted);
    try std.testing.expectEqual(error.RecoveryRequired, restarted.snapshot().failure.?);
    try std.testing.expect(restarted.snapshot().recovery_required and leases.held);
    try std.testing.expectEqual(@as(usize, 1), restarted.snapshot().transactions.len);
    try restarted.recover(restarted.snapshot().transactions[0]);
    try drain(&restarted);
    try std.testing.expect(!restarted.snapshot().recovery_required and !leases.held);
    try std.testing.expect(restarted.snapshot().report.?.recovered);
}

fn manualStatus(proposal: *const manager.Proposal, path: []const u8) ?manager.ManualSourceStatus {
    for (proposal.manual_source_status) |status| if (std.mem.eql(u8, status.path, path)) return status;
    return null;
}

const ZipEntry = struct { path: []const u8, bytes: []const u8 };
fn zipNumber(comptime T: type, bytes: *std.ArrayList(u8), value: T) !void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    try bytes.appendSlice(a, &encoded);
}
fn storedZip(dir: std.Io.Dir, name: []const u8, entries: []const ZipEntry) !void {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    const offsets = try a.alloc(u32, entries.len);
    defer a.free(offsets);
    for (entries, offsets) |entry, *offset| {
        offset.* = @intCast(bytes.items.len);
        try zipNumber(u32, &bytes, 0x04034b50);
        for ([_]u16{ 20, 0, 0, 0, 0 }) |value| try zipNumber(u16, &bytes, value);
        try zipNumber(u32, &bytes, std.hash.Crc32.hash(entry.bytes));
        for (0..2) |_| try zipNumber(u32, &bytes, @intCast(entry.bytes.len));
        try zipNumber(u16, &bytes, @intCast(entry.path.len));
        try zipNumber(u16, &bytes, 0);
        try bytes.appendSlice(a, entry.path);
        try bytes.appendSlice(a, entry.bytes);
    }
    const central: u32 = @intCast(bytes.items.len);
    for (entries, offsets) |entry, offset| {
        try zipNumber(u32, &bytes, 0x02014b50);
        for ([_]u16{ 20, 20, 0, 0, 0, 0 }) |value| try zipNumber(u16, &bytes, value);
        try zipNumber(u32, &bytes, std.hash.Crc32.hash(entry.bytes));
        for (0..2) |_| try zipNumber(u32, &bytes, @intCast(entry.bytes.len));
        try zipNumber(u16, &bytes, @intCast(entry.path.len));
        for (0..4) |_| try zipNumber(u16, &bytes, 0);
        try zipNumber(u32, &bytes, 0);
        try zipNumber(u32, &bytes, offset);
        try bytes.appendSlice(a, entry.path);
    }
    const central_size: u32 = @intCast(bytes.items.len - central);
    try zipNumber(u32, &bytes, 0x06054b50);
    for (0..2) |_| try zipNumber(u16, &bytes, 0);
    for (0..2) |_| try zipNumber(u16, &bytes, @intCast(entries.len));
    try zipNumber(u32, &bytes, central_size);
    try zipNumber(u32, &bytes, central);
    try zipNumber(u16, &bytes, 0);
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes.items });
}
fn sha1(bytes: []const u8) [40]u8 {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(&digest, .lower);
}
fn sha256(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(&digest, .lower);
}
fn writeGameReceipt(dir: std.Io.Dir, descriptor: []const u8, client: []const u8, minecraft_version: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(a, .{
        .schema_version = 1,
        .instance_id = selected.id,
        .instance_name = selected.name,
        .minecraft_version = minecraft_version,
        .loader = "vanilla",
        .loader_version = @as(?[]const u8, null),
        .metadata_sha256 = &sha256(descriptor),
        .client_sha256 = &sha256(client),
        .client_size = client.len,
    }, .{});
    defer a.free(json);
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Display Name/.vela-instance.json", .data = json });
}
test "content manager real archive game receipt dependencies asset tamper and complete override commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease() });
    defer service.deinit();
    const client = "client";
    const library = "library";
    const logging = "logging";
    const asset = "asset";
    const asset_hash = sha1(asset);
    const asset_name = try std.fmt.allocPrint(a, ".minecraft/assets/objects/{s}/{s}", .{ asset_hash[0..2], &asset_hash });
    defer a.free(asset_name);
    const asset_directory = std.fs.path.dirname(asset_name).?;
    try tmp.dir.createDirPath(io, asset_directory);
    try tmp.dir.writeFile(io, .{ .sub_path = asset_name, .data = asset });
    const index = try std.fmt.allocPrint(a, "{{\"objects\":{{\"fixture/icon.png\":{{\"hash\":\"{s}\",\"size\":{d}}}}}}}", .{ &asset_hash, asset.len });
    defer a.free(index);
    try tmp.dir.createDirPath(io, ".minecraft/assets/indexes");
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/assets/indexes/fixture.json", .data = index });
    const descriptor = try std.json.Stringify.valueAlloc(a, .{
        .id = selected.name,
        .mainClass = "net.minecraft.client.main.Main",
        .arguments = .{ .game = [_][]const u8{}, .jvm = [_][]const u8{} },
        .downloads = .{ .client = .{ .url = "https://piston-data.mojang.com/client.jar", .sha1 = &sha1(client), .size = client.len } },
        .assetIndex = .{ .id = "fixture", .url = "https://piston-meta.mojang.com/index.json", .sha1 = &sha1(index), .size = index.len },
        .logging = .{ .client = .{ .argument = "-Dlog4j.configurationFile=${path}", .type = "log4j2-xml", .file = .{ .id = "fixture.xml", .url = "https://launcher.mojang.com/fixture.xml", .sha1 = &sha1(logging), .size = logging.len } } },
        .libraries = [_]struct { name: []const u8, downloads: struct { artifact: struct { path: []const u8, url: []const u8, sha1: []const u8, size: u64 } } }{.{
            .name = "fixture:runtime:1",
            .downloads = .{ .artifact = .{
                .path = "fixture/runtime/1/runtime-1.jar",
                .url = "https://libraries.minecraft.net/fixture/runtime/1/runtime-1.jar",
                .sha1 = &sha1(library),
                .size = library.len,
            } },
        }},
    }, .{});
    defer a.free(descriptor);
    try tmp.dir.createDirPath(io, ".minecraft/versions/Display Name/config");
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Display Name/Display Name.json", .data = descriptor });
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Display Name/Display Name.jar", .data = client });
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Display Name/config/local.cfg", .data = "local settings" });
    try writeGameReceipt(tmp.dir, descriptor, client, selected.minecraft_version);
    const pack_index = "{\"formatVersion\":1,\"game\":\"minecraft\",\"versionId\":\"v1\",\"name\":\"Fixture Pack\",\"files\":[],\"dependencies\":{\"minecraft\":\"1.20.1\"}}";
    try storedZip(tmp.dir, "fixture.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = pack_index }, .{ .path = "overrides/config/pack.cfg", .bytes = "pack settings" } });
    const archive_path = try std.fs.path.join(a, &.{ root, "fixture.mrpack" });
    defer a.free(archive_path);
    const identity: manifest.PackIdentity = .{ .provider = .modrinth, .project_id = "fixture-pack", .version_id = "v1" };
    try service.select(selected);
    try drain(&service);
    try service.importPackFor(archive_path, identity);
    try drain(&service);
    _ = try expectProposal(&service);
    try std.testing.expect(!service.snapshot().proposal.?.ready);
    try std.testing.expectEqual(error.MissingGamePrerequisite, service.snapshot().proposal.?.blocker.?);
    const staged = service.snapshot().proposal.?;
    const staged_status = manualStatus(staged, "config/pack.cfg").?;
    try std.testing.expectEqual(@as(usize, 0), staged.missing_manual);
    try std.testing.expect(staged_status.verified);
    try std.testing.expectEqual(manifest.IdentityProvenance.pack_override, staged.files[0].record.identity_provenance);
    try std.testing.expectEqualStrings(staged.manual_files[0].source_absolute_path, staged_status.source_absolute_path.?);
    try tmp.dir.createDirPath(io, ".minecraft/libraries/fixture/runtime/1");
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/libraries/fixture/runtime/1/runtime-1.jar", .data = library });
    try service.resolve(&.{}, &.{}, &.{}, &.{});
    try drain(&service);
    try std.testing.expect(!service.snapshot().proposal.?.ready);
    try std.testing.expectEqual(error.MissingGamePrerequisite, service.snapshot().proposal.?.blocker.?);
    try tmp.dir.createDirPath(io, ".minecraft/assets/log_configs");
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/assets/log_configs/fixture.xml", .data = logging });
    try service.resolve(&.{}, &.{}, &.{}, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().proposal.?.ready);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/assets/log_configs/fixture.xml", .data = "wronggg" });
    try service.commit();
    try drain(&service);
    try std.testing.expectEqual(error.HashMismatch, service.snapshot().failure.?);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/assets/log_configs/fixture.xml", .data = logging });
    const bad_index = try a.dupe(u8, index);
    defer a.free(bad_index);
    bad_index[0] = '[';
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/assets/indexes/fixture.json", .data = bad_index });
    try service.commit();
    try drain(&service);
    try std.testing.expectEqual(error.HashMismatch, service.snapshot().failure.?);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/assets/indexes/fixture.json", .data = index });
    try tmp.dir.writeFile(io, .{ .sub_path = asset_name, .data = "wrong" });
    try service.commit();
    try drain(&service);
    try std.testing.expectEqual(error.HashMismatch, service.snapshot().failure.?);
    try std.testing.expect(service.snapshot().report == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, ".minecraft/versions/Display Name/config/pack.cfg", .{}));
    try tmp.dir.writeFile(io, .{ .sub_path = asset_name, .data = asset });
    try service.commit();
    try drain(&service);
    const report = service.snapshot().report.?;
    try std.testing.expect(report.committed and report.complete and report.fully_applied);
    const file = try tmp.dir.openFile(io, ".minecraft/versions/Display Name/config/pack.cfg", .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const payload = try reader.interface.allocRemaining(a, .limited(128));
    defer a.free(payload);
    try std.testing.expectEqualStrings("pack settings", payload);
    const local = try tmp.dir.openFile(io, ".minecraft/versions/Display Name/config/local.cfg", .{});
    defer local.close(io);
    var local_reader = local.reader(io, &.{});
    const local_payload = try local_reader.interface.allocRemaining(a, .limited(128));
    defer a.free(local_payload);
    try std.testing.expectEqualStrings("local settings", local_payload);
    try writeGameReceipt(tmp.dir, descriptor, client, "1.19.4");
    try service.importPackFor(archive_path, identity);
    try drain(&service);
    try std.testing.expect(!service.snapshot().proposal.?.ready);
    try std.testing.expectEqual(error.InstalledGameIdentityMismatch, service.snapshot().proposal.?.blocker.?);
    try std.testing.expectError(error.IncompleteContent, service.commit());
    try std.testing.expect(!leases.held);
    const discarded = try a.dupe(u8, try expectStage(&service));
    defer a.free(discarded);
    try service.select(null);
    try service.select(selected);
    try drain(&service);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, discarded, .{ .follow_symlinks = false }));
    try writeGameReceipt(tmp.dir, descriptor, client, selected.minecraft_version);
    var shutdown_stage: ?[]u8 = null;
    defer if (shutdown_stage) |path| a.free(path);
    {
        var secondary = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease() });
        defer secondary.deinit();
        try secondary.select(selected);
        try drain(&secondary);
        try secondary.importPackFor(archive_path, identity);
        try drain(&secondary);
        try std.testing.expect((try expectProposal(&secondary)).ready);
        shutdown_stage = try a.dupe(u8, try expectStage(&secondary));
    }
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, shutdown_stage.?, .{ .follow_symlinks = false }));
    try std.testing.expect(!leases.held);
}

const FixtureArtifact = struct { path: []const u8, url: []const u8, sha1: ?[]const u8 = null, size: u64 };
const FixtureLibrary = struct { name: []const u8, downloads: struct { artifact: FixtureArtifact } };
const FixtureBinding = struct { path: []const u8, sha256: []const u8, size: u64 };
fn fixtureDescriptor(gpa: std.mem.Allocator, instance: config.Instance, client: []const u8, index: []const u8, libraries: []const FixtureLibrary) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .id = instance.name,
        .mainClass = if (instance.loader == .vanilla) "net.minecraft.client.main.Main" else "net.fabricmc.loader.impl.launch.knot.KnotClient",
        .arguments = .{ .game = [_][]const u8{}, .jvm = [_][]const u8{} },
        .downloads = .{ .client = .{ .url = "https://piston-data.mojang.com/client.jar", .sha1 = &sha1(client), .size = client.len } },
        .assetIndex = .{ .id = "fixture", .url = "https://piston-meta.mojang.com/index.json", .sha1 = &sha1(index), .size = index.len },
        .libraries = libraries,
    }, .{ .emit_null_optional_fields = false });
}
fn writeFixtureGame(dir: std.Io.Dir, descriptor: []const u8, client: []const u8, index: []const u8) !void {
    try dir.createDirPath(io, ".minecraft/versions/Display Name");
    try dir.createDirPath(io, ".minecraft/assets/indexes");
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Display Name/Display Name.json", .data = descriptor });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Display Name/Display Name.jar", .data = client });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/assets/indexes/fixture.json", .data = index });
}
fn writeLoaderReceipt(dir: std.Io.Dir, descriptor: []const u8, client: []const u8, instance: config.Instance, bindings: []const FixtureBinding) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, .{
        .schema_version = @as(u32, 1),
        .instance_id = instance.id,
        .instance_name = instance.name,
        .minecraft_version = instance.minecraft_version,
        .loader = @tagName(instance.loader),
        .loader_version = instance.loader_version.?,
        .metadata_sha256 = &sha256(descriptor),
        .client_sha256 = &sha256(client),
        .client_size = client.len,
        .source_sha1 = &sha1(client),
        .profile_sha1 = &sha1(descriptor),
        .source_url = "https://meta.fabricmc.net/v2/versions/loader/1.20.1/0.16.10/profile/json",
        .artifact_bindings = bindings,
    }, .{});
    defer a.free(bytes);
    try dir.writeFile(std.testing.io, .{ .sub_path = ".minecraft/versions/Display Name/.vela-loader.json", .data = bytes });
}

test "content manager uses only exact authoritative loader artifact bindings" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease() });
    defer service.deinit();
    const instance: config.Instance = .{ .id = "stable-id", .name = "Display Name", .minecraft_version = "1.20.1", .loader = .fabric, .loader_version = "0.16.10" };
    const client = "client";
    const library = "library";
    const index = try std.json.Stringify.valueAlloc(a, .{ .objects = std.json.Value{ .object = .empty } }, .{});
    defer a.free(index);
    const library_path = "libraries/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar";
    const libraries = [_]FixtureLibrary{.{ .name = "net.fabricmc:fabric-loader:0.16.10", .downloads = .{ .artifact = .{ .path = library_path["libraries/".len..], .url = "https://maven.fabricmc.net/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar", .size = library.len } } }};
    const descriptor = try fixtureDescriptor(a, instance, client, index, &libraries);
    defer a.free(descriptor);
    try writeFixtureGame(tmp.dir, descriptor, client, index);
    try tmp.dir.createDirPath(io, ".minecraft/libraries/net/fabricmc/fabric-loader/0.16.10");
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/libraries/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar", .data = library });
    try writeLoaderReceipt(tmp.dir, descriptor, client, instance, &.{});
    const pack_index = try std.json.Stringify.valueAlloc(a, .{
        .formatVersion = @as(u32, 1),
        .game = "minecraft",
        .versionId = "v1",
        .name = "Fixture Pack",
        .files = [_]std.json.Value{},
        .dependencies = .{ .minecraft = instance.minecraft_version, .@"fabric-loader" = instance.loader_version.? },
    }, .{});
    defer a.free(pack_index);
    try storedZip(tmp.dir, "fixture.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = pack_index }, .{ .path = "overrides/config/pack.cfg", .bytes = "pack settings" } });
    const archive = try tmp.dir.realPathFileAlloc(io, "fixture.mrpack", a);
    defer a.free(archive);
    try service.select(instance);
    try drain(&service);
    try service.importPackFor(archive, .{ .provider = .modrinth, .project_id = "fixture-pack", .version_id = "v1" });
    try drain(&service);
    _ = try expectProposal(&service);
    try std.testing.expect(!service.snapshot().proposal.?.ready);
    try std.testing.expectEqual(error.UnverifiableGamePrerequisite, service.snapshot().proposal.?.blocker.?);
    const digest = sha256(library);
    const good: FixtureBinding = .{ .path = library_path, .sha256 = &digest, .size = library.len };
    const cases = [_][]const FixtureBinding{
        &.{.{ .path = "libraries/net/fabricmc/fabric-loader/0.16.10/other.jar", .sha256 = &digest, .size = library.len }},
        &.{ good, .{ .path = "libraries/NET/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar", .sha256 = &digest, .size = library.len } },
        &.{ good, .{ .path = "libraries/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar/child.jar", .sha256 = &digest, .size = library.len } },
        &.{.{ .path = library_path, .sha256 = &digest, .size = library.len + 1 }},
    };
    for (cases) |bindings| {
        try writeLoaderReceipt(tmp.dir, descriptor, client, instance, bindings);
        try service.resolve(&.{}, &.{}, &.{}, &.{});
        try drain(&service);
        try std.testing.expect(!service.snapshot().proposal.?.ready);
        try std.testing.expect(service.snapshot().proposal.?.blocker != null);
    }
    try writeLoaderReceipt(tmp.dir, descriptor, client, instance, &.{good});
    try service.resolve(&.{}, &.{}, &.{}, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().proposal.?.ready);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/libraries/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar", .data = "wronggg" });
    try service.commit();
    try drain(&service);
    try std.testing.expectEqual(error.HashMismatch, service.snapshot().failure.?);
    try std.testing.expect(service.snapshot().report == null);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/libraries/net/fabricmc/fabric-loader/0.16.10/fabric-loader-0.16.10.jar", .data = library });
    try service.commit();
    try drain(&service);
    try std.testing.expect(service.snapshot().report.?.committed and service.snapshot().report.?.complete);
    var wrong = instance;
    wrong.loader_version = "0.16.9";
    try writeLoaderReceipt(tmp.dir, descriptor, client, wrong, &.{good});
    try service.importPackFor(archive, .{ .provider = .modrinth, .project_id = "fixture-pack", .version_id = "v1" });
    try drain(&service);
    try std.testing.expect(!service.snapshot().proposal.?.ready);
    try std.testing.expectEqual(error.InstallReceiptMismatch, service.snapshot().proposal.?.blocker.?);
}

test "content manager inspects actual native CPU for opaque modern classifier" {
    const platform = @import("builtin");
    if (platform.os.tag != .linux or (platform.cpu.arch != .x86_64 and platform.cpu.arch != .aarch64)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease() });
    defer service.deinit();
    const client = "client";
    const index = try std.json.Stringify.valueAlloc(a, .{ .objects = std.json.Value{ .object = .empty } }, .{});
    defer a.free(index);
    try tmp.dir.createDirPath(io, ".minecraft/libraries/example/fixture/1");
    const library_dir = try tmp.dir.openDir(io, ".minecraft/libraries/example/fixture/1", .{});
    defer library_dir.close(io);
    const pack_index = try std.json.Stringify.valueAlloc(a, .{
        .formatVersion = @as(u32, 1),
        .game = "minecraft",
        .versionId = "v1",
        .name = "Fixture Pack",
        .files = [_]std.json.Value{},
        .dependencies = .{ .minecraft = selected.minecraft_version },
    }, .{});
    defer a.free(pack_index);
    try storedZip(tmp.dir, "fixture.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = pack_index }, .{ .path = "overrides/config/pack.cfg", .bytes = "pack settings" } });
    const archive = try tmp.dir.realPathFileAlloc(io, "fixture.mrpack", a);
    defer a.free(archive);
    for ([_]bool{ false, true }, 0..) |wrong_cpu, iteration| {
        var elf: [64]u8 = @splat(0);
        elf[0] = 0x7f;
        elf[1] = 'E';
        elf[2] = 'L';
        elf[3] = 'F';
        elf[4] = 2;
        elf[5] = 1;
        elf[6] = 1;
        elf[16] = 3;
        elf[20] = 1;
        elf[18] = if ((platform.cpu.arch == .aarch64) != wrong_cpu) 183 else 62;
        elf[52] = 64;
        try storedZip(library_dir, "fixture-1-natives-fixture.jar", &.{.{ .path = "libfixture.so", .bytes = &elf }});
        const native_bytes = try library_dir.readFileAlloc(io, "fixture-1-natives-fixture.jar", a, .limited(1024 * 1024));
        defer a.free(native_bytes);
        const libraries = [_]FixtureLibrary{.{ .name = "example:fixture:1:natives-fixture", .downloads = .{ .artifact = .{
            .path = "example/fixture/1/fixture-1-natives-fixture.jar",
            .url = "https://libraries.minecraft.net/example/fixture/1/fixture-1-natives-fixture.jar",
            .sha1 = &sha1(native_bytes),
            .size = native_bytes.len,
        } } }};
        const descriptor = try fixtureDescriptor(a, selected, client, index, &libraries);
        defer a.free(descriptor);
        try writeFixtureGame(tmp.dir, descriptor, client, index);
        try writeGameReceipt(tmp.dir, descriptor, client, selected.minecraft_version);
        if (iteration == 0) {
            try service.select(selected);
            try drain(&service);
            try service.importPackFor(archive, .{ .provider = .modrinth, .project_id = "fixture-pack", .version_id = "v1" });
            try drain(&service);
        } else {
            try service.resolve(&.{}, &.{}, &.{}, &.{});
            try drain(&service);
        }
        _ = try expectProposal(&service);
        if (!wrong_cpu) try std.testing.expectEqual(@as(?anyerror, null), service.snapshot().proposal.?.blocker);
        try std.testing.expectEqual(!wrong_cpu, service.snapshot().proposal.?.ready);
        if (wrong_cpu) {
            try std.testing.expect(service.snapshot().proposal.?.blocker != null);
            try std.testing.expectError(error.IncompleteContent, service.commit());
        }
    }
}

test "content manager verifies legacy 1.7 native sources without touching launch outputs" {
    const platform = @import("builtin");
    if (platform.os.tag != .linux or (platform.cpu.arch != .x86_64 and platform.cpu.arch != .aarch64)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease() });
    defer service.deinit();
    var instance = selected;
    instance.minecraft_version = "1.7.10";
    const client = "client";
    const index = try std.json.Stringify.valueAlloc(a, .{ .objects = std.json.Value{ .object = .empty } }, .{});
    defer a.free(index);
    try tmp.dir.createDirPath(io, ".minecraft/libraries/example/fixture/1");
    const library_dir = try tmp.dir.openDir(io, ".minecraft/libraries/example/fixture/1", .{});
    defer library_dir.close(io);
    try tmp.dir.createDirPath(io, ".minecraft/versions/Display Name/natives");
    const output = try tmp.dir.openDir(io, ".minecraft/versions/Display Name/natives", .{});
    defer output.close(io);
    try output.writeFile(io, .{ .sub_path = "old-native.so", .data = "existing launch output" });
    const pack_index = try std.json.Stringify.valueAlloc(a, .{
        .formatVersion = @as(u32, 1),
        .game = "minecraft",
        .versionId = "v1",
        .name = "Legacy Fixture Pack",
        .files = [_]std.json.Value{},
        .dependencies = .{ .minecraft = instance.minecraft_version },
    }, .{});
    defer a.free(pack_index);
    try storedZip(tmp.dir, "legacy.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = pack_index }, .{ .path = "overrides/config/legacy.cfg", .bytes = "settings" } });
    const archive = try tmp.dir.realPathFileAlloc(io, "legacy.mrpack", a);
    defer a.free(archive);
    const Case = enum { valid, wrong_cpu, malformed, missing, wrong_hash, wrong_size, missing_hash, missing_size };
    for (std.enums.values(Case), 0..) |case, iteration| {
        var elf: [64]u8 = @splat(0);
        @memcpy(elf[0..4], "\x7fELF");
        elf[4] = 2;
        elf[5] = 1;
        elf[6] = 1;
        elf[16] = 3;
        elf[20] = 1;
        elf[18] = if ((platform.cpu.arch == .aarch64) != (case == .wrong_cpu)) 183 else 62;
        elf[52] = 64;
        try storedZip(library_dir, "fixture-1-natives-linux.jar", &.{.{ .path = "libfixture.so", .bytes = &elf }});
        if (case == .malformed) try library_dir.writeFile(io, .{ .sub_path = "fixture-1-natives-linux.jar", .data = "not a ZIP archive" });
        const native_bytes = try library_dir.readFileAlloc(io, "fixture-1-natives-linux.jar", a, .limited(1024 * 1024));
        defer a.free(native_bytes);
        const native_hash = if (case == .wrong_hash) sha1("different expected archive") else sha1(native_bytes);
        const descriptor = try std.json.Stringify.valueAlloc(a, .{
            .id = instance.name,
            .mainClass = "net.minecraft.client.main.Main",
            .minecraftArguments = "--demo",
            .downloads = .{ .client = .{ .url = "https://piston-data.mojang.com/client.jar", .sha1 = &sha1(client), .size = client.len } },
            .assetIndex = .{ .id = "fixture", .url = "https://piston-meta.mojang.com/index.json", .sha1 = &sha1(index), .size = index.len },
            .libraries = .{.{
                .name = "example:fixture:1",
                .natives = .{ .linux = "natives-linux" },
                .extract = .{ .exclude = [_][]const u8{"META-INF/"} },
                .downloads = .{ .classifiers = .{ .@"natives-linux" = .{
                    .path = "example/fixture/1/fixture-1-natives-linux.jar",
                    .url = "https://libraries.minecraft.net/example/fixture/1/fixture-1-natives-linux.jar",
                    .sha1 = if (case == .missing_hash) @as(?[]const u8, null) else @as(?[]const u8, &native_hash),
                    .size = if (case == .missing_size) @as(?u64, null) else @as(?u64, native_bytes.len + @intFromBool(case == .wrong_size)),
                } } },
            }},
        }, .{ .emit_null_optional_fields = false });
        defer a.free(descriptor);
        try writeFixtureGame(tmp.dir, descriptor, client, index);
        try writeGameReceipt(tmp.dir, descriptor, client, instance.minecraft_version);
        if (case == .missing) try library_dir.deleteFile(io, "fixture-1-natives-linux.jar");
        if (iteration == 0) {
            try service.select(instance);
            try drain(&service);
            try service.importPackFor(archive, .{ .provider = .modrinth, .project_id = "fixture-pack", .version_id = "v1" });
        } else {
            try service.resolve(&.{}, &.{}, &.{}, &.{});
        }
        try drain(&service);
        const proposal = try expectProposal(&service);
        try std.testing.expectEqual(case == .valid, proposal.ready);
        if (case == .valid) {
            try std.testing.expectEqual(@as(?anyerror, null), proposal.blocker);
        } else {
            try std.testing.expect(proposal.blocker != null);
            if (case == .wrong_cpu) try std.testing.expectEqual(error.NativeArchitectureMismatch, proposal.blocker.?);
            if (case == .wrong_hash) try std.testing.expectEqual(error.HashMismatch, proposal.blocker.?);
            if (case == .wrong_size) try std.testing.expectEqual(error.SizeMismatch, proposal.blocker.?);
            try std.testing.expectError(error.IncompleteContent, service.commit());
        }
        const old = try output.readFileAlloc(io, "old-native.so", a, .limited(1024));
        defer a.free(old);
        try std.testing.expectEqualStrings("existing launch output", old);
        try std.testing.expectError(error.FileNotFound, output.statFile(io, "libfixture.so", .{}));
        try std.testing.expect(!leases.held);
    }
}

test "content manager retired stage cleanup uses its owning stable ID lease" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{ .allow_other = true };
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease() });
    defer service.deinit();
    const index = try std.json.Stringify.valueAlloc(a, .{
        .formatVersion = @as(u32, 1),
        .game = "minecraft",
        .versionId = "v1",
        .name = "Fixture Pack",
        .files = [_]std.json.Value{},
        .dependencies = .{ .minecraft = selected.minecraft_version },
    }, .{});
    defer a.free(index);
    try storedZip(tmp.dir, "fixture.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = index }, .{ .path = "overrides/config/pack.cfg", .bytes = "pack settings" } });
    const archive = try tmp.dir.realPathFileAlloc(io, "fixture.mrpack", a);
    defer a.free(archive);
    try service.select(selected);
    try drain(&service);
    try service.importPackFor(archive, .{ .provider = .modrinth, .project_id = "fixture-pack", .version_id = "v1" });
    try drain(&service);
    const stage = try a.dupe(u8, try expectStage(&service));
    defer a.free(stage);
    var other = selected;
    other.id = "other-id";
    other.name = "Other Name";
    try service.select(other);
    try drain(&service);
    const retained = try std.Io.Dir.cwd().openDir(io, stage, .{ .follow_symlinks = false });
    retained.close(io);
    try std.testing.expect(!leases.held);
    try service.select(selected);
    try drain(&service);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, stage, .{ .follow_symlinks = false }));
    try std.testing.expectEqual(leases.acquired, leases.released);
}

const cf_reference: credentials.Reference = "0123456789abcdef0123456789abcdef".*;
const cf_key = "synthetic-cf-key";
const cf_policy: manager.CurseForgePolicy = .{ .enabled = true, .terms_approved = true, .credential_ref = cf_reference };
const CfVault = struct {
    gets: usize = 0,
    fn store(self: *CfVault) credentials.Store {
        return .{ .ctx = self, .vtable = &.{ .put = put, .get = get, .delete = delete } };
    }
    fn put(_: *anyopaque, _: []const u8, _: []const u8) credentials.Error!void {
        return error.Denied;
    }
    fn delete(_: *anyopaque, _: []const u8) credentials.Error!void {
        return error.Denied;
    }
    fn get(ctx: *anyopaque, allocator: std.mem.Allocator, reference: []const u8) credentials.Error!credentials.Secret {
        const self: *CfVault = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, reference, &cf_reference)) return error.InvalidReference;
        self.gets += 1;
        return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, cf_key) };
    }
};
const CfHttp = struct {
    mode: enum { valid, wrong_project, wrong_file, incompatible, bad_hash, missing_hash, missing_size, collision, case_collision, remote, dependency } = .valid,
    calls: usize = 0,
    files: usize = 0,
    cdn_calls: usize = 0,
    payload: []const u8 = "mod",
    primary_filename: []const u8 = "example.jar",
    remote_url: []const u8 = "https://edge.forgecdn.net/files/0/34/example.jar",
    project_class: u32 = 12,
    official_page: []const u8 = "https://www.curseforge.com/minecraft/texture-packs/example",
    distribution_allowed: bool = true,
    game_versions: []const []const u8 = &.{"1.20.1"},
    list_count: usize = 1,
    fail_second: bool = false,
    fail_all: bool = false,
    wait_for_cancel: bool = false,
    entered: std.atomic.Value(bool) = .init(false),
    fn execute(context: ?*anyopaque, allocator: std.mem.Allocator, worker_io: std.Io, request: http.Request) !http.Response {
        const self: *CfHttp = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        try std.testing.expect(request.require_public_address and !request.follow_redirects);
        try std.testing.expect(std.mem.indexOf(u8, request.url, cf_key) == null);
        var keys: usize = 0;
        for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
            keys += 1;
            try std.testing.expectEqualStrings(cf_key, header.value);
        };
        if (std.mem.eql(u8, request.url, self.remote_url)) {
            try std.testing.expectEqual(@as(usize, 0), keys);
            try std.testing.expectEqual(@as(usize, 0), request.headers.len);
            self.cdn_calls += 1;
            const payload = try allocator.dupe(u8, self.payload);
            return .{ .allocator = allocator, .status = 200, .body = payload, .allocation = payload };
        }
        try std.testing.expectEqual(@as(usize, 1), keys);
        const api_prefix = "https://api.curseforge.com/v1/mods/";
        if (!std.mem.startsWith(u8, request.url, api_prefix)) return error.UnexpectedCredentialRoute;
        var route = std.mem.splitScalar(u8, request.url[api_prefix.len..], '/');
        const project_id = std.fmt.parseInt(u32, route.next() orelse return error.UnexpectedCredentialRoute, 10) catch return error.UnexpectedCredentialRoute;
        const operation = route.next();
        const project = operation == null;
        const listing = if (operation) |value| std.mem.startsWith(u8, value, "files?") else false;
        var page_index: usize = 0;
        if (listing) {
            if (route.next() != null) return error.UnexpectedCredentialRoute;
            if (self.project_class == 4471) try std.testing.expect(std.mem.indexOf(u8, request.url, "modLoaderType=") == null);
            var query = std.mem.splitScalar(u8, operation.?["files?".len..], '&');
            var saw_index = false;
            while (query.next()) |parameter| if (std.mem.startsWith(u8, parameter, "index=")) {
                if (saw_index) return error.UnexpectedCredentialRoute;
                page_index = try std.fmt.parseInt(usize, parameter["index=".len..], 10);
                saw_index = true;
            };
            if (!saw_index or page_index >= self.list_count) return error.UnexpectedCredentialRoute;
        }
        const file_id = if (listing) @as(u32, 34) else if (operation) |value| file: {
            if (!std.mem.eql(u8, value, "files")) return error.UnexpectedCredentialRoute;
            const id = std.fmt.parseInt(u32, route.next() orelse return error.UnexpectedCredentialRoute, 10) catch return error.UnexpectedCredentialRoute;
            if (route.next() != null) return error.UnexpectedCredentialRoute;
            break :file id;
        } else @as(u32, 0);
        const second = project_id == 42;
        self.entered.store(true, .release);
        if (self.wait_for_cancel) {
            while (!request.cancel.?.load(.acquire)) try worker_io.sleep(.fromMilliseconds(1), .awake);
            return error.Canceled;
        }
        if (self.fail_all or (second and self.fail_second)) {
            const failure_body = try allocator.dupe(u8, "{}");
            return .{ .allocator = allocator, .status = 500, .body = failure_body, .allocation = failure_body };
        }
        const body = if (project) try std.json.Stringify.valueAlloc(allocator, .{ .data = .{
            .id = if (self.mode == .wrong_project) @as(u32, 99) else project_id,
            .gameId = @as(u32, 432),
            .classId = self.project_class,
            .name = "Example",
            .summary = "fixture",
            .links = .{ .websiteUrl = self.official_page },
            .allowModDistribution = self.distribution_allowed,
        } }, .{}) else blk: {
            self.files += 1;
            const hash_bytes = sha1(self.payload);
            const hash: []const u8 = if (self.mode == .bad_hash) "bad" else &hash_bytes;
            const Hash = struct { algo: u32, value: []const u8 };
            const Dependency = struct { modId: u32, relationType: u32 };
            const hashes: []const Hash = if (self.mode == .missing_hash) &.{} else &.{.{ .algo = 1, .value = hash }};
            const dependencies: []const Dependency = if (self.mode == .dependency and !second) &.{.{ .modId = 42, .relationType = 3 }} else &.{};
            const filename: []const u8 = switch (self.mode) {
                .collision => "pack.cfg",
                .case_collision => "EXAMPLE.jar",
                else => if (second) "extra.jar" else self.primary_filename,
            };
            const file_value = .{
                .id = if (self.mode == .wrong_file) @as(u32, 99) else file_id,
                .gameId = @as(u32, 432),
                .modId = project_id,
                .displayName = "Example 1",
                .fileName = filename,
                .isAvailable = true,
                .downloadUrl = if (self.mode == .remote) @as(?[]const u8, self.remote_url) else @as(?[]const u8, null),
                .fileLength = if (self.mode == .missing_size) @as(?u64, null) else @as(?u64, self.payload.len),
                .hashes = hashes,
                .gameVersions = if (self.mode == .incompatible) @as([]const []const u8, &.{"1.19.4"}) else self.game_versions,
                .dependencies = dependencies,
            };
            if (listing) {
                const count = @min(@as(usize, 50), self.list_count - page_index);
                const items = try allocator.alloc(@TypeOf(file_value), count);
                defer allocator.free(items);
                for (items, 0..) |*item, index| {
                    item.* = file_value;
                    item.id = @intCast(34 + page_index + index);
                }
                break :blk try std.json.Stringify.valueAlloc(allocator, .{ .data = items, .pagination = .{ .index = page_index, .pageSize = @as(usize, 50), .resultCount = count, .totalCount = self.list_count } }, .{});
            }
            break :blk try std.json.Stringify.valueAlloc(allocator, .{ .data = file_value }, .{});
        };
        return .{ .allocator = allocator, .status = 200, .body = body, .allocation = body };
    }
};
fn writeCfGame(dir: std.Io.Dir) !void {
    const index = "{\"objects\":{}}";
    const client = "client";
    const descriptor = try std.json.Stringify.valueAlloc(a, .{
        .id = selected.name,
        .mainClass = "net.minecraft.client.main.Main",
        .arguments = .{ .game = [_][]const u8{}, .jvm = [_][]const u8{} },
        .downloads = .{ .client = .{ .url = "https://piston-data.mojang.com/client.jar", .sha1 = &sha1(client), .size = client.len } },
        .assetIndex = .{ .id = "fixture", .url = "https://piston-meta.mojang.com/index.json", .sha1 = &sha1(index), .size = index.len },
        .libraries = [_]std.json.Value{},
    }, .{});
    defer a.free(descriptor);
    try writeFixtureGame(dir, descriptor, client, index);
    try writeGameReceipt(dir, descriptor, client, selected.minecraft_version);
}
fn writeCfPack(dir: std.Io.Dir, second: bool, override_path: []const u8) !void {
    const Ref = struct { projectID: u32, fileID: u32, required: bool };
    const refs: []const Ref = if (second) &.{ .{ .projectID = 12, .fileID = 34, .required = true }, .{ .projectID = 42, .fileID = 43, .required = false } } else &.{.{ .projectID = 12, .fileID = 34, .required = true }};
    const json = try std.json.Stringify.valueAlloc(a, .{
        .manifestVersion = @as(u32, 1),
        .manifestType = "minecraftModpack",
        .name = "Fixture",
        .version = "v1",
        .minecraft = .{ .version = selected.minecraft_version, .modLoaders = [_]std.json.Value{} },
        .files = refs,
        .overrides = "overrides",
    }, .{});
    defer a.free(json);
    try storedZip(dir, "fixture.zip", &.{ .{ .path = "manifest.json", .bytes = json }, .{ .path = override_path, .bytes = "pack settings" } });
}
fn expectSuccess(service: *manager.Manager) !void {
    if (service.snapshot().failure) |failure| {
        std.debug.print("content fixture failure: {s}\n", .{@errorName(failure)});
        return failure;
    }
}
fn expectProposal(service: *manager.Manager) !*const manager.Proposal {
    try expectSuccess(service);
    const snapshot = service.snapshot();
    try std.testing.expect(snapshot.proposal != null);
    return snapshot.proposal.?;
}
fn expectStage(service: *manager.Manager) ![]const u8 {
    const proposal = try expectProposal(service);
    try std.testing.expect(proposal.stage_path != null);
    return proposal.stage_path.?;
}
fn expectDesired(service: *manager.Manager) !manifest.Manifest {
    const proposal = try expectProposal(service);
    try std.testing.expect(proposal.desired != null);
    return proposal.desired.?;
}
fn expectFailure(service: *manager.Manager, expected: anyerror) !void {
    const failure = service.snapshot().failure;
    try std.testing.expect(failure != null);
    try std.testing.expectEqual(expected, failure.?);
}
fn importCf(service: *manager.Manager, dir: std.Io.Dir) !void {
    const archive = try dir.realPathFileAlloc(io, "fixture.zip", a);
    defer a.free(archive);
    try service.select(selected);
    try drain(service);
    try service.importPackFor(archive, .{ .provider = .curseforge, .project_id = "pack", .version_id = "v1" });
    try drain(service);
    const proposal = try expectProposal(service);
    try std.testing.expect(proposal.pack != null);
    try std.testing.expect(proposal.desired != null);
}

test "content CF explicit authorization gates before fake vault and HTTP" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var vault: CfVault = .{};
    var fixture: CfHttp = .{};
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
    defer service.deinit();
    try writeCfGame(tmp.dir);
    try writeCfPack(tmp.dir, false, "overrides/config/pack.cfg");
    try importCf(&service, tmp.dir);
    for ([_]manager.CurseForgePolicy{ .{}, .{ .enabled = true, .credential_ref = cf_reference }, .{ .terms_approved = true, .credential_ref = cf_reference }, .{ .enabled = true, .terms_approved = true } }) |policy| {
        try service.setCurseForgePolicy(policy);
        try drain(&service);
        try std.testing.expect(!service.canResolvePackReferences());
        try std.testing.expectError(error.ProviderDisabled, service.resolvePackReferences(&.{}, &.{}, &.{}, &.{}));
    }
    try std.testing.expectError(error.InvalidReference, service.setCurseForgePolicy(.{ .enabled = true, .terms_approved = true, .credential_ref = @as([32]u8, @splat('X')) }));
    try std.testing.expectEqual(@as(usize, 0), vault.gets);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try service.setCurseForgePolicy(cf_policy);
    try importCf(&service, tmp.dir);
    try service.resolvePackReferences(&.{}, &.{}, &.{}, &.{});
    try std.testing.expectError(error.ContentWorkerBusy, service.setCurseForgePolicy(.{}));
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    const proposal = service.snapshot().proposal.?;
    try std.testing.expectEqual(@as(usize, 0), proposal.pack.?.unresolved.len);
    try std.testing.expectEqual(@as(usize, 1), proposal.missing_manual);
    try std.testing.expect(!proposal.ready);
    try std.testing.expect(manualStatus(proposal, "config/pack.cfg").?.verified);
    const remote_manual_status = manualStatus(proposal, "resourcepacks/example.jar").?;
    try std.testing.expect(!remote_manual_status.verified and remote_manual_status.source_absolute_path == null);
    try std.testing.expectEqual(@as(usize, 1), vault.gets);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqualStrings("12", proposal.files[1].record.project_id);
    try std.testing.expectEqualStrings("34", proposal.files[1].record.version_id);
    try std.testing.expectEqualStrings("https://www.curseforge.com/minecraft/texture-packs/example/files/34", proposal.files[1].download.manual_required.official_page);
    try std.testing.expectEqual(leases.acquired, leases.released);
    var disabled = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
    defer disabled.deinit();
    try std.testing.expect(!disabled.canResolvePackReferences());
    try std.testing.expectError(error.ProviderDisabled, disabled.resolvePackReferences(&.{}, &.{}, &.{}, &.{}));
    try std.testing.expectEqual(@as(usize, 1), vault.gets);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "content CF partial retry preserves stage overrides manual optional and conflict decisions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var vault: CfVault = .{};
    var fixture: CfHttp = .{ .fail_second = true };
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
    defer service.deinit();
    try writeCfGame(tmp.dir);
    const previous = try manifest.serialize(a, .{ .schema_version = manifest.schema_version, .instance_id = selected.id, .pack_version = "v0", .pack_membership = .{ .identity = .{ .provider = .curseforge, .project_id = "pack", .version_id = "v0" }, .paths = &.{"config/pack.cfg"} }, .files = &.{.{ .path = "config/pack.cfg", .provider = .curseforge, .project_id = "pack", .version_id = "v0", .identity_provenance = .pack_override, .standalone = false, .hashes = .{ .sha256 = &sha256("original") }, .size = "original".len, .role = .override }} });
    defer a.free(previous);
    try tmp.dir.createDirPath(io, ".vela/instances/stable-id");
    try tmp.dir.writeFile(io, .{ .sub_path = ".vela/instances/stable-id/content.json", .data = previous });
    try tmp.dir.createDirPath(io, ".minecraft/versions/Display Name/config");
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Display Name/config/pack.cfg", .data = "local" });
    try writeCfPack(tmp.dir, true, "overrides/config/pack.cfg");
    try importCf(&service, tmp.dir);
    const stage = try a.dupe(u8, service.snapshot().proposal.?.stage_path.?);
    defer a.free(stage);
    const decisions = &[_]manifest.ConflictDecision{.{ .path = "config/pack.cfg", .choice = .replace }};
    try service.resolvePackReferences(&.{}, decisions, &.{}, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    try std.testing.expectEqual(@as(usize, 1), service.snapshot().proposal.?.pack.?.unresolved.len);
    try std.testing.expect(!service.snapshot().proposal.?.ready);
    try std.testing.expectError(error.IncompleteContent, service.commit());
    try tmp.dir.writeFile(io, .{ .sub_path = "manual.jar", .data = "mod" });
    const manual = try tmp.dir.realPathFileAlloc(io, "manual.jar", a);
    defer a.free(manual);
    for ([_][]const u8{ "bad", "wrong size" }) |bad| {
        try tmp.dir.writeFile(io, .{ .sub_path = "manual.jar", .data = bad });
        try service.resolve(&.{}, decisions, &.{.{ .path = "resourcepacks/example.jar", .source_absolute_path = manual }}, &.{});
        try drain(&service);
        const expected: anyerror = if (bad.len == 3) error.HashMismatch else error.SizeMismatch;
        try std.testing.expectEqual(expected, service.snapshot().failure.?);
        try std.testing.expectEqual(@as(usize, 1), service.snapshot().proposal.?.missing_manual);
        try std.testing.expect(!service.snapshot().proposal.?.ready);
        try std.testing.expectError(error.IncompleteContent, service.commit());
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "manual.jar", .data = "mod" });
    fixture.fail_second = false;
    try service.resolvePackReferences(&.{}, decisions, &.{.{ .path = "resourcepacks/example.jar", .source_absolute_path = manual }}, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    try std.testing.expectEqualStrings(stage, service.snapshot().proposal.?.stage_path.?);
    try std.testing.expectEqual(@as(usize, 0), service.snapshot().proposal.?.pack.?.unresolved.len);
    try std.testing.expectEqual(@as(usize, 0), service.snapshot().proposal.?.missing_manual);
    const retried_status = manualStatus(service.snapshot().proposal.?, "resourcepacks/example.jar").?;
    try std.testing.expect(retried_status.verified);
    try std.testing.expectEqualStrings(manual, retried_status.source_absolute_path.?);
    try std.testing.expect(manualStatus(service.snapshot().proposal.?, "config/pack.cfg").?.verified);
    try std.testing.expect(!service.snapshot().proposal.?.ready);
    try service.resolve(&.{}, decisions, &.{}, &.{.{ .path = "resourcepacks/extra.jar", .include = false }});
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    try std.testing.expect(service.snapshot().proposal.?.ready);
    try std.testing.expect(manualStatus(service.snapshot().proposal.?, "resourcepacks/extra.jar") == null);
    try std.testing.expectEqualStrings(stage, service.snapshot().proposal.?.stage_path.?);
    try service.commit();
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    try std.testing.expect(service.snapshot().report.?.complete);
    try std.testing.expectEqual(@as(usize, 7), fixture.calls);
    try std.testing.expectEqual(@as(usize, 4), vault.gets);
    const mod = try tmp.dir.readFileAlloc(io, ".minecraft/versions/Display Name/resourcepacks/example.jar", a, .limited(32));
    defer a.free(mod);
    try std.testing.expectEqualStrings("mod", mod);
    const settings = try tmp.dir.readFileAlloc(io, ".minecraft/versions/Display Name/config/pack.cfg", a, .limited(32));
    defer a.free(settings);
    try std.testing.expectEqualStrings("pack settings", settings);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, stage, .{ .follow_symlinks = false }));
    try std.testing.expectEqual(leases.acquired, leases.released);
}

test "content CF malformed metadata collisions and remote records preserve incomplete preview" {
    for ([_]CfHttp{ .{ .mode = .wrong_project }, .{ .mode = .wrong_file }, .{ .mode = .incompatible }, .{ .mode = .bad_hash }, .{ .mode = .missing_hash }, .{ .mode = .missing_size }, .{ .mode = .collision }, .{ .mode = .case_collision } }) |item| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var paths = try instances.Paths.init(a, io, root);
        defer paths.deinit();
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var leases: LeaseState = .{};
        var vault: CfVault = .{};
        var fixture = item;
        var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
        defer service.deinit();
        try writeCfGame(tmp.dir);
        try writeCfPack(tmp.dir, false, if (item.mode == .collision) "overrides/resourcepacks/pack.cfg" else if (item.mode == .case_collision) "overrides/resourcepacks/example.jar" else "overrides/config/pack.cfg");
        try importCf(&service, tmp.dir);
        const stage = try a.dupe(u8, service.snapshot().proposal.?.stage_path.?);
        defer a.free(stage);
        try service.resolvePackReferences(&.{}, &.{}, &.{}, &.{});
        try drain(&service);
        try std.testing.expect(service.snapshot().failure != null);
        if (item.mode == .remote) try std.testing.expectEqual(error.ProviderDisabled, service.snapshot().failure.?);
        try std.testing.expectEqualStrings(stage, service.snapshot().proposal.?.stage_path.?);
        try std.testing.expectEqual(@as(usize, 1), service.snapshot().proposal.?.pack.?.unresolved.len);
        try std.testing.expectError(error.IncompleteContent, service.commit());
        try std.testing.expectEqual(leases.acquired, leases.released);
    }
}

test "content CF required dependency cannot be omitted and cancellation joins retained stage cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var vault: CfVault = .{};
    var fixture: CfHttp = .{ .mode = .dependency };
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
    defer service.deinit();
    try writeCfGame(tmp.dir);
    try writeCfPack(tmp.dir, false, "overrides/config/pack.cfg");
    try importCf(&service, tmp.dir);
    try service.resolvePackReferences(&.{}, &.{}, &.{}, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    try std.testing.expect(!service.snapshot().proposal.?.dependencies_ready);
    try std.testing.expect(service.snapshot().dependency_issues.len != 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "manual.jar", .data = "mod" });
    const manual = try tmp.dir.realPathFileAlloc(io, "manual.jar", a);
    defer a.free(manual);
    try service.resolve(&.{}, &.{}, &.{.{ .path = "resourcepacks/example.jar", .source_absolute_path = manual }}, &.{});
    try drain(&service);
    try std.testing.expect(!service.snapshot().proposal.?.ready);
    try std.testing.expectError(error.IncompleteContent, service.commit());
    try writeCfPack(tmp.dir, true, "overrides/config/pack.cfg");
    try importCf(&service, tmp.dir);
    try service.resolvePackReferences(&.{}, &.{}, &.{}, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    try service.resolve(&.{}, &.{}, &.{ .{ .path = "resourcepacks/example.jar", .source_absolute_path = manual }, .{ .path = "resourcepacks/extra.jar", .source_absolute_path = manual } }, &.{.{ .path = "resourcepacks/extra.jar", .include = false }});
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    try std.testing.expect(!service.snapshot().proposal.?.dependencies_ready);
    try std.testing.expectError(error.IncompleteContent, service.commit());
    try service.resolve(&.{}, &.{}, &.{}, &.{.{ .path = "resourcepacks/extra.jar", .include = true }});
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    try std.testing.expect(service.snapshot().proposal.?.ready);
    try writeCfPack(tmp.dir, false, "overrides/config/pack.cfg");
    try importCf(&service, tmp.dir);
    const stage = try a.dupe(u8, service.snapshot().proposal.?.stage_path.?);
    defer a.free(stage);
    fixture.wait_for_cancel = true;
    fixture.entered.store(false, .release);
    try service.resolvePackReferences(&.{}, &.{}, &.{}, &.{});
    var remaining: usize = 10000;
    while (!fixture.entered.load(.acquire)) {
        if (remaining == 0) return error.WorkerDidNotEnter;
        remaining -= 1;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    service.cancel();
    try drain(&service);
    try std.testing.expectEqual(error.Canceled, service.snapshot().failure.?);
    try std.testing.expect(!leases.held and !registry.hasActive());
    try std.testing.expectEqualStrings(stage, service.snapshot().proposal.?.stage_path.?);
    try service.select(null);
    try service.select(selected);
    try drain(&service);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, stage, .{ .follow_symlinks = false }));
    try std.testing.expectEqual(leases.acquired, leases.released);
}

test "content CF duplicate archive references fail before vault and HTTP" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var vault: CfVault = .{};
    var fixture: CfHttp = .{};
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
    defer service.deinit();
    const json = "{\"manifestVersion\":1,\"manifestType\":\"minecraftModpack\",\"name\":\"Fixture\",\"version\":\"v1\",\"minecraft\":{\"version\":\"1.20.1\",\"modLoaders\":[]},\"files\":[{\"projectID\":12,\"fileID\":34,\"required\":true},{\"projectID\":12,\"fileID\":35,\"required\":true}],\"overrides\":\"overrides\"}";
    try storedZip(tmp.dir, "duplicate.zip", &.{.{ .path = "manifest.json", .bytes = json }});
    const archive = try tmp.dir.realPathFileAlloc(io, "duplicate.zip", a);
    defer a.free(archive);
    try service.select(selected);
    try drain(&service);
    try service.importPackFor(archive, .{ .provider = .curseforge, .project_id = "pack", .version_id = "v1" });
    try drain(&service);
    try std.testing.expectEqual(error.DuplicateContent, service.snapshot().failure.?);
    try std.testing.expect(service.snapshot().proposal == null);
    try std.testing.expectEqual(@as(usize, 0), vault.gets);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(leases.acquired, leases.released);
}

fn expectInspectionRetained(inspection: *const @import("core/pack_import.zig").Inspection) !void {
    const archive = try std.Io.Dir.cwd().openFile(io, inspection.archive_absolute_path, .{});
    archive.close(io);
    const stage = try std.Io.Dir.cwd().openDir(io, inspection.stage_absolute_path, .{});
    stage.close(io);
    try std.testing.expectEqual(config.SourceKind.curseforge, inspection.provider);
    try std.testing.expectEqual(@as(usize, 1), inspection.pack.unresolved.len);
}

fn inspectionRollbackAllocations(allocator: std.mem.Allocator) !void {
    const packs = @import("core/pack_import.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    try writeCfPack(tmp.dir, false, "overrides/config/pack.cfg");
    const archive = try tmp.dir.realPathFileAlloc(io, "fixture.zip", a);
    defer a.free(archive);
    var inspected = try packs.inspect(a, io, &paths, archive, null, null);
    defer inspected.deinit();
    defer inspected.cleanup(io) catch {};
    const original_hash = inspected.source_sha256;
    var registry = tasks.Registry.init(allocator);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var service = manager.Manager.initOptions(allocator, io, &paths, &registry, .{ .lease = leases.lease() }) catch |err| {
        try expectInspectionRetained(&inspected);
        return err;
    };
    defer service.deinit();
    try service.select(selected);
    try drain(&service);
    if (service.snapshot().failure) |err| return err;
    service.options.fixture_spawn_failure = error.InjectedSpawnFailure;
    service.importInspectedFor(&inspected, .{ .provider = .curseforge, .project_id = "pack", .version_id = "v1" }) catch |err| {
        try expectInspectionRetained(&inspected);
        try std.testing.expectEqualStrings(&original_hash, &inspected.source_sha256);
        try std.testing.expect(!leases.held and leases.acquired == leases.released);
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.InjectedSpawnFailure, err);
        return;
    };
    return error.UnexpectedInspectionAdoption;
}

test "content inspected adoption retains caller after every allocation or injected spawn failure" {
    try @import("test_allocations").checkAllAllocationFailures(a, inspectionRollbackAllocations, .{});
}

test "content inspected adoption uses private bytes and removes owned stages on manager teardown" {
    const packs = @import("core/pack_import.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    try writeCfGame(tmp.dir);
    try writeCfPack(tmp.dir, false, "overrides/config/pack.cfg");
    const archive = try tmp.dir.realPathFileAlloc(io, "fixture.zip", a);
    defer a.free(archive);
    var inspected = try packs.inspect(a, io, &paths, archive, null, null);
    var caller_owns = true;
    defer if (caller_owns) {
        inspected.cleanup(io) catch {};
        inspected.deinit();
    };
    const private_archive = try a.dupe(u8, inspected.archive_absolute_path);
    defer a.free(private_archive);
    const private_stage = try a.dupe(u8, inspected.stage_absolute_path);
    defer a.free(private_stage);
    try tmp.dir.deleteFile(io, "fixture.zip");
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease() });
    var service_live = true;
    defer if (service_live) service.deinit();
    try service.select(selected);
    try drain(&service);
    try service.importInspectedFor(&inspected, .{ .provider = .curseforge, .project_id = "pack", .version_id = "v1" });
    caller_owns = false;
    try drain(&service);
    const proposal = try expectProposal(&service);
    try std.testing.expect(proposal.pack != null);
    try std.testing.expect(proposal.files.len > 0);
    try std.testing.expect(proposal.stage_path != null);
    try std.testing.expectEqualStrings("v1", proposal.pack.?.identity.version_id);
    try std.testing.expectEqual(manifest.IdentityProvenance.pack_override, proposal.files[0].record.identity_provenance);
    try std.testing.expect(!proposal.files[0].record.standalone);
    const proposal_stage = try a.dupe(u8, proposal.stage_path.?);
    defer a.free(proposal_stage);
    try std.testing.expect(!std.mem.eql(u8, private_stage, proposal_stage));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, private_archive, .{}));
    service.deinit();
    service_live = false;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, proposal_stage, .{}));
    try std.testing.expectEqual(leases.acquired, leases.released);
}

test "content CF remote file approval uses fresh exact metadata and unkeyed CDN" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var vault: CfVault = .{};
    var fixture: CfHttp = .{ .mode = .remote };
    var host = "edge.forgecdn.net".*;
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .allow_curseforge_remote = true, .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .approved_download_hosts = &.{&host}, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
    defer service.deinit();
    try writeCfGame(tmp.dir);
    try service.select(selected);
    try drain(&service);
    var captured = try versionFixture(a, .curseforge, "12", "34", "untrusted-name.jar", "not metadata");
    defer captured.deinit();
    try service.prepareVersion(captured.value, .resourcepack, &.{});
    host[0] = 'X';
    try drain(&service);
    const proposal = try expectProposal(&service);
    try std.testing.expect(proposal.ready);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.cdn_calls);
    try std.testing.expectEqualStrings("resourcepacks/example.jar", proposal.files[0].record.path);
    try std.testing.expectEqual(manifest.IdentityProvenance.official_file, proposal.files[0].record.identity_provenance);
    try std.testing.expectEqual(manifest.schema_version, proposal.plan.next_manifest.schema_version);
    try std.testing.expect(proposal.files[0].authorization != null);
    host[0] = 'e';
    try service.commit();
    try drain(&service);
    try expectSuccess(&service);
    try std.testing.expectEqual(@as(usize, 1), fixture.cdn_calls);
    const bytes = try tmp.dir.readFileAlloc(io, ".minecraft/versions/Display Name/resourcepacks/example.jar", a, .limited(16));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("mod", bytes);
    try std.testing.expectEqual(leases.acquired, leases.released);
}

test "content CF exact file mismatch rejects before any CDN fetch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var vault: CfVault = .{};
    var fixture: CfHttp = .{ .mode = .wrong_file };
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .allow_curseforge_remote = true, .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .approved_download_hosts = &.{"edge.forgecdn.net"}, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
    defer service.deinit();
    try service.select(selected);
    try drain(&service);
    try service.prepareUpdate(.curseforge, "12", "34", .resourcepack);
    try drain(&service);
    try expectFailure(&service, error.VersionMismatch);
    try std.testing.expect(service.snapshot().proposal == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.cdn_calls);
    try std.testing.expectEqual(leases.acquired, leases.released);
}

test "content CF counts every actual metadata HTTP request against 64 budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var vault: CfVault = .{};
    var fixture: CfHttp = .{};
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
    defer service.deinit();
    try writeCfGame(tmp.dir);
    const Ref = struct { projectID: u32, fileID: u32, required: bool };
    var refs: [33]Ref = undefined;
    for (&refs, 0..) |*ref, index| ref.* = .{ .projectID = @intCast(100 + index), .fileID = @intCast(200 + index), .required = true };
    const json = try std.json.Stringify.valueAlloc(a, .{ .manifestVersion = @as(u32, 1), .manifestType = "minecraftModpack", .name = "Budget", .version = "v1", .minecraft = .{ .version = selected.minecraft_version, .modLoaders = [_]std.json.Value{} }, .files = refs, .overrides = "overrides" }, .{});
    defer a.free(json);
    try storedZip(tmp.dir, "fixture.zip", &.{ .{ .path = "manifest.json", .bytes = json }, .{ .path = "overrides/config/pack.cfg", .bytes = "pack settings" } });
    try importCf(&service, tmp.dir);
    const initial = try expectProposal(&service);
    try std.testing.expect(initial.stage_path != null);
    const stage = try a.dupe(u8, initial.stage_path.?);
    defer a.free(stage);
    try service.resolvePackReferences(&.{}, &.{}, &.{}, &.{});
    try drain(&service);
    try expectFailure(&service, error.DependencyLimit);
    try std.testing.expectEqual(@as(usize, 64), fixture.calls);
    try std.testing.expectEqual(@as(usize, 32), fixture.files);
    try std.testing.expectEqual(@as(usize, 0), fixture.cdn_calls);
    const retained = service.snapshot().proposal orelse return error.MissingRetainedProposal;
    try std.testing.expect(retained.stage_path != null);
    try std.testing.expect(retained.pack != null);
    try std.testing.expectEqualStrings(stage, retained.stage_path.?);
    try std.testing.expectEqual(@as(usize, 33), retained.pack.?.unresolved.len);
    try std.testing.expect(!retained.ready);
    try std.testing.expectEqual(leases.acquired, leases.released);
}

test "content CF manual mode requires verified manual source for remote metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var vault: CfVault = .{};
    var fixture: CfHttp = .{ .mode = .remote };
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
    defer service.deinit();
    try service.select(selected);
    try drain(&service);
    try service.prepareUpdate(.curseforge, "12", "34", .resourcepack);
    try drain(&service);
    const proposal = try expectProposal(&service);
    try std.testing.expect(service.snapshot().failure == null);
    try std.testing.expect(proposal.blocker == null);
    try std.testing.expect(proposal.missing_manual != 0);
    try std.testing.expect(!proposal.ready);
    try std.testing.expect(proposal.files[0].download == .manual_required);
    try std.testing.expect(proposal.files[0].authorization == null);
    try std.testing.expectEqualStrings("https://www.curseforge.com/minecraft/texture-packs/example/files/34", proposal.files[0].download.manual_required.official_page);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.cdn_calls);
    try std.testing.expectEqual(leases.acquired, leases.released);
}

test "content CF retained pack authorizations refresh and HTTP outage stays unready" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var vault: CfVault = .{};
    var fixture: CfHttp = .{ .mode = .remote };
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .allow_curseforge_remote = true, .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .approved_download_hosts = &.{"edge.forgecdn.net"}, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
    defer service.deinit();
    try writeCfGame(tmp.dir);
    try writeCfPack(tmp.dir, false, "overrides/config/pack.cfg");
    try importCf(&service, tmp.dir);
    try service.resolvePackReferences(&.{}, &.{}, &.{}, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    const resolved = try expectProposal(&service);
    try std.testing.expect(resolved.pack != null);
    try std.testing.expect(resolved.ready);
    try std.testing.expectEqual(@as(usize, 0), resolved.pack.?.unresolved.len);
    fixture.fail_all = true;
    try service.resolvePackReferences(&.{}, &.{}, &.{}, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    const outage = try expectProposal(&service);
    try std.testing.expect(outage.blocker != null);
    try std.testing.expectEqual(error.HttpFailure, outage.blocker.?);
    try std.testing.expect(!outage.ready);
    try std.testing.expect(!outage.dependencies_ready);
    fixture.fail_all = false;
    fixture.distribution_allowed = false;
    try service.resolvePackReferences(&.{}, &.{}, &.{}, &.{});
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    const revoked = try expectProposal(&service);
    var found = false;
    for (revoked.files) |file| if (file.record.identity_provenance == .official_file) {
        found = true;
        try std.testing.expect(file.download == .manual_required);
        try std.testing.expectEqual(providers.ManualReason.distribution_disabled, file.download.manual_required.reason);
        try std.testing.expect(file.authorization == null);
    };
    try std.testing.expect(found);
    try std.testing.expect(!revoked.ready);
    try std.testing.expectEqual(@as(usize, 0), fixture.cdn_calls);
    try std.testing.expectEqual(leases.acquired, leases.released);
}

test "content CF candidate lists reject 129 entries but admit the 128 boundary" {
    for ([_]usize{ 128, 129 }) |count| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var paths = try instances.Paths.init(a, io, root);
        defer paths.deinit();
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var leases: LeaseState = .{};
        var vault: CfVault = .{};
        var fixture: CfHttp = .{ .list_count = count };
        var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
        defer service.deinit();
        try service.select(selected);
        try drain(&service);
        const project: providers.Project = .{ .provider = .curseforge, .id = "12", .name = "Example", .official_page = fixture.official_page };
        try service.selectProvider(.curseforge);
        try drain(&service);
        try service.loadVersions(project, .resourcepack);
        try drain(&service);
        if (count == 128) {
            try std.testing.expect(service.snapshot().failure == null);
            try std.testing.expectEqual(count, service.snapshot().versions.len);
            try std.testing.expectEqualStrings("34", service.snapshot().versions[0].id);
            try std.testing.expectEqualStrings("161", service.snapshot().versions[count - 1].id);
        } else {
            try expectFailure(&service, error.DependencyLimit);
            try std.testing.expectEqual(@as(usize, 0), service.snapshot().versions.len);
        }
        try std.testing.expectEqual(@as(usize, 4), fixture.calls);
        try std.testing.expectEqual(@as(usize, 3), fixture.files);
        try std.testing.expectEqual(@as(usize, 0), fixture.cdn_calls);
        try std.testing.expectEqual(leases.acquired, leases.released);
    }
}

test "content CF manual tagless modpack browsing refetches confirmed project without remote authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var leases: LeaseState = .{};
    var vault: CfVault = .{};
    var fixture: CfHttp = .{ .mode = .remote, .project_class = 4471, .official_page = "https://www.curseforge.com/minecraft/modpacks/example", .primary_filename = "pack.zip", .remote_url = "https://edge.forgecdn.net/files/0/34/pack.zip" };
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
    defer service.deinit();
    try service.select(selected);
    try drain(&service);
    const project: providers.Project = .{ .provider = .curseforge, .id = "12", .name = "Example", .official_page = fixture.official_page };
    try service.selectProvider(.curseforge);
    try drain(&service);
    try service.loadVersions(project, .modpack);
    try drain(&service);
    try std.testing.expect(service.snapshot().failure == null);
    try std.testing.expectEqual(@as(usize, 1), service.snapshot().versions.len);
    const version = service.snapshot().versions[0];
    try std.testing.expectEqual(@as(usize, 0), version.loaders.len);
    try std.testing.expect(version.files[0].download == .manual_required);
    try std.testing.expect(version.files[0].authorization == null);
    try std.testing.expectEqualStrings("https://www.curseforge.com/minecraft/modpacks/example/files/34", version.files[0].download.manual_required.official_page);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.files);
    try std.testing.expectEqual(@as(usize, 0), fixture.cdn_calls);
    try std.testing.expectEqual(leases.acquired, leases.released);
}

test "content CF confirmed archive is authoritative for tagless modpack loader and exact version" {
    const Case = struct {
        target_loader: config.Loader = .vanilla,
        target_version: ?[]const u8 = null,
        archive_loader: ?[]const u8 = null,
        archive_minecraft: []const u8 = "1.20.1",
        tags: []const []const u8 = &.{"1.20.1"},
        listed: usize = 1,
        failure: ?anyerror = null,
        cdn_calls: usize = 1,
        wrong_format: bool = false,
    };
    const cases = [_]Case{
        .{},
        .{ .archive_loader = "forge-47.2.0", .failure = error.LoaderMismatch },
        .{ .archive_loader = "forge-47.2.0", .target_loader = .forge, .target_version = "47.2.0" },
        .{ .archive_loader = "forge-47.2.0", .target_loader = .forge, .target_version = "47.1.0", .failure = error.LoaderVersionMismatch },
        .{ .archive_minecraft = "1.19.4", .failure = error.MinecraftVersionMismatch },
        .{ .archive_loader = "forge-47.2.0", .tags = &.{ "1.20.1", "Forge" }, .listed = 0, .failure = error.IncompatibleVersion, .cdn_calls = 0 },
        .{ .tags = &.{"1.19.4"}, .listed = 0, .failure = error.IncompatibleVersion, .cdn_calls = 0 },
        .{ .wrong_format = true, .failure = error.PackFormatMismatch },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var paths = try instances.Paths.init(a, io, root);
        defer paths.deinit();
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var leases: LeaseState = .{};
        var vault: CfVault = .{};
        const Loader = struct { id: []const u8, primary: bool };
        const loaders: []const Loader = if (case.archive_loader) |id| &.{.{ .id = id, .primary = true }} else &.{};
        const json = try std.json.Stringify.valueAlloc(a, .{ .manifestVersion = @as(u32, 1), .manifestType = "minecraftModpack", .name = "Remote pack", .version = "v1", .minecraft = .{ .version = case.archive_minecraft, .modLoaders = loaders }, .files = [_]std.json.Value{}, .overrides = "overrides" }, .{});
        defer a.free(json);
        const index_name: []const u8 = if (case.wrong_format) "modrinth.index.json" else "manifest.json";
        try storedZip(tmp.dir, "fixture.zip", &.{ .{ .path = index_name, .bytes = json }, .{ .path = "overrides/config/pack.cfg", .bytes = "pack settings" } });
        const payload = try tmp.dir.readFileAlloc(io, "fixture.zip", a, .limited(64 * 1024));
        defer a.free(payload);
        var fixture: CfHttp = .{ .mode = .remote, .project_class = 4471, .official_page = "https://www.curseforge.com/minecraft/modpacks/example", .primary_filename = "pack.zip", .remote_url = "https://edge.forgecdn.net/files/0/34/pack.zip", .payload = payload, .game_versions = case.tags };
        const hosts = [_][]const u8{"edge.forgecdn.net"};
        var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .allow_curseforge_remote = true, .curseforge = cf_policy, .fixture_credential_store = vault.store(), .transport_options = .{ .allow_curseforge = true, .approved_download_hosts = &hosts, .fixture_http = CfHttp.execute, .fixture_context = &fixture } });
        defer service.deinit();
        try writeCfGame(tmp.dir);
        var target = selected;
        target.loader = case.target_loader;
        target.loader_version = case.target_version;
        try service.select(target);
        try drain(&service);
        const project: providers.Project = .{ .provider = .curseforge, .id = "12", .name = "Example", .official_page = fixture.official_page };
        try service.selectProvider(.curseforge);
        try drain(&service);
        try service.loadVersions(project, .modpack);
        try drain(&service);
        try std.testing.expect(service.snapshot().failure == null);
        try std.testing.expectEqual(case.listed, service.snapshot().versions.len);
        try std.testing.expectEqual(@as(usize, 2), fixture.calls);
        try service.prepareUpdate(.curseforge, "12", "34", .modpack);
        try drain(&service);
        if (case.failure) |failure| {
            try expectFailure(&service, failure);
            try std.testing.expect(service.snapshot().proposal == null);
        } else {
            const proposal = try expectProposal(&service);
            try std.testing.expect(proposal.pack != null);
            try std.testing.expect(proposal.stage_path != null);
            const desired = try expectDesired(&service);
            try std.testing.expect(desired.files.len > 0);
            const pack = proposal.pack.?;
            try std.testing.expectEqual(target.loader, pack.loader);
            if (target.loader_version) |version| try std.testing.expectEqualStrings(version, pack.loader_version.?);
            try std.testing.expectEqualStrings("12", pack.identity.project_id);
            try std.testing.expectEqualStrings("34", pack.identity.version_id);
            try std.testing.expectEqual(manifest.schema_version, desired.schema_version);
            const override = desired.files[0];
            try std.testing.expectEqualStrings("config/pack.cfg", override.path);
            try std.testing.expectEqual(manifest.IdentityProvenance.pack_override, override.identity_provenance);
            try std.testing.expect(!override.standalone);
            try std.testing.expectEqualStrings("12", override.project_id);
            const stage = try std.Io.Dir.openDirAbsolute(io, proposal.stage_path.?, .{});
            stage.close(io);
        }
        try std.testing.expectEqual(case.cdn_calls, fixture.cdn_calls);
        try std.testing.expectEqual(@as(usize, 4) + case.cdn_calls, fixture.calls);
        try std.testing.expectEqual(leases.acquired, leases.released);
    }
}

const ToggleNoRemote = struct {
    http_calls: std.atomic.Value(usize) = .init(0),
    vault_calls: std.atomic.Value(usize) = .init(0),
    preparation_calls: std.atomic.Value(usize) = .init(0),
    fn prepare(context: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: metadata_loader.VanillaTarget, _: instance_preparation.Control) !metadata_loader.PreparedVanilla {
        const self: *ToggleNoRemote = @ptrCast(@alignCast(context.?));
        _ = self.preparation_calls.fetchAdd(1, .monotonic);
        return error.UnexpectedVanillaPreparation;
    }
    fn execute(context: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: http.Request) !http.Response {
        const self: *ToggleNoRemote = @ptrCast(@alignCast(context.?));
        _ = self.http_calls.fetchAdd(1, .monotonic);
        return error.UnexpectedHttpRequest;
    }
    fn store(self: *ToggleNoRemote) credentials.Store {
        return .{ .ctx = self, .vtable = &.{ .put = put, .get = get, .delete = delete } };
    }
    fn touch(context: *anyopaque) void {
        const self: *ToggleNoRemote = @ptrCast(@alignCast(context));
        _ = self.vault_calls.fetchAdd(1, .monotonic);
    }
    fn put(context: *anyopaque, _: []const u8, _: []const u8) credentials.Error!void {
        touch(context);
        return error.Denied;
    }
    fn get(context: *anyopaque, _: std.mem.Allocator, _: []const u8) credentials.Error!credentials.Secret {
        touch(context);
        return error.Denied;
    }
    fn delete(context: *anyopaque, _: []const u8) credentials.Error!void {
        touch(context);
        return error.Denied;
    }
    fn expectUnused(self: *ToggleNoRemote) !void {
        try std.testing.expectEqual(@as(usize, 0), self.http_calls.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), self.vault_calls.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), self.preparation_calls.load(.acquire));
    }
};

fn seedToggleReceipt(dir: std.Io.Dir, records: []const manifest.ManagedFile, bytes: []const u8, membership: ?manifest.PackMembership) !void {
    try dir.createDirPath(io, ".minecraft/versions/Display Name/mods");
    try dir.createDirPath(io, ".vela/instances/stable-id");
    for (records) |record| {
        const physical = try manifest.physicalPath(a, record);
        defer a.free(physical);
        const path = try std.fmt.allocPrint(a, ".minecraft/versions/Display Name/{s}", .{physical});
        defer a.free(path);
        try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
    }
    const receipt = try manifest.serialize(a, .{ .schema_version = manifest.schema_version, .instance_id = selected.id, .pack_version = if (membership) |pack| pack.identity.version_id else "local", .files = records, .pack_membership = membership });
    defer a.free(receipt);
    try dir.writeFile(io, .{ .sub_path = ".vela/instances/stable-id/content.json", .data = receipt });
}

fn expectToggleReceipt(dir: std.Io.Dir, enabled: bool, bytes: []const u8) !void {
    const receipt = try dir.readFileAlloc(io, ".vela/instances/stable-id/content.json", a, .limited(1024 * 1024));
    defer a.free(receipt);
    var document = try manifest.parse(a, receipt);
    defer document.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt, "\"enabled\"") == null);
    const game = try dir.openDir(io, ".minecraft/versions/Display Name", .{ .iterate = true });
    defer game.close(io);
    const observed = try @import("core/content_state.zig").observe(a, io, game, document.value.files);
    defer a.free(observed);
    document.value.files = observed;
    try std.testing.expectEqual(enabled, document.value.files[0].enabled);
    const physical = try manifest.physicalPath(a, document.value.files[0]);
    defer a.free(physical);
    const path = try std.fmt.allocPrint(a, ".minecraft/versions/Display Name/{s}", .{physical});
    defer a.free(path);
    const actual = try dir.readFileAlloc(io, path, a, .limited(1024));
    defer a.free(actual);
    try std.testing.expectEqualStrings(bytes, actual);
    var opposite = document.value.files[0];
    opposite.enabled = !opposite.enabled;
    const counterpart = try manifest.physicalPath(a, opposite);
    defer a.free(counterpart);
    const opposite_path = try std.fmt.allocPrint(a, ".minecraft/versions/Display Name/{s}", .{counterpart});
    defer a.free(opposite_path);
    try std.testing.expectError(error.FileNotFound, dir.statFile(io, opposite_path, .{}));
}

const ToggleCoordinator = @import("core/instance_leases.zig");
fn toggleLease(coordinator: *ToggleCoordinator.Coordinator) install.Lease {
    return .{ .context = coordinator.mutation(0), .acquire = ToggleCoordinator.Mutation.acquireCallback, .recheck = ToggleCoordinator.Mutation.recheckCallback, .release = ToggleCoordinator.Mutation.releaseCallback };
}
fn drainToggle(service: *manager.Manager, coordinator: *ToggleCoordinator.Coordinator) !void {
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 10 * std.time.ns_per_s;
    while (service.isBusy()) {
        coordinator.tick();
        service.tick();
        if (std.Io.Clock.awake.now(io).nanoseconds > deadline) return error.TestTimeout;
        if (service.isBusy()) try io.sleep(.fromMilliseconds(1), .awake);
    }
    coordinator.tick();
}

test "fast mod toggles enforce real leases and preserve standalone and pack ownership" {
    for ([_]manifest.IdentityProvenance{ .official_file, .pack_archive, .pack_override }) |provenance| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var paths = try instances.Paths.init(a, io, root);
        defer paths.deinit();
        var version = try versionFixture(a, .curseforge, "12", "34", "state.jar", "old");
        defer version.deinit();
        const standalone = provenance == .official_file;
        const record: manifest.ManagedFile = .{ .path = "mods/state.jar", .provider = .curseforge, .project_id = "12", .version_id = "34", .hashes = version.value.files[0].hashes, .size = 3, .role = if (provenance == .pack_override) .override else .content, .identity_provenance = provenance, .standalone = standalone };
        const membership: ?manifest.PackMembership = if (standalone) null else .{ .identity = .{ .provider = .curseforge, .project_id = "12", .version_id = "34" }, .paths = &.{record.path} };
        try seedToggleReceipt(tmp.dir, &.{record}, "old", membership);
        var coordinator = ToggleCoordinator.Coordinator.init(io);
        var counters: ToggleNoRemote = .{};
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = toggleLease(&coordinator), .worker_recheck = ToggleCoordinator.Mutation.workerRecheckCallback, .fixture_credential_store = counters.store(), .transport_options = .{ .fixture_http = ToggleNoRemote.execute, .fixture_context = &counters }, .vanilla_preparation = .{ .context = &counters, .prepare = ToggleNoRemote.prepare } });
        defer service.deinit();
        try service.select(selected);
        try drainToggle(&service, &coordinator);
        try expectSuccess(&service);
        try coordinator.reserveLaunch(selected.id);
        try std.testing.expectError(error.InstanceRunning, service.toggleEnabled(record.path, false));
        coordinator.releaseLaunch();
        coordinator.tick();
        const competing = coordinator.mutation(1);
        try competing.acquire(selected.id);
        try std.testing.expectError(error.InstanceBusy, service.toggleEnabled(record.path, false));
        competing.release(selected.id);
        coordinator.tick();
        var requested_path = "mods/state.jar".*;
        try service.toggleEnabled(&requested_path, false);
        @memset(&requested_path, 'x');
        try drainToggle(&service, &coordinator);
        try expectSuccess(&service);
        try expectToggleReceipt(tmp.dir, false, "old");
        try service.toggleEnabled("mods/state.jar.disabled", true);
        try drainToggle(&service, &coordinator);
        try expectSuccess(&service);
        try expectToggleReceipt(tmp.dir, true, "old");
        try counters.expectUnused();
    }
}

test "disabled official standalone choice survives an owned version update and filename change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var old = try versionFixture(a, .modrinth, "project", "old", "state.jar", "old");
    defer old.deinit();
    const record: manifest.ManagedFile = .{ .path = "mods/state.jar", .provider = .modrinth, .project_id = "project", .version_id = "old", .hashes = old.value.files[0].hashes, .size = 3, .enabled = false, .identity_provenance = .official_file };
    try seedToggleReceipt(tmp.dir, &.{record}, "old", null);
    var coordinator = ToggleCoordinator.Coordinator.init(io);
    var counters: ToggleNoRemote = .{};
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = toggleLease(&coordinator), .worker_recheck = ToggleCoordinator.Mutation.workerRecheckCallback, .fixture_credential_store = counters.store(), .transport_options = .{ .fixture_http = ToggleNoRemote.execute, .fixture_context = &counters } });
    defer service.deinit();
    try service.select(selected);
    try drainToggle(&service, &coordinator);
    var updated = try versionFixture(a, .modrinth, "project", "new", "renamed.jar", "new");
    defer updated.deinit();
    try service.prepareVersion(updated.value, .mod, &.{});
    try drainToggle(&service, &coordinator);
    var proposal = try expectProposal(&service);
    try std.testing.expectEqual(@as(usize, 1), proposal.plan.next_manifest.files.len);
    try std.testing.expectEqualStrings("mods/renamed.jar", proposal.plan.next_manifest.files[0].path);
    try std.testing.expect(!proposal.plan.next_manifest.files[0].enabled);
    try tmp.dir.writeFile(io, .{ .sub_path = "replacement.jar", .data = "new" });
    const manual = try tmp.dir.realPathFileAlloc(io, "replacement.jar", a);
    defer a.free(manual);
    try service.resolve(&.{}, &.{}, &.{.{ .path = "mods/renamed.jar", .source_absolute_path = manual }}, &.{});
    try drainToggle(&service, &coordinator);
    proposal = try expectProposal(&service);
    try std.testing.expect(proposal.plan.ready);
    try service.commit();
    try drainToggle(&service, &coordinator);
    try expectSuccess(&service);
    try expectToggleReceipt(tmp.dir, false, "new");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft/versions/Display Name/mods/state.jar.disabled", .{}));
    try std.testing.expectEqualStrings("mods/renamed.jar", service.snapshot().installed[0].path);
    try counters.expectUnused();
}

test "disabled archive and override pack choices survive same path updates but ambiguous identities block" {
    var phase: enum { setup, pack_prepare, pack_review, identity_setup, identity_prepare, identity_review, commit_guard } = .setup;
    var diagnostic_provenance: manifest.IdentityProvenance = .pack_archive;
    errdefer std.debug.print("disabled pack choice {s}/{s}\n", .{ @tagName(diagnostic_provenance), @tagName(phase) });
    for ([_]manifest.IdentityProvenance{ .pack_archive, .pack_override }) |provenance| {
        diagnostic_provenance = provenance;
        phase = .setup;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var paths = try instances.Paths.init(a, io, root);
        defer paths.deinit();
        var old = try versionFixture(a, .modrinth, "pack", "old", "state.jar", "old");
        defer old.deinit();
        const record: manifest.ManagedFile = .{ .path = "mods/state.jar", .provider = .modrinth, .project_id = "pack", .version_id = "old", .hashes = old.value.files[0].hashes, .size = 3, .enabled = false, .role = if (provenance == .pack_override) .override else .content, .identity_provenance = provenance, .standalone = false };
        try seedToggleReceipt(tmp.dir, &.{record}, "old", .{ .identity = .{ .provider = .modrinth, .project_id = "pack", .version_id = "old" }, .paths = &.{record.path} });
        var digest: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash("new", &digest, .{});
        const hash = std.fmt.bytesToHex(digest, .lower);
        var sha1_digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash("new", &sha1_digest, .{});
        const sha1_hash = std.fmt.bytesToHex(sha1_digest, .lower);
        const IndexFile = struct { path: []const u8, hashes: struct { sha1: []const u8, sha512: []const u8 }, downloads: []const []const u8, fileSize: u64 };
        const entries = [_]IndexFile{.{ .path = record.path, .hashes = .{ .sha1 = &sha1_hash, .sha512 = &hash }, .downloads = &.{"https://cdn.modrinth.com/data/pack/new/state.jar"}, .fileSize = 3 }};
        const index_files: []const IndexFile = if (provenance == .pack_archive) &entries else &.{};
        const index = try std.json.Stringify.valueAlloc(a, .{ .formatVersion = @as(u32, 1), .game = "minecraft", .versionId = "new", .name = "Pack", .files = index_files, .dependencies = .{ .minecraft = selected.minecraft_version } }, .{});
        defer a.free(index);
        if (provenance == .pack_archive) {
            try storedZip(tmp.dir, "update.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = index }});
        } else {
            try storedZip(tmp.dir, "update.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = index }, .{ .path = "overrides/mods/state.jar", .bytes = "new" } });
        }
        const archive = try tmp.dir.realPathFileAlloc(io, "update.mrpack", a);
        defer a.free(archive);
        var counters: ToggleNoRemote = .{};
        var leases: LeaseState = .{};
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .fixture_credential_store = counters.store(), .transport_options = .{ .fixture_http = ToggleNoRemote.execute, .fixture_context = &counters } });
        defer service.deinit();
        try service.select(selected);
        try drain(&service);
        phase = .pack_prepare;
        try service.importPackFor(archive, .{ .provider = .modrinth, .project_id = "pack", .version_id = "new" });
        try drain(&service);
        phase = .pack_review;
        const proposal = try expectProposal(&service);
        try std.testing.expectEqual(@as(usize, 1), proposal.plan.next_manifest.files.len);
        const updated = proposal.plan.next_manifest.files[0];
        try std.testing.expect(!updated.enabled and !updated.standalone);
        try std.testing.expectEqual(provenance, updated.identity_provenance);
        try std.testing.expectEqualStrings(record.path, updated.path);
        try std.testing.expectEqualStrings("new", proposal.plan.next_manifest.pack_membership.?.identity.version_id);
        try std.testing.expectEqualStrings(record.path, proposal.plan.next_manifest.pack_membership.?.paths[0]);
        try counters.expectUnused();
    }
    phase = .identity_setup;
    diagnostic_provenance = .official_file;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var old = try versionFixture(a, .modrinth, "project", "old", "state.jar", "old");
    defer old.deinit();
    const record: manifest.ManagedFile = .{ .path = "mods/state.jar", .provider = .modrinth, .project_id = "project", .version_id = "old", .hashes = old.value.files[0].hashes, .size = 3, .enabled = false, .identity_provenance = .official_file };
    var second = record;
    second.path = "mods/second.jar";
    second.enabled = true;
    try seedToggleReceipt(tmp.dir, &.{ record, second }, "old", null);
    var leases: LeaseState = .{};
    var counters: ToggleNoRemote = .{};
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .transport_options = .{ .fixture_http = ToggleNoRemote.execute, .fixture_context = &counters } });
    defer service.deinit();
    try service.select(selected);
    try drain(&service);
    var updated = try versionFixture(a, .modrinth, "project", "new", "renamed.jar", "new");
    defer updated.deinit();
    phase = .identity_prepare;
    try service.prepareVersion(updated.value, .mod, &.{});
    try drain(&service);
    phase = .identity_review;
    const proposal = try expectProposal(&service);
    try std.testing.expectEqual(error.DisabledIdentityUnresolved, proposal.blocker.?);
    try std.testing.expect(!proposal.plan.ready);
    phase = .commit_guard;
    try std.testing.expectError(error.IncompleteContent, service.commit());
    try counters.expectUnused();
}

test "a disabled verified required dependency keeps the proposed root unready" {
    var phase: enum { setup, dependency_prepare, dependency_review, commit_guard, persisted_state } = .setup;
    errdefer std.debug.print("disabled required dependency {s}\n", .{@tagName(phase)});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var dependency = try versionFixture(a, .modrinth, "dep", "dep-v1", "state.jar", "old");
    defer dependency.deinit();
    const record: manifest.ManagedFile = .{ .path = "mods/state.jar", .provider = .modrinth, .project_id = "dep", .version_id = "dep-v1", .hashes = dependency.value.files[0].hashes, .size = 3, .enabled = false, .identity_provenance = .official_file };
    try seedToggleReceipt(tmp.dir, &.{record}, "old", null);
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash("old", &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const metadata = try std.json.Stringify.valueAlloc(a, .{ .id = "dep-v1", .project_id = "dep", .name = "Dependency", .game_versions = [_][]const u8{selected.minecraft_version}, .loaders = [_][]const u8{"minecraft"}, .files = .{.{ .filename = "state.jar", .primary = true, .url = "https://cdn.modrinth.com/data/dep/dep-v1/state.jar", .hashes = .{ .sha512 = &hash }, .size = @as(u64, 3) }}, .dependencies = [_]std.json.Value{} }, .{});
    defer a.free(metadata);
    var fixture: HttpFixture = .{ .body = metadata };
    var leases: LeaseState = .{};
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = leases.lease(), .transport_options = .{ .fixture_http = HttpFixture.execute, .fixture_context = &fixture } });
    defer service.deinit();
    try service.select(selected);
    try drain(&service);
    var candidate = try versionFixture(a, .modrinth, "root", "root-v1", "root.jar", "new");
    defer candidate.deinit();
    candidate.value.dependencies = &.{.{ .kind = .required, .project_id = "dep", .version_id = "dep-v1" }};
    phase = .dependency_prepare;
    try service.prepareVersion(candidate.value, .mod, &.{});
    try drain(&service);
    phase = .dependency_review;
    const proposal = try expectProposal(&service);
    try std.testing.expectEqual(error.DisabledRequiredDependency, proposal.blocker.?);
    try std.testing.expect(!proposal.plan.ready and !proposal.plan.fully_applied);
    var found_disabled = false;
    for (proposal.plan.next_manifest.files) |file| if (std.mem.eql(u8, file.project_id, "dep")) {
        found_disabled = !file.enabled;
    };
    try std.testing.expect(found_disabled);
    phase = .commit_guard;
    try std.testing.expectError(error.IncompleteContent, service.commit());
    phase = .persisted_state;
    const existing = try tmp.dir.readFileAlloc(io, ".minecraft/versions/Display Name/mods/state.jar.disabled", a, .limited(1024));
    defer a.free(existing);
    try std.testing.expectEqualStrings("old", existing);
}

const PreflightFixture = struct {
    descriptor: []u8,
    pin: game_metadata.Sha1,
    calls: std.atomic.Value(usize) = .init(0),
    generation: std.atomic.Value(u64) = .init(0),
    entered: std.atomic.Value(bool) = .init(false),
    wait_for_cancel: bool = false,
    poison: ?*std.atomic.Value(bool) = null,

    fn init(dir: std.Io.Dir, instance: config.Instance) !PreflightFixture {
        if (builtin.os.tag != .linux) return error.SkipZigTest;
        const machine: u16 = switch (builtin.cpu.arch) {
            .x86_64 => 62,
            .aarch64 => 183,
            else => return error.SkipZigTest,
        };
        var elf: [64]u8 = @splat(0);
        @memcpy(elf[0..4], "\x7fELF");
        elf[4] = 2;
        elf[5] = 1;
        elf[6] = 1;
        std.mem.writeInt(u16, elf[16..18], 3, .little);
        std.mem.writeInt(u16, elf[18..20], machine, .little);
        std.mem.writeInt(u32, elf[20..24], 1, .little);
        std.mem.writeInt(u16, elf[52..54], 64, .little);
        try storedZip(dir, "preflight-native.jar", &.{.{ .path = "fixture.so", .bytes = &elf }});
        const native = try dir.readFileAlloc(io, "preflight-native.jar", a, .limited(1024 * 1024));
        defer a.free(native);
        const index = try std.json.Stringify.valueAlloc(a, .{ .objects = .{ .fixture = .{ .hash = &sha1("asset"), .size = @as(u64, 5) } } }, .{});
        defer a.free(index);
        const Download = struct { url: []const u8, path: []const u8, sha1: []const u8, size: u64 };
        const Library = struct { name: []const u8, downloads: struct { artifact: Download } };
        const libraries = [_]Library{
            .{ .name = "example:fixture:1", .downloads = .{ .artifact = .{ .url = "https://libraries.minecraft.net/example/fixture/library.jar", .path = "example/fixture/library.jar", .sha1 = &sha1("library"), .size = 7 } } },
            .{ .name = "example:fixture:1:natives-linux", .downloads = .{ .artifact = .{ .url = "https://libraries.minecraft.net/example/fixture/native.jar", .path = "example/fixture/native.jar", .sha1 = &sha1(native), .size = native.len } } },
        };
        const descriptor = try std.json.Stringify.valueAlloc(a, .{
            .id = instance.name,
            .mainClass = "net.minecraft.client.main.Main",
            .javaVersion = .{ .component = "java-runtime-gamma", .majorVersion = @as(u64, 17) },
            .downloads = .{ .client = .{ .url = "https://piston-data.mojang.com/v1/objects/fixture/client.jar", .sha1 = &sha1("client"), .size = @as(u64, 6) } },
            .assetIndex = .{ .id = "fixture", .url = "https://piston-meta.mojang.com/v1/packages/fixture/assets.json", .sha1 = &sha1(index), .size = index.len },
            .libraries = libraries,
        }, .{});
        errdefer a.free(descriptor);
        const game_dir = try std.fmt.allocPrint(a, ".minecraft/versions/{s}", .{instance.name});
        defer a.free(game_dir);
        try dir.createDirPath(io, game_dir);
        const descriptor_name = try std.fmt.allocPrint(a, "{s}.json", .{instance.name});
        defer a.free(descriptor_name);
        const client_name = try std.fmt.allocPrint(a, "{s}.jar", .{instance.name});
        defer a.free(client_name);
        try writeGameFile(dir, instance, descriptor_name, descriptor);
        try writeGameFile(dir, instance, client_name, "client");
        try dir.createDirPath(io, ".minecraft/assets/indexes");
        try dir.createDirPath(io, ".minecraft/libraries/example/fixture");
        try dir.writeFile(io, .{ .sub_path = ".minecraft/assets/indexes/fixture.json", .data = index });
        try dir.writeFile(io, .{ .sub_path = ".minecraft/libraries/example/fixture/library.jar", .data = "library" });
        try dir.writeFile(io, .{ .sub_path = ".minecraft/libraries/example/fixture/native.jar", .data = native });
        const asset_hash = sha1("asset");
        const asset_dir = try std.fmt.allocPrint(a, ".minecraft/assets/objects/{s}", .{asset_hash[0..2]});
        defer a.free(asset_dir);
        try dir.createDirPath(io, asset_dir);
        const asset_path = try assetPath();
        defer a.free(asset_path);
        try dir.writeFile(io, .{ .sub_path = asset_path, .data = "asset" });
        const index_json = try std.json.Stringify.valueAlloc(a, .{ .formatVersion = @as(u32, 1), .game = "minecraft", .versionId = "fixture", .name = "Fixture", .files = [_]std.json.Value{}, .dependencies = .{ .minecraft = instance.minecraft_version } }, .{});
        defer a.free(index_json);
        try storedZip(dir, "preflight.mrpack", &.{ .{ .path = "modrinth.index.json", .bytes = index_json }, .{ .path = "overrides/config/preflight.cfg", .bytes = "payload" } });
        var pin: game_metadata.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(descriptor, &pin, .{});
        return .{ .descriptor = descriptor, .pin = pin };
    }

    fn deinit(self: *PreflightFixture) void {
        a.free(self.descriptor);
    }
    fn gamePath(instance: config.Instance, filename: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, ".minecraft/versions/{s}/{s}", .{ instance.name, filename });
    }
    fn writeGameFile(dir: std.Io.Dir, instance: config.Instance, filename: []const u8, bytes: []const u8) !void {
        const path = try gamePath(instance, filename);
        defer a.free(path);
        try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
    }
    fn assetPath() ![]u8 {
        const hash = sha1("asset");
        return std.fmt.allocPrint(a, ".minecraft/assets/objects/{s}/{s}", .{ hash[0..2], &hash });
    }
    fn adapter(self: *PreflightFixture) instance_preparation.VanillaPreparationAdapter {
        return .{ .context = self, .prepare = prepare };
    }
    fn fetchSource(context: ?*anyopaque, allocator: std.mem.Allocator, _: std.Io, _: metadata_loader.Request) ![]u8 {
        const self: *PreflightFixture = @ptrCast(@alignCast(context.?));
        return allocator.dupe(u8, self.descriptor);
    }
    fn prepare(context: ?*anyopaque, allocator: std.mem.Allocator, worker_io: std.Io, target: metadata_loader.VanillaTarget, control: instance_preparation.Control) !metadata_loader.PreparedVanilla {
        const self: *PreflightFixture = @ptrCast(@alignCast(context.?));
        _ = self.calls.fetchAdd(1, .monotonic);
        if (target.generation == 0 or target.generation != (control.task orelse return error.InvalidPreparationGeneration).id) return error.InvalidPreparationGeneration;
        self.generation.store(target.generation, .release);
        try control.check();
        const entries = [_]game_metadata.manifest.Entry{.{ .id = target.version_id, .kind = "release", .url = "https://piston-meta.mojang.com/v1/packages/fixture/version.json", .time = "", .release_time = "", .sha1 = self.pin, .compliance_level = null }};
        var prepared = try metadata_loader.prepareVanilla(allocator, worker_io, .{
            .target = target,
            .vanilla = .{ .version_id = target.version_id, .cancel = control.cancel, .manifest = .{ .latest = .{ .release = target.version_id, .snapshot = target.version_id }, .versions = &entries } },
            .fetcher = .{ .context = self, .fetch = fetchSource },
        });
        errdefer prepared.deinit();
        if (self.poison) |flag| flag.store(true, .release);
        if (self.wait_for_cancel) {
            self.entered.store(true, .release);
            while (true) {
                try control.check();
                try worker_io.sleep(.fromMilliseconds(1), .awake);
            }
        }
        try control.check();
        return prepared;
    }
};

const PreflightLease = struct {
    base: install.Lease,
    fail_recheck: std.atomic.Value(bool) = .init(false),
    fn lease(self: *PreflightLease) install.Lease {
        return .{ .context = self, .acquire = acquire, .recheck = recheck, .release = release };
    }
    fn acquire(context: ?*anyopaque, id: []const u8) !void {
        const self: *PreflightLease = @ptrCast(@alignCast(context.?));
        try self.base.acquire(self.base.context, id);
    }
    fn recheck(context: ?*anyopaque, id: []const u8) !void {
        const self: *PreflightLease = @ptrCast(@alignCast(context.?));
        try self.base.recheck(self.base.context, id);
        if (self.fail_recheck.load(.acquire)) return error.LeaseNotHeld;
    }
    fn release(context: ?*anyopaque, id: []const u8) void {
        const self: *PreflightLease = @ptrCast(@alignCast(context.?));
        self.base.release(self.base.context, id);
    }
};

test "canonical vanilla content preflight authenticates the real factory without weakening game readiness" {
    const Mode = enum { complete, metadata_tamper, client_hash, client_size, invalid_receipt, noncanonical, nonvanilla, missing_library, missing_native, missing_index, missing_asset, index_tamper, asset_tamper, late_lease };
    for (std.enums.values(Mode)) |mode| {
        var phase: enum { setup, prepare, review, commit, persisted_state } = .setup;
        errdefer std.debug.print("vanilla content preflight {s}/{s}\n", .{ @tagName(mode), @tagName(phase) });
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var paths = try instances.Paths.init(a, io, root);
        defer paths.deinit();
        var instance = selected;
        instance.name = if (mode == .noncanonical) selected.name else selected.minecraft_version;
        if (mode == .nonvanilla) {
            instance.loader = .fabric;
            instance.loader_version = "0.16.10";
        }
        var fixture = try PreflightFixture.init(tmp.dir, instance);
        defer fixture.deinit();
        const descriptor_name = try std.fmt.allocPrint(a, "{s}.json", .{instance.name});
        defer a.free(descriptor_name);
        const client_name = try std.fmt.allocPrint(a, "{s}.jar", .{instance.name});
        defer a.free(client_name);
        var coordinator = @import("core/instance_leases.zig").Coordinator.init(io);
        var guard: PreflightLease = .{ .base = toggleLease(&coordinator) };
        switch (mode) {
            .metadata_tamper => {
                const changed = try std.fmt.allocPrint(a, "{s}\n", .{fixture.descriptor});
                defer a.free(changed);
                try PreflightFixture.writeGameFile(tmp.dir, instance, descriptor_name, changed);
            },
            .client_hash => try PreflightFixture.writeGameFile(tmp.dir, instance, client_name, "clienT"),
            .client_size => try PreflightFixture.writeGameFile(tmp.dir, instance, client_name, "short"),
            .invalid_receipt => try PreflightFixture.writeGameFile(tmp.dir, instance, ".vela-instance.json", "{}"),
            .missing_library => try tmp.dir.deleteFile(io, ".minecraft/libraries/example/fixture/library.jar"),
            .missing_native => try tmp.dir.deleteFile(io, ".minecraft/libraries/example/fixture/native.jar"),
            .missing_index => try tmp.dir.deleteFile(io, ".minecraft/assets/indexes/fixture.json"),
            .missing_asset, .asset_tamper => {
                const path = try PreflightFixture.assetPath();
                defer a.free(path);
                if (mode == .missing_asset) try tmp.dir.deleteFile(io, path) else try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "Asset" });
            },
            .index_tamper => {
                const bytes = try tmp.dir.readFileAlloc(io, ".minecraft/assets/indexes/fixture.json", a, .limited(1024));
                defer a.free(bytes);
                bytes[2] = 'O';
                try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/assets/indexes/fixture.json", .data = bytes });
            },
            .late_lease => fixture.poison = &guard.fail_recheck,
            else => {},
        }
        var counters: ToggleNoRemote = .{};
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = guard.lease(), .fixture_credential_store = counters.store(), .transport_options = .{ .fixture_http = ToggleNoRemote.execute, .fixture_context = &counters }, .vanilla_preparation = fixture.adapter() });
        defer service.deinit();
        try service.select(instance);
        try drainToggle(&service, &coordinator);
        try expectSuccess(&service);
        const archive = try tmp.dir.realPathFileAlloc(io, "preflight.mrpack", a);
        defer a.free(archive);
        phase = .prepare;
        try service.importPackFor(archive, .{ .provider = .modrinth, .project_id = "pack", .version_id = "fixture" });
        try drainToggle(&service, &coordinator);
        phase = .review;
        const expected_calls: usize = if (mode == .invalid_receipt or mode == .noncanonical or mode == .nonvanilla) 0 else 1;
        try std.testing.expectEqual(expected_calls, fixture.calls.load(.acquire));
        if (expected_calls != 0) try std.testing.expect(fixture.generation.load(.acquire) != 0);
        if (mode == .complete) {
            const proposal = try expectProposal(&service);
            try std.testing.expect(proposal.ready and proposal.prerequisites.loader_ready);
            const first_generation = fixture.generation.load(.acquire);
            phase = .commit;
            try service.commit();
            try drainToggle(&service, &coordinator);
            try expectSuccess(&service);
            try std.testing.expectEqual(@as(usize, 2), fixture.calls.load(.acquire));
            try std.testing.expect(fixture.generation.load(.acquire) != first_generation);
            phase = .persisted_state;
            const installed_path = try PreflightFixture.gamePath(instance, "config/preflight.cfg");
            defer a.free(installed_path);
            const installed = try tmp.dir.readFileAlloc(io, installed_path, a, .limited(1024));
            defer a.free(installed);
            try std.testing.expectEqualStrings("payload", installed);
            const metadata_path = try PreflightFixture.gamePath(instance, descriptor_name);
            defer a.free(metadata_path);
            const unchanged = try tmp.dir.readFileAlloc(io, metadata_path, a, .limited(1024 * 1024));
            defer a.free(unchanged);
            try std.testing.expectEqualStrings(fixture.descriptor, unchanged);
        } else {
            const snapshot = service.snapshot();
            const failure = if (snapshot.proposal) |proposal| blk: {
                try std.testing.expect(!proposal.ready);
                try std.testing.expectError(error.IncompleteContent, service.commit());
                break :blk proposal.blocker orelse return error.MissingPreflightBlocker;
            } else snapshot.failure orelse return error.MissingPreflightBlocker;
            const expected: ?anyerror = switch (mode) {
                .metadata_tamper => error.PreparedMetadataChanged,
                .client_hash => error.ClientHashMismatch,
                .client_size => error.ClientSizeMismatch,
                .invalid_receipt => error.InvalidInstallReceipt,
                .missing_library, .missing_native, .missing_index, .missing_asset => error.MissingGamePrerequisite,
                .index_tamper, .asset_tamper => error.HashMismatch,
                .late_lease => error.LeaseNotHeld,
                else => null,
            };
            if (expected) |err| try std.testing.expectEqual(err, failure);
            const installed_path = try PreflightFixture.gamePath(instance, "config/preflight.cfg");
            defer a.free(installed_path);
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, installed_path, .{}));
        }
        if (mode != .invalid_receipt) {
            const receipt_path = try PreflightFixture.gamePath(instance, ".vela-instance.json");
            defer a.free(receipt_path);
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, receipt_path, .{}));
        }
        try counters.expectUnused();
    }
}

test "canceling canonical vanilla content preparation joins the owned factory and releases the real lease" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var instance = selected;
    instance.name = instance.minecraft_version;
    var fixture = try PreflightFixture.init(tmp.dir, instance);
    defer fixture.deinit();
    fixture.wait_for_cancel = true;
    var coordinator = @import("core/instance_leases.zig").Coordinator.init(io);
    var counters: ToggleNoRemote = .{};
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = toggleLease(&coordinator), .fixture_credential_store = counters.store(), .transport_options = .{ .fixture_http = ToggleNoRemote.execute, .fixture_context = &counters }, .vanilla_preparation = fixture.adapter() });
    defer service.deinit();
    try service.select(instance);
    try drainToggle(&service, &coordinator);
    const archive = try tmp.dir.realPathFileAlloc(io, "preflight.mrpack", a);
    defer a.free(archive);
    try service.importPackFor(archive, .{ .provider = .modrinth, .project_id = "pack", .version_id = "fixture" });
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 10 * std.time.ns_per_s;
    while (!fixture.entered.load(.acquire)) {
        service.tick();
        if (std.Io.Clock.awake.now(io).nanoseconds > deadline) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch(instance.id));
    service.cancelAndJoin();
    try std.testing.expect(service.active == null and !service.isBusy());
    coordinator.tick();
    try coordinator.reserveLaunch(instance.id);
    coordinator.releaseLaunch();
    coordinator.tick();
    try std.testing.expectEqual(@as(usize, 1), fixture.calls.load(.acquire));
    try counters.expectUnused();
    const installed_path = try PreflightFixture.gamePath(instance, "config/preflight.cfg");
    defer a.free(installed_path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, installed_path, .{}));
}

test "fast mod toggles preserve receipt bytes and reload physical disabled state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var version = try versionFixture(a, .modrinth, "project", "old", "Example.JAR", "old");
    defer version.deinit();
    const record: manifest.ManagedFile = .{ .path = "mods/Example.JAR", .provider = .modrinth, .project_id = "project", .version_id = "old", .hashes = version.value.files[0].hashes, .size = 3, .identity_provenance = .official_file };
    try seedToggleReceipt(tmp.dir, &.{record}, "old", null);
    const receipt_path = ".vela/instances/stable-id/content.json";
    const before = try tmp.dir.readFileAlloc(io, receipt_path, a, .limited(1024 * 1024));
    defer a.free(before);
    const before_stat = try tmp.dir.statFile(io, receipt_path, .{});
    var coordinator = ToggleCoordinator.Coordinator.init(io);
    var registry = tasks.Registry.init(a);
    defer registry.deinit();
    {
        var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = toggleLease(&coordinator), .worker_recheck = ToggleCoordinator.Mutation.workerRecheckCallback });
        defer service.deinit();
        try service.select(selected);
        try drainToggle(&service, &coordinator);
        try expectSuccess(&service);
        try service.toggleEnabled(record.path, false);
        try drainToggle(&service, &coordinator);
        try expectSuccess(&service);
        try std.testing.expect(!service.snapshot().installed[0].enabled);
        try expectToggleReceipt(tmp.dir, false, "old");
    }
    {
        var reloaded = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = toggleLease(&coordinator), .worker_recheck = ToggleCoordinator.Mutation.workerRecheckCallback });
        defer reloaded.deinit();
        try reloaded.select(selected);
        try drainToggle(&reloaded, &coordinator);
        try expectSuccess(&reloaded);
        try std.testing.expect(!reloaded.snapshot().installed[0].enabled);
        try reloaded.toggleEnabled("mods/Example.JAR.disabled", true);
        try drainToggle(&reloaded, &coordinator);
        try expectSuccess(&reloaded);
        try std.testing.expect(reloaded.snapshot().installed[0].enabled);
        try expectToggleReceipt(tmp.dir, true, "old");
    }
    const after = try tmp.dir.readFileAlloc(io, receipt_path, a, .limited(1024 * 1024));
    defer a.free(after);
    const after_stat = try tmp.dir.statFile(io, receipt_path, .{});
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(before_stat.inode, after_stat.inode);
    try std.testing.expectEqual(before_stat.mtime.nanoseconds, after_stat.mtime.nanoseconds);
}

test "content manager rejects old receipt versions without rewriting source" {
    for ([_]u32{ 1, 2 }) |version| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var paths = try instances.Paths.init(a, io, root);
        defer paths.deinit();
        try seedToggleReceipt(tmp.dir, &.{}, "old", null);
        const receipt = try std.fmt.allocPrint(a, "{{\"schema_version\":{d},\"instance_id\":\"stable-id\",\"pack_version\":\"local\",\"files\":[]}}", .{version});
        defer a.free(receipt);
        const receipt_path = ".vela/instances/stable-id/content.json";
        try tmp.dir.writeFile(io, .{ .sub_path = receipt_path, .data = receipt });
        var coordinator = ToggleCoordinator.Coordinator.init(io);
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var service = try manager.Manager.initOptions(a, io, &paths, &registry, .{ .lease = toggleLease(&coordinator), .worker_recheck = ToggleCoordinator.Mutation.workerRecheckCallback });
        defer service.deinit();
        try service.select(selected);
        try drainToggle(&service, &coordinator);
        try std.testing.expectEqual(error.UnsupportedSchema, service.snapshot().failure.?);
        const actual = try tmp.dir.readFileAlloc(io, receipt_path, a, .limited(1024 * 1024));
        defer a.free(actual);
        try std.testing.expectEqualStrings(receipt, actual);
    }
}
