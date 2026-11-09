const std = @import("std");
const state = @import("ui/resource_download_state.zig");
const fixture_data = @import("ui/resource_download_fixture.zig");
const navigation_data = @import("ui/resource_navigation_fixture.zig");
const content = @import("application/content_manager.zig");
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const tasks = @import("core/tasks.zig");
const first: config.Instance = .{ .id = "resources-first", .name = "First", .minecraft_version = "1.21.4", .loader = .fabric };
const second: config.Instance = .{ .id = "resources-second", .name = "Second", .minecraft_version = "1.21.4", .loader = .fabric };
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]const u8,
    paths: instances.Paths,
    registry: tasks.Registry,
    backend: content.Manager,
    ui: state.Ui,
    scenario: fixture_data.Scenario,
    navigation: navigation_data.Context,
    fn init(self: *Fixture) !void {
        return self.initScenario(.{});
    }
    fn initScenario(self: *Fixture, scenario: fixture_data.Scenario) !void {
        self.scenario = scenario;
        self.navigation = .{ .scenario = &self.scenario };
        const a = std.testing.allocator;
        const io = std.testing.io;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(io, ".minecraft/versions/First/mods");
        try self.tmp.dir.createDirPath(io, ".minecraft/versions/Second/mods");
        self.root = try self.tmp.dir.realPathFileAlloc(io, ".", a);
        errdefer a.free(self.root);
        self.paths = try instances.Paths.init(a, io, self.root);
        errdefer self.paths.deinit();
        self.registry = tasks.Registry.init(a);
        errdefer self.registry.deinit();
        self.backend = try content.Manager.initOptions(a, io, &self.paths, &self.registry, .{ .lease = fixture_data.Lease.callbacks(), .transport_options = .{ .fixture_http = navigation_data.execute, .fixture_context = &self.navigation } });
        errdefer self.backend.deinit();
        self.ui = state.Ui.init(a);
        errdefer self.ui.deinit();
        try self.backend.select(first);
        try self.ui.bind(first, .mod);
        try self.drain();
    }
    fn deinit(self: *Fixture) void {
        self.backend.cancelAndJoin();
        self.ui.deinit();
        self.backend.deinit();
        self.registry.deinit();
        self.paths.deinit();
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
    fn drain(self: *Fixture) !void {
        for (0..6000) |_| {
            self.backend.tick();
            self.ui.tick(&self.backend, true);
            if (!self.backend.isBusy() and self.ui.job == .idle) return;
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.TestWorkerTimeout;
    }
    fn action(self: *Fixture, intent: state.Intent) !void {
        self.ui.queue(intent);
        self.ui.finish(&self.backend, true, true);
        try self.drain();
        if (self.ui.failure) |err| {
            std.debug.print("resource action {s}: {s}\n", .{ @tagName(intent), @errorName(err) });
            return err;
        }
    }
    fn detail(self: *Fixture) !void {
        self.ui.open();
        self.ui.finish(&self.backend, true, true);
        try self.drain();
        try self.action(.{ .project = self.ui.catalog[0] });
    }
};

test "resource download preserves root version through dependency navigation then installs with explicit confirmation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    errdefer std.debug.print("resource flow failed: route={s}, frames={d}, selected={d}, ready={}, installed={d}, task={s}\n", .{ @tagName(f.ui.route), f.ui.frames.items.len, if (f.ui.frame()) |detail| detail.selected else 0, if (f.backend.snapshot().proposal) |proposal| proposal.ready else false, f.backend.snapshot().installed.len, @tagName(f.ui.task_state) });
    try f.detail();
    try std.testing.expectEqual(state.Route.detail, f.ui.route);
    try std.testing.expectEqual(@as(usize, 2), f.ui.frame().?.versions.len);
    try std.testing.expect(f.ui.currentProposal(f.backend.snapshot()));
    try f.action(.{ .version = 1 });
    try f.action(.{ .choice = .{ .dependency_index = 0, .version_id = "sodium-1", .include = true } });
    try f.action(.{ .dependency = 0 });
    try std.testing.expectEqual(@as(usize, 2), f.ui.frames.items.len);
    try std.testing.expectEqualStrings("sodium", f.ui.frame().?.project.id);
    try f.action(.back);
    try std.testing.expectEqual(@as(usize, 1), f.ui.frames.items.len);
    try std.testing.expectEqual(@as(usize, 1), f.ui.frame().?.selected);
    try std.testing.expectEqualStrings("iris-2", f.backend.snapshot().proposal.?.root.?.id);
    try std.testing.expectEqualStrings("sodium-1", f.ui.frame().?.choice(0).?.version_id.?);
    try std.testing.expect(f.backend.snapshot().proposal.?.ready);
    try f.action(.confirm);
    try std.testing.expect(f.ui.confirm_open and f.ui.locked());
    try std.testing.expect(f.backend.snapshot().report == null);
    f.ui.queue(.commit);
    f.ui.finish(&f.backend, false, true);
    try std.testing.expectEqual(error.ContentControlsLocked, f.ui.failure.?);
    try std.testing.expect(f.backend.snapshot().report == null and !f.backend.isBusy());
    try f.action(.commit);
    try std.testing.expectEqual(state.TaskState.succeeded, f.ui.task_state);
    try std.testing.expect(f.ui.changed and f.backend.snapshot().report.?.committed);
    try std.testing.expectEqual(@as(usize, 2), f.backend.snapshot().installed.len);
    const root = state.installed(f.backend.snapshot(), .modrinth, "iris").?;
    try std.testing.expectEqualStrings("iris-2", root.version_id);
    const bytes = f.tmp.dir.readFileAlloc(std.testing.io, ".minecraft/versions/First/mods/iris.jar", std.testing.allocator, .limited(1024)) catch |err| {
        std.debug.print("installed file {s}: {s}\n", .{ root.path, @errorName(err) });
        return err;
    };
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(fixture_data.payload, bytes);
    try f.action(.dismiss);
    try f.action(.back);
    try std.testing.expectEqual(state.Route.catalog, f.ui.route);
    try std.testing.expectEqual(@as(usize, 4), f.ui.catalog.len);
    try f.action(.back);
    try std.testing.expectEqual(state.Route.local, f.ui.route);
    try std.testing.expect(!f.registry.hasActive());
}

