//! Hermetic native renderer/input regression with real Manager task ownership.
const std = @import("std");
const dvui = @import("dvui");
const tasks = @import("core/tasks.zig");
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const manager_module = @import("application/instances_manager.zig");
const view = @import("ui/instances_view.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const example: config.Instance = .{ .id = "task-fixture", .name = "Task fixture", .minecraft_version = "1.21.1" };

const Installer = struct {
    ready: std.atomic.Value(bool) = .init(false),
    finish: std.atomic.Value(bool) = .init(false),
    held: std.atomic.Value(bool) = .init(false),
    releases: usize = 0,
    succeed: bool = false,
    delete_failure: ?anyerror = null,
    cancel_observed: std.atomic.Value(bool) = .init(false),

    fn acquire(raw: ?*anyopaque, _: []const u8) !void {
        const self: *Installer = @ptrCast(@alignCast(raw.?));
        if (self.held.swap(true, .acq_rel)) return error.InstanceBusy;
    }
    fn recheck(raw: ?*anyopaque, _: []const u8) !void {
        const self: *Installer = @ptrCast(@alignCast(raw.?));
        if (!self.held.load(.acquire)) return error.LeaseLost;
    }
    fn release(raw: ?*anyopaque, _: []const u8) void {
        const self: *Installer = @ptrCast(@alignCast(raw.?));
        std.debug.assert(self.held.swap(false, .acq_rel));
        self.releases += 1;
    }
    fn lease(self: *Installer) @import("core/content_install.zig").Lease {
        return .{ .context = self, .acquire = acquire, .recheck = recheck, .release = release };
    }
    fn run(raw: ?*anyopaque, alloc: std.mem.Allocator, worker_io: std.Io, request: manager_module.CreateRequest, control: manager_module.Control) !manager_module.Installed {
        const self: *Installer = @ptrCast(@alignCast(raw.?));
        var details: tasks.Details = .{ .stage = .downloading, .completed = 2, .total = 8, .received = 2048, .total_bytes = 8192, .bytes_per_second = 1048576 };
        details.addFile(tasks.File.init("libraries/fixture-client.jar", 1024, 4096, 512, .downloading, null));
        details.addFile(tasks.File.init("assets/fixture-index.json", 1024, 1024, 0, .complete, null));
        for (0..6) |index| {
            var path: [120]u8 = undefined;
            const label = try std.fmt.bufPrint(&path, "libraries/fixture-library-{d}.jar", .{index});
            details.addFile(tasks.File.init(label, 0, 1024, 0, .queued, null));
        }
        return self.runInner(alloc, worker_io, request, control, &details) catch |err| {
            if (err == error.Canceled) {
                self.cancel_observed.store(control.cancel.load(.acquire), .release);
                details.stop();
                for (details.files[0..details.file_count]) |*file| {
                    if (file.state != .complete) {
                        file.state = .canceled;
                        file.failure = error.Canceled;
                    }
                }
                control.task.?.reportDetails(details);
            }
            return err;
        };
    }

    fn runInner(self: *Installer, alloc: std.mem.Allocator, worker_io: std.Io, request: manager_module.CreateRequest, control: manager_module.Control, details: *tasks.Details) !manager_module.Installed {
        control.task.?.reportDetails(details.*);
        self.ready.store(true, .release);
        while (!self.finish.load(.acquire)) {
            try control.check();
            try worker_io.sleep(.fromMilliseconds(1), .awake);
        }
        try control.check();
        if (self.succeed) {
            details.stage = .verifying;
            details.completed = 8;
            details.received = 8192;
            details.bytes_per_second = 0;
            for (details.files[0..details.file_count]) |*file| {
                file.received = file.total orelse file.received;
                file.state = .complete;
                file.bytes_per_second = 0;
            }
            control.task.?.reportDetails(details.*);
            return manager_module.Installed.init(alloc, request.instance);
        }
        details.files[0] = tasks.File.init("libraries/fixture-client.jar", 3072, 4096, 0, .failed, error.SizeMismatch);
        details.files[1] = tasks.File.init("assets/fixture-index.json", 1024, 1024, 0, .failed, error.Sha1Mismatch);
        details.received = 4096;
        details.stage = .verifying;
        details.bytes_per_second = 0;
        control.task.?.reportDetails(details.*);
        return error.SizeMismatch;
    }
    fn deleteRecheck(raw: ?*anyopaque, id: []const u8) !void {
        const self: *Installer = @ptrCast(@alignCast(raw.?));
        try recheck(raw, id);
        self.ready.store(true, .release);
        while (!self.finish.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
        if (self.delete_failure) |err| return err;
    }

    fn waitReady(self: *Installer) !void {
        const start = std.Io.Clock.awake.now(io).nanoseconds;
        while (!self.ready.load(.acquire)) {
            if (std.Io.Clock.awake.now(io).nanoseconds - start > 3 * std.time.ns_per_s) return error.InstallerTimeout;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

fn join(manager: *manager_module.Manager) !void {
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (manager.snapshot().phase == .working) {
        manager.tick();
        if (std.Io.Clock.awake.now(io).nanoseconds - start > 3 * std.time.ns_per_s) return error.ManagerJoinTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(manager.active == null);
}

fn contains(outer: dvui.Rect.Physical, inner: dvui.Rect.Physical) bool {
    return inner.x >= outer.x - 0.1 and inner.y >= outer.y - 0.1 and inner.x + inner.w <= outer.x + outer.w + 0.1 and inner.y + inner.h <= outer.y + outer.h + 0.1;
}
fn inside(outer: dvui.Rect.Physical, inner: dvui.Rect.Physical) !void {
    errdefer std.debug.print("task modal containment: outer={any}, inner={any}\n", .{ outer, inner });
    try std.testing.expect(contains(outer, inner));
}

const Frame = struct {
    const Text = struct { value: []const u8, rect: dvui.Rect.Physical, clip: dvui.Rect.Physical };
    const Shape = struct { rect: dvui.Rect.Physical, clip: dvui.Rect.Physical };
    var ui: *view.Ui = undefined;
    var manager: *manager_module.Manager = undefined;
    var store: *config.Store = undefined;
    var arena: ?std.heap.ArenaAllocator = null;
    var texts: []const Text = &.{};
    var shapes: []const Shape = &.{};
    var show_instance_page = true;

    fn clear() void {
        texts = &.{};
        shapes = &.{};
        if (arena) |*previous| previous.deinit();
        arena = null;
    }
    fn bounds(points: []const dvui.Point.Physical) ?dvui.Rect.Physical {
        if (points.len == 0) return null;
        var left = points[0].x;
        var top = points[0].y;
        var right = left;
        var bottom = top;
        for (points[1..]) |point| {
            left = @min(left, point.x);
            top = @min(top, point.y);
            right = @max(right, point.x);
            bottom = @max(bottom, point.y);
        }
        return .{ .x = left, .y = top, .w = right - left, .h = bottom - top };
    }
    fn retain(commands: []const dvui.RenderCommand) !void {
        clear();
        arena = .init(a);
        const alloc = arena.?.allocator();
        var text_items: std.ArrayList(Text) = .empty;
        var shape_items: std.ArrayList(Shape) = .empty;
        for (commands) |command| {
            switch (command.cmd) {
                .text => |text| try text_items.append(alloc, .{ .value = try alloc.dupe(u8, text.text), .rect = text.rs.r, .clip = command.clip }),
                else => {},
            }
            const rect = switch (command.cmd) {
                .triangles => |mesh| mesh.tri.bounds,
                .pathFillConvex => |fill| bounds(fill.path.points),
                .pathStroke => |stroke| bounds(stroke.path.points),
                else => null,
            } orelse continue;
            try shape_items.append(alloc, .{ .rect = rect, .clip = command.clip });
        }
        texts = text_items.items;
        shapes = shape_items.items;
    }
    fn draw() !dvui.App.Result {
        const win = dvui.currentWindow();
        dvui.debug.captureScopeBegin(win.gpa);
        defer dvui.debug.captureScopeEnd();
        var commands: std.ArrayList(dvui.RenderCommand) = .empty;
        const previous_commands = win.defer_render_cmds;
        const previous_after = win.defer_render_cmds_after;
        const previous_rendering = win.render_target.rendering;
        win.defer_render_cmds = &commands;
        win.defer_render_cmds_after = &commands;
        win.render_target.rendering = false;
        defer {
            win.defer_render_cmds = previous_commands;
            win.defer_render_cmds_after = previous_after;
            win.render_target.rendering = previous_rendering;
            commands.deinit(win.arena());
        }
        // Root synchronization remains active even when instance-page rendering is absent.
        view.syncTaskSnapshot(ui, manager.snapshot());
        {
            const root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = dvui.Rect.all(16) });
            defer root.deinit();
            if (show_instance_page) {
                view.drawWithEnabled(ui, store, manager, .{ .installed = &.{}, .available = &.{}, .phase = .idle, .failure = null }, &.{}, true);
            } else {
                dvui.labelNoFmt(@src(), "Another panel", .{}, .{});
            }
        }
        view.drawModal(ui, true);
        for (win.subwindows.stack.items) |*subwindow| {
            try commands.appendSlice(win.arena(), subwindow.render_cmds.items);
            try commands.appendSlice(win.arena(), subwindow.render_cmds_after.items);
        }
        try retain(commands.items);
        view.finish(ui, store, manager);
        return .ok;
    }
    fn geometry(key: []const u8) !dvui.Rect.Physical {
        const tag = try dvui.testing.tagGet(key);
        const capture = dvui.debug.lastCapture() orelse return error.TaskCaptureMissing;
        for (capture.widgets.items) |widget| if (widget.id == tag.id) return widget.rect_border;
        return error.TaskWidgetCaptureMissing;
    }
    fn paintedText(fragment: []const u8) !Text {
        for (texts) |sample| {
            if (std.mem.indexOf(u8, sample.value, fragment) != null and contains(sample.clip, sample.rect)) return sample;
        }
        std.debug.print("task modal painted text missing: {s}\n", .{fragment});
        for (texts) |sample| std.debug.print("  {s} rect={any} clip={any}\n", .{ sample.value, sample.rect, sample.clip });
        return error.TaskTextNotPainted;
    }
    fn scrollIntoFiles(key: []const u8) !void {
        for (0..20) |_| {
            const files = try geometry("instance-task-files");
            const row = try geometry(key);
            if (contains(files, row)) return;
            try wheel(if (row.y < files.y) 40 else -40);
        }
        return error.TaskRowCannotScrollIntoView;
    }
    fn normalizedPaint(fragments: []const []const u8) !Text {
        return numericIn(try geometry("instance-task-body"), fragments);
    }
    fn numericIn(body: dvui.Rect.Physical, fragments: []const []const u8) !Text {
        for (texts) |sample| {
            if (!contains(body, sample.rect) or !contains(sample.clip, sample.rect)) continue;
            var compact: [2048]u8 = undefined;
            var length: usize = 0;
            for (sample.value) |byte| {
                if (std.ascii.isWhitespace(byte)) continue;
                if (length == compact.len) break;
                compact[length] = byte;
                length += 1;
            }
            for (fragments) |fragment| if (std.mem.indexOf(u8, compact[0..length], fragment) != null) return sample;
        }
        std.debug.print("task modal normalized paint missing any of {any}; body={any}\n", .{ fragments, body });
        for (texts) |sample| if (sample.rect.y >= body.y - 1 and sample.rect.y < body.y + body.h + 1) {
            std.debug.print("  {s} rect={any} clip={any}\n", .{ sample.value, sample.rect, sample.clip });
        };
        return error.TaskNumericTextNotPainted;
    }
    fn nativeButton(key: []const u8) !dvui.TagData {
        const tag = try dvui.testing.tagGet(key);
        try std.testing.expect(tag.visible);
        var tab_entries: usize = 0;
        for (dvui.currentWindow().tab_index_prev.items) |entry| if (entry.widgetId == tag.id) {
            tab_entries += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), tab_entries);
        try inside(dvui.Rect.Physical.cast(dvui.windowRect()), try geometry(key));
        return tag;
    }
    fn click(key: []const u8) !void {
        const target = try nativeButton(key);
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = target.rect.center() });
        try dvui.testing.click(.left);
        try dvui.testing.settle(draw);
    }
    fn wheel(amount: f32) !void {
        try dvui.testing.moveTo("instance-task-files");
        _ = try dvui.currentWindow().addEventMouseWheel(amount, .vertical, null);
        try dvui.testing.settle(draw);
    }
    fn absent(key: []const u8) !void {
        if (dvui.tagGet(key) != null) return error.UnexpectedTaskWidget;
    }
    fn noText(fragment: []const u8) !void {
        for (texts) |sample| {
            if (std.mem.indexOf(u8, sample.value, fragment) != null and contains(sample.clip, sample.rect)) {
                std.debug.print("unexpected painted task text: {s}\n", .{sample.value});
                return error.UnexpectedTaskText;
            }
        }
    }
    fn footer(working: bool) !dvui.Rect.Physical {
        const modal = try geometry("instance-task-modal");
        const body = try geometry("instance-task-body");
        const files = try geometry("instance-task-files");
        const footer_rect = try geometry("instance-task-footer");
        try inside(dvui.Rect.Physical.cast(dvui.windowRect()), modal);
        try inside(modal, body);
        try inside(modal, files);
        try inside(modal, footer_rect);
        try inside(body, files);
        try std.testing.expect(body.y + body.h <= footer_rect.y + 0.1);
        try std.testing.expect(files.y + files.h <= footer_rect.y + 0.1);
        for ([_][]const u8{ "instance-task-operation", "instance-task-status", "instance-task-progress", "instance-task-bytes", "instance-task-speed" }) |summary_key| {
            const summary = try geometry(summary_key);
            try inside(body, summary);
            try std.testing.expect(summary.y + summary.h <= files.y + 0.1);
        }
        const key = if (working) "instance-task-cancel" else "instance-task-close";
        _ = try nativeButton(key);
        const button = try geometry(key);
        try inside(footer_rect, button);
        try std.testing.expect(button.x >= footer_rect.x + footer_rect.w / 2);
        try absent(if (working) "instance-task-close" else "instance-task-cancel");
        try absent("instance-task-reopen");
        try noText("任务详情");
        try noText("操作失败");
        try noText("关闭此窗口");
        const label = try paintedText(if (working) "取消" else if (ui.task.phase == .complete) "完成" else "关闭");
        try inside(button, label.rect);
        return footer_rect;
    }
    fn fileRow(index: usize, name: []const u8, percent: f32) !void {
        var row_buf: [80]u8 = undefined;
        var name_buf: [80]u8 = undefined;
        var bar_buf: [80]u8 = undefined;
        const row_key = try std.fmt.bufPrint(&row_buf, "instance-task-file-{d}", .{index});
        const name_key = try std.fmt.bufPrint(&name_buf, "instance-task-file-name-{d}", .{index});
        const bar_key = try std.fmt.bufPrint(&bar_buf, "instance-task-file-progress-{d}", .{index});
        try scrollIntoFiles(row_key);
        const row = try geometry(row_key);
        const label = try geometry(name_key);
        const bar = try geometry(bar_key);
        try inside(try geometry("instance-task-files"), row);
        try inside(row, label);
        try inside(row, bar);
        try inside(label, (try paintedText(name)).rect);
        try std.testing.expect(bar.w > 30 and bar.h > 0 and bar.h <= 10);
        try std.testing.expect(bar.y >= label.y + label.h - 0.1);
        // Confirm renderer commands contain the thin track and proportional fill.
        var track_painted = false;
        var fill_painted = percent == 0;
        for (shapes) |shape| {
            if (!contains(bar, shape.rect) or !contains(shape.clip, shape.rect) or shape.rect.h <= 0) continue;
            if (@abs(shape.rect.w - bar.w) <= 1.1) track_painted = true;
            if (@abs(shape.rect.w - bar.w * percent) <= 1.1) fill_painted = true;
        }
        try std.testing.expect(track_painted);
        try std.testing.expect(fill_painted);
        for (texts) |sample| {
            if (!contains(row, sample.rect) or !contains(sample.clip, sample.rect)) continue;
            for ([_][]const u8{ "libraries/", "assets/", "bytes", "/s", "下载中", "排队", "25.0%", "75.0%" }) |clutter| {
                try std.testing.expect(std.mem.indexOf(u8, sample.value, clutter) == null);
            }
        }
    }
};

fn atBothSizes(comptime scenario: fn (*Installer, *tasks.Registry) anyerror!void, other_panel: bool) !void {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var paths = try instances.Paths.init(a, io, root);
        defer paths.deinit();
        var store = try config.Store.init(a, io, root);
        defer store.deinit();
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var installer: Installer = .{};
        var manager = try manager_module.Manager.init(a, io, &paths, &registry, .{}, installer.lease());
        defer manager.deinit();
        manager.setInstaller(.{ .context = &installer, .run = Installer.run });
        var ui = view.Ui.init(a);
        defer ui.deinit();
        Frame.ui = &ui;
        Frame.manager = &manager;
        Frame.store = &store;
        Frame.show_instance_page = !other_panel;
        defer Frame.clear();
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        window.backend.size_pixels = .{ .w = size.w, .h = size.h };
        var theme = dvui.Theme.builtin.adwaita_dark;
        theme.font_body = theme.font_body.withSize(16);
        theme.font_heading = theme.font_body.withSize(18);
        theme.font_title = theme.font_body.withSize(24);
        window.window.themeSet(theme);
        try manager.startCreate(example);
        try installer.waitReady();
        try dvui.testing.settle(Frame.draw);
        try scenario(&installer, &registry);
        try std.testing.expectEqual(@as(usize, if (installer.succeed) 1 else 0), store.snapshot().instances.len);
        try std.testing.expectEqual(@as(usize, 1), installer.releases);
        try std.testing.expect(!installer.held.load(.acquire));
    }
}

