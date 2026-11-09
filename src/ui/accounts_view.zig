//! Native accounts picker. finish runs after root widgets close, before Window.end.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const accounts_manager = @import("../application/accounts_manager.zig");
const avatar_manager = @import("avatar_manager.zig");
const avatar_image = @import("avatar_image.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const Allocator = std.mem.Allocator;
const Manager = accounts_manager.Manager;
const R = dvui.Rect;

const Action = enum { add, edit, save, close_editor, select, ask_delete, ask_sign_out, confirm, close_confirm, start, cancel, close_login, copy_code, open_verification, open_uri, probe_remember, forget_remember, retry_cleanup, retry_publication, refresh };
const Pending = struct {
    action: Action,
    id: ?[]u8 = null,
    text: ?[]u8 = null,
    remember: bool = false,
    fn deinit(self: *Pending, a: Allocator) void {
        if (self.id) |v| a.free(v);
        if (self.text) |v| a.free(v);
    }
};
const Draft = struct {
    id: ?[]u8 = null,
    name: [255]u8 = @splat(0),
    fn deinit(self: *Draft, a: Allocator) void {
        if (self.id) |v| a.free(v);
        self.* = .{};
    }
};
const Confirmation = struct {
    id: []u8,
    sign_out: bool,
};

pub const Ui = struct {
    allocator: Allocator,
    pending: ?Pending = null,
    draft: Draft = .{},
    editor_open: bool = false,
    confirmation: ?Confirmation = null,
    login_open: bool = false,
    verification_open: bool = false,
    remember: bool = false,
    remember_probe: bool = false,
    failure: ?anyerror = null,
    open_url: *const fn ([]const u8) bool = nativeOpenUrl,

    pub fn init(a: Allocator) !Ui {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Ui) void {
        if (self.pending) |*p| p.deinit(self.allocator);
        self.draft.deinit(self.allocator);
        self.closeConfirmation();
        self.* = undefined;
    }
    fn closeConfirmation(self: *Ui) void {
        if (self.confirmation) |c| self.allocator.free(c.id);
        self.confirmation = null;
    }
    // Event text may belong to the frame arena or Store's old document.
    fn queue(self: *Ui, action: Action, id: ?[]const u8, text: ?[]const u8) void {
        if (self.pending != null) return;
        var p: Pending = .{ .action = action, .remember = self.remember };
        if (id) |v| p.id = self.allocator.dupe(u8, v) catch |err| {
            self.failure = err;
            return;
        };
        if (text) |v| p.text = self.allocator.dupe(u8, v) catch |err| {
            p.deinit(self.allocator);
            self.failure = err;
            return;
        };
        self.pending = p;
    }
};

fn findAccount(doc: *const config.Document, id: []const u8) ?config.Account {
    for (doc.accounts) |account| if (std.mem.eql(u8, id, account.id)) return account;
    return null;
}
fn selected(doc: *const config.Document, id: []const u8) bool {
    return if (doc.selected_account) |v| std.mem.eql(u8, v, id) else false;
}
fn canRefresh(account: config.Account, manager: *const Manager) bool {
    if (account.kind != .microsoft) return false;
    if (account.credential_ref != null) return true;
    const now_ms: u64 = @intCast(@max(0, @divFloor(std.Io.Clock.awake.now(manager.io).nanoseconds, 1_000_000)));
    const identity = manager.launchIdentity(now_ms) catch return false;
    return identity.kind == .microsoft and std.mem.eql(u8, identity.id, account.id) and std.mem.eql(u8, identity.uuid, account.uuid);
}
fn validName(name: []const u8) bool {
    if (name.len < 3 or name.len > 16) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}
fn validVerificationUri(uri: []const u8) bool {
    // Keep the exact private allowlist in core/auth.zig; never allow a prefix.
    for ([_][]const u8{ "https://microsoft.com/devicelogin", "https://www.microsoft.com/devicelogin", "https://www.microsoft.com/link" }) |allowed| {
        if (std.mem.eql(u8, uri, allowed)) return true;
    }
    return false;
}
fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(dvui.currentWindow().arena(), format, args) catch "";
}
fn phaseText(phase: accounts_manager.Phase) []const u8 {
    return switch (phase) {
        .idle => "未登录",
        .starting => "正在连接",
        .device_pending => "等待 Microsoft 授权",
        .slow_down => "等待下一次验证",
        .refreshing => "正在刷新登录",
        .authenticated => "已登录",
        .signing_out => "正在退出登录",
        .cleanup => "正在清理凭据",
        .cancelled => "已取消",
        .expired => "验证码已过期",
        .failed => "登录失败",
    };
}
fn errorText(failure: anyerror) []const u8 {
    return switch (failure) {
        error.SelectionChanged => "所选账户已更改，请关闭后重新编辑",
        error.EditorRequired => "请先打开所选账户的编辑窗口",
        error.Busy => "账户操作尚未完成，请稍后重试",
        error.InvalidAccountName => "用户名须为 3–16 位字母、数字或下划线",
        error.DuplicateUuid => "此账户已存在，请直接选择已有账户",
        error.AccountNotFound => "账户不存在，请重新选择",
        error.Unconfigured => "请在设置中配置 Microsoft 客户端 ID，然后重试登录",
        error.OpenVerificationFailed => "无法打开浏览器，请手动访问下方验证网址并输入验证码",
        else => fmt("操作失败：{s}", .{@errorName(failure)}),
    };
}

