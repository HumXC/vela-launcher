//! Ownership, binding and cancellation regressions for loader-prepared bases.
const std = @import("std");
const A = std.mem.Allocator;
const dl = @import("../../downloader.zig");
const m = @import("../../minecraft/metadata/root.zig");
const loader = @import("../../minecraft/metadata_loader.zig");
const loader_install = @import("../install.zig");
const loaders = @import("../types.zig");
const namespace = @import("../../instance_namespace.zig");
const fs = @import("../../install/safe_fs.zig");
const Config = @import("../../minecraft/install.zig").Config;
const runPrepared = @import("../base_install.zig").runPrepared;

fn preparedRunNow(_: ?*anyopaque) u64 {
    return 0;
}
const prepared_run_control: loaders.Control = .{ .deadline_ms = 1, .now_ms = preparedRunNow };
// Missing assetIndex deliberately stops the shared executor before service/files IO.
const prepared_run_base =
    \\{"id":"1.20.1","mainClass":"vanilla.Main","libraries":[],"javaVersion":{"component":"java-runtime-gamma","majorVersion":17},"downloads":{"client":{"url":"https://piston-data.mojang.com/client.jar","sha1":"0000000000000000000000000000000000000000","size":8}}}
;
const prepared_run_profile =
    \\{"id":"fabric-fixture","inheritsFrom":"1.20.1","mainClass":"net.fabricmc.loader.impl.launch.knot.KnotClient","libraries":[{"name":"net.fabricmc:fabric-loader:0.16.0","url":"https://maven.fabricmc.net/"}]}
;
const PreparedRunFixture = struct {
    entries: [1]m.manifest.Entry = undefined,
    vanilla_calls: usize = 0,
    loader_calls: usize = 0,

    fn prepare(self: *PreparedRunFixture, a: A, io: std.Io, root: []const u8) !loader_install.PreparedMetadata {
        var checksum: m.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(prepared_run_base, &checksum, .{});
        self.entries = .{.{ .id = "1.20.1", .kind = "release", .url = "https://piston-meta.mojang.com/v1/packages/fixture/1.20.1.json", .time = "", .release_time = "", .sha1 = checksum, .compliance_level = null }};
        return loader_install.prepareMetadata(a, io, .{
            .root = root,
            .instance_id = "pack-fixture",
            .instance_name = "Final Pack",
            .generation = 7,
            .selection = .{ .kind = .fabric, .base_id = "1.20.1", .loader_id = "0.16.0" },
            .environment = .{ .os_name = "linux", .arch = "x86_64" },
            .vanilla = .{ .version_id = "1.20.1", .manifest = .{ .latest = .{ .release = "1.20.1", .snapshot = "1.20.1" }, .versions = &self.entries } },
            .fetcher = .{ .context = self, .fetch = vanilla },
            .transport = .{ .context = self, .get = get },
        }, prepared_run_control);
    }
    fn vanilla(raw: ?*anyopaque, a: A, _: std.Io, request: loader.Request) ![]u8 {
        const self: *PreparedRunFixture = @ptrCast(@alignCast(raw.?));
        self.vanilla_calls += 1;
        try std.testing.expect(request.sha1 != null);
        return a.dupe(u8, prepared_run_base);
    }
    fn get(raw: ?*anyopaque, a: A, url: []const u8, _: usize, control: loaders.Control) !loaders.Response {
        try control.check();
        const self: *PreparedRunFixture = @ptrCast(@alignCast(raw.?));
        self.loader_calls += 1;
        const body = if (std.mem.endsWith(u8, url, "/v2/versions/loader/1.20.1"))
            try a.dupe(u8, "[{\"loader\":{\"version\":\"0.16.0\",\"stable\":true}}]")
        else if (std.mem.endsWith(u8, url, "/profile/json"))
            try a.dupe(u8, prepared_run_profile)
        else
            return error.UnexpectedFixtureRequest;
        errdefer a.free(body);
        return .{ .bytes = body, .final_url = try a.dupe(u8, url), .status = 200 };
    }
};
test "metadata preparation owns fresh stages through native cancel open sync and cleanup faults" {
    const Fault = @import("stage_owner.zig").FaultIo;
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]Fault.Mode{ .cancel_create, .fail_open, .fail_sync, .fail_cleanup }) |mode| {
        if (mode == .fail_sync and !@import("../../worlds_tree.zig").directory_sync_supported) continue;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var fixture: PreparedRunFixture = .{};
        var fault: Fault = .{ .mode = mode, .prefix = ".metadata-" };
        const fault_io = fault.start();
        defer fault.stop();
        const expected = switch (mode) {
            .cancel_create => error.Canceled,
            .fail_open => error.AccessDenied,
            .fail_sync => error.InputOutput,
            .fail_cleanup => error.RecoveryRequired,
            else => unreachable,
        };
        try std.testing.expectError(expected, fixture.prepare(a, fault_io, root));
        try std.testing.expect(fault.created);
        try std.testing.expectEqual(mode != .fail_cleanup, fault.removed);
        var versions = try tmp.dir.openDir(io, ".minecraft/versions", .{ .iterate = true });
        defer versions.close(io);
        var iterator = versions.iterate();
        var stages: usize = 0;
        while (try iterator.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, ".metadata-")) stages += 1;
        }
        try std.testing.expectEqual(@as(usize, if (mode == .fail_cleanup) 1 else 0), stages);
    }
}

