const std = @import("std");
const builtin = @import("builtin");
const curl = @import("curl");
const fs = @import("content_fs.zig");
const manifest = @import("content_manifest.zig");
const providers = @import("content_providers.zig");
const instances = @import("instances.zig");
const downloader = @import("downloader.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const Fingerprint = fs.Fingerprint;
const transaction_directory = ".vela-content";
const max_journal_bytes = 16 * 1024 * 1024;

/// Parent callbacks must acquire the real instance transaction gate and running reservation.
/// The reservation remains held through staging, mutations, recovery and worker joining.
pub const Lease = struct {
    context: ?*anyopaque,
    acquire: *const fn (?*anyopaque, []const u8) anyerror!void,
    recheck: *const fn (?*anyopaque, []const u8) anyerror!void,
    release: *const fn (?*anyopaque, []const u8) void,
};
pub const ManualFile = struct { path: []const u8, source_absolute_path: []const u8 };
pub const FetchRequest = struct {
    url: []const u8,
    directory: Dir,
    name: []const u8,
    absolute_path: []const u8,
    max_bytes: u64,
    expected_size: ?u64,
    expected_sha1: ?[20]u8,
    expected_sha256: ?[32]u8 = null,
    expected_sha512: ?[64]u8 = null,
    deadline_ns: ?i96,
    cancel: ?*const std.atomic.Value(bool),
};
/// Only transport is injectable. Transaction, hash verification and filesystem operations are real.
pub const Fetcher = struct {
    context: ?*anyopaque,
    fetchToFile: *const fn (?*anyopaque, Io, FetchRequest) anyerror!void,
};
pub const FaultPoint = enum {
    before_backup,
    after_backup,
    before_journal,
    after_journal,
    before_mutation,
    after_mutation,
    before_manifest,
    after_manifest,
    before_commit_marker,
    after_commit_marker,
    rollback_mutation,
    rollback_manifest,
};
pub const Fault = struct {
    context: ?*anyopaque,
    boundary: *const fn (?*anyopaque, FaultPoint, usize) anyerror!void,
};
pub const Options = struct {
    paths: *const instances.Paths,
    instance_id: []const u8,
    instance_name: []const u8,
    plan: manifest.UpdatePlan,
    files: []const manifest.InstallFile,
    lease: Lease,
    pack: ?manifest.PackPlan = null,
    prerequisites: manifest.CompletionPrerequisites = .{},
    manual_files: []const ManualFile = &.{},
    allow_partial: bool = false,
    allow_curseforge_remote: bool = false,
    cancel: ?*const std.atomic.Value(bool) = null,
    deadline_ns: ?i96 = null,
    fetcher: ?Fetcher = null,
    /// Required when the production fetcher opens a network transfer.
    download_budget: ?*downloader.Budget = null,
    proxy: ?[]const u8 = null,
    ca_bundle: ?[]const u8 = null,
    /// Exact trusted hosts, never suffix patterns; non-CDN pack sources need explicit approval.
    approved_download_hosts: []const []const u8 = &.{"cdn.modrinth.com"},
    fault: ?Fault = null,
};
pub const RecoverOptions = struct {
    paths: *const instances.Paths,
    instance_id: []const u8,
    instance_name: []const u8,
    transaction_id: []const u8,
    lease: Lease,
    fault: ?Fault = null,
};
pub const Report = struct {
    allocator: A,
    backup_directory: []u8,
    transaction_id: []const u8,
    applied_files: usize = 0,
    kept_local: usize = 0,
    fully_applied: bool = false,
    complete: bool = false,
    completeness: ?manifest.Completeness = null,
    committed: bool = false,
    recovered: bool = false,
    pub fn deinit(self: *Report) void {
        self.allocator.free(self.backup_directory);
        self.* = undefined;
    }
};
const Entry = struct {
    path: []const u8,
    kind: enum { install, remove },
    before: ?Fingerprint,
    after: ?Fingerprint,
};
const Journal = struct {
    schema_version: u32,
    instance_id: []const u8,
    instance_name: []const u8,
    transaction_id: []const u8,
    fully_applied: bool,
    kept_local: usize,
    entries: []const Entry,
    manifest_before: ?Fingerprint,
    manifest_after: Fingerprint,
    manifest_temp: []const u8,
};
const Roots = struct {
    game: Dir,
    metadata: Dir,
    transactions: Dir,
    fn open(io: Io, paths: *const instances.Paths, id: []const u8, name: []const u8, create: bool) !Roots {
        if (!fs.safeComponent(id) or !fs.safeComponent(name)) return error.UnsafeInstance;
        const root = try fs.openAbsolute(io, paths.root);
        defer root.close(io);
        const minecraft = try fs.child(root, io, ".minecraft", false, false);
        defer minecraft.close(io);
        const versions = try fs.child(minecraft, io, "versions", false, false);
        defer versions.close(io);
        const game = try fs.child(versions, io, name, false, false);
        errdefer game.close(io);
        const vela = try fs.child(root, io, ".vela", create, false);
        defer vela.close(io);
        const instance_metadata = try fs.child(vela, io, "instances", create, false);
        defer instance_metadata.close(io);
        const metadata = try fs.child(instance_metadata, io, id, create, false);
        errdefer metadata.close(io);
        const transactions = try fs.child(game, io, transaction_directory, create, true);
        errdefer transactions.close(io);
        return .{ .game = game, .metadata = metadata, .transactions = transactions };
    }
    fn deinit(self: Roots, io: Io) void {
        self.transactions.close(io);
        self.metadata.close(io);
        self.game.close(io);
    }
};

fn checkpoint(fault: ?Fault, point: FaultPoint, index: usize) !void {
    if (fault) |f| try f.boundary(f.context, point, index);
}
fn safeManagedPath(path: []const u8) bool {
    if (!manifest.safeRelativePath(path) or manifest.protectedPath(path)) return false;
    if (manifest.pathsCollide(path, transaction_directory)) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| if (!fs.safeComponent(part)) return false;
    return true;
}
fn optionalHashEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return if (b) |right| std.ascii.eqlIgnoreCase(left, right) else false;
    return b == null;
}
fn sameHashes(a: providers.Hashes, b: providers.Hashes) bool {
    if (!optionalHashEqual(a.sha1, b.sha1) or !optionalHashEqual(a.sha512, b.sha512)) return false;
    if (!optionalHashEqual(a.sha256, b.sha256)) return false;
    return true;
}
fn sameRecord(a: manifest.ManagedFile, b: manifest.ManagedFile) bool {
    return std.mem.eql(u8, a.path, b.path) and a.provider == b.provider and
        std.mem.eql(u8, a.project_id, b.project_id) and std.mem.eql(u8, a.version_id, b.version_id) and
        sameHashes(a.hashes, b.hashes) and a.size == b.size and a.role == b.role and a.enabled == b.enabled and
        a.identity_provenance == b.identity_provenance and a.standalone == b.standalone;
}
fn oppositePath(a: A, file: manifest.ManagedFile) ![]u8 {
    var opposite = file;
    opposite.enabled = !file.enabled;
    return manifest.physicalPath(a, opposite);
}
fn requireCounterpartAbsent(a: A, io: Io, game: Dir, file: manifest.ManagedFile) !void {
    if (!manifest.toggleable(file)) return;
    const path = try oppositePath(a, file);
    defer a.free(path);
    const leaf = fs.parent(game, io, path, false) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer leaf.deinit(io);
    if (try fs.inspectEntry(leaf.dir, io, leaf.name) != null) return error.PathAlreadyExists;
}
fn validateOwnershipTransition(previous: manifest.Manifest, plan: manifest.UpdatePlan) !void {
    const next = plan.next_manifest;
    for (previous.files) |old| if (findRecord(next.files, old.path)) |current| {
        if (old.enabled != current.enabled) return error.InvalidEnabledTransition;
    };
    if (plan.fully_applied) return;
    // Partial application may retain old membership, never claim a new pack/version.
    const membership = next.pack_membership orelse return;
    const prior = previous.pack_membership orelse return error.InvalidPackOwnershipTransition;
    if (membership.identity.provider != prior.identity.provider or
        !std.mem.eql(u8, membership.identity.project_id, prior.identity.project_id) or
        !std.mem.eql(u8, membership.identity.version_id, prior.identity.version_id)) return error.InvalidPackOwnershipTransition;
    for (membership.paths) |path| {
        var was_member = false;
        for (prior.paths) |old_path| if (std.mem.eql(u8, old_path, path)) {
            was_member = true;
            break;
        };
        if (!was_member) return error.InvalidPackOwnershipTransition;
        const old = findRecord(previous.files, path) orelse return error.InvalidPackOwnershipTransition;
        const current = findRecord(next.files, path) orelse return error.InvalidPackOwnershipTransition;
        if (!sameRecord(old, current)) return error.InvalidPackOwnershipTransition;
    }
}
fn findRecord(files: []const manifest.ManagedFile, path: []const u8) ?manifest.ManagedFile {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return file;
    return null;
}
fn findInstall(files: []const manifest.InstallFile, desired: manifest.ManagedFile) !manifest.InstallFile {
    for (files) |file| if (std.mem.eql(u8, file.record.path, desired.path)) {
        if (!sameRecord(file.record, desired)) return error.DownloadRecordMismatch;
        if (file.selected == false or (!file.required and file.selected == null)) return error.OptionalSelectionRequired;
        return file;
    };
    return error.MissingDownload;
}
fn validateOptionPaths(options: Options) !void {
    if (options.plan.actions.len > providers.max_items * 2 or options.files.len > providers.max_items or
        options.manual_files.len > providers.max_items or options.plan.conflicts.len > providers.max_items * 2) return error.TooManyItems;
    if (options.pack) |pack| {
        if (pack.initial_world_files.len != 0) return error.ProtectedPath;
        if (pack.files.len > providers.max_items) return error.TooManyItems;
    }
    if (options.instance_id.len == 0 or options.instance_id.len > manifest.max_path_bytes or
        options.instance_name.len == 0 or options.instance_name.len > manifest.max_path_bytes) return error.UnsafeInstance;
    if (!fs.safeComponent(options.instance_id) or !fs.safeComponent(options.instance_name)) return error.UnsafeInstance;
    try manifest.validatePathsForInstance(options.plan.next_manifest, options.instance_name);
    for (options.files) |file| try manifest.checkedPathForInstance(file.record.path, options.instance_name);
    for (options.manual_files) |file| try manifest.checkedPathForInstance(file.path, options.instance_name);
    if (options.pack) |pack| for (pack.files) |file| try manifest.checkedPathForInstance(file.record.path, options.instance_name);
    for (options.plan.actions) |action| {
        try manifest.checkedPathForInstance(action.path, options.instance_name);
        if (action.previous) |file| try manifest.checkedPathForInstance(file.path, options.instance_name);
        if (action.desired) |file| try manifest.checkedPathForInstance(file.path, options.instance_name);
    }
    for (options.plan.conflicts) |conflict| try manifest.checkedPathForInstance(conflict.path, options.instance_name);
    // All supplied views name one filesystem tree. Exact repeated file references
    // are intentional; alternate spellings of a shared directory are not.
    for (options.plan.next_manifest.files) |file| try validateInputPath(options, file.path);
    for (options.files) |file| try validateInputPath(options, file.record.path);
    for (options.manual_files) |file| try validateInputPath(options, file.path);
    if (options.pack) |pack| for (pack.files) |file| try validateInputPath(options, file.record.path);
    for (options.plan.actions) |action| {
        try validateInputPath(options, action.path);
        if (action.previous) |file| try validateInputPath(options, file.path);
        if (action.desired) |file| try validateInputPath(options, file.path);
    }
    for (options.plan.conflicts) |conflict| try validateInputPath(options, conflict.path);
}
fn requireConsistentPath(path: []const u8, other: []const u8) !void {
    if (!std.mem.eql(u8, path, other) and manifest.pathsCollide(path, other)) return error.PathCollision;
}
fn validateInputPath(options: Options, path: []const u8) !void {
    for (options.plan.next_manifest.files) |file| try requireConsistentPath(path, file.path);
    for (options.files) |file| try requireConsistentPath(path, file.record.path);
    for (options.manual_files) |file| try requireConsistentPath(path, file.path);
    if (options.pack) |pack| for (pack.files) |file| try requireConsistentPath(path, file.record.path);
    for (options.plan.actions) |action| {
        try requireConsistentPath(path, action.path);
        if (action.previous) |file| try requireConsistentPath(path, file.path);
        if (action.desired) |file| try requireConsistentPath(path, file.path);
    }
    for (options.plan.conflicts) |conflict| try requireConsistentPath(path, conflict.path);
}
fn validateOptions(options: Options) !void {
    try validateOptionPaths(options);
    if (!options.plan.ready) return error.UnresolvedConflicts;
    if (!options.plan.fully_applied and !options.allow_partial) return error.PartialPlanNeedsConsent;
    try manifest.validate(options.plan.next_manifest);
    if (!std.mem.eql(u8, options.instance_id, options.plan.next_manifest.instance_id)) return error.InstanceMismatch;
    for (options.files, 0..) |file, index| {
        try manifest.validate(.{ .instance_id = options.instance_id, .pack_version = options.plan.next_manifest.pack_version, .files = &.{file.record} });
        if (!safeManagedPath(file.record.path)) return error.ProtectedPath;
        for (options.files[0..index]) |other| if (manifest.pathsCollide(file.record.path, other.record.path)) return error.PathCollision;
    }
    for (options.plan.next_manifest.files) |file| if (!safeManagedPath(file.path)) return error.ProtectedPath;
    for (options.plan.actions, 0..) |action, index| {
        if (!safeManagedPath(action.path)) return error.ProtectedPath;
        if (action.expected_before) |hashes| try providers.validateHashes(hashes);
        if (action.kind == .backup) {
            if (action.expected_before == null or index + 1 >= options.plan.actions.len) return error.InvalidActionSequence;
            const next = options.plan.actions[index + 1];
            if (next.kind == .backup or !std.mem.eql(u8, next.path, action.path) or next.expected_before == null or
                !sameHashes(action.expected_before.?, next.expected_before.?) or action.expected_size != next.expected_size) return error.InvalidActionSequence;
            continue;
        }
        if (action.expected_before != null and (index == 0 or options.plan.actions[index - 1].kind != .backup)) return error.BackupRequired;
        if (action.kind == .remove and (action.expected_before == null or action.desired != null or findRecord(options.plan.next_manifest.files, action.path) != null)) return error.InvalidActionSequence;
        if (action.kind == .install) {
            const desired = action.desired orelse return error.MissingDesiredRecord;
            const record = findRecord(options.plan.next_manifest.files, action.path) orelse return error.MissingDesiredRecord;
            if (!sameRecord(desired, record)) return error.DownloadRecordMismatch;
            const install_file = try findInstall(options.files, desired);
            try validateDownload(options, install_file);
        }
        for (options.plan.actions[0..index]) |other| if (other.kind != .backup and manifest.pathsCollide(action.path, other.path)) return error.PathCollision;
    }
}
fn equalOptional(a: ?Fingerprint, b: ?Fingerprint) bool {
    if (a) |left| return if (b) |right| left.eql(right) else false;
    return b == null;
}
fn requireCurrent(dir: Dir, io: Io, path: []const u8, expected: ?Fingerprint, cancel: ?*const std.atomic.Value(bool), deadline: ?i96) !void {
    if (!equalOptional(try fs.fingerprint(dir, io, path, cancel, deadline), expected)) return error.LocalFileChanged;
}
fn numbered(a: A, prefix: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(a, "{s}-{d}", .{ prefix, index });
}
fn copyPath(source_dir: Dir, source_path: []const u8, dest: Dir, dest_name: []const u8, io: Io, limit: u64, cancel: ?*const std.atomic.Value(bool), deadline: ?i96) !Fingerprint {
    const leaf = try fs.parent(source_dir, io, source_path, false);
    defer leaf.deinit(io);
    const source = try fs.openRegular(leaf.dir, io, leaf.name);
    defer source.close(io);
    return fs.copy(source, dest, io, dest_name, limit, cancel, deadline);
}
fn validateDownload(options: Options, file: manifest.InstallFile) !void {
    if (file.download != .remote) return;
    if (file.record.provider == .curseforge) {
        if (!options.allow_curseforge_remote) return error.CurseForgeManualRequired;
        if (file.record.identity_provenance != .official_file) return error.InvalidRemoteAuthorization;
        try providers.validateRemoteAuthorization(.curseforge, file.record.project_id, file.record.version_id, .{
            .filename = std.fs.path.basename(file.record.path),
            .hashes = file.record.hashes,
            .size = file.record.size,
            .download = file.download,
            .authorization = file.authorization,
        }, .{ .enabled = true, .approved_download_hosts = options.approved_download_hosts });
    }
    if (!approvedUrl(options, file.download.remote)) return error.UnapprovedDownloadHost;
}
fn approvedUrl(options: Options, url: []const u8) bool {
    return providers.approvedDownloadUrl(url, options.approved_download_hosts);
}