test "instance task modal failure heading paints status and actual stage without sentence punctuation" {
    const Scenario = struct {
        fn run(installer: *Installer, registry: *tasks.Registry) !void {
            installer.finish.store(true, .release);
            try join(Frame.manager);
            try dvui.testing.settle(Frame.draw);
            _ = try Frame.paintedText("任务失败 · 校验文件");
            registry.pruneFinished(0);
            try dvui.testing.settle(Frame.draw);
            _ = try Frame.paintedText("任务失败 · 校验文件");
        }
    };
    try atBothSizes(Scenario.run, false);
}

const Removal = enum { dismiss, prune };

fn assertRetainedFailure() !void {
    const retained = Frame.manager.snapshot();
    try std.testing.expectEqual(manager_module.Phase.failed, retained.phase);
    try std.testing.expectEqual(error.SizeMismatch, retained.failure.?);
    try std.testing.expectEqual(@as(usize, 8), retained.details.file_count);
    try std.testing.expectEqualStrings("fixture-client.jar", retained.details.files[0].name());
    try std.testing.expectEqualStrings("libraries/fixture-client.jar", retained.details.files[0].path());
    try std.testing.expectEqual(error.SizeMismatch, retained.details.files[0].failure.?);
    try std.testing.expectEqual(@as(u64, 3072), retained.details.files[0].received);
    try std.testing.expectEqual(@as(f64, 0), retained.details.bytes_per_second);
    _ = try Frame.footer(false);
    _ = try Frame.paintedText("任务失败 · 校验文件");
    _ = try Frame.paintedText("原因");
    _ = try Frame.paintedText("SizeMismatch");
    _ = try Frame.paintedText("下载文件大小与预期不符");
    try Frame.fileRow(0, "fixture-client.jar", 0.75);
    // The summary owns repeated errors; different file failures still keep their details.
    try Frame.absent("instance-task-file-failure-0");
    var repeated_error_count: usize = 0;
    for (Frame.texts) |sample| repeated_error_count += std.mem.count(u8, sample.value, "SizeMismatch");
    try std.testing.expectEqual(@as(usize, 1), repeated_error_count);
    try Frame.scrollIntoFiles("instance-task-file-1");
    const file_failure = try Frame.geometry("instance-task-file-failure-1");
    _ = try Frame.numericIn(file_failure, &.{"Sha1Mismatch"});
    try Frame.absent("instance-task-file-path-0");
}

