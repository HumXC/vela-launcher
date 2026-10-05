//! World folders live in versions/<instance.name>/saves. renameFolder changes the
//! directory; renameDisplayName rewrites only LevelName in the full NBT document.
//! Destructive operations retain immutable verified recovery data and manifests.
//! Local POSIX filesystems get file and directory fsync ordering, not a hardware
//! power-loss guarantee (macOS F_FULLFSYNC is not requested). Network/filesystem
//! rename ambiguity or a failed post-rename barrier yields an uncertain outcome.
//! Windows has no portable directory barrier here: data files still sync, but a
//! completed mutation returns uncertain / DirectoryDurabilityUnavailable. Do not
//! automatically retry it; inspect both recovery_directory and staging_directory.
//! Foreign targets are compile-checked only, not runtime/durability validated.
//! World data APIs require a shared per-instance WorldScope. The transaction gate
//! protects reservation state only; filesystem work runs after releasing the gate.
const std = @import("std");
const config = @import("config.zig");
const instances = @import("instances.zig");
const tree = @import("worlds_tree.zig");
pub const parseLevelDat = @import("worlds_metadata.zig").parse;
pub const listBackups = @import("worlds_recovery.zig").list;
pub const Backup = @import("worlds_recovery.zig").Backup;
pub const BackupList = @import("worlds_recovery.zig").BackupList;
pub const validRecoveryId = artifactId;

test {
    _ = @import("worlds_tests.zig");
}
const A = std.mem.Allocator;
const Dir = std.Io.Dir;
pub const Limits = tree.Limits;
pub const Hooks = tree.Hooks;

