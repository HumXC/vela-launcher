//! Native accounts picker. finish runs after root widgets close, before Window.end.
const std = @import("std");
const dvui = @import("dvui");
const config = @import("../core/config.zig");
const accounts_manager = @import("accounts_manager.zig");
const theme = @import("theme.zig");
const Allocator = std.mem.Allocator;
const Manager = accounts_manager.Manager;
const R = dvui.Rect;
const danger = dvui.Color.fromHex("F0A6A1");

const Action = enum { add, edit, save, close_editor, select, ask_delete, ask_sign_out, confirm, close_confirm, start, cancel, close_login, copy_code, open_uri, probe_remember, forget_remember, retry_cleanup, retry_publication, refresh };
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
    name: [65]u8 = @splat(0),
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
    remember: bool = false,
    remember_probe: bool = false,
    failure: ?anyerror = null,

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
fn wrapped(src: std.builtin.SourceLocation, value: []const u8, color: dvui.Color) void {
    const layout = dvui.textLayout(src, .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = .{ .h = 6 }, .color_text = .{ .color = color } });
    layout.addText(value, .{});
    layout.deinit();
}
fn iconButton(src: std.builtin.SourceLocation, name: []const u8, asset: []const u8, enabled: bool) bool {
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
fn command(src: std.builtin.SourceLocation, text: []const u8, enabled: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{ .grayed = !enabled, .draw_focus = enabled }, .{ .label = .{ .text = text }, .padding = R.all(8), .margin = .{ .x = 4, .y = 4 }, .corners = .all(4) });
    if (enabled) button.processEvents() else button.processHover();
    button.drawBackground();
    dvui.labelNoFmt(@src(), text, .{}, button.style().override(.{ .padding = R.all(0), .margin = R.all(0), .role = .none }));
    button.drawFocus();
    const clicked = enabled and button.clicked();
    button.deinit();
    return clicked;
}
fn rememberCheckbox(src: std.builtin.SourceLocation, target: *bool, enabled: bool) bool {
    const opts = dvui.checkbox_defaults.override(.{ .margin = .{ .y = 6 }, .padding = R.all(0) });
    if (enabled) return dvui.checkbox(src, target, "记住登录", opts);
    const row = dvui.box(src, .{ .dir = .horizontal }, opts.override(.{ .color_text = .{ .color = theme.muted } }));
    defer row.deinit();
    const size = opts.fontGet().textHeight();
    const mark = dvui.spacer(@src(), .{ .min_size_content = dvui.Size.all(size), .gravity_y = 0.5 });
    dvui.checkmark(target.*, false, mark.borderRectScale(), false, 0, opts);
    dvui.labelNoFmt(@src(), "记住登录", .{}, .{ .color_text = .{ .color = theme.muted }, .gravity_y = 0.5, .padding = .{ .x = 6 } });
    return false;
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
    return fmt("操作失败：{s}", .{@errorName(failure)});
}
fn modal(src: std.builtin.SourceLocation, title: []const u8, height: f32) *dvui.FloatingWindowWidget {
    const window = dvui.windowRect();
    const width = @max(0, @min(460, window.w - 24));
    const h = @max(0, @min(height, window.h - 24));
    const result = dvui.floatingWindow(src, .{ .modal = true, .resize = .none, .window_avoid = .none }, .{ .rect = .{ .x = window.x + (window.w - width) / 2, .y = window.y + (window.h - h) / 2, .w = width, .h = h }, .min_size_content = .{ .w = @max(0, width - 26), .h = @max(0, h - 26) }, .max_size_content = .{ .w = @max(0, width - 26), .h = @max(0, h - 26) }, .padding = R.all(12), .margin = R.all(0), .border = R.all(1), .corners = .all(8), .label = .{ .text = title } });
    result.dragAreaSet(dvui.windowHeader(title, "", null));
    return result;
}

