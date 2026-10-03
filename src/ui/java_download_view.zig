const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const java_download = @import("../core/java_download.zig");
const java_download_controller = @import("java_download_controller.zig");
const tasks = @import("../core/tasks.zig");
const R = dvui.Rect;

const Command = union(enum) { start: java_download_controller.Request, cancel };

pub const Ui = struct {
    modal_open: bool = false,
    vendor: java_download.Vendor = .azul,
    major: u8 = 21,
    failure: ?anyerror = null,
    pending: ?Command = null,
    was_open: bool = false,
    cancel_requested: bool = false,

    pub fn init(a: std.mem.Allocator) Ui {
        _ = a;
        return .{};
    }

    pub fn deinit(self: *Ui) void {
        self.* = undefined;
    }

    fn queueStart(self: *Ui) void {
        if (self.pending != null) return;
        self.pending = .{ .start = .{ .vendor = self.vendor, .major = self.major } };
    }

    fn queueCancel(self: *Ui) void {
        self.pending = .cancel;
    }
};

fn frameFmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}

fn gap(src: std.builtin.SourceLocation, height: f32) void {
    _ = dvui.spacer(src, .{ .min_size_content = .{ .h = height } });
}

fn text(src: std.builtin.SourceLocation, value: []const u8, muted: bool) void {
    const layout = dvui.textLayout(src, .{}, .{
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = R.all(0),
        .margin = R.all(0),
        .font = if (muted) dvui.themeGet().font_body.withSize(14) else dvui.themeGet().font_body,
        .color_text = if (muted) .{ .color = theme.muted } else null,
    });
    defer layout.deinit();
    layout.addText(value, .{});
}

fn warning(src: std.builtin.SourceLocation, value: []const u8) void {
    const layout = dvui.textLayout(src, .{}, .{
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = R.all(0),
        .margin = .{ .y = 8 },
        .color_text = .{ .color = dvui.Color.fromHex("F0A6A1") },
    });
    defer layout.deinit();
    layout.addText(value, .{});
}

fn action(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, disabled: bool, highlighted: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = disabled }, .{
        .min_size_content = .{ .h = 24 },
        .padding = R.all(10),
        .margin = .{ .w = 8, .h = 4 },
        .corners = .all(8),
        .border = R.all(1),
        .style = if (highlighted) .highlight else .control,
        .tab_index = if (disabled) 0 else null,
        .label = .{ .text = name },
    });
    defer button.deinit();
    if (!disabled) button.processEvents();
    button.drawBackground();
    {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .min_size_content = .{ .h = 24 }, .padding = R.all(0), .margin = R.all(0) });
        defer row.deinit();
        dvui.icon(@src(), name, asset, .{}, button.style().override(.{
            .min_size_content = .{ .w = 18, .h = 18 },
            .max_size_content = .{ .w = 18, .h = 18 },
            .gravity_y = 0.5,
            .padding = R.all(0),
            .margin = .{ .w = 8 },
            .role = .none,
        }));
        dvui.labelNoFmt(@src(), name, .{ .align_y = 0.5 }, button.style().override(.{ .min_size_content = .{ .h = 24 }, .padding = R.all(0), .margin = R.all(0) }));
    }
    if (!disabled) button.drawFocus();
    return !disabled and button.clicked();
}

fn vendorName(vendor: java_download.Vendor) []const u8 {
    return switch (vendor) {
        .azul => "Azul Zulu CA",
        .microsoft => "Microsoft OpenJDK",
    };
}