/// The launch lifecycle must take this same gate when changing running state.
/// Reservation callbacks hold this gate only while inspecting or updating state.
pub var transaction_gate: std.Io.Mutex = .init;
pub const Guard = struct {
    context: ?*anyopaque = null,
    is_running: ?*const fn (?*anyopaque, []const u8) bool = null,
    running_ids: []const []const u8 = &.{},
    fn check(self: Guard, instance: config.Instance) !void {
        for (self.running_ids) |id| if (std.mem.eql(u8, id, instance.id)) return error.InstanceRunning;
        if (self.is_running) |f| if (f(self.context, instance.id)) return error.InstanceRunning;
    }
};
pub const ScopeIds = struct {
    source: []const u8,
    target: ?[]const u8 = null,

    pub fn normalized(self: ScopeIds) ScopeIds {
        if (self.target) |target| if (std.mem.eql(u8, self.source, target)) return .{ .source = self.source };
        return self;
    }
    pub fn contains(self: ScopeIds, id: []const u8) bool {
        if (std.mem.eql(u8, self.source, id)) return true;
        return if (self.target) |target| std.mem.eql(u8, target, id) else false;
    }
};
pub const ScopeState = enum { available, busy, running };
pub const ScopeStamp = struct {
    source_generation: u64,
    target_generation: ?u64 = null,
};
/// Provider contexts remain at their final address until every worker joins.
pub const WorldScope = struct {
    context: ?*anyopaque,
    probe: *const fn (?*anyopaque, ScopeIds) anyerror!ScopeState,
    acquire: *const fn (?*anyopaque, ScopeIds) anyerror!ScopeStamp,
    recheck: *const fn (?*anyopaque, ScopeIds, ScopeStamp) anyerror!void,
    release: *const fn (?*anyopaque, ScopeIds, ScopeStamp) void,

    pub fn hold(self: WorldScope, requested: ScopeIds) !HeldWorldScope {
        const ids = requested.normalized();
        return .{ .scope = self, .ids = ids, .stamp = try self.acquire(self.context, ids) };
    }
};
/// IDs are borrowed; managers keep their cloned storage alive until JOIN.
pub const HeldWorldScope = struct {
    scope: WorldScope,
    ids: ScopeIds,
    stamp: ScopeStamp,

    pub fn covers(self: HeldWorldScope, requested: ScopeIds) bool {
        if (!self.ids.contains(requested.source)) return false;
        return if (requested.target) |target| self.ids.contains(target) else true;
    }
    pub fn recheck(self: HeldWorldScope) !void {
        try self.scope.recheck(self.scope.context, self.ids, self.stamp);
    }
    pub fn release(self: HeldWorldScope) void {
        self.scope.release(self.scope.context, self.ids, self.stamp);
    }
};
pub const ScopeEntry = struct {
    held: HeldWorldScope,
    owned: bool,

    pub fn deinit(self: ScopeEntry) void {
        if (self.owned) self.held.release();
    }
};
pub const Options = struct {
    limits: Limits = .{},
    hooks: Hooks = .{},
    guard: Guard = .{},
    scope: ?WorldScope = null,
    held_scope: ?HeldWorldScope = null,
    /// Set only after an explicit user confirmation; never inferred from a collision.
    confirmed_destructive: bool = false,
    display_name: ?[]const u8 = null,
};
/// Static owned IDs remain an additional veto; callback predicates are not leases.
pub fn checkStaticGuard(guard: Guard, ids: ScopeIds) !void {
    if (guard.is_running != null) return error.UnsupportedWorldGuard;
    for (guard.running_ids) |id| if (ids.contains(id)) return error.InstanceRunning;
}
/// Enter before opening files and release after all descriptors and cleanup finish.
pub fn enterScope(options: Options, requested: ScopeIds) !ScopeEntry {
    const ids = requested.normalized();
    if (!config.validId(ids.source)) return error.InvalidInstanceId;
    if (ids.target) |target| if (!config.validId(target)) return error.InvalidInstanceId;
    if (options.guard.is_running != null) return error.UnsupportedWorldGuard;
    if (options.scope == null and options.held_scope == null) return error.MissingWorldScope;
    if (options.scope != null and options.held_scope != null) return error.InvalidWorldScope;
    try checkStaticGuard(options.guard, ids);
    if (options.held_scope) |held| {
        if (!held.covers(ids)) return error.LeaseNotHeld;
        try held.recheck();
        return .{ .held = held, .owned = false };
    }
    return .{ .held = try options.scope.?.hold(ids), .owned = true };
}
pub const MetadataStatus = enum { valid, missing, corrupt, unavailable };
pub const Metadata = struct {
    level_name: ?[]const u8 = null,
    last_played_ms: ?i64 = null,
    game_type: ?i32 = null,
    hardcore: ?bool = null,
    data_version: ?i32 = null,
    version_name: ?[]const u8 = null,
    pub fn deinit(self: *Metadata, a: A) void {
        if (self.level_name) |s| a.free(s);
        if (self.version_name) |s| a.free(s);
        self.* = .{};
    }
};
/// Adapter returns owned strings. ParserUnavailable is distinct from corrupt input.
pub const MetadataParser = *const fn (A, []const u8) anyerror!Metadata;
pub const World = struct {
    folder: []const u8,
    directory: []const u8,
    icon_path: ?[]const u8 = null,
    metadata: Metadata = .{},
    metadata_status: MetadataStatus = .missing,
    metadata_error: ?anyerror = null,
    modified_ms: i64,
    pub fn deinit(self: *World, a: A) void {
        a.free(self.folder);
        a.free(self.directory);
        if (self.icon_path) |s| a.free(s);
        self.metadata.deinit(a);
        self.* = undefined;
    }
    pub fn recentPlayMs(self: World) i64 {
        return self.metadata.last_played_ms orelse self.modified_ms;
    }
    pub fn displayName(self: World) []const u8 {
        return self.metadata.level_name orelse self.folder;
    }
};
pub const WorldList = struct {
    allocator: A,
    items: []World,
    pub fn deinit(self: *WorldList) void {
        for (self.items) |*item| item.deinit(self.allocator);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};
pub const WorldRef = struct { instance: config.Instance, folder: []const u8 };
pub const BackupRef = struct { instance: config.Instance, id: []const u8, part: enum { original, overwritten } = .original };
pub const Operation = enum { backup, restore, copy, rename, rename_display_name, delete };
pub const Outcome = struct {
    allocator: A,
    state: enum { committed, rolled_back, uncertain } = .committed,
    cause: ?anyerror = null,
    recovery_id: []const u8,
    recovery_directory: []const u8,
    /// Also inspect this location if artifact publication reported uncertainty.
    staging_directory: ?[]const u8 = null,
    pub fn deinit(self: *Outcome) void {
        self.allocator.free(self.recovery_id);
        self.allocator.free(self.recovery_directory);
        if (self.staging_directory) |s| self.allocator.free(s);
        self.* = undefined;
    }
};
pub const Manifest = struct {
    format: u32 = 1,
    operation: Operation,
    source_instance: []const u8,
    source_folder: []const u8,
    target_instance: ?[]const u8 = null,
    target_folder: ?[]const u8 = null,
    bytes: u64,
    entries: []const tree.Entry,
};

pub fn validFolder(name: []const u8) bool {
    return name.len <= 240 and instances.safeRelativePath(name) and std.mem.indexOfScalar(u8, name, '/') == null and !std.ascii.eqlIgnoreCase(name, ".vela-worlds");
}
fn validateInstance(instance: config.Instance) !void {
    if (!config.validId(instance.id) or !config.validId(instance.name)) return error.UnsafeInstance;
}
fn saves(a: A, io: std.Io, paths: *const instances.Paths, instance: config.Instance, create: bool) !Dir {
    _ = a;
    try validateInstance(instance);
    const root = try tree.openAbsolute(io, paths.root);
    defer root.close(io);
    // Instance namespace creation belongs to the registered-instance owner.
    const minecraft = try tree.child(io, root, ".minecraft", false);
    defer minecraft.close(io);
    const versions = try tree.child(io, minecraft, "versions", false);
    defer versions.close(io);
    const version = try tree.child(io, versions, instance.name, false);
    defer version.close(io);
    return tree.child(io, version, "saves", create);
}
pub fn worldDirectory(a: A, paths: *const instances.Paths, ref: WorldRef) ![]u8 {
    try validateInstance(ref.instance);
    if (!validFolder(ref.folder)) return error.UnsafeWorldName;
    return std.fs.path.join(a, &.{ paths.minecraft, "versions", ref.instance.name, "saves", ref.folder });
}
fn recentFirst(_: void, x: World, y: World) bool {
    if (x.recentPlayMs() != y.recentPlayMs()) return x.recentPlayMs() > y.recentPlayMs();
    return std.mem.lessThan(u8, x.folder, y.folder);
}
pub fn list(a: A, io: std.Io, paths: *const instances.Paths, instance: config.Instance, parser: ?MetadataParser, options: Options) !WorldList {
    try validateInstance(instance);
    const scope = try enterScope(options, .{ .source = instance.id });
    defer scope.deinit();
    const dir = saves(a, io, paths, instance, false) catch |err| switch (err) {
        error.FileNotFound => return .{ .allocator = a, .items = try a.alloc(World, 0) },
        else => return err,
    };
    defer dir.close(io);
    var items: std.ArrayList(World) = .empty;
    errdefer {
        for (items.items) |*w| w.deinit(a);
        items.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try options.hooks.check(io);
        if (!validFolder(entry.name)) continue;
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .directory) continue;
        if (items.items.len >= options.limits.max_files) return error.ResourceLimit;
        var w: World = .{ .folder = try a.dupe(u8, entry.name), .directory = undefined, .modified_ms = @intCast(@divTrunc(stat.mtime.nanoseconds, 1_000_000)) };
        w.directory = worldDirectory(a, paths, .{ .instance = instance, .folder = entry.name }) catch |err| {
            a.free(w.folder);
            return err;
        };
        var owned = false;
        defer if (!owned) w.deinit(a);
        const world = try tree.child(io, dir, entry.name, false);
        defer world.close(io);
        const bytes = tree.readBounded(a, io, world, "level.dat", 16 * 1024 * 1024) catch |err| blk: {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            w.metadata_status = if (err == error.FileNotFound) .missing else .corrupt;
            w.metadata_error = err;
            break :blk null;
        };
        if (bytes) |data| {
            defer a.free(data);
            const parse = parser orelse parseLevelDat;
            w.metadata = parse(a, data) catch |err| blk: {
                if (err == error.OutOfMemory or err == error.Canceled) return err;
                w.metadata_status = .corrupt;
                w.metadata_error = err;
                break :blk .{};
            };
            if (w.metadata_error == null) w.metadata_status = .valid;
        }
        const icon = tree.readBounded(a, io, world, "icon.png", 4 * 1024 * 1024) catch |err| blk: {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            break :blk null;
        };
        if (icon) |data| {
            defer a.free(data);
            if (validPng(data)) w.icon_path = try std.fs.path.join(a, &.{ w.directory, "icon.png" });
        }
        try items.append(a, w);
        owned = true;
    }
    std.mem.sort(World, items.items, {}, recentFirst);
    return .{ .allocator = a, .items = try items.toOwnedSlice(a) };
}

