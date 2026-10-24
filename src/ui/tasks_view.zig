const std = @import("std");
const dvui = @import("dvui");
const tasks = @import("../core/tasks.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const R = dvui.Rect;
const recent_limit = 3;

pub const Options = struct {
    max_visible_rows: u8 = 2,
    compact: bool = false,
};

fn active(state: tasks.State) bool {
    return switch (state) {
        .queued, .running, .canceling => true,
        .canceled, .succeeded, .failed => false,
    };
}

fn stateName(state: tasks.State) []const u8 {
    return switch (state) {
        .queued => "等待中",
        .running => "进行中",
        .canceling => "正在取消",
        .canceled => "已取消",
        .succeeded => "已完成",
        .failed => "失败",
    };
}

fn stageName(stage: tasks.Stage) []const u8 {
    return switch (stage) {
        .queued => "等待",
        .metadata => "读取元数据",
        .downloading => "下载",
        .verifying => "校验",
        .extracting => "解压",
        .installing => "安装",
        .scanning => "扫描",
        .backing_up => "备份",
        .restoring => "还原",
        .copying => "复制",
        .finalizing => "完成处理",
    };
}

fn fraction(progress: tasks.Progress) f32 {
    const total = progress.total orelse return 0;
    if (total == 0) return 0;
    return @as(f32, @floatFromInt(@min(progress.completed, total))) / @as(f32, @floatFromInt(total));
}

fn rowFont(options: Options) dvui.Font {
    _ = options;
    return theme.bodyFont();
}

fn rowHeight(options: Options) f32 {
    const body = rowFont(options);
    return 2 * body.lineHeight() + theme.captionFont().textHeight() + theme.spacing.panel_padding;
}

fn drawRow(task: *tasks.Task, options: Options) !bool {
    const body = rowFont(options);
    const small = theme.captionFont();
    const height = rowHeight(options);
    const title_height = 2 * body.lineHeight();
    const arena = dvui.currentWindow().arena();
    const row = dvui.box(@src(), .{}, .{ .tag = try std.fmt.allocPrint(arena, "task-{d}-row", .{task.id}), .id_extra = @truncate(task.id), .expand = .horizontal, .min_size_content = .{ .h = height }, .max_size_content = .height(height), .padding = R.all(0), .margin = R.all(0) });
    defer row.deinit();
    const width = row.data().contentRect().w;
    const details_width = @max(0, width - theme.sizing.task_icon_button - theme.spacing.list_row_padding);
    // Explicit tracks keep wrapped titles from taking space reserved for status and controls.
    {
        var end: usize = task.title.len;
        _ = body.textSizeEx(task.title, .{ .max_width = details_width, .end_idx = &end, .end_metric = .before });
        const text = if (end > 0 and end < task.title.len and task.title[end - 1] != '\n') blk: {
            const space = std.mem.lastIndexOfScalar(u8, task.title[0..end], ' ');
            const split = if (space) |index| if (index > 0) index else end else end;
            const next = split + @intFromBool(task.title[split] == ' ');
            break :blk try std.fmt.allocPrint(arena, "{s}\n{s}", .{ task.title[0..split], task.title[next..] });
        } else task.title;
        dvui.labelNoFmt(@src(), text, .{}, .{ .tag = try std.fmt.allocPrint(arena, "task-{d}-title", .{task.id}), .rect = .{ .x = 0, .y = theme.spacing.list_row_padding / 2, .w = details_width, .h = title_height }, .font = body, .padding = R.all(0), .margin = R.all(0) });
    }
    const progress = task.progress();
    const status = if (task.state == .failed)
        try std.fmt.allocPrint(arena, "失败：{s}", .{if (task.failure) |failure| @errorName(failure) else "未知错误"})
    else if (active(task.state))
        if (progress.total) |total|
            try std.fmt.allocPrint(arena, "{s} · {s} · {d}/{d}", .{ stateName(task.state), stageName(progress.stage), progress.completed, total })
        else
            try std.fmt.allocPrint(arena, "{s} · {s} · {d}", .{ stateName(task.state), stageName(progress.stage), progress.completed })
    else
        stateName(task.state);
    dvui.labelNoFmt(@src(), status, .{}, .{ .tag = try std.fmt.allocPrint(arena, "task-{d}-status", .{task.id}), .rect = .{ .x = 0, .y = theme.spacing.row_gap + title_height, .w = details_width, .h = small.textHeight() }, .font = small, .color_text = .{ .color = if (task.state == .failed) theme.colors.danger else theme.colors.muted }, .padding = R.all(0), .margin = R.all(0) });
    dvui.progress(@src(), .{ .percent = if (task.state == .succeeded) 1 else fraction(progress), .color = if (task.state == .failed) theme.colors.danger else null }, .{ .tag = try std.fmt.allocPrint(arena, "task-{d}-progress", .{task.id}), .rect = .{ .x = 0, .y = height - theme.spacing.list_row_padding, .w = details_width, .h = theme.style.feedback.compact_progress_height }, .padding = R.all(0), .margin = R.all(0), .border = R.all(0), .corners = .all(theme.style.feedback.compact_progress_height / 2) });
    const side = theme.sizing.task_icon_button;
    const bounds: R = .{ .x = @max(0, width - side), .y = (height - side) / 2, .w = side, .h = side };
    if (task.state == .queued or task.state == .running)
        return components.iconButton(@src(), "取消任务", dvui.entypo.cross, .{ .rect = bounds, .size = side, .tag = try std.fmt.allocPrint(arena, "task-{d}-cancel", .{task.id}) });
    if (!active(task.state))
        return components.iconButton(@src(), "移除通知", dvui.entypo.cross, .{ .rect = bounds, .size = side, .tag = try std.fmt.allocPrint(arena, "task-{d}-dismiss", .{task.id}) });
    return false;
}

const Counts = struct { active: usize = 0, recent: usize = 0 };
fn counts(entries: []const *tasks.Task) Counts {
    var result: Counts = .{};
    for (entries) |entry| {
        if (active(entry.state)) result.active += 1 else result.recent = @min(recent_limit, result.recent + 1);
    }
    return result;
}

fn viewportSize(total: usize, height: f32, options: Options) struct { min: f32, max: f32 } {
    const budget = @max(@as(usize, 1), options.max_visible_rows);
    return .{ .min = @as(f32, @floatFromInt(@min(total, budget))) * height, .max = @as(f32, @floatFromInt(budget)) * height };
}

/// Reserve the same metrics used by the heading and bounded task viewport.
pub fn sectionHeight(registry: *tasks.Registry, options: Options) f32 {
    const count = counts(registry.tasks());
    const total = count.active + count.recent;
    const heading = theme.headingFont();
    const content_height = if (total == 0) dvui.themeGet().font_body.textHeight() else viewportSize(total, rowHeight(options), options).min;
    return (if (options.compact) theme.spacing.row_gap + theme.spacing.detail_gap else theme.spacing.group_gap + theme.spacing.row_gap) + heading.textHeight() + content_height;
}

/// Main thread only. Draw all active tasks and the three newest terminal entries.
pub fn draw(registry: *tasks.Registry) !void {
    try drawWithOptions(registry, .{});
}

/// The viewport budget never limits task history or active entries.
/// Cancellation and dismissal run after every section widget closes; IDs outlive row borrows.
pub fn drawWithOptions(registry: *tasks.Registry, options: Options) !void {
    const entries = registry.tasks();
    const count = counts(entries);
    const Action = union(enum) { cancel: u64, dismiss: u64 };
    var actions: std.ArrayList(Action) = .empty;
    const arena = dvui.currentWindow().arena();
    {
        const section = dvui.box(@src(), .{}, .{ .tag = "task-section", .expand = .horizontal, .padding = R.all(0), .margin = .{ .y = if (options.compact) theme.spacing.row_gap else theme.spacing.group_gap } });
        defer section.deinit();
        dvui.labelNoFmt(@src(), "任务", .{}, .{ .tag = "task-heading", .font = theme.headingFont(), .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = if (options.compact) theme.spacing.detail_gap else theme.spacing.row_gap } });
        const total = count.active + count.recent;
        if (total == 0) {
            dvui.labelNoFmt(@src(), "暂无任务", .{}, .{ .color_text = .{ .color = theme.colors.muted }, .padding = R.all(0), .margin = R.all(0) });
        } else {
            const height = rowHeight(options);
            const size = viewportSize(total, height, options);
            const scroll = dvui.scrollArea(@src(), .{}, .{ .tag = "task-viewport", .expand = .horizontal, .min_size_content = .{ .h = size.min }, .max_size_content = .height(size.max), .background = false, .border = R.all(0), .padding = R.all(0), .margin = R.all(0) });
            defer scroll.deinit();
            // Overscan one row in each direction, keeping widgets bounded by viewport size.
            const first = @min(total, @as(usize, @intFromFloat(@floor(@max(0, scroll.si.viewport.y) / height))) -| 1);
            const visible = @as(usize, @intFromFloat(@ceil(@max(height, scroll.si.viewport.h) / height))) + 3;
            const end = @min(total, first +| visible);
            if (first > 0) _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = @as(f32, @floatFromInt(first)) * height } });
            var row_index: usize = 0;
            var recent: usize = 0;
            for ([_]bool{ true, false }) |show_active| {
                var index = entries.len;
                while (index > 0) {
                    index -= 1;
                    const entry = entries[index];
                    if (active(entry.state) != show_active) continue;
                    if (!show_active) {
                        if (recent == recent_limit) break;
                        recent += 1;
                    }
                    if (row_index >= first and row_index < end) {
                        if (try drawRow(entry, options)) {
                            const action: Action = if (active(entry.state)) .{ .cancel = entry.id } else .{ .dismiss = entry.id };
                            try actions.append(arena, action);
                        }
                    }
                    row_index += 1;
                }
            }
            if (end < total) _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = @as(f32, @floatFromInt(total - end)) * height } });
        }
    }
    for (actions.items) |action| switch (action) {
        .cancel => |id| _ = registry.cancel(id),
        .dismiss => |id| _ = registry.dismiss(id),
    };
}