pub fn draw(ui: *Ui, store: *config.Store, manager: *Manager, avatars: ?*avatar_manager.Manager) void {
    const doc = store.snapshot();
    const snapshot = manager.snapshot();
    const controls_busy = snapshot.busy or snapshot.publication_pending;
    {
        const header = components.toolbar(@src());
        defer header.deinit();
        components.title(@src(), "选择账户");
        if (doc.selected_account) |id| {
            if (findAccount(doc, id)) |account| {
                if (components.iconButton(@src(), "编辑账户", dvui.entypo.edit, .{ .standalone = true, .enabled = !controls_busy, .tag = "account-edit" })) ui.queue(.edit, account.id, null);
            }
        }
        if (components.iconButton(@src(), "添加账户", dvui.entypo.plus, .{ .standalone = true, .enabled = !controls_busy, .tag = "account-add" })) ui.queue(.add, null, null);
    }
    {
        const scroll = components.scrollBody(@src());
        defer scroll.deinit();
        if (!ui.editor_open and !ui.login_open and ui.confirmation == null) {
            if (ui.failure) |err| components.text(@src(), errorText(err), theme.colors.danger);
            if (snapshot.failure) |err| components.text(@src(), errorText(err), theme.colors.danger);
        }
        if (snapshot.busy) {
            components.text(@src(), phaseText(snapshot.phase), theme.colors.accent);
            if (components.button(@src(), "取消操作", .{
                .standalone = true,
            })) ui.queue(.cancel, null, null);
        }
        if (doc.accounts.len == 0) components.emptyState(@src(), "暂无账户，点击右上角 ＋ 添加");
        var cards = @import("card_grid.zig").init(@src(), doc.accounts.len, .{ .min_width = theme.style.layout.account_min_width, .max_columns = theme.style.layout.account_columns, .tag = "account-cards" });
        for (doc.accounts, 0..) |account, index| {
            const cell = cards.cell(@src(), index, account.id);
            defer cell.deinit();
            const initial = account.name[0..@min(account.name.len, std.unicode.utf8ByteSequenceLength(if (account.name.len > 0) account.name[0] else ' ') catch 1)];
            var fallback: ?avatar_image.Face = if (avatars == null) avatar_image.defaultFace(dvui.currentWindow().arena(), account.uuid) catch null else null;
            const face = if (avatars) |cache| cache.face(account) else if (fallback) |*local| local else null;
            var visible = false;
            if (components.selectionCard(@src(), account.id, account.name, .{
                .selected = selected(doc, account.id),
                .enabled = !snapshot.busy,
                .width = cards.cardWidth(index),
                .height = theme.style.cards.account_height,
                .compact = true,
                .stretch = true,
                .bounded_text = true,
                .description = if (account.kind == .offline) "离线账户" else "微软账户",
                .avatar_text = initial,
                .avatar_size = theme.style.cards.avatar,
                .avatar_source = if (face) |pixels| avatar_image.source(pixels) else null,
                .avatar_tag = fmt("account-avatar-{s}", .{account.id}),
                .visible = &visible,
                .tag = fmt("account-card-{s}", .{account.id}),
            })) ui.queue(.select, account.id, null);
            if (visible) if (avatars) |cache| cache.request(account) catch {};
        }
        cards.deinit();
        if (snapshot.cleanup_count != 0) {
            components.text(@src(), fmt("待清理凭据：{d}", .{snapshot.cleanup_count}), theme.colors.muted);
            if (components.button(@src(), "重试清理", .{ .standalone = true, .enabled = !snapshot.busy })) ui.queue(.retry_cleanup, null, null);
        }
        if (snapshot.publication_pending) {
            components.text(@src(), "账户保存未完成", theme.colors.danger);
            if (components.button(@src(), "重试保存", .{ .standalone = true, .enabled = !snapshot.busy })) ui.queue(.retry_publication, null, null);
        }
    }
    if (avatars) |cache| {
        const delay_ms = cache.retryDelayMilliseconds();
        if (delay_ms != std.math.maxInt(u32)) dvui.timer(dvui.parentGet().data().id.update("account-avatar-poll"), @intCast(@min(@as(u64, delay_ms) * 1000, std.math.maxInt(i32))));
    }
    const now_ms: u64 = @intCast(@max(0, std.Io.Clock.awake.now(manager.io).toMilliseconds()));
    drawDialogs(ui, doc, snapshot, now_ms);
}

/// Presentation only: queues user intent; callers decide whether to execute it.
pub fn drawDialogs(ui: *Ui, doc: *const config.Document, snapshot: accounts_manager.Snapshot, now_ms: u64) void {
    const busy = snapshot.busy or snapshot.publication_pending;
    if (ui.editor_open) drawEditor(ui, doc, busy);
    if (ui.confirmation != null) drawConfirmation(ui, doc, busy);
    if (ui.login_open) drawLogin(ui, snapshot, now_ms);
}