fn preparedRunTarget(prepared: *const loader_install.PreparedMetadata) loader_install.MetadataTarget {
    return .{ .root = prepared.root, .instance_id = prepared.instance_id, .instance_name = prepared.instance_name, .generation = prepared.generation, .selection = prepared.selection, .environment = prepared.environment };
}
fn preparedRunConfig(minecraft: []const u8) Config {
    return .{ .version_id = "1.20.1", .root = minecraft, .target = .{ .directory_name = "private-stage", .name = "Final Pack" }, .environment = .{ .os_name = "linux", .arch = "x86_64" }, .manifest_url = "https://example.invalid/not-replay", .metadata_path = "missing-prepared-version.json" };
}

test "prepared executor binds final target and actual planner environment before artifact IO" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: PreparedRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = preparedRunTarget(&prepared);
    const config = preparedRunConfig(minecraft);
    var service: dl.Service = undefined;
    // Private stage name must not be compared with the final prepared name.
    try std.testing.expectError(error.MissingAssetIndex, runPrepared(a, io, &service, config, &prepared, target, prepared_run_control));
    var wrong_target = target;
    wrong_target.generation = 8;
    try std.testing.expectError(error.PreparedMetadataGenerationMismatch, runPrepared(a, io, &service, config, &prepared, wrong_target, prepared_run_control));
    wrong_target = target;
    wrong_target.generation = 0;
    try std.testing.expectError(error.PreparedMetadataGenerationMismatch, runPrepared(a, io, &service, config, &prepared, wrong_target, prepared_run_control));
    wrong_target = target;
    wrong_target.instance_id = "different-instance";
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, config, &prepared, wrong_target, prepared_run_control));
    wrong_target = target;
    wrong_target.instance_name = "different-final-name";
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, config, &prepared, wrong_target, prepared_run_control));
    wrong_target = target;
    wrong_target.selection.loader_id = "changed-loader";
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, config, &prepared, wrong_target, prepared_run_control));
    var wrong_config = config;
    wrong_config.version_id = "1.20.2";
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, wrong_config, &prepared, target, prepared_run_control));
    wrong_config = config;
    wrong_config.root = root;
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, wrong_config, &prepared, target, prepared_run_control));
    wrong_config = config;
    wrong_config.environment.arch = "aarch64";
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, wrong_config, &prepared, target, prepared_run_control));
    wrong_config = config;
    wrong_config.environment.os_version = "changed-os";
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, wrong_config, &prepared, target, prepared_run_control));
    wrong_config = config;
    wrong_config.environment.features = &.{.{ .name = "demo", .enabled = true }};
    try std.testing.expectError(error.PreparedMetadataMismatch, runPrepared(a, io, &service, wrong_config, &prepared, target, prepared_run_control));
    try std.testing.expectEqual(@as(usize, 1), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.loader_calls);
    const stage_descriptor = try std.fs.path.join(a, &.{ minecraft, "versions", "private-stage", "private-stage.json" });
    defer a.free(stage_descriptor);
    try std.testing.expectError(error.FileNotFound, fs.read(a, io, stage_descriptor, 1024, null));
}

