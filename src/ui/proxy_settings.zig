//! Proxy draft and presentation. No native/network work runs while drawing.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const proxy = @import("../core/proxy_config.zig");
const controller = @import("../application/proxy_settings_controller.zig");
const components = @import("components.zig");
const theme = @import("theme.zig");

pub const Command = enum { save, retry, test_connection, detect, recover, cancel };
pub const Draft = struct {
    mode: proxy.Mode,
    protocol: proxy.Protocol,
    host: [254]u8 = @splat(0),
    port: [6]u8 = @splat(0),
    username: [257]u8 = @splat(0),
    bypass: [4097]u8 = @splat(0),
    password: PasswordEditor = .{},
    remove_password: bool = false,
    password_pending: bool = false,
    dirty: bool = false,
    command: ?Command = null,
    failure: ?anyerror = null,
    submitted_revision: ?u64 = null,
    edit_revision: u64 = 0,
    submitted_edit_revision: u64 = 0,
    submitted_secret: bool = false,
    deadline_ns: i128 = 0,
    frame_time_ns: i128 = 0,
    edit_focus: ?dvui.Id = null,
    autosave_failed: bool = false,
    reload_committed: bool = false,
    result_stale: bool = false,

    pub fn init(settings: proxy.Settings) !Draft {
        var self: Draft = .{ .mode = settings.mode, .protocol = settings.protocol };
        try self.load(settings);
        return self;
    }
    fn load(self: *Draft, settings: proxy.Settings) !void {
        self.mode = settings.mode;
        self.protocol = settings.protocol;
        @memset(&self.host, 0);
        @memset(&self.port, 0);
        @memset(&self.username, 0);
        @memset(&self.bypass, 0);
        try copyText(&self.host, settings.host);
        try copyText(&self.username, settings.username);
        try copyText(&self.bypass, settings.bypass);
        _ = try std.fmt.bufPrint(&self.port, "{d}", .{settings.port});
    }
    pub fn deinit(self: *Draft) void {
        self.password.reset();
    }
    /// Erase plaintext on navigation without authorizing the held settings group.
    pub fn clearSecret(self: *Draft) void {
        self.password_pending = self.secretPending();
        self.password.reset();
        self.remove_password = false;
    }
    fn secretPending(self: *const Draft) bool {
        return self.password_pending or self.remove_password or self.password.len != 0 or self.password.invalid;
    }
    pub fn needsSave(self: *const Draft) bool {
        return self.dirty or self.secretPending();
    }
    /// Flush ordinary edits only. A failed attempt still needs retry or a new edit.
    pub fn flush(self: *Draft) void {
        if (self.dirty) self.deadline_ns = 0;
    }
    pub fn value(self: *const Draft, committed: proxy.Settings) !proxy.Settings {
        if (self.mode != .manual) {
            var next = committed;
            next.mode = self.mode;
            return next;
        }
        const port = std.fmt.parseInt(u16, std.mem.sliceTo(&self.port, 0), 10) catch return error.InvalidProxyPort;
        const next: proxy.Settings = .{ .mode = self.mode, .protocol = self.protocol, .host = std.mem.sliceTo(&self.host, 0), .port = port, .username = std.mem.sliceTo(&self.username, 0), .bypass = std.mem.sliceTo(&self.bypass, 0), .credential_ref = if (self.remove_password or self.password.len != 0) null else committed.credential_ref };
        try proxy.validateCredentialReuse(committed, next);
        try proxy.validate(next);
        return next;
    }
    pub fn preflight(self: *const Draft, active: ?*controller.Controller, settings: config.Settings, uncertain: bool) !void {
        if (!self.needsSave()) return;
        if (active) |worker| if (worker.isBusy()) return error.Busy;
        if (uncertain) return error.ConfigPublicationUncertain;
        if (settings.proxy_pending_credential_ref != null) return error.RecoveryRequired;
        const next = try self.value(settings.proxy);
        if (self.mode != .manual) return;
        try proxy.validateCredentialReuse(settings.proxy, next);
        const password = try self.password.borrow();
        if (password != null and next.username.len == 0) return error.InvalidProxyUsername;
        if (password == null and !self.remove_password and next.username.len != 0 and next.credential_ref == null) return error.ProxyAuthenticationIncomplete;
        if (active == null and (password != null or self.remove_password)) return error.ProxyControllerUnavailable;
    }
    /// Explicit password submission; ordinary autosave never calls this method.
    pub fn save(self: *Draft, active: ?*controller.Controller, store: *config.Store) !void {
        if (!self.needsSave()) return;
        if (self.mode != .manual) return self.autosave(active, store);
        try self.preflight(active, store.snapshot().settings, store.publicationUncertain());
        const next = try self.value(store.snapshot().settings.proxy);
        try self.submit(active, store, next, try self.password.borrow(), self.remove_password);
        if (self.submitted_revision != null) self.submitted_secret = self.secretPending();
        self.clearSecret();
        self.password_pending = false;
    }
    fn submit(self: *Draft, active: ?*controller.Controller, store: *config.Store, next: proxy.Settings, password: ?[]const u8, remove: bool) !void {
        if (active) |worker| {
            try worker.startSave(store, next, password, remove);
            self.submitted_revision = worker.snapshot().revision;
            self.submitted_edit_revision = self.edit_revision;
            self.submitted_secret = false;
        } else {
            var document = store.snapshot().*;
            document.settings.proxy = next;
            try store.update(document);
            self.dirty = false;
            if (self.mode == .manual) try self.load(store.snapshot().settings.proxy);
        }
        self.failure = null;
        self.autosave_failed = false;
    }
    fn autosave(self: *Draft, active: ?*controller.Controller, store: *config.Store) !void {
        if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
        if (store.snapshot().settings.proxy_pending_credential_ref != null) return error.RecoveryRequired;
        var next = try self.value(store.snapshot().settings.proxy);
        // Autosave never authorizes a replacement/removal staged in the password editor.
        next.credential_ref = store.snapshot().settings.proxy.credential_ref;
        try proxy.validateCredentialReuse(store.snapshot().settings.proxy, next);
        if (next.mode == .manual and next.username.len != 0 and next.credential_ref == null) return error.ProxyAuthenticationIncomplete;
        if (proxy.same(next, store.snapshot().settings.proxy)) {
            self.dirty = false;
            return;
        }
        try self.submit(active, store, next, null, false);
    }
    /// Controller tick owns publication. A completion acknowledges only its edit revision.
    pub fn sync(self: *Draft, active: ?*controller.Controller) void {
        const worker = active orelse return;
        const revision = self.submitted_revision orelse return;
        const snapshot = worker.snapshot();
        if (snapshot.revision != revision) {
            if (self.submitted_edit_revision == self.edit_revision) {
                self.dirty = false;
                self.reload_committed = true;
            }
            self.submitted_revision = null;
            self.submitted_secret = false;
        } else if (!worker.isBusy()) {
            self.submitted_revision = null;
            // A failed credential submission requires another explicit decision.
            if (self.submitted_secret) self.password_pending = true;
            self.submitted_secret = false;
            // A newer edit is already an explicit request to try the latest group.
            if (self.submitted_edit_revision == self.edit_revision) {
                self.autosave_failed = true;
                self.failure = snapshot.failure orelse error.Cancelled;
            }
        }
    }
    pub fn finish(self: *Draft, active: ?*controller.Controller, store: *config.Store) void {
        self.sync(active);
        if (self.reload_committed) {
            self.reload_committed = false;
            if (self.mode == .manual and !self.dirty and !self.secretPending()) self.load(store.snapshot().settings.proxy) catch |err| {
                self.failure = err;
            };
        }
        if (self.command) |command| {
            self.command = null;
            self.perform(command, active, store) catch |err| {
                self.failure = err;
                if (command == .save or command == .retry) self.autosave_failed = true;
            };
            return;
        }
        if (!self.dirty or (self.mode == .manual and self.secretPending()) or self.autosave_failed or self.submitted_revision != null) return;
        if (active) |worker| if (worker.isBusy()) return;
        const now = if (dvui.current_window) |window| window.frame_time_ns else self.frame_time_ns;
        if (self.deadline_ns != 0 and now < self.deadline_ns) return;
        self.autosave(active, store) catch |err| {
            self.failure = err;
            self.autosave_failed = true;
        };
    }
    fn perform(self: *Draft, command: Command, active: ?*controller.Controller, store: *config.Store) !void {
        if (command == .save) return self.save(active, store);
        if (command == .retry) {
            self.autosave_failed = false;
            self.failure = null;
            self.flush();
            return;
        }
        const worker = active orelse return error.ProxyControllerUnavailable;
        switch (command) {
            .save, .retry => unreachable,
            .cancel => worker.cancel(),
            .recover => {
                try worker.startRecovery(store);
                self.autosave_failed = false;
                self.flush();
            },
            .test_connection, .detect => {
                const next = try self.value(store.snapshot().settings.proxy);
                const secret = if (self.mode == .manual) try self.password.borrow() else null;
                try worker.startProbe(store.snapshot().settings.proxy, next, secret, command == .detect);
                self.result_stale = false;
            },
        }
        self.failure = null;
    }
    fn edited(self: *Draft) void {
        self.dirty = true;
        self.edit_revision +%= 1;
        self.deadline_ns = self.frame_time_ns + 500 * std.time.ns_per_ms;
        self.edit_focus = if (dvui.current_window != null) dvui.focusedWidgetId() else null;
        self.autosave_failed = false;
        self.failure = null;
        self.result_stale = true;
    }
};

