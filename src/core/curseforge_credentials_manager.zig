//! Serialized, worker-owned CurseForge reference transactions. No startup vault access.
//! Config helpers run ONLY on the GUI owner; worker methods never access config.Store.
//! The caller freezes CF publication from preflight through prepare/publication/ack,
//! and throughout recovery; cancel then join before deinit. Native calls cannot interrupt.
const std = @import("std");
const credentials = @import("credentials.zig");
const config = @import("config.zig");
const journal = @import("curseforge_credentials_journal.zig");
const Allocator = std.mem.Allocator;
pub const Reference = credentials.Reference;
pub const Policy = struct { enabled: bool, terms_approved: bool };
pub const Cancellation = struct {
    flag: ?*const std.atomic.Value(bool) = null,

    fn check(self: Cancellation) !void {
        if (self.flag) |flag| if (flag.load(.acquire)) return error.Cancelled;
    }
};

/// Owned nonsecret value: safe to transfer after joining the preparing worker.
pub const Receipt = struct {
    owner: usize,
    sequence: u64,
    pending: journal.Pending,
};
/// Obtain only from prepareConfig/publish/reconcileConfig, never a memory snapshot.
/// A confirmation is valid only while the caller prevents further CF publication.
pub const DurableConfig = struct { active: ?Reference, root_id: [32]u8 };

fn rootId(root: []const u8) [32]u8 {
    var id: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(root, &id, .{});
    return id;
}
pub const Publication = struct { receipt: Receipt, confirmed: DurableConfig };

fn same(a: ?Reference, b: ?Reference) bool {
    if (a) |left| return if (b) |right| std.mem.eql(u8, &left, &right) else false;
    return b == null;
}

fn activeReference(settings: config.Settings) !?Reference {
    const bytes = settings.curseforge_credential_ref orelse return null;
    if (!credentials.validateReference(bytes)) return error.InvalidReference;
    return bytes[0..32].*;
}

/// GUI-only publication: merge current editable policy into the LATEST document.
/// A changed active reference invalidates the receipt; never overwrite it blindly.
pub fn publish(manager: *const Manager, store: *config.Store, receipt: Receipt, policy: Policy) !Publication {
    // The preparing worker must be joined before inspecting its receipt here.
    try manager.validateReceipt(receipt);
    if (!std.mem.eql(u8, manager.journal.root, store.root)) return error.ForeignConfig;
    if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
    if (!same(try activeReference(store.snapshot().settings), receipt.pending.old_ref)) return error.StaleReceipt;
    const next_ref: ?Reference = switch (receipt.pending.action) {
        .set => receipt.pending.new_ref orelse return error.InvalidReceipt,
        .remove => blk: {
            if (receipt.pending.old_ref == null or receipt.pending.new_ref != null) return error.InvalidReceipt;
            break :blk @as(?Reference, null);
        },
    };
    var next = store.snapshot().*;
    next.settings.curseforge_enabled = policy.enabled;
    next.settings.curseforge_terms_approved = policy.terms_approved;
    next.settings.curseforge_credential_ref = if (next_ref) |*ref| ref else null;
    try store.update(next);
    return .{ .receipt = receipt, .confirmed = .{ .active = next_ref, .root_id = rootId(store.root) } };
}

/// GUI-only pre-enqueue check, with workers joined. Freeze CF publication until join.
/// Workers cannot determine same-root proof freshness without violating config ownership.
pub fn validatePublication(manager: *const Manager, store: *const config.Store, publication: Publication) !void {
    try manager.validateReceipt(publication.receipt);
    try manager.validateConfig(publication.confirmed);
    if (!std.mem.eql(u8, manager.journal.root, store.root)) return error.ForeignConfig;
    if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
    if (!same(try activeReference(store.snapshot().settings), publication.confirmed.active)) return error.StalePublication;
    const expected = if (publication.receipt.pending.action == .set) publication.receipt.pending.new_ref else null;
    if (!same(expected, publication.confirmed.active)) return error.InvalidReceipt;
}

/// GUI-only explicit recovery. This republishes authoritative disk, NOT a draft.
pub fn reconcileConfig(store: *config.Store) !DurableConfig {
    try store.reconcile();
    return .{ .active = try activeReference(store.snapshot().settings), .root_id = rootId(store.root) };
}

/// GUI-only mandatory preflight, with workers joined and CF publication frozen.
/// Saves the authoritative current snapshot, including fresh defaults, before staging.
/// Failed preflight invalidates any previous preparation proof without touching vault.
pub fn prepareConfig(manager: *Manager, store: *config.Store) !DurableConfig {
    manager.prepared_config = null;
    try manager.ready();
    if (!std.mem.eql(u8, manager.journal.root, store.root)) return error.ForeignConfig;
    if (store.publicationUncertain()) return error.ConfigPublicationUncertain;
    const active = try activeReference(store.snapshot().settings);
    try store.update(store.snapshot().*);
    const prior: DurableConfig = .{ .active = active, .root_id = rootId(store.root) };
    manager.prepared_config = prior;
    return prior;
}

