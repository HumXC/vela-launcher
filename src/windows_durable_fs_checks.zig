//! COMPILE ONLY: do not run or call these exports against a real launcher root.
//! Forces Windows native adapter operations reachable for x64 and ARM64 builds.
//! Parent owns execution after its release gate; this file does not run tests.
const std = @import("std");
const builtin = @import("builtin");
const fs = @import("core/windows_durable_fs.zig");

comptime {
    if (builtin.os.tag != .windows) @compileError("windows_durable_fs_checks.zig requires a Windows target; do not execute it");
}

fn checkCurrent(_: ?*anyopaque, root: *fs.Root) anyerror!void {
    const leaf: []const u8 = if (root.privacy == .ordinary_config) "config.json" else "auth-cleanup.json";
    const limit: usize = if (root.privacy == .ordinary_config) fs.config_limit else fs.journal_limit;
    var owned = try fs.load(root, root.allocator, leaf, limit);
    defer if (owned) |*bytes| bytes.deinit();
}

export fn force_windows_private_publication(a: *const std.mem.Allocator, io: *const std.Io, path: [*]const u8, path_len: usize) void {
    var root = fs.openRoot(a.*, io.*, path[0..path_len], .private_journal) catch return;
    defer fs.deinit(&root);
    var auth = fs.load(&root, a.*, "auth-cleanup.json", fs.journal_limit) catch return;
    defer if (auth) |*bytes| bytes.deinit();
    var cf = fs.load(&root, a.*, "curseforge-credentials.json", fs.journal_limit) catch return;
    defer if (cf) |*bytes| bytes.deinit();
    const check: fs.PrecommitCheck = .{ .run = checkCurrent };
    const references_only = "{\"schemaVersion\":1,\"references\":[]}";
    fs.publish(&root, "auth-cleanup.json", references_only, check) catch {};
    fs.publish(&root, "curseforge-credentials.json", if (cf) |bytes| bytes.bytes else "{}", check) catch {};
    if (auth) |bytes| fs.reconcile(&root, "auth-cleanup.json", bytes.bytes, check) catch {};
    _ = root.publicationUncertain();
}

export fn force_windows_config_publication(a: *const std.mem.Allocator, io: *const std.Io, path: [*]const u8, path_len: usize) void {
    var root = fs.openRoot(a.*, io.*, path[0..path_len], .ordinary_config) catch return;
    defer fs.deinit(&root);
    var disk = fs.load(&root, a.*, "config.json", fs.config_limit) catch return;
    defer if (disk) |*bytes| bytes.deinit();
    const check: fs.PrecommitCheck = .{ .run = checkCurrent };
    if (disk) |bytes| {
        fs.publish(&root, "config.json", bytes.bytes, check) catch {};
        fs.reconcile(&root, "config.json", bytes.bytes, check) catch {};
    }
}

// Forced owner semantics only; these exports must never be executed as a test.
const config = @import("core/config.zig");
const auth_cleanup = @import("core/auth_cleanup.zig");
const cf_journal = @import("core/curseforge_credentials_journal.zig");
const cf_manager = @import("core/curseforge_credentials_manager.zig");
const credentials = @import("core/credentials.zig");

export fn force_windows_config_owner(a: *const std.mem.Allocator, io: *const std.Io, path: [*]const u8, path_len: usize) void {
    var owned: ?fs.Root = fs.openRoot(a.*, io.*, path[0..path_len], .ordinary_config) catch return;
    var store = config.Store.initWithOwnedRoot(a.*, io.*, &owned) catch return;
    defer store.deinit();
    store.prepareStorage() catch {};
    store.update(.{}) catch {};
    store.reconcile() catch {};
    _ = store.publicationUncertain();
    _ = store.snapshot();
    var native = config.Store.init(a.*, io.*, path[0..path_len]) catch return;
    native.deinit();
}

export fn force_windows_private_owners(a: *const std.mem.Allocator, io: *const std.Io, path: [*]const u8, path_len: usize) void {
    const ref: credentials.Reference = @splat('0');
    var owned: ?fs.Root = fs.openRoot(a.*, io.*, path[0..path_len], .private_journal) catch return;
    var auth = auth_cleanup.Journal.initWithOwnedRoot(a.*, io.*, &owned) catch return;
    defer auth.deinit();
    auth.stage(ref) catch {};
    auth.remove(ref) catch {};
    _ = auth.references();
    var native_auth = auth_cleanup.Journal.init(a.*, io.*, path[0..path_len]) catch return;
    native_auth.deinit();
    var debt = cf_journal.Journal.init(a.*, io.*, path[0..path_len]) catch return;
    defer debt.deinit();
    debt.ensureBaseline() catch {};
    debt.stageSet(null, ref) catch {};
    debt.resolve(null) catch {};
    debt.stageRemove(ref) catch {};
    debt.forget(ref) catch {};
    debt.reload() catch {};
    _ = debt.poisoned();
    _ = debt.snapshot();
}

export fn force_windows_manager_owner(a: *const std.mem.Allocator, io: *const std.Io, path: [*]const u8, path_len: usize) void {
    var cfg = config.Store.init(a.*, io.*, path[0..path_len]) catch return;
    defer cfg.deinit();
    cfg.prepareStorage() catch return;
    var owned: ?cf_journal.Journal = cf_journal.Journal.init(a.*, io.*, path[0..path_len]) catch return;
    var manager = cf_manager.Manager.initWithOwnedJournal(&owned, null) catch return;
    defer manager.deinit();
    const prior = cf_manager.prepareConfig(&manager, &cfg) catch return;
    var secret: credentials.Secret = .{ .allocator = a.*, .bytes = a.dupe(u8, "CF-COMPILE-CANARY-NOT-A-REAL-KEY") catch return };
    defer secret.deinit();
    const receipt = manager.prepareSet(prior, @splat('1'), &secret, .{}) catch return;
    const publication = cf_manager.publish(&manager, &cfg, receipt, .{ .enabled = true, .terms_approved = true }) catch return;
    cf_manager.validatePublication(&manager, &cfg, publication) catch {};
    manager.acknowledge(publication, .{}) catch {};
    manager.recover(cf_manager.reconcileConfig(&cfg) catch return, .{}) catch {};
    _ = manager.prepareRemove(cf_manager.prepareConfig(&manager, &cfg) catch return, .{}) catch return;
    var native = cf_manager.Manager.init(a.*, io.*, path[0..path_len], null) catch return;
    native.deinit();
}
