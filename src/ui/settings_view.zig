const std = @import("std");
const dvui = @import("dvui");
const builtin = @import("builtin");
const config = @import("../core/config.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const credentials = @import("../core/credentials.zig");
const credential_controller = @import("../application/curseforge_credentials_controller.zig");
const masked_key = @import("curseforge_key_editor.zig");
const proxy_ui = @import("proxy_settings.zig");
const proxy_controller = @import("../application/proxy_settings_controller.zig");
const R = dvui.Rect;

const Field = enum { memory, connections, client_id, game_exit, cf_enabled, cf_terms };
const EditState = struct { dirty: bool = false, due: i128 = 0, failure: ?anyerror = null };
fn now() i128 {
    return if (dvui.current_window != null) dvui.currentWindow().frame_time_ns else 0;
}
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
    edits: [6]EditState = @splat(.{}),
    last_focus: ?dvui.Id = null,
    retry_requested: bool = false,
    restore_field: ?Field = null,
    failure: ?anyerror = null,
    saved: bool = false,
    key_editor: masked_key.Editor = .{},
    key_pending: ?KeyRequest = null,
    key_failure: ?anyerror = null,
    key_discard_queued: bool = false,
    confirm_remove: bool = false,
    proxy: proxy_ui.Draft,
    /// Optional external runtime binding; existing fixtures need not instantiate workers.
    proxy_controller: ?*proxy_controller.Controller = null,

    pub fn init(a: std.mem.Allocator, initial_settings: config.Settings) !Ui {
        var self: Ui = .{ .a = a, .game_exit_behavior = initial_settings.game_exit_behavior, .curseforge_enabled = initial_settings.curseforge_enabled, .curseforge_terms_approved = initial_settings.curseforge_terms_approved, .proxy = try proxy_ui.Draft.init(initial_settings.proxy) };
        errdefer self.client_id.deinit(a);
        try self.client_id.appendSlice(a, initial_settings.microsoft_client_id);
        _ = try std.fmt.bufPrint(&self.memory_buffer, "{d}", .{initial_settings.default_memory_mb});
        _ = try std.fmt.bufPrint(&self.connections_buffer, "{d}", .{initial_settings.download_connections});
        return self;
    }

    pub fn deinit(self: *Ui) void {
        self.clearKey();
        self.proxy.deinit();
        self.client_id.deinit(self.a);
        self.client_id = .empty;
        self.edits = @splat(.{});
        self.failure = null;
        self.saved = false;
    }

    /// Navigation/lifecycle hook: clears both kinds of unsaved credential input.
    pub fn clearSecrets(self: *Ui) void {
        self.clearKey();
        self.proxy.clearSecret();
    }

    pub fn clearKey(self: *Ui) void {
        self.key_editor.reset();
        if (self.key_pending) |*request| request.deinit();
        self.key_pending = null;
        self.key_failure = null;
        self.confirm_remove = false;
        self.key_discard_queued = false;
    }

    fn finishKeyDiscard(self: *Ui) void {
        if (self.key_discard_queued) self.clearKey();
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

    pub fn flush(self: *Ui) void {
        for (&self.edits) |*state| state.due = 0;
        self.proxy.flush();
    }

    pub fn dirty(self: *const Ui) bool {
        for (self.edits) |state| if (state.dirty) return true;
        return false;
    }

    fn retry(self: *Ui) void {
        self.failure = null;
        self.retry_requested = true;
        self.flush();
    }

    fn edited(self: *Ui, field: Field, delayed: bool) void {
        self.last_focus = if (dvui.current_window != null) dvui.focusedWidgetId() else null;
        self.edits[@backingInt(field)] = .{ .dirty = true, .due = now() + (if (delayed) @as(i128, 500 * std.time.ns_per_ms) else 0) };
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

fn failureText(failure: anyerror) []const u8 {
    return switch (failure) {
        error.InvalidMemory => "内存必须为 256 至 1048576 MiB 的整数",
        error.InvalidDownloadConnections => "下载连接数必须为 1 至 64 的整数",
        error.InvalidClientId => "Microsoft 客户端 ID 含无效字符或超过 4096 字节",
        else => "保存失败",
    };
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

fn drawCredentials(ui: *Ui, snapshot: credential_controller.Snapshot, settings: config.Settings, content_busy: bool, store_uncertain: bool) void {
    const configured = settings.curseforge_credential_ref != null;
    if (!configured) ui.confirm_remove = false;
    const editor = dvui.box(@src(), .{}, .{ .expand = .horizontal, .padding = R.all(0), .margin = R.all(0) });
    defer editor.deinit();
    components.fieldLabel(@src(), "CurseForge API 密钥");
    const action = components.formActions(@src(), .{ .save_label = "保存密钥", .save_enabled = ui.key_pending == null and keyAllowed(.save_key, snapshot, content_busy, store_uncertain) and ui.key_editor.readyForSave() });
    if (action == .cancel) ui.key_discard_queued = true;
    components.text(@src(), if (configured) "已配置" else "未配置", theme.colors.muted);
    const result = result: {
        const row = fieldRow(@src());
        defer row.deinit();
        const drawn = ui.key_editor.draw(@src(), components.entryOptions("CurseForge API 密钥", .{ .gap_after = 0 }));
        if (drawn.edited) ui.key_failure = null;
        if (drawn.cancel) ui.key_discard_queued = true;
        if (!ui.key_discard_queued and (action == .save or drawn.submit)) ui.requestKey(.save_key, snapshot, content_busy, store_uncertain) catch |err| {
            ui.key_failure = err;
        };
        _ = dvui.spacer(@src(), .{ .min_size_content = .width(theme.spacing.row_gap) });
        const remove_allowed = configured and ui.key_pending == null and keyAllowed(.remove_key, snapshot, content_busy, store_uncertain);
        if (components.iconButton(@src(), "移除 API 密钥", dvui.entypo.trash, .{ .enabled = remove_allowed })) {
            ui.clearKey();
            ui.confirm_remove = true;
        }
        if (components.iconButton(@src(), "恢复凭据状态", dvui.entypo.cw, .{ .enabled = ui.key_pending == null and keyAllowed(.recover_key, snapshot, content_busy, store_uncertain) })) ui.requestKey(.recover_key, snapshot, content_busy, store_uncertain) catch |err| {
            ui.key_failure = err;
        };
        break :result drawn;
    };
    switch (result.status) {
        .invalid_input => components.text(@src(), "密钥含无效字符", theme.colors.danger),
        .too_long => components.text(@src(), "密钥超过 512 字节", theme.colors.danger),
        else => {},
    }
    if (ui.confirm_remove) {
        components.text(@src(), "确认移除 CurseForge API 密钥？", theme.colors.danger);
        switch (components.formActions(@src(), .{ .save_label = "确认移除 API 密钥", .cancel_label = "取消移除", .save_enabled = configured and ui.key_pending == null and keyAllowed(.remove_key, snapshot, content_busy, store_uncertain) })) {
            .save => ui.requestKey(.remove_key, snapshot, content_busy, store_uncertain) catch |err| {
                ui.key_failure = err;
            },
            .cancel => ui.clearKey(),
            .none => {},
        }
    }
    if (store_uncertain or snapshot.commit_uncertain) {
        components.text(@src(), "配置持久化状态待确认", theme.colors.danger);
    } else if (snapshot.cleanup_pending) {
        components.text(@src(), "凭据变更已保存，清理尚未完成", theme.colors.danger);
    } else if (snapshot.recovery_required) {
        components.text(@src(), "凭据状态需要恢复", theme.colors.danger);
    } else if (snapshot.publication_pending) {
        components.text(@src(), "正在保存凭据配置", theme.colors.muted);
    } else if (snapshot.busy) {
        components.text(@src(), "正在处理凭据", theme.colors.muted);
    } else if (snapshot.committed) {
        components.text(@src(), if (configured) "密钥配置已保存" else "密钥已移除", theme.colors.muted);
    }
    const failure: ?anyerror = if (ui.key_failure) |err| err else snapshot.failure;
    if (failure) |err| {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "凭据操作失败（{s}）", .{@errorName(err)}) catch "凭据操作失败";
        components.text(@src(), message, theme.colors.danger);
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
    components.title(@src(), "设置");
    defer {
        if (ui.last_focus != dvui.focusedWidgetId()) for (&ui.edits) |*state| {
            state.due = 0;
        };
        if (ui.failure == null) for (ui.edits) |state| {
            if (state.dirty and state.failure == null and state.due > now()) dvui.timer(page.data().id.update("settings-autosave"), 50_000);
        };
    }
    {
        const scroll = components.scrollBody(@src());
        defer scroll.deinit();
        {
            const panel = components.formPanel(@src(), .{ .tag = "settings-resources" });
            defer panel.deinit();
            const fields = components.formRow(@src());
            defer fields.deinit();
            {
                const cell = fields.cell(@src(), 0);
                defer cell.deinit();
                components.fieldLabel(@src(), "默认游戏内存（MiB）");
                {
                    const row = fieldRow(@src());
                    defer row.deinit();
                    if (components.entry(@src(), "默认游戏内存（MiB）", &ui.memory_buffer, .{ .gap_after = 0, .digits_only = true, .tag = "默认游戏内存" })) ui.edited(.memory, true);
                    drawFieldReset(ui, .memory);
                }
                drawFieldStatus(ui, .memory);
            }
            {
                const cell = fields.cell(@src(), 1);
                defer cell.deinit();
                components.fieldLabel(@src(), "下载连接数");
                {
                    const row = fieldRow(@src());
                    defer row.deinit();
                    if (components.entry(@src(), "下载连接数", &ui.connections_buffer, .{ .gap_after = 0, .digits_only = true, .tag = "下载连接数" })) ui.edited(.connections, true);
                    drawFieldReset(ui, .connections);
                }
                drawFieldStatus(ui, .connections);
            }
        }
        {
            const panel = components.formPanel(@src(), .{ .tag = "settings-game-exit" });
            defer panel.deinit();
            components.fieldLabel(@src(), "游戏结束后");
            const modes = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .max_size_content = .width(360), .padding = R.all(0), .margin = R.all(0) });
            defer modes.deinit();
            if (components.button(@src(), "显示启动器", .{ .primary = ui.game_exit_behavior == .restore_launcher })) {
                ui.game_exit_behavior = .restore_launcher;
                ui.edited(.game_exit, false);
            }
            if (components.button(@src(), "退出启动器", .{ .primary = ui.game_exit_behavior == .exit_launcher })) {
                ui.game_exit_behavior = .exit_launcher;
                ui.edited(.game_exit, false);
            }
        }
        {
            const panel = components.formPanel(@src(), .{ .tag = "settings-microsoft" });
            defer panel.deinit();
            components.fieldLabel(@src(), "Microsoft 客户端 ID");
            {
                const row = fieldRow(@src());
                defer row.deinit();
                const entry = dvui.textEntry(@src(), .{ .text = .{ .array_list = .{ .backing = &ui.client_id, .allocator = ui.a, .limit = 4096 } } }, components.entryOptions("Microsoft 客户端 ID", .{ .gap_after = 0 }));
                if (entry.text_changed) ui.edited(.client_id, true);
                entry.deinit();
                drawFieldReset(ui, .client_id);
            }
            drawFieldStatus(ui, .client_id);
        }
        {
            const panel = components.formPanel(@src(), .{ .tag = "settings-curseforge" });
            defer panel.deinit();
            const policy_enabled = credential_failure == null and (if (controller) |active| !active.lease() and !content_busy else true);
            if (components.toggle(@src(), &ui.curseforge_enabled, "CurseForge", policy_enabled)) ui.edited(.cf_enabled, false);
            if (components.checkbox(@src(), &ui.curseforge_terms_approved, "已确认 CurseForge 接入条款", policy_enabled)) ui.edited(.cf_terms, false);
            if (controller) |active| drawCredentials(ui, active.snapshot(), settings, content_busy, store_uncertain);
            if (credential_failure) |err| {
                components.fieldLabel(@src(), "CurseForge API 密钥");
                var buffer: [256]u8 = undefined;
                const message = std.fmt.bufPrint(&buffer, "密钥不可用（{s}）", .{@errorName(err)}) catch "密钥不可用";
                components.text(@src(), message, theme.colors.danger);
            }
        }
        proxy_ui.draw(&ui.proxy, ui.proxy_controller, settings, store_uncertain);
        const status = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .height(104), .max_size_content = .height(104) });
        defer status.deinit();
        const message = if (ui.failure) |err| try std.fmt.allocPrint(dvui.currentWindow().arena(), "设置未保存（{s}），请重试", .{@errorName(err)}) else if (ui.dirty()) "部分修改尚未保存，请检查输入或等待当前操作完成" else "有效修改将自动保存";
        components.text(@src(), message, if (ui.failure != null) theme.colors.danger else theme.colors.muted);
        if (components.button(@src(), "重试保存", .{ .enabled = ui.failure != null })) ui.retry();
    }
}