pub const Manager = struct {
    journal: journal.Journal,
    injected: ?credentials.Store,
    native: ?credentials.Native = null,
    address: ?usize = null,
    prepared_config: ?DurableConfig = null,
    baseline_recovery: bool = false,
    phase: enum { ready, awaiting_publication, recovery },
    receipt: ?Receipt = null,
    sequence: u64 = 0,

    /// Init loads reference debt only; does not initialize Native, rewrite, or clean.
    /// Keep at a stable address after the first worker method, including during deinit.
    pub fn init(a: Allocator, io: std.Io, root: []const u8, injected: ?credentials.Store) !Manager {
        const canonical = try std.fs.path.resolve(a, &.{root});
        defer a.free(canonical);
        var debt = try journal.Journal.init(a, io, canonical);
        errdefer debt.deinit();
        const dirty = debt.snapshot().pending != null or debt.snapshot().cleanup.len != 0;
        return .{ .journal = debt, .injected = injected, .phase = if (dirty) .recovery else .ready };
    }

    /// Consumes the journal immediately; this constructor performs no allocation
    /// or path resolution and has no failure after taking ownership. The resulting
    /// Manager must stay at its final address after first use, exactly like init.
    /// Injected vault and root-factory contexts stay externally owned and stable.
    pub fn initWithOwnedJournal(owned: *?journal.Journal, injected: ?credentials.Store) !Manager {
        const debt = owned.* orelse return error.InvalidJournal;
        owned.* = null;
        const dirty = debt.snapshot().pending != null or debt.snapshot().cleanup.len != 0 or debt.poisoned();
        return .{ .journal = debt, .injected = injected, .phase = if (dirty) .recovery else .ready };
    }

    /// Caller MUST cancel and join every worker first; no outstanding Store borrows.
    pub fn deinit(self: *Manager) void {
        self.pin();
        if (self.native) |*native| native.deinit();
        self.journal.deinit();
        self.* = undefined;
    }

    /// Read only with worker joined, or on its serialized owner. Contains no secret.
    pub fn needsRecovery(self: *const Manager) bool {
        return self.phase == .recovery or self.journal.poisoned();
    }

    pub fn pending(self: *const Manager) ?journal.Pending {
        return self.journal.snapshot().pending;
    }

    fn pin(self: *Manager) void {
        const address = @intFromPtr(self);
        if (self.address) |previous| {
            if (address != previous) @panic("credential manager moved after first use");
        } else self.address = address;
    }

    fn ready(self: *Manager) !void {
        self.pin();
        if (self.phase != .ready or self.journal.poisoned()) return error.RecoveryRequired;
        if (self.sequence == std.math.maxInt(u64)) return error.ReceiptExhausted;
    }

    fn store(self: *Manager) !credentials.Store {
        if (self.injected) |injected| return injected;
        if (self.native == null) self.native = try credentials.Native.init();
        return self.native.?.store();
    }

    fn staged(self: *Manager) Receipt {
        self.sequence += 1;
        const receipt: Receipt = .{
            .owner = @intFromPtr(self),
            .sequence = self.sequence,
            .pending = self.journal.snapshot().pending.?,
        };
        self.receipt = receipt;
        self.phase = .recovery;
        return receipt;
    }

    /// Moves and empties *Secret immediately; caller may safely deinit the empty value.
    /// Always wipes owned bytes, including validation/cancel/allocation/IO errors.
    /// Fresh reference is caller-generated; journal rejects old/new or debt reuse.
    pub fn prepareSet(self: *Manager, prior: DurableConfig, new: Reference, secret: *credentials.Secret, cancel: Cancellation) !Receipt {
        var owned = secret.*;
        secret.bytes = &.{};
        defer owned.deinit();
        try self.ready();
        const old = try self.takePreparedConfig(prior);
        try cancel.check();
        if (owned.bytes.len == 0 or owned.bytes.len > 512) return error.InvalidKey;
        for (owned.bytes) |byte| if (byte < 33 or byte > 126) return error.InvalidKey;
        try self.ensureBaseline(cancel);
        self.journal.stageSet(old, new) catch |err| {
            if (self.journal.poisoned()) self.phase = .recovery;
            return err;
        };
        const receipt = self.staged();
        try cancel.check();
        const vault = try self.store();
        try cancel.check();
        try vault.put(&new, owned.bytes);
        try cancel.check();
        self.phase = .awaiting_publication;
        return receipt;
    }

    /// Clearing config must be durably confirmed before any delete is attempted.
    pub fn prepareRemove(self: *Manager, prior: DurableConfig, cancel: Cancellation) !Receipt {
        try self.ready();
        const old = (try self.takePreparedConfig(prior)) orelse return error.NoCredential;
        try cancel.check();
        try self.ensureBaseline(cancel);
        self.journal.stageRemove(old) catch |err| {
            if (self.journal.poisoned()) self.phase = .recovery;
            return err;
        };
        const receipt = self.staged();
        try cancel.check();
        self.phase = .awaiting_publication;
        return receipt;
    }

    /// Worker-only acknowledgment of successful GUI publication, then old-ref cleanup.
    /// Publication failure has no token: new prepares remain blocked by the pending phase.
    pub fn acknowledge(self: *Manager, publication: Publication, cancel: Cancellation) !void {
        self.pin();
        try self.validateReceipt(publication.receipt);
        const receipt = self.receipt.?;
        try self.validateConfig(publication.confirmed);
        const expected = if (receipt.pending.action == .set) receipt.pending.new_ref else null;
        if (!same(expected, publication.confirmed.active)) return error.InvalidReceipt;
        self.phase = .recovery;
        try cancel.check();
        try self.journal.resolve(publication.confirmed.active);
        self.receipt = null;
        try self.cleanup(publication.confirmed, cancel);
        self.phase = .ready;
    }

    /// Explicit worker recovery after GUI reconcileConfig. Reload debt before resolving.
    /// Even a failed put's NEW ref can be protected if authoritative config names it.
    pub fn recover(self: *Manager, confirmed: DurableConfig, cancel: Cancellation) !void {
        self.pin();
        try self.validateConfig(confirmed);
        self.phase = .recovery;
        try cancel.check();
        self.prepared_config = null;
        if (self.baseline_recovery) {
            self.journal.ensureBaseline() catch |err| switch (err) {
                error.JournalChanged => try self.journal.reload(),
                else => return err,
            };
            self.baseline_recovery = false;
        }
        if (self.journal.poisoned() or self.journal.snapshot().pending != null or self.journal.snapshot().cleanup.len != 0) {
            try self.journal.reload();
        }
        try cancel.check();
        if (self.journal.snapshot().pending == null and self.journal.snapshot().cleanup.len == 0) {
            self.receipt = null;
            self.phase = .ready;
            return;
        }
        try self.journal.resolve(confirmed.active);
        self.receipt = null;
        try self.cleanup(confirmed, cancel);
        self.phase = .ready;
    }

    fn validateReceipt(self: *const Manager, receipt: Receipt) !void {
        if (self.address != @intFromPtr(self)) return error.InvalidReceipt;
        if (self.phase != .awaiting_publication or self.receipt == null or
            !std.meta.eql(self.receipt.?, receipt)) return error.InvalidReceipt;
    }

    fn validateConfig(self: *const Manager, confirmed: DurableConfig) !void {
        const expected = rootId(self.journal.root);
        if (!std.mem.eql(u8, &expected, &confirmed.root_id)) return error.ForeignConfig;
        if (confirmed.active) |ref| if (!credentials.validateReference(&ref)) return error.InvalidReference;
    }

    fn ensureBaseline(self: *Manager, cancel: Cancellation) !void {
        self.baseline_recovery = true;
        self.journal.ensureBaseline() catch |err| {
            self.phase = .recovery;
            return err;
        };
        self.baseline_recovery = false;
        try cancel.check();
    }

    fn takePreparedConfig(self: *Manager, prior: DurableConfig) !?Reference {
        const registered = self.prepared_config;
        self.prepared_config = null;
        try self.validateConfig(prior);
        if (registered == null or !std.meta.eql(registered.?, prior)) return error.InvalidPreparation;
        return prior.active;
    }

    fn cleanup(self: *Manager, confirmed: DurableConfig, cancel: Cancellation) !void {
        while (self.journal.snapshot().cleanup.len != 0) {
            const ref = self.journal.snapshot().cleanup[0];
            if (same(ref, confirmed.active)) return error.ProtectedReference;
            try cancel.check();
            const vault = try self.store();
            try cancel.check();
            vault.delete(&ref) catch |err| switch (err) {
                error.NotFound => {},
                else => return err,
            };
            try cancel.check();
            try self.journal.forget(ref);
        }
    }
};

const test_old: Reference = @splat('0');
const test_new: Reference = @splat('1');
const test_other: Reference = @splat('2');
const test_key = "CF-CANARY-ONLY-NOT-A-REAL-KEY";
const test_policy: Policy = .{ .enabled = true, .terms_approved = true };

fn testRoot(tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    return std.testing.allocator.dupe(u8, buffer[0..len]);
}

// Stack-owned canary: the free hook verifies zeroing before allocator poisoning.
const WipeSpy = struct {
    bytes: [513]u8 = undefined,
    frees: usize = 0,

    fn secret(self: *WipeSpy, bytes: []const u8) credentials.Secret {
        @memcpy(self.bytes[0..bytes.len], bytes);
        return .{ .allocator = .{ .ptr = self, .vtable = &vtable }, .bytes = self.bytes[0..bytes.len] };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        return null;
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, bytes: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *WipeSpy = @ptrCast(@alignCast(ctx));
        for (bytes) |byte| std.debug.assert(byte == 0);
        self.frees += 1;
    }
};

