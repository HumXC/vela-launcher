//! Source-only fakes: no native picker, HTTP, Java execution or credentials.
const std = @import("std");
const config = @import("core/config.zig");
const paths_mod = @import("core/instances.zig");
const packs = @import("core/pack_import.zig");
const manifest = @import("core/content_manifest.zig");
const providers = @import("core/content_providers.zig");
const controller_mod = @import("ui/pack_import_controller.zig");
const view = @import("ui/pack_import_view.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const Fixture = struct {
    inspected: std.atomic.Value(usize) = .init(0),
    cleaned: std.atomic.Value(usize) = .init(0),
    picked: std.atomic.Value(bool) = .init(false),
    release_picker: std.atomic.Value(bool) = .init(true),
    release_inspection: std.atomic.Value(bool) = .init(true),
    inspection_failure: ?anyerror = null,
    cleanup_failure: ?anyerror = null,
    provider: providers.Provider = .modrinth,
    loader: config.Loader = .fabric,
    loader_version: ?[]const u8 = "0.15.7",
    owned_state: controller_mod.Snapshot = .{ .phase = .idle, .failure = null, .cleanup_failure = null, .preparation_generation = 0, .serial = 0, .role = null, .runtime_major = null, .installer_major = null, .instance = null, .archive_sha256 = null, .content_ready = false },
    drained: [4]usize = @splat(0),
    drain_failure: ?anyerror = null,
    fn runner(self: *Fixture) view.Runner {
        return .{ .context = self, .pick = pick, .inspect = inspect, .cleanup = cleanup, .owned_snapshot = ownedSnapshot, .drain = drain };
    }
    fn ownedSnapshot(raw: ?*anyopaque, _: *const controller_mod.Controller) controller_mod.Snapshot {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        return self.owned_state;
    }
    fn drain(raw: ?*anyopaque, action: view.OwnedAction, store: *config.Store, _: *controller_mod.Controller, services: controller_mod.Services) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        if (services.store != store) return error.WrongStore;
        self.drained[@intFromEnum(action)] += 1;
        if (self.drain_failure) |err| return err;
    }
    fn pick(raw: ?*anyopaque, allocator: std.mem.Allocator) !?[:0]const u8 {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.picked.store(true, .release);
        while (!self.release_picker.load(.acquire)) std.Thread.yield() catch {};
        return try allocator.dupeZ(u8, "/fake/original.mrpack");
    }
    fn inspect(raw: ?*anyopaque, allocator: std.mem.Allocator, _: std.Io, paths: *const paths_mod.Paths, source: []const u8, cancellation: ?*const packs.CancelToken) !packs.Inspection {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        _ = self.inspected.fetchAdd(1, .acq_rel);
        if (!std.mem.eql(u8, source, "/fake/original.mrpack")) return error.WrongArchivePath;
        while (!self.release_inspection.load(.acquire)) {
            if (cancellation.?.load(.acquire)) return error.Canceled;
            std.Thread.yield() catch {};
        }
        if (self.inspection_failure) |err| return err;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        var parsed_arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer parsed_arena.deinit();
        const aa = arena.allocator();
        const pa = parsed_arena.allocator();
        const sha: [64]u8 = @splat('a');
        const stage = try std.fs.path.join(aa, &.{ paths.vela, "pack-import-stage", "import-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" });
        const plan: manifest.PackPlan = .{
            .identity = .{ .provider = self.provider, .project_id = try std.fmt.allocPrint(pa, "local-{s}", .{sha}), .version_id = try pa.dupe(u8, &sha) },
            .name = try pa.dupe(u8, "Fixture pack"),
            .version = try pa.dupe(u8, "v1"),
            .minecraft_version = try pa.dupe(u8, "1.20.1"),
            .loader = self.loader,
            .loader_version = if (self.loader_version) |version| try pa.dupe(u8, version) else null,
        };
        const archive = try std.fs.path.join(aa, &.{ stage, "pack.mrpack" });
        // This is a fake Inspection, not a successful game/content prerequisite.
        return .{ .arena = arena, .parsed = .{ .arena = parsed_arena, .value = plan }, .pack = plan, .provider = self.provider, .source_sha256 = sha, .stage_absolute_path = stage, .archive_absolute_path = archive };
    }
    fn cleanup(raw: ?*anyopaque, _: std.Io, inspection: *const packs.Inspection) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        if (!std.mem.endsWith(u8, inspection.stage_absolute_path, "import-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")) return error.WrongStage;
        _ = self.cleaned.fetchAdd(1, .acq_rel);
        if (self.cleanup_failure) |err| return err;
    }
};
const Harness = struct {
    tmp: std.testing.TmpDir,
    root: [:0]const u8,
    store: config.Store,
    controller: controller_mod.Controller,
    ui: view.Ui,
    fn init(fixture: *Fixture, extra: view.Options) !Harness {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        errdefer a.free(root);
        var store = try config.Store.init(a, io, root);
        errdefer store.deinit();
        var controller = try controller_mod.Controller.init(a, io, root, .{});
        errdefer controller.deinit(undefined);
        var options = extra;
        options.runner = fixture.runner();
        return .{ .tmp = tmp, .root = root, .store = store, .controller = controller, .ui = try view.Ui.initOptions(a, io, root, options) };
    }
    fn deinit(self: *Harness) void {
        self.controller.deinit(undefined);
        self.ui.deinit();
        self.store.deinit();
        a.free(self.root);
        self.tmp.cleanup();
    }
    // These tests never admit a valid prerequisite request. Non-dereferenceable
    // manager identities let owned dispatch compare services without fake I/O.
    fn services(self: *Harness) controller_mod.Services {
        return .{ .store = &self.store, .java = @ptrFromInt(0x1000), .java_download = @ptrFromInt(0x2000), .instances = @ptrFromInt(0x3000), .content = @ptrFromInt(0x4000) };
    }
    fn finish(self: *Harness, blocked: bool) void {
        view.finish(&self.ui, &self.store, &self.controller, self.services(), blocked);
    }
    fn start(self: *Harness) !void {
        view.open(&self.ui);
        try self.ui.queueArchive("/fake/original.mrpack");
        self.finish(false);
    }
    fn waitPreview(self: *Harness) !void {
        const deadline = std.Io.Clock.awake.now(io).nanoseconds + 10 * std.time.ns_per_s;
        while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
            self.ui.tick(&self.controller);
            if (self.ui.failure != null) return error.PreviewFailed;
            if (self.ui.preview) |preview| if (preview.thread == null and !preview.cleanup_requested and self.ui.draft.base != null) return;
            std.Thread.yield() catch {};
        }
        return error.TestTimeout;
    }
    fn waitIdle(self: *Harness) !void {
        const deadline = std.Io.Clock.awake.now(io).nanoseconds + 10 * std.time.ns_per_s;
        while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
            self.ui.tick(&self.controller);
            if (!self.ui.isBusy()) return;
            std.Thread.yield() catch {};
        }
        return error.TestTimeout;
    }
};
fn waitFlag(flag: *const std.atomic.Value(bool)) !void {
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 10 * std.time.ns_per_s;
    while (!flag.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.TestTimeout;
        std.Thread.yield() catch {};
    }
}
const exact_row: config.Instance = .{ .id = "existing-id", .name = "Existing", .minecraft_version = "1.20.1", .loader = .fabric, .loader_version = "0.15.7" };

