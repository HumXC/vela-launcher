//! UI owner for pack inspection/decisions and the shared creation coordinator.
//! tick owns creation's instances/Java work; App must honor the owns* queries.
//! Services and fixture contexts outlive deinit, which cancels and joins workers.
const std = @import("std");
const config = @import("../core/config.zig");
const paths_mod = @import("../core/instances.zig");
const packs = @import("../core/pack_import.zig");
const backend = @import("../core/pack_install.zig");
const manifest = @import("../core/content_manifest.zig");
const content = @import("../core/content_install.zig");
const providers = @import("../core/content_providers.zig");
const creation = @import("instance_creation_controller.zig");
const instances = @import("instances_manager.zig");
const tasks = @import("../core/tasks.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const pack_loader_version = @import("../core/pack_loader_version.zig");

pub const Services = creation.Services;
pub const Source = backend.Source;
pub const OptionalChoice = backend.OptionalChoice;
pub const Options = struct {
    creation_options: creation.Options = .{},
    backend_options: backend.Options = .{},
};
pub const Phase = enum { idle, inspecting, ready, creating, complete, failed, canceled };
pub const Snapshot = struct {
    phase: Phase,
    busy: bool,
    failure: ?anyerror,
    pack_plan: ?manifest.PackPlan,
    manual_files: []const content.ManualFile,
    optional: []const OptionalChoice,
    creation: creation.Snapshot,
    blocker: ?anyerror,
};
const InspectionJob = struct {
    a: A,
    io: Io,
    arena: std.heap.ArenaAllocator,
    paths: *const paths_mod.Paths,
    source: Source,
    options: backend.Options,
    cancel: backend.CancelToken = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    inspection: ?packs.Inspection = null,
    failure: ?anyerror = null,
    fn run(job: *InspectionJob) void {
        job.inspection = backend.inspect(job.a, job.io, job.paths, job.source, job.options, &job.cancel) catch |err| blk: {
            job.failure = err;
            break :blk null;
        };
        if (job.cancel.load(.acquire)) job.failure = error.Canceled;
        job.done.store(true, .release);
    }
    fn destroy(job: *InspectionJob) void {
        job.cancel.store(true, .release);
        if (job.thread) |thread| thread.join();
        if (job.inspection) |*inspection| {
            inspection.cleanup(job.io) catch {};
            inspection.deinit();
        }
        job.arena.deinit();
        job.a.destroy(job);
    }
};
const Core = struct {
    a: A,
    io: Io,
    paths: paths_mod.Paths,
    options_arena: std.heap.ArenaAllocator,
    options: Options,
    choices_arena: std.heap.ArenaAllocator,
    creation: creation.Controller,
    // Core is heap-stable and is destroyed only after both workers join.
    telemetry: tasks.Task = .{ .id = 0, .title = "Pack files", .kind = .modpack_install },
    job: ?*InspectionJob = null,
    request: ?backend.Request = null,
    manual: []const content.ManualFile = &.{},
    optional: []const OptionalChoice = &.{},
    phase: Phase = .idle,
    failure: ?anyerror = null,
    started: bool = false,
};
pub const Controller = struct {
    core: *Core,
    pub fn init(a: A, io: Io, paths: *const paths_mod.Paths, options: Options) !Controller {
        const core = try a.create(Core);
        errdefer a.destroy(core);
        var owned_paths = try paths_mod.Paths.init(a, io, paths.root);
        errdefer owned_paths.deinit();
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const owned_options = try backend.clone(Options, arena.allocator(), options);
        var coordinator = try creation.Controller.init(a, io, paths.root, owned_options.creation_options);
        errdefer coordinator.deinit(undefined);
        core.* = .{ .a = a, .io = io, .paths = owned_paths, .options_arena = arena, .options = owned_options, .choices_arena = .init(a), .creation = coordinator };
        return .{ .core = core };
    }
    pub fn isBusy(self: *const Controller) bool {
        const core = self.core;
        return core.phase == .inspecting or core.phase == .creating;
    }
    pub fn inspect(self: *Controller, source: Source) !void {
        const core = self.core;
        if (self.isBusy() or core.creation.ownership().instances_publication) return error.Busy;
        const job = try core.a.create(InspectionJob);
        errdefer core.a.destroy(job);
        var arena: std.heap.ArenaAllocator = .init(core.a);
        errdefer arena.deinit();
        const owned_source = try backend.clone(Source, arena.allocator(), source);
        if (core.job) |old| old.destroy();
        core.job = null;
        core.request = null;
        core.started = false;
        core.phase = .idle;
        core.telemetry.reportDetails(.{});
        job.* = .{ .a = core.a, .io = core.io, .arena = arena, .paths = &core.paths, .source = owned_source, .options = core.options.backend_options };
        job.options.telemetry = &core.telemetry;
        job.thread = try std.Thread.spawn(.{}, InspectionJob.run, .{job});
        core.job = job;
        _ = core.choices_arena.reset(.free_all);
        core.manual = &.{};
        core.optional = &.{};
        core.request = null;
        core.started = false;
        core.phase = .inspecting;
        core.failure = null;
    }
    pub fn inspectLocal(self: *Controller, absolute_path: []const u8) !void {
        try self.inspect(.{ .local = absolute_path });
    }
    pub fn inspectOnline(self: *Controller, version: providers.Version) !void {
        try self.inspect(.{ .online = version });
    }
    pub fn setDecisions(self: *Controller, manual: []const content.ManualFile, optional: []const OptionalChoice) !void {
        const core = self.core;
        if (self.isBusy() or core.creation.ownership().instances_publication) return error.Busy;
        if (core.job == null or core.job.?.inspection == null) return error.MissingInspection;
        const pack = core.job.?.inspection.?.pack;
        for (optional, 0..) |choice, i| {
            for (optional[0..i]) |other| if (std.mem.eql(u8, choice.path, other.path)) return error.DuplicateDecision;
            var found = false;
            for (pack.files) |file| if (std.mem.eql(u8, choice.path, file.record.path)) {
                if (file.required and !choice.include) return error.RequiredFileExcluded;
                found = true;
            };
            if (!found) return error.UnknownPackFile;
        }
        for (manual, 0..) |mapping, i| {
            if (!std.fs.path.isAbsolute(mapping.source_absolute_path)) return error.ManualPathNotAbsolute;
            for (manual[0..i]) |other| if (std.mem.eql(u8, mapping.path, other.path)) return error.DuplicateManualFile;
            var found = false;
            for (pack.files) |file| if (std.mem.eql(u8, mapping.path, file.record.path)) {
                found = true;
            };
            if (!found) return error.UnknownPackFile;
        }
        var next: std.heap.ArenaAllocator = .init(core.a);
        errdefer next.deinit();
        const owned_manual = try backend.clone([]const content.ManualFile, next.allocator(), manual);
        const owned_optional = try backend.clone([]const OptionalChoice, next.allocator(), optional);
        core.choices_arena.deinit();
        core.choices_arena = next;
        core.manual = owned_manual;
        core.optional = owned_optional;
        core.started = false;
        core.request = null;
        core.phase = .ready;
        core.failure = null;
    }
    fn blocker(self: *const Controller) ?anyerror {
        const core = self.core;
        const job = core.job orelse return error.MissingInspection;
        const inspection = job.inspection orelse return error.MissingInspection;
        if (inspection.pack.unresolved.len != 0) return error.UnresolvedPackReferences;
        for (inspection.pack.files) |file| {
            var selected = file.selected;
            for (core.optional) |choice| if (std.mem.eql(u8, choice.path, file.record.path)) {
                selected = choice.include;
            };
            if (!file.required and selected == null) return error.OptionalDecisionRequired;
            if (!file.required and selected == false) continue;
            if (file.download == .manual_required) {
                var found = false;
                for (core.manual) |mapping| if (std.mem.eql(u8, mapping.path, file.record.path)) {
                    found = true;
                };
                if (!found) return error.ManualFileRequired;
            }
        }
        return null;
    }
    /// Identity/loader/version/origin come exclusively from the inspected pack.
    /// The caller supplies new stable ID/name and runtime settings only.
    pub fn start(self: *Controller, instance: config.Instance, services: Services) !void {
        const core = self.core;
        if (self.isBusy()) return error.Busy;
        if (self.blocker()) |err| return err;
        const inspection = &core.job.?.inspection.?;
        var row = instance;
        row.minecraft_version = inspection.pack.minecraft_version;
        row.loader = inspection.pack.loader;
        const loader_version = try pack_loader_version.normalize(core.a, inspection.pack.loader, inspection.pack.minecraft_version, inspection.pack.loader_version);
        defer if (loader_version) |version| core.a.free(version);
        row.loader_version = loader_version;
        row.origin = .{ .kind = inspection.pack.identity.provider, .project_id = inspection.pack.identity.project_id, .version_id = inspection.pack.identity.version_id };
        const owned = try instances.cloneInstance(core.choices_arena.allocator(), row);
        core.request = .{ .paths = &core.paths, .inspection = inspection, .instance = owned, .manual_files = core.manual, .optional = core.optional, .options = core.options.backend_options };
        core.telemetry.reportDetails(.{});
        core.request.?.options.telemetry = &core.telemetry;
        try core.creation.startExtended(owned, .{ .context = &core.request.?, .run = backend.precommit }, services);
        core.started = true;
        core.phase = .creating;
        core.failure = null;
    }
    pub fn tick(self: *Controller, services: Services) void {
        self.tickWithMutations(services, true);
    }
    pub fn tickWithMutations(self: *Controller, services: Services, allow_mutations: bool) void {
        const core = self.core;
        if (core.phase == .inspecting) {
            const job = core.job.?;
            if (!job.done.load(.acquire)) return;
            if (job.thread) |thread| {
                thread.join();
                job.thread = null;
            }
            // Cancellation after worker completion still invalidates its result.
            if (job.cancel.load(.acquire)) job.failure = error.Canceled;
            core.failure = job.failure;
            core.phase = if (job.failure) |err| if (err == error.Canceled) .canceled else .failed else .ready;
            if (job.failure != null) {
                job.destroy();
                core.job = null;
            }
        }
        if (core.started) {
            core.creation.tickWithMutations(services, allow_mutations);
            const state = core.creation.snapshot();
            core.phase = switch (state.phase) {
                .complete => .complete,
                .failed => .failed,
                .canceled => .canceled,
                else => .creating,
            };
            if (state.failure) |err| core.failure = err;
            if (core.phase == .complete or core.phase == .failed or core.phase == .canceled) {
                if (core.job) |job| {
                    job.destroy();
                    core.job = null;
                }
                core.request = null;
            }
        }
    }
    pub fn publish(self: *Controller, services: Services, allow_mutations: bool) !void {
        if (!allow_mutations) return error.MutationsDisabled;
        const core = self.core;
        const state = core.creation.snapshot();
        if (!core.started or (state.phase != .awaiting_publication and state.phase != .awaiting_reconciliation)) return error.NoPendingPublication;
        core.creation.publishOrdinary(services, allow_mutations) catch |err| {
            core.failure = err;
            return err;
        };
        core.failure = null;
    }
    pub fn cancel(self: *Controller, services: Services) void {
        if (self.core.job) |job| job.cancel.store(true, .release);
        if (self.core.started) {
            self.core.creation.cancel(services);
        } else if (self.core.phase == .ready) {
            if (self.core.job) |job| job.destroy();
            self.core.job = null;
            self.core.request = null;
            self.core.phase = .canceled;
        }
    }
    pub fn snapshot(self: *const Controller) Snapshot {
        const core = self.core;
        return .{ .phase = core.phase, .busy = self.isBusy(), .failure = core.failure, .pack_plan = if (core.job) |job| if (job.thread == null) if (job.inspection) |inspection| inspection.pack else null else null else null, .manual_files = core.manual, .optional = core.optional, .creation = core.creation.snapshot(), .blocker = if (core.phase == .ready) self.blocker() else null };
    }
    pub fn creationSnapshot(self: *const Controller) instances.Snapshot {
        return self.core.creation.creationSnapshot();
    }
    /// Inspection details survive job destruction; creation uses ordinary Java/game
    /// details until the pack precommit hook starts reporting its own stages.
    pub fn details(self: *const Controller) tasks.Details {
        const core = self.core;
        const pack = core.telemetry.details();
        if (!core.started) return pack;
        const phase = core.creation.snapshot().phase;
        if (pack.stage == .queued or core.phase == .complete or phase == .awaiting_publication or phase == .awaiting_reconciliation)
            return core.creation.creationSnapshot().details;
        return pack;
    }
    pub fn ownership(self: *const Controller) @import("../application/creation_runtime.zig").Ownership {
        var result = self.core.creation.ownership();
        result.pinned = self.core.phase == .creating or result.instances_publication or result.java_discovery or result.java_download;
        return result;
    }
    pub fn presentsCreation(self: *const Controller, manager: *const instances.Manager) bool {
        return self.core.started and self.core.creation.presentsCreation(manager);
    }
    pub fn deinit(self: *Controller, services: Services) void {
        const core = self.core;
        core.creation.deinit(services);
        if (core.job) |job| job.destroy();
        core.choices_arena.deinit();
        core.options_arena.deinit();
        core.paths.deinit();
        core.a.destroy(core);
        self.* = undefined;
    }
};

test "pack controller inspection joins before exposing plan and accepts repeat inspection" {
    const test_io = std.testing.io;
    const fixtures = @import("../pack_install_fixture.zig");
    var fixture = try fixtures.Fixture.init();
    defer fixture.deinit();
    try fixtures.zip(fixture.tmp.dir, "source.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = fixtures.index }});
    const source = try fixture.path("source.mrpack");
    defer std.testing.allocator.free(source);
    var controller = try Controller.init(std.testing.allocator, test_io, &fixture.paths, .{});
    defer controller.deinit(undefined);
    for (0..2) |_| {
        var stale: tasks.Details = .{ .stage = .downloading, .received = 100, .total_bytes = 100 };
        stale.addFile(tasks.File.init("old.mrpack", 100, 100, 0, .complete, null));
        controller.core.telemetry.reportDetails(stale);
        try controller.inspectLocal(source);
        try std.testing.expect(controller.snapshot().busy);
        try std.testing.expect(controller.snapshot().pack_plan == null);
        controller.core.job.?.thread.?.join();
        controller.core.job.?.thread = null;
        controller.tick(undefined);
        const state = controller.snapshot();
        try std.testing.expectEqual(Phase.ready, state.phase);
        try std.testing.expectEqualStrings("Offline Pack", state.pack_plan.?.name);
        try std.testing.expect(state.blocker == null);
        try std.testing.expectEqual(@as(usize, 0), controller.details().file_count);
        try std.testing.expectEqual(@as(u64, 0), controller.details().received);
        try std.testing.expectEqual(@as(f64, 0), controller.details().bytes_per_second);
        try std.testing.expectError(error.UnknownPackFile, controller.setDecisions(&.{}, &.{.{ .path = "unknown", .include = true }}));
        try controller.setDecisions(&.{}, &.{});
    }
}

test "pack controller cancellation joins inspection without taking shared creation ownership" {
    const fixtures = @import("../pack_install_fixture.zig");
    var fixture = try fixtures.Fixture.init();
    defer fixture.deinit();
    try fixtures.zip(fixture.tmp.dir, "source.mrpack", &.{.{ .path = "modrinth.index.json", .bytes = fixtures.index }});
    const source = try fixture.path("source.mrpack");
    defer std.testing.allocator.free(source);
    var controller = try Controller.init(std.testing.allocator, std.testing.io, &fixture.paths, .{});
    defer controller.deinit(undefined);
    try controller.inspectLocal(source);
    controller.cancel(undefined);
    controller.core.job.?.thread.?.join();
    controller.core.job.?.thread = null;
    controller.tick(undefined);
    const released = controller.ownership();
    try std.testing.expect(!released.pinned and !released.instances_publication and !released.java_discovery and !released.java_download);
    try std.testing.expect(!controller.snapshot().busy);
}
