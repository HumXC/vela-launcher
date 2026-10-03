const std = @import("std");
const dvui = @import("dvui");
const builtin = @import("builtin");
const config = @import("../core/config.zig");
const theme = @import("theme.zig");
const credentials = @import("../core/credentials.zig");
const credential_controller = @import("curseforge_credentials_controller.zig");
const masked_key = @import("curseforge_key_editor.zig");
const R = dvui.Rect;

const Command = enum { save, cancel };
pub const KeyCommand = enum { save_key, remove_key, recover_key };
const KeyRequest = struct {
    command: KeyCommand,
    policy: credential_controller.Policy,
    secret: ?credentials.Secret = null,

    fn deinit(self: *KeyRequest) void {
        if (self.secret) |*secret| secret.deinit();
        self.secret = null;
    }
};

/// Owns the editable draft, including all strings; no Store snapshot is retained.
pub const Ui = struct {
    a: std.mem.Allocator,
    memory_buffer: [24]u8 = @splat(0),
    connections_buffer: [24]u8 = @splat(0),
    client_id: std.ArrayList(u8) = .empty,
    game_exit_behavior: config.GameExitBehavior,
    curseforge_enabled: bool,
    curseforge_terms_approved: bool,
    pending: ?Command = null,
    failure: ?anyerror = null,
    saved: bool = false,
    key_editor: masked_key.Editor = .{},
    key_pending: ?KeyRequest = null,
    key_failure: ?anyerror = null,
    confirm_remove: bool = false,

    pub fn init(a: std.mem.Allocator, initial_settings: config.Settings) !Ui {
        var self: Ui = .{ .a = a, .game_exit_behavior = initial_settings.game_exit_behavior, .curseforge_enabled = initial_settings.curseforge_enabled, .curseforge_terms_approved = initial_settings.curseforge_terms_approved };
        errdefer self.client_id.deinit(a);
        try self.client_id.appendSlice(a, initial_settings.microsoft_client_id);
        _ = try std.fmt.bufPrint(&self.memory_buffer, "{d}", .{initial_settings.default_memory_mb});
        _ = try std.fmt.bufPrint(&self.connections_buffer, "{d}", .{initial_settings.download_connections});
        return self;
    }

    pub fn deinit(self: *Ui) void {
        self.clearKey();
        self.client_id.deinit(self.a);
        self.client_id = .empty;
        self.pending = null;
        self.failure = null;
        self.saved = false;
    }

    pub fn clearKey(self: *Ui) void {
        self.key_editor.reset();
        if (self.key_pending) |*request| request.deinit();
        self.key_pending = null;
        self.key_failure = null;
        self.confirm_remove = false;
    }

    pub fn requestKey(self: *Ui, command: KeyCommand, snapshot: credential_controller.Snapshot, content_busy: bool, store_uncertain: bool) !void {
        self.saved = false;
        errdefer self.clearKey();
        var owned: ?credentials.Secret = null;
        defer if (owned) |*secret| secret.deinit();
        if (command == .save_key) {
            const borrowed = try self.key_editor.borrowForSave();
            const bytes = try self.a.dupe(u8, borrowed);
            owned = .{ .allocator = self.a, .bytes = bytes };
        }
        self.key_editor.reset();
        if (self.key_pending != null) return error.Busy;
        try requireKeyCommand(command, snapshot, content_busy, store_uncertain);
        if (command == .remove_key and !self.confirm_remove) return error.ConfirmationRequired;
        self.key_pending = .{ .command = command, .policy = .{ .enabled = command == .save_key and self.curseforge_enabled, .terms_approved = self.curseforge_terms_approved }, .secret = owned };
        owned = null;
        self.confirm_remove = false;
        self.key_failure = null;
    }

    fn edited(self: *Ui) void {
        self.saved = false;
        self.failure = null;
    }

    fn settings(self: *const Ui) !config.Settings {
        const memory_text = std.mem.trim(u8, std.mem.sliceTo(&self.memory_buffer, 0), " ");
        const connections_text = std.mem.trim(u8, std.mem.sliceTo(&self.connections_buffer, 0), " ");
        const memory = std.fmt.parseInt(u32, memory_text, 10) catch return error.InvalidMemory;
        if (memory < 256 or memory > 1024 * 1024) return error.InvalidMemory;
        const connections = std.fmt.parseInt(u16, connections_text, 10) catch return error.InvalidDownloadConnections;
        if (connections == 0 or connections > 64) return error.InvalidDownloadConnections;
        const client_id = self.client_id.items;
        if (client_id.len > 4096 or !std.unicode.utf8ValidateSlice(client_id)) return error.InvalidClientId;
        var it = std.unicode.Utf8View.initUnchecked(client_id).iterator();
        while (it.nextCodepoint()) |cp| if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.InvalidClientId;
        return .{ .default_memory_mb = memory, .download_connections = connections, .microsoft_client_id = client_id, .game_exit_behavior = self.game_exit_behavior, .curseforge_enabled = self.curseforge_enabled, .curseforge_terms_approved = self.curseforge_terms_approved };
    }
};

fn fieldLabel(src: std.builtin.SourceLocation, text: []const u8) void {
    dvui.labelNoFmt(src, text, .{}, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = 6 } });
}

fn numericEntry(src: std.builtin.SourceLocation, name: []const u8, buffer: []u8) bool {
    const height = dvui.themeGet().font_body.textHeight();
    const entry = dvui.textEntry(src, .{ .text = .{ .buffer = buffer } }, .{ .tag = name, .label = .{ .text = name }, .expand = .horizontal, .min_size_content = .{ .h = height }, .max_size_content = .{ .w = 240, .h = height }, .padding = R.all(8), .margin = .{ .h = 16 }, .corners = .all(4) });
    if (@import("builtin").is_test) {
        const border_tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}-border", .{name}) catch name;
        dvui.tag(border_tag, .{ .id = entry.data().id, .rect = entry.data().borderRectScale().r, .visible = entry.data().visible() });
        const caret_tag = std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}-caret", .{name}) catch name;
        dvui.tag(caret_tag, .{ .id = entry.textLayout.data().id, .rect = entry.textLayout.screenRectScale(entry.textLayout.cursor_rect).r, .visible = entry.data().visible() });
    }
    const changed = entry.text_changed;
    entry.deinit();
    return changed;
}