test "preview owns auto tuple local identity and private archive until cleanup" {
    var fixture: Fixture = .{};
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    try harness.start();
    try harness.waitPreview();
    const inspection = &harness.ui.preview.?.inspection.?;
    try std.testing.expectEqualStrings("1.20.1", harness.ui.draft.base.?);
    try std.testing.expectEqual(config.Loader.fabric, harness.ui.draft.loader);
    try std.testing.expectEqualStrings("0.15.7", harness.ui.draft.loader_version.?);
    try std.testing.expect(std.mem.startsWith(u8, inspection.pack.identity.project_id, "local-"));
    try std.testing.expectEqualStrings(&inspection.source_sha256, inspection.pack.identity.version_id);
    try std.testing.expect(!std.mem.eql(u8, "/fake/original.mrpack", inspection.archive_absolute_path));
    try std.testing.expect(!harness.ui.isBusy());
    try std.testing.expectEqual(@as(usize, 0), fixture.cleaned.load(.acquire));
    try harness.ui.queueOwned(.close, &harness.controller);
    harness.finish(false);
    try harness.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), fixture.cleaned.load(.acquire));
    try std.testing.expect(harness.ui.preview == null);
}

test "vanilla preview remains vanilla and never guesses Fabric" {
    var fixture: Fixture = .{ .loader = .vanilla, .loader_version = null };
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    try harness.start();
    try harness.waitPreview();
    try std.testing.expectEqual(config.Loader.vanilla, harness.ui.draft.loader);
    try std.testing.expect(harness.ui.draft.loader_version == null);
    const row = try harness.ui.draft.value(.create, harness.store.snapshot());
    try std.testing.expect(view.matchesPack(row, harness.ui.preview.?.inspection.?.pack));
}