const ProductionFetcher = struct {
    allocator: A,
    io: Io,
    service: ?*downloader.Service = null,
    download_budget: ?*downloader.Budget,
    proxy: ?[]const u8,
    ca_bundle: ?[]const u8,
    cache_root: []const u8,
    policy: ?@import("proxy_policy.zig").Policy = null,
    fn deinit(self: *ProductionFetcher) void {
        if (self.service) |service| {
            service.deinit();
            curl.globalDeinit();
        }
        if (self.policy) |*policy| policy.deinit();
    }
    fn fetchToFile(context: ?*anyopaque, io: Io, request: FetchRequest) !void {
        const self: *ProductionFetcher = @ptrCast(@alignCast(context.?));
        try fs.cancelled(io, request.cancel, request.deadline_ns);
        if (self.policy == null) self.policy = try @import("proxy_policy.zig").capture(self.allocator, self.io, self.proxy);
        if (self.service == null) {
            try curl.globalInit();
            errdefer curl.globalDeinit();
            self.service = try downloader.Service.init(self.allocator, self.io, self.download_budget orelse return error.MissingDownloadBudget, 1);
        }
        const task = try self.service.?.submit(.{
            .url = request.url,
            .output = .{ .file = request.absolute_path },
            .expected_sha1 = request.expected_sha1,
            .expected_sha256 = request.expected_sha256,
            .expected_sha512 = request.expected_sha512,
            .artifact_cache_root = self.cache_root,
            .expected_size = request.expected_size,
            .max_bytes = std.math.cast(usize, request.max_bytes) orelse return error.BodyTooLarge,
            .proxy_policy = &self.policy.?,
            .ca_bundle = self.ca_bundle,
            .timeout_ms = 120_000,
            .https_only = true,
            .follow_redirects = false,
            .require_public_address = true,
        });
        var cancellation: ?anyerror = null;
        while (true) {
            const snapshot = task.snapshot();
            if (downloader.terminal(snapshot.progress.phase)) {
                defer task.release() catch unreachable;
                if (cancellation) |err| return err;
                if (snapshot.failure) |err| return err;
                if (snapshot.source != .artifact and (snapshot.http_status < 200 or snapshot.http_status >= 300)) return error.HttpStatus;
                return;
            }
            fs.cancelled(io, request.cancel, request.deadline_ns) catch |err| {
                cancellation = err;
                task.cancel();
            };
            task.wait() catch |err| {
                cancellation = err;
                task.cancel();
                task.join();
            };
        }
    }
};
fn stage(a: A, io: Io, options: Options, fetcher: Fetcher, txn: Dir, txn_path: []const u8, index: usize, file: manifest.InstallFile) !Fingerprint {
    const stage_name = try numbered(a, "stage", index);
    if (try fs.inspectEntry(txn, io, stage_name) != null) return error.PathAlreadyExists;
    const limit = file.record.size orelse providers.max_file_bytes;
    switch (file.download) {
        .manual_required => {
            var selected: ?[]const u8 = null;
            for (options.manual_files) |manual| if (std.mem.eql(u8, manual.path, file.record.path)) {
                if (selected != null) return error.DuplicateManualFile;
                selected = manual.source_absolute_path;
            };
            const path = selected orelse return error.ManualFileRequired;
            const parent_path = std.fs.path.dirname(path) orelse return error.UnsafePath;
            const directory = try fs.openAbsolute(io, parent_path);
            defer directory.close(io);
            const source = try fs.openRegular(directory, io, std.fs.path.basename(path));
            defer source.close(io);
            _ = try fs.copy(source, txn, io, stage_name, limit, options.cancel, options.deadline_ns);
        },
        .remote => |url| {
            try validateDownload(options, file);
            const absolute_path = try std.fs.path.join(a, &.{ txn_path, stage_name });
            var sha1_bytes: [20]u8 = undefined;
            const digest: ?[20]u8 = if (file.record.hashes.sha1) |hash| blk: {
                _ = try std.fmt.hexToBytes(&sha1_bytes, hash);
                break :blk sha1_bytes;
            } else null;
            try fetcher.fetchToFile(fetcher.context, io, .{
                .url = url,
                .directory = txn,
                .name = stage_name,
                .absolute_path = absolute_path,
                .max_bytes = limit,
                .expected_size = file.record.size,
                .expected_sha1 = digest,
                .expected_sha256 = try @import("artifact_cache.zig").parseHex(32, file.record.hashes.sha256),
                .expected_sha512 = try @import("artifact_cache.zig").parseHex(64, file.record.hashes.sha512),
                .deadline_ns = options.deadline_ns,
                .cancel = options.cancel,
            });
        },
    }
    const staged_file = fs.openRegularForSeal(txn, io, stage_name) catch |err| switch (err) {
        error.FileNotFound => return error.MissingStagedFile,
        else => return err,
    };
    defer staged_file.close(io);
    // Verify and seal the same checked inode, using a handle that can write
    // attributes and flush on Windows. Read-only probes retain their own API.
    const result = try fs.stream(staged_file, null, io, limit, options.cancel, options.deadline_ns);
    try result.verify(file.record.hashes, file.record.size);
    try fs.cancelled(io, options.cancel, options.deadline_ns);
    try staged_file.setPermissions(io, fs.privatePermissions(false));
    try staged_file.sync(io);
    try fs.syncDir(txn, io);
    return result;
}
const CompletionProbe = struct {
    arena: A,
    io: Io,
    game: Dir,
    next_manifest: manifest.Manifest,
    cancel: ?*const std.atomic.Value(bool),
    deadline: ?i96,
    fn inspect(context: ?*anyopaque, path: []const u8) !?manifest.LocalFile {
        const self: *CompletionProbe = @ptrCast(@alignCast(context.?));
        if (!safeManagedPath(path)) return error.ProtectedPath;
        const record = findRecord(self.next_manifest.files, path) orelse return null;
        const physical = try manifest.physicalPath(self.arena, record);
        const value = (try fs.fingerprint(self.game, self.io, physical, self.cancel, self.deadline)) orelse return null;
        const owned = try self.arena.create(Fingerprint);
        owned.* = value;
        return .{ .hashes = owned.hashes(), .size = owned.size };
    }
};

