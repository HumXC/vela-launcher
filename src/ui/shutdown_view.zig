const std = @import("std");
const dvui = @import("dvui");
const lifecycle = @import("../core/lifecycle.zig");
const theme = @import("theme.zig");
const R = dvui.Rect;

/// Call only while Policy.shutdown == .prompt; the caller applies the choice.
pub fn draw(active_background: usize) ?lifecycle.CloseChoice {
    const window = dvui.windowRect();
    const width = @max(0, @min(420, window.w - 24));
    const height = @max(0, @min(300, window.h - 24));
    var open = true;
    var choice: ?lifecycle.CloseChoice = null;
    {
        const modal = dvui.floatingWindow(@src(), .{
            .modal = true,
            .open_flag = &open,
            .resize = .none,
            .window_avoid = .none,
        }, .{
            .rect = .{
                .x = window.x + (window.w - width) / 2,
                .y = window.y + (window.h - height) / 2,
                .w = width,
                .h = height,
            },
            .min_size_content = .{ .w = @max(0, width - 26), .h = @max(0, height - 26) },
            .max_size_content = .{ .w = @max(0, width - 26), .h = @max(0, height - 26) },
            .padding = R.all(12),
            .border = R.all(1),
            .margin = R.all(0),
            .corners = .all(8),
            .label = .{ .text = "退出启动器" },
        });
        defer modal.deinit();
        modal.dragAreaSet(dvui.windowHeader("退出启动器", "", &open));
        {
            const content = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{
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
            const button_options: dvui.Options = .{
                .expand = .horizontal,
                .min_size_content = .{ .h = 20 },
                .padding = R.all(8),
                .margin = .{ .h = 8 },
                .border = R.all(1),
                .corners = .all(8),
                .style = .control,
            };
            if (dvui.button(@src(), "等待完成", .{}, button_options)) choice = .wait;
            if (dvui.button(@src(), "取消任务并退出", .{}, button_options)) choice = .cancel_and_quit;
            if (dvui.button(@src(), "保持打开", .{}, button_options.override(.{ .style = .highlight }))) choice = .keep_open;
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