fn drawEditor(ui: *Ui, doc: *const config.Document, busy: bool) void {
    const adding = ui.draft.id == null;
    const account = if (ui.draft.id) |id| findAccount(doc, id) else null;
    const current = if (account) |value| selected(doc, value.id) else false;
    const microsoft = if (account) |value| value.kind == .microsoft else false;
    const enabled = !busy and current;
    const height = (if (microsoft) theme.style.dialogs.microsoft_account_height else theme.style.dialogs.account_height) +
        (if (ui.failure != null) theme.style.dialogs.error_height else @as(f32, 0));
    const window = components.modal(@src(), if (adding) "添加账户" else if (microsoft) "编辑微软账户" else "编辑离线账户", height);
    defer window.deinit();
    var save_clicked = false;
    {
        const actions = components.modalActions(@src(), 3);
        defer actions.deinit();
        if (actions.action(@src(), 0, "取消", .{ .tag = "account-cancel" })) ui.queue(.close_editor, null, null);
        if (!adding) {
            if (actions.action(@src(), 1, "删除", .{ .enabled = enabled, .destructive = true, .tag = "account-delete" })) ui.queue(if (microsoft) .ask_sign_out else .ask_delete, ui.draft.id, null);
        }
        if (microsoft) {
            if (actions.action(@src(), 2, "退出登录", .{ .enabled = enabled, .tag = "account-sign-out" })) ui.queue(.ask_sign_out, ui.draft.id, null);
        } else {
            save_clicked = actions.action(@src(), if (adding) 1 else 2, if (adding) "离线登录" else "保存", .{ .enabled = !busy and (adding or current), .primary = !adding, .tag = "account-offline-login" });
        }
        if (adding) {
            if (actions.action(@src(), 2, "微软登录", .{ .enabled = !busy, .primary = true, .tag = "account-microsoft-login" })) ui.queue(.start, null, null);
        }
    }
    const scroll = components.scrollBody(@src());
    defer scroll.deinit();
    if (adding) {
        _ = components.field(@src(), "用户名或者邮箱", &ui.draft.name, .{ .tag = "account-name", .gap_after = 0 });
    } else if (account) |value| {
        if (microsoft) {
            const information = components.modalSection(@src(), .{ .min_height = 248, .gap_after = 0, .tag = "account-microsoft-details" });
            defer information.deinit();
            components.text(@src(), "用户名", theme.colors.muted);
            _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.card_gap) });
            dvui.labelNoFmt(@src(), value.name, .{ .ellipsize = true }, .{ .font = theme.headingFont(), .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = theme.spacing.card_gap } });
            components.text(@src(), "UUID", theme.colors.muted);
            _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.card_gap) });
            components.hint(@src(), value.uuid);
            _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.card_gap) });
            components.text(@src(), "微软账户信息由登录同步。删除账户或退出登录将移除此账户，并清理已保存的登录凭据。", theme.colors.muted);
        } else {
            _ = components.field(@src(), "用户名", &ui.draft.name, .{ .tag = "account-name", .gap_after = 0 });
        }
        if (!current) components.text(@src(), "所选账户已更改，请关闭后重新编辑", theme.colors.danger);
    } else components.text(@src(), "账户不存在，请关闭后重新选择", theme.colors.danger);
    // Footer layout runs first; copy only after the field handles this frame’s events.
    if (save_clicked) ui.queue(.save, ui.draft.id, std.mem.sliceTo(&ui.draft.name, 0));
    if (ui.failure) |err| {
        _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.card_gap) });
        components.text(@src(), errorText(err), theme.colors.danger);
    }
}
fn drawConfirmation(ui: *Ui, doc: *const config.Document, busy: bool) void {
    const confirmation = ui.confirmation.?;
    const window = components.modal(@src(), if (confirmation.sign_out) "微软账户退出登录确认" else "删除离线账户确认", if (confirmation.sign_out) theme.style.dialogs.sign_out_height else theme.style.dialogs.account_confirm_height);
    defer window.deinit();
    const account = findAccount(doc, confirmation.id);
    switch (components.modalFormActions(@src(), .{ .save_label = "确认", .save_enabled = !busy and account != null and selected(doc, confirmation.id) })) {
        .save => ui.queue(.confirm, confirmation.id, null),
        .cancel => ui.queue(.close_confirm, null, null),
        .none => {},
    }
    const scroll = components.scrollBody(@src());
    defer scroll.deinit();
    const information = components.modalSection(@src(), .{ .min_height = if (confirmation.sign_out) 112 else 72, .gap_after = 0, .tag = "account-confirm-information" });
    defer information.deinit();
    if (account) |value| {
        dvui.labelNoFmt(@src(), if (confirmation.sign_out) fmt("退出「{s}」的登录？", .{value.name}) else fmt("删除账户「{s}」？", .{value.name}), .{ .ellipsize = true }, .{ .font = theme.headingFont(), .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = if (value.kind == .microsoft) theme.spacing.card_gap else 0 } });
        if (value.kind == .microsoft) components.text(@src(), "此操作将移除账户，并清理已保存的登录凭据。", theme.colors.muted);
    } else components.text(@src(), "账户不存在", theme.colors.danger);
    if (ui.failure) |err| components.text(@src(), errorText(err), theme.colors.danger);
}
fn drawLogin(ui: *Ui, snapshot: accounts_manager.Snapshot, now_ms: u64) void {
    const window = components.modal(@src(), if (ui.verification_open) "微软登录 · 等待授权" else "微软登录 · 验证码", if (ui.verification_open) theme.style.dialogs.device_wait_height else theme.style.dialogs.device_code_height);
    defer window.deinit();
    switch (components.modalFormActions(@src(), .{ .cancel_label = "返回", .save_label = "关闭" })) {
        .cancel => ui.queue(.close_login, null, null),
        .save => ui.queue(.close_editor, null, null),
        .none => {},
    }
    const scroll = components.scrollBody(@src());
    defer scroll.deinit();
    components.text(@src(), "在浏览器中登录微软账户，并输入下方验证码。授权完成后将自动登录。", theme.colors.muted);
    _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.card_gap) });
    const information = components.modalSection(@src(), .{ .min_height = if (ui.verification_open) 248 else 200, .gap_after = 0, .tag = "account-device-information" });
    defer information.deinit();
    components.text(@src(), phaseText(snapshot.phase), if (snapshot.phase == .authenticated) theme.colors.accent else theme.colors.muted);
    if (snapshot.device) |device| {
        const usable = (snapshot.phase == .device_pending or snapshot.phase == .slow_down) and now_ms < device.expires_at_ms;
        _ = dvui.spacer(@src(), .{ .min_size_content = .height(theme.spacing.card_gap) });
        dvui.labelNoFmt(@src(), device.userCode(), .{}, .{ .font = theme.fontSized(24), .min_size_content = .{ .w = 184, .h = 36 }, .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 }, .border = R.all(0), .margin = .{ .h = 18 }, .background = true, .color_fill = .{ .color = theme.colors.inset }, .tag = "account-device-code" });
        components.hint(@src(), device.verificationUri());
        components.hint(@src(), fmt("有效期剩余 {d} 秒 · 下次检查 {d} 秒后", .{ ((device.expires_at_ms -| now_ms) + 999) / 1000, ((device.next_poll_ms -| now_ms) + 999) / 1000 }));
        {
            const actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = R.all(0), .background = false });
            defer actions.deinit();
            if (components.button(@src(), "复制验证码", .{ .enabled = usable, .placement = .footer, .tag = "account-copy-code" })) ui.queue(.copy_code, null, device.userCode());
            _ = dvui.spacer(@src(), .{ .min_size_content = .width(theme.style.dialogs.action_gap) });
            if (components.button(@src(), if (ui.verification_open) "重新打开验证页" else "打开验证页", .{ .enabled = usable, .primary = true, .placement = .footer, .min_width = if (ui.verification_open) 184 else 144, .tag = "account-open-verification" })) ui.queue(.open_verification, null, null);
        }
    }
    if (snapshot.failure) |err| components.text(@src(), errorText(err), theme.colors.danger);
    if (ui.failure) |err| components.text(@src(), errorText(err), theme.colors.danger);
    const unconfigured = if (ui.failure) |err| err == error.Unconfigured else false;
    if (!snapshot.busy and !snapshot.publication_pending and (snapshot.phase == .failed or snapshot.phase == .expired or snapshot.phase == .cancelled or unconfigured)) {
        if (components.button(@src(), "重试登录", .{ .primary = true, .tag = "account-login-retry" })) ui.queue(.start, null, null);
    }
    if (snapshot.busy or snapshot.phase == .device_pending or snapshot.phase == .slow_down) dvui.timer(dvui.parentGet().data().id.update("account-login-poll"), 250_000);
}