test "prepared executor validates window IDs cancellation and deadline without touching owners" {
    const prepared: loader_install.PreparedMetadata = undefined;
    const target: loader_install.MetadataTarget = .{ .root = ".", .instance_id = "pack-fixture", .instance_name = "Final Pack", .generation = 7, .selection = .{ .kind = .fabric, .base_id = "1.20.1", .loader_id = "0.16.0" }, .environment = .{ .os_name = "linux", .arch = "x86_64" } };
    var service: dl.Service = undefined;
    var config = preparedRunConfig(".minecraft");
    config.window = 0;
    try std.testing.expectError(error.InvalidWindow, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, prepared_run_control));
    config.window = 129;
    try std.testing.expectError(error.InvalidWindow, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, prepared_run_control));
    config.window = 16;
    config.version_id = "../escape";
    try std.testing.expectError(error.UnsafeVersionId, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, prepared_run_control));
    config.version_id = "1.20.1";
    config.target.directory_name = "../escape";
    try std.testing.expectError(error.UnsafeVersionId, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, prepared_run_control));
    config.target.directory_name = "private-stage";
    var cancel = std.atomic.Value(bool).init(true);
    config.cancel = &cancel;
    try std.testing.expectError(error.Canceled, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, prepared_run_control));
    config.cancel = null;
    var control = prepared_run_control;
    control.cancel = &cancel;
    try std.testing.expectError(error.Canceled, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, control));
    control.cancel = null;
    control.deadline_ms = 0;
    try std.testing.expectError(error.DeadlineExceeded, runPrepared(std.testing.allocator, std.testing.io, &service, config, &prepared, target, control));
}

test "prepared executor preserves frozen owners across shared-executor errors and rejects mutation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: PreparedRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = preparedRunTarget(&prepared);
    const config = preparedRunConfig(minecraft);
    var service: dl.Service = undefined;
    const original_class = prepared.base.value.main_class;
    prepared.base.value.main_class = "changed.Main";
    try std.testing.expectError(error.PreparedMetadataChanged, runPrepared(a, io, &service, config, &prepared, target, prepared_run_control));
    prepared.base.value.main_class = original_class;
    const original_profile = prepared.bundle.profile;
    prepared.bundle.profile = "{}";
    try std.testing.expectError(error.PreparedMetadataChanged, runPrepared(a, io, &service, config, &prepared, target, prepared_run_control));
    prepared.bundle.profile = original_profile;
    for (0..2) |_| try std.testing.expectError(error.MissingAssetIndex, runPrepared(a, io, &service, config, &prepared, target, prepared_run_control));
    try prepared.validateBinding(a, io, target);
    try std.testing.expectEqualStrings("vanilla.Main", prepared.base.value.main_class.?);
    try std.testing.expectEqualStrings(prepared_run_base, prepared.vanilla_sources[0].bytes);
    try std.testing.expectEqual(@as(usize, 1), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.loader_calls);
}

fn preparedRunAllocationFailure(a: A, config: Config, prepared: *const loader_install.PreparedMetadata, target: loader_install.MetadataTarget) !void {
    var service: dl.Service = undefined;
    var installed = runPrepared(a, std.testing.io, &service, config, prepared, target, prepared_run_control) catch |err| switch (err) {
        error.MissingAssetIndex => return,
        else => return err,
    };
    installed.deinit();
    return error.UnexpectedFixtureInstallSuccess;
}
test "prepared replay and consuming executor release independent owners on every allocation failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: PreparedRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = preparedRunTarget(&prepared);
    try @import("test_allocations").checkAllAllocationFailures(a, preparedRunAllocationFailure, .{ preparedRunConfig(minecraft), &prepared, target });
    try prepared.validateBinding(a, io, target);
    try std.testing.expectEqual(@as(usize, 1), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.loader_calls);
}