fn failureText(failure: anyerror) []const u8 {
    return switch (failure) {
        error.InvalidMemory => "内存必须为 256 至 1048576 MiB 的整数",
        error.InvalidDownloadConnections => "下载连接数必须为 1 至 64 的整数",
        error.InvalidClientId => "Microsoft 客户端 ID 含无效字符或超过 4096 字节",
        else => "保存失败",
    };
}

fn segment(src: std.builtin.SourceLocation, label: []const u8, selected: bool) bool {
    return dvui.button(src, label, .{}, .{ .label = .{ .text = label }, .style = if (selected) .highlight else .control, .expand = .horizontal, .min_size_content = .{ .h = 20 }, .padding = R.all(8), .margin = R.all(0), .border = R.all(1), .corners = .all(4) });
}

fn requireKeyCommand(command: KeyCommand, snapshot: credential_controller.Snapshot, content_busy: bool, store_uncertain: bool) !void {
    if (content_busy or snapshot.worker_active) return error.Busy;
    // A joined recovery job may start while a retained publication freezes the lease.
    if (command == .recover_key) {
        if (!snapshot.recovery_required and !snapshot.cleanup_pending and !snapshot.commit_uncertain and !snapshot.publication_pending and !store_uncertain) return error.NoRecoveryRequired;
        return;
    }
    if (snapshot.publication_pending) return error.Busy;
    if (store_uncertain or snapshot.commit_uncertain) return error.PublicationUncertain;
    if (snapshot.recovery_required or snapshot.cleanup_pending) return error.RecoveryRequired;
    if (snapshot.busy) return error.Busy;
}

fn keyAllowed(command: KeyCommand, snapshot: credential_controller.Snapshot, content_busy: bool, store_uncertain: bool) bool {
    requireKeyCommand(command, snapshot, content_busy, store_uncertain) catch return false;
    return true;
}

fn policyCheckbox(src: std.builtin.SourceLocation, value: *bool, label: []const u8, enabled: bool) bool {
    const opts = dvui.checkbox_defaults.override(.{ .padding = R.all(0), .margin = .{ .h = 16 } });
    if (enabled) return dvui.checkbox(src, value, label, opts);
    const row = dvui.box(src, .{ .dir = .horizontal }, opts.override(.{ .expand = .horizontal, .color_text = .{ .color = theme.muted } }));
    defer row.deinit();
    const size = opts.fontGet().textHeight();
    const mark = dvui.spacer(@src(), .{ .min_size_content = dvui.Size.all(size), .gravity_y = 0.5 });
    dvui.checkmark(value.*, false, mark.borderRectScale(), false, 0, opts);
    dvui.labelNoFmt(@src(), label, .{}, .{ .color_text = .{ .color = theme.muted }, .gravity_y = 0.5, .padding = .{ .x = 6 } });
    return false;
}

fn keyIcon(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, enabled: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, .{ .label = .{ .text = name }, .min_size_content = .{ .w = 18, .h = 18 }, .max_size_content = .{ .w = 18, .h = 18 }, .padding = R.all(8), .margin = .{ .x = 4 }, .corners = .all(4) });
    if (enabled) button.processEvents() else button.processHover();
    button.drawBackground();
    dvui.icon(@src(), name, asset, .{}, button.style().override(.{ .padding = R.all(0), .margin = R.all(0), .min_size_content = .{ .w = 18, .h = 18 }, .max_size_content = .{ .w = 18, .h = 18 }, .role = .none }));
    button.drawFocus();
    const clicked = enabled and button.clicked();
    const hovered = button.hovered();
    const rect = button.data().rectScale().r;
    button.deinit();
    if (hovered) dvui.tooltip(src, .{ .active_rect = rect }, "{s}", .{name}, .{ .id_extra = 1 });
    return clicked;
}

fn keyStatus(src: std.builtin.SourceLocation, value: []const u8, warning: bool) void {
    const message = dvui.textLayout(src, .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = 6 }, .color_text = .{ .color = if (warning) dvui.Color.fromHex("F0A6A1") else theme.muted } });
    message.addText(value, .{});
    message.deinit();
}

fn drawCredentials(ui: *Ui, snapshot: credential_controller.Snapshot, settings: config.Settings, content_busy: bool, store_uncertain: bool) void {
    const configured = settings.curseforge_credential_ref != null;
    if (!configured) ui.confirm_remove = false;
    fieldLabel(@src(), "CurseForge API 密钥");
    keyStatus(@src(), if (configured) "已配置" else "未配置", false);
    const height = (dvui.Options{}).fontGet().sizeM(0, 1).h;
    const result = ui.key_editor.draw(@src(), .{ .expand = .horizontal, .min_size_content = .{ .h = height }, .max_size_content = .height(height), .padding = R.all(8), .margin = .{ .h = 8 }, .corners = .all(4) });
    if (result.edited) ui.key_failure = null;
    if (result.cancel) ui.clearKey();
    if (result.submit) ui.requestKey(.save_key, snapshot, content_busy, store_uncertain) catch |err| {
        ui.key_failure = err;
    };
    switch (result.status) {
        .invalid_input => keyStatus(@src(), "密钥含无效字符", true),
        .too_long => keyStatus(@src(), "密钥超过 512 字节", true),
        else => {},
    }
    {
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = 8 } });
        defer actions.deinit();
        const save_allowed = ui.key_pending == null and keyAllowed(.save_key, snapshot, content_busy, store_uncertain);
        const remove_allowed = configured and ui.key_pending == null and keyAllowed(.remove_key, snapshot, content_busy, store_uncertain);
        if (keyIcon(@src(), "保存 API 密钥", dvui.entypo.save, save_allowed and ui.key_editor.readyForSave())) ui.requestKey(.save_key, snapshot, content_busy, store_uncertain) catch |err| {
            ui.key_failure = err;
        };
        if (keyIcon(@src(), "移除 API 密钥", dvui.entypo.trash, remove_allowed)) {
            ui.clearKey();
            ui.confirm_remove = true;
        }
        if (keyIcon(@src(), "恢复凭据状态", dvui.entypo.cw, ui.key_pending == null and keyAllowed(.recover_key, snapshot, content_busy, store_uncertain))) ui.requestKey(.recover_key, snapshot, content_busy, store_uncertain) catch |err| {
            ui.key_failure = err;
        };
    }
    if (ui.confirm_remove) {
        keyStatus(@src(), "确认移除 CurseForge API 密钥？", true);
        const confirmation = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = 8 } });
        defer confirmation.deinit();
        if (keyIcon(@src(), "确认移除 API 密钥", dvui.entypo.check, configured and ui.key_pending == null and keyAllowed(.remove_key, snapshot, content_busy, store_uncertain))) ui.requestKey(.remove_key, snapshot, content_busy, store_uncertain) catch |err| {
            ui.key_failure = err;
        };
        if (keyIcon(@src(), "取消移除", dvui.entypo.cross, true)) ui.clearKey();
    }
    if (store_uncertain or snapshot.commit_uncertain) {
        keyStatus(@src(), "配置持久化状态待确认", true);
    } else if (snapshot.cleanup_pending) {
        keyStatus(@src(), "凭据变更已保存，清理尚未完成", true);
    } else if (snapshot.recovery_required) {
        keyStatus(@src(), "凭据状态需要恢复", true);
    } else if (snapshot.publication_pending) {
        keyStatus(@src(), "正在保存凭据配置", false);
    } else if (snapshot.busy) {
        keyStatus(@src(), "正在处理凭据", false);
    } else if (snapshot.committed) {
        keyStatus(@src(), if (configured) "密钥配置已保存" else "密钥已移除", false);
    }
    const failure: ?anyerror = if (ui.key_failure) |err| err else snapshot.failure;
    if (failure) |err| {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "凭据操作失败（{s}）", .{@errorName(err)}) catch "凭据操作失败";
        keyStatus(@src(), message, true);
    }
}