fn nativeOpenUrl(uri: []const u8) bool {
    return dvui.openURL(.{ .url = uri });
}

fn openVerification(ui: *Ui, uri: []const u8) !void {
    if (!validVerificationUri(uri)) return error.InvalidVerificationUri;
    if (!ui.open_url(uri)) return error.OpenVerificationFailed;
    ui.verification_open = true;
}

fn cancelActiveLogin(manager: *Manager) void {
    const snapshot = manager.snapshot();
    // cancel() clears the transient launch token, so success must survive closing.
    if (snapshot.phase != .authenticated and (snapshot.busy or snapshot.device != null or snapshot.publication_pending)) manager.cancel();
}

/// Parent must tick manager before root draw, and call this before Window.end.
pub fn finish(ui: *Ui, store: *config.Store, manager: *Manager) void {
    if (ui.remember_probe) {
        const snapshot = manager.snapshot();
        if (!snapshot.busy) {
            ui.remember_probe = false;
            ui.remember = snapshot.remember_available;
            if (!ui.remember) ui.failure = snapshot.failure orelse error.SecureStorageUnavailable;
        }
    }
    var pending = ui.pending orelse return;
    ui.pending = null;
    defer pending.deinit(ui.allocator);
    apply(ui, store, manager, pending) catch |err| {
        ui.failure = err;
        return;
    };
    ui.failure = null;
}
fn apply(ui: *Ui, store: *config.Store, manager: *Manager, pending: Pending) !void {
    switch (pending.action) {
        .add => {
            ui.draft.deinit(ui.allocator);
            ui.login_open = false;
            ui.verification_open = false;
            ui.editor_open = true;
        },
        .edit => {
            const account = findAccount(store.snapshot(), pending.id.?) orelse return error.AccountNotFound;
            if (!selected(store.snapshot(), account.id)) return error.SelectionChanged;
            var draft: Draft = .{};
            draft.id = try ui.allocator.dupe(u8, account.id);
            const count = @min(account.name.len, draft.name.len - 1);
            @memcpy(draft.name[0..count], account.name[0..count]);
            ui.draft.deinit(ui.allocator);
            ui.draft = draft;
            ui.editor_open = true;
        },
        .save => {
            const name = pending.text.?;
            if (!validName(name)) return error.InvalidAccountName;
            if (pending.id) |id| {
                const account = findAccount(store.snapshot(), id) orelse return error.AccountNotFound;
                if (!selected(store.snapshot(), id)) return error.SelectionChanged;
                if (account.kind != .offline) return error.NotOfflineAccount;
                const snapshot = manager.snapshot();
                if (snapshot.busy or snapshot.publication_pending) return error.Busy;
                try manager.editOffline(store, id, name);
            } else try manager.loginOffline(store, name);
            ui.editor_open = false;
            ui.draft.deinit(ui.allocator);
        },
        .close_editor => {
            if (ui.login_open) cancelActiveLogin(manager);
            ui.editor_open = false;
            ui.login_open = false;
            ui.verification_open = false;
            ui.draft.deinit(ui.allocator);
        },
        .select => try manager.select(store, pending.id.?),
        .ask_delete, .ask_sign_out => {
            const account = findAccount(store.snapshot(), pending.id.?) orelse return error.AccountNotFound;
            if (!selected(store.snapshot(), account.id)) return error.SelectionChanged;
            if (!ui.editor_open or ui.draft.id == null or !std.mem.eql(u8, ui.draft.id.?, account.id)) return error.EditorRequired;
            if (pending.action == .ask_sign_out and account.kind != .microsoft) return error.NotMicrosoftAccount;
            if (pending.action == .ask_delete and account.kind != .offline) return error.NotOfflineAccount;
            const id = try ui.allocator.dupe(u8, account.id);
            ui.closeConfirmation();
            ui.confirmation = .{ .id = id, .sign_out = pending.action == .ask_sign_out };
        },
        .confirm => {
            const c = ui.confirmation orelse return error.ConfirmationRequired;
            if (!std.mem.eql(u8, c.id, pending.id.?)) return error.SelectionChanged;
            _ = findAccount(store.snapshot(), c.id) orelse return error.AccountNotFound;
            if (!selected(store.snapshot(), c.id)) return error.SelectionChanged;
            const snapshot = manager.snapshot();
            if (snapshot.busy or snapshot.publication_pending) return error.Busy;
            if (c.sign_out) try manager.signOut(store, c.id) else try manager.removeOffline(store, c.id);
            ui.closeConfirmation();
            ui.editor_open = false;
            ui.draft.deinit(ui.allocator);
        },
        .close_confirm => ui.closeConfirmation(),
        .start => {
            ui.editor_open = false;
            ui.login_open = true;
            ui.verification_open = false;
            try manager.startDeviceRemember(store, pending.remember);
        },
        .open_verification => {
            const snapshot = manager.snapshot();
            const device = snapshot.device orelse return error.InvalidState;
            if (snapshot.phase != .device_pending and snapshot.phase != .slow_down) return error.InvalidState;
            const now_ms: u64 = @intCast(@max(0, std.Io.Clock.awake.now(manager.io).toMilliseconds()));
            if (now_ms >= device.expires_at_ms) return error.AuthorizationExpired;
            try openVerification(ui, device.verificationUri());
        },
        .cancel => manager.cancel(),
        .close_login => {
            const succeeded = manager.snapshot().phase == .authenticated;
            cancelActiveLogin(manager);
            ui.login_open = false;
            ui.verification_open = false;
            ui.editor_open = !succeeded;
            if (succeeded) ui.draft.deinit(ui.allocator);
        },
        .copy_code => dvui.clipboardTextSet(pending.text.?),
        .open_uri => {
            try openVerification(ui, pending.text.?);
        },
        .probe_remember => {
            ui.remember = false;
            try manager.probeRemember();
            ui.remember_probe = true;
        },
        .forget_remember => ui.remember = false,
        .retry_cleanup => try manager.retryCleanup(store),
        .retry_publication => try manager.retryPublication(store),
        .refresh => {
            const doc = store.snapshot();
            if (!selected(doc, pending.id.?)) return error.SelectionChanged;
            const account = findAccount(doc, pending.id.?) orelse return error.AccountNotFound;
            if (!canRefresh(account, manager)) return error.CredentialUnavailable;
            ui.login_open = true;
            try manager.refreshSelected(store);
        },
    }
}

