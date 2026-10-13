const std = @import("std");
const dvui = @import("dvui");
const lifecycle = @import("../core/lifecycle.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const R = dvui.Rect;

/// Geometry from this draw, in physical pixels; absent widgets stay null.
pub const Layout = struct {
    viewport: ?dvui.Rect.Physical = null,
    modal: ?dvui.Rect.Physical = null,
    clip: ?dvui.Rect.Physical = null,
    wait: ?dvui.Rect.Physical = null,
    cancel_and_quit: ?dvui.Rect.Physical = null,
    keep_open: ?dvui.Rect.Physical = null,
};

/// Call only while Policy.shutdown == .prompt; the caller applies the choice.
pub fn draw(active_background: usize) ?lifecycle.CloseChoice {
    return drawWithLayout(active_background, null);
}

/// Reports actual widget rectangles without applying any application policy.
pub fn drawWithLayout(active_background: usize, layout: ?*Layout) ?lifecycle.CloseChoice {
    if (layout) |report| report.* = .{ .viewport = dvui.windowRectPixels() };
    var open = true;
    var choice: ?lifecycle.CloseChoice = null;
    {
        const modal = components.modalWithClose(@src(), "退出启动器 · 后台任务", theme.style.dialogs.shutdown_height, &open);
        defer modal.deinit();
        const previous_clip = dvui.clip(modal.data().rectScale().r);
        defer dvui.clipSet(previous_clip);
        if (layout) |report| report.modal = modal.data().rectScale().r;
        // Reserve the entire footer before the text takes the remaining space.
        {
            const actions = dvui.box(@src(), .{}, .{
                .tag = "shutdown-actions",
                .expand = .horizontal,
                .gravity_y = 1,
                .padding = R.all(0),
                .margin = .{ .y = theme.style.dialogs.footer_gap },
            });
            defer actions.deinit();
            if (layout) |report| report.clip = dvui.clipGet();
            if (components.button(@src(), "等待完成", .{ .expand = true, .placement = .footer, .rect_out = if (layout) |report| &report.wait else null })) choice = .wait;
            _ = dvui.spacer(@src(), .{ .min_size_content = .height(12) });
            if (components.button(@src(), "取消任务并退出", .{ .expand = true, .placement = .footer, .rect_out = if (layout) |report| &report.cancel_and_quit else null })) choice = .cancel_and_quit;
            _ = dvui.spacer(@src(), .{ .min_size_content = .height(12) });
            if (components.button(@src(), "保持打开", .{ .expand = true, .primary = true, .placement = .footer, .rect_out = if (layout) |report| &report.keep_open else null })) choice = .keep_open;
        }
        {
            const content = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{
                .tag = "shutdown-information",
                .expand = .both,
                .padding = R.all(0),
                .margin = R.all(0),
            });
            defer content.deinit();
            const information = components.modalSection(@src(), .{ .min_height = 116, .gap_after = 0, .tag = "shutdown-information-panel" });
            defer information.deinit();
            {
                const question = dvui.textLayout(@src(), .{}, .{
                    .font = theme.headingFont(),
                    .expand = .horizontal,
                    .padding = R.all(0),
                    .margin = .{ .y = 8, .h = 8 },
                    .background = false,
                });
                defer question.deinit();
                question.addText("要退出启动器吗？", .{});
            }
            {
                var buffer: [128]u8 = undefined;
                const count = std.fmt.bufPrint(&buffer, "仍有 {d} 个后台任务正在进行。", .{active_background}) catch unreachable;
                const status = dvui.textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .padding = R.all(0),
                    .margin = .{ .h = 16 },
                    .color_text = .{ .color = theme.muted },
                    .background = false,
                });
                defer status.deinit();
                status.addText(count, .{ .color_text = .{ .color = theme.muted } });
            }
        }
        for (dvui.events()) |*event| {
            if (!dvui.eventMatch(event, .{
                .id = modal.data().id,
                .focus_id = dvui.focusedWidgetIdInCurrentSubwindow(),
                .r = modal.data().rectScale().r,
            })) continue;
            if (event.evt == .key and event.evt.key.action == .down and event.evt.key.code == .escape) {
                event.handle(@src(), modal.data());
                open = false;
            }
        }
    }
    return if (!open) .keep_open else choice;
}

test {
    std.testing.refAllDecls(@This());
}