const FakeVault = struct {
    root: []const u8,
    puts: usize = 0,
    deletes: usize = 0,
    exists: [3]bool = .{ true, false, false },
    fail_put: bool = false,
    fail_delete: bool = false,
    cancel_put: ?*std.atomic.Value(bool) = null,
    cancel_delete: ?*std.atomic.Value(bool) = null,

    fn store(self: *FakeVault) credentials.Store {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: credentials.Store.VTable = .{ .put = put, .get = get, .delete = delete };
    fn index(ref: []const u8) usize {
        std.debug.assert(ref.len == 32 and ref[0] >= '0' and ref[0] <= '2');
        return ref[0] - '0';
    }
    fn put(ctx: *anyopaque, ref: []const u8, _: []const u8) credentials.Error!void {
        const self: *FakeVault = @ptrCast(@alignCast(ctx));
        var disk = journal.Journal.init(std.testing.allocator, std.testing.io, self.root) catch return error.StorageFailure;
        defer disk.deinit();
        // Loading actual disk proves staging precedes this commit-ambiguous call.
        const staged = disk.snapshot().pending orelse return error.StorageFailure;
        std.debug.assert(staged.action == .set and same(staged.new_ref, ref[0..32].*));
        self.puts += 1;
        self.exists[index(ref)] = true;
        if (self.cancel_put) |flag| flag.store(true, .release);
        if (self.fail_put) return error.Denied;
    }
    fn get(_: *anyopaque, _: Allocator, _: []const u8) credentials.Error!credentials.Secret {
        return error.StorageFailure;
    }
    fn delete(ctx: *anyopaque, ref: []const u8) credentials.Error!void {
        const self: *FakeVault = @ptrCast(@alignCast(ctx));
        var disk = journal.Journal.init(std.testing.allocator, std.testing.io, self.root) catch return error.StorageFailure;
        defer disk.deinit();
        std.debug.assert(disk.snapshot().pending == null);
        var cfg = config.Store.init(std.testing.allocator, std.testing.io, self.root) catch return error.StorageFailure;
        defer cfg.deinit();
        std.debug.assert(!same(activeReference(cfg.snapshot().settings) catch return error.StorageFailure, ref[0..32].*));
        self.deletes += 1;
        if (self.cancel_delete) |flag| flag.store(true, .release);
        const existed = self.exists[index(ref)];
        self.exists[index(ref)] = false;
        if (self.fail_delete) return error.StorageFailure;
        if (!existed) return error.NotFound;
    }
};

// Preserve real userdata; override only serial test callbacks on the temporary FS.
const FaultIo = struct {
    threadlocal var active: ?*FaultIo = null;
    real: std.Io = std.testing.io,
    vtable: std.Io.VTable = undefined,
    syncs: usize = 0,
    creates: usize = 0,
    fail_create: ?usize = null,
    renames: usize = 0,
    fail_sync: ?usize = null,
    cancel_rename: ?*std.atomic.Value(bool) = null,
    fn start(self: *FaultIo) std.Io {
        std.debug.assert(active == null);
        active = self;
        self.vtable = self.real.vtable.*;
        self.vtable.dirCreateFile = create;
        self.vtable.dirCreateFileAtomic = createAtomic;
        self.vtable.fileSync = sync;
        self.vtable.dirRename = rename;
        return .{ .userdata = self.real.userdata, .vtable = &self.vtable };
    }
    fn stop(self: *FaultIo) void {
        std.debug.assert(active == self);
        active = null;
    }
    fn reset(self: *FaultIo) void {
        self.syncs = 0;
        self.creates = 0;
        self.fail_create = null;
        self.renames = 0;
        self.fail_sync = null;
    }
    fn createAtomic(ctx: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.CreateFileAtomicOptions) std.Io.Dir.CreateFileAtomicError!std.Io.File.Atomic {
        const self = active.?;
        self.creates += 1;
        if (self.fail_create == self.creates) return error.AccessDenied;
        return self.real.vtable.dirCreateFileAtomic(ctx, dir, path, options);
    }
    fn create(ctx: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
        const self = active.?;
        self.creates += 1;
        if (self.fail_create == self.creates) return error.AccessDenied;
        return self.real.vtable.dirCreateFile(ctx, dir, path, options);
    }
    fn sync(ctx: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        const self = active.?;
        self.syncs += 1;
        if (self.fail_sync == self.syncs) return error.InputOutput;
        return self.real.vtable.fileSync(ctx, file);
    }
    fn rename(ctx: ?*anyopaque, old: std.Io.Dir, old_path: []const u8, new: std.Io.Dir, new_path: []const u8) std.Io.Dir.RenameError!void {
        const self = active.?;
        self.renames += 1;
        try self.real.vtable.dirRename(ctx, old, old_path, new, new_path);
        if (self.cancel_rename) |flag| flag.store(true, .release);
    }
};

fn initializeConfig(store: *config.Store) !void {
    try store.update(.{ .settings = .{ .curseforge_credential_ref = &test_old } });
}

fn expectNoKey(tmp: *std.testing.TmpDir) !void {
    for ([_][]const u8{ ".vela/config.json", ".vela/curseforge-credentials.json" }) |path| {
        const bytes = try tmp.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4 * 1024 * 1024));
        defer std.testing.allocator.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, test_key) == null);
    }
}

test "CF manager stages before put consumes wipes publishes latest and acknowledges" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var cfg = try config.Store.init(a, std.testing.io, root);
    defer cfg.deinit();
    try initializeConfig(&cfg);
    var vault: FakeVault = .{ .root = root };
    var manager = try Manager.init(a, std.testing.io, root, vault.store());
    defer manager.deinit();
    try std.testing.expect(manager.native == null);
    try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
    const prior = try prepareConfig(&manager, &cfg);
    var spy: WipeSpy = .{};
    var secret = spy.secret(test_key);
    const receipt = try manager.prepareSet(prior, test_new, &secret, .{});
    try std.testing.expectEqual(@as(usize, 0), secret.bytes.len);
    secret.deinit();
    try std.testing.expectEqual(@as(usize, 1), spy.frees);
    try std.testing.expectEqual(@as(usize, 1), vault.puts);
    try std.testing.expectEqual(@as(usize, 0), vault.deletes);
    var latest = cfg.snapshot().*;
    latest.settings.download_connections = 17;
    latest.settings.microsoft_client_id = "unrelated-new-client";
    latest.instances = &.{.{ .id = "world", .name = "World", .minecraft_version = "1.21.5" }};
    latest.accounts = &.{.{ .id = "player", .name = "Player", .uuid = "uuid", .credential_ref = "account-only" }};
    try cfg.update(latest);
    const publication = try publish(&manager, &cfg, receipt, test_policy);
    try std.testing.expectEqual(@as(u16, 17), cfg.snapshot().settings.download_connections);
    try std.testing.expectEqualStrings("unrelated-new-client", cfg.snapshot().settings.microsoft_client_id);
    try std.testing.expectEqualStrings("world", cfg.snapshot().instances[0].id);
    try std.testing.expectEqualStrings("account-only", cfg.snapshot().accounts[0].credential_ref.?);
    try std.testing.expect(cfg.snapshot().settings.curseforge_enabled and cfg.snapshot().settings.curseforge_terms_approved);
    try std.testing.expectEqualStrings(&test_new, cfg.snapshot().settings.curseforge_credential_ref.?);
    try std.testing.expectEqual(@as(usize, 0), vault.deletes);
    try manager.acknowledge(publication, .{});
    try std.testing.expectEqual(@as(usize, 1), vault.deletes);
    try std.testing.expect(vault.exists[1] and !vault.exists[0]);
    try std.testing.expect(manager.pending() == null and !manager.needsRecovery());
    try std.testing.expect(manager.native == null);
    try expectNoKey(&tmp);
}

test "CF manager put errors and post-put cancellation retain debt and protect authoritative refs" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |cancelled| {
        for ([_]?Reference{ test_old, test_new, null }) |protected| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const root = try testRoot(&tmp);
            defer a.free(root);
            var cfg = try config.Store.init(a, std.testing.io, root);
            defer cfg.deinit();
            try initializeConfig(&cfg);
            var flag = std.atomic.Value(bool).init(false);
            var vault: FakeVault = .{ .root = root, .fail_put = !cancelled, .cancel_put = if (cancelled) &flag else null };
            {
                var manager = try Manager.init(a, std.testing.io, root, vault.store());
                defer manager.deinit();
                const prior = try prepareConfig(&manager, &cfg);
                var spy: WipeSpy = .{};
                var secret = spy.secret(test_key);
                try std.testing.expectError(if (cancelled) error.Cancelled else error.Denied, manager.prepareSet(prior, test_new, &secret, .{ .flag = &flag }));
                try std.testing.expectEqual(@as(usize, 1), spy.frees);
                try std.testing.expect(secret.bytes.len == 0);
                try std.testing.expect(manager.needsRecovery() and manager.pending() != null);
                try std.testing.expectEqual(@as(usize, 0), vault.deletes);
                secret = spy.secret(test_key);
                try std.testing.expectError(error.RecoveryRequired, manager.prepareSet(prior, test_other, &secret, .{}));
                try std.testing.expectEqual(@as(usize, 2), spy.frees);
            }
            var restarted = try Manager.init(a, std.testing.io, root, vault.store());
            defer restarted.deinit();
            try std.testing.expect(restarted.native == null and restarted.needsRecovery());
            try std.testing.expectEqual(@as(usize, 1), vault.puts);
            try std.testing.expectEqual(@as(usize, 0), vault.deletes);
            // Simulate an explicit authoritative later config, not the failed draft.
            var latest = cfg.snapshot().*;
            latest.settings.curseforge_credential_ref = if (protected) |*ref| ref else null;
            latest.settings.download_connections = 23;
            try cfg.update(latest);
            flag.store(false, .release);
            const confirmed = try reconcileConfig(&cfg);
            try restarted.recover(confirmed, .{});
            try std.testing.expect(!restarted.needsRecovery() and restarted.pending() == null);
            try std.testing.expectEqual(@as(u16, 23), cfg.snapshot().settings.download_connections);
            try std.testing.expectEqual(@as(usize, if (protected == null) 2 else 1), vault.deletes);
            if (protected) |ref| try std.testing.expect(vault.exists[FakeVault.index(&ref)]);
            try expectNoKey(&tmp);
        }
    }
}