test "resource context change discards old confirmation and a forged commit cannot install" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.detail();
    try f.action(.confirm);
    try f.backend.select(second);
    try f.ui.bind(second, .mod);
    try f.drain();
    try std.testing.expectEqual(state.Route.local, f.ui.route);
    try std.testing.expect(!f.ui.confirm_open and f.ui.frames.items.len == 0);
    f.ui.queue(.commit);
    f.ui.finish(&f.backend, true, true);
    try std.testing.expectEqual(error.ContentControlsLocked, f.ui.failure.?);
    try std.testing.expect(f.backend.snapshot().report == null);
    f.ui.failure = null;
    f.ui.open();
    f.ui.finish(&f.backend, true, false);
    try std.testing.expectEqual(error.ContentControlsLocked, f.ui.failure.?);
    try std.testing.expect(f.ui.pending == null and !f.backend.isBusy());
}

test "resource provider unavailability retains Modrinth and root proposal is tied to the selected version" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.ui.route = .catalog;
    f.ui.queue(.{ .provider = .curseforge });
    f.ui.finish(&f.backend, true, true);
    try std.testing.expectEqual(error.ProviderDisabled, f.ui.failure.?);
    try std.testing.expectEqual(@import("core/content_providers.zig").Provider.modrinth, f.ui.provider);
    try f.detail();
    const proposal = f.backend.snapshot().proposal.?;
    var foreign = proposal.*;
    foreign.root = .{ .provider = .modrinth, .id = "foreign" };
    try std.testing.expect(!f.ui.currentProposal(.{ .proposal = &foreign }));
    try std.testing.expect(f.ui.currentProposal(f.backend.snapshot()));
}