/// Draw queues commands; call finish only after all parent/page widgets close.
pub fn draw(ui: *Ui) !void {
    try drawPage(ui, null, .{}, false, false, null);
}

pub fn drawWithCredentials(ui: *Ui, controller: *credential_controller.Controller, settings: config.Settings, content_busy: bool, store_uncertain: bool) !void {
    try drawPage(ui, controller, settings, content_busy, store_uncertain, null);
}

pub fn drawUnavailable(ui: *Ui, settings: config.Settings, failure: anyerror) !void {
    ui.clearKey();
    ui.curseforge_enabled = settings.curseforge_enabled;
    ui.curseforge_terms_approved = settings.curseforge_terms_approved;
    try drawPage(ui, null, settings, false, false, failure);
}

fn drawPage(ui: *Ui, controller: ?*credential_controller.Controller, settings: config.Settings, content_busy: bool, store_uncertain: bool, credential_failure: ?anyerror) !void {
    const page = dvui.box(@src(), .{}, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer page.deinit();
    dvui.labelNoFmt(@src(), "设置", .{}, .{ .font = dvui.themeGet().font_title, .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = 16 } });
    {
        const footer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 1, .min_size_content = .{ .h = 36 }, .padding = .{ .y = 8 }, .margin = R.all(0) });
        defer footer.deinit();
        if (dvui.buttonLabelAndIcon(@src(), .{ .label = "保存", .tvg_bytes = dvui.entypo.save, .icon_first = true, .icon_label = "保存" }, .{ .style = .highlight, .min_size_content = .{ .h = 20 }, .padding = R.all(8), .margin = .{ .w = 8 }, .corners = .all(4) })) ui.pending = .save;
        if (dvui.button(@src(), "取消", .{}, .{ .min_size_content = .{ .h = 20 }, .padding = R.all(8), .margin = R.all(0), .corners = .all(4) })) ui.pending = .cancel;
    }
    {
        const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .border = R.all(0), .padding = R.all(0), .margin = R.all(0) });
        defer scroll.deinit();
        fieldLabel(@src(), "默认游戏内存（MiB）");
        if (numericEntry(@src(), "默认游戏内存", &ui.memory_buffer)) ui.edited();
        fieldLabel(@src(), "下载连接数");
        if (numericEntry(@src(), "下载连接数", &ui.connections_buffer)) ui.edited();
        fieldLabel(@src(), "游戏结束后");
        {
            const modes = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .max_size_content = .width(360), .padding = R.all(0), .margin = .{ .h = 16 } });
            defer modes.deinit();
            if (segment(@src(), "显示启动器", ui.game_exit_behavior == .restore_launcher)) {
                ui.game_exit_behavior = .restore_launcher;
                ui.edited();
            }
            if (segment(@src(), "退出启动器", ui.game_exit_behavior == .exit_launcher)) {
                ui.game_exit_behavior = .exit_launcher;
                ui.edited();
            }
        }
        fieldLabel(@src(), "Microsoft 客户端 ID");
        {
            const height = dvui.themeGet().font_body.textHeight();
            const entry = dvui.textEntry(@src(), .{ .text = .{ .array_list = .{ .backing = &ui.client_id, .allocator = ui.a, .limit = 4096 } } }, .{ .label = .{ .text = "Microsoft 客户端 ID" }, .expand = .horizontal, .min_size_content = .{ .h = height }, .max_size_content = .height(height), .padding = R.all(8), .margin = .{ .h = 16 }, .corners = .all(4) });
            if (entry.text_changed) ui.edited();
            entry.deinit();
        }
        const policy_enabled = credential_failure == null and (if (controller) |active| !active.lease() and !content_busy else true);
        if (policyCheckbox(@src(), &ui.curseforge_enabled, "CurseForge", policy_enabled)) ui.edited();
        if (policyCheckbox(@src(), &ui.curseforge_terms_approved, "已确认 CurseForge 接入条款", policy_enabled)) ui.edited();
        if (controller) |active| drawCredentials(ui, active.snapshot(), settings, content_busy, store_uncertain);
        if (credential_failure) |err| {
            fieldLabel(@src(), "CurseForge API 密钥");
            var buffer: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "密钥不可用（{s}）", .{@errorName(err)}) catch "密钥不可用";
            keyStatus(@src(), message, true);
        }
        if (ui.failure) |failure| {
            const text = try std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}（{s}）", .{ failureText(failure), @errorName(failure) });
            const message = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0), .color_text = .{ .color = dvui.Color.fromHex("F0A6A1") } });
            message.addText(text, .{});
            message.deinit();
        } else if (ui.saved) {
            dvui.labelNoFmt(@src(), "已保存", .{}, .{ .expand = .horizontal, .color_text = .{ .color = theme.accent }, .padding = R.all(0), .margin = R.all(0) });
        }
    }
}