test "CF manager config pre and post rename uncertainty never authorizes cleanup" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_]usize{ 1, 3 }) |failure| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var fault: FaultIo = .{};
        const io = fault.start();
        defer fault.stop();
        var cfg = try config.Store.init(a, io, root);
        defer cfg.deinit();
        try initializeConfig(&cfg);
        var vault: FakeVault = .{ .root = root };
        var manager = try Manager.init(a, io, root, vault.store());
        defer manager.deinit();
        const prior = try prepareConfig(&manager, &cfg);
        var spy: WipeSpy = .{};
        var secret = spy.secret(test_key);
        const receipt = try manager.prepareSet(prior, test_new, &secret, .{});
        fault.reset();
        fault.fail_sync = failure;
        try std.testing.expectError(error.InputOutput, publish(&manager, &cfg, receipt, test_policy));
        try std.testing.expect(cfg.publicationUncertain());
        try std.testing.expectEqualStrings(&test_old, cfg.snapshot().settings.curseforge_credential_ref.?);
        try std.testing.expectEqual(@as(usize, 0), vault.deletes);
        try std.testing.expect(manager.journal.snapshot().cleanup.len == 2 and manager.pending() != null);
        try std.testing.expectError(error.ConfigPublicationUncertain, publish(&manager, &cfg, receipt, test_policy));
        secret = spy.secret(test_key);
        try std.testing.expectError(error.RecoveryRequired, manager.prepareSet(prior, test_other, &secret, .{}));
        try std.testing.expectEqual(@as(usize, 2), spy.frees);
        fault.reset();
        const confirmed = try reconcileConfig(&cfg);
        try std.testing.expect(same(confirmed.active, if (failure == 3) test_new else test_old));
        try manager.recover(confirmed, .{});
        try std.testing.expect(!manager.needsRecovery());
        try std.testing.expectEqual(@as(usize, 1), vault.deletes);
        try std.testing.expect(vault.exists[if (failure == 3) 1 else 0]);
        try expectNoKey(&tmp);
    }
}

test "CF manager journal staging and acknowledgment uncertainty require explicit reload" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_]usize{ 1, 3 }) |failure| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var fault: FaultIo = .{};
        const io = fault.start();
        defer fault.stop();
        var cfg = try config.Store.init(a, io, root);
        defer cfg.deinit();
        try initializeConfig(&cfg);
        var vault: FakeVault = .{ .root = root };
        var manager = try Manager.init(a, io, root, vault.store());
        defer manager.deinit();
        const prior = try prepareConfig(&manager, &cfg);
        try manager.journal.ensureBaseline();
        var spy: WipeSpy = .{};
        var secret = spy.secret(test_key);
        fault.reset();
        fault.fail_sync = failure;
        const result = manager.prepareSet(prior, test_new, &secret, .{});
        if (result) |_| return error.ExpectedStageFailure else |_| {}
        try std.testing.expect(manager.needsRecovery() and manager.journal.poisoned());
        try std.testing.expectEqual(@as(usize, 1), spy.frees);
        try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
        try std.testing.expectError(error.RecoveryRequired, manager.prepareRemove(prior, .{}));
        fault.reset();
        try manager.recover(try reconcileConfig(&cfg), .{});
        try std.testing.expect(!manager.needsRecovery());
        try std.testing.expect(vault.exists[0]);
        try std.testing.expectEqual(@as(usize, if (failure == 3) 1 else 0), vault.deletes);
        try expectNoKey(&tmp);
    }
    // Resolve and forget may each fail before or after their own rename.
    for ([_]usize{ 1, 3, 4, 6 }) |failure| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var fault: FaultIo = .{};
        const io = fault.start();
        defer fault.stop();
        var cfg = try config.Store.init(a, io, root);
        defer cfg.deinit();
        try initializeConfig(&cfg);
        var vault: FakeVault = .{ .root = root };
        var manager = try Manager.init(a, io, root, vault.store());
        defer manager.deinit();
        const prior = try prepareConfig(&manager, &cfg);
        var spy: WipeSpy = .{};
        var secret = spy.secret(test_key);
        const receipt = try manager.prepareSet(prior, test_new, &secret, .{});
        const publication = try publish(&manager, &cfg, receipt, test_policy);
        fault.reset();
        fault.fail_sync = failure;
        if (manager.acknowledge(publication, .{})) |_| return error.ExpectedAckFailure else |_| {}
        try std.testing.expect(manager.needsRecovery() and manager.journal.poisoned());
        try std.testing.expect(vault.exists[1]);
        try std.testing.expectEqual(@as(usize, if (failure <= 3) 0 else 1), vault.deletes);
        fault.reset();
        try manager.recover(try reconcileConfig(&cfg), .{});
        try std.testing.expect(!manager.needsRecovery() and vault.exists[1]);
        try std.testing.expect(manager.journal.snapshot().cleanup.len == 0);
        try expectNoKey(&tmp);
    }
}

test "CF manager delete failure NotFound and cancellation retain debt until explicit retry" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for (0..3) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var cfg = try config.Store.init(a, std.testing.io, root);
        defer cfg.deinit();
        try initializeConfig(&cfg);
        var flag = std.atomic.Value(bool).init(false);
        var vault: FakeVault = .{ .root = root, .fail_delete = mode == 0, .cancel_delete = if (mode == 1) &flag else null };
        if (mode == 2) vault.exists[0] = false;
        var manager = try Manager.init(a, std.testing.io, root, vault.store());
        defer manager.deinit();
        const prior = try prepareConfig(&manager, &cfg);
        var spy: WipeSpy = .{};
        var secret = spy.secret(test_key);
        const receipt = try manager.prepareSet(prior, test_new, &secret, .{});
        const publication = try publish(&manager, &cfg, receipt, test_policy);
        const result = manager.acknowledge(publication, .{ .flag = &flag });
        if (mode == 2) {
            try result;
            try std.testing.expect(!manager.needsRecovery());
        } else {
            try std.testing.expectError(if (mode == 0) error.StorageFailure else error.Cancelled, result);
            try std.testing.expect(manager.needsRecovery() and manager.journal.snapshot().cleanup.len == 1);
            try std.testing.expectError(error.RecoveryRequired, manager.prepareRemove(prior, .{}));
            vault.fail_delete = false;
            vault.cancel_delete = null;
            flag.store(false, .release);
            try manager.recover(try reconcileConfig(&cfg), .{});
            try std.testing.expect(!manager.needsRecovery());
        }
        try std.testing.expectEqual(@as(usize, if (mode == 2) 1 else 2), vault.deletes);
        try std.testing.expect(vault.exists[1] and !vault.exists[0]);
        try std.testing.expect(manager.journal.snapshot().cleanup.len == 0);
        try expectNoKey(&tmp);
    }
}

test "CF manager removal publishes before delete and recovers old or null active ref" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_]?usize{ null, 1, 3 }) |failure| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var fault: FaultIo = .{};
        const io = fault.start();
        defer fault.stop();
        var cfg = try config.Store.init(a, io, root);
        defer cfg.deinit();
        try initializeConfig(&cfg);
        var vault: FakeVault = .{ .root = root };
        var manager = try Manager.init(a, io, root, vault.store());
        defer manager.deinit();
        const prior = try prepareConfig(&manager, &cfg);
        const receipt = try manager.prepareRemove(prior, .{});
        try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
        fault.reset();
        fault.fail_sync = failure;
        if (failure != null) {
            try std.testing.expectError(error.InputOutput, publish(&manager, &cfg, receipt, .{ .enabled = false, .terms_approved = false }));
            try std.testing.expectEqual(@as(usize, 0), vault.deletes);
            fault.reset();
            try manager.recover(try reconcileConfig(&cfg), .{});
        } else {
            const publication = try publish(&manager, &cfg, receipt, .{ .enabled = false, .terms_approved = false });
            try validatePublication(&manager, &cfg, publication);
            try std.testing.expect(cfg.snapshot().settings.curseforge_credential_ref == null);
            try std.testing.expectEqual(@as(usize, 0), vault.deletes);
            try manager.acknowledge(publication, .{});
        }
        try std.testing.expect(!manager.needsRecovery());
        try std.testing.expectEqual(@as(usize, if (failure == 1) 0 else 1), vault.deletes);
        try std.testing.expectEqual(failure == 1, vault.exists[0]);
        try expectNoKey(&tmp);
    }
}