test "resource graph preserves transitive choices across dependency returns and installs all required files" {
    var f: Fixture = undefined;
    try f.initScenario(.{ .transitive = true });
    defer f.deinit();
    try f.detail();
    try f.action(.{ .choice = .{ .dependency_index = 0, .version_id = "sodium-1", .include = true } });
    try std.testing.expect(f.backend.snapshot().proposal.?.ready);
    try f.action(.{ .dependency = 0 });
    try f.action(.{ .choice = .{ .dependency_index = 0, .version_id = "fabric-api-1", .include = true } });
    try f.action(.back);
    try std.testing.expectEqualStrings("sodium-1", f.ui.frame().?.choice(0).?.version_id.?);
    try std.testing.expect(f.backend.snapshot().proposal.?.ready);
    try f.action(.{ .dependency = 0 });
    try std.testing.expectEqualStrings("fabric-api-1", f.ui.frame().?.choice(0).?.version_id.?);
    try f.action(.back);
    try f.action(.confirm);
    try f.action(.commit);
    try std.testing.expectEqual(state.TaskState.succeeded, f.ui.task_state);
    try std.testing.expectEqual(@as(usize, 3), f.backend.snapshot().installed.len);
}

test "resource optional dependencies default to a recorded exclusion without toggling" {
    var f: Fixture = undefined;
    try f.initScenario(.{ .optional = true });
    defer f.deinit();
    try f.detail();
    try std.testing.expect(!f.ui.frame().?.choice(1).?.include);
    try f.action(.{ .choice = .{ .dependency_index = 0, .version_id = "sodium-1", .include = true } });
    try std.testing.expect(f.backend.snapshot().proposal.?.ready);
    try std.testing.expectEqual(@as(usize, 2), f.backend.snapshot().proposal.?.files.len);
}

test "resource failed dependency preparation cannot confirm an older ready proposal" {
    var f: Fixture = undefined;
    try f.initScenario(.{ .multiple_sodium = true });
    defer f.deinit();
    try f.detail();
    try f.action(.{ .choice = .{ .dependency_index = 0, .version_id = "sodium-1", .include = true } });
    try std.testing.expect(f.ui.currentProposal(f.backend.snapshot()) and f.backend.snapshot().proposal.?.ready);
    f.scenario.fail_requests.store(true, .release);
    f.ui.queue(.{ .choice = .{ .dependency_index = 0, .version_id = "sodium-2", .include = true } });
    f.ui.finish(&f.backend, true, true);
    try f.drain();
    try std.testing.expectEqual(error.FixtureMetadataUnavailable, f.ui.failure.?);
    try std.testing.expect(f.backend.snapshot().proposal.?.ready);
    try std.testing.expect(!f.ui.currentProposal(f.backend.snapshot()));
    f.ui.queue(.confirm);
    f.ui.finish(&f.backend, true, true);
    try std.testing.expectEqual(error.NoProposal, f.ui.failure.?);
    try std.testing.expect(!f.ui.confirm_open);
    f.scenario.fail_requests.store(false, .release);
    try f.action(.retry);
    try std.testing.expect(f.ui.currentProposal(f.backend.snapshot()) and f.backend.snapshot().proposal.?.ready);
    try std.testing.expectEqualStrings("sodium-2", f.ui.frame().?.choice(0).?.version_id.?);
}

test "resource changed dependency detail version returns to the original project" {
    var f: Fixture = undefined;
    try f.initScenario(.{ .multiple_sodium = true });
    defer f.deinit();
    try f.detail();
    try f.action(.{ .choice = .{ .dependency_index = 0, .version_id = "sodium-1", .include = true } });
    try f.action(.{ .dependency = 0 });
    try f.action(.{ .version = 1 });
    try std.testing.expectEqualStrings("sodium-2", f.ui.frame().?.version().?.id);
    try f.action(.back);
    try std.testing.expectEqualStrings("iris-1", f.ui.frame().?.version().?.id);
    try std.testing.expectEqualStrings("sodium-2", f.ui.frame().?.choice(0).?.version_id.?);
    try std.testing.expect(f.backend.snapshot().proposal.?.ready);
}

test "resource transitive optional dependencies are excluded before visiting their detail" {
    var f: Fixture = undefined;
    try f.initScenario(.{ .transitive = true, .optional = true });
    defer f.deinit();
    try f.detail();
    try f.action(.{ .choice = .{ .dependency_index = 0, .version_id = "sodium-1", .include = true } });
    const excluded = for (f.ui.frame().?.choices.items) |candidate_choice| {
        if (std.mem.eql(u8, candidate_choice.from.id, "sodium-1") and candidate_choice.dependency_index == 0) break !candidate_choice.include;
    } else false;
    try std.testing.expect(excluded);
    try std.testing.expect(f.backend.snapshot().proposal.?.ready);
    try std.testing.expectEqual(@as(usize, 2), f.backend.snapshot().proposal.?.files.len);
}