/// Store.update is deliberately outside draw: it invalidates borrowed snapshots.
/// Failure keeps the working copy for retry; Cancel atomically reloads the latest settings.
pub fn finish(ui: *Ui, store: *config.Store) void {
    if (ui.pending == .cancel) {
        finishSettings(ui, store, false);
        return;
    }
    const unavailable = ui.key_pending != null;
    if (unavailable) ui.clearKey();
    finishSettings(ui, store, false);
    if (unavailable) ui.key_failure = error.CredentialsUnavailable;
}

pub fn finishWithCredentials(ui: *Ui, store: *config.Store, controller: *credential_controller.Controller, content_busy: bool) void {
    const policy_locked = controller.lease() or content_busy;
    if (ui.pending == .cancel) {
        finishSettings(ui, store, policy_locked);
        return;
    }
    const conflicting = ui.pending != null and ui.key_pending != null;
    if (conflicting) ui.clearKey();
    finishSettings(ui, store, policy_locked);
    if (conflicting) {
        ui.key_failure = error.Busy;
        return;
    }
    var request = ui.key_pending orelse return;
    ui.key_pending = null;
    ui.key_editor.reset();
    ui.confirm_remove = false;
    defer request.deinit();
    requireKeyCommand(request.command, controller.snapshot(), content_busy, store.publicationUncertain()) catch |err| {
        ui.key_failure = err;
        return;
    };
    switch (request.command) {
        .save_key => if (request.secret) |*secret| {
            controller.startSet(store, secret, request.policy) catch |err| {
                ui.key_failure = err;
                return;
            };
        } else {
            ui.key_failure = error.InvalidKey;
            return;
        },
        .remove_key => controller.startRemove(store, request.policy) catch |err| {
            ui.key_failure = err;
            return;
        },
        .recover_key => controller.startRecovery(store) catch |err| {
            ui.key_failure = err;
            return;
        },
    }
    ui.key_failure = null;
}

pub fn finishUnavailable(ui: *Ui, store: *config.Store) void {
    ui.clearKey();
    finishSettings(ui, store, true);
}

fn finishSettings(ui: *Ui, store: *config.Store, preserve_cf_policy: bool) void {
    const command = ui.pending orelse return;
    ui.pending = null;
    ui.saved = false;
    switch (command) {
        .cancel => {
            ui.clearKey();
            const next = Ui.init(ui.a, store.snapshot().settings) catch |err| {
                ui.failure = err;
                return;
            };
            ui.deinit();
            ui.* = next;
        },
        .save => {
            const settings = ui.settings() catch |err| {
                ui.clearKey();
                ui.failure = err;
                return;
            };
            if (store.publicationUncertain()) store.reconcile() catch |err| {
                ui.clearKey();
                ui.failure = err;
                return;
            };
            // Merge only draft-owned fields into the reconciled/latest document.
            var document = store.snapshot().*;
            document.settings.default_memory_mb = settings.default_memory_mb;
            document.settings.download_connections = settings.download_connections;
            document.settings.game_exit_behavior = settings.game_exit_behavior;
            document.settings.microsoft_client_id = settings.microsoft_client_id;
            if (!preserve_cf_policy) {
                document.settings.curseforge_enabled = settings.curseforge_enabled;
                document.settings.curseforge_terms_approved = settings.curseforge_terms_approved;
            }
            store.update(document) catch |err| {
                ui.clearKey();
                ui.failure = err;
                return;
            };
            ui.failure = null;
            ui.saved = true;
        },
    }
}

fn setNumber(buffer: []u8, text: []const u8) void {
    @memset(buffer, 0);
    @memcpy(buffer[0..text.len], text);
}

fn testRoot(tmp: *std.testing.TmpDir) ![]u8 {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    return std.testing.allocator.dupe(u8, path[0..len]);
}

test "settings draft owns strings and validates numeric boundaries" {
    var source = [_]u8{ 'p', 'u', 'b', 'l', 'i', 'c' };
    var ui = try Ui.init(std.testing.allocator, .{ .microsoft_client_id = &source });
    defer ui.deinit();
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("public", (try ui.settings()).microsoft_client_id);
    for ([_][]const u8{ "", "0", "255", "1048577", "-256", "4294967296", "abc", "1.5" }) |text| {
        setNumber(&ui.memory_buffer, text);
        try std.testing.expectError(error.InvalidMemory, ui.settings());
    }
    for ([_][]const u8{ "256", "1048576" }) |text| {
        setNumber(&ui.memory_buffer, text);
        _ = try ui.settings();
    }
    for ([_][]const u8{ "", "0", "65", "65536", "-1", "a" }) |text| {
        setNumber(&ui.connections_buffer, text);
        try std.testing.expectError(error.InvalidDownloadConnections, ui.settings());
    }
    for ([_][]const u8{ "1", "64" }) |text| {
        setNumber(&ui.connections_buffer, text);
        _ = try ui.settings();
    }
}

test "settings public identifier rejects controls and invalid UTF8 but permits an empty gate" {
    var ui = try Ui.init(std.testing.allocator, .{});
    defer ui.deinit();
    _ = try ui.settings();
    for ([_][]const u8{ "bad\n", "bad\x00", "\xff", "\xc2\x85" }) |text| {
        ui.client_id.clearRetainingCapacity();
        try ui.client_id.appendSlice(ui.a, text);
        try std.testing.expectError(error.InvalidClientId, ui.settings());
    }
    ui.client_id.clearRetainingCapacity();
    try ui.client_id.appendNTimes(ui.a, 'a', 4097);
    try std.testing.expectError(error.InvalidClientId, ui.settings());
    ui.client_id.items.len = 4096;
    _ = try ui.settings();
}