test "CF manager rejects forged foreign mismatched and stale receipts and proofs" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var fault: FaultIo = .{};
    const io = fault.start();
    defer fault.stop();
    var cfg = try config.Store.init(a, io, root);
    defer cfg.deinit();
    try initializeConfig(&cfg);
    var vault: FakeVault = .{ .root = root };
    var manager = try Manager.init(a, io, root, vault.store());
    defer manager.deinit();
    const prior = try prepareConfig(&manager, &cfg);
    var spy: WipeSpy = .{};
    var secret = spy.secret(test_key);
    const receipt = try manager.prepareSet(prior, test_new, &secret, .{});
    var forged = [_]Receipt{receipt} ** 5;
    forged[0].owner ^= 1;
    forged[1].sequence += 1;
    forged[2].pending.old_ref = test_other;
    forged[3].pending.new_ref = test_other;
    forged[4].pending.action = .remove;
    fault.reset();
    for (forged) |bad| try std.testing.expectError(error.InvalidReceipt, publish(&manager, &cfg, bad, test_policy));
    try std.testing.expectEqual(@as(usize, 0), fault.syncs + fault.renames);
    var other_tmp = std.testing.tmpDir(.{});
    defer other_tmp.cleanup();
    const other_root = try testRoot(&other_tmp);
    defer a.free(other_root);
    var foreign = try config.Store.init(a, std.testing.io, other_root);
    defer foreign.deinit();
    try initializeConfig(&foreign);
    try std.testing.expectError(error.ForeignConfig, publish(&manager, &foreign, receipt, test_policy));
    try std.testing.expectError(error.ForeignConfig, manager.recover(try reconcileConfig(&foreign), .{}));
    const publication = try publish(&manager, &cfg, receipt, test_policy);
    try validatePublication(&manager, &cfg, publication);
    for (forged) |bad| {
        var wrong = publication;
        wrong.receipt = bad;
        try std.testing.expectError(error.InvalidReceipt, manager.acknowledge(wrong, .{}));
    }
    var wrong = publication;
    wrong.confirmed.active = test_old;
    try std.testing.expectError(error.InvalidReceipt, manager.acknowledge(wrong, .{}));
    wrong = publication;
    wrong.confirmed.root_id[0] ^= 1;
    try std.testing.expectError(error.ForeignConfig, manager.acknowledge(wrong, .{}));
    try std.testing.expectEqual(@as(usize, 0), vault.deletes);
    // A newer GUI publication invalidates the proof before acknowledgment is queued.
    var latest = cfg.snapshot().*;
    latest.settings.curseforge_credential_ref = &test_other;
    try cfg.update(latest);
    try std.testing.expectError(error.StalePublication, validatePublication(&manager, &cfg, publication));
    try std.testing.expectError(error.StaleReceipt, publish(&manager, &cfg, receipt, test_policy));
    try manager.recover(try reconcileConfig(&cfg), .{});
    try std.testing.expectEqual(@as(usize, 2), vault.deletes);
    try std.testing.expectError(error.InvalidReceipt, manager.acknowledge(publication, .{}));
    try expectNoKey(&tmp);
}

test "CF manager rejects invalid keys same refs and debt reuse before vault mutation" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var cfg = try config.Store.init(a, std.testing.io, root);
    defer cfg.deinit();
    try initializeConfig(&cfg);
    var vault: FakeVault = .{ .root = root };
    var manager = try Manager.init(a, std.testing.io, root, vault.store());
    defer manager.deinit();
    for ([_][]const u8{ "", "space key", "line\nkey", "zero\x00key", "\xff", &(@as([513]u8, @splat('x'))) }) |invalid| {
        const prior = try prepareConfig(&manager, &cfg);
        var spy: WipeSpy = .{};
        var secret = spy.secret(invalid);
        try std.testing.expectError(error.InvalidKey, manager.prepareSet(prior, test_new, &secret, .{}));
        try std.testing.expect(secret.bytes.len == 0);
        try std.testing.expectEqual(@as(usize, if (invalid.len == 0) 0 else 1), spy.frees);
    }
    var prior = try prepareConfig(&manager, &cfg);
    var spy: WipeSpy = .{};
    var secret = spy.secret(test_key);
    try std.testing.expectError(error.InvalidPending, manager.prepareSet(prior, test_old, &secret, .{}));
    prior = try prepareConfig(&manager, &cfg);
    secret = spy.secret(test_key);
    var invalid_ref = test_new;
    invalid_ref[0] = 'A';
    try std.testing.expectError(error.InvalidReference, manager.prepareSet(prior, invalid_ref, &secret, .{}));
    var flag = std.atomic.Value(bool).init(true);
    prior = try prepareConfig(&manager, &cfg);
    secret = spy.secret(test_key);
    try std.testing.expectError(error.Cancelled, manager.prepareSet(prior, test_new, &secret, .{ .flag = &flag }));
    try std.testing.expectEqual(@as(usize, 3), spy.frees);
    try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
    try std.testing.expect(manager.pending() == null and !manager.needsRecovery());
    // A persisted reference debt cannot be used as a fresh ref, even without pending.
    var debt = try journal.Journal.init(a, std.testing.io, root);
    defer debt.deinit();
    try debt.stageSet(test_old, test_new);
    try debt.resolve(test_old);
    var restarted = try Manager.init(a, std.testing.io, root, vault.store());
    defer restarted.deinit();
    try std.testing.expect(restarted.needsRecovery() and restarted.pending() == null);
    secret = spy.secret(test_key);
    try std.testing.expectError(error.RecoveryRequired, restarted.prepareSet(prior, test_new, &secret, .{}));
    // Frozen journal's explicit uniqueness check remains enforced by prepareSet too.
    try std.testing.expectError(error.InvalidPending, debt.stageSet(test_old, test_new));
    try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
    try expectNoKey(&tmp);
}

fn allocationFailures(a: Allocator, recovery: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer std.testing.allocator.free(root);
    var baseline = try config.Store.init(std.testing.allocator, std.testing.io, root);
    defer baseline.deinit();
    try initializeConfig(&baseline);
    var vault: FakeVault = .{ .root = root };
    if (recovery) {
        var staged = try Manager.init(std.testing.allocator, std.testing.io, root, vault.store());
        defer staged.deinit();
        const initial_prior = try prepareConfig(&staged, &baseline);
        var initial_spy: WipeSpy = .{};
        var initial_secret = initial_spy.secret(test_key);
        const initial_receipt = try staged.prepareSet(initial_prior, test_new, &initial_secret, .{});
        _ = try publish(&staged, &baseline, initial_receipt, test_policy);
        try std.testing.expect(initial_secret.bytes.len == 0 and initial_spy.frees == 1);
    }
    var manager = try Manager.init(a, std.testing.io, root, vault.store());
    defer manager.deinit();
    var cfg = try config.Store.init(a, std.testing.io, root);
    defer cfg.deinit();
    if (recovery) {
        try manager.recover(try reconcileConfig(&cfg), .{});
        try std.testing.expect(vault.exists[1] and !vault.exists[0]);
        try expectNoKey(&tmp);
        return;
    }
    const prior = try prepareConfig(&manager, &cfg);
    var spy: WipeSpy = .{};
    var secret = spy.secret(test_key);
    const receipt = manager.prepareSet(prior, test_new, &secret, .{}) catch |err| {
        try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
        try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
        return err;
    };
    try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
    const publication = try publish(&manager, &cfg, receipt, test_policy);
    try manager.acknowledge(publication, .{});
    try std.testing.expect(vault.exists[1] and !vault.exists[0]);
    try expectNoKey(&tmp);
}

test "CF manager allocation failures never leak owned secrets or delete active refs" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{true});
}

