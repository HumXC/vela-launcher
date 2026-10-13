//! UI-thread account owner. Only joined workers publish; no Store strings cross threads.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../core/config.zig");
const auth = @import("../core/auth.zig");
const credentials = @import("../core/credentials.zig");
const cleanup = @import("../core/auth_cleanup.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const wa = std.heap.page_allocator;
const RuntimeAdapter = if (builtin.is_test) struct {
    fn deinit(_: *@This()) void {}
} else @import("../core/auth_transport.zig").Adapter;

pub const Phase = enum { idle, starting, device_pending, slow_down, refreshing, authenticated, signing_out, cleanup, cancelled, expired, failed };
pub const DeviceSnapshot = struct {
    code: [128]u8 = @splat(0),
    code_len: usize = 0,
    uri: [512]u8 = @splat(0),
    uri_len: usize = 0,
    expires_at_ms: u64,
    next_poll_ms: u64,
    pub fn userCode(self: *const DeviceSnapshot) []const u8 {
        return self.code[0..self.code_len];
    }
    pub fn verificationUri(self: *const DeviceSnapshot) []const u8 {
        return self.uri[0..self.uri_len];
    }
};
pub const Snapshot = struct { phase: Phase, busy: bool, failure: ?anyerror, device: ?DeviceSnapshot, cleanup_count: usize, publication_pending: bool, remember_available: bool };
pub const HttpOptions = struct { proxy_url: ?[]const u8 = null, ca_bundle: ?[]const u8 = null };
pub const JournalHooks = struct {
    ctx: *anyopaque,
    stage: *const fn (*anyopaque, credentials.Reference) anyerror!void,
    remove: *const fn (*anyopaque, credentials.Reference) anyerror!void,
    references: *const fn (*anyopaque) []const credentials.Reference,
};
pub const Fixture = struct { transport: auth.Transport, store: credentials.Store, entropy: auth.Entropy, journal: JournalHooks };
pub const Options = struct { root: []const u8, http_options: HttpOptions = .{}, fixture: ?Fixture = null };
pub const LaunchIdentity = struct { id: []const u8, username: []const u8, uuid: []const u8, kind: config.AccountKind, access_token: ?[]const u8 };
pub const OwnedLaunchSession = struct {
    allocator: A,
    id: []u8,
    username: []u8,
    uuid: []u8,
    kind: config.AccountKind,
    token: ?credentials.Secret = null,
    expires_at_ms: u64 = 0,
    pub fn deinit(self: *OwnedLaunchSession) void {
        if (self.token) |*token| token.deinit();
        self.allocator.free(self.id);
        self.allocator.free(self.username);
        self.allocator.free(self.uuid);
        self.* = undefined;
    }
    fn clone(a: A, identity: LaunchIdentity, expiry: u64) !OwnedLaunchSession {
        const id = try a.dupe(u8, identity.id);
        errdefer a.free(id);
        const name = try a.dupe(u8, identity.username);
        errdefer a.free(name);
        const uuid = try a.dupe(u8, identity.uuid);
        errdefer a.free(uuid);
        const token: ?credentials.Secret = if (identity.access_token) |bytes| .{ .allocator = a, .bytes = try a.dupe(u8, bytes) } else null;
        return .{ .allocator = a, .id = id, .username = name, .uuid = uuid, .kind = identity.kind, .token = token, .expires_at_ms = expiry };
    }
};
fn nameValid(name: []const u8) bool {
    if (name.len < 3 or name.len > 16) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}
pub fn offlineUuid(name: []const u8) ![32]u8 {
    if (!nameValid(name)) return error.InvalidAccountName;
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update("OfflinePlayer:");
    md5.update(name);
    var bytes: [16]u8 = undefined;
    md5.final(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x30;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.bytesToHex(bytes, .lower);
}
pub fn findAccount(doc: *const config.Document, id: []const u8) ?config.Account {
    for (doc.accounts) |account| if (std.mem.eql(u8, account.id, id)) return account;
    return null;
}
fn duplicateUuid(doc: *const config.Document, uuid: []const u8, excluding: ?[]const u8) bool {
    for (doc.accounts) |account| {
        if (excluding) |id| if (std.mem.eql(u8, account.id, id)) continue;
        if (std.ascii.eqlIgnoreCase(account.uuid, uuid)) return true;
    }
    return false;
}
fn now(io: Io) u64 {
    return @intCast(@max(0, @divFloor(Io.Clock.awake.now(io).nanoseconds, 1_000_000)));
}

pub const Manager = struct {
    allocator: A,
    io: Io,
    worker: *Worker,
    active: ?*Job = null,
    publication: ?*Job = null,
    phase: Phase = .idle,
    failure: ?anyerror = null,
    device: ?DeviceSnapshot = null,
    selection: ?OwnedLaunchSession = null,
    session: ?OwnedLaunchSession = null,
    session_persisted: bool = false,
    cleanup_count: usize = 0,
    remember_available: bool = false,
    reset_needed: bool = false,
    pending_ack: ?credentials.Reference = null,
    pub fn init(a: A, io: Io, root: []const u8) !Manager {
        return initWithOptions(a, io, .{ .root = root });
    }
    pub fn initWithOptions(a: A, io: Io, options: Options) !Manager {
        return .{ .allocator = a, .io = io, .worker = try Worker.create(io, options) };
    }
    pub fn deinit(self: *Manager) void {
        self.clearSession();
        self.clearSelection();
        if (self.active) |job| {
            job.cancel.cancel();
            job.thread.?.join();
            job.destroy();
        }
        if (self.publication) |job| job.destroy();
        // Shutdown may wait for native cancellation cleanup. Never free live contexts.
        self.worker.destroy();
        self.* = undefined;
    }
    fn clearSession(self: *Manager) void {
        if (self.session) |*s| s.deinit();
        self.session = null;
        self.session_persisted = false;
    }
    fn clearSelection(self: *Manager) void {
        if (self.selection) |*s| s.deinit();
        self.selection = null;
    }
    pub fn snapshot(self: *const Manager) Snapshot {
        return .{ .phase = self.phase, .busy = self.active != null or self.reset_needed or self.pending_ack != null, .failure = self.failure, .device = self.device, .cleanup_count = self.cleanup_count, .publication_pending = self.publication != null, .remember_available = self.remember_available };
    }
    fn syncSelection(self: *Manager, store: *config.Store) !void {
        const doc = store.snapshot();
        const account = if (doc.selected_account) |id| findAccount(doc, id) else null;
        if (account) |v| {
            if (self.selection) |s| if (std.mem.eql(u8, s.id, v.id) and std.mem.eql(u8, s.username, v.name) and std.mem.eql(u8, s.uuid, v.uuid) and s.kind == v.kind) return;
            const s = OwnedLaunchSession.clone(self.allocator, .{ .id = v.id, .username = v.name, .uuid = v.uuid, .kind = v.kind, .access_token = null }, 0) catch |err| {
                self.clearSelection();
                return err;
            };
            self.clearSelection();
            self.selection = s;
        } else self.clearSelection();
    }
    pub fn select(self: *Manager, store: *config.Store, id: []const u8) !void {
        if (self.active != null or self.publication != null) return error.Busy;
        var doc = store.snapshot().*;
        const account = findAccount(&doc, id) orelse return error.AccountNotFound;
        doc.selected_account = account.id;
        try store.update(doc);
        try self.syncSelection(store);
    }
    pub fn addOffline(self: *Manager, store: *config.Store, name: []const u8) !void {
        return self.createOffline(store, name, false);
    }
    /// Publish the new account and its selection together for explicit offline login.
    pub fn loginOffline(self: *Manager, store: *config.Store, name: []const u8) !void {
        if (self.active != null or self.publication != null) return error.Busy;
        return self.createOffline(store, name, true);
    }
    fn createOffline(self: *Manager, store: *config.Store, name: []const u8, select_new: bool) !void {
        const uuid = try offlineUuid(name);
        var doc = store.snapshot().*;
        if (duplicateUuid(&doc, &uuid, null)) return error.DuplicateUuid;
        var random: [16]u8 = undefined;
        try self.io.randomSecure(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        var id_buffer: [40]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "offline-{s}", .{hex});
        if (findAccount(&doc, id) != null) return error.DuplicateId;
        const items = try self.allocator.alloc(config.Account, doc.accounts.len + 1);
        defer self.allocator.free(items);
        @memcpy(items[0..doc.accounts.len], doc.accounts);
        items[items.len - 1] = .{ .id = id, .name = name, .uuid = &uuid, .kind = .offline };
        doc.accounts = items;
        var new_selection: ?OwnedLaunchSession = null;
        errdefer if (new_selection) |*selection| selection.deinit();
        if (select_new) {
            doc.selected_account = id;
            // Prepare all owned metadata before committing so allocation failure is retryable.
            new_selection = try OwnedLaunchSession.clone(self.allocator, .{ .id = id, .username = name, .uuid = &uuid, .kind = .offline, .access_token = null }, 0);
        }
        try store.update(doc);
        if (new_selection) |selection| {
            self.clearSelection();
            self.selection = selection;
        } else try self.syncSelection(store);
    }
    pub fn editOffline(self: *Manager, store: *config.Store, id: []const u8, name: []const u8) !void {
        const uuid = try offlineUuid(name);
        var doc = store.snapshot().*;
        const old = findAccount(&doc, id) orelse return error.AccountNotFound;
        if (old.kind != .offline) return error.NotOfflineAccount;
        if (duplicateUuid(&doc, &uuid, id)) return error.DuplicateUuid;
        const items = try self.allocator.dupe(config.Account, doc.accounts);
        defer self.allocator.free(items);
        for (items) |*item| if (std.mem.eql(u8, item.id, id)) {
            item.name = name;
            item.uuid = &uuid;
        };
        doc.accounts = items;
        try store.update(doc);
        try self.syncSelection(store);
    }
    pub fn removeOffline(self: *Manager, store: *config.Store, id: []const u8) !void {
        var doc = store.snapshot().*;
        const old = findAccount(&doc, id) orelse return error.AccountNotFound;
        if (old.kind != .offline) return error.NotOfflineAccount;
        const items = try self.allocator.alloc(config.Account, doc.accounts.len - 1);
        defer self.allocator.free(items);
        var n: usize = 0;
        for (doc.accounts) |item| if (!std.mem.eql(u8, item.id, id)) {
            items[n] = item;
            n += 1;
        };
        doc.accounts = items;
        if (doc.selected_account) |selected| if (std.mem.eql(u8, selected, id)) {
            doc.selected_account = null;
        };
        try store.update(doc);
        try self.syncSelection(store);
    }
    pub fn launchIdentity(self: *const Manager, now_ms: u64) !LaunchIdentity {
        if (self.active != null or self.publication != null or self.reset_needed or self.pending_ack != null) return error.Busy;
        const selected = self.selection orelse return error.NoAccountSelected;
        var token: ?[]const u8 = null;
        if (selected.kind == .microsoft) {
            const s = self.session orelse return error.LoginRequired;
            if (!std.mem.eql(u8, s.id, selected.id)) return error.LoginRequired;
            if (now_ms >= s.expires_at_ms) return error.AuthorizationExpired;
            token = (s.token orelse return error.LoginRequired).bytes;
        }
        return .{ .id = selected.id, .username = selected.username, .uuid = selected.uuid, .kind = selected.kind, .access_token = token };
    }
    pub fn canLaunch(self: *const Manager, now_ms: u64) bool {
        _ = self.launchIdentity(now_ms) catch return false;
        return true;
    }
    pub fn cloneLaunchSession(self: *const Manager, a: A, now_ms: u64) !OwnedLaunchSession {
        return OwnedLaunchSession.clone(a, try self.launchIdentity(now_ms), if (self.session) |s| s.expires_at_ms else 0);
    }

    fn newJob(self: *Manager, action: Action, store: ?*config.Store) !*Job {
        if (self.reset_needed or self.pending_ack != null) return error.Busy;
        if (self.active != null or self.publication != null) return error.Busy;
        if (store) |s| if (s.publicationUncertain()) return error.ConfigPublicationUncertain;
        const job = try wa.create(Job);
        job.* = .{ .worker = self.worker, .action = action };
        errdefer job.destroy();
        if (store) |s| {
            const doc = s.snapshot();
            if (doc.accounts.len > 4096) return error.TooManyAccounts;
            for (doc.accounts) |account| if (account.credential_ref) |ref| {
                if (!credentials.validateReference(ref) or account.uuid.len != 32) return error.InvalidReference;
                job.known[job.known_count] = .{ .uuid = account.uuid[0..32].*, .ref = ref[0..32].* };
                job.known_count += 1;
            };
            if (action == .begin or action == .refresh or action == .refresh_session) {
                if (doc.settings.microsoft_client_id.len == 0) return error.Unconfigured;
                job.client_id = try wa.dupe(u8, doc.settings.microsoft_client_id);
            }
        }
        return job;
    }
    fn start(self: *Manager, job: *Job, phase: Phase) !void {
        job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
            job.destroy();
            return err;
        };
        self.active = job;
        self.phase = phase;
        self.failure = null;
    }
    /// Explicit user action; defaults to memory-only, with no vault/journal access.
    pub fn startDevice(self: *Manager, store: *config.Store) !void {
        return self.startDeviceRemember(store, false);
    }
    pub fn startDeviceRemember(self: *Manager, store: *config.Store, remember: bool) !void {
        const job = try self.newJob(.begin, store);
        job.remember = remember;
        self.clearSession();
        self.device = null;
        try self.start(job, .starting);
    }
    pub fn probeRemember(self: *Manager) !void {
        if (self.device != null) return error.Busy;
        const job = try self.newJob(.probe, null);
        job.output.phase = self.phase;
        try self.start(job, self.phase);
    }
    pub fn refreshSelected(self: *Manager, store: *config.Store) !void {
        const doc = store.snapshot();
        const id = doc.selected_account orelse return error.NoAccountSelected;
        const account = findAccount(doc, id) orelse return error.AccountNotFound;
        if (account.kind != .microsoft) return error.NotMicrosoftAccount;
        if (account.uuid.len != 32) return error.InvalidReference;
        const transient = if (self.session) |s| std.mem.eql(u8, s.id, id) and !self.session_persisted else false;
        const ref = account.credential_ref;
        if (!transient and ref == null) return error.LoginRequired;
        if (ref) |value| if (!credentials.validateReference(value)) return error.InvalidReference;
        const job = try self.newJob(if (transient) .refresh_session else .refresh, store);
        if (ref) |value| job.reference = value[0..32].*;
        job.expected_uuid = account.uuid[0..32].*;
        try self.start(job, .refreshing);
    }

    pub fn cancel(self: *Manager) void {
        self.clearSession();
        self.device = null;
        self.phase = .cancelled;
        self.failure = null;
        self.reset_needed = true;
        if (self.active) |job| {
            job.cancel.cancel();
            return;
        }
        if (self.publication) |job| {
            job.cancel.cancel();
            job.output.phase = .cancelled;
            job.wipeOutputToken();
        }
        self.scheduleReset();
    }
    fn scheduleReset(self: *Manager) void {
        if (self.active != null or (!self.reset_needed and self.pending_ack == null)) return;
        const job = wa.create(Job) catch |err| {
            self.failure = err;
            return;
        };
        const action: Action = if (self.pending_ack != null) (if (self.reset_needed or self.phase == .cancelled) .ack_reset else .ack) else .reset;
        job.* = .{ .worker = self.worker, .action = action, .reference = self.pending_ack };
        self.start(job, self.phase) catch |err| {
            self.failure = err;
            return;
        };
        self.pending_ack = null;
        if (action == .reset or action == .ack_reset) self.reset_needed = false;
    }

    pub fn signOut(self: *Manager, store: *config.Store, id: []const u8) !void {
        const account = findAccount(store.snapshot(), id) orelse return error.AccountNotFound;
        if (account.kind != .microsoft) return error.NotMicrosoftAccount;
        const job = try self.newJob(.signout, store);
        job.account_id = wa.dupe(u8, id) catch |err| {
            job.destroy();
            return err;
        };
        if (account.credential_ref) |ref| job.reference = ref[0..32].*;
        // Clear main-thread launch secrets before any native deletion starts.
        self.clearSession();
        self.device = null;
        try self.start(job, .signing_out);
    }
    pub fn retryCleanup(self: *Manager, store: *config.Store) !void {
        if (self.reset_needed or self.pending_ack != null) return error.Busy;
        if (self.active != null or self.publication != null) return error.Busy;
        if (store.publicationUncertain()) try store.reconcile();
        const job = try self.newJob(.cleanup, store);
        self.clearSession();
        self.device = null;
        try self.start(job, .cleanup);
    }
    pub fn retryPublication(self: *Manager, store: *config.Store) !void {
        const job = self.publication orelse return error.NoPendingPublication;
        if (store.publicationUncertain()) try store.reconcile();
        try self.publish(job, store);
        self.publication = null;
        self.finish(job);
    }
    pub fn tick(self: *Manager, store: *config.Store) void {
        self.syncSelection(store) catch |err| {
            self.failure = err;
        };
        if (self.active) |job| {
            if (!job.done.load(.acquire)) return;
            job.thread.?.join();
            job.thread = null;
            self.active = null;
            if (job.output.reset_worker) self.reset_needed = false;
            self.publish(job, store) catch |err| {
                self.publication = job;
                self.failure = err;
                self.phase = .failed;
                self.device = null;
                self.scheduleReset();
                return;
            };
            self.finish(job);
        }
        self.scheduleReset();
        if (self.active == null and self.publication == null and (self.phase == .device_pending or self.phase == .slow_down)) {
            const device = self.device orelse return;
            if (now(self.io) >= device.next_poll_ms) {
                const job = self.newJob(.poll, store) catch |err| {
                    self.failure = err;
                    self.phase = .failed;
                    return;
                };
                self.start(job, self.phase) catch |err| {
                    self.failure = err;
                    self.phase = .failed;
                };
            }
        }
    }
    fn publish(self: *Manager, job: *Job, store: *config.Store) !void {
        var doc = store.snapshot().*;
        if (job.output.session) |*s| {
            const ref = job.output.reference;
            var existing: ?usize = null;
            for (doc.accounts, 0..) |account, i| if (std.ascii.eqlIgnoreCase(account.uuid, s.uuid)) {
                if (account.kind != .microsoft) return error.DuplicateUuid;
                if (ref) |new_ref| if (account.credential_ref) |old| {
                    if (!std.mem.eql(u8, old, &new_ref)) {
                        const previous = job.output.previous_ref orelse return error.AccountChanged;
                        if (!std.mem.eql(u8, old, &previous)) return error.AccountChanged;
                    }
                };
                existing = i;
                break;
            };
            if (existing) |i| {
                const stable_id = try wa.dupe(u8, doc.accounts[i].id);
                wa.free(s.id);
                s.id = stable_id;
            } else {
                var random: [16]u8 = undefined;
                try self.io.randomSecure(&random);
                const id = try std.fmt.allocPrint(wa, "microsoft-{s}", .{std.fmt.bytesToHex(random, .lower)});
                if (findAccount(&doc, id) != null) {
                    wa.free(id);
                    return error.DuplicateId;
                }
                wa.free(s.id);
                s.id = id;
            }
            const items = try self.allocator.alloc(config.Account, doc.accounts.len + @as(usize, if (existing == null) 1 else 0));
            defer self.allocator.free(items);
            @memcpy(items[0..doc.accounts.len], doc.accounts);
            items[existing orelse doc.accounts.len] = .{ .id = s.id, .name = s.username, .uuid = s.uuid, .kind = .microsoft, .credential_ref = if (ref) |*r| r else if (existing) |i| doc.accounts[i].credential_ref else null };
            doc.accounts = items;
            doc.selected_account = s.id;
            try store.update(doc);
            if (job.output.needs_ack) job.output.acknowledge = ref;
            self.clearSession();
            if (!job.cancel.cancelled() and s.token != null) {
                self.session = s.*;
                self.session_persisted = job.output.persisted_session;
            }
            if (!job.cancel.cancelled() and s.token != null) job.output.session = null;
            try self.syncSelection(store);
        }
        if (job.output.deleted) {
            const ref = job.reference;
            const items = try self.allocator.dupe(config.Account, doc.accounts);
            defer self.allocator.free(items);
            for (items) |*account| if (std.mem.eql(u8, account.id, job.account_id)) {
                if (account.credential_ref) |current| {
                    if (ref == null or !std.mem.eql(u8, current, &ref.?)) return error.AccountChanged;
                    account.credential_ref = null;
                }
            };
            doc.accounts = items;
            try store.update(doc);
            try self.syncSelection(store);
        }
    }
    fn finish(self: *Manager, job: *Job) void {
        if (job.output.failure) |failure| if (failure == error.AccountMismatch) self.clearSession();
        self.phase = job.output.phase;
        self.failure = job.output.failure;
        self.device = job.output.device;
        if (job.output.remember_checked) self.remember_available = job.output.remember_available;
        self.cleanup_count = job.output.cleanup_count;
        if (job.output.needs_ack) self.pending_ack = job.output.acknowledge;
        job.destroy();
        self.scheduleReset();
    }
};

const Action = enum { begin, poll, refresh, refresh_session, signout, cleanup, reset, ack, ack_reset, probe };
const Known = struct { uuid: [32]u8, ref: credentials.Reference };
const Output = struct {
    phase: Phase = .idle,
    failure: ?anyerror = null,
    device: ?DeviceSnapshot = null,
    session: ?OwnedLaunchSession = null,
    reference: ?credentials.Reference = null,
    previous_ref: ?credentials.Reference = null,
    acknowledge: ?credentials.Reference = null,
    deleted: bool = false,
    reset_worker: bool = false,
    needs_ack: bool = false,
    persisted_session: bool = false,
    cleanup_count: usize = 0,
    remember_checked: bool = false,
    remember_available: bool = false,
};
const Job = struct {
    worker: *Worker,
    action: Action,
    done: std.atomic.Value(bool) = .init(false),
    cancel: auth.CancelToken = .{},
    thread: ?std.Thread = null,
    client_id: []u8 = &.{},
    account_id: []u8 = &.{},
    reference: ?credentials.Reference = null,
    expected_uuid: ?[32]u8 = null,
    known: [4096]Known = undefined,
    known_count: usize = 0,
    output: Output = .{},
    remember: bool = false,
    fn wipeOutputToken(self: *Job) void {
        if (self.output.session) |*session| if (session.token) |*token| {
            token.deinit();
            session.token = null;
        };
    }
    fn destroy(self: *Job) void {
        if (self.output.session) |*s| s.deinit();
        wa.free(self.client_id);
        wa.free(self.account_id);
        wa.destroy(self);
    }
    fn run(self: *Job) void {
        self.worker.perform(self) catch |err| {
            const failure = if (self.worker.profile_mismatch) error.AccountMismatch else self.worker.stage_failure orelse err;
            self.output.failure = failure;
            self.output.phase = switch (failure) {
                error.Cancelled => .cancelled,
                error.AuthorizationExpired => .expired,
                else => .failed,
            };
            if (self.action == .probe) {
                self.output.remember_checked = true;
                self.output.remember_available = false;
            }
            if ((self.action != .refresh and self.action != .refresh_session and self.action != .ack and self.action != .probe) or failure == error.AccountMismatch)
                if (self.worker.client) |*c| c.reset();
        };
        if (self.cancel.cancelled()) {
            self.wipeOutputToken();
            if (self.worker.client) |*c| c.reset();
            self.output.reset_worker = true;
            self.output.phase = .cancelled;
            self.output.failure = null;
        }
        self.output.cleanup_count = self.worker.references().len;
        self.done.store(true, .release);
    }
};

fn releaseResponse(allocator: A, body: []const u8) void {
    const owned = @constCast(body);
    std.crypto.secureZero(u8, owned);
    if (owned.len != 0) allocator.rawFree(owned, .fromByteUnits(@alignOf(u8)), @returnAddress());
}
// Guard the refresh identity before Client can rotate an existing vault reference.
fn profileMatches(allocator: A, body: []const u8, expected: [32]u8) !bool {
    if (body.len > auth.max_response_bytes) return error.BodyTooLarge;
    var scanner = std.json.Scanner.initCompleteInput(allocator, body);
    defer scanner.deinit();
    var depth: usize = 0;
    var tokens: usize = 0;
    while (true) {
        const token = try scanner.next();
        tokens += 1;
        if (tokens > 8192) return error.ResourceLimit;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > 32) return error.ResourceLimit;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.MalformedResponse;
                depth -= 1;
            },
            .end_of_document => break,
            else => {},
        }
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always, .max_value_len = 16 * 1024, .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedResponse;
    const id = parsed.value.object.get("id") orelse return error.MalformedResponse;
    if (id != .string or id.string.len != 32) return error.MalformedResponse;
    for (id.string) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) return error.MalformedResponse;
    return std.ascii.eqlIgnoreCase(id.string, &expected);
}
test "accounts profile guard requires typed UUID and rejects duplicate fields" {
    const expected: [32]u8 = "00112233445566778899aabbccddeeff".*;
    try std.testing.expect(try profileMatches(std.testing.allocator, "{\"id\":\"00112233445566778899AABBCCDDEEFF\",\"name\":\"FixturePlayer\"}", expected));
    try std.testing.expect(!try profileMatches(std.testing.allocator, "{\"id\":\"ffeeddccbbaa99887766554433221100\"}", expected));
    try std.testing.expectError(error.DuplicateField, profileMatches(std.testing.allocator, "{\"id\":\"00112233445566778899aabbccddeeff\",\"id\":\"00112233445566778899aabbccddeeff\"}", expected));
    try std.testing.expectError(error.MalformedResponse, profileMatches(std.testing.allocator, "{\"id\":123}", expected));
    try std.testing.expectError(error.MalformedResponse, profileMatches(std.testing.allocator, "{\"id\":\"zz112233445566778899aabbccddeeff00\"}", expected));
}
test "accounts profile guard bounds body depth and token count" {
    const expected: [32]u8 = "00112233445566778899aabbccddeeff".*;
    const oversized = try std.testing.allocator.alloc(u8, auth.max_response_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.BodyTooLarge, profileMatches(std.testing.allocator, oversized, expected));
    const deep = comptime blk: {
        var bytes: [67]u8 = @splat('[');
        bytes[33] = '0';
        @memset(bytes[34..], ']');
        break :blk bytes;
    };
    try std.testing.expectError(error.ResourceLimit, profileMatches(std.testing.allocator, &deep, expected));
    const many_tokens = comptime blk: {
        @setEvalBranchQuota(20_000);
        var repeated: [2 * 8192]u8 = undefined;
        for (0..8192) |i| @memcpy(repeated[i * 2 ..][0..2], "0,");
        break :blk "[" ++ repeated ++ "0]";
    };
    try std.testing.expectError(error.ResourceLimit, profileMatches(std.testing.allocator, many_tokens, expected));
}
const Worker = struct {
    io: Io,
    root: []u8,
    proxy: ?[]u8,
    ca: ?[]u8,
    fixture: ?Fixture,
    native: ?credentials.Native = null,
    adapter: ?RuntimeAdapter = null,
    journal: ?cleanup.Journal = null,
    base_store: ?credentials.Store = null,
    transport: ?auth.Transport = null,
    client: ?auth.Client = null,
    client_id: []u8 = &.{},
    stage_failure: ?anyerror = null,
    expected_profile: ?[32]u8 = null,
    profile_mismatch: bool = false,
    journal_touched: bool = false,
    fn create(io: Io, options: Options) !*Worker {
        const w = try wa.create(Worker);
        errdefer wa.destroy(w);
        const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", wa);
        defer wa.free(cwd);
        const root = try std.fs.path.resolve(wa, &.{ cwd, options.root });
        errdefer wa.free(root);
        const proxy = if (options.http_options.proxy_url) |value| try wa.dupe(u8, value) else null;
        errdefer if (proxy) |value| wa.free(value);
        const ca = if (options.http_options.ca_bundle) |value| try wa.dupe(u8, value) else null;
        w.* = .{ .io = io, .root = root, .proxy = proxy, .ca = ca, .fixture = options.fixture };
        return w;
    }
    fn destroy(w: *Worker) void {
        if (w.client) |*c| c.deinit();
        if (w.adapter) |*adapter| adapter.deinit();
        if (w.native) |*native| native.deinit();
        if (w.journal) |*j| j.deinit();
        wa.free(w.client_id);
        wa.free(w.root);
        if (w.proxy) |value| wa.free(value);
        if (w.ca) |value| wa.free(value);
        wa.destroy(w);
    }
    fn ensureJournal(w: *Worker) !void {
        w.journal_touched = true;
        if (w.fixture == null and w.journal == null) w.journal = try cleanup.Journal.init(wa, w.io, w.root);
    }
    fn reloadJournal(w: *Worker) !void {
        w.journal_touched = true;
        if (w.fixture != null) return;
        if (w.journal) |*j| j.deinit();
        w.journal = null;
        try w.ensureJournal();
    }
    fn references(w: *Worker) []const credentials.Reference {
        if (!w.journal_touched) return &.{};
        if (w.fixture) |f| return f.journal.references(f.journal.ctx);
        if (w.journal) |*j| return j.references();
        return &.{};
    }
    fn stage(w: *Worker, ref: credentials.Reference) !void {
        w.journal_touched = true;
        if (w.fixture) |f| return f.journal.stage(f.journal.ctx, ref);
        try w.ensureJournal();
        try w.journal.?.stage(ref);
    }
    fn remove(w: *Worker, ref: credentials.Reference) !void {
        w.journal_touched = true;
        if (w.fixture) |f| return f.journal.remove(f.journal.ctx, ref);
        try w.ensureJournal();
        try w.journal.?.remove(ref);
    }
    fn entropy(ctx: *anyopaque, bytes: []u8) error{EntropyUnavailable}!void {
        const w: *Worker = @ptrCast(@alignCast(ctx));
        w.io.randomSecure(bytes) catch return error.EntropyUnavailable;
    }
    fn guardedRequest(ctx: *anyopaque, allocator: A, request: auth.Request) auth.TransportError!auth.Response {
        const w: *Worker = @ptrCast(@alignCast(ctx));
        const upstream = w.transport.?;
        const response = try upstream.request(upstream.ctx, allocator, request);
        if (w.expected_profile) |expected| if (response.status == 200 and std.mem.eql(u8, request.url, "https://api.minecraftservices.com/minecraft/profile")) {
            const matches = profileMatches(allocator, response.body, expected) catch |err| {
                releaseResponse(allocator, response.body);
                return if (err == error.OutOfMemory) error.OutOfMemory else error.TransportFailure;
            };
            if (!matches) {
                w.profile_mismatch = true;
                releaseResponse(allocator, response.body);
                return error.TransportFailure;
            }
        };
        return response;
    }
    fn ensureTransport(w: *Worker) !void {
        if (w.transport != null) return;
        if (w.fixture) |f| {
            if (f.transport.kind != .fixture) return error.InvalidFixture;
            w.transport = f.transport;
            return;
        }
        if (builtin.is_test) return error.FixtureRequired else {
            w.adapter = try @import("../core/auth_transport.zig").Adapter.init(wa, w.io, .{ .proxy = w.proxy, .ca_bundle = w.ca });
            w.transport = w.adapter.?.transport();
        }
    }
    fn ensureBackend(w: *Worker) !void {
        if (w.base_store != null) return;
        if (w.fixture) |f| {
            w.base_store = f.store;
            return;
        }
        if (builtin.is_test) return error.FixtureRequired else {
            w.native = try credentials.Native.init();
            w.base_store = w.native.?.store();
        }
    }
    fn probe(w: *Worker) !void {
        var random: [16]u8 = undefined;
        const e = if (w.fixture) |f| f.entropy else auth.Entropy{ .ctx = w, .fill = entropy };
        try e.fill(e.ctx, &random);
        const ref = std.fmt.bytesToHex(random, .lower);
        var secret = w.base_store.?.get(wa, &ref) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        secret.deinit();
    }
    fn ensureClient(w: *Worker, id: []const u8, persist: bool, require_journal: bool) !void {
        if (persist) {
            if (require_journal) try w.ensureJournal();
            try w.ensureBackend();
            try w.probe();
        }
        try w.ensureTransport();
        if (w.client != null and std.mem.eql(u8, w.client_id, id) and w.client.?.options.persist_refresh == persist) return;
        const copy = try wa.dupe(u8, id);
        errdefer wa.free(copy);
        if (w.client) |*c| c.deinit();
        w.client = null;
        wa.free(w.client_id);
        w.client_id = &.{};
        const wrapped: ?credentials.Store = if (persist) .{ .ctx = w, .vtable = &store_vtable } else null;
        w.client = try auth.Client.init(wa, .{ .enabled = true, .client_id = copy, .allow_production = true, .persist_refresh = persist }, .{ .ctx = w, .kind = w.transport.?.kind, .supports_post = w.transport.?.supports_post, .request = guardedRequest }, wrapped, if (w.fixture) |f| f.entropy else .{ .ctx = w, .fill = entropy });
        w.client_id = copy;
    }
    const store_vtable = credentials.Store.VTable{ .put = put, .get = get, .delete = delete };
    fn put(ctx: *anyopaque, ref: []const u8, secret: []const u8) credentials.Error!void {
        const w: *Worker = @ptrCast(@alignCast(ctx));
        if (w.client.?.pending_cleanup_ref) |pending| if (std.mem.eql(u8, &pending, ref)) {
            w.stage(pending) catch |err| {
                w.stage_failure = err;
                return error.StorageFailure;
            };
        };
        try w.base_store.?.put(ref, secret);
    }
    fn get(ctx: *anyopaque, a: A, ref: []const u8) credentials.Error!credentials.Secret {
        const w: *Worker = @ptrCast(@alignCast(ctx));
        return w.base_store.?.get(a, ref);
    }
    fn delete(ctx: *anyopaque, ref: []const u8) credentials.Error!void {
        const w: *Worker = @ptrCast(@alignCast(ctx));
        return w.base_store.?.delete(ref);
    }
    fn capture(w: *Worker, job: *Job) !void {
        const c = &w.client.?;
        job.output.persisted_session = c.options.persist_refresh;
        if (c.deviceView()) |v| {
            if (v.user_code.len > 128 or v.verification_uri.len > 512) return error.InvalidResponse;
            var d = DeviceSnapshot{ .expires_at_ms = v.expires_at_ms, .next_poll_ms = v.next_poll_ms, .code_len = v.user_code.len, .uri_len = v.verification_uri.len };
            @memcpy(d.code[0..d.code_len], v.user_code);
            @memcpy(d.uri[0..d.uri_len], v.verification_uri);
            job.output.device = d;
        }
        if (c.state != .authenticated) return;
        const account = c.account orelse return error.InvalidResponse;
        if (job.expected_uuid) |uuid| if (!std.ascii.eqlIgnoreCase(&uuid, account.uuid)) return error.AccountMismatch;
        const ref = account.credential_ref;
        if (ref) |new_ref| for (job.known[0..job.known_count]) |known| if (std.ascii.eqlIgnoreCase(&known.uuid, account.uuid) and !std.mem.eql(u8, &known.ref, &new_ref)) {
            try w.stage(known.ref);
            job.output.previous_ref = known.ref;
            break;
        };
        job.output.session = try OwnedLaunchSession.clone(wa, .{ .id = account.uuid, .username = account.name, .uuid = account.uuid, .kind = .microsoft, .access_token = try c.accessToken(now(w.io)) }, c.token_expires_at_ms);
        job.output.reference = ref;
        if (ref) |current| for (w.references()) |pending| if (std.mem.eql(u8, &current, &pending)) {
            job.output.needs_ack = true;
            break;
        };
        job.output.phase = .authenticated;
    }
    fn perform(w: *Worker, job: *Job) !void {
        w.stage_failure = null;
        w.profile_mismatch = false;
        w.expected_profile = job.expected_uuid;
        defer w.expected_profile = null;
        if (job.action == .reset) {
            if (w.client) |*c| c.reset();
            job.output.phase = .cancelled;
            return;
        }
        if (job.action == .signout) if (w.client) |*c| c.reset();
        if (job.cancel.cancelled()) return error.Cancelled;
        switch (job.action) {
            .begin => {
                try w.ensureClient(job.client_id, job.remember, job.remember);
                _ = try w.client.?.beginDevice(now(w.io), &job.cancel);
                job.output.phase = .device_pending;
                try w.capture(job);
            },
            .poll => {
                if (w.client == null) return error.InvalidState;
                const result = try w.client.?.poll(now(w.io), &job.cancel);
                job.output.phase = if (result == .slow_down) .slow_down else .device_pending;
                try w.capture(job);
            },
            .refresh => {
                try w.ensureClient(job.client_id, true, false);
                try w.client.?.refresh(&job.reference.?, now(w.io), &job.cancel);
                try w.capture(job);
            },
            .refresh_session => {
                if (w.client == null or !std.mem.eql(u8, w.client_id, job.client_id)) return error.LoginRequired;
                try w.client.?.refreshSession(now(w.io), &job.cancel);
                try w.capture(job);
            },
            .signout => {
                if (job.reference) |ref| {
                    try w.ensureBackend();
                    w.base_store.?.delete(&ref) catch |err| if (err != error.NotFound) return err;
                    job.output.deleted = true;
                    try w.remove(ref);
                    if (w.client) |*c| if (c.pending_cleanup_ref) |pending| if (std.mem.eql(u8, &pending, &ref)) {
                        c.pending_cleanup_ref = null;
                    };
                } else job.output.deleted = true;
                job.output.phase = .idle;
            },
            .cleanup => {
                if (w.client) |*c| c.reset();
                try w.reloadJournal();
                try w.ensureBackend();
                const refs = try wa.dupe(credentials.Reference, w.references());
                defer wa.free(refs);
                for (refs) |ref| {
                    if (job.cancel.cancelled()) return error.Cancelled;
                    var referenced = false;
                    for (job.known[0..job.known_count]) |known| if (std.mem.eql(u8, &known.ref, &ref)) {
                        referenced = true;
                        break;
                    };
                    if (!referenced) w.base_store.?.delete(&ref) catch |err| if (err != error.NotFound) return err;
                    try w.remove(ref);
                    if (w.client) |*c| if (c.pending_cleanup_ref) |pending| if (std.mem.eql(u8, &pending, &ref)) {
                        c.pending_cleanup_ref = null;
                    };
                }
                job.output.phase = .idle;
            },
            .ack, .ack_reset => {
                if (job.action == .ack_reset) if (w.client) |*c| c.reset();
                try w.remove(job.reference.?);
                job.output.phase = if (job.action == .ack_reset) .cancelled else .authenticated;
            },
            .probe => {
                job.output.remember_checked = true;
                try w.ensureJournal();
                try w.ensureBackend();
                try w.probe();
                job.output.remember_available = true;
            },
            .reset => unreachable,
        }
    }
};