test "settings save and cancel are deferred and preserve unrelated current records" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var ui = try Ui.init(a, store.snapshot().settings);
    defer ui.deinit();
    setNumber(&ui.memory_buffer, "4096");
    ui.game_exit_behavior = .exit_launcher;
    ui.curseforge_enabled = true;
    try ui.client_id.appendSlice(a, "public-client");
    ui.pending = .save;
    try std.testing.expectEqual(@as(u32, 2048), store.snapshot().settings.default_memory_mb);
    try store.update(.{ .instances = &.{.{ .id = "instance", .name = "instance", .minecraft_version = "1.21" }}, .selected_instance = "instance" });
    finish(&ui, &store);
    try std.testing.expect(ui.failure == null);
    try std.testing.expect(ui.saved);
    try std.testing.expect(ui.pending == null);
    try std.testing.expectEqual(@as(u32, 4096), store.snapshot().settings.default_memory_mb);
    try std.testing.expectEqual(config.GameExitBehavior.exit_launcher, store.snapshot().settings.game_exit_behavior);
    try std.testing.expect(store.snapshot().settings.curseforge_enabled);
    try std.testing.expectEqualStrings("public-client", store.snapshot().settings.microsoft_client_id);
    try std.testing.expectEqualStrings("instance", store.snapshot().selected_instance.?);
    ui.client_id.items[0] = 'X';
    try std.testing.expectEqualStrings("public-client", store.snapshot().settings.microsoft_client_id);
    setNumber(&ui.memory_buffer, "0");
    ui.pending = .save;
    finish(&ui, &store);
    try std.testing.expectEqual(error.InvalidMemory, ui.failure.?);
    try std.testing.expectEqualStrings("0", std.mem.sliceTo(&ui.memory_buffer, 0));
    try std.testing.expectEqual(@as(u32, 4096), store.snapshot().settings.default_memory_mb);
    ui.pending = .cancel;
    finish(&ui, &store);
    try std.testing.expect(ui.failure == null);
    try std.testing.expectEqual(@as(u32, 4096), (try ui.settings()).default_memory_mb);
    try std.testing.expectEqualStrings("public-client", ui.client_id.items);
    var reopened = try config.Store.init(a, std.testing.io, root);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u32, 4096), reopened.snapshot().settings.default_memory_mb);
}

test "settings disk failure retains draft and old store then permits retry" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, io, root);
    defer store.deinit();
    try store.update(.{});
    var ui = try Ui.init(a, store.snapshot().settings);
    defer ui.deinit();
    setNumber(&ui.memory_buffer, "8192");
    try ui.client_id.appendSlice(a, "draft-client");
    try tmp.dir.rename(".vela/config.json", tmp.dir, ".vela/previous.json", io);
    try tmp.dir.createDir(io, ".vela/config.json", .default_dir);
    ui.pending = .save;
    finish(&ui, &store);
    try std.testing.expect(ui.failure != null);
    try std.testing.expect(!ui.saved);
    try std.testing.expect(ui.pending == null);
    try std.testing.expectEqual(@as(u32, 2048), store.snapshot().settings.default_memory_mb);
    try std.testing.expectEqual(@as(u32, 8192), (try ui.settings()).default_memory_mb);
    try std.testing.expectEqualStrings("draft-client", ui.client_id.items);
    try tmp.dir.deleteDir(io, ".vela/config.json");
    ui.pending = .save;
    finish(&ui, &store);
    try std.testing.expectEqual(error.FileNotFound, ui.failure.?);
    try std.testing.expect(!ui.saved);
    try std.testing.expect(store.publicationUncertain());
    try std.testing.expectEqualStrings("draft-client", ui.client_id.items);
    try tmp.dir.rename(".vela/previous.json", tmp.dir, ".vela/config.json", io);
    ui.pending = .save;
    finish(&ui, &store);
    try std.testing.expect(ui.failure == null);
    try std.testing.expect(ui.saved);
    try std.testing.expectEqual(@as(u32, 8192), store.snapshot().settings.default_memory_mb);
}

test "settings init rolls back allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            var ui = try Ui.init(a, .{ .microsoft_client_id = "public-client" });
            defer ui.deinit();
        }
    }.run, .{});
}

test "settings public declarations are analyzed without GUI context" {
    std.testing.refAllDecls(@This());
}

// Only intercept sync; all IO and userdata remain the real tempfile backend.
const SettingsSyncFault = struct {
    threadlocal var active: ?*SettingsSyncFault = null;
    real: std.Io = std.testing.io,
    vtable: std.Io.VTable = undefined,
    syncs: usize = 0,
    fail_at: ?usize = null,

    fn start(self: *SettingsSyncFault) std.Io {
        std.debug.assert(active == null);
        active = self;
        self.vtable = self.real.vtable.*;
        self.vtable.fileSync = sync;
        return .{ .userdata = self.real.userdata, .vtable = &self.vtable };
    }

    fn stop(self: *SettingsSyncFault) void {
        std.debug.assert(active == self);
        active = null;
    }

    fn sync(ctx: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        const self = active.?;
        self.syncs += 1;
        if (self.fail_at == self.syncs) return error.InputOutput;
        return self.real.vtable.fileSync(ctx, file);
    }
};