/// Publish after drawing, when no view still borrows Store snapshots.
pub fn finish(ui: *Ui, store: *config.Store) void {
    ui.finishKeyDiscard();
    const unavailable = ui.key_pending != null;
    if (unavailable) ui.clearKey();
    finishSettings(ui, store, false);
    if (unavailable) ui.key_failure = error.CredentialsUnavailable;
}

pub fn finishWithCredentials(ui: *Ui, store: *config.Store, controller: *credential_controller.Controller, content_busy: bool) void {
    ui.finishKeyDiscard();
    const policy_locked = controller.lease() or content_busy;
    finishSettings(ui, store, policy_locked);
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
    ui.finishKeyDiscard();
    ui.clearKey();
    finishSettings(ui, store, true);
}

fn fieldRow(src: std.builtin.SourceLocation) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0), .background = false });
}

fn drawFieldReset(ui: *Ui, comptime field: Field) void {
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(theme.spacing.row_gap) });
    if (components.iconButton(@src(), "恢复已保存值", dvui.entypo.cw, .{ .enabled = ui.edits[@backingInt(field)].dirty })) ui.restore_field = field;
}

fn drawFieldStatus(ui: *Ui, comptime field: Field) void {
    const state = ui.edits[@backingInt(field)];
    // Clean fields have no footer. The reset button already indicates an unsaved draft.
    if (state.failure) |err| components.text(@src(), failureText(err), theme.colors.danger);
}