test "CF manager cancellation after staging before put retains debt and never initializes native" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var fault: FaultIo = .{};
    const io = fault.start();
    defer fault.stop();
    var cfg = try config.Store.init(a, io, root);
    defer cfg.deinit();
    try initializeConfig(&cfg);
    var flag = std.atomic.Value(bool).init(false);
    var vault: FakeVault = .{ .root = root };
    var manager = try Manager.init(a, io, root, vault.store());
    defer manager.deinit();
    const prior = try prepareConfig(&manager, &cfg);
    try manager.journal.ensureBaseline();
    var spy: WipeSpy = .{};
    var secret = spy.secret(test_key);
    fault.cancel_rename = &flag;
    try std.testing.expectError(error.Cancelled, manager.prepareSet(prior, test_new, &secret, .{ .flag = &flag }));
    try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
    try std.testing.expect(manager.native == null and manager.needsRecovery());
    try std.testing.expect(manager.pending() != null and manager.journal.snapshot().cleanup.len == 2);
    try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
    fault.cancel_rename = null;
    flag.store(false, .release);
    try manager.recover(try reconcileConfig(&cfg), .{});
    try std.testing.expect(manager.native == null and !manager.needsRecovery());
    try std.testing.expectEqual(@as(usize, 0), vault.puts);
    try std.testing.expectEqual(@as(usize, 1), vault.deletes);
    try std.testing.expect(vault.exists[0]);
    try expectNoKey(&tmp);
}

test "CF manager accepts one and 512 byte boundary keys" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_]usize{ 1, 512 }) |len| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var cfg = try config.Store.init(a, std.testing.io, root);
        defer cfg.deinit();
        try initializeConfig(&cfg);
        var vault: FakeVault = .{ .root = root };
        var manager = try Manager.init(a, std.testing.io, root, vault.store());
        defer manager.deinit();
        const prior = try prepareConfig(&manager, &cfg);
        var spy: WipeSpy = .{};
        const bytes: [512]u8 = @splat('~');
        var secret = spy.secret(bytes[0..len]);
        const receipt = try manager.prepareSet(prior, test_new, &secret, .{});
        try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
        const publication = try publish(&manager, &cfg, receipt, test_policy);
        try manager.acknowledge(publication, .{});
        try std.testing.expect(vault.exists[1] and !vault.exists[0]);
    }
}

fn expectMissingJournal(tmp: *std.testing.TmpDir) !void {
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".vela/curseforge-credentials.json", .{}));
}

test "CF first-use config preflight creates durable defaults before cancelled or ambiguous put" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for (0..3) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var cfg = try config.Store.init(a, std.testing.io, root);
        defer cfg.deinit();
        var flag = std.atomic.Value(bool).init(mode == 0);
        var vault: FakeVault = .{ .root = root, .exists = .{ false, false, false }, .fail_put = mode == 1, .cancel_put = if (mode == 2) &flag else null };
        var manager = try Manager.init(a, std.testing.io, root, vault.store());
        defer manager.deinit();
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".vela/config.json", .{}));
        try expectMissingJournal(&tmp);
        const prior = try prepareConfig(&manager, &cfg);
        try std.testing.expect(prior.active == null);
        const stat = try tmp.dir.statFile(std.testing.io, ".vela/config.json", .{});
        try std.testing.expectEqual(@as(u32, 0), stat.permissions.toMode() & 0o022);
        const saved = try tmp.dir.readFileAlloc(std.testing.io, ".vela/config.json", a, .limited(4 * 1024 * 1024));
        defer a.free(saved);
        try std.testing.expect(std.mem.indexOf(u8, saved, test_key) == null);
        try expectMissingJournal(&tmp);
        var spy: WipeSpy = .{};
        var secret = spy.secret(test_key);
        try std.testing.expectError(if (mode == 1) error.Denied else error.Cancelled, manager.prepareSet(prior, test_new, &secret, .{ .flag = &flag }));
        try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
        try std.testing.expectEqual(@as(usize, if (mode == 0) 0 else 1), vault.puts);
        try std.testing.expectEqual(@as(usize, 0), vault.deletes);
        flag.store(false, .release);
        const confirmed = try reconcileConfig(&cfg);
        try std.testing.expect(confirmed.active == null);
        try manager.recover(confirmed, .{});
        try std.testing.expect(!manager.needsRecovery() and manager.pending() == null and manager.native == null);
        try std.testing.expectEqual(@as(usize, if (mode == 0) 0 else 1), vault.deletes);
        if (mode == 0) try expectMissingJournal(&tmp) else try expectNoKey(&tmp);
    }
}

test "CF preflight publication failure invalidates old proof before secret or native staging" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_]usize{ 0, 1, 3 }) |failure| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var fault: FaultIo = .{};
        const io = fault.start();
        defer fault.stop();
        var cfg = try config.Store.init(a, io, root);
        defer cfg.deinit();
        try initializeConfig(&cfg);
        var vault: FakeVault = .{ .root = root };
        var manager = try Manager.init(a, io, root, vault.store());
        defer manager.deinit();
        const prior = try prepareConfig(&manager, &cfg);
        fault.reset();
        if (failure == 0) fault.fail_create = 1 else fault.fail_sync = failure;
        if (prepareConfig(&manager, &cfg)) |_| return error.ExpectedPreflightFailure else |_| {}
        try std.testing.expect(cfg.publicationUncertain() and manager.prepared_config == null);
        const syncs = fault.syncs;
        const creates = fault.creates;
        try std.testing.expectError(error.ConfigPublicationUncertain, prepareConfig(&manager, &cfg));
        try std.testing.expectEqual(syncs, fault.syncs);
        try std.testing.expectEqual(creates, fault.creates);
        var spy: WipeSpy = .{};
        var secret = spy.secret(test_key);
        try std.testing.expectError(error.InvalidPreparation, manager.prepareSet(prior, test_new, &secret, .{}));
        try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
        try std.testing.expect(manager.pending() == null and manager.native == null);
        try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
        try expectMissingJournal(&tmp);
        fault.reset();
        try manager.recover(try reconcileConfig(&cfg), .{});
        _ = try prepareConfig(&manager, &cfg);
        try expectMissingJournal(&tmp);
    }
}

test "CF prepare consumes keys but rejects absent forged foreign and consumed preflight proofs" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for (0..6) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var cfg = try config.Store.init(a, std.testing.io, root);
        defer cfg.deinit();
        var vault: FakeVault = .{ .root = root, .exists = .{ false, false, false } };
        var manager = try Manager.init(a, std.testing.io, root, vault.store());
        defer manager.deinit();
        var prior: DurableConfig = if (mode == 0) .{ .active = null, .root_id = rootId(root) } else try prepareConfig(&manager, &cfg);
        if (mode == 1) prior.root_id[0] ^= 1;
        if (mode == 2) prior.active = test_old;
        if (mode == 3) {
            var invalid = test_old;
            invalid[0] = 'A';
            prior.active = invalid;
        }
        if (mode == 4) try std.testing.expectError(error.NoCredential, manager.prepareRemove(prior, .{}));
        if (mode == 5) {
            var other_tmp = std.testing.tmpDir(.{});
            defer other_tmp.cleanup();
            const other_root = try testRoot(&other_tmp);
            defer a.free(other_root);
            var foreign = try config.Store.init(a, std.testing.io, other_root);
            defer foreign.deinit();
            try std.testing.expectError(error.ForeignConfig, prepareConfig(&manager, &foreign));
            try std.testing.expectError(error.FileNotFound, other_tmp.dir.statFile(std.testing.io, ".vela/config.json", .{}));
        }
        var spy: WipeSpy = .{};
        var secret = spy.secret(test_key);
        try std.testing.expectError(if (mode == 1) error.ForeignConfig else if (mode == 3) error.InvalidReference else error.InvalidPreparation, manager.prepareSet(prior, test_new, &secret, .{}));
        try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
        try std.testing.expectError(error.InvalidPreparation, manager.prepareRemove(.{ .active = test_old, .root_id = rootId(root) }, .{}));
        try std.testing.expect(manager.native == null and manager.pending() == null);
        try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
        try expectMissingJournal(&tmp);
    }
}