test "settings explicit Save reconciles committed disk account references and Cancel never reconciles" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    try store.update(.{});
    var ui = try Ui.init(a, store.snapshot().settings);
    defer ui.deinit();
    var fault: SettingsSyncFault = .{};
    store.io = fault.start();
    defer fault.stop();
    fault.fail_at = 3;
    const reference = "0123456789abcdef0123456789abcdef";
    try std.testing.expectError(error.InputOutput, store.update(.{
        .accounts = &.{.{ .id = "disk-online", .name = "DiskPlayer", .uuid = "00112233445566778899aabbccddeeff", .kind = .microsoft, .credential_ref = reference }},
        .selected_account = "disk-online",
        .settings = .{ .curseforge_credential_ref = reference },
    }));
    try std.testing.expect(store.publicationUncertain());
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().accounts.len);
    const authoritative = try tmp.dir.readFileAlloc(std.testing.io, ".vela/config.json", a, .limited(1024 * 1024));
    defer a.free(authoritative);
    const syncs = fault.syncs;
    setNumber(&ui.memory_buffer, "invalid");
    ui.pending = .save;
    finish(&ui, &store);
    try std.testing.expectEqual(error.InvalidMemory, ui.failure.?);
    try std.testing.expectEqual(syncs, fault.syncs);
    try std.testing.expect(store.publicationUncertain());
    ui.pending = .cancel;
    finish(&ui, &store);
    try std.testing.expect(ui.failure == null);
    try std.testing.expect(!ui.saved);
    try std.testing.expectEqual(syncs, fault.syncs);
    try std.testing.expect(store.publicationUncertain());
    try std.testing.expectEqual(@as(u32, 2048), (try ui.settings()).default_memory_mb);
    const after_cancel = try tmp.dir.readFileAlloc(std.testing.io, ".vela/config.json", a, .limited(1024 * 1024));
    defer a.free(after_cancel);
    try std.testing.expectEqualStrings(authoritative, after_cancel);

    setNumber(&ui.memory_buffer, "8192");
    setNumber(&ui.connections_buffer, "9");
    ui.game_exit_behavior = .exit_launcher;
    ui.curseforge_enabled = true;
    ui.curseforge_terms_approved = true;
    try ui.client_id.appendSlice(a, "edited-public-client");
    fault.syncs = 0;
    fault.fail_at = 1;
    ui.pending = .save;
    finish(&ui, &store);
    try std.testing.expectEqual(error.InputOutput, ui.failure.?);
    try std.testing.expect(!ui.saved);
    try std.testing.expect(store.publicationUncertain());
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().accounts.len);
    try std.testing.expectEqualStrings("edited-public-client", ui.client_id.items);
    try std.testing.expectEqual(@as(u32, 8192), (try ui.settings()).default_memory_mb);
    fault.fail_at = null;
    ui.pending = .save;
    finish(&ui, &store);
    try std.testing.expect(ui.failure == null);
    try std.testing.expect(ui.saved);
    try std.testing.expect(!store.publicationUncertain());
    const latest = store.snapshot();
    try std.testing.expectEqual(@as(usize, 1), latest.accounts.len);
    try std.testing.expectEqualStrings("disk-online", latest.selected_account.?);
    try std.testing.expectEqualStrings(reference, latest.accounts[0].credential_ref.?);
    try std.testing.expectEqual(@as(u32, 8192), latest.settings.default_memory_mb);
    try std.testing.expectEqual(@as(u16, 9), latest.settings.download_connections);
    try std.testing.expectEqual(config.GameExitBehavior.exit_launcher, latest.settings.game_exit_behavior);
    try std.testing.expect(latest.settings.curseforge_enabled);
    try std.testing.expect(latest.settings.curseforge_terms_approved);
    try std.testing.expectEqualStrings(reference, latest.settings.curseforge_credential_ref.?);
    try std.testing.expectEqualStrings("edited-public-client", latest.settings.microsoft_client_id);
    var reloaded = try config.Store.init(a, std.testing.io, root);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings(reference, reloaded.snapshot().accounts[0].credential_ref.?);
    try std.testing.expectEqualStrings(reference, reloaded.snapshot().settings.curseforge_credential_ref.?);
    try std.testing.expect(reloaded.snapshot().settings.curseforge_terms_approved);
    try std.testing.expectEqual(@as(u32, 8192), reloaded.snapshot().settings.default_memory_mb);
}

fn keyTestSnapshot() credential_controller.Snapshot {
    return .{ .phase = .idle, .busy = false, .worker_active = false, .publication_pending = false, .recovery_required = false, .committed = false, .commit_uncertain = false, .cleanup_pending = false, .failure = null, .task_id = null };
}

fn setTestKey(ui: *Ui, value: []const u8) void {
    ui.key_editor.reset();
    @memset(&ui.key_editor.bytes, 0xa5);
    @memcpy(ui.key_editor.bytes[0..value.len], value);
    ui.key_editor.len = value.len;
    ui.key_editor.status = .ready;
}

fn expectKeyCleared(ui: *const Ui) !void {
    for (ui.key_editor.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(@as(usize, 0), ui.key_editor.len);
    try std.testing.expectEqual(masked_key.Status.empty, ui.key_editor.status);
}

const KeyWipeAllocator = struct {
    backing: std.mem.Allocator,
    frees: usize = 0,
    all_zero: bool = true,
    fail: bool = false,

    fn allocator(self: *KeyWipeAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *KeyWipeAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail) return null;
        return self.backing.rawAlloc(len, alignment, ret);
    }

    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *KeyWipeAllocator = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        for (bytes) |byte| if (byte != 0) {
            self.all_zero = false;
        };
        self.backing.rawFree(bytes, alignment, ret);
    }
};

test "settings rejected draft cannot enqueue retained key bytes and rejection wipes" {
    var probe: KeyWipeAllocator = .{ .backing = std.testing.allocator };
    var ui = try Ui.init(probe.allocator(), .{ .microsoft_client_id = "" });
    defer ui.deinit();
    for ([_]masked_key.Status{ .invalid_input, .too_long }) |status| {
        setTestKey(&ui, "RetainedCanary!");
        ui.key_editor.status = status;
        probe.fail = true;
        try std.testing.expect(!ui.key_editor.readyForSave());
        try std.testing.expectError(error.InvalidKey, ui.requestKey(.save_key, keyTestSnapshot(), false, false));
        try std.testing.expect(ui.key_pending == null);
        try expectKeyCleared(&ui);
    }
    try std.testing.expectError(error.InvalidKey, ui.requestKey(.save_key, keyTestSnapshot(), false, false));
    try std.testing.expect(ui.key_pending == null);
    probe.fail = false;
    setTestKey(&ui, "FreshCanary!");
    try ui.requestKey(.save_key, keyTestSnapshot(), false, false);
    try expectKeyCleared(&ui);
    try std.testing.expectEqualStrings("FreshCanary!", ui.key_pending.?.secret.?.bytes);
    ui.clearKey();
    try std.testing.expect(ui.key_pending == null and probe.all_zero);
}