fn mergeField(ui: *const Ui, field: Field, value: *config.Settings) !bool {
    switch (field) {
        .memory => {
            const parsed = std.fmt.parseInt(u32, std.mem.trim(u8, std.mem.sliceTo(&ui.memory_buffer, 0), " "), 10) catch return error.InvalidMemory;
            if (parsed < 256 or parsed > 1024 * 1024) return error.InvalidMemory;
            if (value.default_memory_mb == parsed) return false;
            value.default_memory_mb = parsed;
        },
        .connections => {
            const parsed = std.fmt.parseInt(u16, std.mem.trim(u8, std.mem.sliceTo(&ui.connections_buffer, 0), " "), 10) catch return error.InvalidDownloadConnections;
            if (parsed == 0 or parsed > 64) return error.InvalidDownloadConnections;
            if (value.download_connections == parsed) return false;
            value.download_connections = parsed;
        },
        .client_id => {
            const text = ui.client_id.items;
            if (text.len > 4096 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidClientId;
            var it = std.unicode.Utf8View.initUnchecked(text).iterator();
            while (it.nextCodepoint()) |cp| if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.InvalidClientId;
            if (std.mem.eql(u8, value.microsoft_client_id, text)) return false;
            value.microsoft_client_id = text;
        },
        .game_exit => {
            if (value.game_exit_behavior == ui.game_exit_behavior) return false;
            value.game_exit_behavior = ui.game_exit_behavior;
        },
        .cf_enabled => {
            if (value.curseforge_enabled == ui.curseforge_enabled) return false;
            value.curseforge_enabled = ui.curseforge_enabled;
        },
        .cf_terms => {
            if (value.curseforge_terms_approved == ui.curseforge_terms_approved) return false;
            value.curseforge_terms_approved = ui.curseforge_terms_approved;
        },
    }
    return true;
}

fn restoreField(ui: *Ui, field: Field, value: config.Settings) !void {
    switch (field) {
        .memory => {
            @memset(&ui.memory_buffer, 0);
            _ = try std.fmt.bufPrint(&ui.memory_buffer, "{d}", .{value.default_memory_mb});
        },
        .connections => {
            @memset(&ui.connections_buffer, 0);
            _ = try std.fmt.bufPrint(&ui.connections_buffer, "{d}", .{value.download_connections});
        },
        .client_id => if (!std.mem.eql(u8, ui.client_id.items, value.microsoft_client_id)) {
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(ui.a, value.microsoft_client_id);
            ui.client_id.deinit(ui.a);
            ui.client_id = text;
        },
        .game_exit => ui.game_exit_behavior = value.game_exit_behavior,
        .cf_enabled => ui.curseforge_enabled = value.curseforge_enabled,
        .cf_terms => ui.curseforge_terms_approved = value.curseforge_terms_approved,
    }
    ui.edits[@backingInt(field)] = .{};
}

fn finishSettings(ui: *Ui, store: *config.Store, preserve_cf_policy: bool) void {
    // Proxy failures never block unrelated ordinary settings.
    ui.proxy.finish(ui.proxy_controller, store);
    if (ui.restore_field) |field| {
        ui.restore_field = null;
        restoreField(ui, field, store.snapshot().settings) catch |err| {
            ui.failure = err;
            return;
        };
    }
    for (0..ui.edits.len) |i| if (!ui.edits[i].dirty) {
        restoreField(ui, @fromBackingInt(@intCast(i)), store.snapshot().settings) catch |err| {
            ui.failure = err;
            return;
        };
    };
    if (ui.failure != null) return;
    var accepted: [6]bool = @splat(false);
    var candidate = store.snapshot().settings;
    var any = false;
    for (&ui.edits, 0..) |*state, i| {
        if (!state.dirty or state.failure != null or state.due > now()) continue;
        const field: Field = @fromBackingInt(@intCast(i));
        if (preserve_cf_policy and (field == .cf_enabled or field == .cf_terms)) continue;
        const changed = mergeField(ui, field, &candidate) catch |err| {
            state.failure = err;
            continue;
        };
        if (!changed and !store.publicationUncertain()) {
            state.* = .{};
            continue;
        }
        accepted[i] = true;
        any = true;
    }
    if (!any) return;
    if (store.publicationUncertain()) {
        if (!ui.retry_requested) {
            ui.failure = error.ConfigPublicationUncertain;
            return;
        }
        store.reconcile() catch |err| {
            ui.failure = err;
            ui.retry_requested = false;
            return;
        };
    }
    ui.retry_requested = false;
    var document = store.snapshot().*;
    var changed = false;
    for (accepted, 0..) |accept, i| if (accept) {
        changed = (mergeField(ui, @fromBackingInt(@intCast(i)), &document.settings) catch unreachable) or changed;
    };
    if (changed) store.update(document) catch |err| {
        ui.failure = err;
        ui.saved = false;
        return;
    };
    for (accepted, 0..) |accept, i| if (accept) {
        ui.edits[i] = .{};
    };
    ui.saved = !ui.dirty();
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

test "settings autosave independently validates fields and flushes delayed changes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var ui = try Ui.init(a, store.snapshot().settings);
    defer ui.deinit();
    setNumber(&ui.memory_buffer, "0");
    ui.edited(.memory, true);
    ui.game_exit_behavior = .exit_launcher;
    ui.edited(.game_exit, false);
    var latest = store.snapshot().*;
    latest.settings.download_connections = 12;
    try store.update(latest);
    finish(&ui, &store);
    try std.testing.expectEqual(config.GameExitBehavior.exit_launcher, store.snapshot().settings.game_exit_behavior);
    try std.testing.expect(ui.edits[0].failure == null);
    ui.flush();
    finish(&ui, &store);
    try std.testing.expectEqual(error.InvalidMemory, ui.edits[0].failure.?);
    try std.testing.expectEqual(@as(u32, 2048), store.snapshot().settings.default_memory_mb);
    try std.testing.expectEqual(@as(u16, 12), store.snapshot().settings.download_connections);
    setNumber(&ui.memory_buffer, "4096");
    ui.edited(.memory, true);
    finish(&ui, &store);
    try std.testing.expectEqual(@as(u32, 2048), store.snapshot().settings.default_memory_mb);
    ui.flush();
    finish(&ui, &store);
    try std.testing.expect(!ui.dirty());
    try store.reconcile();
    try std.testing.expectEqual(@as(u32, 4096), store.snapshot().settings.default_memory_mb);
}

test "settings init rolls back allocation failure" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, struct {
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
test "settings autosave IO failure stops writes and no-op edits avoid disk" {
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
    ui.edited(.memory, false);
    finish(&ui, &store);
    try std.testing.expectEqual(@as(usize, 0), fault.syncs);
    fault.fail_at = 1;
    setNumber(&ui.memory_buffer, "8192");
    ui.edited(.memory, false);
    finish(&ui, &store);
    try std.testing.expectEqual(error.InputOutput, ui.failure.?);
    const syncs = fault.syncs;
    for (0..3) |_| {
        ui.flush();
        finish(&ui, &store);
    }
    try std.testing.expectEqual(syncs, fault.syncs);
    try std.testing.expectEqual(@as(u32, 2048), store.snapshot().settings.default_memory_mb);
    fault.fail_at = null;
    ui.retry();
    finish(&ui, &store);
    try std.testing.expect(ui.saved and ui.failure == null);
    try std.testing.expectEqual(@as(u32, 8192), store.snapshot().settings.default_memory_mb);
}

test "settings autosave proceeds past invalid proxy and defers leased policy" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var ui = try Ui.init(a, store.snapshot().settings);
    defer ui.deinit();
    ui.proxy.mode = .manual;
    @memset(&ui.proxy.host, 0);
    ui.proxy.dirty = true;
    setNumber(&ui.memory_buffer, "4096");
    ui.edited(.memory, false);
    ui.curseforge_enabled = true;
    ui.edited(.cf_enabled, false);
    finishSettings(&ui, &store, true);
    try std.testing.expect(ui.proxy.failure != null);
    try std.testing.expectEqual(@as(u32, 4096), store.snapshot().settings.default_memory_mb);
    try std.testing.expect(!store.snapshot().settings.curseforge_enabled and ui.dirty());
    finishSettings(&ui, &store, false);
    try std.testing.expect(store.snapshot().settings.curseforge_enabled and !ui.dirty());
    setNumber(&ui.memory_buffer, "0");
    ui.edited(.memory, false);
    finish(&ui, &store);
    ui.restore_field = .memory;
    finish(&ui, &store);
    try std.testing.expectEqualStrings("4096", std.mem.sliceTo(&ui.memory_buffer, 0));
    try std.testing.expect(!ui.dirty());
}

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

test "settings autosave uncertain disk stops until retry and preserves new credential reference" {
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
    var latest = store.snapshot().*;
    latest.settings.curseforge_credential_ref = reference;
    try std.testing.expectError(error.InputOutput, store.update(latest));
    const syncs = fault.syncs;
    setNumber(&ui.memory_buffer, "8192");
    ui.edited(.memory, false);
    finish(&ui, &store);
    try std.testing.expect(ui.failure != null);
    for (0..3) |_| {
        ui.flush();
        finish(&ui, &store);
    }
    try std.testing.expectEqual(syncs, fault.syncs);
    try std.testing.expectEqualStrings("8192", std.mem.sliceTo(&ui.memory_buffer, 0));
    fault.fail_at = null;
    ui.retry();
    finish(&ui, &store);
    try std.testing.expect(ui.saved and ui.failure == null);
    try std.testing.expectEqual(@as(u32, 8192), store.snapshot().settings.default_memory_mb);
    try std.testing.expectEqualStrings(reference, store.snapshot().settings.curseforge_credential_ref.?);
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
    try std.testing.expect(!ui.dirty() and !ui.saved);
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
    try std.testing.expect(ui.key_pending.?.secret == null and !ui.dirty());
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

test "key form Cancel defers wiping and preserves unrelated settings draft" {
    var ui = try Ui.init(std.testing.allocator, .{});
    defer ui.deinit();
    setNumber(&ui.memory_buffer, "8192");
    setTestKey(&ui, "fixture-key");
    try ui.requestKey(.save_key, keyTestSnapshot(), false, false);
    setTestKey(&ui, "uncommitted-key");
    ui.key_failure = error.InvalidKey;
    ui.key_discard_queued = true;
    try std.testing.expect(ui.key_pending != null and ui.key_editor.readyForSave());
    ui.finishKeyDiscard();
    try expectKeyCleared(&ui);
    try std.testing.expect(ui.key_pending == null and ui.key_failure == null and !ui.key_discard_queued);
    try std.testing.expectEqual(@as(u32, 8192), (try ui.settings()).default_memory_mb);
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
    ui.edited(.memory, false);
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
    ui.edited(.memory, false);
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
    ui.edited(.memory, false);
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

test "proxy settings save preserves newer unrelated settings and cancel clears plaintext" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try config.Store.init(a, std.testing.io, root);
    defer store.deinit();
    var ui = try Ui.init(a, store.snapshot().settings);
    defer ui.deinit();
    ui.proxy.mode = .manual;
    ui.proxy.dirty = true;
    var latest = store.snapshot().*;
    latest.settings.resource_list_view = true;
    latest.settings.download_connections = 12;
    try store.update(latest);
    ui.proxy.command = .save;
    finishUnavailable(&ui, &store);
    try std.testing.expectEqual(@import("../core/proxy_config.zig").Mode.manual, store.snapshot().settings.proxy.mode);
    try std.testing.expect(store.snapshot().settings.resource_list_view);
    try std.testing.expectEqual(@as(u8, 12), store.snapshot().settings.download_connections);
    // CF being unavailable must not erase independent proxy input every frame.
    @memcpy(ui.proxy.password.bytes[0..6], "secret");
    ui.proxy.password.len = 6;
    finishUnavailable(&ui, &store);
    try std.testing.expectEqualStrings("secret", (try ui.proxy.password.borrow()).?);
    ui.clearSecrets();
    for (ui.proxy.password.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    @memcpy(ui.proxy.password.bytes[0..6], "secret");
    ui.proxy.password.len = 6;
    ui.clearSecrets();
    finish(&ui, &store);
    try std.testing.expect((try ui.proxy.password.borrow()) == null);
}