test "offline names validate exact ASCII boundaries" {
    for ([_][]const u8{ "abc", "Player_1", "0123456789abcdef" }) |v| try std.testing.expect(validName(v));
    for ([_][]const u8{ "", "ab", "0123456789abcdefg", "a b", "a-b", "玩家名", "abc\n" }) |v| try std.testing.expect(!validName(v));
}
test "verification URLs mirror exact core allowlist" {
    for ([_][]const u8{ "https://microsoft.com/devicelogin", "https://www.microsoft.com/devicelogin", "https://www.microsoft.com/link" }) |v| try std.testing.expect(validVerificationUri(v));
    for ([_][]const u8{ "http://www.microsoft.com/link", "https://www.microsoft.com/link?code=x", "https://www.microsoft.com/link/", "https://www.microsoft.com/link.evil", "https://microsoft.com/link", "https://login.microsoftonline.com/", "https://www.microsoft.com@evil.test/link" }) |v| try std.testing.expect(!validVerificationUri(v));
}
test "pending strings survive borrowed frame and Store buffers" {
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    var id = [_]u8{ 'i', 'd', '-', 'a' };
    var name = [_]u8{ 'A', 'b', 'c' };
    ui.queue(.save, &id, &name);
    @memset(&id, 'x');
    @memset(&name, 'x');
    try std.testing.expectEqualStrings("id-a", ui.pending.?.id.?);
    try std.testing.expectEqualStrings("Abc", ui.pending.?.text.?);
    ui.queue(.cancel, null, null);
    try std.testing.expectEqual(Action.save, ui.pending.?.action);
    try std.testing.expect(!ui.remember);
}