fn openRecoveryTransactions(io: Io, paths: *const instances.Paths, id: []const u8, name: []const u8) !?Dir {
    if (!fs.safeComponent(id) or !fs.safeComponent(name)) return error.RecoveryRequired;
    var current = fs.openAbsolute(io, paths.root) catch return error.RecoveryRequired;
    errdefer current.close(io);
    for ([_][]const u8{ ".minecraft", "versions", name, transaction_directory }) |part| {
        const next = fs.child(current, io, part, false, std.mem.eql(u8, part, transaction_directory)) catch |err| {
            if (err == error.FileNotFound) {
                current.close(io);
                return null;
            }
            return error.RecoveryRequired;
        };
        current.close(io);
        current = next;
    }
    return current;
}

fn transactionPending(a: A, io: Io, transactions: Dir, id: []const u8, name: []const u8, transaction_id: []const u8) !bool {
    // scanPending supplies the exact full ID spelling observed in enumeration.
    // Re-enumerating its parent per child would make history scans quadratic.
    std.debug.assert(validTransactionId(transaction_id));
    const named = try transactions.statFile(io, transaction_id, .{ .follow_symlinks = false });
    try fs.rejectReparse(named);
    if (named.kind != .directory) return error.UnsafeFileType;
    const txn = try transactions.openDir(io, transaction_id, .{ .iterate = true, .follow_symlinks = false });
    defer txn.close(io);
    const opened = try txn.stat(io);
    try fs.rejectReparse(opened);
    if (opened.kind != .directory or opened.inode != named.inode) return error.UnsafeFileType;
    if (builtin.os.tag != .windows and opened.permissions.toMode() & 0o077 != 0) return error.UnsafePrivateDirectory;
    const has_journal = try fs.inspectEntry(txn, io, "journal.json") != null;
    const committed = try fs.inspectEntry(txn, io, "committed") != null;
    const rolled_back = try fs.inspectEntry(txn, io, "rolled-back") != null;
    if (!has_journal) {
        if (committed or rolled_back) return error.RecoveryRequired;
        // execute never mutates game files before publishing its durable journal.
        return false;
    }
    const bytes = try fs.read(a, txn, io, "journal.json", max_journal_bytes);
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Journal, a, bytes, .{ .allocate = .alloc_always, .max_value_len = max_journal_bytes });
    defer parsed.deinit();
    try validateJournal(parsed.value, id, name, transaction_id);
    try validateJournalManifests(a, io, txn, parsed.value);
    if (committed and rolled_back) return error.RecoveryRequired;
    if (!committed and !rolled_back) return true;
    const marker = try fs.read(a, txn, io, if (committed) "committed" else "rolled-back", 2);
    defer a.free(marker);
    if (!std.mem.eql(u8, marker, "1\n")) return error.RecoveryRequired;
    return false;
}