pub fn draw(draft: *Draft, active: ?*controller.Controller, settings: config.Settings, uncertain: bool) void {
    draft.sync(active);
    draft.frame_time_ns = dvui.currentWindow().frame_time_ns;
    const prior_focus = draft.edit_focus;
    const timer_id = dvui.parentGet().data().id.update("proxy-autosave");
    defer {
        if (draft.dirty and prior_focus != null and prior_focus != dvui.focusedWidgetId()) draft.flush();
        if (draft.dirty and (draft.mode != .manual or !draft.secretPending()) and !draft.autosave_failed) dvui.timer(timer_id, 50_000);
    }
    const panel = components.formPanel(@src(), .{ .tag = "settings-proxy" });
    defer panel.deinit();
    components.fieldLabel(@src(), "启动器网络代理");
    const busy = if (active) |worker| worker.isBusy() else false;
    {
        const modes = selectorRow(@src(), &.{ "直连", "跟随系统", "手动" });
        defer modes.deinit();
        inline for (.{ proxy.Mode.direct, proxy.Mode.system, proxy.Mode.manual }, .{ "直连", "跟随系统", "手动" }) |mode, label| {
            const choice = dvui.box(@src(), .{}, .{ .id_extra = @backingInt(mode), .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
            defer choice.deinit();
            if (components.button(@src(), label, .{ .primary = draft.mode == mode, .min_width = 0 })) {
                draft.mode = mode;
                draft.edited();
            }
        }
    }
    switch (draft.mode) {
        .direct => components.text(@src(), "不使用代理，保持默认网络行为。", theme.colors.muted),
        .system => components.text(@src(), "读取系统与环境代理；未配置时直连。检测失败会明确提示。", theme.colors.muted),
        .manual => {
            components.fieldLabel(@src(), "代理协议");
            {
                const protocols = selectorRow(@src(), &.{ "HTTP", "HTTPS", "SOCKS5" });
                defer protocols.deinit();
                inline for (.{ proxy.Protocol.http, proxy.Protocol.https, proxy.Protocol.socks5 }, .{ "HTTP", "HTTPS", "SOCKS5" }) |protocol, label| {
                    const choice = dvui.box(@src(), .{}, .{ .id_extra = @backingInt(protocol), .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
                    defer choice.deinit();
                    if (components.button(@src(), label, .{ .primary = draft.protocol == protocol, .min_width = 0 })) {
                        draft.protocol = protocol;
                        draft.edited();
                    }
                }
            }
            if (components.field(@src(), "主机（不含协议或账号）", &draft.host, .{ .tag = "代理主机" })) draft.edited();
            if (components.field(@src(), "端口", &draft.port, .{ .digits_only = true, .tag = "代理端口" })) draft.edited();
            if (components.field(@src(), "用户名（可选）", &draft.username, .{ .tag = "代理用户名" })) draft.edited();
            components.fieldLabel(@src(), "代理密码（可选）");
            components.text(@src(), if (settings.proxy.credential_ref != null) "已保存密码；仅同一主机、端口、协议和用户名可留空保留。更改后请更新密码或移除凭据。" else "未保存密码；无需认证时留空。", theme.colors.muted);
            if (draft.password.draw(!busy)) {
                draft.remove_password = false;
                draft.password_pending = true;
                draft.edited();
            }
            if (draft.password.invalid) components.text(@src(), "密码须为有效文本，最多 512 字节，不含控制字符。", theme.colors.danger);
            if (components.checkbox(@src(), &draft.remove_password, "移除已存密码（需点击更新密码）", !busy and settings.proxy.credential_ref != null)) {
                if (draft.remove_password) draft.password.reset();
                draft.password_pending = true;
                draft.edited();
            }
            if (components.field(@src(), "绕过代理（逗号分隔，支持域名与 IP）", &draft.bypass, .{ .tag = "代理绕过列表" })) draft.edited();
        },
    }
    // Reserve a compact feedback line without a large empty action placeholder.
    {
        const feedback = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .height(theme.bodyFont().lineHeight()), .padding = dvui.Rect.all(0), .margin = .{ .h = theme.spacing.row_gap } });
        defer feedback.deinit();
        if (draft.mode == .manual and draft.secretPending()) {
            components.text(@src(), "密码编辑尚未提交；普通代理设置暂缓自动保存。", theme.colors.muted);
            if (components.button(@src(), "更新密码", .{ .enabled = !busy and active != null, .expand = true })) draft.command = .save;
        } else if (draft.autosave_failed and draft.dirty) {
            if (components.button(@src(), "重试保存代理设置", .{ .enabled = !busy, .expand = true })) draft.command = .retry;
        } else components.text(@src(), if (draft.failure) |failure| failureText(failure) else if (draft.dirty) "代理设置待自动保存…" else "有效代理修改将自动保存", if (draft.failure != null) theme.colors.danger else theme.colors.muted);
        if (draft.failure != null and (draft.secretPending() or (draft.autosave_failed and draft.dirty))) components.text(@src(), failureText(draft.failure.?), theme.colors.danger);
    }
    {
        const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
        defer actions.deinit();
        if (components.button(@src(), "测试连接", .{ .enabled = !busy and active != null, .expand = true })) draft.command = .test_connection;
        if (draft.mode == .system and components.button(@src(), "重新检测", .{ .enabled = !busy and active != null, .expand = true })) draft.command = .detect;
        if (busy and components.button(@src(), "取消代理操作", .{ .expand = true })) draft.command = .cancel;
    }
    if (settings.proxy_pending_credential_ref != null or uncertain) {
        components.text(@src(), "凭据更新尚待确认；恢复会保留当前密码并清理未使用的凭据。", theme.colors.danger);
        if (components.button(@src(), "恢复代理凭据状态", .{ .enabled = !busy and active != null, .expand = true })) draft.command = .recover;
    }
    if (active) |worker| {
        const snapshot = worker.snapshot();
        if (snapshot.phase != .idle) components.text(@src(), statusText(snapshot), if (snapshot.failure != null) theme.colors.danger else theme.colors.muted);
        if (snapshot.failure) |failure| {
            const label = std.fmt.allocPrint(dvui.currentWindow().arena(), "错误：{s}", .{@errorName(failure)}) catch "代理操作失败";
            components.text(@src(), label, theme.colors.danger);
        }
        if (snapshot.phase == .connected or snapshot.phase == .detected) {
            components.text(@src(), sourceText(snapshot.result.source), theme.colors.muted);
            components.text(@src(), if (snapshot.result.proxied) "测试目标使用代理" else "测试目标使用直连（可能命中绕过规则）", theme.colors.muted);
        }
        if (draft.result_stale and (snapshot.phase == .connected or snapshot.phase == .detected or snapshot.phase == .no_system_proxy)) components.text(@src(), "草稿已更改，请重新测试。", theme.colors.muted);
    } else components.text(@src(), "代理测试与密码存储服务未连接；仍可保存不含密码的代理设置。", theme.colors.muted);
}

fn selectorRow(src: std.builtin.SourceLocation, labels: []const []const u8) *dvui.BoxWidget {
    const available = dvui.parentGet().data().contentRect().w;
    var needed: f32 = 0;
    for (labels) |label| needed += theme.bodyFont().textSize(label).w + 2 * (theme.sizing.control_padding_x + theme.sizing.control_border) + theme.spacing.action_gap;
    return dvui.box(src, .{ .dir = if (available >= needed) .horizontal else .vertical }, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = dvui.Rect.all(0), .margin = .{ .y = theme.spacing.row_gap, .h = theme.spacing.row_gap } });
}
pub fn failureText(failure: anyerror) []const u8 {
    return switch (failure) {
        error.InvalidProxyPort => "端口必须为 1 至 65535 的整数。",
        error.InvalidProxyAddress => "请检查代理主机、端口和绕过列表。",
        error.InvalidProxyUsername => "使用代理密码时必须填写用户名。",
        error.ProxyAuthenticationIncomplete => "认证信息尚未完整；请输入密码并点击更新密码，或清空用户名。",
        error.ProxyCredentialsNeedUpdate => "代理端点或用户名已更改；请重新输入并更新密码，或勾选移除已存密码后点击更新密码。",
        error.InvalidProxyPassword => "密码无效或超过 512 字节，请重新输入。",
        error.Busy => "代理操作进行中，请稍候或取消。",
        error.RecoveryRequired, error.ConfigPublicationUncertain => "请先恢复代理凭据状态，再保存设置。",
        error.Unavailable, error.ProxyControllerUnavailable => "系统凭据库或代理服务不可用，密码未保存。",
        error.Denied => "系统凭据库拒绝访问，密码未保存。",
        error.NotFound => "已保存的代理密码不存在，请重新输入。",
        else => "代理操作失败；设置或密码可能尚未保存，请检查后重试。",
    };
}
fn statusText(snapshot: controller.Snapshot) []const u8 {
    return switch (snapshot.phase) {
        .idle => "",
        .saving => "正在保存代理设置…",
        .testing => "正在测试 HTTPS 连接（网络超时 30 秒）…",
        .detecting => "正在检测系统代理…",
        .cleaning => "设置已保存；正在等待旧任务结束并清理旧凭据…",
        .saved => "代理设置已保存。",
        .connected => "HTTPS 连接测试成功（使用当前草稿）。",
        .detected => "代理检测完成（尚未测试网络连接）。",
        .no_system_proxy => "未检测到系统代理，测试目标将直连。",
        .cancelled => "代理操作已取消。",
        .recovery_required => if (snapshot.committed) "代理设置已保存，旧凭据清理失败；请恢复。" else "代理保存未确认，请恢复凭据状态。",
        .failed => switch (snapshot.stage) {
            .detection => "代理检测失败，不能判定为未配置。",
            .connection => "HTTPS 连接测试失败，请检查代理、认证和网络。",
            .credentials => "系统凭据操作失败，密码未确认保存。",
            .settings => "代理设置保存失败。",
        },
    };
}
fn sourceText(source: controller.Source) []const u8 {
    return switch (source) {
        .none => "来源：无代理配置",
        .environment => "来源：环境变量",
        .windows => "来源：Windows 系统设置",
        .macos => "来源：macOS 系统设置",
        .gnome => "来源：GNOME 系统设置",
        .kde => "来源：KDE 系统设置",
        .manual => "来源：手动设置",
        .explicit => "来源：显式代理",
    };
}
fn copyText(buffer: []u8, text: []const u8) !void {
    if (text.len >= buffer.len) return error.InvalidProxyAddress;
    @memcpy(buffer[0..text.len], text);
}

/// Adapted from the existing masked key editor. Passwords also allow spaces and
/// Unicode. Never preload a saved secret; block copy/cut/context and accessibility values.
pub const PasswordEditor = struct {
    bytes: [513]u8 = @splat(0),
    len: usize = 0,
    invalid: bool = false,
    pub fn reset(self: *PasswordEditor) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
        self.invalid = false;
    }
    pub fn borrow(self: *const PasswordEditor) !?[]const u8 {
        if (self.invalid or !validPassword(self.bytes[0..self.len])) return error.InvalidProxyPassword;
        return if (self.len == 0) null else self.bytes[0..self.len];
    }
    fn sync(self: *PasswordEditor, entry: *dvui.TextEntryWidget) void {
        self.len = entry.len;
        std.crypto.secureZero(u8, self.bytes[self.len..]);
    }
    fn insert(self: *PasswordEditor, entry: *dvui.TextEntryWidget, text: []const u8, selected: bool) void {
        const selection = entry.textLayout.selectionGet(entry.len);
        if (selection.end < selection.start or !validPassword(text) or text.len > 512 - (entry.len - (selection.end - selection.start))) {
            self.invalid = true;
            return;
        }
        entry.textTyped(text, selected);
        self.invalid = false;
    }
    pub fn draw(self: *PasswordEditor, enabled: bool) bool {
        var entry: dvui.TextEntryWidget = undefined;
        var opts = components.entryOptions("代理密码", .{});
        opts.role = .password_input;
        opts.id_extra = @intFromPtr(self);
        opts.name = "ProxyPasswordEditor";
        opts.tab_index = if (enabled) null else 0;
        entry.init(@src(), .{ .text = .{ .buffer = self.bytes[0..512] }, .password_char = "*", .multiline = false, .cache_layout = false, .tree_sitter = null }, opts);
        defer entry.deinit();
        lockExports(&entry);
        if (entry.data().accesskit_node()) |node| {
            dvui.AccessKit.nodeClearValue(node);
            inline for (.{ "replace_selected_text", "scroll_into_view", "show_context_menu", "custom_action" }) |name| dvui.AccessKit.nodeRemoveAction(node, @field(dvui.AccessKit.Action, name));
            if (!enabled) dvui.AccessKit.nodeSetDisabled(node);
        }
        var cancelled = false;
        if (enabled) for (dvui.events()) |*event| {
            const matched = entry.matchEvent(event);
            lockExports(&entry);
            if (!matched) continue;
            if (cancelled) {
                if (event.evt == .text and event.evt.text.action == .value) std.crypto.secureZero(u8, event.evt.text.action.value.txt);
                event.handle(@src(), entry.data());
                continue;
            }
            switch (event.evt) {
                .text => |text| if (text.action == .value) {
                    const value = text.action.value;
                    defer std.crypto.secureZero(u8, value.txt);
                    event.handle(@src(), entry.data());
                    self.insert(&entry, value.txt, value.selected);
                    continue;
                },
                .key => |key| {
                    if (key.matchBind("copy") or key.matchBind("cut")) {
                        event.handle(@src(), entry.data());
                        continue;
                    }
                    if (key.matchBind("paste")) {
                        event.handle(@src(), entry.data());
                        if (key.action == .down) self.insert(&entry, dvui.clipboardText(), false);
                        continue;
                    }
                    if (key.code == .escape and key.action == .down) {
                        event.handle(@src(), entry.data());
                        cancelled = true;
                        self.reset();
                        entry.setLen(0);
                        entry.textLayout.selection.* = .{};
                        continue;
                    }
                },
                .mouse => |mouse| if (mouse.action == .press and mouse.button == .middle) {
                    event.handle(@src(), entry.data());
                    dvui.focusWidget(entry.data().id, null, event.num);
                    self.insert(&entry, dvui.primarySelectionText(), false);
                    continue;
                },
                else => {},
            }
            const before = entry.len;
            entry.processEvent(event);
            if (entry.len != before) self.invalid = false;
            lockExports(&entry);
        };
        self.sync(&entry);
        entry.draw();
        lockExports(&entry);
        return entry.text_changed or cancelled;
    }
};
fn lockExports(entry: *dvui.TextEntryWidget) void {
    entry.textLayout.state.te_show_context_menu = false;
    entry.textLayout.process_events_in_deinit = false;
}
fn validPassword(bytes: []const u8) bool {
    if (bytes.len > 512 or !std.unicode.utf8ValidateSlice(bytes)) return false;
    var iterator = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (iterator.nextCodepoint()) |cp| if (cp < 32 or (cp >= 127 and cp <= 159)) return false;
    return true;
}

