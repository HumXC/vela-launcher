//! Hermetic native renderer/input regression with real Manager task ownership.
const std = @import("std");
const dvui = @import("dvui");
const tasks = @import("core/tasks.zig");
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const manager_module = @import("ui/instances_manager.zig");
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
                view.drawWithEnabled(ui, store, manager, .{ .installed = &.{}, .available = &.{}, .phase = .idle, .failure = null, .completed = 0, .total = 0, .installing_version = null }, &.{}, true);
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
        const label = try paintedText(if (working) "取消" else "关闭");
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