test "deferred archive command copies path before caller mutates it" {
    var fixture: Fixture = .{};
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    view.open(&harness.ui);
    var original = "/fake/original.mrpack".*;
    try harness.ui.queueArchive(&original);
    @memset(&original, 'x');
    harness.finish(false);
    try harness.waitPreview();
    try std.testing.expectEqual(@as(usize, 1), fixture.inspected.load(.acquire));
}

test "blocked commands are discarded without worker or delayed replay" {
    var fixture: Fixture = .{};
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    view.open(&harness.ui);
    try harness.ui.queueArchive("/fake/original.mrpack");
    harness.finish(true);
    harness.finish(false);
    try std.testing.expect(harness.ui.pending == null and harness.ui.preview == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.inspected.load(.acquire));
    harness.ui.pending = .confirm;
    harness.finish(true);
    try std.testing.expect(harness.ui.pending == null);
}

test "cleanup reservation and inspect spawn failures cannot create a private stage" {
    const faults = [_]view.Options{
        .{ .fixture_cleanup_spawn_failure = error.FakeCleanupSpawn },
        .{ .fixture_inspect_spawn_failure = error.FakeInspectSpawn },
    };
    for (faults) |options| {
        var fixture: Fixture = .{};
        var harness = try Harness.init(&fixture, options);
        defer harness.deinit();
        try harness.start();
        try std.testing.expect(harness.ui.failure != null);
        try std.testing.expect(harness.ui.preview == null);
        try std.testing.expectEqual(@as(usize, 0), fixture.inspected.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), fixture.cleaned.load(.acquire));
    }
}

test "inspection failure joins and cleans the reserved worker without success publication" {
    var fixture: Fixture = .{ .inspection_failure = error.BadPackArchive };
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    try harness.start();
    try harness.waitIdle();
    try std.testing.expectEqual(error.BadPackArchive, harness.ui.failure.?);
    try std.testing.expect(harness.ui.preview == null and harness.ui.draft.base == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.cleaned.load(.acquire));
}

test "late native picker result cannot reopen a closed modal" {
    var fixture: Fixture = .{ .release_picker = .init(false) };
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    defer fixture.release_picker.store(true, .release);
    view.open(&harness.ui);
    harness.ui.pending = .browse;
    harness.finish(false);
    try waitFlag(&fixture.picked);
    try harness.ui.queueOwned(.close, &harness.controller);
    harness.finish(false);
    fixture.release_picker.store(true, .release);
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 10 * std.time.ns_per_s;
    while (harness.ui.picker != null) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.TestTimeout;
        harness.finish(false);
        std.Thread.yield() catch {};
    }
    try std.testing.expect(!harness.ui.modal_open and harness.ui.preview == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.inspected.load(.acquire));
}

