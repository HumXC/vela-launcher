//! Build-bound adapter smoke test: no network request or JDK download.
const std = @import("std");
const downloader = @import("downloader.zig");
const curl = @import("curl");
const java = @import("java_download.zig");

test "Java Service adapter typechecks real downloader and rejects non HTTP transport" {
    try curl.globalInit();
    defer curl.globalDeinit();
    const service = try downloader.Service.init(std.testing.allocator, std.testing.io, 1);
    defer service.deinit();
    var adapter: java.ServiceTransport(downloader.Service) = .{ .service = service, .io = std.testing.io };
    const transport = adapter.transport();
    try std.testing.expectError(error.InvalidUrl, transport.get(transport.context, std.testing.allocator, "file:///unused", 4096, .{}));
    const release: java.RuntimeRelease = .{
        .allocator = std.testing.allocator,
        .vendor = .microsoft,
        .major = 21,
        .platform = .{ .os = .linux, .arch = .x64 },
        .version = "21.0.1",
        .url = "file:///unused",
        .archive = .tar_gz,
        .sha256 = @splat(0),
    };
    try std.testing.expectError(error.InvalidUrl, transport.download(transport.context, std.testing.io, &release, "unused", .{}));
}

test "Java adapter forwards measured downloading rate and keeps exact downloader sizes" {
    const FakeService = struct {
        request: ?downloader.Request = null,
        task: Task = .{},
        const Task = struct {
            index: usize = 0,
            pub fn cancel(_: *@This()) void {}
            pub fn release(_: *@This()) !void {}
            pub fn snapshot(self: *@This()) downloader.Snapshot {
                const index = self.index;
                self.index += 1;
                return .{ .progress = .{ .phase = if (index == 0) .downloading else if (index == 1) .processing else .complete, .received = 501, .total = 501, .bytes_per_second = 4321 }, .failure = null, .result = .{ .bytes = "metadata" }, .source = .network, .http_status = 200 };
            }
        };
        pub fn submit(self: *@This(), request: downloader.Request) !*Task {
            self.request = request;
            self.task = .{};
            return &self.task;
        }
    };
    const Capture = struct {
        measured: usize = 0,
        cleared: usize = 0,
        last: ?java.Progress = null,
        pub fn progress(ctx: ?*anyopaque, p: java.Progress) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.last = p;
            if (p.bytes_per_second == 4321) self.measured += 1 else if (p.bytes_per_second == 0) self.cleared += 1;
        }
    };
    var service: FakeService = .{};
    var adapter: java.ServiceTransport(FakeService) = .{ .service = &service, .io = std.testing.io };
    const transport = adapter.transport();
    var capture: Capture = .{};
    var release: java.RuntimeRelease = .{ .allocator = std.testing.allocator, .vendor = .azul, .major = 21, .platform = .{ .os = .linux, .arch = .x64 }, .version = "21.0.1", .url = "https://cdn.azul.com/zulu/bin/fixture.tar.gz", .archive = .tar_gz, .sha256 = @splat(0), .size = 1000, .size_precision = .azul_rounded_kilobyte };
    const hooks: java.Hooks = .{ .context = &capture, .progress = Capture.progress };
    try transport.download(transport.context, std.testing.io, &release, "unused", hooks);
    try std.testing.expectEqual(@as(usize, 1), capture.measured);
    try std.testing.expectEqual(@as(usize, 2), capture.cleared);
    try std.testing.expectEqual(@as(u64, 501), capture.last.?.received);
    try std.testing.expectEqual(@as(f64, 0), capture.last.?.bytes_per_second);
    try std.testing.expectEqual(@as(?u64, null), service.request.?.expected_size);
    try std.testing.expectEqual(@as(?usize, 1499), service.request.?.max_bytes);
    release.size_precision = .exact;
    try transport.download(transport.context, std.testing.io, &release, "unused", .{});
    try std.testing.expectEqual(@as(?u64, 1000), service.request.?.expected_size);
    capture = .{};
    const bytes = try transport.get(transport.context, std.testing.allocator, "https://example.invalid/metadata", 4096, hooks);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), capture.measured);
    try std.testing.expectEqual(@as(usize, 3), capture.cleared);
    try std.testing.expectEqual(java.Phase.metadata, capture.last.?.phase);
}