fn scanPending(a: A, io: Io, transactions: Dir, id: []const u8, name: []const u8, pending: ?*std.ArrayList([]const u8)) !void {
    // History is retained for inspection; only unresolved work consumes pending capacity.
    // Use an independent scratch arena: `a` may itself be an arena, where free
    // cannot reclaim per-journal allocations during a long read-only scan.
    var pending_count: usize = 0;
    var recovery_required = false;
    // Own the enumeration cursor independently of all transaction inspection.
    // Only full ASCII transaction IDs observed here are opened; other names fail closed.
    const enumeration = try transactions.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
    defer enumeration.close(io);
    var iterator = enumeration.iterate();
    while (try iterator.next(io)) |entry| {
        try io.checkCancel();
        if (!validTransactionId(entry.name)) {
            recovery_required = true;
            continue;
        }
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const unresolved = transactionPending(scratch.allocator(), io, transactions, id, name, entry.name) catch |err| switch (err) {
            error.OutOfMemory, error.ProtectedPath, error.Canceled => return err,
            else => {
                recovery_required = true;
                continue;
            },
        };
        if (unresolved) {
            pending_count += 1;
            if (pending_count > providers.max_items) return error.RecoveryRequired;
            if (pending) |list| {
                try list.append(a, try a.dupe(u8, entry.name));
            } else recovery_required = true;
        }
    }
    if (recovery_required) return error.RecoveryRequired;
}

fn ensureNoPending(a: A, io: Io, transactions: Dir, id: []const u8, name: []const u8) !void {
    scanPending(a, io, transactions, id, name, null) catch |err| switch (err) {
        error.OutOfMemory, error.ProtectedPath, error.Canceled => return err,
        else => return error.RecoveryRequired,
    };
}

/// Caller holds the stable launch/content reservation until this read-only check returns.
pub fn requireRecoveryClear(a: A, io: Io, paths: *const instances.Paths, instance_id: []const u8, instance_name: []const u8) !void {
    const transactions = (try openRecoveryTransactions(io, paths, instance_id, instance_name)) orelse return;
    defer transactions.close(io);
    try ensureNoPending(a, io, transactions, instance_id, instance_name);
}

/// Malformed or unreadable transactions are errors, never silently excluded from this list.
pub fn listPendingTransactions(a: A, io: Io, paths: *const instances.Paths, instance_id: []const u8, instance_name: []const u8) !providers.Owned([]const []const u8) {
    var arena: std.heap.ArenaAllocator = .init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var pending: std.ArrayList([]const u8) = .empty;
    if (try openRecoveryTransactions(io, paths, instance_id, instance_name)) |transactions| {
        defer transactions.close(io);
        scanPending(aa, io, transactions, instance_id, instance_name, &pending) catch |err| switch (err) {
            error.OutOfMemory, error.ProtectedPath, error.Canceled => return err,
            else => return error.RecoveryRequired,
        };
    }
    const value = try pending.toOwnedSlice(aa);
    return .{ .arena = arena, .value = value };
}
/// Inspect the persisted receipt without creating metadata or a transaction namespace.
fn validatePersistedPaths(a: A, io: Io, options: Options) !void {
    var current = try fs.openAbsolute(io, options.paths.root);
    defer current.close(io);
    for ([_][]const u8{ ".vela", "instances", options.instance_id }) |part| {
        const next = fs.child(current, io, part, false, false) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        current.close(io);
        current = next;
    }
    const bytes = fs.read(a, current, io, "content.json", providers.max_json_bytes) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer a.free(bytes);
    var previous = try manifest.parseForInstance(a, bytes, options.instance_name);
    defer previous.deinit();
    if (!std.mem.eql(u8, previous.value.instance_id, options.instance_id)) return error.InstanceMismatch;
    for (previous.value.files) |file| try validateInputPath(options, file.path);
}