test "resource selects newest compatible root and dependency versions from unordered metadata" {
    var f: Fixture = undefined;
    try f.initScenario(.{ .multiple_sodium = true, .reverse_versions = true });
    defer f.deinit();
    try f.detail();
    try std.testing.expectEqualStrings("iris-1", f.ui.frame().?.version().?.id);
    try std.testing.expectEqualStrings("sodium-1", f.ui.frame().?.choice(0).?.version_id.?);
    try std.testing.expect(f.ui.currentProposal(f.backend.snapshot()) and f.backend.snapshot().proposal.?.ready);
    try std.testing.expectEqual(@as(usize, 2), f.backend.snapshot().proposal.?.files.len);
    try f.action(.{ .dependency = 0 });
    try std.testing.expectEqualStrings("sodium-1", f.ui.frame().?.version().?.id);
    try f.action(.{ .version = 1 });
    try f.action(.back);
    try std.testing.expectEqualStrings("iris-1", f.ui.frame().?.version().?.id);
    try std.testing.expectEqualStrings("sodium-2", f.ui.frame().?.choice(0).?.version_id.?);
}

test "installed labels resolve opaque receipt ids from cached local versions including disabled jars" {
    const manifest = @import("core/content_manifest.zig");
    const local = @import("core/local_content.zig");
    var file: manifest.ManagedFile = .{ .path = "mods/iris.jar", .provider = .modrinth, .project_id = "iris", .version_id = "3dM0X6ou", .hashes = .{}, .identity_provenance = .official_file };
    var entry: local.Entry = .{ .path = file.path, .physical_path = "/game/mods/iris.jar", .name = "Iris Shaders", .version = "1.8.8" };
    try std.testing.expectEqualStrings("1.8.8", state.installedVersion(.{}, file, &.{entry}).?);
    file.enabled = false;
    entry.enabled = false;
    entry.path = "mods/iris.jar.disabled";
    try std.testing.expectEqualStrings("1.8.8", state.installedVersion(.{}, file, &.{entry}).?);
    entry.version = null;
    try std.testing.expect(state.installedVersion(.{}, file, &.{entry}) == null);
    entry.version = "   ";
    try std.testing.expect(state.installedVersion(.{}, file, &.{entry}) == null);
    entry.version = "1.8.8";
    entry.path = "mods/other.jar.disabled";
    try std.testing.expect(state.installedVersion(.{}, file, &.{entry}) == null);
}

test "installed labels resolve matching provider metadata and never display an opaque id as its name" {
    const manifest = @import("core/content_manifest.zig");
    const providers = @import("core/content_providers.zig");
    const file: manifest.ManagedFile = .{ .path = "mods/iris.jar", .provider = .modrinth, .project_id = "iris", .version_id = "3dM0X6ou", .hashes = .{}, .identity_provenance = .official_file };
    var version: providers.Version = .{ .provider = .modrinth, .project_id = "iris", .id = file.version_id, .name = "1.8.8", .minecraft_versions = &.{"1.21.4"}, .loaders = &.{"fabric"}, .files = &.{}, .dependencies = &.{} };
    try std.testing.expectEqualStrings("1.8.8", state.installedVersion(.{ .versions = &.{version} }, file, &.{}).?);
    try std.testing.expectEqualStrings("1.8.8", state.installedVersion(.{ .candidates = &.{version} }, file, &.{}).?);
    version.provider = .curseforge;
    try std.testing.expect(state.installedVersion(.{ .versions = &.{version} }, file, &.{}) == null);
    version.provider = .modrinth;
    version.project_id = "other";
    try std.testing.expect(state.installedVersion(.{ .versions = &.{version} }, file, &.{}) == null);
    version.project_id = "iris";
    version.name = file.version_id;
    try std.testing.expect(state.installedVersion(.{ .versions = &.{version} }, file, &.{}) == null);
    try std.testing.expect(state.installedVersion(.{}, file, &.{}) == null);
}