test "Java adapter forwards final child bytes on success failure and cancellation before release" {
    const FakeService = struct {
        task: Task = .{},
        const Task = struct {
            phase: downloader.Phase = .complete,
            total: ?u64 = 106674581,
            index: usize = 0,
            cancel_requested: bool = false,
            released: bool = false,
            submitted: bool = false,
            pub fn cancel(self: *@This()) void {
                self.cancel_requested = true;
            }
            pub fn release(self: *@This()) !void {
                self.released = true;
            }
            pub fn snapshot(self: *@This()) downloader.Snapshot {
                const terminal = self.index > 0;
                self.index += 1;
                return .{
                    .progress = .{
                        .phase = if (terminal) self.phase else .downloading,
                        .received = if (!terminal) 24482688 else if (self.phase == .complete) 106674581 else 24482691,
                        .total = self.total,
                        // Stale downloader speed must never escape a terminal sample.
                        .bytes_per_second = 14575206.4,
                    },
                    .failure = if (!terminal or self.phase == .complete) null else if (self.phase == .canceled) error.Canceled else error.ChecksumMismatch,
                    .result = null,
                    .source = .network,
                    .http_status = 200,
                };
            }
        };
        pub fn submit(self: *@This(), _: downloader.Request) !*Task {
            self.task.submitted = true;
            return &self.task;
        }
    };
    const Capture = struct {
        task: *FakeService.Task,
        values: [2]java.Progress = undefined,
        count: usize = 0,
        cancel: bool = false,
        fn canceled(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return self.cancel and self.task.submitted;
        }
        fn progress(ctx: ?*anyopaque, value: java.Progress) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.values[self.count] = value;
            self.count += 1;
        }
    };
    for ([_]downloader.Phase{ .complete, .failed, .canceled, .complete }, 0..) |phase, index| {
        const hook_cancel = index == 3;
        var service: FakeService = .{ .task = .{ .phase = phase, .total = if (phase == .complete) 106674581 else null } };
        var adapter: java.ServiceTransport(FakeService) = .{ .service = &service, .io = std.testing.io };
        const transport = adapter.transport();
        var capture: Capture = .{ .task = &service.task, .cancel = hook_cancel };
        const hooks: java.Hooks = .{ .context = &capture, .canceled = Capture.canceled, .progress = Capture.progress };
        const release: java.RuntimeRelease = .{ .allocator = std.testing.allocator, .vendor = .microsoft, .major = 21, .platform = .{ .os = .linux, .arch = .x64 }, .version = "21.0.1", .url = "https://aka.ms/download-jdk/fixture.tar.gz", .archive = .tar_gz, .sha256 = @splat(0) };
        if (phase == .complete and !hook_cancel) {
            try transport.download(transport.context, std.testing.io, &release, "unused", hooks);
        } else {
            try std.testing.expectError(if (hook_cancel or phase == .canceled) error.Canceled else error.ChecksumMismatch, transport.download(transport.context, std.testing.io, &release, "unused", hooks));
        }
        try std.testing.expect(service.task.released);
        try std.testing.expectEqual(hook_cancel, service.task.cancel_requested);
        try std.testing.expectEqual(@as(usize, 2), capture.count);
        try std.testing.expectEqual(@as(u64, 24482688), capture.values[0].received);
        try std.testing.expectEqual(@as(f64, if (hook_cancel) 0 else 14575206.4), capture.values[0].bytes_per_second);
        const final = capture.values[1];
        try std.testing.expectEqual(java.Phase.downloading, final.phase);
        try std.testing.expectEqual(@as(u64, if (phase == .complete) 106674581 else 24482691), final.received);
        try std.testing.expectEqual(service.task.total, final.total);
        try std.testing.expectEqual(@as(f64, 0), final.bytes_per_second);
    }
}