fn selectors(ui: *Ui, locked: bool) void {
    text(@src(), "发行商", true);
    gap(@src(), 6);
    if (locked) {
        text(@src(), vendorName(ui.vendor), false);
    } else {
        var vendor_index: usize = if (ui.vendor == .azul) 0 else 1;
        if (dvui.dropdown(@src(), &.{ "Azul Zulu CA", "Microsoft OpenJDK" }, .{ .choice = &vendor_index }, .{}, .{
            .expand = .horizontal,
            .max_size_content = .width(0),
            .min_size_content = .{ .h = 24 },
            .padding = R.all(8),
            .margin = R.all(0),
            .corners = .all(8),
            .label = .{ .text = "发行商" },
        })) {
            ui.vendor = if (vendor_index == 0) .azul else .microsoft;
            if (!java_download.supported(ui.vendor, ui.major)) ui.major = 21;
        }
    }
    gap(@src(), 16);
    text(@src(), "Java 主版本", true);
    gap(@src(), 6);
    if (locked) {
        text(@src(), frameFmt("Java {d}", .{ui.major}), false);
    } else {
        const major_values = java_download.vendorMajors(ui.vendor);
        var labels: [java_download.majors.len][]const u8 = undefined;
        for (major_values, 0..) |major, i| labels[i] = frameFmt("Java {d}", .{major});
        const major_labels = labels[0..major_values.len];
        var major_index: usize = 0;
        for (major_values, 0..) |major, i| {
            if (major == ui.major) {
                major_index = i;
                break;
            }
        }
        if (dvui.dropdown(@src(), major_labels, .{ .choice = &major_index }, .{}, .{
            .expand = .horizontal,
            .max_size_content = .width(0),
            .min_size_content = .{ .h = 24 },
            .padding = R.all(8),
            .margin = R.all(0),
            .corners = .all(8),
            .label = .{ .text = "Java 主版本" },
        })) ui.major = major_values[major_index];
    }
}

fn stageName(stage: tasks.Stage) []const u8 {
    return switch (stage) {
        .queued => "等待开始",
        .metadata => "获取下载信息",
        .downloading => "正在下载",
        .verifying => "校验下载文件",
        .extracting => "解压文件",
        .installing => "保存运行环境",
        .scanning => "验证 Java",
        .finalizing => "完成处理",
        .backing_up => "正在备份",
        .restoring => "正在恢复",
        .copying => "正在复制",
    };
}

fn progressFraction(progress: tasks.Progress) f32 {
    const total = progress.total orelse return 0;
    if (total == 0) return 0;
    return @as(f32, @floatFromInt(@min(progress.completed, total))) / @as(f32, @floatFromInt(total));
}

fn status(snapshot: java_download_controller.Snapshot, cancel_requested: bool) void {
    if (snapshot.request) |request| {
        text(@src(), frameFmt("{s} · Java {d}", .{ vendorName(request.vendor), request.major }), true);
        gap(@src(), 8);
    }
    switch (snapshot.phase) {
        .idle => {},
        .running => {
            text(@src(), if (cancel_requested) "正在取消…" else stageName(snapshot.progress.stage), false);
            gap(@src(), 8);
            dvui.progress(@src(), .{ .percent = progressFraction(snapshot.progress) }, .{ .expand = .horizontal, .min_size_content = .{ .h = 6 }, .margin = R.all(0) });
            gap(@src(), 8);
            const byte_progress = snapshot.progress.stage == .downloading or snapshot.progress.stage == .verifying;
            const caption = if (byte_progress) "已接收" else "进度";
            const unit = if (byte_progress) "字节" else "";
            if (snapshot.progress.total) |total| {
                text(@src(), frameFmt("{s} {d} / {d} {s}", .{ caption, snapshot.progress.completed, total, unit }), true);
            } else {
                text(@src(), frameFmt("{s} {d} {s}，总量未知", .{ caption, snapshot.progress.completed, unit }), true);
            }
        },
        .complete => {
            if (snapshot.installed == null) warning(@src(), "处理已结束，但没有已下载的 Java 运行环境。");
        },
        .canceled => text(@src(), "已取消下载", true),
        .failed => {
            if (snapshot.failure) |err| {
                warning(@src(), frameFmt("下载失败：{s}", .{@errorName(err)}));
            } else {
                warning(@src(), "下载失败");
            }
        },
    }
    if (snapshot.release) |release| {
        gap(@src(), 8);
        text(@src(), frameFmt("运行环境版本：{s}", .{release.version}), true);
    }
    if (snapshot.installed) |installed| {
        gap(@src(), 12);
        if (snapshot.probe_failure != null or installed.status == .unusable) {
            warning(@src(), "已下载，但 Java 不可用；文件已保留。");
        } else if (installed.status == .installed_unverified) {
            warning(@src(), "已下载，尚未验证；不能作为可用 Java。");
        } else if (snapshot.registered) {
            text(@src(), "下载完成，Java 已验证并添加到管理列表。", false);
        } else {
            warning(@src(), "已下载并验证，但未添加到 Java 管理列表。");
        }
        gap(@src(), 8);
        text(@src(), "保留目录", true);
        text(@src(), installed.directory, false);
        gap(@src(), 8);
        text(@src(), "Java 路径", true);
        text(@src(), installed.java_path, false);
    }
    if (snapshot.probe_failure) |err| warning(@src(), frameFmt("Java 验证失败：{s}", .{@errorName(err)}));
    if (snapshot.registration_failure) |err| warning(@src(), frameFmt("添加到管理列表失败：{s}", .{@errorName(err)}));
}