test "proxy draft owns input validates bounds and preserves latest reference" {
    var host = "localhost".*;
    var draft = try Draft.init(.{ .mode = .manual, .host = &host, .username = "user" });
    defer draft.deinit();
    host[0] = 'X';
    const reference = "0123456789abcdef0123456789abcdef";
    const committed: proxy.Settings = .{ .host = "localhost", .username = "user", .credential_ref = reference };
    try std.testing.expectEqualStrings("localhost", (try draft.value(committed)).host);
    try std.testing.expectEqualStrings(reference, (try draft.value(committed)).credential_ref.?);
    @memset(&draft.port, 0);
    try copyText(&draft.port, "65536");
    try std.testing.expectError(error.InvalidProxyPort, draft.value(.{}));
    @memset(&draft.port, 0);
    try copyText(&draft.port, "0");
    try std.testing.expectError(error.InvalidProxyAddress, draft.value(.{}));
}

test "proxy password accepts unicode and spaces rejects controls and resets" {
    var editor: PasswordEditor = .{};
    const secret = "密码 with spaces";
    @memcpy(editor.bytes[0..secret.len], secret);
    editor.len = secret.len;
    try std.testing.expectEqualStrings(secret, (try editor.borrow()).?);
    try std.testing.expect(!validPassword("bad\npassword"));
    editor.reset();
    for (editor.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect((try editor.borrow()) == null);
}

test "proxy autosave debounces flushes and preserves unrelated latest settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var store = try config.Store.init(std.testing.allocator, std.testing.io, path[0..len]);
    defer store.deinit();
    var draft = try Draft.init(store.snapshot().settings.proxy);
    defer draft.deinit();
    draft.mode = .system;
    draft.frame_time_ns = 100;
    draft.edited();
    draft.frame_time_ns = draft.deadline_ns - 1;
    draft.finish(null, &store);
    try std.testing.expectEqual(proxy.Mode.direct, store.snapshot().settings.proxy.mode);
    var latest = store.snapshot().*;
    latest.settings.default_memory_mb = 4096;
    try store.update(latest);
    draft.frame_time_ns += 1;
    draft.finish(null, &store);
    try std.testing.expectEqual(proxy.Mode.system, store.snapshot().settings.proxy.mode);
    try std.testing.expectEqual(@as(u32, 4096), store.snapshot().settings.default_memory_mb);
    try std.testing.expect(!draft.dirty);
    draft.mode = .manual;
    draft.edited();
    draft.flush();
    draft.finish(null, &store);
    try std.testing.expectEqual(proxy.Mode.manual, store.snapshot().settings.proxy.mode);
}