fn assertWorkingLayout(installer: *Installer) !void {
    const footer_before = try Frame.footer(true);
    const files = try Frame.geometry("instance-task-files");
    const body_before = try Frame.geometry("instance-task-body");
    const progress_before = try Frame.geometry("instance-task-progress");
    const bytes_before = try Frame.geometry("instance-task-bytes");
    const speed_before = try Frame.geometry("instance-task-speed");
    try inside(body_before, progress_before);
    try inside(body_before, bytes_before);
    try inside(body_before, speed_before);
    _ = try Frame.numericIn(progress_before, &.{"2/8"});
    _ = try Frame.numericIn(progress_before, &.{ "25.0%", "25%" });
    _ = try Frame.numericIn(bytes_before, &.{ "2KB", "2.0KB", "2.00KB" });
    _ = try Frame.numericIn(bytes_before, &.{ "8KB", "8.0KB", "8.00KB" });
    _ = try Frame.numericIn(speed_before, &.{ "1MB/s", "1.0MB/s", "1.00MB/s" });
    try Frame.noText("bytes");
    try Frame.noText("KiB");
    try Frame.fileRow(0, "fixture-client.jar", 0.25);
    const first_before = try Frame.geometry("instance-task-file-progress-0");
    const last_before = try Frame.geometry("instance-task-file-7");
    const overflow = !contains(files, last_before);
    try Frame.wheel(-10000);
    try std.testing.expectEqualDeep(footer_before, try Frame.footer(true));
    try std.testing.expectEqualDeep(body_before, try Frame.geometry("instance-task-body"));
    try std.testing.expectEqualDeep(progress_before, try Frame.geometry("instance-task-progress"));
    try std.testing.expectEqualDeep(bytes_before, try Frame.geometry("instance-task-bytes"));
    try std.testing.expectEqualDeep(speed_before, try Frame.geometry("instance-task-speed"));
    try Frame.fileRow(7, "fixture-library-5.jar", 0);
    const first_after = try Frame.geometry("instance-task-file-progress-0");
    if (overflow) {
        try std.testing.expect(first_after.y < first_before.y - 1);
    } else {
        // Compact rows can all fit in the large window: assert every bar is painted.
        try std.testing.expectEqualDeep(first_before, first_after);
        try Frame.fileRow(1, "fixture-index.json", 1);
        for (2..8) |index| {
            var name: [80]u8 = undefined;
            try Frame.fileRow(index, try std.fmt.bufPrint(&name, "fixture-library-{d}.jar", .{index - 2}), 0);
        }
    }
    try Frame.wheel(10000);
    try Frame.fileRow(0, "fixture-client.jar", 0.25);
    // Actual key events must not hide a running task or release its lease.
    try dvui.testing.pressKey(.escape, .none);
    try dvui.testing.settle(Frame.draw);
    _ = try Frame.footer(true);
    Frame.ui.queue(.close_task, null);
    _ = try dvui.testing.step(Frame.draw);
    try dvui.testing.settle(Frame.draw);
    _ = try Frame.footer(true);
    try std.testing.expectEqual(manager_module.Phase.working, Frame.manager.snapshot().phase);
    try std.testing.expect(Frame.manager.active != null);
    try std.testing.expect(installer.held.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), installer.releases);
}