test "blocked ownership invalidates a picker result rather than replaying it" {
    var fixture: Fixture = .{ .release_picker = .init(false) };
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    defer fixture.release_picker.store(true, .release);
    view.open(&harness.ui);
    harness.ui.pending = .browse;
    harness.finish(false);
    try waitFlag(&fixture.picked);
    harness.finish(true);
    fixture.release_picker.store(true, .release);
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 10 * std.time.ns_per_s;
    while (harness.ui.picker != null) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.TestTimeout;
        harness.finish(false);
        std.Thread.yield() catch {};
    }
    try std.testing.expect(harness.ui.preview == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.inspected.load(.acquire));
}

test "existing choice is a full owned row and changed durable row rejects before admission" {
    var fixture: Fixture = .{};
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    var document = harness.store.snapshot().*;
    document.instances = &.{exact_row};
    try harness.store.update(document);
    try harness.start();
    try harness.waitPreview();
    try harness.ui.queueExisting(harness.store.snapshot().instances[0]);
    harness.finish(false);
    var changed = exact_row;
    changed.max_memory_mb = 4096;
    document = harness.store.snapshot().*;
    document.instances = &.{changed};
    try harness.store.update(document);
    try std.testing.expect(harness.ui.existing.?.value.max_memory_mb == null);
    harness.ui.pending = .confirm;
    harness.finish(false);
    try std.testing.expectEqual(error.InstanceConfigurationChanged, harness.ui.failure.?);
    try std.testing.expect(!harness.ui.pinned and harness.ui.preview != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.cleaned.load(.acquire));
}

test "invalid name and numeric memory retain preview without prerequisite workers" {
    var fixture: Fixture = .{};
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    try harness.start();
    try harness.waitPreview();
    @memset(&harness.ui.draft.name, 0);
    harness.ui.draft.name[0] = '/';
    harness.ui.pending = .confirm;
    harness.finish(false);
    try std.testing.expectEqual(error.InvalidInstanceName, harness.ui.failure.?);
    @memset(&harness.ui.draft.name, 0);
    @memcpy(harness.ui.draft.name[0..5], "Valid");
    @memcpy(harness.ui.draft.memory[0..2], "12");
    harness.ui.pending = .confirm;
    harness.finish(false);
    try std.testing.expectEqual(error.InvalidMemory, harness.ui.failure.?);
    try std.testing.expect(harness.ui.preview != null and !harness.ui.pinned);
}

test "full row comparison includes Java memory debug origin and loader tuple" {
    var row = exact_row;
    try std.testing.expect(view.sameRow(row, exact_row));
    row.java_path = "/jdk/bin/java";
    try std.testing.expect(!view.sameRow(row, exact_row));
    row = exact_row;
    row.debug_launch = true;
    try std.testing.expect(!view.sameRow(row, exact_row));
    row = exact_row;
    row.origin = .{ .kind = .modrinth, .project_id = "p", .version_id = "v" };
    try std.testing.expect(!view.sameRow(row, exact_row));
    row = exact_row;
    row.loader_version = "0.15.8";
    try std.testing.expect(!view.sameRow(row, exact_row));
}

