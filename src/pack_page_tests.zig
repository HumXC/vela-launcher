const std = @import("std");
const fixtures = @import("pack_install_fixture.zig");
const page_mod = @import("ui/pack_page.zig");
const install = @import("application/pack_install_controller.zig");
const config = @import("core/config.zig");
const http = @import("core/http_transport.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const Download = struct {
    bytes: []const u8,
    release: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),
    fail: bool = false,
    fn request(raw: ?*anyopaque, allocator: std.mem.Allocator, request_io: std.Io, req: http.Request) !http.Response {
        const self: *Download = @ptrCast(@alignCast(raw.?));
        try std.testing.expectEqualStrings("https://cdn.modrinth.com/fixture.mrpack", req.url);
        self.entered.store(true, .release);
        while (!self.release.load(.acquire)) try request_io.sleep(.fromMilliseconds(1), .awake);
        if (self.fail) return error.ConnectionRefused;
        const body = try allocator.dupe(u8, self.bytes);
        return .{ .allocator = allocator, .status = 200, .body = body, .allocation = body };
    }
};

test "pack online prepare shows a task then confirms or reports failure and cancellation" {
    for (0..5) |scenario| {
        var fixture = try fixtures.Fixture.init();
        defer fixture.deinit();
        try fixtures.zip(fixture.tmp.dir, "source.mrpack", &.{
            .{ .path = "modrinth.index.json", .bytes = fixtures.index },
            .{ .path = if (scenario == 4) "overrides/assets/forbidden.txt" else "overrides/saves/枪战地图/level.dat", .bytes = "initial world" },
        });
        const bytes = try fixture.tmp.dir.readFileAlloc(io, "source.mrpack", a, .limited(1024 * 1024));
        defer a.free(bytes);
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(bytes, &digest, .{});
        var hash = std.fmt.bytesToHex(digest, .lower);
        if (scenario == 3) hash[0] = if (hash[0] == '0') '1' else '0';
        var download: Download = .{ .bytes = bytes, .fail = scenario == 1 };
        var store = try config.Store.init(a, io, fixture.paths.root);
        defer store.deinit();
        const services: install.Services = .{ .store = &store, .java = undefined, .java_download = undefined, .instances = undefined };
        var registry = @import("core/tasks.zig").Registry.init(a);
        defer registry.deinit();
        var budget = try @import("core/downloader.zig").Budget.init(io, 8);
        defer budget.deinit();
        var page = try page_mod.Page.init(a, io, &fixture.paths, &registry, &budget);
        defer page.deinit(services);
        try std.testing.expectEqualStrings(fixture.paths.cache, page.installer.core.options.backend_options.transport_options.cache_root.?);
        // Always release the fixture before Page joins its worker, including on assertion failure.
        defer download.release.store(true, .release);
        page.installer.core.options.backend_options.transport_options.fixture_http = Download.request;
        page.installer.core.options.backend_options.transport_options.fixture_context = &download;
        try page.ui.acceptCatalog(&.{.{ .provider = .modrinth, .id = "project1", .name = "Fixture pack", .official_page = "https://modrinth.com/modpack/project1" }}, 1);
        try page.ui.openProject(0);
        try page.ui.acceptVersions(&.{.{ .provider = .modrinth, .project_id = "project1", .id = "version1", .name = "Release", .minecraft_versions = &.{"1.20.1"}, .loaders = &.{"vanilla"}, .dependencies = &.{}, .files = &.{.{ .filename = "fixture.mrpack", .hashes = .{ .sha1 = &hash }, .size = bytes.len, .primary = true, .download = .{ .remote = "https://cdn.modrinth.com/fixture.mrpack" } }} }});
        page.ui.active = true;
        var model: @import("ui/model.zig").Model = .{};
        var navigation = @import("ui/instances_view.zig").Ui.init(a);
        defer navigation.deinit();
        page.ui.queue(.prepare);
        page.finish(&model, &navigation, services, true);
        try std.testing.expect(page.ui.failure == null);
        try std.testing.expectEqualStrings(fixture.paths.cache, page.installer.core.options.backend_options.transport_options.cache_root.?);
        try std.testing.expect(page.ui.task_visible and page.opening);
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        for (0..5000) |_| {
            if (download.entered.load(.acquire)) break;
            if (page.installer.core.job.?.done.load(.acquire)) return page.installer.core.job.?.failure orelse error.DownloadEndedBeforeCallback;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        try std.testing.expect(download.entered.load(.acquire));
        const pending = try page.presentation(arena.allocator());
        try std.testing.expectEqual(.working, pending.task);
        try std.testing.expectEqualStrings("正在下载整合包归档", pending.stage);
        try std.testing.expectEqual(@as(usize, 1), pending.details.file_count);
        try std.testing.expectEqualStrings("fixture.mrpack", pending.details.files[0].name());
        try std.testing.expectEqual(.downloading, pending.details.files[0].state);
        try std.testing.expectEqual(@as(?u64, bytes.len), pending.details.total_bytes);
        try std.testing.expectEqual(@as(u64, 0), pending.details.received);
        if (scenario == 2) {
            page.ui.queue(.cancel);
            page.finish(&model, &navigation, services, true);
        }
        download.release.store(true, .release);
        page.installer.core.job.?.thread.?.join();
        page.installer.core.job.?.thread = null;
        page.installer.tickWithMutations(services, true);
        page.tickPresentation(services, true);
        try std.testing.expect(!page.opening);
        const result = try page.presentation(arena.allocator());
        if (scenario == 0) {
            try std.testing.expectEqual(.confirm, page.ui.route);
            try std.testing.expectEqual(.none, result.task);
            try std.testing.expect(result.ready);
        } else {
            try std.testing.expectEqual(if (scenario == 2) @as(@import("ui/pack_view.zig").Task, .canceled) else .failed, result.task);
            try std.testing.expectEqual(.detail, page.ui.route);
            try std.testing.expectEqual(@as(f64, 0), result.details.files[0].bytes_per_second);
            try std.testing.expectEqual(@as(usize, if (scenario == 4) 2 else 1), result.details.file_count);
            try std.testing.expectEqualStrings("fixture.mrpack", result.details.files[0].name());
            try std.testing.expectEqual(@as(f64, 0), result.details.bytes_per_second);
            if (scenario == 1 or scenario == 3) {
                try std.testing.expectEqual(if (scenario == 1) @as(anyerror, error.ConnectionRefused) else error.Sha1Mismatch, result.details.files[0].failure.?);
                if (scenario == 3) {
                    try std.testing.expectEqual(.verifying, result.details.stage);
                    try std.testing.expectEqual(@as(u64, bytes.len), result.details.received);
                }
                try std.testing.expectEqual(.failed, result.details.files[0].state);
                try std.testing.expect(page.installer.core.job == null);
                try std.testing.expectEqualDeep(result.details, page.installer.details());
            }
            if (scenario == 4) {
                try std.testing.expectEqual(error.ProtectedPath, result.failure.?);
                try std.testing.expectEqual(.extracting, result.details.stage);
                try std.testing.expectEqual(.complete, result.details.files[0].state);
                try std.testing.expectEqualStrings("assets", result.details.files[1].path());
                try std.testing.expectEqual(error.ProtectedPath, result.details.files[1].failure.?);
                try std.testing.expectEqualStrings("解压或检查整合包失败", @import("ui/pack_view.zig").failureStage(result.details.stage));
                try std.testing.expect(page.installer.core.job == null);
                try std.testing.expectEqualDeep(result.details, page.installer.details());
            }
            page.ui.queue(.dismiss);
            page.finish(&model, &navigation, services, true);
            try std.testing.expect(!page.ui.task_visible);
        }
    }
}

test "local pack inspection shows failure and cancellation in the task modal and allows retry" {
    var fixture = try fixtures.Fixture.init();
    defer fixture.deinit();
    const source = try fixture.path("local.mrpack");
    defer a.free(source);
    var store = try config.Store.init(a, io, fixture.paths.root);
    defer store.deinit();
    const services: install.Services = .{ .store = &store, .java = undefined, .java_download = undefined, .instances = undefined };
    var registry = @import("core/tasks.zig").Registry.init(a);
    defer registry.deinit();
    var budget = try @import("core/downloader.zig").Budget.init(io, 8);
    defer budget.deinit();
    var page = try page_mod.Page.init(a, io, &fixture.paths, &registry, &budget);
    defer page.deinit(services);
    page.ui.active = true;
    page.ui.route = .local;
    try @import("ui/pack_view.zig").setText(&page.ui.archive, source);
    var model: @import("ui/model.zig").Model = .{};
    var navigation = @import("ui/instances_view.zig").Ui.init(a);
    defer navigation.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    // Failure -> dismiss -> cancel retry -> dismiss -> successful retry, same page.
    for (0..3) |scenario| {
        try fixtures.zip(fixture.tmp.dir, "local.mrpack", &.{.{ .path = if (scenario == 0) "missing-index.txt" else "modrinth.index.json", .bytes = fixtures.index }});
        page.ui.queue(.inspect_archive);
        page.finish(&model, &navigation, services, true);
        try std.testing.expect(page.ui.failure == null);
        try std.testing.expect(page.ui.task_visible);
        try std.testing.expectEqual(.working, (try page.presentation(arena.allocator())).task);
        if (scenario == 1) {
            page.ui.queue(.cancel);
            page.finish(&model, &navigation, services, true);
        }
        page.installer.core.job.?.thread.?.join();
        page.installer.core.job.?.thread = null;
        page.installer.tickWithMutations(services, true);
        page.tickPresentation(services, true);
        const result = try page.presentation(arena.allocator());
        try std.testing.expectEqual(.local, page.ui.route);
        try std.testing.expect(page.ui.failure == null);
        if (scenario < 2) {
            try std.testing.expectEqual(if (scenario == 0) @as(@import("ui/pack_view.zig").Task, .failed) else .canceled, result.task);
            try std.testing.expect(result.failure != null);
            try std.testing.expect(page.ui.task_visible);
            page.ui.queue(.dismiss);
            page.finish(&model, &navigation, services, true);
            try std.testing.expectEqual(.none, (try page.presentation(arena.allocator())).task);
            try std.testing.expectEqual(.local, page.ui.route);
        } else {
            try std.testing.expect(result.ready);
            try std.testing.expect(result.failure == null);
            try std.testing.expectEqual(.none, result.task);
            try std.testing.expect(!page.ui.task_visible);
        }
    }
}