test "accounts view editor and confirmation remain deferred and own metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var store = try config.Store.init(std.testing.allocator, std.testing.io, path[0..len]);
    defer store.deinit();
    try store.update(.{ .accounts = &.{.{ .id = "account-a", .name = "Player_A", .uuid = "00000000000000000000000000000000" }}, .selected_account = "account-a" });
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    // These UI-only commands must not inspect or call the manager.
    var manager: Manager = undefined;
    ui.queue(.edit, store.snapshot().accounts[0].id, null);
    try std.testing.expect(!ui.editor_open);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.editor_open);
    try std.testing.expectEqualStrings("account-a", ui.draft.id.?);
    try std.testing.expectEqualStrings("Player_A", std.mem.sliceTo(&ui.draft.name, 0));
    ui.queue(.ask_delete, store.snapshot().accounts[0].id, null);
    try std.testing.expect(ui.confirmation == null);
    finish(&ui, &store, &manager);
    try store.update(.{});
    try std.testing.expectEqualStrings("account-a", ui.draft.id.?);
    try std.testing.expectEqualStrings("account-a", ui.confirmation.?.id);
    ui.queue(.close_confirm, null, null);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.confirmation == null);
    ui.queue(.save, ui.draft.id, "ab");
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.InvalidAccountName, ui.failure.?);
    try std.testing.expect(ui.editor_open);
    ui.queue(.close_editor, null, null);
    finish(&ui, &store, &manager);
    try std.testing.expect(!ui.editor_open);
    try std.testing.expect(ui.draft.id == null);
}

const LoginFixture = struct {
    const auth = @import("../core/auth.zig");
    const credentials = @import("../core/credentials.zig");
    requests: usize = 0,
    service_calls: usize = 0,
    block_begin: bool = false,
    entered: std.atomic.Value(bool) = .init(false),
    saw_cancel: std.atomic.Value(bool) = .init(false),

    fn fixture(self: *LoginFixture) accounts_manager.Fixture {
        return .{
            .transport = .{ .ctx = self, .kind = .fixture, .supports_post = true, .request = request },
            .store = .{ .ctx = self, .vtable = &.{ .put = put, .get = get, .delete = delete } },
            .entropy = .{ .ctx = self, .fill = entropy },
            .journal = .{ .ctx = self, .stage = journal, .remove = journal, .references = references },
        };
    }
    fn request(ctx: *anyopaque, a: Allocator, req: auth.Request) auth.TransportError!auth.Response {
        const self: *LoginFixture = @ptrCast(@alignCast(ctx));
        self.entered.store(true, .release);
        if (self.block_begin) {
            const deadline = clockMs() + 3_000;
            while (clockMs() < deadline) {
                if (req.cancel) |cancel| if (cancel.cancelled()) {
                    self.saw_cancel.store(true, .release);
                    return error.Cancelled;
                };
                std.testing.io.sleep(.fromMilliseconds(1), .awake) catch return error.TransportFailure;
            }
            return error.Timeout;
        }
        const suffixes = [_][]const u8{ "/devicecode", "/token", "/user/authenticate", "/xsts/authorize", "/login_with_xbox", "/entitlements/mcstore", "/minecraft/profile" };
        const bodies = [_][]const u8{
            "{\"device_code\":\"fixture-device-secret\",\"user_code\":\"REAL-1234\",\"verification_uri\":\"https://www.microsoft.com/link\",\"expires_in\":900,\"interval\":1}",
            "{\"access_token\":\"fixture-msa\",\"refresh_token\":\"fixture-refresh\",\"expires_in\":3600,\"token_type\":\"Bearer\"}",
            "{\"Token\":\"fixture-xbl\",\"DisplayClaims\":{\"xui\":[{\"uhs\":\"123\"}]}}",
            "{\"Token\":\"fixture-xsts\",\"DisplayClaims\":{\"xui\":[{\"uhs\":\"123\"}]}}",
            "{\"access_token\":\"fixture-minecraft\",\"expires_in\":3600}",
            "{\"items\":[{\"name\":\"game_minecraft\"}]}",
            "{\"id\":\"00112233445566778899aabbccddeeff\",\"name\":\"FixturePlayer\"}",
        };
        const index = self.requests % bodies.len;
        if (!std.mem.endsWith(u8, req.url, suffixes[index])) return error.TransportFailure;
        if (index == 0 and std.mem.indexOf(u8, req.body, "client_id=fixture-client") == null) return error.TransportFailure;
        self.requests += 1;
        return .{ .status = 200, .body = try a.dupe(u8, bodies[index]) };
    }
    fn put(ctx: *anyopaque, _: []const u8, _: []const u8) credentials.Error!void {
        const self: *LoginFixture = @ptrCast(@alignCast(ctx));
        self.service_calls += 1;
        return error.Unavailable;
    }
    fn get(ctx: *anyopaque, _: Allocator, _: []const u8) credentials.Error!credentials.Secret {
        const self: *LoginFixture = @ptrCast(@alignCast(ctx));
        self.service_calls += 1;
        return error.Unavailable;
    }
    fn delete(ctx: *anyopaque, _: []const u8) credentials.Error!void {
        const self: *LoginFixture = @ptrCast(@alignCast(ctx));
        self.service_calls += 1;
        return error.Unavailable;
    }
    fn entropy(ctx: *anyopaque, _: []u8) error{EntropyUnavailable}!void {
        const self: *LoginFixture = @ptrCast(@alignCast(ctx));
        self.service_calls += 1;
        return error.EntropyUnavailable;
    }
    fn journal(ctx: *anyopaque, _: credentials.Reference) anyerror!void {
        const self: *LoginFixture = @ptrCast(@alignCast(ctx));
        self.service_calls += 1;
        return error.UnexpectedJournalAccess;
    }
    fn references(ctx: *anyopaque) []const credentials.Reference {
        const self: *LoginFixture = @ptrCast(@alignCast(ctx));
        self.service_calls += 1;
        return &.{};
    }
    fn clockMs() u64 {
        return @intCast(@max(0, std.Io.Clock.awake.now(std.testing.io).toMilliseconds()));
    }
    fn waitPhase(manager: *Manager, store: *config.Store, phase: accounts_manager.Phase) !void {
        const deadline = clockMs() + 5_000;
        while (clockMs() < deadline) {
            manager.tick(store);
            const snapshot = manager.snapshot();
            if (!snapshot.busy and snapshot.phase == phase) return;
            if (!snapshot.busy and snapshot.failure != null) return snapshot.failure.?;
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.LoginFixtureTimedOut;
    }
};

const BrowserFixture = struct {
    var calls: usize = 0;
    var succeeds: bool = false;
    fn open(uri: []const u8) bool {
        std.debug.assert(std.mem.eql(u8, uri, "https://www.microsoft.com/link"));
        calls += 1;
        return succeeds;
    }
};

test "accounts view missing client ID reports actionable real error without services or browser" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var store = try config.Store.init(std.testing.allocator, std.testing.io, root);
    defer store.deinit();
    var fake: LoginFixture = .{};
    var manager = try Manager.initWithOptions(std.testing.allocator, std.testing.io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    BrowserFixture.calls = 0;
    ui.open_url = BrowserFixture.open;
    ui.queue(.start, null, null);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.Unconfigured, ui.failure.?);
    try std.testing.expect(ui.login_open and !ui.editor_open);
    try std.testing.expect(manager.snapshot().device == null and !manager.snapshot().busy);
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.Unconfigured), "客户端 ID") != null);
    try std.testing.expectEqual(@as(usize, 0), fake.requests);
    try std.testing.expectEqual(@as(usize, 0), fake.service_calls);
    try std.testing.expectEqual(@as(usize, 0), BrowserFixture.calls);
}

