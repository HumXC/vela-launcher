//! Independent mock component gallery. No managers, workers, stores or business finish calls.
const std = @import("std");
const dvui = @import("dvui");
const components = @import("components.zig");
const theme = @import("theme.zig");
const accounts = @import("accounts_view.zig");
const instances = @import("instances_view.zig");
const config = @import("../core/config.zig");
const tasks = @import("../core/tasks.zig");

pub const Scene = enum { @"account-add", @"account-offline", @"account-microsoft", @"account-delete", @"account-signout", @"account-code", @"account-wait", @"instance-delete", @"instance-unsaved", @"instance-task", dialog, controls, @"selection-card" };
pub const Variant = enum { default, empty, filled, @"long-text", disabled, loading, @"error", selected, downloading, @"unknown-total", verifying, complete, failed, @"no-files" };

pub fn supports(scene: Scene, variant: Variant) bool {
    if (variant == .default) return true;
    return switch (scene) {
        .@"account-add" => switch (variant) {
            .empty, .filled, .@"long-text", .loading, .@"error" => true,
            else => false,
        },
        .@"account-offline", .@"account-microsoft", .@"account-delete", .@"account-signout", .@"instance-delete" => switch (variant) {
            .@"long-text", .disabled, .@"error" => true,
            else => false,
        },
        .@"account-code", .@"account-wait" => false,
        .@"instance-unsaved" => variant == .disabled,
        .@"instance-task" => switch (variant) {
            .downloading, .@"unknown-total", .verifying, .complete, .failed, .@"no-files", .@"long-text", .disabled => true,
            else => false,
        },
        .dialog => switch (variant) {
            .@"long-text", .disabled, .@"error" => true,
            else => false,
        },
        .controls => switch (variant) {
            .empty, .filled, .@"long-text", .disabled, .selected, .@"error" => true,
            else => false,
        },
        .@"selection-card" => switch (variant) {
            .@"long-text", .disabled, .selected => true,
            else => false,
        },
    };
}

pub const FileData = struct {
    path: []const u8,
    received: u64 = 0,
    total: ?u64 = null,
    speed: f64 = 0,
    state: tasks.FileState = .downloading,
};
/// Data is read-only and borrowed for Context's lifetime. The entry owns parsed JSON.
pub const Data = struct {
    name: ?[]const u8 = null,
    username: ?[]const u8 = null,
    uuid: ?[]const u8 = null,
    title: ?[]const u8 = null,
    message: ?[]const u8 = null,
    description: ?[]const u8 = null,
    completed: ?u64 = null,
    total: ?u64 = null,
    received: ?u64 = null,
    total_bytes: ?u64 = null,
    speed: ?f64 = null,
    files: ?[]const FileData = null,
};

pub const Event = enum { none, cancel, submit, microsoft_login, delete, sign_out, close, retry, changed, selected };
const long_name = "一个用于检查中文长名称换行与布局的 Minecraft 生存整合包实例名称";
const long_message = "这是用于直接核对弹窗长文本的 mock 内容。文字需要在当前窗口内自然换行，保留正确的行距、内边距和底部按钮区域。组件内容可以独立修改，无需先启动游戏、请求网络或等待真实任务失败。";