test "cleanup failure retains visible stage debt and never deletes a game or Java path" {
    var fixture: Fixture = .{ .cleanup_failure = error.CleanupDenied };
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    try harness.start();
    try harness.waitPreview();
    try harness.ui.queueOwned(.close, &harness.controller);
    harness.finish(false);
    try harness.waitIdle();
    try std.testing.expectEqual(error.CleanupDenied, harness.ui.cleanup_failure.?);
    const stage = std.mem.sliceTo(&harness.ui.cleanup_stage, 0);
    try std.testing.expect(std.mem.indexOf(u8, stage, "pack-import-stage") != null);
    try std.testing.expect(std.mem.indexOf(u8, stage, ".minecraft") == null);
    try std.testing.expect(std.mem.indexOf(u8, stage, "jdks") == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.cleaned.load(.acquire));
    view.open(&harness.ui);
    try harness.ui.queueArchive("/fake/original.mrpack");
    harness.finish(false);
    try std.testing.expectEqual(error.PreviewCleanupRequired, harness.ui.failure.?);
}

test "review handoff is one shot" {
    var fixture: Fixture = .{};
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    harness.ui.review_requested = true;
    try std.testing.expect(harness.ui.takeReviewRequest());
    try std.testing.expect(!harness.ui.takeReviewRequest());
}

test "archive queue rejects relative NUL and invalid UTF8 paths" {
    var fixture: Fixture = .{};
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    try std.testing.expectError(error.ArchivePathNotAbsolute, harness.ui.queueArchive("relative.mrpack"));
    const nul = [_]u8{ '/', 0 };
    try std.testing.expectError(error.ArchivePathNotAbsolute, harness.ui.queueArchive(&nul));
    const invalid = [_]u8{ '/', 0xff };
    try std.testing.expectError(error.ArchivePathNotAbsolute, harness.ui.queueArchive(&invalid));
    try std.testing.expect(harness.ui.pending == null);
}

fn queuedAllocationFailures(allocator: std.mem.Allocator) !void {
    var ui = try view.Ui.init(allocator, io, "/fake/root");
    defer ui.deinit(); // No Controller request was ever admitted.
    try ui.queueArchive("/fake/original.mrpack");
    view.finish(&ui, undefined, undefined, undefined, true);
    var row = exact_row;
    row.java_path = "/fake/jdk/bin/java";
    row.origin = .{ .kind = .modrinth, .project_id = "project", .version_id = "version" };
    try ui.queueExisting(row);
    view.finish(&ui, undefined, undefined, undefined, true);
}
test "queued owned paths and full rows roll back every allocation failure" {
    try std.testing.checkAllAllocationFailures(a, queuedAllocationFailures, .{});
}

test "owned UI cancel drains completed picker while finish is blocked" {
    var fixture: Fixture = .{ .release_picker = .init(false) };
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    defer fixture.release_picker.store(true, .release);
    view.open(&harness.ui);
    harness.ui.pending = .browse;
    harness.finish(false);
    try waitFlag(&fixture.picked);
    harness.ui.cancel();
    try std.testing.expect(harness.ui.isBusy()); // Native callback is still held.
    try std.testing.expectError(error.UiStopping, harness.ui.queueArchive("/fake/original.mrpack"));
    fixture.release_picker.store(true, .release);
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 10 * std.time.ns_per_s;
    while (harness.ui.isBusy()) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.TestTimeout;
        harness.finish(true);
        harness.ui.tick(&harness.controller);
        std.Thread.yield() catch {};
    }
    try std.testing.expect(harness.ui.picker == null and harness.ui.preview == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.inspected.load(.acquire));
    view.open(&harness.ui);
    try std.testing.expect(!harness.ui.modal_open);
}

test "owned UI cancel joins its inspecting worker without foreign services" {
    var fixture: Fixture = .{ .release_inspection = .init(false) };
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    try harness.start();
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 10 * std.time.ns_per_s;
    while (fixture.inspected.load(.acquire) == 0) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.TestTimeout;
        std.Thread.yield() catch {};
    }
    harness.ui.cancel();
    harness.finish(true);
    try harness.waitIdle();
    try std.testing.expect(harness.ui.preview == null and !harness.ui.modal_open);
    try std.testing.expectEqual(error.Canceled, harness.ui.failure.?);
    try std.testing.expect(!harness.ui.takeReviewRequest());
}