test "task rows distinguish every outcome and cap only finished history" {
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    for (0..20) |_| {
        const task = try registry.create(.game_install, "version");
        try registry.start(task);
        registry.finish(task, .succeeded);
    }
    const queued = try registry.create(.java_scan, "scan");
    const running = try registry.create(.java_download, "download");
    try registry.start(running);
    const canceling = try registry.create(.save_backup, "backup");
    try registry.start(canceling);
    _ = registry.cancel(canceling.id);
    const count = counts(registry.tasks());
    try std.testing.expectEqual(@as(usize, 3), count.active);
    try std.testing.expectEqual(@as(usize, recent_limit), count.recent);
    try std.testing.expect(active(queued.state));
    try std.testing.expect(active(running.state));
    try std.testing.expect(active(canceling.state));
    inline for (std.meta.tags(tasks.State)) |state| try std.testing.expect(stateName(state).len > 0);
    inline for (std.meta.tags(tasks.Stage)) |stage| try std.testing.expect(stageName(stage).len > 0);
    try std.testing.expect(!std.mem.eql(u8, stateName(.failed), stateName(.canceled)));
    try std.testing.expect(!std.mem.eql(u8, stateName(.canceled), stateName(.succeeded)));
}

test "task progress fraction handles unknown empty and clamped totals" {
    try std.testing.expectEqual(@as(f32, 0), fraction(.{ .stage = .downloading, .completed = 8, .total = null }));
    try std.testing.expectEqual(@as(f32, 0), fraction(.{ .stage = .downloading, .completed = 0, .total = 0 }));
    try std.testing.expectEqual(@as(f32, 0.5), fraction(.{ .stage = .downloading, .completed = 5, .total = 10 }));
    try std.testing.expectEqual(@as(f32, 1), fraction(.{ .stage = .downloading, .completed = 15, .total = 10 }));
}