fn assertClosed() !void {
    try Frame.absent("instance-task-modal");
    try Frame.absent("instance-task-reopen");
    try dvui.testing.settle(Frame.draw);
    try Frame.absent("instance-task-modal");
}

fn failureScenario(installer: *Installer, registry: *tasks.Registry, removal: Removal) !void {
    const task_id = Frame.manager.snapshot().task_id.?;
    try assertWorkingLayout(installer);
    // Root synchronization still supplies live detail outside the instance panel.
    Frame.show_instance_page = false;
    try dvui.testing.settle(Frame.draw);
    try Frame.fileRow(0, "fixture-client.jar", 0.25);
    _ = try Frame.footer(true);
    Frame.show_instance_page = true;
    try dvui.testing.settle(Frame.draw);
    installer.finish.store(true, .release);
    try join(Frame.manager);
    try dvui.testing.settle(Frame.draw);
    try assertRetainedFailure();
    switch (removal) {
        .dismiss => try std.testing.expect(registry.dismiss(task_id)),
        .prune => registry.pruneFinished(0),
    }
    // Dismissal/pruning cannot lose owned failure or silently close its window.
    try std.testing.expect(!registry.dismiss(task_id));
    try dvui.testing.settle(Frame.draw);
    try assertRetainedFailure();
    const footer = try Frame.footer(false);
    const failure = try Frame.geometry("instance-task-failure");
    const summary = try Frame.geometry("instance-task-progress");
    try Frame.wheel(-10000);
    try Frame.fileRow(7, "fixture-library-5.jar", 0);
    try std.testing.expectEqualDeep(footer, try Frame.footer(false));
    try std.testing.expectEqualDeep(failure, try Frame.geometry("instance-task-failure"));
    try std.testing.expectEqualDeep(summary, try Frame.geometry("instance-task-progress"));
    _ = try Frame.paintedText("SizeMismatch");
    try Frame.click("instance-task-close");
    try assertClosed();
}