test "accounts view production finish begins real fixture login validates browser and preserves success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var store = try config.Store.init(std.testing.allocator, std.testing.io, root);
    defer store.deinit();
    try store.update(.{ .settings = .{ .microsoft_client_id = "fixture-client" } });
    var fake: LoginFixture = .{};
    var manager = try Manager.initWithOptions(std.testing.allocator, std.testing.io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    @memcpy(ui.draft.name[0..18], "player@example.com");
    BrowserFixture.calls = 0;
    BrowserFixture.succeeds = false;
    ui.open_url = BrowserFixture.open;
    ui.queue(.start, null, null);
    finish(&ui, &store, &manager);
    try LoginFixture.waitPhase(&manager, &store, .device_pending);
    try std.testing.expectEqual(@as(usize, 1), fake.requests);
    const device = manager.snapshot().device.?;
    try std.testing.expectEqualStrings("REAL-1234", device.userCode());
    try std.testing.expectEqualStrings("https://www.microsoft.com/link", device.verificationUri());
    try std.testing.expect(device.expires_at_ms > device.next_poll_ms);
    try std.testing.expectEqual(@as(usize, 0), BrowserFixture.calls);
    ui.queue(.open_verification, null, null);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.OpenVerificationFailed, ui.failure.?);
    try std.testing.expect(!ui.verification_open);
    BrowserFixture.succeeds = true;
    ui.queue(.open_verification, null, null);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.verification_open);
    try std.testing.expectEqual(@as(usize, 2), BrowserFixture.calls);
    const bad_uri = "https://www.microsoft.com/link?redirect=evil";
    @memcpy(manager.device.?.uri[0..bad_uri.len], bad_uri);
    manager.device.?.uri_len = bad_uri.len;
    ui.queue(.open_verification, null, null);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.InvalidVerificationUri, ui.failure.?);
    try std.testing.expectEqual(@as(usize, 2), BrowserFixture.calls);
    manager.device = device;
    ui.queue(.close_login, null, null);
    finish(&ui, &store, &manager);
    try LoginFixture.waitPhase(&manager, &store, .cancelled);
    try std.testing.expect(ui.editor_open and !ui.login_open and !ui.verification_open);
    try std.testing.expectEqualStrings("player@example.com", std.mem.sliceTo(&ui.draft.name, 0));
    // Retry must execute a fresh begin, not redisplay the cancelled code.
    fake.requests = 0;
    ui.queue(.start, null, null);
    finish(&ui, &store, &manager);
    try LoginFixture.waitPhase(&manager, &store, .authenticated);
    try std.testing.expectEqual(@as(usize, 7), fake.requests);
    try std.testing.expectEqual(@as(usize, 1), store.snapshot().accounts.len);
    try std.testing.expectEqual(@as(usize, 0), fake.service_calls);
    const before = try manager.launchIdentity(LoginFixture.clockMs());
    try std.testing.expect(before.access_token != null);
    ui.queue(.close_editor, null, null);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(accounts_manager.Phase.authenticated, manager.snapshot().phase);
    try std.testing.expect((try manager.launchIdentity(LoginFixture.clockMs())).access_token != null);
    ui.login_open = true;
    ui.queue(.close_login, null, null);
    finish(&ui, &store, &manager);
    try std.testing.expect(!ui.login_open and !ui.editor_open);
    try std.testing.expect((try manager.launchIdentity(LoginFixture.clockMs())).access_token != null);
}