/// Validate the PNG container and CRCs before exposing its actual path to a decoder.
/// The UI decoder must still reject invalid pixel/compression data; no external URL.
fn validPng(bytes: []const u8) bool {
    if (bytes.len < 45 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return false;
    var offset: usize = 8;
    var first = true;
    var pixels = false;
    while (offset <= bytes.len - 12) {
        const length = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (length > bytes.len - offset - 12) return false;
        const kind = bytes[offset + 4 ..][0..4];
        const data = bytes[offset + 8 ..][0..length];
        const crc = std.mem.readInt(u32, bytes[offset + 8 + length ..][0..4], .big);
        if (std.hash.crc.Crc32.hash(bytes[offset + 4 ..][0 .. length + 4]) != crc) return false;
        if (first) {
            if (!std.mem.eql(u8, kind, "IHDR") or length != 13) return false;
            const width = std.mem.readInt(u32, data[0..4], .big);
            const height = std.mem.readInt(u32, data[4..8], .big);
            if (width == 0 or height == 0 or width > 512 or height > 512) return false;
            first = false;
        } else if (std.mem.eql(u8, kind, "IHDR")) return false;
        if (std.mem.eql(u8, kind, "IDAT")) pixels = true;
        offset += length + 12;
        if (std.mem.eql(u8, kind, "IEND")) return length == 0 and pixels and offset == bytes.len;
    }
    return false;
}

fn collide(io: std.Io, dir: Dir, name: []const u8, ignore: ?[]const u8) !?[]const u8 {
    // Return name rather than a borrowed iterator buffer. Case-only foreign collisions
    // are rejected even on case-sensitive hosts to keep backups portable.
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (ignore) |s| if (std.mem.eql(u8, entry.name, s)) continue;
        if (std.ascii.eqlIgnoreCase(entry.name, name)) {
            if (!std.mem.eql(u8, entry.name, name)) return error.NameCollision;
            return name;
        }
    }
    return null;
}
fn artifactId(id: []const u8) bool {
    if (id.len != 32) return false;
    for (id) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}