test "shutdown joins preview cleanup after Controller without leaking its Inspection" {
    var fixture: Fixture = .{};
    {
        var harness = try Harness.init(&fixture, .{});
        defer harness.deinit();
        try harness.start();
        try harness.waitPreview();
        try std.testing.expectEqual(@as(usize, 0), fixture.cleaned.load(.acquire));
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.cleaned.load(.acquire));
}

fn pinOwned(harness: *Harness, fixture: *Fixture, phase: controller_mod.Phase) void {
    harness.ui.pinned = true;
    harness.ui.generation = 7;
    harness.ui.owner_controller = &harness.controller;
    harness.ui.owner_services = harness.services();
    fixture.owned_state.phase = phase;
    fixture.owned_state.preparation_generation = 7;
    fixture.owned_state.serial = 3;
    fixture.owned_state.role = .runtime;
}

test "blocked owned cancel dispatches once without admitting foreign work" {
    var fixture: Fixture = .{};
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    pinOwned(&harness, &fixture, .creating);
    try harness.ui.queueOwned(.cancel, &harness.controller);
    harness.finish(true);
    try std.testing.expect(harness.ui.pending == null and harness.ui.pending_drain == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.drained[@intFromEnum(view.OwnedAction.cancel)]);
    harness.finish(false);
    try std.testing.expectEqual(@as(usize, 1), fixture.drained[@intFromEnum(view.OwnedAction.cancel)]);
    try std.testing.expectEqual(@as(usize, 0), fixture.inspected.load(.acquire));
}

test "blocked owned close joins private cleanup without foreign cancellation" {
    var fixture: Fixture = .{};
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    try harness.start();
    try harness.waitPreview();
    try harness.ui.queueOwned(.close, &harness.controller);
    harness.finish(true);
    try harness.waitIdle();
    try std.testing.expect(!harness.ui.modal_open and harness.ui.preview == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.cleaned.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fixture.drained[@intFromEnum(view.OwnedAction.cancel)]);
}

test "blocked explicit recovery dispatches only in its owned phase" {
    for ([_]view.OwnedAction{ .reconcile, .retry_adoption }) |action| {
        var fixture: Fixture = .{};
        var harness = try Harness.init(&fixture, .{});
        defer harness.deinit();
        pinOwned(&harness, &fixture, if (action == .reconcile) .awaiting_reconciliation else .awaiting_adoption);
        try harness.ui.queueOwned(action, &harness.controller);
        harness.finish(true);
        try std.testing.expectEqual(@as(usize, 1), fixture.drained[@intFromEnum(action)]);
        try std.testing.expect(harness.ui.failure == null and harness.ui.pinned);
        harness.finish(false);
        try std.testing.expectEqual(@as(usize, 1), fixture.drained[@intFromEnum(action)]);
    }
}

test "blocked recovery preserves existing deep-check errors without replay" {
    var fixture: Fixture = .{ .drain_failure = error.NoOwnedPublicationUncertainty };
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    pinOwned(&harness, &fixture, .awaiting_reconciliation);
    try harness.ui.queueOwned(.reconcile, &harness.controller);
    harness.finish(true);
    try std.testing.expectEqual(error.NoOwnedPublicationUncertainty, harness.ui.failure.?);
    try std.testing.expect(harness.ui.pinned);
    harness.finish(false);
    try std.testing.expectEqual(@as(usize, 1), fixture.drained[@intFromEnum(view.OwnedAction.reconcile)]);
}

