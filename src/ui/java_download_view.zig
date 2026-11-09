const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const components = @import("components.zig");
const java_download = @import("../core/java_download.zig");
const java_download_controller = @import("../application/java_download_controller.zig");
const tasks = @import("../core/tasks.zig");
const task_view = @import("instance_task_view.zig");
const R = dvui.Rect;

const Command = union(enum) { start: java_download_controller.Request, cancel };

pub const Ui = struct {
    start_admitted: bool = false,
    vendor: java_download.Vendor = .azul,
    major: u8 = 21,
    failure: ?anyerror = null,
    pending: ?Command = null,
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

/// Preserve the required game version when acquisition is opened from a chooser.
pub fn suggestMajor(ui: *Ui, required: u32) void {
    if (ui.pending != null or required > std.math.maxInt(u8)) return;
    const major: u8 = @intCast(required);
    if (!java_download.supported(.azul, major)) return;
    ui.major = major;
    if (!java_download.supported(ui.vendor, major)) ui.vendor = .azul;
}

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
        .font = if (muted) theme.captionFont() else theme.bodyFont(),
        .color_text = if (muted) .{ .color = theme.colors.muted } else null,
        .background = false,
    });
    defer layout.deinit();
    layout.addText(value, .{});
}

fn feedback(src: std.builtin.SourceLocation, value: []const u8, color: dvui.Color) void {
    const layout = dvui.textLayout(src, .{}, .{
        .expand = .horizontal,
        .max_size_content = .width(0),
        .padding = R.all(0),
        .margin = .{ .y = theme.style.spacing.row_gap },
        .font = theme.bodyFont(),
        .color_text = .{ .color = color },
        .background = false,
    });
    defer layout.deinit();
    layout.addText(value, .{});
}

fn vendorName(vendor: java_download.Vendor) []const u8 {
    return switch (vendor) {
        .azul => "Azul Zulu CA",
        .microsoft => "Microsoft OpenJDK",
    };
}

fn lockedValue(src: std.builtin.SourceLocation, name: []const u8, value: []const u8, tag: []const u8) void {
    var buffer: [64]u8 = @splat(0);
    const length = @min(value.len, buffer.len - 1);
    @memcpy(buffer[0..length], value[0..length]);
    _ = components.entry(src, name, &buffer, .{ .enabled = false, .kind = .full, .gap_after = 0, .tag = tag });
}