pub fn draw(ui: *Ui, controller: *java_download_controller.Controller) void {
    if (!ui.modal_open) {
        if (ui.was_open) ui.queueCancel();
        ui.was_open = false;
        return;
    }
    ui.was_open = true;
    const snapshot = controller.snapshot();
    if (snapshot.phase != .running) ui.cancel_requested = false;
    const busy = snapshot.phase == .running or ui.pending != null;
    const window = dvui.windowRect();
    const width = @max(160, @min(600, window.w - 56));
    const height = @max(140, @min(560, window.h - 56));
    {
        const modal = dvui.floatingWindow(@src(), .{
            .modal = true,
            .open_flag = &ui.modal_open,
            .resize = .none,
            .window_avoid = .none,
        }, .{
            .rect = .{ .x = window.x + (window.w - width - 26) / 2, .y = window.y + (window.h - height - 26) / 2, .w = width + 26, .h = height + 26 },
            .min_size_content = .{ .w = width, .h = height },
            .max_size_content = .{ .w = width, .h = height },
            .padding = R.all(12),
            .margin = R.all(0),
            .corners = .all(8),
            .label = .{ .text = "下载 Java" },
        });
        defer modal.deinit();
        modal.dragAreaSet(dvui.windowHeader("下载 Java", "", &ui.modal_open));
        {
            const actions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .gravity_y = 1, .min_size_content = .{ .h = 48 }, .margin = .{ .y = 12 }, .padding = R.all(0) });
            defer actions.deinit();
            if (snapshot.phase == .running) {
                if (action(@src(), "取消下载", dvui.entypo.cross, ui.cancel_requested, false)) ui.queueCancel();
            } else {
                if (action(@src(), "下载 Java", dvui.entypo.download, busy, true)) ui.queueStart();
                if (action(@src(), "关闭", dvui.entypo.cross, false, false)) ui.modal_open = false;
            }
        }
        const body = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0), .border = R.all(0), .background = false });
        defer body.deinit();
        gap(@src(), 8);
        selectors(ui, busy or ui.pending != null);
        gap(@src(), 16);
        text(@src(), "当前平台", true);
        gap(@src(), 6);
        if (controller.hostPlatform()) |platform| {
            text(@src(), frameFmt("{s} · {s}", .{ @tagName(platform.os), @tagName(platform.arch) }), false);
        } else |err| {
            warning(@src(), frameFmt("当前平台不受支持：{s}", .{@errorName(err)}));
        }
        gap(@src(), 20);
        if (ui.failure) |err| warning(@src(), frameFmt("无法开始下载：{s}", .{@errorName(err)}));
        status(snapshot, ui.cancel_requested);
    }
    if (!ui.modal_open) {
        ui.queueCancel();
        ui.was_open = false;
    }
}

fn validateRequest(request: java_download_controller.Request) !void {
    if (!java_download.supported(request.vendor, request.major)) return error.UnsupportedRelease;
}