test "compact task viewport preserves every active row and stable dimensions" {
    var registry = tasks.Registry.init(std.testing.allocator);
    defer registry.deinit();
    for (0..20) |_| _ = try registry.create(.java_scan, "scan");
    for (0..5) |_| {
        const task = try registry.create(.game_install, "version");
        try registry.start(task);
        registry.finish(task, .succeeded);
    }
    const before = counts(registry.tasks());
    try std.testing.expectEqual(@as(usize, 20), before.active);
    try std.testing.expectEqual(@as(usize, 3), before.recent);
    const compact = viewportSize(before.active + before.recent, 90, .{ .max_visible_rows = 1 });
    try std.testing.expectEqual(@as(f32, 90), compact.min);
    try std.testing.expectEqual(compact.min, compact.max);
    registry.tasks()[0].report(.scanning, 999, null);
    const after = counts(registry.tasks());
    try std.testing.expectEqual(before, after);
    const updated = viewportSize(after.active + after.recent, 90, .{ .max_visible_rows = 1 });
    try std.testing.expectEqual(compact, updated);
    const defaults = viewportSize(23, 90, .{});
    try std.testing.expectEqual(@as(f32, 180), defaults.min);
    try std.testing.expectEqual(defaults.min, defaults.max);
    const zero_budget = viewportSize(23, 90, .{ .max_visible_rows = 0 });
    try std.testing.expectEqual(compact, zero_budget);
    const single = viewportSize(1, 90, .{});
    try std.testing.expectEqual(@as(f32, 90), single.min);
    try std.testing.expectEqual(@as(f32, 180), single.max);
}