fn dismissedFailure(installer: *Installer, registry: *tasks.Registry) !void {
    try failureScenario(installer, registry, .dismiss);
}
fn prunedFailure(installer: *Installer, registry: *tasks.Registry) !void {
    try failureScenario(installer, registry, .prune);
}
fn canceled(installer: *Installer, _: *tasks.Registry) !void {
    try assertWorkingLayout(installer);
    try Frame.click("instance-task-cancel");
    try assertClosed();
    try join(Frame.manager);
    try dvui.testing.settle(Frame.draw);
    try assertClosed();
    try std.testing.expectEqual(manager_module.Phase.canceled, Frame.manager.snapshot().phase);
    try std.testing.expectEqual(error.Canceled, Frame.manager.snapshot().failure.?);
    try std.testing.expectEqual(error.Canceled, Frame.manager.snapshot().details.files[0].failure.?);
    try std.testing.expect(installer.cancel_observed.load(.acquire));
    try std.testing.expect(Frame.manager.active == null);
    try std.testing.expectEqual(@as(f64, 0), Frame.manager.snapshot().details.bytes_per_second);
    try std.testing.expectEqual(@as(usize, 1), installer.releases);
    try std.testing.expect(!installer.held.load(.acquire));
    try Frame.absent("instance-task-failure");
    try Frame.absent("instance-task-file-failure-0");
}