fn finishQueued(ui: *Ui, controller: anytype) void {
    const command = ui.pending orelse return;
    ui.pending = null;
    switch (command) {
        .start => |request| {
            if (!ui.modal_open) return;
            ui.failure = null;
            validateRequest(request) catch |err| {
                ui.failure = err;
                return;
            };
            controller.start(request) catch |err| {
                ui.failure = err;
                return;
            };
            ui.cancel_requested = false;
        },
        .cancel => {
            controller.cancel();
            ui.cancel_requested = true;
        },
    }
}

// Call after the complete frame draw: snapshot strings are borrowed only above.
pub fn finish(ui: *Ui, controller: *java_download_controller.Controller) void {
    finishQueued(ui, controller);
}

const TestController = struct {
    starts: usize = 0,
    cancels: usize = 0,
    request: ?java_download_controller.Request = null,
    failure: ?anyerror = null,

    fn start(self: *TestController, request: java_download_controller.Request) !void {
        self.starts += 1;
        if (self.failure) |err| return err;
        self.request = request;
    }

    fn cancel(self: *TestController) void {
        self.cancels += 1;
    }
};

test "download queue owns scalar selection and finishes only once" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    var controller: TestController = .{};
    ui.modal_open = true;
    ui.queueStart();
    ui.vendor = .microsoft;
    ui.major = 17;
    try std.testing.expectEqual(@as(usize, 0), controller.starts);
    finishQueued(&ui, &controller);
    try std.testing.expectEqual(java_download.Vendor.azul, controller.request.?.vendor);
    try std.testing.expectEqual(@as(u8, 21), controller.request.?.major);
    finishQueued(&ui, &controller);
    try std.testing.expectEqual(@as(usize, 1), controller.starts);
    try std.testing.expect(ui.pending == null);
}

test "finish rejects unsupported Microsoft Java 8 without starting" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    var controller: TestController = .{};
    ui.modal_open = true;
    ui.vendor = .microsoft;
    ui.major = 8;
    ui.queueStart();
    finishQueued(&ui, &controller);
    try std.testing.expectEqual(@as(?anyerror, error.UnsupportedRelease), ui.failure);
    try std.testing.expectEqual(@as(usize, 0), controller.starts);
    try std.testing.expect(ui.pending == null);
}

test "closing overrides queued start and cancellation stays deferred" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    var controller: TestController = .{};
    ui.modal_open = true;
    ui.queueStart();
    ui.modal_open = false;
    ui.queueCancel();
    try std.testing.expectEqual(@as(usize, 0), controller.cancels);
    finishQueued(&ui, &controller);
    try std.testing.expectEqual(@as(usize, 0), controller.starts);
    try std.testing.expectEqual(@as(usize, 1), controller.cancels);
    try std.testing.expect(ui.cancel_requested);
}

test "closed modal cannot execute a pending start and start errors remain visible" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    var controller: TestController = .{ .failure = error.Busy };
    ui.queueStart();
    finishQueued(&ui, &controller);
    try std.testing.expectEqual(@as(usize, 0), controller.starts);
    ui.modal_open = true;
    ui.queueStart();
    finishQueued(&ui, &controller);
    try std.testing.expectEqual(@as(?anyerror, error.Busy), ui.failure);
    try std.testing.expect(ui.pending == null);
    controller.failure = null;
    ui.queueStart();
    finishQueued(&ui, &controller);
    try std.testing.expect(ui.failure == null);
}

test "progress handles unknown zero and oversized totals" {
    try std.testing.expectEqual(@as(f32, 0), progressFraction(.{ .stage = .downloading, .completed = 4, .total = null }));
    try std.testing.expectEqual(@as(f32, 0), progressFraction(.{ .stage = .downloading, .completed = 4, .total = 0 }));
    try std.testing.expectEqual(@as(f32, 0.5), progressFraction(.{ .stage = .downloading, .completed = 4, .total = 8 }));
    try std.testing.expectEqual(@as(f32, 1), progressFraction(.{ .stage = .downloading, .completed = 10, .total = 8 }));
}