pub fn draw(ui: *Ui, store: *config.Store, manager: *Manager) void {
    const doc = store.snapshot();
    const snapshot = manager.snapshot();
    const configured = doc.settings.microsoft_client_id.len != 0;
    {
        const header = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = R.all(0), .margin = .{ .h = 10 } });
        defer header.deinit();
        dvui.labelNoFmt(@src(), "账户", .{}, .{ .expand = .horizontal, .padding = R.all(0) });
        if (iconButton(@src(), "添加离线账户", dvui.entypo.plus, !snapshot.busy)) ui.queue(.add, null, null);
    }
    if (ui.failure) |err| wrapped(@src(), errorText(err), danger);
    if (snapshot.failure) |err| wrapped(@src(), errorText(err), danger);
    if (snapshot.busy and !ui.login_open and !ui.remember_probe) {
        wrapped(@src(), phaseText(snapshot.phase), theme.accent);
        if (command(@src(), "取消", true)) ui.queue(.cancel, null, null);
    }
    if (doc.accounts.len == 0) wrapped(@src(), "暂无账户", theme.muted);
    for (doc.accounts, 0..) |account, index| {
        const row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = index, .expand = .horizontal, .padding = .{ .y = 8 }, .margin = R.all(0), .border = .{ .h = 1 } });
        {
            const metadata = dvui.box(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .width(0), .padding = R.all(0), .margin = R.all(0) });
            wrapped(@src(), account.name, if (selected(doc, account.id)) theme.accent else dvui.Color.fromHex("EDF1EA"));
            wrapped(@src(), if (account.kind == .offline) "离线" else "Microsoft", theme.muted);
            wrapped(@src(), account.uuid, theme.muted);
            metadata.deinit();
        }
        if (selected(doc, account.id)) {
            dvui.labelNoFmt(@src(), "已选择", .{}, .{ .color_text = .{ .color = theme.accent }, .padding = R.all(8) });
        } else if (command(@src(), "选择", !snapshot.busy)) ui.queue(.select, account.id, null);
        if (account.kind == .offline) {
            if (iconButton(@src(), "编辑账户", dvui.entypo.edit, !snapshot.busy)) ui.queue(.edit, account.id, null);
            if (iconButton(@src(), "删除账户", dvui.entypo.trash, !snapshot.busy)) ui.queue(.ask_delete, account.id, null);
        } else {
            if (selected(doc, account.id) and canRefresh(account, manager)) {
                if (iconButton(@src(), "刷新登录", dvui.entypo.cw, !snapshot.busy and configured)) ui.queue(.refresh, account.id, null);
            }
            if (iconButton(@src(), "退出登录", dvui.entypo.log_out, !snapshot.busy)) ui.queue(.ask_sign_out, account.id, null);
        }
        row.deinit();
    }
    if (!configured) wrapped(@src(), "Microsoft 客户端 ID 未配置", theme.muted);
    if (command(@src(), "Microsoft 登录", configured and !snapshot.busy and !snapshot.publication_pending)) ui.queue(.start, null, null);
    {
        var remember = ui.remember;
        if (rememberCheckbox(@src(), &remember, !snapshot.busy and snapshot.device == null and !snapshot.publication_pending and !ui.remember_probe)) {
            ui.queue(if (remember) .probe_remember else .forget_remember, null, null);
        }
        if (ui.remember_probe) wrapped(@src(), "正在检查安全存储", theme.muted);
    }
    if (snapshot.cleanup_count != 0) {
        wrapped(@src(), fmt("待清理凭据：{d}", .{snapshot.cleanup_count}), theme.muted);
        if (command(@src(), "重试清理", !snapshot.busy)) ui.queue(.retry_cleanup, null, null);
    }
    if (snapshot.publication_pending) {
        wrapped(@src(), "账户保存未完成", danger);
        if (command(@src(), "重试保存", !snapshot.busy)) ui.queue(.retry_publication, null, null);
    }
    if (ui.editor_open) drawEditor(ui, snapshot.busy);
    if (ui.confirmation != null) drawConfirmation(ui, doc, snapshot.busy);
    if (ui.login_open) drawLogin(ui, doc, manager, snapshot, configured);
}