fn waitForNavigationGate(f: *Fixture, gate: *navigation_data.Gate) !void {
    for (0..3000) |_| {
        f.backend.tick();
        f.ui.tick(&f.backend, true);
        if (gate.started.load(.acquire)) return;
        if (f.ui.failure) |err| return err;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.MetadataGateTimeout;
}
fn openNavigationCatalog(f: *Fixture) !void {
    f.ui.open();
    f.ui.finish(&f.backend, true, true);
    try f.drain();
}
test "resource navigation back cancels dependency metadata before the remaining requests" {
    var f: Fixture = undefined;
    try f.initScenario(.{ .optional = true });
    defer f.deinit();
    var gate: navigation_data.Gate = .{ .match = "/version/sodium-1" };
    defer gate.release.store(true, .release);
    try openNavigationCatalog(&f);
    f.ui.catalog_scroll.viewport.y = 492;
    f.navigation.gate = &gate;
    f.ui.queue(.{ .project = f.ui.catalog[0] });
    f.ui.finish(&f.backend, true, true);
    try waitForNavigationGate(&f, &gate);
    try std.testing.expectEqual(state.Job.prepare, f.ui.job);
    const requests = gate.requests.load(.acquire);
    // A previous commit can still owe its deferred local inventory refresh.
    f.backend.pending_refresh = true;
    f.ui.queue(.back);
    f.ui.finish(&f.backend, false, true);
    try std.testing.expectEqual(state.Route.catalog, f.ui.route);
    try std.testing.expectEqual(state.Job.idle, f.ui.job);
    try std.testing.expect(f.backend.pending_refresh);
    try std.testing.expectEqual(@as(f32, 492), f.ui.catalog_scroll.viewport.y);
    try std.testing.expect(f.ui.failure == null and f.ui.frames.items.len == 0);
    try f.drain();
    try std.testing.expect(gate.cancel_seen.load(.acquire));
    try std.testing.expectEqual(requests, gate.requests.load(.acquire));
    try std.testing.expect(f.backend.snapshot().proposal == null and !f.registry.hasActive());
}
test "resource navigation returns before a late version response and ignores its result" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var gate: navigation_data.Gate = .{ .match = "/project/iris/version", .late_result = true };
    defer gate.release.store(true, .release);
    try openNavigationCatalog(&f);
    f.navigation.gate = &gate;
    f.ui.queue(.{ .project = f.ui.catalog[0] });
    f.ui.finish(&f.backend, true, true);
    try waitForNavigationGate(&f, &gate);
    try std.testing.expect(!f.ui.locked());
    f.ui.queue(.search);
    f.ui.queue(.back);
    f.ui.finish(&f.backend, true, true);
    try std.testing.expectEqual(state.Route.catalog, f.ui.route);
    try std.testing.expect(f.backend.isBusy());
    f.ui.queue(.back);
    f.ui.finish(&f.backend, true, true);
    try std.testing.expectEqual(state.Route.local, f.ui.route);
    try std.testing.expect(f.ui.failure == null and f.ui.frames.items.len == 0);
    gate.release.store(true, .release);
    try f.drain();
    try std.testing.expect(gate.cancel_seen.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), f.backend.snapshot().versions.len);
    try std.testing.expectEqual(@as(usize, 4), f.ui.catalog.len);
    try std.testing.expect(f.ui.failure == null and !f.registry.hasActive());
}
test "resource navigation retains catalog and each parent detail scroll with selected versions" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.detail();
    f.ui.catalog_scroll.viewport.y = 388;
    f.ui.frame().?.scroll.viewport.y = 173;
    try f.action(.{ .version = 1 });
    try f.action(.{ .choice = .{ .dependency_index = 0, .version_id = "sodium-1", .include = true } });
    try f.action(.{ .dependency = 0 });
    try std.testing.expectEqual(@as(f32, 0), f.ui.frame().?.scroll.viewport.y);
    f.ui.frame().?.scroll.viewport.y = 86;
    try f.action(.back);
    try std.testing.expectEqual(@as(f32, 173), f.ui.frame().?.scroll.viewport.y);
    try std.testing.expectEqual(@as(usize, 1), f.ui.frame().?.selected);
    try std.testing.expectEqualStrings("sodium-1", f.ui.frame().?.choice(0).?.version_id.?);
    try f.action(.back);
    try std.testing.expectEqual(state.Route.catalog, f.ui.route);
    try std.testing.expectEqual(@as(f32, 388), f.ui.catalog_scroll.viewport.y);
}