pub fn execute(a: A, io: Io, options: Options) !Report {
    try validateOptionPaths(options);
    try validatePersistedPaths(a, io, options);
    try requireRecoveryClear(a, io, options.paths, options.instance_id, options.instance_name);
    try validateOptions(options);
    try options.lease.acquire(options.lease.context, options.instance_id);
    defer options.lease.release(options.lease.context, options.instance_id);
    try options.lease.recheck(options.lease.context, options.instance_id);
    // Repeat under the actual per-ID lease before any directories can be created.
    try validatePersistedPaths(a, io, options);
    try requireRecoveryClear(a, io, options.paths, options.instance_id, options.instance_name);
    try fs.cancelled(io, options.cancel, options.deadline_ns);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const roots = try Roots.open(io, options.paths, options.instance_id, options.instance_name, true);
    defer roots.deinit(io);
    try ensureNoPending(aa, io, roots.transactions, options.instance_id, options.instance_name);
    var nonce: [16]u8 = undefined;
    try Io.randomSecure(io, &nonce);
    const transaction_id = try std.fmt.allocPrint(aa, "txn-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
    if (try fs.inspectEntry(roots.transactions, io, transaction_id) != null) return error.PathAlreadyExists;
    const txn = try fs.child(roots.transactions, io, transaction_id, true, true);
    defer txn.close(io);
    const game_path = try options.paths.instanceDirectory(options.instance_name);
    defer options.paths.allocator.free(game_path);
    const backup_path = try std.fs.path.join(a, &.{ game_path, transaction_directory, transaction_id });
    errdefer a.free(backup_path);
    var report: Report = .{ .allocator = a, .backup_directory = backup_path, .transaction_id = std.fs.path.basename(backup_path), .fully_applied = options.plan.fully_applied };
    for (options.plan.conflicts) |conflict| if (conflict.choice == .keep_local) {
        report.kept_local += 1;
    };
    const manifest_before = try fs.fingerprint(roots.metadata, io, "content.json", options.cancel, options.deadline_ns);
    var previous: ?providers.Owned(manifest.Manifest) = null;
    defer if (previous) |*value| value.deinit();
    if (manifest_before) |before| {
        const bytes = try fs.read(aa, roots.metadata, io, "content.json", providers.max_json_bytes);
        previous = try manifest.parseForInstance(aa, bytes, options.instance_name);
        previous.?.value.files = try @import("content_state.zig").observe(aa, io, roots.game, previous.?.value.files);
        if (!std.mem.eql(u8, previous.?.value.instance_id, options.instance_id)) return error.InstanceMismatch;
        const copied = try copyPath(roots.metadata, "content.json", txn, "manifest-before", io, providers.max_json_bytes, options.cancel, options.deadline_ns);
        if (!copied.eql(before)) return error.LocalFileChanged;
    }
    if (previous) |prior| {
        try validateOwnershipTransition(prior.value, options.plan);
        for (prior.value.files) |file| try requireCounterpartAbsent(aa, io, roots.game, file);
    }
    for (options.plan.next_manifest.files) |file| {
        const old = if (previous) |prior| findRecord(prior.value.files, file.path) else null;
        try requireCounterpartAbsent(aa, io, roots.game, file);
        var mutated = false;
        for (options.plan.actions) |action| if (action.kind != .backup and std.mem.eql(u8, action.path, file.path)) {
            mutated = true;
            break;
        };
        if (!mutated) {
            const physical = try manifest.physicalPath(aa, file);
            const actual = (try fs.fingerprint(roots.game, io, physical, options.cancel, options.deadline_ns)) orelse return error.LocalFileChanged;
            var kept_local = false;
            if (!options.plan.fully_applied and options.allow_partial) {
                for (options.plan.conflicts) |conflict| if (conflict.choice == .keep_local and std.mem.eql(u8, conflict.path, file.path)) {
                    const persisted_record = old orelse return error.UnmanagedFile;
                    if (!sameRecord(file, persisted_record)) return error.LocalFileChanged;
                    kept_local = true;
                    break;
                };
            }
            if (!kept_local) try actual.verify(file.hashes, file.size);
        }
    }
    const next_bytes = try manifest.serialize(aa, options.plan.next_manifest);
    try fs.write(txn, io, "manifest-after", next_bytes);
    const manifest_after = (try fs.fingerprint(txn, io, "manifest-after", null, null)).?;
    const manifest_temp = try std.fmt.allocPrint(aa, ".content-{s}.next", .{transaction_id});
    try fs.write(roots.metadata, io, manifest_temp, next_bytes);
    defer roots.metadata.deleteFile(io, manifest_temp) catch {};
    var entries: std.ArrayList(Entry) = .empty;
    var production: ProductionFetcher = .{ .allocator = a, .io = io, .proxy = options.proxy, .ca_bundle = options.ca_bundle, .download_budget = options.download_budget, .cache_root = options.paths.cache };
    defer production.deinit();
    const fetcher = options.fetcher orelse Fetcher{ .context = &production, .fetchToFile = ProductionFetcher.fetchToFile };
    for (options.plan.actions) |action| {
        if (action.kind == .backup) continue;
        try options.lease.recheck(options.lease.context, options.instance_id);
        try fs.cancelled(io, options.cancel, options.deadline_ns);
        const persisted = if (previous) |prior| findRecord(prior.value.files, action.path) else null;
        if (action.previous) |claimed| {
            const persisted_record = persisted orelse return error.UnmanagedFile;
            if (!sameRecord(claimed, persisted_record)) return error.LocalFileChanged;
        }
        const source_record = persisted orelse action.desired orelse return error.UnmanagedFile;
        const physical = try manifest.physicalPath(aa, source_record);
        if (action.desired) |desired| {
            if (!std.mem.eql(u8, physical, try manifest.physicalPath(aa, desired))) return error.InvalidEnabledTransition;
        }
        const before = try fs.fingerprint(roots.game, io, physical, options.cancel, options.deadline_ns);
        if (action.expected_before) |expected| {
            const old = before orelse return error.LocalFileChanged;
            if (previous == null or findRecord(previous.?.value.files, action.path) == null) return error.UnmanagedFile;
            try old.verify(expected, action.expected_size);
        } else if (before != null) return error.UnmanagedFile;
        const index = entries.items.len;
        var after: ?Fingerprint = null;
        if (action.kind == .install) after = try stage(aa, io, options, fetcher, txn, backup_path, index, try findInstall(options.files, action.desired.?));
        if (before) |old| {
            try checkpoint(options.fault, .before_backup, index);
            const backup_name = try numbered(aa, "before", index);
            const copied = try copyPath(roots.game, physical, txn, backup_name, io, providers.max_file_bytes, options.cancel, options.deadline_ns);
            if (!copied.eql(old)) return error.LocalFileChanged;
            try checkpoint(options.fault, .after_backup, index);
        }
        try entries.append(aa, .{ .path = physical, .kind = if (action.kind == .install) .install else .remove, .before = before, .after = after });
    }
    const journal: Journal = .{
        .schema_version = 2,
        .instance_id = options.instance_id,
        .instance_name = options.instance_name,
        .transaction_id = transaction_id,
        .fully_applied = options.plan.fully_applied,
        .kept_local = report.kept_local,
        .entries = entries.items,
        .manifest_before = manifest_before,
        .manifest_after = manifest_after,
        .manifest_temp = manifest_temp,
    };
    const journal_bytes = try std.json.Stringify.valueAlloc(aa, journal, .{});
    if (journal_bytes.len > max_journal_bytes) return error.JournalTooLarge;
    try checkpoint(options.fault, .before_journal, 0);
    try fs.atomicWrite(txn, io, "journal.json", journal_bytes);
    // Once this durable journal exists, every managed mutation can be recovered.
    commit(aa, io, options, roots, txn, journal, &report) catch |err| {
        if (builtin.is_test and err == error.SimulatedCrash) return err;
        if ((fs.inspectEntry(txn, io, "committed") catch return error.RecoveryRequired) != null) return error.RecoveryRequired;
        rollback(aa, io, roots, txn, journal, options.lease, options.fault) catch return error.RecoveryRequired;
        return err;
    };
    return report;
}
fn commit(a: A, io: Io, options: Options, roots: Roots, txn: Dir, journal: Journal, report: *Report) !void {
    try checkpoint(options.fault, .after_journal, 0);
    for (journal.entries, 0..) |entry, index| {
        try options.lease.recheck(options.lease.context, options.instance_id);
        try fs.cancelled(io, options.cancel, options.deadline_ns);
        try checkpoint(options.fault, .before_mutation, index);
        try requireCurrent(roots.game, io, entry.path, entry.before, options.cancel, options.deadline_ns);
        const leaf = try fs.parent(roots.game, io, entry.path, true);
        defer leaf.deinit(io);
        switch (entry.kind) {
            .install => {
                const stage_name = try numbered(a, "stage", index);
                try requireCurrent(txn, io, stage_name, entry.after, options.cancel, options.deadline_ns);
                if (entry.before == null) try txn.renamePreserve(stage_name, leaf.dir, leaf.name, io) else try txn.rename(stage_name, leaf.dir, leaf.name, io);
            },
            .remove => try leaf.dir.renamePreserve(leaf.name, txn, try numbered(a, "removed", index), io),
        }
        try fs.syncDir(leaf.dir, io);
        try fs.syncDir(txn, io);
        report.applied_files += 1;
        try checkpoint(options.fault, .after_mutation, index);
    }
    try options.lease.recheck(options.lease.context, options.instance_id);
    try fs.cancelled(io, options.cancel, options.deadline_ns);
    if (options.pack) |pack| {
        var probe: CompletionProbe = .{ .arena = a, .io = io, .game = roots.game, .next_manifest = options.plan.next_manifest, .cancel = options.cancel, .deadline = options.deadline_ns };
        report.completeness = try manifest.checkCompleteness(pack, .{ .context = &probe, .inspect = CompletionProbe.inspect }, options.prerequisites);
        report.complete = options.plan.fully_applied and report.completeness.?.complete;
        if (!options.plan.fully_applied) report.completeness.?.complete = false;
    }
    for (journal.entries) |entry| {
        try requireCurrent(roots.game, io, entry.path, entry.after, options.cancel, options.deadline_ns);
    }
    try checkpoint(options.fault, .before_manifest, 0);
    try requireCurrent(roots.metadata, io, "content.json", journal.manifest_before, options.cancel, options.deadline_ns);
    try requireCurrent(roots.metadata, io, journal.manifest_temp, journal.manifest_after, options.cancel, options.deadline_ns);
    if (journal.manifest_before == null) try roots.metadata.renamePreserve(journal.manifest_temp, roots.metadata, "content.json", io) else try roots.metadata.rename(journal.manifest_temp, roots.metadata, "content.json", io);
    try fs.syncDir(roots.metadata, io);
    try checkpoint(options.fault, .after_manifest, 0);
    try fs.cancelled(io, options.cancel, options.deadline_ns);
    try checkpoint(options.fault, .before_commit_marker, 0);
    try fs.cancelled(io, options.cancel, options.deadline_ns);
    try fs.atomicWrite(txn, io, "committed", "1\n");
    report.committed = true;
    // A durable commit wins cancellation and instrumentation races after this point.
    checkpoint(options.fault, .after_commit_marker, 0) catch |err| {
        if (builtin.is_test and err == error.SimulatedCrash) return err;
    };
}

fn rollback(a: A, io: Io, roots: Roots, txn: Dir, journal: Journal, lease: Lease, fault: ?Fault) !void {
    try validateJournal(journal, journal.instance_id, journal.instance_name, journal.transaction_id);
    try validateJournalManifests(a, io, txn, journal);
    var index = journal.entries.len;
    while (index > 0) {
        index -= 1;
        const entry = journal.entries[index];
        try lease.recheck(lease.context, journal.instance_id);
        try checkpoint(fault, .rollback_mutation, index);
        const current = try fs.fingerprint(roots.game, io, entry.path, null, null);
        if (equalOptional(current, entry.before)) continue;
        if (!equalOptional(current, entry.after)) return error.RecoveryConflict;
        const leaf = try fs.parent(roots.game, io, entry.path, true);
        defer leaf.deinit(io);
        if (entry.before) |before| {
            const backup_name = try numbered(a, "before", index);
            try requireCurrent(txn, io, backup_name, before, null, null);
            const restore_name = try numbered(a, "restore", index);
            if (try fs.inspectEntry(txn, io, restore_name) != null) {
                try requireCurrent(txn, io, restore_name, before, null, null);
                try txn.deleteFile(io, restore_name);
            }
            const restored = try copyPath(txn, backup_name, txn, restore_name, io, providers.max_file_bytes, null, null);
            if (!restored.eql(before)) return error.BackupChanged;
            try requireCurrent(roots.game, io, entry.path, entry.after, null, null);
            if (entry.after == null) try txn.renamePreserve(restore_name, leaf.dir, leaf.name, io) else try txn.rename(restore_name, leaf.dir, leaf.name, io);
        } else {
            try requireCurrent(roots.game, io, entry.path, entry.after, null, null);
            try leaf.dir.deleteFile(io, leaf.name);
        }
        try fs.syncDir(leaf.dir, io);
        try fs.syncDir(txn, io);
    }
    try lease.recheck(lease.context, journal.instance_id);
    try checkpoint(fault, .rollback_manifest, 0);
    const current = try fs.fingerprint(roots.metadata, io, "content.json", null, null);
    if (!equalOptional(current, journal.manifest_before)) {
        if (!equalOptional(current, journal.manifest_after)) return error.RecoveryConflict;
        if (journal.manifest_before) |before| {
            try requireCurrent(txn, io, "manifest-before", before, null, null);
            const restore_name = try std.fmt.allocPrint(a, ".content-{s}.restore", .{journal.transaction_id});
            if (try fs.inspectEntry(roots.metadata, io, restore_name) != null) {
                try requireCurrent(roots.metadata, io, restore_name, before, null, null);
                try roots.metadata.deleteFile(io, restore_name);
            }
            const restored = try copyPath(txn, "manifest-before", roots.metadata, restore_name, io, providers.max_json_bytes, null, null);
            if (!restored.eql(before)) return error.BackupChanged;
            try requireCurrent(roots.metadata, io, "content.json", journal.manifest_after, null, null);
            try roots.metadata.rename(restore_name, roots.metadata, "content.json", io);
        } else try roots.metadata.deleteFile(io, "content.json");
        try fs.syncDir(roots.metadata, io);
    }
    if (try fs.inspectEntry(roots.metadata, io, journal.manifest_temp) != null) {
        try requireCurrent(roots.metadata, io, journal.manifest_temp, journal.manifest_after, null, null);
        try roots.metadata.deleteFile(io, journal.manifest_temp);
        try fs.syncDir(roots.metadata, io);
    }
    if (try fs.inspectEntry(txn, io, "rolled-back") == null) try fs.atomicWrite(txn, io, "rolled-back", "1\n");
}
fn validTransactionId(id: []const u8) bool {
    if (id.len != 36 or !std.mem.startsWith(u8, id, "txn-")) return false;
    for (id[4..]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}
fn validateJournalPaths(journal: Journal, instance_name: []const u8) !void {
    if (journal.entries.len > providers.max_items) return error.InvalidJournal;
    for (journal.entries) |entry| {
        try manifest.checkedPathForInstance(entry.path, instance_name);
    }
}
fn validateJournalManifests(a: A, io: Io, txn: Dir, journal: Journal) !void {
    const names = [_][]const u8{ "manifest-before", "manifest-after" };
    const expected = [_]?Fingerprint{ journal.manifest_before, journal.manifest_after };
    var documents: [2]?providers.Owned(manifest.Manifest) = .{ null, null };
    defer {
        for (&documents) |*document| if (document.*) |*owned| owned.deinit();
    }
    for (names, expected, 0..) |name, fingerprint, index| {
        const value = fingerprint orelse continue;
        const bytes = try fs.read(a, txn, io, name, providers.max_json_bytes);
        defer a.free(bytes);
        documents[index] = try manifest.parseForInstance(a, bytes, journal.instance_name);
        const document = documents[index].?.value;
        if (!std.mem.eql(u8, document.instance_id, journal.instance_id)) return error.InstanceMismatch;
        for (document.files) |file| for (journal.entries) |entry| {
            if (!std.mem.eql(u8, file.path, entry.path) and manifest.pathsCollide(file.path, entry.path)) return error.InvalidJournal;
        };
        try requireCurrent(txn, io, name, value, null, null);
    }
    if (documents[0]) |before| if (documents[1]) |after| {
        for (before.value.files) |old| for (after.value.files) |new| {
            if (!std.mem.eql(u8, old.path, new.path) and manifest.pathsCollide(old.path, new.path)) return error.InvalidJournal;
        };
    };
}
fn validateJournal(journal: Journal, instance_id: []const u8, instance_name: []const u8, transaction_id: []const u8) !void {
    try validateJournalPaths(journal, instance_name);
    if (journal.schema_version != 2) return error.UnsupportedJournalVersion;
    if (!std.mem.eql(u8, journal.instance_id, instance_id) or !std.mem.eql(u8, journal.instance_name, instance_name) or
        !std.mem.eql(u8, journal.transaction_id, transaction_id)) return error.InstanceMismatch;
    if (journal.entries.len > providers.max_items or !fs.safeComponent(journal.manifest_temp)) return error.InvalidJournal;
    var name_buffer: [96]u8 = undefined;
    const expected_temp = try std.fmt.bufPrint(&name_buffer, ".content-{s}.next", .{transaction_id});
    if (!std.mem.eql(u8, journal.manifest_temp, expected_temp)) return error.InvalidJournal;
    if (journal.manifest_after.size > providers.max_json_bytes or (journal.manifest_before != null and journal.manifest_before.?.size > providers.max_json_bytes)) return error.InvalidJournal;
    for (journal.entries, 0..) |entry, index| {
        if (!safeManagedPath(entry.path)) return error.InvalidJournal;
        if ((entry.kind == .install) != (entry.after != null) or (entry.kind == .remove and entry.before == null)) return error.InvalidJournal;
        for (journal.entries[0..index]) |other| {
            if (manifest.pathsCollide(entry.path, other.path)) return error.InvalidJournal;
        }
        if (entry.before) |value| try value.verify(value.hashes(), value.size);
        if (entry.after) |value| try value.verify(value.hashes(), value.size);
    }
    try journal.manifest_after.verify(journal.manifest_after.hashes(), journal.manifest_after.size);
    if (journal.manifest_before) |value| try value.verify(value.hashes(), value.size);
}
pub fn recover(a: A, io: Io, options: RecoverOptions) !Report {
    if (!validTransactionId(options.transaction_id)) return error.InvalidTransaction;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    // Read-only priority preflight. Actual recovery reopens and rereads under its lease.
    {
        const preflight_roots = try Roots.open(io, options.paths, options.instance_id, options.instance_name, false);
        defer preflight_roots.deinit(io);
        const preflight_txn = try fs.child(preflight_roots.transactions, io, options.transaction_id, false, true);
        defer preflight_txn.close(io);
        const preflight_bytes = try fs.read(aa, preflight_txn, io, "journal.json", max_journal_bytes);
        const preflight = try std.json.parseFromSlice(Journal, aa, preflight_bytes, .{ .allocate = .alloc_always, .max_value_len = max_journal_bytes });
        defer preflight.deinit();
        try validateJournal(preflight.value, options.instance_id, options.instance_name, options.transaction_id);
        try validateJournalManifests(aa, io, preflight_txn, preflight.value);
    }
    try options.lease.acquire(options.lease.context, options.instance_id);
    defer options.lease.release(options.lease.context, options.instance_id);
    try options.lease.recheck(options.lease.context, options.instance_id);
    const roots = try Roots.open(io, options.paths, options.instance_id, options.instance_name, false);
    defer roots.deinit(io);
    const txn = try fs.child(roots.transactions, io, options.transaction_id, false, true);
    defer txn.close(io);
    const bytes = try fs.read(aa, txn, io, "journal.json", max_journal_bytes);
    const parsed = try std.json.parseFromSlice(Journal, aa, bytes, .{ .allocate = .alloc_always, .max_value_len = max_journal_bytes });
    defer parsed.deinit();
    const journal = parsed.value;
    try validateJournal(journal, options.instance_id, options.instance_name, options.transaction_id);
    try validateJournalManifests(aa, io, txn, journal);
    const game_path = try options.paths.instanceDirectory(options.instance_name);
    defer options.paths.allocator.free(game_path);
    const backup_path = try std.fs.path.join(a, &.{ game_path, transaction_directory, options.transaction_id });
    errdefer a.free(backup_path);
    var report: Report = .{ .allocator = a, .backup_directory = backup_path, .transaction_id = std.fs.path.basename(backup_path), .recovered = true, .kept_local = journal.kept_local };
    const committed = try fs.inspectEntry(txn, io, "committed") != null;
    const rolled_back = try fs.inspectEntry(txn, io, "rolled-back") != null;
    if (committed and rolled_back) return error.InvalidJournal;
    if (committed or rolled_back) {
        const marker = try fs.read(aa, txn, io, if (committed) "committed" else "rolled-back", 2);
        if (!std.mem.eql(u8, marker, "1\n")) return error.InvalidJournal;
        report.committed = committed;
        report.fully_applied = committed and journal.fully_applied;
        report.applied_files = if (committed) journal.entries.len else 0;
        return report;
    }
    try rollback(aa, io, roots, txn, journal, options.lease, options.fault);
    return report;
}
/// Names are owned by the returned arena. Includes committed/rolled-back backups for inspection.
pub fn listTransactions(a: A, io: Io, paths: *const instances.Paths, instance_id: []const u8, instance_name: []const u8) !providers.Owned([]const []const u8) {
    var arena: std.heap.ArenaAllocator = .init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const roots = try Roots.open(io, paths, instance_id, instance_name, false);
    defer roots.deinit(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = roots.transactions.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !fs.safeComponent(entry.name) or !std.mem.startsWith(u8, entry.name, "txn-")) continue;
        const txn = try fs.child(roots.transactions, io, entry.name, false, true);
        defer txn.close(io);
        if (try fs.inspectEntry(txn, io, "journal.json") != null) try names.append(aa, try aa.dupe(u8, entry.name));
    }
    const value = try names.toOwnedSlice(aa);
    return .{ .arena = arena, .value = value };
}

test "all executor entry points compile" {
    std.testing.refAllDecls(@This());
}

const TestLease = struct {
    held: bool = false,
    acquired: usize = 0,
    released: usize = 0,
    fn acquire(ctx: ?*anyopaque, _: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (self.held) return error.InstanceBusy;
        self.held = true;
        self.acquired += 1;
    }
    fn recheck(ctx: ?*anyopaque, _: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (!self.held) return error.LeaseNotHeld;
    }
    fn release(ctx: ?*anyopaque, _: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.held = false;
        self.released += 1;
    }
    fn lease(self: *@This()) Lease {
        return .{ .context = self, .acquire = acquire, .recheck = recheck, .release = release };
    }
};
fn emptyTestPlan(document: manifest.Manifest) manifest.UpdatePlan {
    return .{ .actions = &.{}, .conflicts = &.{}, .next_manifest = document, .ready = true, .fully_applied = true };
}
const test_cf_sha1 = "a9993e364706816aba3e25717850c26c9cd0d89d";
const test_cf_hosts: []const []const u8 = &.{"edge.forgecdn.net"};
fn testCFInstallFile() manifest.InstallFile {
    const url = "https://edge.forgecdn.net/files/34/a.jar";
    return .{ .record = .{ .path = "mods/a.jar", .provider = .curseforge, .project_id = "12", .version_id = "34", .hashes = .{ .sha1 = test_cf_sha1 }, .size = 3, .identity_provenance = .official_file }, .download = .{ .remote = url }, .authorization = .{ .project_id = "12", .file_id = "34", .filename = "a.jar", .url = url, .sha1 = test_cf_sha1, .size = 3, .official_page = "https://www.curseforge.com/minecraft/mc-mods/example", .distribution_allowed = true, .available = true, .approved_download_hosts = test_cf_hosts } };
}
test "CF remote requires opt-in and exact transient authorization before any lease or fetch" {
    var fixture = try ReceiptFixture.init();
    defer fixture.deinit();
    var lease_state: TestLease = .{};
    var file = testCFInstallFile();
    var options: Options = .{ .paths = &fixture.paths, .instance_id = "instance", .instance_name = "Test", .plan = emptyTestPlan(.{ .instance_id = "instance", .pack_version = "v2", .files = &.{file.record} }), .files = &.{file}, .lease = lease_state.lease(), .approved_download_hosts = test_cf_hosts };
    const action: manifest.Action = .{ .kind = .install, .path = file.record.path, .desired = file.record };
    options.plan.actions = &.{action};
    try std.testing.expectError(error.CurseForgeManualRequired, execute(std.testing.allocator, std.testing.io, options));
    try std.testing.expectEqual(@as(usize, 0), lease_state.acquired);
    options.allow_curseforge_remote = true;
    const proof = file.authorization.?;
    file.authorization = null;
    options.files = &.{file};
    try std.testing.expectError(error.MissingRemoteAuthorization, execute(std.testing.allocator, std.testing.io, options));
    file.authorization = proof;
    options.files = &.{file};
    try validateOptions(options);
    var changed = file;
    changed.record.identity_provenance = .pack_archive;
    try std.testing.expectError(error.InvalidRemoteAuthorization, validateDownload(options, changed));
    changed = file;
    changed.download = .{ .remote = "https://edge.forgecdn.net/files/34/other.jar" };
    try std.testing.expectError(error.InvalidRemoteAuthorization, validateDownload(options, changed));
    var other_hosts = options;
    other_hosts.approved_download_hosts = &.{"cdn.modrinth.com"};
    try std.testing.expectError(error.InvalidRemoteAuthorization, validateDownload(other_hosts, file));
    try std.testing.expectEqual(@as(usize, 0), lease_state.acquired);
    try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, ".minecraft/versions/Test/.vela-content", .{}));
}
test "record matching includes provenance and standalone ownership and partial updates cannot claim a new pack" {
    var file = testCFInstallFile().record;
    file.standalone = false;
    var changed = file;
    changed.identity_provenance = .pack_archive;
    try std.testing.expect(!sameRecord(file, changed));
    changed = file;
    changed.standalone = true;
    try std.testing.expect(!sameRecord(file, changed));
    const old: manifest.Manifest = .{ .instance_id = "instance", .pack_version = "old", .files = &.{file}, .pack_membership = .{ .identity = .{ .provider = .curseforge, .project_id = "1", .version_id = "2" }, .paths = &.{file.path} } };
    var plan = emptyTestPlan(old);
    plan.fully_applied = false;
    try validateOwnershipTransition(old, plan);
    var new_proof = old.pack_membership.?;
    new_proof.identity.version_id = "3";
    plan.next_manifest.pack_membership = new_proof;
    try std.testing.expectError(error.InvalidPackOwnershipTransition, validateOwnershipTransition(old, plan));
    plan.next_manifest = old;
    plan.next_manifest.files = &.{changed};
    try std.testing.expectError(error.InvalidPackOwnershipTransition, validateOwnershipTransition(old, plan));
}
const ReceiptFixture = struct {
    tmp: std.testing.TmpDir,
    paths: instances.Paths,
    guard: TestLease = .{},
    fetches: usize = 0,
    fn init() !@This() {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(std.testing.io, &buf);
        var paths = try instances.Paths.init(std.testing.allocator, std.testing.io, buf[0..len]);
        errdefer paths.deinit();
        try tmp.dir.createDirPath(std.testing.io, ".minecraft/versions/Test/mods");
        try tmp.dir.createDirPath(std.testing.io, ".vela/instances/instance");
        return .{ .tmp = tmp, .paths = paths };
    }
    fn deinit(self: *@This()) void {
        self.paths.deinit();
        self.tmp.cleanup();
    }
    fn options(self: *@This(), plan: manifest.UpdatePlan, files: []const manifest.InstallFile) Options {
        return .{ .paths = &self.paths, .instance_id = "instance", .instance_name = "Test", .plan = plan, .files = files, .lease = self.guard.lease(), .fetcher = .{ .context = self, .fetchToFile = fetch } };
    }
    fn fetch(ctx: ?*anyopaque, io: Io, request: FetchRequest) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        try std.testing.expect(self.guard.held);
        try std.testing.expect(request.expected_sha1 != null and request.expected_size == 3);
        self.fetches += 1;
        try fs.write(request.directory, io, request.name, "abc");
    }
    fn readReceipt(self: *@This()) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, ".vela/instances/instance/content.json", std.testing.allocator, .limited(1024 * 1024));
    }
};
const ReceiptCrash = struct {
    point: FaultPoint,
    fn boundary(ctx: ?*anyopaque, point: FaultPoint, _: usize) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (point == self.point) return error.SimulatedCrash;
    }
};
test "journal preserves exact current receipt bytes across rollback and durable commit" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]FaultPoint{ .after_manifest, .after_commit_marker }) |point| {
        var fixture = try ReceiptFixture.init();
        defer fixture.deinit();
        const prior: manifest.Manifest = .{ .instance_id = "instance", .pack_version = "old" };
        const desired: manifest.Manifest = .{ .instance_id = "instance", .pack_version = "new" };
        const serialized = try manifest.serialize(a, prior);
        defer a.free(serialized);
        const before = try std.fmt.allocPrint(a, "\n{s}\n", .{serialized});
        defer a.free(before);
        const after = try manifest.serialize(a, desired);
        defer a.free(after);
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = ".vela/instances/instance/content.json", .data = before });
        var plan = try manifest.buildUpdatePlan(a, prior, desired, &.{}, &.{}, .{ .instance_id = "instance", .running = false });
        defer plan.deinit();
        var crash: ReceiptCrash = .{ .point = point };
        var options = fixture.options(plan.value, &.{});
        options.fault = .{ .context = &crash, .boundary = ReceiptCrash.boundary };
        try std.testing.expectError(error.SimulatedCrash, execute(a, io, options));
        var transactions = try listTransactions(a, io, &fixture.paths, "instance", "Test");
        defer transactions.deinit();
        try std.testing.expectEqual(@as(usize, 1), transactions.value.len);
        const recovery: RecoverOptions = .{ .paths = &fixture.paths, .instance_id = "instance", .instance_name = "Test", .transaction_id = transactions.value[0], .lease = fixture.guard.lease() };
        var report = try recover(a, io, recovery);
        defer report.deinit();
        try std.testing.expectEqual(point == .after_commit_marker, report.committed);
        const current = try fixture.readReceipt();
        defer a.free(current);
        try std.testing.expectEqualStrings(if (report.committed) after else before, current);
        var again = try recover(a, io, recovery);
        defer again.deinit();
        try std.testing.expectEqual(report.committed, again.committed);
        try std.testing.expect(!fixture.guard.held and fixture.guard.acquired == fixture.guard.released and fixture.fetches == 0);
    }
}
test "authorized CF download uses only fake CDN fetcher and persists no authorization" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try ReceiptFixture.init();
    defer fixture.deinit();
    const prior: manifest.Manifest = .{ .instance_id = "instance", .pack_version = "old" };
    const file = testCFInstallFile();
    const desired: manifest.Manifest = .{ .instance_id = "instance", .pack_version = "new", .files = &.{file.record} };
    const before = try manifest.serialize(a, prior);
    defer a.free(before);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = ".vela/instances/instance/content.json", .data = before });
    var plan = try manifest.buildUpdatePlan(a, prior, desired, &.{}, &.{}, .{ .instance_id = "instance", .running = false });
    defer plan.deinit();
    var options = fixture.options(plan.value, &.{file});
    options.allow_curseforge_remote = true;
    options.approved_download_hosts = test_cf_hosts;
    var report = try execute(a, io, options);
    defer report.deinit();
    try std.testing.expect(report.committed and fixture.fetches == 1 and !fixture.guard.held);
    const bytes = try fixture.readReceipt();
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "authorization") == null and std.mem.indexOf(u8, bytes, "forgecdn.net") == null);
    var parsed = try manifest.parse(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("12", parsed.value.files[0].project_id);
    try std.testing.expectEqual(manifest.IdentityProvenance.official_file, parsed.value.files[0].identity_provenance);
}
test "journal path preflight bounds precede uninitialized entries" {
    const a = std.testing.allocator;
    const entries = try a.alloc(Entry, providers.max_items + 1);
    defer a.free(entries);
    const transaction_id = "txn-" ++ @as([32]u8, @splat('1'));
    const journal: Journal = .{
        .schema_version = 2,
        .instance_id = "instance",
        .instance_name = "Test",
        .transaction_id = transaction_id,
        .fully_applied = true,
        .kept_local = 0,
        .entries = entries,
        .manifest_before = null,
        .manifest_after = .{ .size = 0, .sha1 = @as([40]u8, @splat('0')), .sha256 = @as([64]u8, @splat('0')), .sha512 = @as([128]u8, @splat('0')) },
        .manifest_temp = ".content-" ++ transaction_id ++ ".next",
    };
    try std.testing.expectError(error.InvalidJournal, validateJournal(journal, "instance", "Test", transaction_id));
}