pub const Context = struct {
    allocator: std.mem.Allocator,
    scene: Scene,
    variant: Variant,
    data: Data,
    account_ui: accounts.Ui,
    instance_ui: instances.Ui,
    account_rows: [1]config.Account,
    name_buffer: [255]u8 = @splat(0),
    check: bool = false,
    choice: usize = 0,
    selected: bool = false,
    event_count: u64 = 0,
    last_event: Event = .none,

    pub fn init(a: std.mem.Allocator, scene: Scene, variant: Variant, data: Data) !Context {
        if (!supports(scene, variant)) return error.UnsupportedPreviewState;
        const name = data.name orelse if (variant == .@"long-text") long_name else "晨光生存 · Minecraft 1.21.4";
        if (!std.unicode.utf8ValidateSlice(name) or name.len > 200) return error.InvalidMockName;
        if (data.speed) |speed| if (!std.math.isFinite(speed) or speed < 0) return error.InvalidMockSpeed;
        var self: Context = .{
            .allocator = a,
            .scene = scene,
            .variant = variant,
            .data = data,
            .account_ui = try accounts.Ui.init(a),
            .instance_ui = instances.Ui.init(a),
            .account_rows = .{.{ .id = "mock-account", .name = data.username orelse if (variant == .@"long-text" and scene != .@"account-add") long_name else "VelaPlayer", .uuid = data.uuid orelse "01234567-89ab-cdef-0123-456789abcdef", .kind = if (scene == .@"account-microsoft" or scene == .@"account-signout") .microsoft else .offline }},
            .selected = variant == .selected,
            .check = variant == .selected,
        };
        errdefer self.deinit();
        const username = data.username orelse switch (variant) {
            .empty => "",
            .@"long-text" => "a-long-address-for-layout-verification@example.invalid",
            .filled => "VelaPlayer",
            else => "",
        };
        try putText(&self.account_ui.draft.name, username);
        try putText(&self.name_buffer, data.name orelse if (variant == .empty) "" else name);
        switch (scene) {
            .@"account-add" => self.account_ui.editor_open = true,
            .@"account-offline", .@"account-microsoft" => {
                self.account_ui.editor_open = true;
                self.account_ui.draft.id = try a.dupe(u8, "mock-account");
                if (data.username == null) try putText(&self.account_ui.draft.name, self.account_rows[0].name);
            },
            .@"account-delete", .@"account-signout" => self.account_ui.confirmation = .{ .id = try a.dupe(u8, "mock-account"), .sign_out = scene == .@"account-signout" },
            .@"instance-delete" => {
                self.instance_ui.mode = .delete_confirm;
                self.instance_ui.delete_confirmation_locked = variant == .disabled;
                try putText(&self.instance_ui.draft.original_name, name);
            },
            .@"account-code", .@"account-wait" => {
                self.account_ui.login_open = true;
                self.account_ui.verification_open = scene == .@"account-wait";
            },
            .@"instance-unsaved" => self.instance_ui.navigation_prompt = true,
            .@"instance-task" => try self.seedTask(name),
            else => {},
        }
        if (variant == .@"error") {
            self.account_ui.failure = error.InvalidAccountName;
            self.instance_ui.failure = error.InstanceBusy;
        }
        return self;
    }

    pub fn deinit(self: *Context) void {
        self.account_ui.deinit();
        self.instance_ui.deinit();
    }

    fn seedTask(self: *Context, name: []const u8) !void {
        const variant = self.variant;
        self.instance_ui.task = .{
            .visible = true,
            .task_id = 1,
            .operation = .creating,
            .phase = if (variant == .complete) .complete else if (variant == .failed) .failed else .working,
            .instance_name = try self.allocator.dupe(u8, name),
            .failure = if (variant == .failed) error.SizeMismatch else null,
        };
        self.instance_ui.task_can_cancel = variant != .disabled;
        const data = self.data;
        var details: tasks.Details = .{
            .stage = if (variant == .verifying or variant == .failed) .verifying else if (variant == .complete) .finalizing else .downloading,
            .completed = data.completed orelse if (variant == .complete) 5216 else 5002,
            .total = if (variant == .@"unknown-total") null else data.total orelse 5216,
            .received = data.received orelse 583 * 1024,
            .total_bytes = if (variant == .@"unknown-total") null else data.total_bytes orelse 583 * 1024,
            .bytes_per_second = data.speed orelse if (variant == .complete or variant == .failed or variant == .verifying) 0 else 1.5 * 1024 * 1024,
        };
        if (data.files) |files| {
            for (files) |file| {
                if (!std.math.isFinite(file.speed) or file.speed < 0) return error.InvalidMockSpeed;
                details.addFile(tasks.File.init(file.path, file.received, file.total, file.speed, file.state, null));
            }
        } else if (variant != .@"no-files") {
            const path = if (variant == .@"long-text") "libraries/very-long-library-file-name-for-layout-review-with-a-lot-of-details-and-version-1.21.4.jar" else "assets/34.json";
            details.addFile(tasks.File.init(path, 583 * 1024, 583 * 1024, 0, .complete, null));
            details.addFile(tasks.File.init("libraries/minecraft-client-1.21.4.jar", 10 * 1024 * 1024, 64 * 1024 * 1024, details.bytes_per_second, if (variant == .failed) .failed else if (variant == .complete) .complete else .downloading, if (variant == .failed) error.SizeMismatch else null));
        }
        if (variant == .complete) {
            details.completed = details.total orelse details.completed;
            for (details.files[0..details.file_count]) |*file| {
                file.received = file.total orelse file.received;
                file.state = .complete;
            }
        }
        if (self.instance_ui.task.phase != .working) details.stop();
        self.instance_ui.task.details = details;
    }

    pub fn record(self: *Context, event: Event) void {
        if (event == .none) return;
        self.last_event = event;
        self.event_count += 1;
    }

    // Mock auth metadata exists only in this independent, service-free gallery.
    fn accountSnapshot(self: *const Context) @import("accounts_manager.zig").Snapshot {
        var snapshot: @import("accounts_manager.zig").Snapshot = .{ .phase = .idle, .busy = self.variant == .loading or self.variant == .disabled, .failure = null, .device = null, .cleanup_count = 0, .publication_pending = false, .remember_available = false };
        if (self.scene == .@"account-code" or self.scene == .@"account-wait") {
            var device: @import("accounts_manager.zig").DeviceSnapshot = .{ .expires_at_ms = 900_000, .next_poll_ms = 5_000 };
            const code = "ABCD-EFGH";
            const uri = "https://www.microsoft.com/link";
            @memcpy(device.code[0..code.len], code);
            device.code_len = code.len;
            @memcpy(device.uri[0..uri.len], uri);
            device.uri_len = uri.len;
            snapshot.device = device;
            snapshot.phase = .device_pending;
        }
        return snapshot;
    }

    /// Consume intent and free queued payloads. Never call business finish/apply.
    pub fn consumeIntents(self: *Context) void {
        if (self.account_ui.pending) |pending| {
            self.record(switch (pending.action) {
                .save => .submit,
                .confirm => if (self.account_ui.confirmation) |confirmation| if (confirmation.sign_out) .sign_out else .delete else .submit,
                .start => .microsoft_login,
                .ask_delete => .delete,
                .ask_sign_out => .sign_out,
                .close_editor, .close_confirm, .close_login => .cancel,
                else => .changed,
            });
            if (pending.id) |id| self.allocator.free(id);
            if (pending.text) |text| self.allocator.free(text);
            self.account_ui.pending = null;
        }
        if (self.instance_ui.pending) |pending| {
            self.record(switch (pending.action) {
                .confirm => .delete,
                .cancel => .cancel,
                .close_task => .close,
                .retry_publication => .retry,
                else => .changed,
            });
            if (pending.text) |text| self.allocator.free(text);
            self.instance_ui.pending = null;
        }
    }

    pub fn draw(self: *Context) void {
        if (self.scene != .controls and self.scene != .@"selection-card") {
            const background = dvui.box(@src(), .{}, .{ .expand = .both, .color_fill = .{ .color = theme.background }, .padding = .all(24), .margin = .all(0), .background = true });
            background.deinit();
        }
        switch (self.scene) {
            .@"account-add", .@"account-offline", .@"account-microsoft", .@"account-delete", .@"account-signout", .@"account-code", .@"account-wait" => {
                const doc: config.Document = .{ .accounts = &self.account_rows, .selected_account = "mock-account" };
                accounts.drawDialogs(&self.account_ui, &doc, self.accountSnapshot(), 0);
            },
            .@"instance-delete", .@"instance-unsaved", .@"instance-task" => instances.drawModal(&self.instance_ui, self.variant != .disabled),
            .dialog => self.drawDialog(),
            .controls => self.drawControls(),
            .@"selection-card" => self.drawCard(),
        }
        self.consumeIntents();
    }

    fn drawDialog(self: *Context) void {
        const modal = components.modal(@src(), self.data.title orelse "确认操作", 360);
        defer modal.deinit();
        switch (components.modalFormActions(@src(), .{ .save_label = "确认", .save_enabled = self.variant != .disabled })) {
            .save => self.record(.submit),
            .cancel => self.record(.cancel),
            .none => {},
        }
        const body = components.scrollBody(@src());
        defer body.deinit();
        components.text(@src(), self.data.message orelse if (self.variant == .@"long-text") long_message else "这里直接显示 mock 内容，可用于核对弹窗文字、间距和操作区域。", if (self.variant == .@"error") theme.danger else theme.foreground);
    }

    fn drawControls(self: *Context) void {
        const body = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .all(24), .background = true, .color_fill = .{ .color = theme.background } });
        defer body.deinit();
        const scroll = components.scrollBody(@src());
        defer scroll.deinit();
        const panel = components.formPanel(@src(), .{});
        defer panel.deinit();
        const enabled = self.variant != .disabled;
        if (components.field(@src(), "实例名称", &self.name_buffer, .{ .enabled = enabled, .tag = "mock-name" })) self.record(.changed);
        const choices = [_][]const u8{ "自动选择 Java", "Java 21 · 本机运行时", "Java 17 · 启动器运行时" };
        if (enabled) {
            if (components.dropdown(@src(), "Java", &choices, .{ .choice = &self.choice }, .{})) self.record(.changed);
        } else {
            _ = components.button(@src(), choices[self.choice], .{ .enabled = false, .expand = true });
        }
        if (components.checkbox(@src(), &self.check, "调试启动", enabled)) self.record(.changed);
        if (components.toggle(@src(), &self.selected, "启用开关", enabled)) self.record(.changed);
        if (self.variant == .@"error") components.text(@src(), self.data.message orelse "输入内容无效，请检查名称与内存设置。", theme.danger);
        const actions = components.toolbar(@src());
        defer actions.deinit();
        if (components.button(@src(), "保存", .{ .primary = true, .enabled = enabled, .tag = "mock-save" })) self.record(.submit);
        if (components.button(@src(), "取消", .{ .tag = "mock-cancel" })) self.record(.cancel);
    }

    fn drawCard(self: *Context) void {
        const body = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .all(24), .background = true, .color_fill = .{ .color = theme.background } });
        defer body.deinit();
        if (components.selectionCard(@src(), "mock-card", self.data.name orelse if (self.variant == .@"long-text") long_name else "晨光生存", .{ .width = 440, .height = 136, .selected = self.selected, .enabled = self.variant != .disabled, .description = self.data.description orelse "Minecraft 1.21.4 · Fabric", .signal = .good, .status = "0/20 · 42 ms", .tag = "mock-card" })) {
            self.selected = !self.selected;
            self.record(.selected);
        }
    }
};