const PostReplayClock = struct {
    calls: usize = 0,
    deadline_after: ?usize = null,
    cancel_at: ?usize = null,
    cancel_target: ?*std.atomic.Value(bool) = null,
    fn now(raw: ?*anyopaque) u64 {
        const self: *PostReplayClock = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.cancel_at) |n| {
            if (self.calls == n) {
                if (self.cancel_target) |flag| flag.store(true, .release);
            }
        }
        if (self.deadline_after) |n| if (self.calls > n) return 1;
        return 0;
    }
};

test "prepared executor retains deadline and distinct cancellation flags after replay" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var fixture: PreparedRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const target = preparedRunTarget(&prepared);
    var config_cancel: std.atomic.Value(bool) = .init(false);
    var loader_cancel: std.atomic.Value(bool) = .init(false);
    var config = preparedRunConfig(minecraft);
    config.cancel = &config_cancel;
    var clock: PostReplayClock = .{};
    const control: loaders.Control = .{ .cancel = &loader_cancel, .deadline_ms = 1, .context = &clock, .now_ms = PostReplayClock.now };
    var replay = try prepared.replayBase(a, io, target, control);
    // Calibrate replay's checks; runPrepared adds one entry check before replay.
    const last_replay_check = clock.calls + 1;
    replay.deinit();
    try std.testing.expect(prepared.base.value.asset_index == null);
    const vanilla_calls = fixture.vanilla_calls;
    const loader_calls = fixture.loader_calls;
    var service: dl.Service = undefined;
    clock.calls = 0;
    clock.deadline_after = last_replay_check;
    try std.testing.expectError(error.DeadlineExceeded, runPrepared(a, io, &service, config, &prepared, target, control));
    try std.testing.expectEqual(last_replay_check + 1, clock.calls);
    clock.deadline_after = null;
    const flags = [_]*std.atomic.Value(bool){ &config_cancel, &loader_cancel };
    for (flags) |flag| {
        config_cancel.store(false, .release);
        loader_cancel.store(false, .release);
        clock.calls = 0;
        clock.cancel_at = last_replay_check;
        clock.cancel_target = flag;
        try std.testing.expectError(error.Canceled, runPrepared(a, io, &service, config, &prepared, target, control));
        try std.testing.expectEqual(last_replay_check, clock.calls);
        try std.testing.expect(flag.load(.acquire));
        const other = if (flag == &config_cancel) &loader_cancel else &config_cancel;
        try std.testing.expect(!other.load(.acquire));
    }
    try prepared.validateBinding(a, io, target);
    try std.testing.expectEqual(vanilla_calls, fixture.vanilla_calls);
    try std.testing.expectEqual(loader_calls, fixture.loader_calls);
}

test "artifacts-only consuming executor releases direct namespace and retains borrowed namespace on error" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var fixture: PreparedRunFixture = .{};
    var prepared = try fixture.prepare(a, io, root);
    defer prepared.deinit();
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var config = preparedRunConfig(minecraft);
    config.publish_metadata = false;
    const target = preparedRunTarget(&prepared);
    var service: dl.Service = undefined;
    try std.testing.expectError(error.MissingAssetIndex, runPrepared(a, io, &service, config, &prepared, target, prepared_run_control));
    const token = try namespace.acquire(io);
    defer token.release();
    config.namespace_token = token;
    try std.testing.expectError(error.MissingAssetIndex, runPrepared(a, io, &service, config, &prepared, target, prepared_run_control));
    try token.recheck();
    try std.testing.expectError(error.InstanceNamespaceBusy, namespace.acquire(io));
    try std.testing.expectEqual(@as(usize, 1), fixture.vanilla_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.loader_calls);
}