test "CF absent journal baseline and first stage filesystem failures explicitly recover without native put" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for (0..8) |failure| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var fault: FaultIo = .{};
        const io = fault.start();
        defer fault.stop();
        var cfg = try config.Store.init(a, io, root);
        defer cfg.deinit();
        try initializeConfig(&cfg);
        var vault: FakeVault = .{ .root = root };
        var manager = try Manager.init(a, io, root, vault.store());
        defer manager.deinit();
        const prior = try prepareConfig(&manager, &cfg);
        try expectMissingJournal(&tmp);
        fault.reset();
        if (failure == 0) fault.fail_create = 1 else if (failure == 7) fault.fail_create = 2 else fault.fail_sync = failure;
        var spy: WipeSpy = .{};
        var secret = spy.secret(test_key);
        if (manager.prepareSet(prior, test_new, &secret, .{})) |_| return error.ExpectedFirstWriteFailure else |_| {}
        try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
        try std.testing.expect(manager.needsRecovery() and manager.native == null);
        try std.testing.expectEqual(failure <= 3, manager.baseline_recovery);
        try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
        fault.reset();
        const confirmed = try reconcileConfig(&cfg);
        fault.reset();
        try manager.recover(confirmed, .{});
        try std.testing.expect(!manager.needsRecovery() and !manager.baseline_recovery and manager.pending() == null);
        try std.testing.expectEqual(@as(usize, if (failure == 6) 1 else 0), vault.deletes);
        try std.testing.expect(vault.exists[0] and manager.native == null);
        try expectNoKey(&tmp);
    }
}

test "CF absent baseline and stage allocation failures wipe secrets and explicitly recover" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |stage| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var cfg = try config.Store.init(a, std.testing.io, root);
        defer cfg.deinit();
        var failing = std.testing.FailingAllocator.init(a, .{});
        var vault: FakeVault = .{ .root = root, .exists = .{ false, false, false } };
        var manager = try Manager.init(failing.allocator(), std.testing.io, root, vault.store());
        defer manager.deinit();
        const prior = try prepareConfig(&manager, &cfg);
        try expectMissingJournal(&tmp);
        if (stage) try manager.journal.ensureBaseline();
        failing.fail_index = failing.alloc_index;
        var spy: WipeSpy = .{};
        var secret = spy.secret(test_key);
        try std.testing.expectError(error.OutOfMemory, manager.prepareSet(prior, test_new, &secret, .{}));
        try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1 and manager.native == null);
        try std.testing.expectEqual(!stage, manager.baseline_recovery);
        try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
        failing.fail_index = std.math.maxInt(usize);
        try manager.recover(try reconcileConfig(&cfg), .{});
        try std.testing.expect(!manager.needsRecovery() and manager.pending() == null);
        try std.testing.expectEqual(@as(usize, 0), vault.puts + vault.deletes);
        try expectNoKey(&tmp);
    }
}

test "CF baseline retry reloads appeared pending and debt without overwriting protected references" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |pending| {
        for ([_]?Reference{ test_old, test_new, null }) |protected| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const root = try testRoot(&tmp);
            defer a.free(root);
            var fault: FaultIo = .{};
            const io = fault.start();
            defer fault.stop();
            var cfg = try config.Store.init(a, io, root);
            defer cfg.deinit();
            try initializeConfig(&cfg);
            var vault: FakeVault = .{ .root = root, .exists = .{ true, true, false } };
            var manager = try Manager.init(a, io, root, vault.store());
            defer manager.deinit();
            const prior = try prepareConfig(&manager, &cfg);
            fault.reset();
            fault.fail_create = 1;
            var spy: WipeSpy = .{};
            var secret = spy.secret(test_key);
            try std.testing.expectError(error.PersistenceFailure, manager.prepareSet(prior, test_new, &secret, .{}));
            try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1 and manager.baseline_recovery);
            fault.reset();
            var appeared = try journal.Journal.init(a, std.testing.io, root);
            defer appeared.deinit();
            try appeared.stageSet(test_old, test_new);
            if (!pending) try appeared.resolve(null);
            try std.testing.expectError(error.JournalChanged, manager.journal.ensureBaseline());
            var latest = cfg.snapshot().*;
            latest.settings.curseforge_credential_ref = if (protected) |*ref| ref else null;
            try cfg.update(latest);
            try manager.recover(try reconcileConfig(&cfg), .{});
            try std.testing.expect(!manager.needsRecovery() and manager.pending() == null and manager.native == null);
            try std.testing.expectEqual(@as(usize, 0), vault.puts);
            try std.testing.expectEqual(@as(usize, if (protected == null) 2 else 1), vault.deletes);
            if (protected) |ref| try std.testing.expect(vault.exists[FakeVault.index(&ref)]);
            try expectNoKey(&tmp);
        }
    }
}

test "CF successful baseline or stage never authorizes resetting a disappeared journal" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |staged| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var cfg = try config.Store.init(a, std.testing.io, root);
        defer cfg.deinit();
        try initializeConfig(&cfg);
        var vault: FakeVault = .{ .root = root };
        var manager = try Manager.init(a, std.testing.io, root, vault.store());
        defer manager.deinit();
        const prior = try prepareConfig(&manager, &cfg);
        try manager.journal.ensureBaseline();
        var spy: WipeSpy = .{};
        var secret = spy.secret(test_key);
        if (staged) _ = try manager.prepareSet(prior, test_new, &secret, .{});
        try tmp.dir.deleteFile(std.testing.io, ".vela/curseforge-credentials.json");
        if (!staged) try std.testing.expectError(error.JournalChanged, manager.prepareSet(prior, test_new, &secret, .{}));
        try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
        try std.testing.expect(!manager.baseline_recovery);
        try std.testing.expectError(error.JournalChanged, manager.recover(try reconcileConfig(&cfg), .{}));
        try std.testing.expect(manager.needsRecovery() and manager.native == null);
        try std.testing.expectEqual(@as(usize, if (staged) 1 else 0), vault.puts);
        try std.testing.expectEqual(@as(usize, 0), vault.deletes);
        try expectMissingJournal(&tmp);
    }
}

const WindowsOwnerFake = @import("auth_cleanup_test.zig").WindowsFake;
const windows_owner_fs = @import("windows_durable_fs.zig");
const windows_test_root = "C:/owned/launcher";
fn windowsManagerConfig(allocator: Allocator, fake: *WindowsOwnerFake) !config.Store {
    var owned: ?windows_owner_fs.Root = try windows_owner_fs.openRootWithOps(allocator, windows_test_root, .ordinary_config, fake.nativeOps());
    return config.Store.initWithOwnedRoot(allocator, std.testing.io, &owned);
}
fn windowsManagerJournal(allocator: Allocator, fake: *WindowsOwnerFake) !journal.Journal {
    return journal.Journal.initWithNativeOps(allocator, std.testing.io, windows_test_root, fake.nativeOps(), .{ .context = fake, .open = WindowsOwnerFake.reopen });
}
fn windowsManager(allocator: Allocator, fake: *WindowsOwnerFake, vault: *WindowsVault) !Manager {
    var owned: ?journal.Journal = try windowsManagerJournal(allocator, fake);
    return Manager.initWithOwnedJournal(&owned, vault.store());
}
/// These callbacks inspect authoritative owner bytes using fresh owned capabilities.
/// Contexts stay at their final stack address and no native vault is initialized.
const WindowsVault = struct {
    config_fs: *WindowsOwnerFake,
    journal_fs: *WindowsOwnerFake,
    puts: usize = 0,
    deletes: usize = 0,
    exists: [3]bool = .{ true, false, false },
    deleted: [3]bool = .{ false, false, false },
    const vtable: credentials.Store.VTable = .{ .put = put, .get = get, .delete = delete };
    fn store(self: *WindowsVault) credentials.Store {
        return .{ .ctx = self, .vtable = &vtable };
    }
    fn index(ref: []const u8) usize {
        std.debug.assert(ref.len == 32 and ref[0] >= '0' and ref[0] <= '2');
        return ref[0] - '0';
    }
    fn put(ctx: *anyopaque, ref: []const u8, bytes: []const u8) credentials.Error!void {
        const self: *WindowsVault = @ptrCast(@alignCast(ctx));
        self.puts += 1;
        var disk = windowsManagerJournal(std.testing.allocator, self.journal_fs) catch return error.StorageFailure;
        defer disk.deinit();
        const staged = disk.snapshot().pending orelse return error.StorageFailure;
        if (staged.action != .set or !same(staged.new_ref, ref[0..32].*)) return error.StorageFailure;
        if (!std.mem.eql(u8, bytes, test_key)) return error.InvalidSecret;
        if (std.mem.indexOf(u8, self.journal_fs.diskBytes(), bytes) != null) return error.StorageFailure;
        self.exists[index(ref)] = true;
    }
    fn get(_: *anyopaque, _: Allocator, _: []const u8) credentials.Error!credentials.Secret {
        return error.StorageFailure;
    }
    fn delete(ctx: *anyopaque, ref: []const u8) credentials.Error!void {
        const self: *WindowsVault = @ptrCast(@alignCast(ctx));
        var disk = windowsManagerJournal(std.testing.allocator, self.journal_fs) catch return error.StorageFailure;
        defer disk.deinit();
        if (disk.snapshot().pending != null) return error.StorageFailure;
        var cfg = windowsManagerConfig(std.testing.allocator, self.config_fs) catch return error.StorageFailure;
        defer cfg.deinit();
        if (same(activeReference(cfg.snapshot().settings) catch return error.StorageFailure, ref[0..32].*)) return error.Denied;
        self.deletes += 1;
        self.deleted[index(ref)] = true;
        const existed = self.exists[index(ref)];
        self.exists[index(ref)] = false;
        if (!existed) return error.NotFound;
    }
};