fn putText(buffer: []u8, value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value) or value.len >= buffer.len or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidMockText;
    @memset(buffer, 0);
    @memcpy(buffer[0..value.len], value);
}

test "component preview task states do not need a real task or manager" {
    const a = std.testing.allocator;
    for ([_]Variant{ .downloading, .@"unknown-total", .verifying, .complete, .failed, .@"no-files" }) |variant| {
        var context = try Context.init(a, .@"instance-task", variant, .{});
        defer context.deinit();
        try std.testing.expect(context.instance_ui.task.visible);
        if (variant == .@"unknown-total") try std.testing.expect(context.instance_ui.task.details.total == null);
        if (variant == .complete) try std.testing.expectEqual(@as(f64, 0), context.instance_ui.task.details.bytes_per_second);
        if (variant == .@"no-files") try std.testing.expectEqual(@as(usize, 0), context.instance_ui.task.details.file_count);
    }
}

test "component preview consumes destructive and login intents without executing business" {
    const a = std.testing.allocator;
    var context = try Context.init(a, .@"instance-delete", .default, .{ .name = "Keep this instance" });
    defer context.deinit();
    context.instance_ui.queue(.confirm, null);
    context.consumeIntents();
    try std.testing.expectEqual(Event.delete, context.last_event);
    try std.testing.expect(context.instance_ui.pending == null);
    try std.testing.expectEqualStrings("Keep this instance", std.mem.sliceTo(&context.instance_ui.draft.original_name, 0));
    context.account_ui.pending = .{ .action = .start, .text = try a.dupe(u8, "preview@example.invalid") };
    context.consumeIntents();
    try std.testing.expectEqual(Event.microsoft_login, context.last_event);
    try std.testing.expectEqual(@as(u64, 2), context.event_count);
    try std.testing.expect(context.account_ui.pending == null);
}