fn completed(installer: *Installer, registry: *tasks.Registry) !void {
    try assertWorkingLayout(installer);
    // Worker does not read this field until the release/acquire finish handshake.
    installer.succeed = true;
    const task_id = Frame.manager.snapshot().task_id.?;
    installer.finish.store(true, .release);
    try join(Frame.manager);
    // finish publishes at the end of one frame; the following frame paints complete.
    _ = try dvui.testing.step(Frame.draw);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expectEqual(manager_module.Phase.complete, Frame.manager.snapshot().phase);
    try std.testing.expect(Frame.manager.active == null);
    try std.testing.expectEqual(@as(usize, 1), installer.releases);
    try std.testing.expect(!installer.held.load(.acquire));
    _ = try Frame.footer(false);
    try Frame.noText("关闭");
    try Frame.fileRow(0, "fixture-client.jar", 1);
    try Frame.fileRow(7, "fixture-library-5.jar", 1);
    registry.pruneFinished(0);
    try std.testing.expect(!registry.dismiss(task_id));
    try dvui.testing.settle(Frame.draw);
    // Success remains visible after JOIN/publication/pruning and repeated frames.
    _ = try Frame.footer(false);
    _ = try Frame.paintedText("完成");
    try Frame.click("instance-task-close");
    try assertClosed();
}

fn humanUnits(installer: *Installer, registry: *tasks.Registry) !void {
    const task = Frame.manager.active.?.task.?;
    const original = task.details();
    var details = original;
    // Reproduce the reported late-install state with a completed short JSON file.
    details.completed = 5002;
    details.total = 5216;
    details.received = 583 * 1024;
    details.total_bytes = details.received;
    details.bytes_per_second = 0;
    details.file_count = 1;
    details.omitted_files = 0;
    details.files[0] = tasks.File.init("34.json", details.received, details.total_bytes, 0, .complete, null);
    task.reportDetails(details);
    try dvui.testing.settle(Frame.draw);
    _ = try Frame.numericIn(try Frame.geometry("instance-task-speed"), &.{"—"});
    _ = try Frame.numericIn(try Frame.geometry("instance-task-progress"), &.{"5002/5216"});
    _ = try Frame.numericIn(try Frame.geometry("instance-task-bytes"), &.{"583.0KB"});
    details.stage = .verifying;
    details.bytes_per_second = 1024;
    task.reportDetails(details);
    try dvui.testing.settle(Frame.draw);
    _ = try Frame.numericIn(try Frame.geometry("instance-task-speed"), &.{"—"});
    details = original;
    details.received = 99;
    details.total_bytes = 512;
    details.bytes_per_second = 1;
    task.reportDetails(details);
    try dvui.testing.settle(Frame.draw);
    const bytes = try Frame.geometry("instance-task-bytes");
    _ = try Frame.numericIn(bytes, &.{"99B"});
    _ = try Frame.numericIn(bytes, &.{"512B"});
    _ = try Frame.numericIn(try Frame.geometry("instance-task-speed"), &.{"1B/s"});
    details.received = 2048;
    details.total_bytes = 8192;
    details.bytes_per_second = 512 * 1024;
    task.reportDetails(details);
    try dvui.testing.settle(Frame.draw);
    _ = try Frame.numericIn(try Frame.geometry("instance-task-bytes"), &.{"2.0KB"});
    _ = try Frame.numericIn(try Frame.geometry("instance-task-speed"), &.{"512.0KB/s"});
    details.received = 2 * 1024 * 1024 * 1024;
    details.total_bytes = 4 * 1024 * 1024 * 1024;
    details.bytes_per_second = 2 * 1024 * 1024;
    task.reportDetails(details);
    try dvui.testing.settle(Frame.draw);
    _ = try Frame.numericIn(try Frame.geometry("instance-task-bytes"), &.{ "2048MB", "2048.0MB", "2048.00MB" });
    _ = try Frame.numericIn(try Frame.geometry("instance-task-bytes"), &.{ "4096MB", "4096.0MB", "4096.00MB" });
    _ = try Frame.numericIn(try Frame.geometry("instance-task-speed"), &.{ "2MB/s", "2.0MB/s", "2.00MB/s" });
    for ([_][]const u8{ "GB", "GiB", "KiB", "bytes" }) |label| try Frame.noText(label);
    task.reportDetails(original);
    try dvui.testing.settle(Frame.draw);
    // Restored KB telemetry exercises the same actual geometry and cancel path.
    try canceled(installer, registry);
}

test "instance task modal summary paints human B KB maximum MB amounts and speeds" {
    try atBothSizes(humanUnits, false);
}
test "instance task modal fixed summary thin file bars and retained error until manual close after dismissal" {
    try atBothSizes(dismissedFailure, false);
}
test "instance task modal retains genuine failure until manual close after registry pruning" {
    try atBothSizes(prunedFailure, true);
}
test "instance task modal working Escape blocked and cancel closes joins worker releases lease" {
    try atBothSizes(canceled, false);
}
test "instance task modal successful completion requires manual close after publication and pruning" {
    try atBothSizes(completed, false);
}