fn selectors(ui: *Ui, locked: bool) void {
    const panel = components.formPanel(@src(), .{ .tag = "java-download-selectors" });
    defer panel.deinit();
    const fields = components.formRow(@src());
    defer fields.deinit();
    {
        const vendor = fields.cell(@src(), 0);
        defer vendor.deinit();
        components.fieldLabel(@src(), "发行商");
        if (locked) {
            lockedValue(@src(), "发行商", vendorName(ui.vendor), "java-download-vendor");
        } else {
            var vendor_index: usize = if (ui.vendor == .azul) 0 else 1;
            if (components.dropdown(@src(), "发行商", &.{ "Azul Zulu CA", "Microsoft OpenJDK" }, .{ .choice = &vendor_index }, .{}, .{ .tag = "java-download-vendor", .margin = R.all(0) })) {
                ui.vendor = if (vendor_index == 0) .azul else .microsoft;
                if (!java_download.supported(ui.vendor, ui.major)) ui.major = 21;
            }
        }
    }
    {
        const major = fields.cell(@src(), 1);
        defer major.deinit();
        components.fieldLabel(@src(), "版本");
        if (locked) {
            lockedValue(@src(), "版本", frameFmt("Java {d}", .{ui.major}), "java-download-major");
        } else {
            const major_values = java_download.vendorMajors(ui.vendor);
            var labels: [java_download.majors.len][]const u8 = undefined;
            for (major_values, 0..) |value, i| labels[i] = frameFmt("Java {d}", .{value});
            var major_index: usize = 0;
            for (major_values, 0..) |value, i| {
                if (value == ui.major) {
                    major_index = i;
                    break;
                }
            }
            if (components.dropdown(@src(), "版本", labels[0..major_values.len], .{ .choice = &major_index }, .{}, .{ .tag = "java-download-major", .margin = R.all(0) })) ui.major = major_values[major_index];
        }
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

fn progressText(buffer: []u8, progress: tasks.Progress) ![]const u8 {
    const byte_progress = progress.stage == .downloading or progress.stage == .verifying;
    if (byte_progress) {
        var received_buffer: [48]u8 = undefined;
        var total_buffer: [48]u8 = undefined;
        const received = try task_view.formatBytes(&received_buffer, progress.completed);
        if (progress.total) |total| {
            return std.fmt.bufPrint(buffer, "已接收 {s} / {s}", .{ received, try task_view.formatBytes(&total_buffer, total) });
        }
        return std.fmt.bufPrint(buffer, "已接收 {s}，总量未知", .{received});
    }
    if (progress.total) |total| return std.fmt.bufPrint(buffer, "进度 {d} / {d}", .{ progress.completed, total });
    return std.fmt.bufPrint(buffer, "进度 {d}，总量未知", .{progress.completed});
}

fn speedText(buffer: []u8, phase: java_download_controller.Phase, stage: tasks.Stage, speed: f64, cancel_requested: bool) !?[]const u8 {
    if (phase != .running or stage != .downloading or cancel_requested) return null;
    var speed_buffer: [48]u8 = undefined;
    return try std.fmt.bufPrint(buffer, "速度：{s}", .{try task_view.formatSpeed(&speed_buffer, speed, true)});
}

fn status(snapshot: java_download_controller.Snapshot, cancel_requested: bool) void {
    if (snapshot.request) |request| {
        text(@src(), frameFmt("{s} · Java {d}", .{ vendorName(request.vendor), request.major }), true);
        gap(@src(), theme.spacing.row_gap);
    }
    switch (snapshot.phase) {
        .idle => {},
        .running => {
            text(@src(), if (cancel_requested) "正在取消…" else stageName(snapshot.progress.stage), false);
            gap(@src(), theme.spacing.row_gap);
            dvui.progress(@src(), .{ .percent = progressFraction(snapshot.progress) }, .{ .expand = .horizontal, .min_size_content = .{ .h = theme.style.feedback.progress_height }, .margin = R.all(0) });
            gap(@src(), theme.spacing.row_gap);
            var progress_buffer: [160]u8 = undefined;
            text(@src(), progressText(&progress_buffer, snapshot.progress) catch "—", true);
            var speed_buffer: [80]u8 = undefined;
            if (speedText(&speed_buffer, snapshot.phase, snapshot.progress.stage, snapshot.bytes_per_second, cancel_requested) catch null) |speed| {
                text(@src(), speed, true);
            }
        },
        .complete => {
            if (snapshot.installed == null) feedback(@src(), "处理已结束，但没有已下载的 Java 运行环境。", theme.colors.warning);
        },
        .canceled => text(@src(), "已取消下载", true),
        .failed => {
            if (snapshot.failure) |err| {
                feedback(@src(), frameFmt("下载失败：{s}", .{@errorName(err)}), theme.colors.danger);
            } else {
                feedback(@src(), "下载失败", theme.colors.danger);
            }
        },
    }
    if (snapshot.release) |release| {
        gap(@src(), theme.spacing.row_gap);
        text(@src(), frameFmt("运行环境版本：{s}", .{release.version}), true);
    }
    if (snapshot.installed) |installed| {
        gap(@src(), theme.spacing.card_gap);
        if (snapshot.probe_failure != null or installed.status == .unusable) {
            feedback(@src(), "已下载，但 Java 不可用；文件已保留。", theme.colors.warning);
        } else if (installed.status == .installed_unverified) {
            feedback(@src(), "已下载，尚未验证；不能作为可用 Java。", theme.colors.warning);
        } else if (snapshot.registered) {
            text(@src(), "下载完成，Java 已验证并添加到管理列表。", false);
        } else {
            feedback(@src(), "已下载并验证，但未添加到 Java 管理列表。", theme.colors.warning);
        }
        gap(@src(), theme.spacing.row_gap);
        text(@src(), "保留目录", true);
        text(@src(), installed.directory, true);
        gap(@src(), theme.spacing.row_gap);
        text(@src(), "Java 路径", true);
        text(@src(), installed.java_path, true);
    }
    if (snapshot.probe_failure) |err| feedback(@src(), frameFmt("Java 验证失败：{s}", .{@errorName(err)}), theme.colors.danger);
    if (snapshot.registration_failure) |err| feedback(@src(), frameFmt("添加到管理列表失败：{s}", .{@errorName(err)}), theme.colors.danger);
}

/// Reset presentation admission before drawing any page. Navigation does not cancel work.
pub fn beginFrame(ui: *Ui) void {
    ui.start_admitted = false;
}

/// The owning Java page supplies mutation gates; task lifetime is independent of visibility.
pub fn drawInline(ui: *Ui, controller: *java_download_controller.Controller, enabled: bool) void {
    ui.start_admitted = enabled;
    drawBody(ui, controller, enabled);
}

pub const Action = enum { none, start, cancel };

/// Reserve the fixed footer; capture form values after its input is processed.
pub fn drawActions(ui: *Ui, controller: *java_download_controller.Controller, enabled: bool) Action {
    const snapshot = controller.snapshot();
    const platform_hint = if (controller.hostPlatform()) |platform| frameFmt("下载适用于 {s} · {s} 的 Java", .{ switch (platform.os) {
        .linux => "Linux",
        .windows => "Windows",
        .macos => "macOS",
    }, switch (platform.arch) {
        .x64 => "x64",
        .aarch64 => "ARM64",
    } }) else |_| "当前平台不受支持";
    const busy = snapshot.phase == .running or ui.pending != null;
    const supported = if (controller.hostPlatform()) |_| true else |_| false;
    if (snapshot.phase == .running) {
        if (components.button(@src(), "取消下载", .{ .standalone = true, .enabled = enabled and !ui.cancel_requested, .gravity_x = 1, .placement = .footer, .tag = "java-download-cancel" })) return .cancel;
    } else if (components.button(@src(), "下载 Java", .{ .standalone = true, .enabled = enabled and !busy and supported, .primary = true, .gravity_x = 1, .placement = .footer, .tag = "java-download-start", .tooltip = platform_hint })) return .start;
    return .none;
}

pub fn applyAction(ui: *Ui, action: Action) void {
    switch (action) {
        .none => {},
        .start => ui.queueStart(),
        .cancel => ui.queueCancel(),
    }
}

fn drawBody(ui: *Ui, controller: *java_download_controller.Controller, enabled: bool) void {
    const snapshot = controller.snapshot();
    if (snapshot.phase != .running) ui.cancel_requested = false;
    const busy = snapshot.phase == .running or ui.pending != null;
    selectors(ui, !enabled or busy);
    if (controller.hostPlatform()) |_| {} else |err| {
        feedback(@src(), frameFmt("当前平台不受支持：{s}", .{@errorName(err)}), theme.colors.warning);
    }
    if (ui.failure) |err| feedback(@src(), frameFmt("无法开始下载：{s}", .{@errorName(err)}), theme.colors.danger);
    status(snapshot, ui.cancel_requested);
}

fn validateRequest(request: java_download_controller.Request) !void {
    if (!java_download.supported(request.vendor, request.major)) return error.UnsupportedRelease;
}

fn finishQueued(ui: *Ui, controller: anytype) void {
    const command = ui.pending orelse return;
    const admitted = ui.start_admitted;
    ui.start_admitted = false;
    ui.pending = null;
    switch (command) {
        .start => |request| {
            if (!admitted) return;
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
    ui.start_admitted = true;
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
    ui.start_admitted = true;
    ui.vendor = .microsoft;
    ui.major = 8;
    ui.queueStart();
    finishQueued(&ui, &controller);
    try std.testing.expectEqual(@as(?anyerror, error.UnsupportedRelease), ui.failure);
    try std.testing.expectEqual(@as(usize, 0), controller.starts);
    try std.testing.expect(ui.pending == null);
}

test "explicit cancellation overrides inline start and stays deferred" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    var controller: TestController = .{};
    ui.start_admitted = true;
    ui.queueStart();
    ui.queueCancel();
    try std.testing.expectEqual(@as(usize, 0), controller.cancels);
    finishQueued(&ui, &controller);
    try std.testing.expectEqual(@as(usize, 0), controller.starts);
    try std.testing.expectEqual(@as(usize, 1), controller.cancels);
    try std.testing.expect(ui.cancel_requested);
}

test "navigation rejects an unseen start without cancelling ongoing work" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    var controller: TestController = .{};
    ui.start_admitted = true;
    ui.queueStart();
    finishQueued(&ui, &controller);
    try std.testing.expectEqual(@as(usize, 1), controller.starts);
    // An unseen acquisition view cannot admit another queued start.
    ui.queueStart();
    beginFrame(&ui);
    finishQueued(&ui, &controller);
    try std.testing.expectEqual(@as(usize, 1), controller.starts);
    try std.testing.expectEqual(@as(usize, 0), controller.cancels);
    try std.testing.expect(ui.pending == null);
}

test "inline start failure remains visible and retry needs fresh admission" {
    var ui = Ui.init(std.testing.allocator);
    defer ui.deinit();
    var controller: TestController = .{ .failure = error.Busy };
    ui.queueStart();
    finishQueued(&ui, &controller);
    try std.testing.expectEqual(@as(usize, 0), controller.starts);
    ui.start_admitted = true;
    ui.queueStart();
    finishQueued(&ui, &controller);
    try std.testing.expectEqual(@as(?anyerror, error.Busy), ui.failure);
    try std.testing.expect(ui.pending == null);
    controller.failure = null;
    ui.start_admitted = true;
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

test "Java transfer captions format bytes without converting item progress" {
    var buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings("已接收 512 B / 1.0 KB", try progressText(&buffer, .{ .stage = .downloading, .completed = 512, .total = 1024 }));
    try std.testing.expectEqualStrings("已接收 10.0 MB / 100.0 MB", try progressText(&buffer, .{ .stage = .downloading, .completed = 10 * 1024 * 1024, .total = 100 * 1024 * 1024 }));
    try std.testing.expectEqualStrings("已接收 1.5 KB，总量未知", try progressText(&buffer, .{ .stage = .downloading, .completed = 1536, .total = null }));
    try std.testing.expectEqualStrings("已接收 0 B / 0 B", try progressText(&buffer, .{ .stage = .verifying, .completed = 0, .total = 0 }));
    try std.testing.expectEqualStrings("进度 2 / 8", try progressText(&buffer, .{ .stage = .extracting, .completed = 2, .total = 8 }));
    _ = try progressText(&buffer, .{ .stage = .downloading, .completed = std.math.maxInt(u64), .total = std.math.maxInt(u64) });
}

test "Java live speed appears only during uncanceled active downloads" {
    var buffer: [80]u8 = undefined;
    try std.testing.expectEqualStrings("速度：1.5 MB/s", (try speedText(&buffer, .running, .downloading, 1.5 * 1024 * 1024, false)).?);
    try std.testing.expectEqualStrings("速度：0 B/s", (try speedText(&buffer, .running, .downloading, 0, false)).?);
    for ([_]f64{ -1, std.math.nan(f64), std.math.inf(f64) }) |speed| {
        try std.testing.expectEqualStrings("速度：—", (try speedText(&buffer, .running, .downloading, speed, false)).?);
    }
    try std.testing.expect(try speedText(&buffer, .running, .downloading, 1024, true) == null);
    for ([_]java_download_controller.Phase{ .idle, .complete, .failed, .canceled }) |phase| {
        try std.testing.expect(try speedText(&buffer, phase, .downloading, 1024, false) == null);
    }
    for ([_]tasks.Stage{ .metadata, .verifying, .extracting, .scanning }) |stage| {
        try std.testing.expect(try speedText(&buffer, .running, stage, 1024, false) == null);
    }
}