fn drawEditor(ui: *Ui, busy: bool) void {
    const window = modal(@src(), if (ui.draft.id == null) "添加离线账户" else "编辑离线账户", 250);
    defer window.deinit();
    const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer scroll.deinit();
    dvui.labelNoFmt(@src(), "玩家名称", .{}, .{ .padding = R.all(0), .margin = .{ .h = 6 } });
    const input = dvui.textEntry(@src(), .{ .text = .{ .buffer = &ui.draft.name } }, .{ .label = .{ .text = "玩家名称" }, .expand = .horizontal, .padding = R.all(8), .corners = .all(4) });
    input.deinit();
    const name = std.mem.sliceTo(&ui.draft.name, 0);
    if (!validName(name)) wrapped(@src(), "名称须为 3–16 位字母、数字或下划线", danger);
    if (ui.failure) |err| wrapped(@src(), errorText(err), danger);
    if (command(@src(), "保存", validName(name) and !busy)) ui.queue(.save, ui.draft.id, name);
    if (command(@src(), "取消", true)) ui.queue(.close_editor, null, null);
}
fn drawConfirmation(ui: *Ui, doc: *const config.Document, busy: bool) void {
    const confirmation = ui.confirmation.?;
    const window = modal(@src(), if (confirmation.sign_out) "退出登录" else "删除账户", 230);
    defer window.deinit();
    const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer scroll.deinit();
    if (findAccount(doc, confirmation.id)) |account| {
        wrapped(@src(), if (confirmation.sign_out) fmt("退出「{s}」的登录？", .{account.name}) else fmt("删除账户「{s}」？", .{account.name}), dvui.Color.fromHex("EDF1EA"));
        if (command(@src(), "确认", !busy)) ui.queue(.confirm, confirmation.id, null);
    } else wrapped(@src(), "账户不存在", danger);
    if (ui.failure) |err| wrapped(@src(), errorText(err), danger);
    if (command(@src(), "取消", true)) ui.queue(.close_confirm, null, null);
}
fn drawLogin(ui: *Ui, doc: *const config.Document, manager: *Manager, snapshot: accounts_manager.Snapshot, configured: bool) void {
    const window = modal(@src(), "Microsoft 登录", 360);
    defer window.deinit();
    const scroll = dvui.scrollArea(@src(), .{ .horizontal = .none }, .{ .expand = .both, .padding = R.all(0), .margin = R.all(0) });
    defer scroll.deinit();
    wrapped(@src(), phaseText(snapshot.phase), theme.accent);
    if (snapshot.phase == .authenticated) {
        if (doc.selected_account) |id| {
            if (findAccount(doc, id)) |account| {
                wrapped(@src(), account.name, dvui.Color.fromHex("EDF1EA"));
                wrapped(@src(), account.uuid, theme.muted);
            }
        }
    }
    if (snapshot.device) |device| {
        if (snapshot.phase == .device_pending or snapshot.phase == .slow_down) {
            wrapped(@src(), device.userCode(), dvui.Color.fromHex("EDF1EA"));
            wrapped(@src(), device.verificationUri(), theme.muted);
            const now_ms: u64 = @intCast(@max(0, @divFloor(std.Io.Clock.awake.now(manager.io).nanoseconds, 1_000_000)));
            const remaining = device.expires_at_ms -| now_ms;
            wrapped(@src(), fmt("有效期：{d} 秒", .{(remaining +| 999) / 1000}), theme.muted);
            wrapped(@src(), fmt("下次验证：{d} 秒", .{((device.next_poll_ms -| now_ms) +| 999) / 1000}), theme.muted);
            if (iconButton(@src(), "复制验证码", dvui.entypo.copy, remaining != 0 and device.userCode().len != 0)) ui.queue(.copy_code, null, device.userCode());
            if (command(@src(), "打开验证页", remaining != 0 and validVerificationUri(device.verificationUri()))) ui.queue(.open_uri, null, device.verificationUri());
        }
    }
    if (snapshot.failure) |err| wrapped(@src(), errorText(err), danger);
    if (ui.failure) |err| wrapped(@src(), errorText(err), danger);
    if (snapshot.busy) {
        if (command(@src(), "取消登录", true)) ui.queue(.cancel, null, null);
    } else {
        if (snapshot.phase != .authenticated and command(@src(), "重新登录", configured and !snapshot.publication_pending)) ui.queue(.start, null, null);
        if (command(@src(), "关闭", true)) ui.queue(.close_login, null, null);
    }
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
            ui.editor_open = true;
        },
        .edit => {
            const account = findAccount(store.snapshot(), pending.id.?) orelse return error.AccountNotFound;
            if (account.kind != .offline) return error.NotOfflineAccount;
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
            if (pending.id) |id| try manager.editOffline(store, id, name) else try manager.addOffline(store, name);
            ui.editor_open = false;
            ui.draft.deinit(ui.allocator);
        },
        .close_editor => {
            ui.editor_open = false;
            ui.draft.deinit(ui.allocator);
        },
        .select => try manager.select(store, pending.id.?),
        .ask_delete, .ask_sign_out => {
            const id = try ui.allocator.dupe(u8, pending.id.?);
            ui.closeConfirmation();
            ui.confirmation = .{ .id = id, .sign_out = pending.action == .ask_sign_out };
        },
        .confirm => {
            const c = ui.confirmation orelse return error.ConfirmationRequired;
            if (!std.mem.eql(u8, c.id, pending.id.?)) return error.SelectionChanged;
            if (c.sign_out) try manager.signOut(store, pending.id.?) else try manager.removeOffline(store, pending.id.?);
            ui.closeConfirmation();
        },
        .close_confirm => ui.closeConfirmation(),
        .start => {
            if (store.snapshot().settings.microsoft_client_id.len == 0) return error.ClientIdRequired;
            ui.login_open = true;
            try manager.startDeviceRemember(store, pending.remember);
        },
        .cancel => manager.cancel(),
        .close_login => ui.login_open = false,
        .copy_code => dvui.clipboardTextSet(pending.text.?),
        .open_uri => {
            if (!validVerificationUri(pending.text.?)) return error.InvalidVerificationUri;
            if (!dvui.openURL(.{ .url = pending.text.? })) return error.OpenVerificationFailed;
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

test "editor and confirmation remain deferred and own metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var store = try config.Store.init(std.testing.allocator, std.testing.io, path[0..len]);
    defer store.deinit();
    try store.update(.{ .accounts = &.{.{ .id = "account-a", .name = "Player_A", .uuid = "00000000000000000000000000000000" }} });
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