test "generic content executor rejects initial world source plans before acquiring lease" {
    var fixture = try ReceiptFixture.init();
    defer fixture.deinit();
    var options = fixture.options(.{ .actions = &.{}, .conflicts = &.{}, .next_manifest = .{ .instance_id = "instance", .pack_version = "v1" }, .ready = true, .fully_applied = true }, &.{});
    var world = testCFInstallFile();
    world.record.path = "saves/World/level.dat";
    world.record.provider = .modrinth;
    world.record.identity_provenance = .pack_archive;
    options.pack = .{ .identity = .{ .provider = .modrinth, .project_id = "p", .version_id = "v" }, .name = "World", .version = "v", .minecraft_version = "1.21.1", .initial_world_files = &.{world} };
    options.prerequisites = .{ .overrides_processed = true, .dependencies_resolved = true, .loader_ready = true };
    const Probe = struct {
        fn inspect(_: ?*anyopaque, _: []const u8) !?manifest.LocalFile {
            return error.UnexpectedProbe;
        }
    };
    try std.testing.expectError(error.ProtectedPath, manifest.checkCompleteness(options.pack.?, .{ .context = null, .inspect = Probe.inspect }, options.prerequisites));
    try std.testing.expectError(error.ProtectedPath, execute(std.testing.allocator, std.testing.io, options));
    try std.testing.expectEqual(@as(usize, 0), fixture.guard.acquired);
    try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
}