fn verify(a: A, io: std.Io, source: Dir, expected: tree.Snapshot, options: Options) !void {
    var actual = try tree.snapshot(a, io, source, null, options.limits, options.hooks);
    defer actual.deinit();
    if (!tree.equal(expected, actual)) return error.IntegrityMismatch;
}
fn writeManifest(a: A, io: std.Io, dir: Dir, manifest: Manifest, options: Options) !void {
    const json = try std.json.Stringify.valueAlloc(a, manifest, .{});
    defer a.free(json);
    if (json.len > options.limits.max_manifest_bytes) return error.ResourceLimit;
    const file = try dir.createFile(io, "manifest.json", .{ .exclusive = true });
    defer file.close(io);
    try file.writePositionalAll(io, json, 0);
    try file.sync(io);
    try tree.syncDir(io, dir);
}

pub fn backup(a: A, io: std.Io, paths: *const instances.Paths, ref: WorldRef, options: Options) !Outcome {
    return transact(a, io, paths, .backup, ref, null, null, options);
}
pub fn copy(a: A, io: std.Io, paths: *const instances.Paths, source: WorldRef, target: WorldRef, options: Options) !Outcome {
    return transact(a, io, paths, .copy, source, target, null, options);
}
pub fn rename(a: A, io: std.Io, paths: *const instances.Paths, ref: WorldRef, new_folder: []const u8, options: Options) !Outcome {
    return transact(a, io, paths, .rename, ref, .{ .instance = ref.instance, .folder = new_folder }, null, options);
}
pub const renameFolder = rename;
pub fn renameDisplayName(a: A, io: std.Io, paths: *const instances.Paths, ref: WorldRef, new_name: []const u8, options: Options) !Outcome {
    var opts = options;
    opts.display_name = new_name;
    return transact(a, io, paths, .rename_display_name, ref, ref, null, opts);
}
pub fn delete(a: A, io: std.Io, paths: *const instances.Paths, ref: WorldRef, options: Options) !Outcome {
    return transact(a, io, paths, .delete, ref, null, null, options);
}
pub fn restore(a: A, io: std.Io, paths: *const instances.Paths, ref: BackupRef, target: WorldRef, options: Options) !Outcome {
    if (!artifactId(ref.id)) return error.UnsafeArtifactId;
    return transact(a, io, paths, .restore, .{ .instance = ref.instance, .folder = target.folder }, target, ref, options);
}

