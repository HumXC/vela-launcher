const std = @import("std");
const dvui = @import("dvui");
const lifecycle = @import("../core/lifecycle.zig");
const theme = @import("theme.zig");
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
    const window = dvui.windowRect();
    const width = @max(0, @min(420, window.w - 24));
    const height = @max(0, @min(340, window.h - 24));
    // Pass the bound on every draw, including after a native viewport resize.
    var modal_rect: R = .{
        .x = window.x + (window.w - width) / 2,
        .y = window.y + (window.h - height) / 2,
        .w = width,
        .h = height,
    };
    var open = true;
    var choice: ?lifecycle.CloseChoice = null;
    {
        const modal = dvui.floatingWindow(@src(), .{
            .modal = true,
            .rect = &modal_rect,
            .open_flag = &open,
            .resize = .none,
            .window_avoid = .none,
        }, .{
            .rect = modal_rect,
            .min_size_content = .{ .w = @max(0, width - 26), .h = @max(0, height - 26) },
            .max_size_content = .{ .w = @max(0, width - 26), .h = @max(0, height - 26) },
            .padding = R.all(12),
            .border = R.all(1),
            .margin = R.all(0),
            .corners = .all(8),
            .label = .{ .text = "退出启动器" },
        });
        defer modal.deinit();
        const previous_clip = dvui.clip(modal.data().rectScale().r);
        defer dvui.clipSet(previous_clip);
        if (layout) |report| report.modal = modal.data().rectScale().r;
        modal.dragAreaSet(dvui.windowHeader("退出启动器", "", &open));
        // Reserve the entire footer before the text takes the remaining space.
        {
            const actions = dvui.box(@src(), .{}, .{
                .tag = "shutdown-actions",
                .expand = .horizontal,
                .gravity_y = 1,
                .padding = R.all(0),
                .margin = R.all(0),
            });
            defer actions.deinit();
            if (layout) |report| report.clip = dvui.clipGet();
            const button_options: dvui.Options = .{
                .expand = .horizontal,
                .min_size_content = .{ .h = 20 },
                .padding = R.all(8),
                .margin = .{ .h = 8 },
                .border = R.all(1),
                .corners = .all(8),
                .style = .control,
            };
            if (choiceButton(@src(), "等待完成", button_options, if (layout) |report| &report.wait else null)) choice = .wait;
            if (choiceButton(@src(), "取消任务并退出", button_options, if (layout) |report| &report.cancel_and_quit else null)) choice = .cancel_and_quit;
            if (choiceButton(@src(), "保持打开", button_options.override(.{ .style = .highlight }), if (layout) |report| &report.keep_open else null)) choice = .keep_open;
        }
        {
            const content = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{
                .tag = "shutdown-information",
                .expand = .both,
                .padding = R.all(0),
                .margin = R.all(0),
            });
            defer content.deinit();
            {
                const question = dvui.textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .padding = R.all(0),
                    .margin = .{ .y = 8, .h = 8 },
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

/// The normal dvui.button rendering path, with its real border rectangle reported.
fn choiceButton(src: std.builtin.SourceLocation, label: []const u8, options: dvui.Options, rect: ?*?dvui.Rect.Physical) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{}, options);
    defer button.deinit();
    button.processEvents();
    button.drawBackground();
    dvui.labelNoFmt(@src(), label, .{ .align_x = 0.5, .align_y = 0.5 }, options.strip().override(button.style()).override(.{ .gravity_x = 0.5, .gravity_y = 0.5 }));
    button.drawFocus();
    if (rect) |report| report.* = button.data().borderRectScale().r;
    return button.clicked();
}

test {
    std.testing.refAllDecls(@This());
}