test "proxy autosave holds secrets and stops failed group until retry or edit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var store = try config.Store.init(std.testing.allocator, std.testing.io, path[0..len]);
    defer store.deinit();
    var draft = try Draft.init(store.snapshot().settings.proxy);
    defer draft.deinit();
    draft.mode = .manual;
    draft.edited();
    draft.password.bytes[0] = 's';
    draft.password.len = 1;
    draft.flush();
    draft.finish(null, &store);
    try std.testing.expectEqual(@as(usize, 1), draft.password.len);
    try std.testing.expectEqual(proxy.Mode.direct, store.snapshot().settings.proxy.mode);
    draft.clearSecret();
    try std.testing.expect(draft.password_pending);
    draft.finish(null, &store);
    try std.testing.expectEqual(proxy.Mode.direct, store.snapshot().settings.proxy.mode);
    // Simulate explicit abandonment of the secret edit for the remaining group tests.
    draft.password_pending = false;
    @memset(&draft.port, 0);
    try copyText(&draft.port, "bad");
    draft.finish(null, &store);
    try std.testing.expectEqual(error.InvalidProxyPort, draft.failure.?);
    @memset(&draft.port, 0);
    try copyText(&draft.port, "8080");
    draft.flush();
    draft.finish(null, &store);
    try std.testing.expectEqual(proxy.Mode.direct, store.snapshot().settings.proxy.mode);
    draft.command = .retry;
    draft.finish(null, &store);
    draft.finish(null, &store);
    try std.testing.expectEqual(@as(u16, 8080), store.snapshot().settings.proxy.port);
    try std.testing.expect(!draft.dirty);
    try copyText(&draft.username, "user");
    draft.edited();
    draft.flush();
    draft.finish(null, &store);
    try std.testing.expectEqual(error.ProxyAuthenticationIncomplete, draft.failure.?);
    try std.testing.expectEqualStrings("", store.snapshot().settings.proxy.username);
    @memset(&draft.username, 0);
    draft.edited();
    draft.flush();
    draft.finish(null, &store);
    try std.testing.expect(!draft.dirty);
}

