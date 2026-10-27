//! Copies downloader snapshots into bounded task telemetry before handle release.
const std = @import("std");
const dl = @import("../downloader.zig");
const tasks = @import("../tasks.zig");

pub fn file(path: []const u8, snapshot: dl.Snapshot) tasks.File {
    const state: tasks.FileState = switch (snapshot.progress.phase) {
        .queued, .preparing, .ready => .queued,
        .downloading => .downloading,
        .processing, .parsing, .committing => .verifying,
        .complete => .complete,
        .failed => .failed,
        .canceled => .canceled,
    };
    return tasks.File.init(path, snapshot.progress.received, snapshot.progress.total, snapshot.progress.bytes_per_second, state, snapshot.failure);
}

pub fn single(task: ?*tasks.Task, stage: tasks.Stage, path: []const u8, snapshot: dl.Snapshot) void {
    const target = task orelse return;
    const value = file(path, snapshot);
    var details: tasks.Details = .{ .stage = stage, .received = value.received, .total_bytes = value.total, .bytes_per_second = value.bytes_per_second };
    details.addFile(value);
    target.reportDetails(details);
}

test "snapshot copy owns filename and preserves actual unknown and terminal measurements" {
    var label = [_]u8{ '/', 'x', '/', 'a', '.', 'j', 'a', 'r' };
    var snapshot: dl.Snapshot = .{ .progress = .{ .phase = .downloading, .received = 32, .total = null, .bytes_per_second = 17.5 }, .result = null, .failure = null, .source = .network, .http_status = 0 };
    const copied = file(&label, snapshot);
    @memset(&label, 'z');
    try std.testing.expectEqualStrings("a.jar", copied.name());
    try std.testing.expectEqualStrings("/x/a.jar", copied.path());
    try std.testing.expectEqual(@as(u64, 32), copied.received);
    try std.testing.expectEqual(@as(?u64, null), copied.total);
    try std.testing.expectEqual(@as(f64, 17.5), copied.bytes_per_second);
    snapshot.progress.phase = .failed;
    snapshot.failure = error.ChecksumMismatch;
    const failed = file("bad.jar", snapshot);
    try std.testing.expectEqual(tasks.FileState.failed, failed.state);
    try std.testing.expectEqual(@as(?anyerror, error.ChecksumMismatch), failed.failure);
    try std.testing.expectEqual(@as(f64, 0), failed.bytes_per_second);
}

/// Retains the artifact snapshot across sidecar fetches and verification/write work.
pub const Artifact = struct {
    task: ?*tasks.Task,
    details: tasks.Details,

    pub fn capture(target: ?*tasks.Task, path: []const u8) Artifact {
        var details = if (target) |task| task.details() else tasks.Details{};
        const label = tasks.File.init(path, 0, null, 0, .verifying, null);
        var found: ?tasks.File = null;
        for (details.files[0..details.file_count]) |entry| {
            if (std.mem.eql(u8, entry.path(), label.path())) {
                found = entry;
                break;
            }
        }
        const entry = found orelse label;
        details.file_count = 0;
        details.omitted_files = 0;
        details.addFile(entry);
        details.received = entry.received;
        details.total_bytes = entry.total;
        details.stop();
        return .{ .task = target, .details = details };
    }

    pub fn publish(self: *Artifact, state: tasks.FileState, failure: ?anyerror) void {
        const target = self.task orelse return;
        self.details.stage = .verifying;
        self.details.files[0].state = state;
        self.details.files[0].failure = failure;
        self.details.stop();
        target.reportDetails(self.details);
    }

    pub fn fail(self: *Artifact, failure: anyerror) void {
        self.publish(if (failure == error.Canceled) .canceled else .failed, failure);
    }
};

/// Adapts the synchronous loader HTTP client without changing its error contract.
pub const HttpObserver = struct {
    task: ?*tasks.Task,
    path: []const u8,
    stage: tasks.Stage = .metadata,
    pub fn observer(self: *HttpObserver) @import("../http_transport.zig").Observer {
        report(self, .{});
        return .{ .context = self, .report = report };
    }
    fn report(raw: ?*anyopaque, value: @import("../http_transport.zig").Progress) void {
        const self: *HttpObserver = @ptrCast(@alignCast(raw.?));
        const target = self.task orelse return;
        const state: tasks.FileState = if (value.failure) |err| if (err == error.Canceled) .canceled else .failed else if (value.complete) .complete else .downloading;
        const entry = tasks.File.init(self.path, value.received, value.total, value.bytes_per_second, state, value.failure);
        var details: tasks.Details = .{ .stage = self.stage, .received = entry.received, .total_bytes = entry.total, .bytes_per_second = entry.bytes_per_second };
        details.addFile(entry);
        target.reportDetails(details);
    }
    pub fn fail(self: *HttpObserver, failure: anyerror) void {
        const target = self.task orelse return;
        var details = target.details();
        if (details.file_count != 0) {
            details.files[0].failure = failure;
            details.files[0].state = if (failure == error.Canceled) .canceled else .failed;
        }
        details.stop();
        target.reportDetails(details);
    }
};