test "settings credential editor never preloads and queued save owns only a copied secret" {
    const a = std.testing.allocator;
    var ui = try Ui.init(a, .{ .microsoft_client_id = "", .curseforge_enabled = true, .curseforge_terms_approved = true, .curseforge_credential_ref = "0123456789abcdef0123456789abcdef" });
    defer ui.deinit();
    try expectKeyCleared(&ui);
    try std.testing.expect(ui.key_editor.address == null and ui.key_pending == null);
    const address = @intFromPtr(&ui.key_editor);
    setTestKey(&ui, "fixture-key");
    try ui.requestKey(.save_key, keyTestSnapshot(), false, false);
    try expectKeyCleared(&ui);
    try std.testing.expectEqual(address, ui.key_editor.address.?);
    try std.testing.expectEqualStrings("fixture-key", ui.key_pending.?.secret.?.bytes);
    try std.testing.expect(ui.key_pending.?.policy.enabled and ui.key_pending.?.policy.terms_approved);
    try std.testing.expect(ui.pending == null and !ui.saved);
    @memset(&ui.key_editor.bytes, 0);
    try std.testing.expectEqualStrings("fixture-key", ui.key_pending.?.secret.?.bytes);
    ui.clearKey();
    try std.testing.expect(ui.key_pending == null and !ui.confirm_remove);
}

test "settings clear and deinit wipe all inline bytes and pending secret before free" {
    var probe: KeyWipeAllocator = .{ .backing = std.testing.allocator };
    var ui = try Ui.init(probe.allocator(), .{ .microsoft_client_id = "" });
    setTestKey(&ui, "fixture-key");
    try ui.requestKey(.save_key, keyTestSnapshot(), false, false);
    @memset(&ui.key_editor.bytes, 0xa5);
    ui.clearKey();
    try expectKeyCleared(&ui);
    try std.testing.expect(ui.key_pending == null);
    try std.testing.expectEqual(@as(usize, 1), probe.frees);
    try std.testing.expect(probe.all_zero);
    setTestKey(&ui, "second-fixture");
    try ui.requestKey(.save_key, keyTestSnapshot(), false, false);
    ui.deinit();
    try expectKeyCleared(&ui);
    try std.testing.expect(ui.key_pending == null);
    try std.testing.expectEqual(@as(usize, 2), probe.frees);
    try std.testing.expect(probe.all_zero);
}

test "settings key enqueue failures wipe borrowed input owned copy and tails" {
    var probe: KeyWipeAllocator = .{ .backing = std.testing.allocator };
    var ui = try Ui.init(probe.allocator(), .{ .microsoft_client_id = "" });
    defer ui.deinit();
    const address = @intFromPtr(&ui.key_editor);
    var busy = keyTestSnapshot();
    busy.busy = true;
    setTestKey(&ui, "fixture-key");
    try std.testing.expectError(error.Busy, ui.requestKey(.save_key, busy, false, false));
    try expectKeyCleared(&ui);
    try std.testing.expect(ui.key_pending == null and probe.all_zero);
    try std.testing.expectEqual(@as(usize, 1), probe.frees);
    try std.testing.expectEqual(address, ui.key_editor.address.?);
    setTestKey(&ui, "fixture-key");
    probe.fail = true;
    try std.testing.expectError(error.OutOfMemory, ui.requestKey(.save_key, keyTestSnapshot(), false, false));
    try expectKeyCleared(&ui);
    try std.testing.expect(ui.key_pending == null);
    probe.fail = false;
    setTestKey(&ui, "fixture-key");
    ui.key_editor.bytes[0] = 0x7f;
    try std.testing.expectError(error.InvalidKey, ui.requestKey(.save_key, keyTestSnapshot(), false, false));
    try expectKeyCleared(&ui);
    setTestKey(&ui, "fixture-key");
    try std.testing.expectError(error.PublicationUncertain, ui.requestKey(.save_key, keyTestSnapshot(), false, true));
    try expectKeyCleared(&ui);
    try std.testing.expect(ui.key_pending == null and probe.all_zero);
}

test "settings credential remove requires confirmation and recovery is explicit and joined" {
    var ui = try Ui.init(std.testing.allocator, .{ .microsoft_client_id = "", .curseforge_enabled = true, .curseforge_terms_approved = true });
    defer ui.deinit();
    setTestKey(&ui, "fixture-key");
    try std.testing.expectError(error.ConfirmationRequired, ui.requestKey(.remove_key, keyTestSnapshot(), false, false));
    try expectKeyCleared(&ui);
    ui.confirm_remove = true;
    try ui.requestKey(.remove_key, keyTestSnapshot(), false, false);
    try std.testing.expect(!ui.key_pending.?.policy.enabled and ui.key_pending.?.policy.terms_approved);
    try std.testing.expect(ui.key_pending.?.secret == null and ui.pending == null);
    ui.clearKey();
    try std.testing.expectError(error.NoRecoveryRequired, ui.requestKey(.recover_key, keyTestSnapshot(), false, false));
    var recovery = keyTestSnapshot();
    recovery.busy = true;
    recovery.recovery_required = true;
    recovery.worker_active = true;
    try std.testing.expectError(error.Busy, ui.requestKey(.recover_key, recovery, false, false));
    try std.testing.expect(ui.key_pending == null);
    recovery.worker_active = false;
    recovery.publication_pending = true;
    try ui.requestKey(.recover_key, recovery, false, false);
    try std.testing.expectEqual(KeyCommand.recover_key, ui.key_pending.?.command);
    try std.testing.expect(ui.key_pending.?.secret == null);
    ui.clearKey();
    try std.testing.expectError(error.Busy, ui.requestKey(.recover_key, recovery, true, false));
}

test "settings Cancel clears key command and replaces unpinned draft at the same address" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var ui = try Ui.init(a, store.snapshot().settings);
    defer ui.deinit();
    const address = @intFromPtr(&ui.key_editor);
    setTestKey(&ui, "fixture-key");
    try ui.requestKey(.save_key, keyTestSnapshot(), false, false);
    @memset(&ui.key_editor.bytes, 0xa5);
    ui.pending = .cancel;
    finish(&ui, &store);
    try expectKeyCleared(&ui);
    try std.testing.expect(ui.pending == null and ui.key_pending == null and ui.key_failure == null);
    try std.testing.expectEqual(address, @intFromPtr(&ui.key_editor));
    try std.testing.expect(ui.key_editor.address == null);
    ui.key_editor.reset();
    try std.testing.expectEqual(address, ui.key_editor.address.?);
    try std.testing.expect(store.snapshot().settings.curseforge_credential_ref == null);
}