test "Windows manager stage faults wipe owned secret and prevent all vault puts" {
    const a = std.testing.allocator;
    for (0..4) |which| {
        var config_fs: WindowsOwnerFake = .{};
        var journal_fs: WindowsOwnerFake = .{};
        var vault: WindowsVault = .{ .config_fs = &config_fs, .journal_fs = &journal_fs };
        var cfg = try windowsManagerConfig(a, &config_fs);
        defer cfg.deinit();
        try cfg.update(.{ .settings = .{ .curseforge_credential_ref = &test_old } });
        var manager = try windowsManager(a, &journal_fs, &vault);
        defer manager.deinit();
        try manager.journal.ensureBaseline();
        const prior = try prepareConfig(&manager, &cfg);
        if (which == 0) journal_fs.failure = .write;
        if (which == 1) journal_fs.failure = .move_after;
        if (which == 2) {
            journal_fs.drift_at_load = journal_fs.load_count + 2;
            journal_fs.drift_bytes = "{broken";
        }
        if (which == 3) journal_fs.cancel_before = true;
        var spy: WipeSpy = .{};
        var secret = spy.secret(test_key);
        try std.testing.expectError(if (which == 1) error.CommitUncertain else if (which == 2) error.InvalidJournal else error.PersistenceFailure, manager.prepareSet(prior, test_new, &secret, .{}));
        try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
        try std.testing.expect(vault.puts == 0 and vault.deletes == 0 and manager.native == null);
        try std.testing.expect(manager.needsRecovery() and !journal_fs.temp_open);
    }
}

test "Windows manager ambiguous acknowledgment retains debt and recovery preserves config protected reference" {
    const a = std.testing.allocator;
    var config_fs: WindowsOwnerFake = .{};
    var journal_fs: WindowsOwnerFake = .{};
    var vault: WindowsVault = .{ .config_fs = &config_fs, .journal_fs = &journal_fs };
    var cfg = try windowsManagerConfig(a, &config_fs);
    defer cfg.deinit();
    try cfg.update(.{ .settings = .{ .curseforge_credential_ref = &test_old } });
    var manager = try windowsManager(a, &journal_fs, &vault);
    defer manager.deinit();
    const prior = try prepareConfig(&manager, &cfg);
    var spy: WipeSpy = .{};
    var secret = spy.secret(test_key);
    const receipt = try manager.prepareSet(prior, test_new, &secret, .{});
    try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1 and vault.puts == 1);
    const publication = try publish(&manager, &cfg, receipt, test_policy);
    journal_fs.failure = .move_after;
    try std.testing.expectError(error.CommitUncertain, manager.acknowledge(publication, .{}));
    try std.testing.expect(manager.pending() != null and manager.journal.snapshot().cleanup.len == 2 and vault.deletes == 0);
    try std.testing.expect(manager.journal.poisoned() and manager.journal.windows_root.?.publication_uncertain);
    journal_fs.failure = .none;
    const confirmed = try reconcileConfig(&cfg);
    try manager.recover(confirmed, .{});
    try std.testing.expect(!manager.needsRecovery() and manager.pending() == null and manager.journal.snapshot().cleanup.len == 0);
    try std.testing.expect(vault.deletes == 1 and vault.deleted[0] and !vault.deleted[1] and vault.exists[1]);
    try std.testing.expect(same(try activeReference(cfg.snapshot().settings), test_new));
    try manager.recover(confirmed, .{});
    try std.testing.expect(vault.deletes == 1);
    try std.testing.expect(std.mem.indexOf(u8, config_fs.diskBytes(), test_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, journal_fs.diskBytes(), test_key) == null);
}

test "Windows manager ambiguous config publication waits for authoritative reconciliation before deletion" {
    const a = std.testing.allocator;
    var config_fs: WindowsOwnerFake = .{};
    var journal_fs: WindowsOwnerFake = .{};
    var vault: WindowsVault = .{ .config_fs = &config_fs, .journal_fs = &journal_fs };
    var cfg = try windowsManagerConfig(a, &config_fs);
    defer cfg.deinit();
    try cfg.update(.{ .settings = .{ .curseforge_credential_ref = &test_old } });
    var manager = try windowsManager(a, &journal_fs, &vault);
    defer manager.deinit();
    const prior = try prepareConfig(&manager, &cfg);
    var spy: WipeSpy = .{};
    var secret = spy.secret(test_key);
    const receipt = try manager.prepareSet(prior, test_new, &secret, .{});
    config_fs.failure = .move_after;
    try std.testing.expectError(error.CommitUncertain, publish(&manager, &cfg, receipt, test_policy));
    try std.testing.expect(cfg.publicationUncertain() and manager.pending() != null and vault.deletes == 0 and vault.puts == 1);
    try std.testing.expect(same(try activeReference(cfg.snapshot().settings), test_old));
    try std.testing.expectError(error.ConfigPublicationUncertain, cfg.update(.{}));
    config_fs.failure = .none;
    const confirmed = try reconcileConfig(&cfg);
    try std.testing.expect(same(confirmed.active, test_new));
    try manager.recover(confirmed, .{});
    try std.testing.expect(vault.deletes == 1 and vault.deleted[0] and !vault.deleted[1] and !manager.needsRecovery());
    try std.testing.expect(secret.bytes.len == 0 and spy.frees == 1);
}

test "Windows manager consumed journal capability closes exactly once for clean dirty and poisoned owners" {
    var absent: ?journal.Journal = null;
    try std.testing.expectError(error.InvalidJournal, Manager.initWithOwnedJournal(&absent, null));
    for (0..3) |which| {
        var fake: WindowsOwnerFake = .{};
        var owned: ?journal.Journal = try windowsManagerJournal(std.testing.allocator, &fake);
        try owned.?.ensureBaseline();
        if (which == 1) try owned.?.stageSet(null, test_new);
        if (which == 2) {
            fake.failure = .write;
            try std.testing.expectError(error.PersistenceFailure, owned.?.stageSet(null, test_new));
        }
        var manager = try Manager.initWithOwnedJournal(&owned, null);
        try std.testing.expect(owned == null and manager.native == null and manager.needsRecovery() == (which != 0));
        manager.deinit();
        try std.testing.expect(fake.opens == 1 and fake.closes == 1 and !fake.temp_open);
    }
}

fn windowsManagerAllocationScenario(allocator: Allocator) !void {
    var config_fs: WindowsOwnerFake = .{};
    var journal_fs: WindowsOwnerFake = .{};
    defer std.debug.assert(config_fs.opens == config_fs.closes and journal_fs.opens == journal_fs.closes and !config_fs.temp_open and !journal_fs.temp_open);
    var vault: WindowsVault = .{ .config_fs = &config_fs, .journal_fs = &journal_fs };
    var cfg = try windowsManagerConfig(allocator, &config_fs);
    defer cfg.deinit();
    var manager = try windowsManager(allocator, &journal_fs, &vault);
    defer manager.deinit();
    const prior = try prepareConfig(&manager, &cfg);
    var spy: WipeSpy = .{};
    var secret = spy.secret(test_key);
    defer secret.deinit();
    const receipt = try manager.prepareSet(prior, test_new, &secret, .{});
    const publication = try publish(&manager, &cfg, receipt, test_policy);
    try manager.acknowledge(publication, .{});
}
test "Windows manager allocation failures release consumed journal config and secret ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, windowsManagerAllocationScenario, .{});
}