test "stopped finish rejects already queued reconciliation and retry" {
    for ([_]view.OwnedAction{ .reconcile, .retry_adoption }) |action| {
        var fixture: Fixture = .{};
        var harness = try Harness.init(&fixture, .{});
        defer harness.deinit();
        pinOwned(&harness, &fixture, if (action == .reconcile) .awaiting_reconciliation else .awaiting_adoption);
        try harness.ui.queueOwned(action, &harness.controller);
        harness.ui.stopping = true;
        harness.finish(true);
        try std.testing.expectEqual(error.UiStopping, harness.ui.failure.?);
        try std.testing.expectEqual(@as(usize, 0), fixture.drained[@intFromEnum(action)]);
        try std.testing.expectError(error.UiStopping, harness.ui.queueOwned(action, &harness.controller));
        harness.finish(false);
        try std.testing.expectEqual(@as(usize, 0), fixture.drained[@intFromEnum(action)]);
    }
}

test "stopped UI allows owned cancel and close but retains coordinator ownership" {
    var fixture: Fixture = .{};
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    pinOwned(&harness, &fixture, .cleaning);
    harness.ui.cancel();
    try harness.ui.queueOwned(.cancel, &harness.controller);
    harness.finish(true);
    try harness.ui.queueOwned(.close, &harness.controller);
    harness.finish(true);
    try std.testing.expect(harness.ui.pinned and !harness.ui.modal_open);
    try std.testing.expectEqual(@as(usize, 1), fixture.drained[@intFromEnum(view.OwnedAction.cancel)]);
}

test "stale owned drain binding is consumed and never replayed" {
    const Drift = enum { generation, serial, role, phase, epoch, pinned, controller, services, store };
    for (std.enums.values(Drift)) |drift| {
        var fixture: Fixture = .{};
        var harness = try Harness.init(&fixture, .{});
        defer harness.deinit();
        pinOwned(&harness, &fixture, .creating);
        try harness.ui.queueOwned(.cancel, &harness.controller);
        switch (drift) {
            .generation => fixture.owned_state.preparation_generation += 1,
            .serial => fixture.owned_state.serial += 1,
            .role => fixture.owned_state.role = .installer,
            .phase => fixture.owned_state.phase = .awaiting_adoption,
            .epoch => harness.ui.epoch += 1,
            .pinned => harness.ui.pinned = false,
            .controller => harness.ui.owner_controller = null,
            .services => harness.ui.owner_services.?.java = @ptrFromInt(0x5000),
            .store => harness.ui.owner_services.?.store = @ptrFromInt(0x5000),
        }
        harness.finish(true);
        try std.testing.expectEqual(if (drift == .services or drift == .store) error.ConfigurationChanged else error.StalePreparationGeneration, harness.ui.failure.?);
        try std.testing.expect(harness.ui.pending == null and harness.ui.pending_drain == null);
        harness.finish(false);
        try std.testing.expectEqual(@as(usize, 0), fixture.drained[@intFromEnum(view.OwnedAction.cancel)]);
    }
}

test "blocked wrong-phase recovery never reaches store reconciliation or retry" {
    for ([_]view.OwnedAction{ .reconcile, .retry_adoption }) |action| {
        var fixture: Fixture = .{};
        var harness = try Harness.init(&fixture, .{});
        defer harness.deinit();
        pinOwned(&harness, &fixture, .creating);
        try harness.ui.queueOwned(action, &harness.controller);
        harness.finish(true);
        try std.testing.expectEqual(error.StalePreparationGeneration, harness.ui.failure.?);
        try std.testing.expectEqual(@as(usize, 0), fixture.drained[@intFromEnum(action)]);
    }
}

test "shutdown retains private archive until the pinned reader joins" {
    var fixture: Fixture = .{};
    var harness = try Harness.init(&fixture, .{});
    defer harness.deinit();
    try harness.start();
    try harness.waitPreview();
    pinOwned(&harness, &fixture, .preparing);
    harness.ui.cancel();
    harness.finish(true);
    try std.testing.expect(harness.ui.preview != null and !harness.ui.preview.?.cleanup_requested);
    try std.testing.expectEqual(@as(usize, 0), fixture.cleaned.load(.acquire));
}
