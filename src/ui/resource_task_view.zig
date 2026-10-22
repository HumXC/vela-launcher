//! Path-bound acquisition task presentation; the controller owns all transactions.
const std = @import("std");
const dvui = @import("dvui");
const content = @import("content_manager.zig");
const state = @import("resource_download_state.zig");
const providers = @import("../core/content_providers.zig");
const tasks = @import("../core/tasks.zig");
const progress_view = @import("instance_task_view.zig");
const components = @import("components.zig");
const theme = @import("theme.zig");
fn fmt(comptime pattern: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), pattern, args) catch "";
}
fn text(src: std.builtin.SourceLocation, value: []const u8, font: dvui.Font, rect: dvui.Rect, color: dvui.Color) void {
    dvui.labelNoFmt(src, components.ellipsize(value, font, @max(0, rect.w)), .{}, .{ .rect = rect, .font = font, .padding = .all(0), .margin = .all(0), .background = false, .color_text = .{ .color = color } });
}
fn fileProgress(ui: *state.Ui, path: []const u8) ?*const tasks.File {
    if (ui.task_details) |*details| for (details.files[0..@min(details.file_count, details.files.len)]) |*file| {
        if (std.mem.eql(u8, file.name(), std.fs.path.basename(path))) return file;
    };
    return null;
}
fn fileVersion(ui: *state.Ui, record: anytype) ?providers.Version {
    const detail = ui.frame() orelse return null;
    for ([_][]const providers.Version{ detail.versions, detail.candidates }) |versions| for (versions) |version| {
        if (version.provider == record.provider and std.mem.eql(u8, version.project_id, record.project_id) and std.mem.eql(u8, version.id, record.version_id)) return version;
    };
    return null;
}
fn item(ui: *state.Ui, path: []const u8, version: ?providers.Version, primary: bool, index: usize) void {
    const progress = fileProgress(ui, path);
    var name = std.fs.path.basename(path);
    if (version) |value| {
        name = value.name;
        if (ui.frame()) |detail| if (value.provider == detail.project.provider and std.mem.eql(u8, value.project_id, detail.project.id)) {
            name = detail.project.name;
        };
        for (ui.catalog) |project| if (project.provider == value.provider and std.mem.eql(u8, project.id, value.project_id)) {
            name = project.name;
            break;
        };
    }
    const failed = if (progress) |file| if (file.failure) |err| err != error.Canceled else false else false;
    const percent: f32 = if (ui.task_state == .succeeded) 1 else if (progress) |file| progress_view.fraction(file.received, file.total) else 0;
    const complete = percent >= 1;
    const status = if (ui.task_state == .succeeded) "已安装" else if (failed) "下载失败" else if (complete) "已下载" else if (ui.task_state == .canceled) "已取消" else if (ui.task_state == .failed) "未应用" else if (progress != null) (if (progress.?.total != null) fmt("下载中 · {d:.0}%", .{percent * 100}) else "下载中") else "等待下载";
    const color = if (failed) theme.danger else if (!complete and (ui.task_state == .failed or ui.task_state == .canceled)) theme.muted else theme.accent;
    const row = components.bentoPanel(@src(), .{ .id_extra = index, .expand = .horizontal, .min_size_content = .height(72), .max_size_content = .width(0), .padding = .all(15), .margin = .{ .y = if (index == 0) 0 else 12 }, .corners = .all(theme.sizing.card_radius), .color_fill = .{ .color = theme.style.colors.inset }, .color_border = .{ .color = theme.outline } });
    defer row.deinit();
    const width = row.data().contentRect().w;
    const badge_width = @min(148, width * 0.4);
    text(@src(), name, theme.headingFont(), .{ .w = @max(0, width - badge_width - 16), .h = 28 }, theme.foreground);
    text(@src(), fmt("{s} · {s}", .{ if (version) |value| value.name else std.fs.path.basename(path), if (primary) "主资源" else "依赖资源" }), theme.fontSized(14), .{ .y = 32, .w = width, .h = 24 }, theme.muted);
    {
        const badge = dvui.box(@src(), .{}, .{ .rect = .{ .x = width - badge_width, .y = -4, .w = badge_width, .h = 32 }, .padding = .{ .x = 7, .w = 7, .y = 4, .h = 4 }, .margin = .all(0), .border = .all(1), .corners = .all(theme.sizing.control_radius), .background = true, .color_fill = .{ .color = theme.style.colors.inset }, .color_border = .{ .color = theme.outline } });
        defer badge.deinit();
        dvui.labelNoFmt(@src(), status, .{}, .{ .font = theme.fontSized(14), .padding = .all(0), .margin = .all(0), .gravity_x = 0.5, .gravity_y = 0.5, .color_text = .{ .color = color } });
    }
    dvui.progress(@src(), .{ .percent = percent, .color = color }, .{ .rect = .{ .y = 64, .w = width, .h = 8 }, .min_size_content = .height(8), .padding = .all(0), .margin = .all(0), .corners = .all(4), .tag = fmt("resource-task-file-{d}", .{index}) });
}
pub fn draw(ui: *state.Ui, snapshot: content.Snapshot, allowed: bool, comptime failureText: anytype) void {
    const modal = components.modalPanel(@src(), "下载与安装", 560, null);
    defer modal.deinit();
    const rect = dvui.parentGet().data().contentRect();
    const width = rect.w;
    const footer_y = @max(0, rect.h - 48);
    const compact = rect.h < 440;
    const body_y: f32 = if (compact) 124 else 152;
    const hint_y = if (compact) footer_y else @max(152, footer_y - 72);
    const failed = ui.task_state == .failed;
    const status_color = if (failed) theme.danger else if (ui.task_state == .succeeded) theme.accent else theme.muted;
    text(@src(), "下载与安装", theme.fontSized(24), .{ .w = width, .h = 36 }, if (failed) theme.danger else theme.foreground);
    var summary: []const u8 = if (ui.instance) |instance| instance.name else "当前实例";
    if (ui.frame()) |detail| if (detail.version()) |version| {
        summary = fmt("{s} · {s}", .{ summary, version.name });
    };
    text(@src(), summary, theme.bodyFont(), .{ .y = if (compact) 44 else 52, .w = width, .h = 24 }, theme.muted);
    const message = switch (ui.task_state) {
        .running => if (snapshot.progress) |progress| switch (progress.stage) {
            .installing, .finalizing => "正在应用资源与安装记录",
            .verifying => "正在校验资源与所需依赖",
            else => "正在下载资源与所需依赖",
        } else "正在准备资源与所需依赖",
        .succeeded => "安装完成",
        .failed => if (snapshot.recovery_required) "安装中断 · 需要恢复安装状态" else "安装失败 · 安装尚未完成",
        .canceled => "任务已取消",
        .none => "",
    };
    text(@src(), message, theme.bodyFont(), .{ .y = if (compact) 76 else 88, .w = width, .h = 24 }, status_color);
    _ = dvui.separator(@src(), .{ .rect = .{ .y = if (compact) 108 else 128, .w = width, .h = 1 }, .padding = .all(0), .margin = .all(0), .color_border = .{ .color = theme.outline } });
    {
        const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .rect = .{ .y = body_y, .w = width, .h = @max(0, hint_y - body_y - 16) }, .padding = .all(0), .margin = .all(0), .background = false });
        defer scroll.deinit();
        if (snapshot.proposal) |proposal| {
            var visible_index: usize = 0;
            for ([_]bool{ true, false }) |root_group| for (proposal.files) |file| {
                if (file.selected == false) continue;
                const primary = if (ui.frame()) |detail| file.record.provider == detail.project.provider and std.mem.eql(u8, file.record.project_id, detail.project.id) else false;
                if (primary != root_group) continue;
                item(ui, file.record.path, fileVersion(ui, file.record), primary, visible_index);
                visible_index += 1;
            };
        } else if (ui.task_details) |*details| for (details.files[0..@min(details.file_count, details.files.len)], 0..) |*file, i| item(ui, file.name(), null, i == 0, i);
    }
    if (!compact) text(@src(), if (ui.failure) |err| failureText(err) else switch (ui.task_state) {
        .succeeded => "已安装到当前实例，可在资源管理中查看。",
        .canceled => "任务已停止，可重新确认安装方案。",
        else => "已满足的 Minecraft 与加载器保持原样。",
    }, theme.bodyFont(), .{ .y = hint_y, .w = width, .h = 48 }, if (failed) theme.danger else theme.muted);
    {
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .y = footer_y, .w = width, .h = 48 }, .padding = .all(0), .margin = .all(0), .background = false });
        defer actions.deinit();
        const ready = allowed and !snapshot.busy;
        if (ui.task_state == .running) {
            if (components.button(@src(), "取消任务", .{ .enabled = allowed, .gravity_x = 1, .min_width = 144, .placement = .footer, .tag = "resource-task-cancel" })) ui.queue(.cancel);
        } else if (snapshot.recovery_required) {
            if (snapshot.transactions.len > 0 and components.button(@src(), "恢复安装状态", .{ .enabled = ready, .primary = true, .gravity_x = 1, .min_width = 144, .placement = .footer, .tag = "resource-task-recover" })) ui.queue(.{ .recover = snapshot.transactions[0] });
        } else {
            if (ui.task_state == .succeeded) {
                if (components.button(@src(), "查看本地", .{ .enabled = ready, .primary = true, .min_width = 144, .placement = .footer, .tag = "resource-task-local" })) ui.queue(.view_local);
            } else if (components.button(@src(), "重试", .{ .enabled = ready, .primary = true, .min_width = 144, .placement = .footer, .tag = "resource-task-retry" })) ui.queue(.retry);
            if (components.button(@src(), "关闭", .{ .enabled = ready, .gravity_x = 1, .min_width = 144, .placement = .footer, .tag = "resource-task-close" })) ui.queue(.dismiss);
        }
    }
}