test "settings leased policy save preserves latest CF bits and reference while updating unrelated fields" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var ui = try Ui.init(a, store.snapshot().settings);
    defer ui.deinit();
    var latest = store.snapshot().*;
    latest.settings.curseforge_enabled = true;
    latest.settings.curseforge_terms_approved = true;
    latest.settings.curseforge_credential_ref = "0123456789abcdef0123456789abcdef";
    try store.update(latest);
    ui.curseforge_enabled = false;
    ui.curseforge_terms_approved = false;
    setNumber(&ui.memory_buffer, "4096");
    ui.pending = .save;
    finishSettings(&ui, &store, true);
    try std.testing.expect(ui.saved and ui.failure == null);
    try std.testing.expectEqual(@as(u32, 4096), store.snapshot().settings.default_memory_mb);
    try std.testing.expect(store.snapshot().settings.curseforge_enabled and store.snapshot().settings.curseforge_terms_approved);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", store.snapshot().settings.curseforge_credential_ref.?);
    setTestKey(&ui, "fixture-key");
    try ui.requestKey(.save_key, keyTestSnapshot(), false, false);
    finish(&ui, &store);
    try expectKeyCleared(&ui);
    try std.testing.expect(ui.key_pending == null);
    try std.testing.expectEqual(error.CredentialsUnavailable, ui.key_failure.?);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", store.snapshot().settings.curseforge_credential_ref.?);
}

test "settings unavailable credentials clears secrets preserves latest policy and allows unrelated Save" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var ui = try Ui.init(a, store.snapshot().settings);
    defer ui.deinit();
    var latest = store.snapshot().*;
    latest.settings.curseforge_enabled = true;
    latest.settings.curseforge_terms_approved = true;
    latest.settings.curseforge_credential_ref = "0123456789abcdef0123456789abcdef";
    try store.update(latest);
    setTestKey(&ui, "fixture-key");
    try ui.requestKey(.save_key, keyTestSnapshot(), false, false);
    setNumber(&ui.memory_buffer, "4096");
    ui.pending = .save;
    finishUnavailable(&ui, &store);
    try expectKeyCleared(&ui);
    try std.testing.expect(ui.key_pending == null and ui.saved and ui.failure == null);
    try std.testing.expectEqual(@as(u32, 4096), store.snapshot().settings.default_memory_mb);
    try std.testing.expect(store.snapshot().settings.curseforge_enabled and store.snapshot().settings.curseforge_terms_approved);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", store.snapshot().settings.curseforge_credential_ref.?);
}

const KeyNoVault = struct {
    calls: usize = 0,

    fn store(self: *KeyNoVault) credentials.Store {
        return .{ .ctx = self, .vtable = &.{ .put = put, .get = get, .delete = delete } };
    }

    fn put(ctx: *anyopaque, _: []const u8, _: []const u8) credentials.Error!void {
        const self: *KeyNoVault = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return error.Unavailable;
    }

    fn get(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8) credentials.Error!credentials.Secret {
        const self: *KeyNoVault = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return error.Unavailable;
    }

    fn delete(ctx: *anyopaque, _: []const u8) credentials.Error!void {
        const self: *KeyNoVault = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return error.Unavailable;
    }
};

test "settings public key recovery accepts joined controller publication debt and leased Save keeps latest policy" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var vault: KeyNoVault = .{};
    var controller = credential_controller.Controller.init(a, std.testing.io, root, .{ .injected_store = vault.store() }) catch |err| {
        if (err == error.UnsupportedDurability) return error.SkipZigTest;
        return err;
    };
    defer controller.deinit();
    controller.publication_pending = true;
    controller.recovery_required = true;
    controller.frozen = true;
    const snapshot = controller.snapshot();
    try std.testing.expect(snapshot.busy and snapshot.publication_pending and !snapshot.worker_active);
    var ui = try Ui.init(a, store.snapshot().settings);
    defer ui.deinit();
    try ui.requestKey(.recover_key, snapshot, false, false);
    try std.testing.expectEqual(KeyCommand.recover_key, ui.key_pending.?.command);
    ui.clearKey();
    var latest = store.snapshot().*;
    latest.settings.curseforge_enabled = true;
    latest.settings.curseforge_terms_approved = true;
    latest.settings.curseforge_credential_ref = "0123456789abcdef0123456789abcdef";
    try store.update(latest);
    setNumber(&ui.memory_buffer, "4096");
    ui.pending = .save;
    finishWithCredentials(&ui, &store, &controller, false);
    try std.testing.expect(ui.saved and ui.failure == null);
    try std.testing.expectEqual(@as(u32, 4096), store.snapshot().settings.default_memory_mb);
    try std.testing.expect(store.snapshot().settings.curseforge_enabled and store.snapshot().settings.curseforge_terms_approved);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", store.snapshot().settings.curseforge_credential_ref.?);
    try std.testing.expectEqual(@as(usize, 0), vault.calls);
}

test "settings public credential finish rechecks fresh content busy and wipes rejected owned secret" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var vault: KeyNoVault = .{};
    var controller = credential_controller.Controller.init(a, std.testing.io, root, .{ .injected_store = vault.store() }) catch |err| {
        if (err == error.UnsupportedDurability) return error.SkipZigTest;
        return err;
    };
    defer controller.deinit();
    var probe: KeyWipeAllocator = .{ .backing = a };
    var ui = try Ui.init(probe.allocator(), .{ .microsoft_client_id = "" });
    defer ui.deinit();
    setTestKey(&ui, "fixture-key");
    try ui.requestKey(.save_key, controller.snapshot(), false, false);
    finishWithCredentials(&ui, &store, &controller, true);
    try expectKeyCleared(&ui);
    try std.testing.expect(ui.key_pending == null and !ui.saved);
    try std.testing.expectEqual(error.Busy, ui.key_failure.?);
    try std.testing.expectEqual(@as(usize, 1), probe.frees);
    try std.testing.expect(probe.all_zero);
    try std.testing.expectEqual(@as(usize, 0), vault.calls);
    try std.testing.expect(store.snapshot().settings.curseforge_credential_ref == null);
}