fn deleteLayout(unfinished: bool, actionable: bool) !void {
    const modal = try Frame.geometry("instance-task-modal");
    const viewport = dvui.Rect.Physical.cast(dvui.windowRect());
    const body = try Frame.geometry("instance-task-body");
    const footer = try Frame.geometry("instance-task-footer");
    try inside(viewport, modal);
    try inside(modal, body);
    try inside(modal, footer);
    try std.testing.expectApproxEqAbs(viewport.center().x, modal.center().x, 0.1);
    try std.testing.expectApproxEqAbs(viewport.center().y, modal.center().y, 0.1);
    const dialogs = @import("ui/style.zig").dialogs;
    const problem = Frame.ui.task.failure != null or Frame.ui.task.durability_uncertain or Frame.ui.task.recovery_directory != null or Frame.ui.task_can_retry;
    try std.testing.expectApproxEqAbs(if (problem) dialogs.instance_delete_task_error_height else dialogs.instance_delete_task_height, modal.h, 0.1);
    try std.testing.expect(body.y + body.h <= footer.y + 0.1);
    const button_key = if (unfinished) "instance-task-cancel" else "instance-task-close";
    const button = try dvui.testing.tagGet(button_key);
    try std.testing.expect(button.visible);
    try inside(footer, try Frame.geometry(button_key));
    var tab_entries: usize = 0;
    for (dvui.currentWindow().tab_index_prev.items) |entry| if (entry.widgetId == button.id) {
        tab_entries += 1;
    };
    try std.testing.expectEqual(@as(usize, if (actionable) 1 else 0), tab_entries);
    try Frame.absent(if (unfinished) "instance-task-close" else "instance-task-cancel");
    for ([_][]const u8{ "instance-task-summary", "instance-task-progress", "instance-task-bytes", "instance-task-speed", "instance-task-files-panel", "instance-task-files", "instance-task-file-0", "instance-task-file-progress-0", "instance-task-no-files", "instance-task-omitted" }) |key| try Frame.absent(key);
    for ([_][]const u8{ "总体进度", "传输：", "速度：", "暂无文件详情", "fixture-hidden-file", "服务器配置已移除" }) |fragment| try Frame.noText(fragment);
    _ = try Frame.paintedText(if (unfinished and actionable) "正在永久删除实例" else if (unfinished) "实例文件已删除" else "关闭");
}

fn deleteBodyReach(key: []const u8) !void {
    for (0..24) |_| {
        const body = try Frame.geometry("instance-task-body");
        const target = try Frame.geometry(key);
        if (contains(body, target)) return;
        try dvui.testing.moveTo("instance-task-body");
        _ = try dvui.currentWindow().addEventMouseWheel(if (target.y < body.y) 40 else -40, .vertical, null);
        try dvui.testing.settle(Frame.draw);
    }
    return error.DeleteTaskContentCannotScrollIntoView;
}

fn atDeleteSizes(comptime scenario: fn (*Installer, *tasks.Registry, *dvui.testing, std.Io.Dir) anyerror!void) !void {
    if (dvui.Backend.kind != .testing) return error.SkipZigTest;
    for ([_]dvui.Size{ .{ .w = 640, .h = 400 }, .{ .w = 1280, .h = 720 } }) |size| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, ".minecraft/versions/Task fixture/saves/World");
        try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Task fixture/saves/World/level.dat", .data = "world" });
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var paths = try instances.Paths.init(a, io, root);
        defer paths.deinit();
        var store = try config.Store.init(a, io, root);
        defer store.deinit();
        try store.update(.{ .instances = &.{example} });
        var registry = tasks.Registry.init(a);
        defer registry.deinit();
        var worker: Installer = .{};
        var manager = try manager_module.Manager.init(a, io, &paths, &registry, .{}, worker.lease());
        defer manager.deinit();
        // Always release the worker gate before Manager.deinit joins it, including failures.
        defer worker.finish.store(true, .release);
        manager.setWorkerRecheck(Installer.deleteRecheck);
        var ui = view.Ui.init(a);
        defer ui.deinit();
        Frame.ui = &ui;
        Frame.manager = &manager;
        Frame.store = &store;
        Frame.show_instance_page = false;
        defer Frame.clear();
        var window = try dvui.testing.init(.{ .window_size = size });
        defer window.deinit();
        window.backend.size_pixels = .cast(size);
        var theme = dvui.Theme.builtin.adwaita_dark;
        theme.font_body = theme.font_body.withSize(16);
        theme.font_heading = theme.font_body.withSize(18);
        theme.font_title = theme.font_body.withSize(24);
        window.window.themeSet(theme);
        try manager.startDelete(example);
        try worker.waitReady();
        // Even unexpected worker telemetry must never introduce download controls.
        var details: tasks.Details = .{ .stage = .finalizing, .completed = 1, .total = 2, .received = 1024, .total_bytes = 2048, .bytes_per_second = 512 };
        details.addFile(tasks.File.init("fixture-hidden-file", 1024, 2048, 512, .downloading, null));
        manager.active.?.task.?.reportDetails(details);
        try dvui.testing.settle(Frame.draw);
        try deleteLayout(true, true);
        try scenario(&worker, &registry, &window, tmp.dir);
    }
}

fn deleteCanceled(worker: *Installer, _: *tasks.Registry, window: *dvui.testing, dir: std.Io.Dir) !void {
    try dvui.testing.pressKey(.escape, .none);
    try dvui.testing.settle(Frame.draw);
    Frame.ui.queue(.close_task, null);
    _ = try dvui.testing.step(Frame.draw);
    try dvui.testing.settle(Frame.draw);
    try deleteLayout(true, true);
    try std.testing.expect(worker.held.load(.acquire));
    for ([_]dvui.Size{ .{ .w = 1280, .h = 720 }, .{ .w = 640, .h = 400 } }) |size| {
        window.backend.size = .cast(size);
        window.backend.size_pixels = .cast(size);
        _ = try dvui.testing.step(Frame.draw);
        try dvui.testing.settle(Frame.draw);
        try deleteLayout(true, true);
        const before = try Frame.geometry("instance-task-modal");
        for ([_]f32{ 24, before.h / 2 }) |offset| {
            const start: dvui.Point.Physical = .{ .x = before.x + 80, .y = before.y + offset };
            _ = try window.window.addEventMouseMotion(.{ .pt = start });
            try dvui.testing.settle(Frame.draw);
            _ = try window.window.addEventMouseButton(.left, .press);
            try dvui.testing.settle(Frame.draw);
            _ = try window.window.addEventMouseMotion(.{ .pt = .{ .x = start.x + 50, .y = start.y + 30 } });
            try dvui.testing.settle(Frame.draw);
            _ = try window.window.addEventMouseButton(.left, .release);
            try dvui.testing.settle(Frame.draw);
            try std.testing.expectEqualDeep(before, try Frame.geometry("instance-task-modal"));
        }
    }
    try Frame.click("instance-task-cancel");
    try assertClosed();
    worker.finish.store(true, .release);
    try join(Frame.manager);
    try dvui.testing.settle(Frame.draw);
    try assertClosed();
    try std.testing.expectEqual(manager_module.Phase.canceled, Frame.manager.snapshot().phase);
    try std.testing.expectEqual(@as(usize, 1), worker.releases);
    try std.testing.expect(!worker.held.load(.acquire));
    try dir.access(io, ".minecraft/versions/Task fixture/saves/World/level.dat", .{});
}