fn transact(a: A, io: std.Io, paths: *const instances.Paths, operation: Operation, source_ref: WorldRef, target_ref: ?WorldRef, restore_id: ?BackupRef, options: Options) !Outcome {
    try validateInstance(source_ref.instance);
    if (!validFolder(source_ref.folder)) return error.UnsafeWorldName;
    if ((operation == .delete or operation == .rename_display_name) and !options.confirmed_destructive) return error.ConfirmationRequired;
    if (target_ref) |target| {
        try validateInstance(target.instance);
        if (!validFolder(target.folder)) return error.UnsafeWorldName;
        if (std.ascii.eqlIgnoreCase(source_ref.instance.name, target.instance.name) and std.mem.eql(u8, source_ref.folder, target.folder) and operation != .restore and operation != .rename_display_name) return error.SameWorld;
    }
    const ids: ScopeIds = .{ .source = source_ref.instance.id, .target = if (target_ref) |target| target.instance.id else null };
    const scope = try enterScope(options, ids);
    defer scope.deinit();
    try options.hooks.check(io);
    const source_saves = try saves(a, io, paths, source_ref.instance, false);
    defer source_saves.close(io);
    const target_saves = if (target_ref) |target| try saves(a, io, paths, target.instance, true) else source_saves;
    defer if (target_ref != null) target_saves.close(io);
    const collision = if (target_ref) |target| try collide(io, target_saves, target.folder, if (operation == .rename) source_ref.folder else null) else null;
    if (collision != null and operation == .rename) return error.NameCollision;
    if (collision != null and !options.confirmed_destructive) return error.ConfirmationRequired;
    const repository = try tree.child(io, target_saves, ".vela-worlds", true);
    defer repository.close(io);
    var random: [16]u8 = undefined;
    io.random(&random);
    const id = std.fmt.bytesToHex(random, .lower);
    const staging = try std.fmt.allocPrint(a, ".stage-{s}", .{id});
    defer a.free(staging);
    try repository.createDir(io, staging, .default_dir);
    var published = false;
    defer if (!published) {
        const old = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(old);
        repository.deleteTree(io, staging) catch {};
    };
    const stage = try tree.child(io, repository, staging, false);
    defer stage.close(io);
    const payload = try tree.child(io, stage, "payload", true);
    defer payload.close(io);
    var restore_repo: ?Dir = null;
    defer if (restore_repo) |d| d.close(io);
    var restore_artifact: ?Dir = null;
    defer if (restore_artifact) |d| d.close(io);
    const source = if (restore_id) |backup_id| blk: {
        restore_repo = try tree.child(io, source_saves, ".vela-worlds", false);
        restore_artifact = try tree.child(io, restore_repo.?, backup_id.id, false);
        if (backup_id.part == .overwritten) {
            const nested = try tree.child(io, restore_artifact.?, "overwritten", false);
            restore_artifact.?.close(io);
            restore_artifact = nested;
        }
        break :blk try tree.child(io, restore_artifact.?, "payload", false);
    } else try tree.child(io, source_saves, source_ref.folder, false);
    defer source.close(io);
    var expected = try tree.snapshot(a, io, source, payload, options.limits, options.hooks);
    defer expected.deinit();
    try verify(a, io, payload, expected, options);
    if (restore_artifact) |artifact| {
        const bytes = try tree.readBounded(a, io, artifact, "manifest.json", options.limits.max_manifest_bytes);
        defer a.free(bytes);
        const parsed = try std.json.parseFromSlice(Manifest, a, bytes, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        if (parsed.value.format != 1 or !config.validId(parsed.value.source_instance) or !validFolder(parsed.value.source_folder)) return error.InvalidManifest;
        const recorded: tree.Snapshot = .{ .allocator = a, .entries = @constCast(parsed.value.entries), .bytes = parsed.value.bytes };
        if (!tree.equal(expected, recorded)) return error.IntegrityMismatch;
    }
    try writeManifest(a, io, stage, .{ .operation = operation, .source_instance = source_ref.instance.id, .source_folder = source_ref.folder, .target_instance = if (target_ref) |t| t.instance.id else null, .target_folder = if (target_ref) |t| t.folder else null, .bytes = expected.bytes, .entries = expected.entries }, options);
    // An overwrite gets its own independently verified recovery payload+manifest.
    if (if (operation == .rename_display_name) null else collision) |name| {
        const existing = try tree.child(io, target_saves, name, false);
        defer existing.close(io);
        const recovery = try tree.child(io, stage, "overwritten", true);
        defer recovery.close(io);
        const previous = try tree.child(io, recovery, "payload", true);
        defer previous.close(io);
        var old_tree = try tree.snapshot(a, io, existing, previous, options.limits, options.hooks);
        defer old_tree.deinit();
        try verify(a, io, previous, old_tree, options);
        try verify(a, io, existing, old_tree, options);
        try writeManifest(a, io, recovery, .{ .operation = operation, .source_instance = target_ref.?.instance.id, .source_folder = name, .bytes = old_tree.bytes, .entries = old_tree.entries }, options);
    }
    if (target_ref != null) {
        const candidate = try tree.child(io, stage, "candidate", true);
        defer candidate.close(io);
        var copied = try tree.snapshot(a, io, payload, candidate, options.limits, options.hooks);
        defer copied.deinit();
        if (!tree.equal(expected, copied)) return error.IntegrityMismatch;
        try verify(a, io, candidate, expected, options);
        if (operation == .rename_display_name) {
            const bytes = try tree.readBounded(a, io, candidate, "level.dat", 16 * 1024 * 1024);
            defer a.free(bytes);
            const changed = try @import("worlds_metadata.zig").rewrite(a, bytes, options.display_name.?);
            defer a.free(changed);
            const file = try candidate.createFile(io, "level.dat", .{});
            defer file.close(io);
            try file.writePositionalAll(io, changed, 0);
            try file.sync(io);
            var changed_tree = try tree.snapshot(a, io, candidate, null, options.limits, options.hooks);
            defer changed_tree.deinit();
            try verify(a, io, candidate, changed_tree, options);
        }
    }
    try verify(a, io, source, expected, options);
    var outcome: Outcome = .{ .allocator = a, .recovery_id = try a.dupe(u8, &id), .recovery_directory = undefined };
    outcome.recovery_directory = std.fs.path.join(a, &.{ paths.minecraft, "versions", if (target_ref) |t| t.instance.name else source_ref.instance.name, "saves", ".vela-worlds", &id }) catch |err| {
        a.free(outcome.recovery_id);
        return err;
    };
    errdefer outcome.deinit();
    outcome.staging_directory = try std.fs.path.join(a, &.{ std.fs.path.dirname(outcome.recovery_directory).?, staging });
    if (!tree.directory_sync_supported) {
        outcome.state = .uncertain;
        outcome.cause = error.DirectoryDurabilityUnavailable;
    }
    try scope.held.recheck();
    try checkStaticGuard(options.guard, ids);
    try options.hooks.check(io);
    // No cancellation points after publication. Preallocated outcome needs no fallible allocation.
    const old_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_protection);
    repository.renamePreserve(staging, repository, &id, io) catch |err| {
        if (!ambiguousRename(err)) return err;
        // An RPC/I/O error may have happened after the rename; retain both names.
        published = true;
        outcome.state = .uncertain;
        outcome.cause = err;
        return outcome;
    };
    published = true;
    if (!syncCommit(io, repository, stage, &outcome)) return outcome;
    if (operation == .backup) {
        if (options.hooks.committed) |notify| notify(options.hooks.context);
        return outcome;
    }
    if (operation == .delete) {
        source_saves.renamePreserve(source_ref.folder, stage, "removed", io) catch |err| {
            outcome.state = if (ambiguousRename(err)) .uncertain else .rolled_back;
            outcome.cause = err;
            return outcome;
        };
        if (!syncCommit(io, source_saves, stage, &outcome)) return outcome;
        if (options.hooks.committed) |notify| notify(options.hooks.context);
        return outcome;
    }
    const target_name = target_ref.?.folder;
    const moving_source = operation == .rename or operation == .rename_display_name;
    const displaced: ?[]const u8 = if (moving_source) source_ref.folder else collision;
    const displaced_saves = if (moving_source) source_saves else target_saves;
    if (displaced) |name| {
        displaced_saves.renamePreserve(name, stage, "removed", io) catch |err| {
            outcome.state = if (ambiguousRename(err)) .uncertain else .rolled_back;
            outcome.cause = err;
            return outcome;
        };
        if (!syncCommit(io, displaced_saves, stage, &outcome)) return outcome;
    }
    stage.renamePreserve("candidate", target_saves, target_name, io) catch |err| {
        outcome.cause = err;
        outcome.state = if (ambiguousRename(err)) .uncertain else .rolled_back;
        if (outcome.state == .uncertain) return outcome;
        if (displaced) |name| {
            stage.renamePreserve("removed", displaced_saves, name, io) catch {
                outcome.state = .uncertain;
                return outcome;
            };
            _ = syncCommit(io, displaced_saves, stage, &outcome);
        }
        return outcome;
    };
    if (!syncCommit(io, target_saves, stage, &outcome)) return outcome;
    if (options.hooks.committed) |notify| notify(options.hooks.context);
    return outcome;
}

fn ambiguousRename(err: anyerror) bool {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied, error.DirNotEmpty, error.FileBusy, error.DiskQuota, error.IsDir, error.SymLinkLoop, error.LinkQuotaExceeded, error.FileNotFound, error.NotDir, error.NoSpaceLeft, error.ReadOnlyFileSystem, error.CrossDevice, error.PathAlreadyExists, error.NameTooLong, error.InvalidWtf8, error.InvalidUtf8, error.BadPathName, error.RenamePreserveUnsupported => false,
        else => true,
    };
}
fn syncCommit(io: std.Io, first: Dir, second: Dir, outcome: *Outcome) bool {
    tree.syncDir(io, first) catch |err| {
        outcome.state = .uncertain;
        outcome.cause = err;
        return false;
    };
    tree.syncDir(io, second) catch |err| {
        outcome.state = .uncertain;
        outcome.cause = err;
        return false;
    };
    return true;
}