test "proxy completion acknowledges submitted revision without clearing newer edits" {
    var worker = try controller.Controller.init(std.testing.allocator, std.testing.io, .{});
    defer worker.deinit();
    var draft = try Draft.init(.{});
    defer draft.deinit();
    draft.edited();
    draft.submitted_revision = 0;
    draft.submitted_edit_revision = draft.edit_revision;
    draft.edited();
    worker.revision = 1;
    draft.sync(&worker);
    try std.testing.expect(draft.dirty);
    try std.testing.expect(draft.submitted_revision == null);
    draft.submitted_revision = worker.revision;
    draft.submitted_edit_revision = draft.edit_revision;
    worker.revision += 1;
    draft.sync(&worker);
    try std.testing.expect(!draft.dirty);
    try std.testing.expect(draft.reload_committed);
    draft.edited();
    draft.submitted_revision = worker.revision;
    draft.submitted_edit_revision = draft.edit_revision;
    worker.failure = error.Denied;
    draft.sync(&worker);
    try std.testing.expect(draft.dirty);
    try std.testing.expect(draft.autosave_failed);
    draft.flush();
    try std.testing.expect(draft.autosave_failed);
    draft.edited();
    try std.testing.expect(!draft.autosave_failed);
}

test "proxy mode autosave ignores hidden invalid fields and preserves manual draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var store = try config.Store.init(std.testing.allocator, std.testing.io, path[0..len]);
    defer store.deinit();
    var draft = try Draft.init(store.snapshot().settings.proxy);
    defer draft.deinit();
    @memset(&draft.port, 0);
    try copyText(&draft.port, "bad");
    try copyText(&draft.username, "unfinished-user");
    draft.password.invalid = true;
    draft.password_pending = true;
    draft.remove_password = true;
    for ([_]proxy.Mode{ .system, .direct }) |mode| {
        draft.mode = mode;
        draft.edited();
        draft.flush();
        try draft.preflight(null, store.snapshot().settings, false);
        draft.finish(null, &store);
        try std.testing.expectEqual(mode, store.snapshot().settings.proxy.mode);
        try std.testing.expectEqual(@as(u16, 7890), store.snapshot().settings.proxy.port);
        try std.testing.expectEqualStrings("", store.snapshot().settings.proxy.username);
        try std.testing.expectEqualStrings("bad", std.mem.sliceTo(&draft.port, 0));
        try std.testing.expectEqualStrings("unfinished-user", std.mem.sliceTo(&draft.username, 0));
        try std.testing.expect(draft.password_pending and draft.password.invalid and draft.remove_password);
        try std.testing.expect(!draft.dirty);
    }
    draft.mode = .manual;
    try std.testing.expectError(error.InvalidProxyPort, draft.value(store.snapshot().settings.proxy));
}

test "proxy autosave without controller cannot rebind a saved secret" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var store = try config.Store.init(std.testing.allocator, std.testing.io, path[0..len]);
    defer store.deinit();
    var document = store.snapshot().*;
    document.settings.proxy = .{ .mode = .manual, .username = "user", .credential_ref = "0123456789abcdef0123456789abcdef" };
    try store.update(document);
    var draft = try Draft.init(store.snapshot().settings.proxy);
    defer draft.deinit();
    @memset(&draft.host, 0);
    try copyText(&draft.host, "other.example");
    draft.edited();
    draft.flush();
    draft.finish(null, &store);
    try std.testing.expectEqual(error.ProxyCredentialsNeedUpdate, draft.failure.?);
    try std.testing.expectEqualStrings("127.0.0.1", store.snapshot().settings.proxy.host);
    try std.testing.expectError(error.ProxyCredentialsNeedUpdate, draft.preflight(null, store.snapshot().settings, false));
}