fn deleteRetry(worker: *Installer, registry: *tasks.Registry, _: *dvui.testing, dir: std.Io.Dir) !void {
    const id = Frame.manager.snapshot().task_id.?;
    worker.finish.store(true, .release);
    try join(Frame.manager);
    try std.testing.expectEqual(manager_module.Phase.awaiting_publication, Frame.manager.snapshot().phase);
    // Block config publication after the real filesystem deletion, then permit retry.
    Frame.store.publication_uncertain = true;
    _ = try dvui.testing.step(Frame.draw);
    try dvui.testing.settle(Frame.draw);
    try deleteLayout(true, false);
    _ = try Frame.paintedText("保存配置失败");
    try std.testing.expect(Frame.ui.task_can_retry and worker.held.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), Frame.store.snapshot().instances.len);
    try std.testing.expectError(error.FileNotFound, dir.access(io, ".minecraft/versions/Task fixture", .{}));
    // The disabled cancel must not abandon a committed deletion awaiting publication.
    const cancel = try dvui.testing.tagGet("instance-task-cancel");
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = cancel.rect.center() });
    try dvui.testing.click(.left);
    try dvui.testing.settle(Frame.draw);
    try std.testing.expect(Frame.ui.task.visible and Frame.manager.pending != null);
    try deleteBodyReach("instance-task-retry");
    _ = try Frame.nativeButton("instance-task-retry");
    Frame.store.publication_uncertain = false;
    try Frame.click("instance-task-retry");
    try deleteBodyReach("instance-task-status");
    try deleteLayout(false, true);
    _ = try Frame.paintedText("服务器已保留并解除绑定");
    try Frame.absent("instance-task-retry");
    try std.testing.expectEqual(manager_module.Phase.complete, Frame.manager.snapshot().phase);
    try std.testing.expectEqual(@as(usize, 0), Frame.store.snapshot().instances.len);
    try std.testing.expectEqual(@as(usize, 1), worker.releases);
    registry.pruneFinished(0);
    try std.testing.expect(!registry.dismiss(id));
    try dvui.testing.settle(Frame.draw);
    try deleteLayout(false, true);
    try Frame.click("instance-task-close");
    try assertClosed();
}

fn deleteFailed(worker: *Installer, _: *tasks.Registry, _: *dvui.testing, dir: std.Io.Dir) !void {
    worker.delete_failure = error.PermanentDeletionIncomplete;
    worker.finish.store(true, .release);
    try join(Frame.manager);
    try dvui.testing.settle(Frame.draw);
    try deleteLayout(false, true);
    _ = try Frame.paintedText("任务失败");
    try deleteBodyReach("instance-task-failure");
    _ = try Frame.paintedText("部分文件可能已经删除");
    _ = try Frame.paintedText("PermanentDeletionIncomplete");
    try Frame.absent("instance-task-retry");
    try std.testing.expect(Frame.manager.isBusy() and worker.held.load(.acquire));
    try Frame.click("instance-task-close");
    try assertClosed();
    try std.testing.expectEqual(@as(usize, 1), Frame.store.snapshot().instances.len);
    // This injected pre-mutation failure checks UI handling without erasing fixture data.
    try dir.access(io, ".minecraft/versions/Task fixture/saves/World/level.dat", .{});
}

fn deleteRecovery(worker: *Installer, _: *tasks.Registry, _: *dvui.testing, _: std.Io.Dir) !void {
    worker.finish.store(true, .release);
    try join(Frame.manager);
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expectEqual(manager_module.Phase.complete, Frame.manager.snapshot().phase);
    // Inject result diagnostics independently of platform directory-sync support.
    const result = &Frame.manager.published.?.result.?;
    result.durability_uncertain = true;
    result.recovery_directory = "fixture-recovery-directory";
    try dvui.testing.settle(Frame.draw);
    try deleteLayout(false, true);
    try deleteBodyReach("instance-task-durability");
    _ = try Frame.paintedText("勿重复执行删除");
    try deleteBodyReach("instance-task-recovery");
    _ = try Frame.paintedText("fixture-recovery-directory");
    try Frame.absent("instance-task-retry");
    try Frame.click("instance-task-close");
    try assertClosed();
}

test "instance deletion compact task stays centered through resize ignores dragging and cancels a real worker" {
    try atDeleteSizes(deleteCanceled);
}

test "instance deletion compact task retains config failure and retries saving before manual close" {
    try atDeleteSizes(deleteRetry);
}

test "instance deletion compact task preserves partial deletion failure and retained safety lease" {
    try atDeleteSizes(deleteFailed);
}

test "instance deletion compact task keeps uncertain durability and recovery path reachable" {
    try atDeleteSizes(deleteRecovery);
}