test "accounts view close editor cancels an active begin before publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var store = try config.Store.init(std.testing.allocator, std.testing.io, root);
    defer store.deinit();
    try store.update(.{ .settings = .{ .microsoft_client_id = "fixture-client" } });
    var fake: LoginFixture = .{ .block_begin = true };
    var manager = try Manager.initWithOptions(std.testing.allocator, std.testing.io, .{ .root = root, .fixture = fake.fixture() });
    defer manager.deinit();
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    ui.queue(.start, null, null);
    finish(&ui, &store, &manager);
    const deadline = LoginFixture.clockMs() + 2_000;
    while (!fake.entered.load(.acquire)) {
        if (LoginFixture.clockMs() >= deadline) return error.LoginFixtureTimedOut;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    ui.queue(.close_editor, null, null);
    finish(&ui, &store, &manager);
    try LoginFixture.waitPhase(&manager, &store, .cancelled);
    try std.testing.expect(fake.saw_cancel.load(.acquire));
    try std.testing.expect(!ui.login_open and !ui.editor_open);
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().accounts.len);
    try std.testing.expect(manager.session == null and manager.snapshot().device == null);
}

test "accounts view selected Microsoft editor keeps identity read-only and signout deferred" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var store = try config.Store.init(std.testing.allocator, std.testing.io, path[0..len]);
    defer store.deinit();
    const account: config.Account = .{ .id = "microsoft-fixture", .name = "FixturePlayer", .uuid = "00112233445566778899aabbccddeeff", .kind = .microsoft };
    try store.update(.{ .accounts = &.{account}, .selected_account = account.id });
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    // No authentication, native credentials, or manager mutation is needed to edit details.
    var manager: Manager = undefined;
    ui.queue(.edit, account.id, null);
    try std.testing.expect(!ui.editor_open);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.editor_open and ui.failure == null);
    try std.testing.expectEqualStrings(account.id, ui.draft.id.?);
    ui.queue(.save, ui.draft.id, "ChangedName");
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.NotOfflineAccount, ui.failure.?);
    try std.testing.expect(ui.editor_open);
    ui.queue(.ask_sign_out, ui.draft.id, null);
    try std.testing.expect(ui.confirmation == null);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.confirmation.?.sign_out);
    try std.testing.expectEqualStrings(account.id, ui.confirmation.?.id);
    try std.testing.expectEqualStrings(account.name, store.snapshot().accounts[0].name);
    try std.testing.expectEqualStrings(account.uuid, store.snapshot().accounts[0].uuid);
    try std.testing.expectEqualStrings(account.id, store.snapshot().selected_account.?);
    ui.queue(.close_confirm, null, null);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.editor_open and ui.confirmation == null);
    ui.queue(.close_editor, null, null);
    finish(&ui, &store, &manager);
    try std.testing.expect(!ui.editor_open and ui.draft.id == null);
    try std.testing.expectEqual(@as(usize, 1), store.snapshot().accounts.len);
}

test "accounts view removal requires selected editor and blocks stale or busy confirmation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var store = try config.Store.init(std.testing.allocator, std.testing.io, path[0..len]);
    defer store.deinit();
    const accounts = [_]config.Account{
        .{ .id = "offline-a", .name = "Player_A", .uuid = "00000000000000000000000000000000" },
        .{ .id = "offline-b", .name = "Player_B", .uuid = "11111111111111111111111111111111" },
    };
    try store.update(.{ .accounts = &accounts, .selected_account = "offline-a" });
    var ui = try Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager = try Manager.init(std.testing.allocator, std.testing.io, path[0..len]);
    defer manager.deinit();
    ui.queue(.add, null, null);
    finish(&ui, &store, &manager);
    ui.queue(.ask_delete, "offline-a", null);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.EditorRequired, ui.failure.?);
    try std.testing.expect(ui.confirmation == null);
    ui.queue(.edit, "offline-b", null);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.SelectionChanged, ui.failure.?);
    try std.testing.expect(ui.draft.id == null);
    ui.queue(.edit, "offline-a", null);
    finish(&ui, &store, &manager);
    ui.queue(.ask_delete, ui.draft.id, null);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.confirmation != null and !ui.confirmation.?.sign_out);
    ui.queue(.confirm, "offline-b", null);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.SelectionChanged, ui.failure.?);
    try store.update(.{ .accounts = &accounts, .selected_account = "offline-b" });
    ui.queue(.confirm, "offline-a", null);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.SelectionChanged, ui.failure.?);
    try std.testing.expect(ui.confirmation != null and ui.editor_open);
    try std.testing.expectEqual(@as(usize, 2), store.snapshot().accounts.len);
    try store.update(.{ .accounts = &accounts, .selected_account = "offline-a" });
    manager.reset_needed = true;
    ui.queue(.confirm, "offline-a", null);
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.Busy, ui.failure.?);
    try std.testing.expect(ui.confirmation != null and ui.editor_open);
    ui.queue(.save, "offline-a", "ChangedName");
    finish(&ui, &store, &manager);
    try std.testing.expectEqual(error.Busy, ui.failure.?);
    try std.testing.expectEqualStrings("Player_A", store.snapshot().accounts[0].name);
    manager.reset_needed = false;
    ui.queue(.confirm, "offline-a", null);
    finish(&ui, &store, &manager);
    try std.testing.expect(ui.failure == null and ui.confirmation == null and !ui.editor_open);
    try std.testing.expect(ui.draft.id == null);
    try std.testing.expectEqual(@as(usize, 1), store.snapshot().accounts.len);
    try std.testing.expectEqualStrings("offline-b", store.snapshot().accounts[0].id);
    try std.testing.expect(store.snapshot().selected_account == null);
}