test "component preview account long text and confirmations use injected metadata" {
    for ([_]Scene{ .@"account-offline", .@"account-microsoft", .@"account-delete", .@"account-signout" }) |scene| {
        var context = try Context.init(std.testing.allocator, scene, .@"long-text", .{});
        defer context.deinit();
        try std.testing.expectEqualStrings(long_name, context.account_rows[0].name);
        if (scene == .@"account-offline" or scene == .@"account-microsoft") {
            try std.testing.expectEqualStrings(long_name, std.mem.sliceTo(&context.account_ui.draft.name, 0));
        } else {
            context.account_ui.pending = .{ .action = .confirm, .id = try std.testing.allocator.dupe(u8, "mock-account") };
            context.consumeIntents();
            try std.testing.expectEqual(if (scene == .@"account-signout") Event.sign_out else Event.delete, context.last_event);
            try std.testing.expect(context.account_ui.pending == null);
            try std.testing.expect(context.account_ui.confirmation != null);
            try std.testing.expectEqualStrings(long_name, context.account_rows[0].name);
        }
    }
}

test "component preview rejects incompatible states and invalid custom data" {
    try std.testing.expectError(error.UnsupportedPreviewState, Context.init(std.testing.allocator, .@"instance-delete", .downloading, .{}));
    try std.testing.expectError(error.InvalidMockName, Context.init(std.testing.allocator, .dialog, .default, .{ .name = &(@as([201]u8, @splat('x'))) }));
    try std.testing.expectError(error.InvalidMockSpeed, Context.init(std.testing.allocator, .@"instance-task", .default, .{ .speed = std.math.nan(f64) }));
    var context = try Context.init(std.testing.allocator, .@"account-add", .filled, .{ .username = "MockOnly" });
    defer context.deinit();
    try std.testing.expectEqualStrings("MockOnly", std.mem.sliceTo(&context.account_ui.draft.name, 0));
}

test "component preview device scenes inject mock snapshots and consume browser intent without services" {
    for ([_]Scene{ .@"account-code", .@"account-wait" }) |scene| {
        var context = try Context.init(std.testing.allocator, scene, .default, .{});
        defer context.deinit();
        const snapshot = context.accountSnapshot();
        try std.testing.expectEqualStrings("ABCD-EFGH", snapshot.device.?.userCode());
        try std.testing.expectEqualStrings("https://www.microsoft.com/link", snapshot.device.?.verificationUri());
        try std.testing.expect(context.account_ui.login_open);
        try std.testing.expectEqual(scene == .@"account-wait", context.account_ui.verification_open);
        context.account_ui.pending = .{ .action = .open_verification };
        context.consumeIntents();
        try std.testing.expect(context.account_ui.pending == null);
        try std.testing.expectEqual(@as(u64, 1), context.event_count);
    }
}
