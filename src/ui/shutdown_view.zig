const std = @import("std");
const dvui = @import("dvui");
const lifecycle = @import("../core/lifecycle.zig");
const shutdown = @import("../core/shutdown.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const R = dvui.Rect;

/// Geometry from this draw, in physical pixels; absent widgets stay null.
pub const Layout = struct {
    viewport: ?dvui.Rect.Physical = null,
    modal: ?dvui.Rect.Physical = null,
    clip: ?dvui.Rect.Physical = null,
    cancel_and_quit: ?dvui.Rect.Physical = null,
    keep_open: ?dvui.Rect.Physical = null,
};

/// Call only while Policy.shutdown == .prompt; the caller applies the choice.
pub fn draw(summary: shutdown.Summary) ?lifecycle.CloseChoice {
    return drawWithLayout(summary, null);
}

/// Reports actual widget rectangles without applying any application policy.
pub fn drawWithLayout(summary: shutdown.Summary, layout: ?*Layout) ?lifecycle.CloseChoice {
    if (layout) |report| report.* = .{ .viewport = dvui.windowRectPixels() };
    var open = true;
    var choice: ?lifecycle.CloseChoice = null;
    {
        const modal = components.modalWithClose(@src(), "确认退出启动器", theme.style.dialogs.shutdown_height, &open);
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
            if (components.button(@src(), "不退出", .{ .tag = "shutdown-keep-open", .expand = true, .primary = true, .placement = .footer, .rect_out = if (layout) |report| &report.keep_open else null })) choice = .keep_open;
            if (dvui.firstFrame(modal.data().id)) {
                if (dvui.tagGet("shutdown-keep-open")) |button| dvui.focusWidget(button.id, null, null);
            }
            _ = dvui.spacer(@src(), .{ .min_size_content = .height(12) });
            if (components.button(@src(), summary.cancelLabel(), .{ .tag = "shutdown-cancel-and-quit", .expand = true, .placement = .footer, .rect_out = if (layout) |report| &report.cancel_and_quit else null })) choice = .cancel_and_quit;
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
                if (summary.count() == 1) {
                    question.addText("当前正在", .{});
                    inline for (@typeInfo(shutdown.Operation).@"enum".field_names) |field| {
                        const operation: shutdown.Operation = @field(shutdown.Operation, field);
                        if (summary.contains(operation)) question.addText(operation.label(), .{});
                    }
                    question.addText("，确认退出？", .{});
                } else {
                    question.addText(if (summary.any()) "以下操作正在进行，确认退出？" else "确认退出启动器？", .{});
                }
            }
            {
                const status = dvui.textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .padding = R.all(0),
                    .margin = .{ .h = 16 },
                    .color_text = .{ .color = theme.colors.muted },
                    .background = false,
                });
                defer status.deinit();
                if (summary.count() > 1) {
                    inline for (@typeInfo(shutdown.Operation).@"enum".field_names) |field| {
                        const operation: shutdown.Operation = @field(shutdown.Operation, field);
                        if (summary.contains(operation)) {
                            status.addText(operation.label(), .{});
                            status.addText("\n", .{});
                        }
                    }
                }
                status.addText("退出将取消上述操作。", .{ .color_text = .{ .color = theme.colors.muted } });
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