test "HTTP bridge owns actual file label and retains terminal error" {
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const task = try registry.create(.game_install, "Loader");
    var path = "/loader.jar".*;
    var adapter: HttpObserver = .{ .task = task, .path = &path, .stage = .downloading };
    const observer_value = adapter.observer();
    observer_value.report(observer_value.context, .{ .received = 20, .total = null, .bytes_per_second = 15 });
    @memset(&path, 'z');
    const live = task.details();
    try std.testing.expectEqualStrings("loader.jar", live.files[0].name());
    try std.testing.expectEqual(@as(u64, 20), live.received);
    try std.testing.expectEqual(@as(?u64, null), live.total_bytes);
    try std.testing.expectEqual(@as(f64, 15), live.bytes_per_second);
    adapter.fail(error.ResourceLimit);
    const failed = task.details();
    try std.testing.expectEqualStrings("loader.jar", failed.files[0].name());
    try std.testing.expectEqual(@as(?anyerror, error.ResourceLimit), failed.files[0].failure);
    try std.testing.expectEqual(tasks.FileState.failed, failed.files[0].state);
    try std.testing.expectEqual(@as(f64, 0), failed.bytes_per_second);
}

test "cleanup joins final partial snapshot and preserves a prior real failure under cancellation" {
    const curl = @import("curl");
    const multi = curl.libcurl.curl_multi_init() orelse return error.CurlInit;
    defer _ = curl.libcurl.curl_multi_cleanup(multi);
    // This stack task is never submitted. The only worker publishes a final sample
    // after observing cancellation; no network or filesystem operation is possible.
    var budget = try dl.Budget.init(std.testing.io, 1);
    defer budget.deinit();
    var service: dl.Service = .{ .allocator = std.testing.allocator, .io = std.testing.io, .multi = multi, .max_active = 1, .budget = &budget };
    var url = "https://example.invalid/partial.jar".*;
    var download: dl.Task = .{ .service = &service, .request = .{ .url = &url }, .url = &url, .temp = &.{}, .progress = .{ .phase = .downloading, .received = 8, .total = 128, .bytes_per_second = 20 } };
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const target = try registry.create(.game_install, "Cancel sample");
    single(target, .downloading, &url, download.snapshot());
    const Worker = struct {
        fn finish(task: *dl.Task) void {
            while (!task.canceled.load(.acquire)) std.atomic.spinLoopHint();
            const owner = task.service;
            owner.mutex.lockUncancelable(owner.io);
            defer owner.mutex.unlock(owner.io);
            task.progress.received = 37;
            task.progress.phase = .canceled;
            task.failure = error.Canceled;
            task.completion.set(owner.io);
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.finish, .{&download});
    defer worker.join();
    download.cancel();
    download.join();
    single(target, .downloading, &url, download.snapshot());
    const canceled = target.details();
    try std.testing.expectEqual(@as(u64, 37), canceled.received);
    try std.testing.expectEqual(@as(?u64, 128), canceled.total_bytes);
    try std.testing.expectEqual(tasks.FileState.canceled, canceled.files[0].state);
    try std.testing.expectEqual(@as(f64, 0), canceled.bytes_per_second);
    download.progress.phase = .failed;
    download.failure = error.ChecksumMismatch;
    download.cancel();
    download.join();
    single(target, .downloading, &url, download.snapshot());
    registry.finish(target, .canceled);
    const failed = target.details();
    try std.testing.expectEqual(tasks.FileState.failed, failed.files[0].state);
    try std.testing.expectEqual(@as(?anyerror, error.ChecksumMismatch), failed.files[0].failure);
    try std.testing.expectEqual(@as(u64, 37), failed.received);
    try std.testing.expectEqual(@as(f64, 0), failed.bytes_per_second);
}
