//! Worker-only offline instance transactions. Caller owns the stable-ID lease through
//! config publication and confirms rename/delete before invocation. No config writes.
//! Rename recovery manifests describe prepared intent; deletion permanently erases files.
const std = @import("std");
const builtin = @import("builtin");
const content_fs = @import("content_fs.zig");
const namespace = @import("instance_namespace.zig");
const config = @import("config.zig");
const instances = @import("instances.zig");
const tree = @import("worlds_tree.zig");
const worlds = @import("worlds.zig");
const safe = @import("install/safe_fs.zig");
const loader = @import("minecraft/metadata_loader.zig");
const metadata = @import("minecraft/metadata/version.zig");
const A = std.mem.Allocator;
const Dir = std.Io.Dir;
const Stat = std.Io.File.Stat;

fn windowsReadOnlyPermissions(before: std.Io.File.Permissions) std.Io.File.Permissions {
    // Zig 0.16 setReadOnly references a missing flat Windows constant.
    var attributes = before.toAttributes();
    attributes.READONLY = true;
    attributes.NORMAL = false;
    return @fromBackingInt(@intCast(@as(std.os.windows.DWORD, @bitCast(attributes))));
}

pub const Operation = enum { inspected, renamed, deleted };
/// Borrowed only while its owned, authenticated preparation remains alive.
/// This proof is for existing-instance inspection, never a rename/delete exemption.
pub const TrustedVanilla = struct {
    prepared: *const loader.PreparedVanilla,
    generation: u64,
    environment: @import("minecraft/metadata/root.zig").rules.Environment,
};
pub const Options = struct {
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Static running IDs add a veto; dynamic callbacks are unsupported.
    guard: worlds.Guard = .{},
    limits: tree.Limits = .{},
    trusted_vanilla: ?TrustedVanilla = null,
    lease: ?LeaseCheck = null,
    namespace_token: ?namespace.Token = null,
    worker_checks: bool = false,
};
/// Adapter for a caller-owned stable-ID mutation lease; never releases that lease.
/// Recheck runs outside the shared gate and may acquire it internally.
pub const LeaseCheck = struct {
    context: ?*anyopaque = null,
    recheck: *const fn (?*anyopaque, []const u8) anyerror!void,
};
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    operation: Operation,
    instance: config.Instance,
    recovery_directory: ?[]const u8 = null,
    original_name: ?[]const u8 = null,
    durability_uncertain: bool = false,
    /// Official metadata pin and actual local client hash/size, not full readiness.
    local_client_verified: bool = false,
    publication_proof: ?PublicationProof = null,
    deletion_proof: ?DeletionProof = null,
    /// Direct inspection transfers ownership while its returned proof keeps files open.
    owned_ns: ?namespace.Token = null,

    /// Release held evidence after publication while preserving owned instance strings.
    pub fn releasePublicationProof(self: *Result) void {
        if (self.publication_proof) |proof| proof.close();
        self.publication_proof = null;
        if (self.deletion_proof) |proof| proof.close();
        self.deletion_proof = null;
        if (self.owned_ns) |token| token.release();
        self.owned_ns = null;
    }

    /// Caller holds the stable-ID lease and namespace reservation. No content rehash.
    pub fn recheckPublication(self: *const Result, root: []const u8) !void {
        if (self.operation == .deleted) {
            const proof = self.deletion_proof orelse return error.InvalidCompletedPublication;
            try proof.recheck(root, self.instance.name);
            return;
        }
        if (!self.local_client_verified) return;
        const proof = self.publication_proof orelse return error.InvalidCompletedPublication;
        try proof.recheck(root, self.instance.name);
    }

    pub fn deinit(self: *Result) void {
        const token = self.owned_ns;
        self.owned_ns = null;
        self.releasePublicationProof();
        self.arena.deinit();
        if (token) |held| held.release();
        self.* = undefined;
    }
};

fn check(io: std.Io, instance: config.Instance, options: Options) !void {
    try io.checkCancel();
    try safe.canceled(options.cancel);
    {
        try worlds.transaction_gate.lock(io);
        defer worlds.transaction_gate.unlock(io);
        for (options.guard.running_ids) |id| if (std.mem.eql(u8, id, instance.id)) return error.InstanceRunning;
    }
    try safe.canceled(options.cancel);
}
fn requireScope(options: Options) !LeaseCheck {
    const lease = options.lease orelse return error.MissingStableScope;
    if (options.guard.is_running != null) return error.UnsupportedInstanceGuard;
    return lease;
}
fn recheckNamespace(token: namespace.Token, options: Options) !void {
    if (options.worker_checks) {
        try token.recheckWaiting();
    } else {
        try token.recheck();
    }
}
fn reserveNamespace(io: std.Io, options: Options) !namespace.Token {
    if (options.namespace_token) |token| {
        try recheckNamespace(token, options);
        return token;
    }
    return if (options.worker_checks) namespace.acquireWaiting(io) else namespace.acquire(io);
}
fn canceled(context: ?*anyopaque) bool {
    const flag: *const std.atomic.Value(bool) = @ptrCast(@alignCast(context.?));
    return flag.load(.acquire);
}
fn hooks(options: Options) tree.Hooks {
    return .{ .context = if (options.cancel) |flag| @constCast(flag) else null, .canceled = if (options.cancel != null) canceled else null };
}
fn validate(instance: config.Instance, options: Options) !void {
    if (!config.validId(instance.id) or !config.validId(instance.name)) return error.UnsafeInstance;
    try safe.component(instance.name);
    if (options.limits.max_files == 0 or options.limits.max_files > 100_000 or
        options.limits.max_bytes == 0 or options.limits.max_bytes > 32 * 1024 * 1024 * 1024 or
        options.limits.max_file_bytes == 0 or options.limits.max_file_bytes > 4 * 1024 * 1024 * 1024 or
        options.limits.max_depth == 0 or options.limits.max_depth > 32 or
        options.limits.max_manifest_bytes == 0 or options.limits.max_manifest_bytes > 32 * 1024 * 1024) return error.InvalidLimits;
}
fn owned(a: A, instance: config.Instance) !config.Instance {
    var result = instance;
    result.id = try a.dupe(u8, instance.id);
    result.name = try a.dupe(u8, instance.name);
    result.minecraft_version = try a.dupe(u8, instance.minecraft_version);
    if (instance.loader_version) |s| result.loader_version = try a.dupe(u8, s);
    if (instance.java_path) |s| result.java_path = try a.dupe(u8, s);
    if (instance.origin) |o| result.origin = .{ .kind = o.kind, .project_id = try a.dupe(u8, o.project_id), .version_id = try a.dupe(u8, o.version_id) };
    return result;
}
fn directoryStat(io: std.Io, dir: Dir) !Stat {
    const stat = try dir.statFile(io, ".", .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.UnsafeFileType;
    return stat;
}
fn sameInode(x: Stat, y: Stat) !void {
    if (x.kind != y.kind or x.inode != y.inode) return error.TreeChanged;
    if (@hasField(Stat, "device")) if (x.device != y.device) return error.TreeChanged;
    if (@hasField(Stat, "dev")) if (x.dev != y.dev) return error.TreeChanged;
}
const Root = struct {
    root: Dir,
    minecraft: Dir,
    versions: Dir,
    fn open(io: std.Io, path: []const u8) !Root {
        const root = try tree.openAbsolute(io, path);
        errdefer root.close(io);
        const minecraft = try tree.child(io, root, ".minecraft", false);
        errdefer minecraft.close(io);
        const versions = try tree.child(io, minecraft, "versions", false);
        return .{ .root = root, .minecraft = minecraft, .versions = versions };
    }
    fn close(self: Root, io: std.Io) void {
        self.versions.close(io);
        self.minecraft.close(io);
        self.root.close(io);
    }
    fn verify(self: Root, io: std.Io, path: []const u8) !void {
        const current = try Root.open(io, path);
        defer current.close(io);
        try sameInode(try directoryStat(io, self.root), try directoryStat(io, current.root));
        try sameInode(try directoryStat(io, self.minecraft), try directoryStat(io, current.minecraft));
        try sameInode(try directoryStat(io, self.versions), try directoryStat(io, current.versions));
    }
};
const DeletionProof = struct {
    io: std.Io,
    root: Root,

    fn close(self: DeletionProof) void {
        self.root.close(self.io);
    }

    fn recheck(self: DeletionProof, root: []const u8, name: []const u8) !void {
        try self.root.verify(self.io, root);
        _ = self.root.versions.statFile(self.io, name, .{ .follow_symlinks = false }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        return error.TreeChanged;
    }
};
fn collision(io: std.Io, dir: Dir, name: []const u8) !void {
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |entry| {
        count += 1;
        if (count > 100_000) return error.ResourceLimit;
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return error.NameCollision;
    }
}

// Snapshot hashing is reused, but every opened file additionally rejects hardlinks.
fn audit(io: std.Io, dir: Dir, depth: usize, count: *usize, bytes: *u64, options: Options, seal: bool) !void {
    if (depth > options.limits.max_depth) return error.ResourceLimit;
    const before = try directoryStat(io, dir);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try hooks(options).check(io);
        try safe.component(entry.name);
        count.* += 1;
        if (count.* > options.limits.max_files) return error.ResourceLimit;
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        switch (stat.kind) {
            .directory => {
                const child = try tree.child(io, dir, entry.name, false);
                defer child.close(io);
                try sameInode(stat, try directoryStat(io, child));
                try audit(io, child, depth + 1, count, bytes, options, seal);
            },
            .file => {
                if (stat.nlink != 1) return error.HardLinkAlias;
                if (stat.size > options.limits.max_file_bytes or stat.size > options.limits.max_bytes -| bytes.*) return error.ResourceLimit;
                bytes.* += stat.size;
                const file = try dir.openFile(io, entry.name, .{
                    .follow_symlinks = false,
                    .mode = if (builtin.os.tag == .windows and seal) .read_write else .read_only,
                });
                defer file.close(io);
                const opened = try file.stat(io);
                try sameInode(stat, opened);
                if (opened.nlink != 1 or opened.size != stat.size) return error.TreeChanged;
                if (seal) {
                    try file.setPermissions(io, if (builtin.os.tag == .windows)
                        windowsReadOnlyPermissions(opened.permissions)
                    else
                        .fromMode(0o400));
                    try file.sync(io);
                }
                const after = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
                try sameInode(opened, after);
                if (after.nlink != 1) return error.HardLinkAlias;
            },
            else => return error.UnsafeFileType,
        }
    }
    const after = try directoryStat(io, dir);
    try sameInode(before, after);
    if (before.mtime.nanoseconds != after.mtime.nanoseconds) return error.TreeChanged;
    if (seal) {
        // Windows default directory attributes do not provide a POSIX access-mode seal.
        if (builtin.os.tag != .windows) try dir.setPermissions(io, .fromMode(0o500));
        try tree.syncDir(io, dir);
    }
}
fn auditTree(io: std.Io, dir: Dir, options: Options, seal: bool) !void {
    var count: usize = 0;
    var bytes: u64 = 0;
    try audit(io, dir, 0, &count, &bytes, options, seal);
}
fn verified(a: A, io: std.Io, dir: Dir, expected: tree.Snapshot, options: Options) !void {
    try auditTree(io, dir, options, false);
    var actual = try tree.snapshot(a, io, dir, null, options.limits, hooks(options));
    defer actual.deinit();
    if (!tree.equal(expected, actual)) return error.IntegrityMismatch;
}
fn readMetadata(a: A, io: std.Io, dir: Dir, name: []const u8) ![]u8 {
    return readDocument(a, io, dir, name, metadata.max_document_bytes);
}
fn readDocument(a: A, io: std.Io, dir: Dir, name: []const u8, limit: usize) ![]u8 {
    const stat = try dir.statFile(io, name, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.UnsafeFileType;
    if (stat.nlink != 1) return error.HardLinkAlias;
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
    defer file.close(io);
    const opened = try file.stat(io);
    try sameInode(stat, opened);
    if (opened.nlink != 1 or opened.size != stat.size) return error.TreeChanged;
    if (opened.size > limit) return error.MetadataTooLarge;
    const data = try a.alloc(u8, @intCast(opened.size));
    errdefer a.free(data);
    if (try file.readPositionalAll(io, data, 0) != data.len) return error.TreeChanged;
    var extra: [1]u8 = undefined;
    if (try file.readPositional(io, &.{&extra}, opened.size) != 0) return error.TreeChanged;
    const after = try file.stat(io);
    if (after.nlink != 1 or after.size != opened.size or after.mtime.nanoseconds != opened.mtime.nanoseconds or after.ctime.nanoseconds != opened.ctime.nanoseconds) return error.TreeChanged;
    try sameInode(after, try dir.statFile(io, name, .{ .follow_symlinks = false }));
    return data;
}

const ClientProof = struct { id: []const u8, sha1: ?[20]u8 = null, sha256: ?[32]u8 = null, size: ?u64 };
const Receipt = struct { name: []const u8, bytes: []const u8, vanilla: bool };
const Identity = struct {
    minecraft_version: []const u8,
    loader: config.Loader,
    loader_version: ?[]const u8,
    receipt: ?Receipt = null,
    ambiguous_flattened: bool = false,
    client: ?ClientProof = null,
};
pub const max_install_receipt_bytes = 8 * 1024 * 1024;
const receipt_limit = max_install_receipt_bytes;
const receipt_string_limit = 4096;
const ReceiptArtifact = struct { path: []const u8, sha256: []const u8, size: u64 };
const ReceiptBounds = struct { artifact_bindings: ?[]const ReceiptArtifact = null };

// Bound structure before dynamic Value maps/arrays can amplify a small document.
fn receiptPreflight(a: A, bytes: []const u8) !void {
    if (bytes.len > receipt_limit) return error.MetadataTooLarge;
    var scanner = std.json.Scanner.initCompleteInput(a, bytes);
    defer scanner.deinit();
    var depth: usize = 0;
    var tokens: usize = 0;
    var root_key = true;
    var expect_bindings = false;
    var bindings = false;
    var binding_count: usize = 0;
    var binding_key = true;
    var binding_fields: u3 = 0;
    while (true) {
        const token = scanner.nextAllocMax(a, .alloc_if_needed, receipt_string_limit) catch |err| return switch (err) {
            error.OutOfMemory => err,
            error.ValueTooLong => error.ResourceLimit,
            else => error.InvalidInstallReceipt,
        };
        defer switch (token) {
            .allocated_string, .allocated_number => |text| a.free(text),
            else => {},
        };
        tokens += 1;
        if (tokens > 65536) return error.ResourceLimit;
        if (tokens == 1 and token != .object_begin) return error.InvalidInstallReceipt;
        if (bindings and depth == 2 and token != .object_begin and token != .array_end) return error.InvalidInstallReceipt;
        switch (token) {
            .object_begin, .array_begin => {
                if (expect_bindings) {
                    if (token != .array_begin) return error.InvalidInstallReceipt;
                    bindings = true;
                    expect_bindings = false;
                }
                if (bindings and depth >= 3) return error.InvalidInstallReceipt;
                depth += 1;
                if (depth > 8) return error.ResourceLimit;
                if (bindings and depth == 3) {
                    binding_count += 1;
                    if (binding_count > 4096) return error.ResourceLimit;
                    binding_key = true;
                    binding_fields = 0;
                }
            },
            .object_end, .array_end => {
                if (bindings and depth == 3 and binding_fields != 7) return error.InvalidInstallReceipt;
                if (depth == 0) return error.InvalidInstallReceipt;
                depth -= 1;
                if (depth == 1) {
                    root_key = true;
                    bindings = false;
                }
            },
            .string, .allocated_string => |text| {
                if (text.len > receipt_string_limit) return error.ResourceLimit;
                if (depth == 1) {
                    if (root_key) {
                        expect_bindings = std.mem.eql(u8, text, "artifact_bindings");
                        root_key = false;
                    } else {
                        if (expect_bindings) return error.InvalidInstallReceipt;
                        root_key = true;
                    }
                } else if (bindings and depth == 3) {
                    if (binding_key) {
                        const bit: u3 = if (std.mem.eql(u8, text, "path")) 1 else if (std.mem.eql(u8, text, "sha256")) 2 else if (std.mem.eql(u8, text, "size")) 4 else return error.InvalidInstallReceipt;
                        if (binding_fields & bit != 0) return error.InvalidInstallReceipt;
                        binding_fields |= bit;
                    }
                    binding_key = !binding_key;
                }
            },
            .end_of_document => break,
            else => {
                switch (token) {
                    .number, .allocated_number => |text| if (text.len > receipt_string_limit) return error.ResourceLimit,
                    else => {},
                }
                if (depth == 1) {
                    if (expect_bindings) return error.InvalidInstallReceipt;
                    root_key = true;
                } else if (bindings and depth == 3) binding_key = !binding_key;
            },
        }
    }
    var typed = std.json.parseFromSlice(ReceiptBounds, a, bytes, .{ .ignore_unknown_fields = true, .max_value_len = receipt_string_limit }) catch |err| return if (err == error.OutOfMemory) err else error.InvalidInstallReceipt;
    defer typed.deinit();
    var aliases = std.StringHashMap(void).init(a);
    defer {
        var keys = aliases.keyIterator();
        while (keys.next()) |key| a.free(key.*);
        aliases.deinit();
    }
    if (typed.value.artifact_bindings) |entries| for (entries) |entry| {
        if (!std.mem.startsWith(u8, entry.path, "libraries/") or !lowerHex(entry.sha256, 64)) return error.InvalidInstallReceipt;
        var components = std.mem.splitScalar(u8, entry.path, '/');
        while (components.next()) |part| safe.component(part) catch return error.InvalidInstallReceipt;
        const key = try std.ascii.allocLowerString(a, entry.path);
        errdefer a.free(key);
        const found = try aliases.getOrPut(key);
        if (found.found_existing) return error.DuplicateArtifactPath;
    };
}
fn parseReceipt(a: A, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    try receiptPreflight(a, bytes);
    return std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always, .max_value_len = receipt_string_limit }) catch |err| return if (err == error.OutOfMemory) err else error.InvalidInstallReceipt;
}
/// Caller owns the returned parsed arena and must call deinit().
pub fn parseInstallReceipt(a: A, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return parseReceipt(a, bytes);
}
fn fieldText(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidInstallReceipt;
    if (value != .string) return error.InvalidInstallReceipt;
    return value.string;
}
fn lowerHex(text: []const u8, length: usize) bool {
    if (text.len != length) return false;
    for (text) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}
fn optionalReceipt(a: A, io: std.Io, dir: Dir, name: []const u8) !?[]const u8 {
    return readDocument(a, io, dir, name, receipt_limit) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}
fn receiptIdentity(a: A, io: std.Io, dir: Dir, instance: config.Instance, document: metadata.Version, document_bytes: []const u8) !?Identity {
    const vanilla = try optionalReceipt(a, io, dir, ".vela-instance.json");
    const modded = try optionalReceipt(a, io, dir, ".vela-loader.json");
    if (vanilla != null and modded != null) return error.InvalidInstallReceipt;
    const bytes = vanilla orelse modded orelse return null;
    var parsed = try parseReceipt(a, bytes);
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInstallReceipt;
    const object = parsed.value.object;
    const schema = object.get("schema_version") orelse return error.InvalidInstallReceipt;
    if (schema != .integer or schema.integer != 1) return error.InvalidInstallReceipt;
    const id = try fieldText(object, "instance_id");
    const name = try fieldText(object, "instance_name");
    const base = try fieldText(object, "minecraft_version");
    const kind = std.meta.stringToEnum(config.Loader, try fieldText(object, "loader")) orelse return error.InvalidInstallReceipt;
    if (!config.validId(id) or !config.validId(name) or !config.validId(base)) return error.InvalidInstallReceipt;
    if (!std.mem.eql(u8, name, instance.name) or !std.mem.eql(u8, document.id, name) or document.jar != null or document.inherits_from != null) return error.InvalidInstallReceipt;
    const version = object.get("loader_version") orelse return error.InvalidInstallReceipt;
    const loader_version: ?[]const u8 = if (kind == .vanilla) blk: {
        if (version != .null or vanilla == null) return error.InvalidInstallReceipt;
        break :blk null;
    } else blk: {
        if (version != .string or !config.validId(version.string) or modded == null) return error.InvalidInstallReceipt;
        break :blk try a.dupe(u8, version.string);
    };
    const expected = try fieldText(object, "metadata_sha256");
    if (!lowerHex(expected, 64)) return error.InvalidInstallReceipt;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(document_bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(&digest, .lower);
    if (!std.mem.eql(u8, expected, &actual)) return error.InstallReceiptMismatch;
    const client_hash = try fieldText(object, "client_sha256");
    if (!lowerHex(client_hash, 64)) return error.InvalidInstallReceipt;
    var client_sha256: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&client_sha256, client_hash);
    const client_size = object.get("client_size") orelse return error.InvalidInstallReceipt;
    if (client_size != .integer or client_size.integer < 0) return error.InvalidInstallReceipt;
    if (object.get("client_jar")) |client_jar| {
        if (client_jar != .string) return error.InvalidInstallReceipt;
        const expected_jar = try std.fmt.allocPrint(a, "{s}.jar", .{instance.name});
        defer a.free(expected_jar);
        if (!std.mem.eql(u8, client_jar.string, expected_jar)) return error.InvalidInstallReceipt;
    }
    if (modded != null) {
        if (!lowerHex(try fieldText(object, "source_sha1"), 40) or !lowerHex(try fieldText(object, "profile_sha1"), 40)) return error.InvalidInstallReceipt;
        const url = try fieldText(object, "source_url");
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return error.InvalidInstallReceipt;
    }
    return .{ .minecraft_version = try a.dupe(u8, base), .loader = kind, .loader_version = loader_version, .receipt = .{ .name = if (vanilla != null) ".vela-instance.json" else ".vela-loader.json", .bytes = bytes, .vanilla = vanilla != null }, .client = .{ .id = try a.dupe(u8, name), .sha256 = client_sha256, .size = @intCast(client_size.integer) } };
}
fn inspect(a: A, io: std.Io, root: []const u8, handles: Root, instance: config.Instance, options: Options) !Identity {
    const minecraft_path = try std.fs.path.join(a, &.{ root, ".minecraft" });
    const filename = try std.fmt.allocPrint(a, "{s}.json", .{instance.name});
    const metadata_path = try std.fs.path.join(a, &.{ minecraft_path, "versions", instance.name, filename });
    var loaded = try loader.load(a, io, .{ .root = minecraft_path, .version_id = instance.name, .metadata_path = metadata_path, .cancel = options.cancel }, .{});
    defer loaded.deinit();
    var identity: Identity = .{ .minecraft_version = "", .loader = .vanilla, .loader_version = null };
    // Reopen every source through pinned rooted handles and compare the bytes used.
    for (loaded.sources.value, 0..) |source, index| {
        const folder = if (index == 0) instance.name else source.id;
        const dir = try tree.child(io, handles.versions, folder, false);
        defer dir.close(io);
        const name = try std.fmt.allocPrint(a, "{s}.json", .{folder});
        const bytes = try readMetadata(a, io, dir, name);
        if (!std.mem.eql(u8, bytes, source.bytes)) return error.TreeChanged;
        var parsed = try metadata.parseSlice(a, bytes);
        defer parsed.deinit();
        if (index == 0 and parsed.value.inherits_from == null) {
            if (try receiptIdentity(a, io, dir, instance, parsed.value, bytes)) |verified_identity| {
                identity = verified_identity;
            } else {
                identity.ambiguous_flattened = true;
            }
        }
    }
    if (identity.receipt == null) identity.minecraft_version = try inheritanceBase(a, loaded.sources.value);
    if (identity.minecraft_version.len == 0) return error.MissingBaseVersion;
    if (identity.receipt == null) for (loaded.version.value.downloads) |download| if (std.mem.eql(u8, download.name, "client")) {
        identity.client = .{ .id = try a.dupe(u8, loaded.version.value.jar orelse loaded.version.value.id), .sha1 = download.download.sha1, .size = download.download.size };
        break;
    };
    if (loaded.version.value.libraries) |libraries| for (libraries) |library| {
        var parts = std.mem.splitScalar(u8, library.name, ':');
        const group = parts.next() orelse continue;
        const artifact = parts.next() orelse continue;
        const version = parts.next() orelse continue;
        const kind: ?config.Loader = if (std.mem.eql(u8, group, "net.fabricmc") and std.mem.eql(u8, artifact, "fabric-loader")) .fabric else if (std.mem.eql(u8, group, "org.quiltmc") and std.mem.eql(u8, artifact, "quilt-loader")) .quilt else if (std.mem.eql(u8, group, "net.minecraftforge") and std.mem.eql(u8, artifact, "forge")) .forge else if (std.mem.eql(u8, group, "net.neoforged") and (std.mem.eql(u8, artifact, "neoforge") or std.mem.eql(u8, artifact, "forge"))) .neoforge else null;
        if (kind) |k| {
            if (identity.loader != .vanilla and identity.loader != k) return error.UnknownLoaderIdentity;
            identity.loader = k;
            if (identity.receipt == null) {
                identity.loader_version = try a.dupe(u8, version);
            } else if (!std.mem.eql(u8, version, identity.loader_version orelse return error.InstallReceiptMismatch)) {
                const prefixed = try std.fmt.allocPrint(a, "{s}-{s}", .{ identity.minecraft_version, identity.loader_version.? });
                if (!std.mem.eql(u8, artifact, "forge") or !std.mem.eql(u8, version, prefixed)) return error.InstallReceiptMismatch;
            }
        }
    };
    const main = loaded.version.value.main_class orelse return error.MissingMainClass;
    if (identity.loader == .vanilla and !std.mem.eql(u8, main, "net.minecraft.client.main.Main") and !std.mem.eql(u8, main, "net.minecraft.client.Minecraft") and !std.mem.eql(u8, main, "com.mojang.minecraft.MinecraftApplet")) return error.UnknownLoaderIdentity;
    if (identity.receipt) |receipt| if (receipt.vanilla and identity.loader != .vanilla) return error.InstallReceiptMismatch;
    try handles.verify(io, root);
    return identity;
}

/// Proves local base/loader identity and the resolved client JAR, not libraries/assets/Java.
pub fn inspectInstalled(a: A, io: std.Io, root: []const u8, instance: config.Instance, options: Options) !Result {
    return inspectExisting(a, io, root, instance, options);
}
/// Parent holds the stable-ID lease across this call and publication of its result.
/// Lease callbacks and all filesystem work run outside the gate.
pub fn inspectInstalledLeased(a: A, io: std.Io, root: []const u8, instance: config.Instance, options: Options, lease: LeaseCheck) !Result {
    var scoped = options;
    scoped.lease = lease;
    return inspectExisting(a, io, root, instance, scoped);
}
fn inspectExisting(a: A, io: std.Io, root: []const u8, instance: config.Instance, options: Options) !Result {
    const lease = try requireScope(options);
    try validate(instance, options);
    try lease.recheck(lease.context, instance.id);
    const token = try reserveNamespace(io, options);
    // Release last unless a returned live proof takes ownership of this token.
    var release_token = options.namespace_token == null;
    defer if (release_token) token.release();
    try recheckNamespace(token, options);
    try check(io, instance, options);
    var result = try inspectExistingBody(a, io, root, instance, options);
    errdefer result.deinit();
    try lease.recheck(lease.context, instance.id);
    try recheckNamespace(token, options);
    try check(io, instance, options);
    if (release_token and result.publication_proof != null) {
        result.owned_ns = token;
        release_token = false;
    }
    return result;
}
const HeldFile = struct {
    file: std.Io.File,
    stat: Stat,
    fn open(io: std.Io, dir: Dir, name: []const u8) !HeldFile {
        const named = try dir.statFile(io, name, .{ .follow_symlinks = false });
        if (named.kind != .file) return error.UnsafeFileType;
        if (named.nlink != 1) return error.HardLinkAlias;
        const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
        errdefer file.close(io);
        const opened = try file.stat(io);
        try sameFile(named, opened);
        return .{ .file = file, .stat = opened };
    }
    fn recheck(self: HeldFile, io: std.Io, dir: Dir, name: []const u8) !void {
        try sameFile(self.stat, try self.file.stat(io));
        try sameFile(self.stat, try dir.statFile(io, name, .{ .follow_symlinks = false }));
    }
};
const HeldClient = struct {
    dir: Dir,
    file: HeldFile,
    fn close(self: HeldClient, io: std.Io) void {
        self.file.file.close(io);
        self.dir.close(io);
    }
};
const PublicationProof = struct {
    io: std.Io,
    root: Root,
    source: Dir,
    source_stat: Stat,
    metadata: HeldFile,
    client: HeldClient,
    fn close(self: PublicationProof) void {
        self.client.close(self.io);
        self.metadata.file.close(self.io);
        self.source.close(self.io);
        self.root.close(self.io);
    }
    fn recheck(self: PublicationProof, root: []const u8, name: []const u8) !void {
        try self.root.verify(self.io, root);
        const named_source = try self.root.versions.statFile(self.io, name, .{ .follow_symlinks = false });
        try sameDirectory(self.source_stat, named_source);
        try sameDirectory(self.source_stat, try directoryStat(self.io, self.source));
        try sameDirectory(self.source_stat, try directoryStat(self.io, self.client.dir));
        var buffer: [512]u8 = undefined;
        try self.metadata.recheck(self.io, self.source, try std.fmt.bufPrint(&buffer, "{s}.json", .{name}));
        try self.client.file.recheck(self.io, self.client.dir, try std.fmt.bufPrint(&buffer, "{s}.jar", .{name}));
    }
};
fn sameFile(before: Stat, after: Stat) !void {
    if (after.kind != .file) return error.UnsafeFileType;
    if (after.nlink != 1) return error.HardLinkAlias;
    try sameInode(before, after);
    if (before.size != after.size or before.mtime.nanoseconds != after.mtime.nanoseconds or before.ctime.nanoseconds != after.ctime.nanoseconds) return error.TreeChanged;
}
fn sameDirectory(before: Stat, after: Stat) !void {
    if (after.kind != .directory) return error.UnsafeFileType;
    try sameInode(before, after);
    if (before.mtime.nanoseconds != after.mtime.nanoseconds or before.ctime.nanoseconds != after.ctime.nanoseconds) return error.TreeChanged;
}
const CanonicalProof = struct { client: ClientProof, metadata: HeldFile };

fn canonicalVanilla(a: A, io: std.Io, root: []const u8, source: Dir, instance: config.Instance, identity: Identity, proof: TrustedVanilla) !CanonicalProof {
    const prepared = proof.prepared;
    try prepared.validateBinding(a, io, .{ .root = root, .instance_id = instance.id, .instance_name = instance.name, .version_id = identity.minecraft_version, .generation = proof.generation, .environment = proof.environment });
    if (identity.loader != .vanilla or identity.loader_version != null or
        !std.mem.eql(u8, identity.minecraft_version, instance.name) or prepared.sources.len != 1 or
        !std.mem.eql(u8, prepared.sources[0].id, instance.name)) return error.UntrustedCanonicalVanilla;
    const version = prepared.base.value;
    if (!std.mem.eql(u8, version.id, instance.name) or version.inherits_from != null or version.jar != null or
        !std.mem.eql(u8, version.main_class orelse return error.MissingMainClass, "net.minecraft.client.main.Main")) return error.UntrustedCanonicalVanilla;
    if (prepared.runtime_major != metadata.requiredJavaMajor(version)) return error.PreparedMetadataMismatch;
    const filename = try std.fmt.allocPrint(a, "{s}.json", .{instance.name});
    const held = try HeldFile.open(io, source, filename);
    errdefer held.file.close(io);
    if (held.stat.size != prepared.sources[0].bytes.len) return error.PreparedMetadataChanged;
    const bytes = try a.alloc(u8, @intCast(held.stat.size));
    if (try held.file.readPositionalAll(io, bytes, 0) != bytes.len) return error.TreeChanged;
    try held.recheck(io, source, filename);
    if (!std.mem.eql(u8, bytes, prepared.sources[0].bytes)) return error.PreparedMetadataChanged;
    for (version.downloads) |download| {
        if (!std.mem.eql(u8, download.name, "client")) continue;
        return .{ .client = .{ .id = instance.name, .sha1 = download.download.sha1 orelse return error.MissingClientHash, .size = download.download.size orelse return error.MissingClientSize }, .metadata = held };
    }
    return error.MissingClientDownload;
}

fn inspectExistingBody(a: A, io: std.Io, root: []const u8, instance: config.Instance, options: Options) !Result {
    var result: Result = .{ .arena = .init(a), .operation = .inspected, .instance = undefined };
    errdefer result.deinit();
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const ar = scratch.allocator();
    const output = result.arena.allocator();
    result.instance = try owned(output, instance);
    const handles = try Root.open(io, root);
    var retained = false;
    defer if (!retained) handles.close(io);
    const source = try tree.child(io, handles.versions, instance.name, false);
    defer if (!retained) source.close(io);
    var held_metadata: ?HeldFile = null;
    defer if (held_metadata) |held| held.file.close(io);
    var held_client: ?HeldClient = null;
    defer if (held_client) |held| held.close(io);
    const before = try directoryStat(io, source);
    try auditTree(io, source, options, false);
    var snapshot = try tree.snapshot(ar, io, source, null, options.limits, hooks(options));
    defer snapshot.deinit();
    const identity = try inspect(ar, io, root, handles, instance, options);
    var client = identity.client;
    if (identity.ambiguous_flattened) {
        const proof = options.trusted_vanilla orelse return error.MissingInstallReceipt;
        const canonical = try canonicalVanilla(ar, io, root, source, instance, identity, proof);
        held_metadata = canonical.metadata;
        client = canonical.client;
    }
    result.instance.minecraft_version = try output.dupe(u8, identity.minecraft_version);
    result.instance.loader = identity.loader;
    result.instance.loader_version = if (identity.loader_version) |version| try output.dupe(u8, version) else null;
    held_client = try verifyClient(io, handles, client orelse return error.MissingClientDownload, options);
    try verified(ar, io, source, snapshot, options);
    try sameDirectory(before, try handles.versions.statFile(io, instance.name, .{ .follow_symlinks = false }));
    if (identity.ambiguous_flattened) {
        const publication: PublicationProof = .{ .io = io, .root = handles, .source = source, .source_stat = before, .metadata = held_metadata.?, .client = held_client.? };
        try publication.recheck(root, instance.name);
        result.publication_proof = publication;
        retained = true;
        held_metadata = null;
        held_client = null;
        result.local_client_verified = true;
    }
    return result;
}

fn canonicalProtection(a: A, io: std.Io, versions: Dir, instance: config.Instance, base: []const u8, options: Options) !void {
    if (std.ascii.eqlIgnoreCase(instance.name, base)) return error.CanonicalVersionProtected;
    var it = versions.iterate();
    var count: usize = 0;
    var bytes_read: usize = 0;
    while (try it.next(io)) |entry| {
        try hooks(options).check(io);
        count += 1;
        if (count > 4096) return error.ResourceLimit;
        if (std.mem.eql(u8, entry.name, instance.name)) continue;
        // No following unknown entries just to inspect canonical dependencies.
        const stat = try versions.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .directory) return error.UnsafeFileType;
        try safe.component(entry.name);
        const dir = try tree.child(io, versions, entry.name, false);
        defer dir.close(io);
        const name = try std.fmt.allocPrint(a, "{s}.json", .{entry.name});
        const bytes = readMetadata(a, io, dir, name) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        bytes_read += bytes.len;
        if (bytes_read > 64 * 1024 * 1024) return error.ResourceLimit;
        var parsed = try metadata.parseSlice(a, bytes);
        defer parsed.deinit();
        if (parsed.value.inherits_from) |parent| if (std.ascii.eqlIgnoreCase(parent, instance.name)) return error.CanonicalVersionProtected;
        if (parsed.value.jar) |jar| if (std.ascii.eqlIgnoreCase(jar, instance.name)) return error.CanonicalVersionProtected;
    }
}
fn privateDir(io: std.Io, parent: Dir, name: []const u8) !Dir {
    try parent.createDir(io, name, content_fs.privatePermissions(true));
    return tree.child(io, parent, name, false);
}
const Manifest = struct {
    schema_version: u32 = 1,
    transaction_id: []const u8,
    operation: Operation,
    instance_id: []const u8,
    old_name: []const u8,
    new_name: ?[]const u8,
    instance: config.Instance,
    snapshot_bytes: u64,
    entries: []const tree.Entry,
    backup: []const u8 = "backup",
    original: []const u8 = "original",
    phase: []const u8 = "prepared",
};
fn writeManifest(a: A, io: std.Io, dir: Dir, manifest: Manifest, options: Options) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(a, manifest, .{});
    if (json.len > options.limits.max_manifest_bytes) return error.ResourceLimit;
    const file = try dir.createFile(io, "manifest.json", .{ .read = true, .exclusive = true, .permissions = content_fs.privatePermissions(false) });
    defer file.close(io);
    try file.writePositionalAll(io, json, 0);
    try file.setPermissions(io, if (builtin.os.tag == .windows)
        windowsReadOnlyPermissions((try file.stat(io)).permissions)
    else
        .fromMode(0o400));
    try file.sync(io);
    try tree.syncDir(io, dir);
    try verifyManifest(a, io, dir, json, options);
    return json;
}
fn verifyManifest(a: A, io: std.Io, dir: Dir, expected: []const u8, options: Options) !void {
    const before = try dir.statFile(io, "manifest.json", .{ .follow_symlinks = false });
    if (before.kind != .file or before.nlink != 1) return error.UnsafeFileType;
    const actual = try tree.readBounded(a, io, dir, "manifest.json", options.limits.max_manifest_bytes);
    defer a.free(actual);
    if (!std.mem.eql(u8, actual, expected)) return error.IntegrityMismatch;
    const after = try dir.statFile(io, "manifest.json", .{ .follow_symlinks = false });
    try sameInode(before, after);
    if (after.nlink != 1) return error.HardLinkAlias;
}

pub fn rename(a: A, io: std.Io, root: []const u8, instance: config.Instance, new_name: []const u8, options: Options) !Result {
    _ = try requireScope(options);
    if (!config.validId(new_name)) return error.UnsafeInstance;
    try safe.component(new_name);
    if (std.ascii.eqlIgnoreCase(instance.name, new_name)) return error.SameInstanceName;
    return transact(a, io, root, instance, new_name, .renamed, options);
}
pub fn remove(a: A, io: std.Io, root: []const u8, instance: config.Instance, options: Options) !Result {
    return eraseInstance(a, io, root, instance, options);
}

/// Every directory is pinned before erasure; paths used for unlink are single
/// validated components relative to those handles, never recursive string paths.
const ErasePlan = struct {
    const Directory = struct { handle: Dir, parent: ?usize, name: []const u8, stat: Stat };
    const File = struct { parent: usize, name: []const u8, stat: Stat, identity: bool };
    allocator: A,
    directories: std.ArrayList(Directory) = .empty,
    files: std.ArrayList(File) = .empty,
    entries: usize = 0,

    fn close(self: *ErasePlan, io: std.Io) void {
        // The root is borrowed from eraseInstance; descendant handles are owned.
        for (self.directories.items[1..]) |directory| directory.handle.close(io);
        self.directories.deinit(self.allocator);
        self.files.deinit(self.allocator);
    }

    fn collect(self: *ErasePlan, io: std.Io, parent: usize, depth: usize, json_name: []const u8, receipt_name: ?[]const u8, options: Options) anyerror!void {
        if (depth > options.limits.max_depth) return error.ResourceLimit;
        const dir = self.directories.items[parent].handle;
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            try hooks(options).check(io);
            try safe.component(entry.name);
            self.entries += 1;
            if (self.entries > options.limits.max_files) return error.ResourceLimit;
            const name = try self.allocator.dupe(u8, entry.name);
            const stat = try dir.statFile(io, name, .{ .follow_symlinks = false });
            switch (stat.kind) {
                .directory => {
                    const child = try tree.child(io, dir, name, false);
                    var retained = false;
                    defer if (!retained) child.close(io);
                    try sameInode(stat, try directoryStat(io, child));
                    const index = self.directories.items.len;
                    try self.directories.append(self.allocator, .{ .handle = child, .parent = parent, .name = name, .stat = stat });
                    retained = true;
                    try self.collect(io, index, depth + 1, json_name, receipt_name, options);
                },
                .file => {
                    if (stat.nlink != 1) return error.HardLinkAlias;
                    const identity = parent == 0 and (std.mem.eql(u8, name, json_name) or (if (receipt_name) |receipt| std.mem.eql(u8, name, receipt) else false));
                    try self.files.append(self.allocator, .{ .parent = parent, .name = name, .stat = stat, .identity = identity });
                },
                else => return error.UnsafeFileType,
            }
        }
    }

    fn verifyDirectories(self: *const ErasePlan, io: std.Io, index: usize) !void {
        var current = index;
        while (self.directories.items[current].parent) |parent| {
            const directory = self.directories.items[current];
            try sameInode(directory.stat, try directoryStat(io, directory.handle));
            try sameInode(directory.stat, try self.directories.items[parent].handle.statFile(io, directory.name, .{ .follow_symlinks = false }));
            current = parent;
        }
        try sameInode(self.directories.items[0].stat, try directoryStat(io, self.directories.items[0].handle));
    }

    fn eraseFile(self: *const ErasePlan, io: std.Io, file: File) !void {
        try self.verifyDirectories(io, file.parent);
        const dir = self.directories.items[file.parent].handle;
        const current = try dir.statFile(io, file.name, .{ .follow_symlinks = false });
        try sameInode(file.stat, current);
        if (current.nlink != 1 or current.size != file.stat.size or current.mtime.nanoseconds != file.stat.mtime.nanoseconds) return error.TreeChanged;
        try dir.deleteFile(io, file.name);
    }
};

fn eraseInstance(a: A, io: std.Io, root: []const u8, instance: config.Instance, options: Options) !Result {
    const lease = try requireScope(options);
    try validate(instance, options);
    try lease.recheck(lease.context, instance.id);
    const token = try reserveNamespace(io, options);
    defer if (options.namespace_token == null) token.release();
    try recheckNamespace(token, options);
    var result: Result = .{ .arena = .init(a), .operation = .deleted, .instance = undefined };
    errdefer result.deinit();
    result.instance = try owned(result.arena.allocator(), instance);
    result.original_name = try result.arena.allocator().dupe(u8, instance.name);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const ar = scratch.allocator();
    const handles = try Root.open(io, root);
    var release_handles = true;
    defer if (release_handles) handles.close(io);
    try check(io, instance, options);
    const source = try tree.child(io, handles.versions, instance.name, false);
    defer source.close(io);
    const source_stat = try directoryStat(io, source);
    const identity = try inspect(ar, io, root, handles, instance, options);
    if (identity.ambiguous_flattened) return error.CanonicalVersionProtected;
    try canonicalProtection(ar, io, handles.versions, instance, identity.minecraft_version, options);
    try auditTree(io, source, options, false);
    var snapshot = try tree.snapshot(ar, io, source, null, options.limits, hooks(options));
    defer snapshot.deinit();
    var plan: ErasePlan = .{ .allocator = ar };
    // Install the borrowed root before the cleanup scope uses directories[1..].
    try plan.directories.append(ar, .{ .handle = source, .parent = null, .name = instance.name, .stat = source_stat });
    defer plan.close(io);
    const json_name = try std.fmt.allocPrint(ar, "{s}.json", .{instance.name});
    try plan.collect(io, 0, 0, json_name, if (identity.receipt) |receipt| receipt.name else null, options);
    try lease.recheck(lease.context, instance.id);
    try recheckNamespace(token, options);
    try check(io, instance, options);
    try handles.verify(io, root);
    try sameInode(source_stat, try handles.versions.statFile(io, instance.name, .{ .follow_symlinks = false }));
    try canonicalProtection(ar, io, handles.versions, instance, identity.minecraft_version, options);
    try verified(ar, io, source, snapshot, options);
    for (plan.directories.items, 0..) |_, index| try plan.verifyDirectories(io, index);
    try lease.recheck(lease.context, instance.id);
    try recheckNamespace(token, options);
    try check(io, instance, options);

    // Transfer the already acquired roots before the first destructive operation.
    // Failure cleanup closes them; success retains rooted absence for publication.
    result.deletion_proof = .{ .io = io, .root = handles };
    release_handles = false;

    // From the first unlink onward there is no rollback. Retain intervention debt
    // on any failure instead of treating an unknown partial erasure as cancellation.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    for ([_]bool{ false, true }) |identity_files| {
        for (plan.files.items) |file| {
            if (file.identity != identity_files) continue;
            handles.verify(io, root) catch return error.PermanentDeletionIncomplete;
            sameInode(source_stat, handles.versions.statFile(io, instance.name, .{ .follow_symlinks = false }) catch return error.PermanentDeletionIncomplete) catch return error.PermanentDeletionIncomplete;
            plan.eraseFile(io, file) catch return error.PermanentDeletionIncomplete;
        }
        if (!identity_files) {
            var index = plan.directories.items.len;
            while (index > 1) {
                index -= 1;
                const directory = plan.directories.items[index];
                handles.verify(io, root) catch return error.PermanentDeletionIncomplete;
                sameInode(source_stat, handles.versions.statFile(io, instance.name, .{ .follow_symlinks = false }) catch return error.PermanentDeletionIncomplete) catch return error.PermanentDeletionIncomplete;
                plan.verifyDirectories(io, index) catch return error.PermanentDeletionIncomplete;
                plan.directories.items[directory.parent.?].handle.deleteDir(io, directory.name) catch return error.PermanentDeletionIncomplete;
            }
        }
    }
    handles.verify(io, root) catch return error.PermanentDeletionIncomplete;
    sameInode(source_stat, handles.versions.statFile(io, instance.name, .{ .follow_symlinks = false }) catch return error.PermanentDeletionIncomplete) catch return error.PermanentDeletionIncomplete;
    handles.versions.deleteDir(io, instance.name) catch return error.PermanentDeletionIncomplete;
    if (!namedAbsent(io, handles.versions, instance.name)) return error.PermanentDeletionIncomplete;
    tree.syncDir(io, handles.versions) catch {
        result.durability_uncertain = true;
    };
    return result;
}
fn transact(a: A, io: std.Io, root: []const u8, instance: config.Instance, new_name: ?[]const u8, operation: Operation, options: Options) !Result {
    const lease = try requireScope(options);
    try validate(instance, options);
    try lease.recheck(lease.context, instance.id);
    const token = try reserveNamespace(io, options);
    defer if (options.namespace_token == null) token.release();
    try recheckNamespace(token, options);
    var result: Result = .{ .arena = .init(a), .operation = operation, .instance = undefined };
    errdefer result.deinit();
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const ar = scratch.allocator();
    const output = result.arena.allocator();
    result.instance = try owned(output, instance);
    result.original_name = try output.dupe(u8, instance.name);
    if (new_name) |name| result.instance.name = try output.dupe(u8, name);
    const handles = try Root.open(io, root);
    defer handles.close(io);
    try check(io, instance, options);
    if (new_name) |name| try collision(io, handles.versions, name);
    const source = try tree.child(io, handles.versions, instance.name, false);
    defer source.close(io);
    const source_stat = try directoryStat(io, source);
    const identity = try inspect(ar, io, root, handles, instance, options);
    if (identity.ambiguous_flattened) return error.CanonicalVersionProtected;
    try canonicalProtection(ar, io, handles.versions, instance, identity.minecraft_version, options);

    try auditTree(io, source, options, false);
    const vela = try tree.child(io, handles.root, ".vela", true);
    defer vela.close(io);
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io, &random);
    const transaction_id = try std.fmt.allocPrint(ar, "instance-{s}", .{std.fmt.bytesToHex(random, .lower)});
    const recovery = try privateDir(io, vela, transaction_id);
    defer recovery.close(io);
    // Failed preparation deliberately retains only private recoverable artifacts.
    result.recovery_directory = try std.fs.path.join(output, &.{ root, ".vela", transaction_id });
    const backup = try privateDir(io, recovery, "backup");
    defer backup.close(io);
    var snapshot = try tree.snapshot(ar, io, source, backup, options.limits, hooks(options));
    defer snapshot.deinit();
    try verified(ar, io, backup, snapshot, options);
    try auditTree(io, backup, options, true);
    try verified(ar, io, backup, snapshot, options);

    var expected_stage: ?tree.Snapshot = null;
    defer if (expected_stage) |*snapshot_value| snapshot_value.deinit();
    if (new_name) |name| {
        const staged = try privateDir(io, recovery, "staged");
        defer staged.close(io);
        var stage_snapshot = try tree.snapshot(ar, io, backup, staged, options.limits, hooks(options));
        defer stage_snapshot.deinit();
        if (!tree.equal(snapshot, stage_snapshot)) return error.IntegrityMismatch;
        try verified(ar, io, staged, snapshot, options);
        const old_json = try std.fmt.allocPrint(ar, "{s}.json", .{instance.name});
        const new_json = try std.fmt.allocPrint(ar, "{s}.json", .{name});
        try collision(io, staged, new_json);
        const rewritten = if (identity.receipt) |receipt| try rewriteFlattened(ar, io, staged, instance, name, receipt) else null;
        try staged.renamePreserve(old_json, staged, new_json, io);
        try tree.syncDir(io, staged);
        const entries = try ar.dupe(tree.Entry, snapshot.entries);
        var expected_bytes = snapshot.bytes;
        const old_jar = try std.fmt.allocPrint(ar, "{s}.jar", .{instance.name});
        const new_jar = try std.fmt.allocPrint(ar, "{s}.jar", .{name});
        for (entries) |*entry| {
            if (std.mem.eql(u8, entry.path, old_json)) {
                entry.path = try ar.dupe(u8, new_json);
                if (rewritten) |data| updateExpected(entry, data.document, &expected_bytes);
            } else if (rewritten != null and std.mem.eql(u8, entry.path, old_jar)) {
                entry.path = try ar.dupe(u8, new_jar);
            } else {
                if (rewritten) |data| if (std.mem.eql(u8, entry.path, identity.receipt.?.name)) updateExpected(entry, data.receipt, &expected_bytes);
                entry.path = try ar.dupe(u8, entry.path);
            }
        }
        std.mem.sort(tree.Entry, entries, {}, struct {
            fn less(_: void, x: tree.Entry, y: tree.Entry) bool {
                return std.mem.lessThan(u8, x.path, y.path);
            }
        }.less);
        expected_stage = .{ .allocator = ar, .entries = entries, .bytes = expected_bytes };
        try verified(ar, io, staged, expected_stage.?, options);
    }
    const manifest_json = try writeManifest(ar, io, recovery, .{ .transaction_id = transaction_id, .operation = operation, .instance_id = instance.id, .old_name = instance.name, .new_name = new_name, .instance = instance, .snapshot_bytes = snapshot.bytes, .entries = snapshot.entries }, options);
    try tree.syncDir(io, vela);

    try lease.recheck(lease.context, instance.id);
    try recheckNamespace(token, options);
    try check(io, instance, options);
    try handles.verify(io, root);
    try sameInode(try directoryStat(io, vela), try handles.root.statFile(io, ".vela", .{ .follow_symlinks = false }));
    try sameInode(try directoryStat(io, recovery), try vela.statFile(io, transaction_id, .{ .follow_symlinks = false }));
    try sameInode(source_stat, try handles.versions.statFile(io, instance.name, .{ .follow_symlinks = false }));
    try canonicalProtection(ar, io, handles.versions, instance, identity.minecraft_version, options);
    if (new_name) |name| try collision(io, handles.versions, name);
    try verified(ar, io, source, snapshot, options);
    try verified(ar, io, backup, snapshot, options);
    var stage_stat: ?Stat = null;
    if (expected_stage) |expected| {
        const staged = try tree.child(io, recovery, "staged", false);
        stage_stat = try directoryStat(io, staged);
        defer staged.close(io);
        try verified(ar, io, staged, expected, options);
    }
    try verifyManifest(ar, io, recovery, manifest_json, options);
    try lease.recheck(lease.context, instance.id);
    try recheckNamespace(token, options);
    try check(io, instance, options);
    // No cancellation after the first namespace mutation: report committed success.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    handles.versions.renamePreserve(instance.name, recovery, "original", io) catch |err| {
        if (!namedMatches(io, handles.versions, instance.name, source_stat) or !namedAbsent(io, recovery, "original")) return error.RecoveryRequired;
        return err;
    };
    if (!namedMatches(io, recovery, "original", source_stat) or !namedAbsent(io, handles.versions, instance.name)) return error.RecoveryRequired;
    if (new_name) |name| {
        recovery.renamePreserve("staged", handles.versions, name, io) catch |err| {
            // A failed syscall is not enough evidence that publication did not occur.
            if (!namedMatches(io, recovery, "staged", stage_stat.?) or !namedDifferent(io, handles.versions, name, stage_stat.?)) return error.RecoveryRequired;
            recovery.renamePreserve("original", handles.versions, instance.name, io) catch return error.RecoveryRequired;
            if (!namedMatches(io, handles.versions, instance.name, source_stat) or !namedAbsent(io, recovery, "original")) return error.RecoveryRequired;
            return err;
        };
        if (!namedMatches(io, handles.versions, name, stage_stat.?) or !namedAbsent(io, recovery, "staged")) return error.RecoveryRequired;
    }
    // Namespace commit already happened. Durability failures must not masquerade as
    // an uncommitted failure; the verified immutable backup remains available.
    tree.syncDir(io, handles.versions) catch {
        result.durability_uncertain = true;
    };
    tree.syncDir(io, recovery) catch {
        result.durability_uncertain = true;
    };
    return result;
}
fn namedMatches(io: std.Io, dir: Dir, name: []const u8, expected: Stat) bool {
    const actual = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return false;
    sameInode(expected, actual) catch return false;
    return true;
}
fn namedAbsent(io: std.Io, dir: Dir, name: []const u8) bool {
    _ = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| return err == error.FileNotFound;
    return false;
}
fn namedDifferent(io: std.Io, dir: Dir, name: []const u8, expected: Stat) bool {
    const actual = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| return err == error.FileNotFound;
    sameInode(expected, actual) catch return true;
    return false;
}
fn inheritanceBase(a: A, sources: []const loader.Source) ![]const u8 {
    var id = sources[0].id;
    for (0..sources.len) |_| {
        const bytes = for (sources) |source| {
            if (std.mem.eql(u8, source.id, id)) break source.bytes;
        } else return error.MissingBaseVersion;
        var parsed = try metadata.parseSlice(a, bytes);
        defer parsed.deinit();
        if (parsed.value.inherits_from) |parent| {
            id = try a.dupe(u8, parent);
        } else return a.dupe(u8, parsed.value.id);
    }
    return error.MissingBaseVersion;
}
fn verifyClient(io: std.Io, handles: Root, client: ClientProof, options: Options) !HeldClient {
    if (client.sha256 == null and client.sha1 == null) return error.MissingClientHash;
    const expected_size = client.size orelse return error.MissingClientSize;
    if (expected_size > options.limits.max_file_bytes or expected_size > options.limits.max_bytes) return error.ResourceLimit;
    try safe.component(client.id);
    const dir = try tree.child(io, handles.versions, client.id, false);
    errdefer dir.close(io);
    var name_buffer: [512]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "{s}.jar", .{client.id});
    const before = try dir.statFile(io, name, .{ .follow_symlinks = false });
    if (before.kind != .file) return error.UnsafeFileType;
    if (before.nlink != 1) return error.HardLinkAlias;
    if (before.size != expected_size) return error.ClientSizeMismatch;
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
    errdefer file.close(io);
    const opened = try file.stat(io);
    try sameInode(before, opened);
    if (opened.nlink != 1 or opened.size != expected_size) return error.TreeChanged;
    var hash: std.crypto.hash.Sha1 = .init(.{});
    var strong_hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var position: u64 = 0;
    while (true) {
        try hooks(options).check(io);
        const n = try file.readPositional(io, &.{&buffer}, position);
        if (n == 0) break;
        if (n > expected_size -| position) return error.ClientSizeMismatch;
        if (client.sha256 != null) strong_hash.update(buffer[0..n]) else hash.update(buffer[0..n]);
        position += n;
    }
    if (position != expected_size) return error.ClientSizeMismatch;
    if (client.sha256) |expected| {
        var actual: [32]u8 = undefined;
        strong_hash.final(&actual);
        if (!std.mem.eql(u8, &actual, &expected)) return error.ClientHashMismatch;
    } else {
        var actual: [20]u8 = undefined;
        hash.final(&actual);
        if (!std.mem.eql(u8, &actual, &client.sha1.?)) return error.ClientHashMismatch;
    }
    const after = try file.stat(io);
    if (after.nlink != 1 or after.size != opened.size or after.mtime.nanoseconds != opened.mtime.nanoseconds or after.ctime.nanoseconds != opened.ctime.nanoseconds) return error.TreeChanged;
    try sameInode(before, try dir.statFile(io, name, .{ .follow_symlinks = false }));
    try sameInode(try directoryStat(io, dir), try handles.versions.statFile(io, client.id, .{ .follow_symlinks = false }));
    const held: HeldFile = .{ .file = file, .stat = opened };
    try held.recheck(io, dir, name);
    return .{ .dir = dir, .file = held };
}
const Rewritten = struct { document: []const u8, receipt: []const u8 };
fn rewriteFlattened(a: A, io: std.Io, staged: Dir, instance: config.Instance, new_name: []const u8, receipt: Receipt) !Rewritten {
    const old_json = try std.fmt.allocPrint(a, "{s}.json", .{instance.name});
    const old_jar = try std.fmt.allocPrint(a, "{s}.jar", .{instance.name});
    const new_jar = try std.fmt.allocPrint(a, "{s}.jar", .{new_name});
    const original = try readMetadata(a, io, staged, old_json);
    var version = try metadata.parseSlice(a, original);
    defer version.deinit();
    const staged_identity = (try receiptIdentity(a, io, staged, instance, version.value, original)) orelse return error.InvalidInstallReceipt;
    if (!std.mem.eql(u8, staged_identity.receipt.?.bytes, receipt.bytes)) return error.TreeChanged;
    var document = try std.json.parseFromSlice(std.json.Value, a, original, .{ .allocate = .alloc_always });
    defer document.deinit();
    const ja = document.arena.allocator();
    try document.value.object.put(ja, "id", .{ .string = new_name });
    _ = document.value.object.swapRemove("jar");
    _ = document.value.object.swapRemove("inheritsFrom");
    const bytes = try std.json.Stringify.valueAlloc(a, document.value, .{});
    var next_receipt = try parseReceipt(a, receipt.bytes);
    defer next_receipt.deinit();
    const ra = next_receipt.arena.allocator();
    try next_receipt.value.object.put(ra, "instance_name", .{ .string = new_name });
    if (next_receipt.value.object.contains("client_jar")) try next_receipt.value.object.put(ra, "client_jar", .{ .string = new_jar });
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const hex = try a.dupe(u8, &std.fmt.bytesToHex(&hash, .lower));
    try next_receipt.value.object.put(ra, "metadata_sha256", .{ .string = hex });
    const receipt_bytes = try std.json.Stringify.valueAlloc(a, next_receipt.value, .{});
    if (receipt_bytes.len > receipt_limit or bytes.len > metadata.max_document_bytes) return error.MetadataTooLarge;
    const jar_stat = try staged.statFile(io, old_jar, .{ .follow_symlinks = false });
    if (jar_stat.kind != .file) return error.UnsafeFileType;
    if (jar_stat.nlink != 1) return error.HardLinkAlias;
    try collision(io, staged, new_jar);
    try staged.renamePreserve(old_jar, staged, new_jar, io);
    try rewritePrivate(io, staged, old_json, bytes);
    try rewritePrivate(io, staged, receipt.name, receipt_bytes);
    return .{ .document = bytes, .receipt = receipt_bytes };
}
fn rewritePrivate(io: std.Io, dir: Dir, name: []const u8, bytes: []const u8) !void {
    const before = try dir.statFile(io, name, .{ .follow_symlinks = false });
    if (before.kind != .file or before.nlink != 1) return error.UnsafeFileType;
    const file = try dir.openFile(io, name, .{ .mode = .read_write, .follow_symlinks = false });
    defer file.close(io);
    const opened = try file.stat(io);
    try sameInode(before, opened);
    if (opened.nlink != 1) return error.HardLinkAlias;
    try file.writePositionalAll(io, bytes, 0);
    try file.setLength(io, bytes.len);
    try file.sync(io);
    try sameInode(before, try dir.statFile(io, name, .{ .follow_symlinks = false }));
}
fn updateExpected(entry: *tree.Entry, bytes: []const u8, total: *u64) void {
    total.* = total.* - entry.size + bytes.len;
    entry.size = bytes.len;
    std.crypto.hash.sha2.Sha256.hash(bytes, &entry.sha256, .{});
}

const TestCall = enum { inspect_installed, rename_instance, remove_instance };
const TestCheckChain = struct {
    mutation: *@import("instance_leases.zig").Mutation,
    injected: ?LeaseCheck,
    fn recheck(context: ?*anyopaque, id: []const u8) anyerror!void {
        const self: *TestCheckChain = @ptrCast(@alignCast(context.?));
        try self.mutation.recheck(id);
        if (self.injected) |injected| try injected.recheck(injected.context, id);
    }
};
fn testScopedCall(a: A, io: std.Io, root: []const u8, instance: config.Instance, new_name: ?[]const u8, options: Options, call: TestCall) !Result {
    const leases = @import("instance_leases.zig");
    var coordinator = leases.Coordinator.init(io);
    const mutation = coordinator.mutation(0);
    try mutation.acquire(instance.id);
    defer {
        mutation.release(instance.id);
        coordinator.tick();
    }
    var scoped = options;
    var chain: TestCheckChain = .{ .mutation = mutation, .injected = options.lease };
    scoped.lease = .{ .context = &chain, .recheck = TestCheckChain.recheck };
    return switch (call) {
        .inspect_installed => inspectInstalled(a, io, root, instance, scoped),
        .rename_instance => rename(a, io, root, instance, new_name.?, scoped),
        .remove_instance => remove(a, io, root, instance, scoped),
    };
}
fn testInspectInstalled(a: A, io: std.Io, root: []const u8, instance: config.Instance, options: Options) !Result {
    return testScopedCall(a, io, root, instance, null, options, .inspect_installed);
}
fn testRename(a: A, io: std.Io, root: []const u8, instance: config.Instance, new_name: []const u8, options: Options) !Result {
    return testScopedCall(a, io, root, instance, new_name, options, .rename_instance);
}
fn testRemove(a: A, io: std.Io, root: []const u8, instance: config.Instance, options: Options) !Result {
    return testScopedCall(a, io, root, instance, null, options, .remove_instance);
}

const fixture_instance: config.Instance = .{ .id = "stable-id", .name = "Play", .minecraft_version = "placeholder", .java_path = "/fixture/java", .origin = .{ .kind = .modrinth, .project_id = "project", .version_id = "release" } };
const fixture_base = "{\"id\":\"1.21\",\"mainClass\":\"net.minecraft.client.main.Main\",\"downloads\":{\"client\":{\"url\":\"https://example.invalid/client\",\"size\":4,\"sha1\":\"1405df66cbe219b0bf6355bc3d60361a8376b6b4\"}},\"arguments\":{\"game\":[],\"jvm\":[]}}";
const fixture_alias = "{\"id\":\"Play\",\"inheritsFrom\":\"1.21\"}";
fn fixture(io: std.Io, dir: Dir) !void {
    try dir.createDirPath(io, ".minecraft/versions/1.21");
    try dir.createDirPath(io, ".minecraft/versions/Play/saves/World");
    try dir.createDirPath(io, ".minecraft/versions/Play/config");
    try dir.createDirPath(io, ".minecraft/versions/Play/extraMods");
    try dir.createDirPath(io, ".minecraft/assets");
    try dir.createDirPath(io, ".minecraft/libraries");
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/1.21/1.21.json", .data = fixture_base });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/1.21/1.21.jar", .data = "base" });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/Play.json", .data = fixture_alias });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/saves/World/level.dat", .data = "world" });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/config/options.txt", .data = "config" });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/extraMods/mod.jar", .data = "mod" });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/assets/shared", .data = "asset" });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/libraries/shared", .data = "library" });
}
fn expectBytes(io: std.Io, dir: Dir, path: []const u8, expected: []const u8) !void {
    const data = try dir.readFileAlloc(io, path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings(expected, data);
}
// Fixtures undo read-only permissions solely so tmpDir.cleanup can remove them.
fn fixtureWritable(io: std.Io, dir: Dir) void {
    dir.setPermissions(io, .fromMode(0o700)) catch return;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind == .directory) {
            const child = tree.child(io, dir, entry.name, false) catch continue;
            fixtureWritable(io, child);
            child.close(io);
        }
    }
}

test "instance transaction rename preserves metadata payload shared data and recovery" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer fixtureWritable(io, tmp.dir);
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var result = try testRename(a, io, root, fixture_instance, "New Play", .{});
    defer result.deinit();
    try std.testing.expectEqual(.renamed, result.operation);
    try std.testing.expectEqualStrings("New Play", result.instance.name);
    try std.testing.expectEqualStrings("stable-id", result.instance.id);
    try std.testing.expectEqualStrings("Play", result.original_name.?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".minecraft/versions/Play", .{}));
    try expectBytes(io, tmp.dir, ".minecraft/versions/New Play/New Play.json", fixture_alias);
    try expectBytes(io, tmp.dir, ".minecraft/versions/New Play/saves/World/level.dat", "world");
    try expectBytes(io, tmp.dir, ".minecraft/versions/New Play/config/options.txt", "config");
    try expectBytes(io, tmp.dir, ".minecraft/versions/New Play/extraMods/mod.jar", "mod");
    try expectBytes(io, tmp.dir, ".minecraft/versions/1.21/1.21.json", fixture_base);
    try expectBytes(io, tmp.dir, ".minecraft/assets/shared", "asset");
    try expectBytes(io, tmp.dir, ".minecraft/libraries/shared", "library");
    const recovery = try tree.openAbsolute(io, result.recovery_directory.?);
    defer recovery.close(io);
    try expectBytes(io, recovery, "backup/Play.json", fixture_alias);
    try expectBytes(io, recovery, "original/Play.json", fixture_alias);
    const backup_stat = try recovery.statFile(io, "backup", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o500), backup_stat.permissions.toMode() & 0o777);
    const file_stat = try recovery.statFile(io, "backup/Play.json", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o400), file_stat.permissions.toMode() & 0o777);
    const manifest_bytes = try recovery.readFileAlloc(io, "manifest.json", a, .limited(1024 * 1024));
    defer a.free(manifest_bytes);
    const manifest = try std.json.parseFromSlice(Manifest, a, manifest_bytes, .{});
    defer manifest.deinit();
    try std.testing.expectEqualStrings("stable-id", manifest.value.instance_id);
    try std.testing.expectEqualStrings("Play", manifest.value.old_name);
    try std.testing.expectEqualStrings("New Play", manifest.value.new_name.?);
    try std.testing.expectEqual(.renamed, manifest.value.operation);
    var renamed_inspection = try testInspectInstalled(a, io, root, result.instance, .{});
    defer renamed_inspection.deinit();
    try std.testing.expectEqualStrings("1.21", renamed_inspection.instance.minecraft_version);
}

test "instance transaction permanently deletes only the owned instance tree" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer fixtureWritable(io, tmp.dir);
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var result = try testRemove(a, io, root, fixture_instance, .{});
    defer result.deinit();
    try std.testing.expectEqual(.deleted, result.operation);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".minecraft/versions/Play", .{}));
    try std.testing.expect(result.recovery_directory == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
    try expectBytes(io, tmp.dir, ".minecraft/assets/shared", "asset");
    try expectBytes(io, tmp.dir, ".minecraft/libraries/shared", "library");
    try expectBytes(io, tmp.dir, ".minecraft/versions/1.21/1.21.json", fixture_base);
}

test "deleted result publication rejects recreated directory file and symlink without erasing them" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Kind = enum { directory, file, symlink };
    for ([_]Kind{ .directory, .file, .symlink }) |kind| {
        if (kind == .symlink and builtin.os.tag == .windows) continue;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try fixture(io, tmp.dir);
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var result = try testRemove(a, io, root, fixture_instance, .{});
        defer result.deinit();
        try std.testing.expect(!result.local_client_verified and result.deletion_proof != null);
        try result.recheckPublication(root);
        const path = ".minecraft/versions/Play";
        switch (kind) {
            .directory => {
                try tmp.dir.createDirPath(io, path);
                try tmp.dir.writeFile(io, .{ .sub_path = path ++ "/retained", .data = "replacement" });
            },
            .file => try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "replacement" }),
            .symlink => try tmp.dir.symLink(io, "../assets/shared", path, .{}),
        }
        try std.testing.expectError(error.TreeChanged, result.recheckPublication(root));
        try std.testing.expectError(error.TreeChanged, result.recheckPublication(root));
        switch (kind) {
            .directory => try expectBytes(io, tmp.dir, path ++ "/retained", "replacement"),
            .file => try expectBytes(io, tmp.dir, path, "replacement"),
            .symlink => {
                const stat = try tmp.dir.statFile(io, path, .{ .follow_symlinks = false });
                try std.testing.expectEqual(.sym_link, stat.kind);
            },
        }
        try expectBytes(io, tmp.dir, ".minecraft/assets/shared", "asset");
        try expectBytes(io, tmp.dir, ".minecraft/libraries/shared", "library");
    }
}

test "deleted result publication rejects replacement root minecraft and versions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const u8{ "launcher", "launcher/.minecraft", "launcher/.minecraft/versions" }) |path| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        {
            const launcher = try tree.child(io, tmp.dir, "launcher", true);
            defer launcher.close(io);
            try fixture(io, launcher);
        }
        const root = try tmp.dir.realPathFileAlloc(io, "launcher", a);
        defer a.free(root);
        var result = try testRemove(a, io, root, fixture_instance, .{});
        defer result.deinit();
        try result.recheckPublication(root);
        try tmp.dir.renamePreserve(path, tmp.dir, "previous", io);
        try tmp.dir.createDirPath(io, "launcher/.minecraft/versions");
        try tmp.dir.writeFile(io, .{ .sub_path = "launcher/.minecraft/versions/retained", .data = "replacement" });
        try std.testing.expectError(error.TreeChanged, result.recheckPublication(root));
        try expectBytes(io, tmp.dir, "launcher/.minecraft/versions/retained", "replacement");
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "launcher/.minecraft/versions/Play", .{}));
    }
}

const DeletionCloseIo = struct {
    var closes: usize = 0;

    fn close(context: ?*anyopaque, dirs: []const Dir) void {
        closes += dirs.len;
        std.testing.io.vtable.dirClose(context, dirs);
    }
};

test "deleted result requires publication proof and closes retained roots exactly once" {
    const a = std.testing.allocator;
    const real_io = std.testing.io;
    var missing: Result = .{ .arena = .init(a), .operation = .deleted, .instance = fixture_instance };
    defer missing.deinit();
    try std.testing.expectError(error.InvalidCompletedPublication, missing.recheckPublication("/missing-proof"));
    for ([_]bool{ false, true }) |full_cleanup| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try fixture(real_io, tmp.dir);
        const root = try tmp.dir.realPathFileAlloc(real_io, ".", a);
        defer a.free(root);
        var vtable = real_io.vtable.*;
        vtable.dirClose = DeletionCloseIo.close;
        const io: std.Io = .{ .userdata = real_io.userdata, .vtable = &vtable };
        DeletionCloseIo.closes = 0;
        var result = try testRemove(a, io, root, fixture_instance, .{});
        var result_live = true;
        defer if (result_live) result.deinit();
        try result.recheckPublication(root);
        const before = DeletionCloseIo.closes;
        if (full_cleanup) {
            result.deinit();
            result_live = false;
        } else {
            result.releasePublicationProof();
            try std.testing.expect(result.deletion_proof == null);
            try std.testing.expectError(error.InvalidCompletedPublication, result.recheckPublication(root));
            result.releasePublicationProof();
            result.deinit();
            result_live = false;
        }
        try std.testing.expectEqual(before + 3, DeletionCloseIo.closes);
    }
}

const EraseFaultIo = struct {
    var files: usize = 0;
    var fail_file: ?usize = null;
    var fail_root: bool = false;
    var late_cancel: ?*std.atomic.Value(bool) = null;

    fn deleteFile(context: ?*anyopaque, dir: Dir, path: []const u8) Dir.DeleteFileError!void {
        files += 1;
        if (fail_file == files) return error.FileSystem;
        try std.testing.io.vtable.dirDeleteFile(context, dir, path);
        if (late_cancel) |flag| flag.store(true, .release);
    }

    fn deleteDir(context: ?*anyopaque, dir: Dir, path: []const u8) Dir.DeleteDirError!void {
        if (fail_root and std.mem.eql(u8, path, "Play")) return error.FileSystem;
        return std.testing.io.vtable.dirDeleteDir(context, dir, path);
    }

    fn wrap(vtable: *std.Io.VTable) std.Io {
        vtable.* = std.testing.io.vtable.*;
        vtable.dirDeleteFile = deleteFile;
        vtable.dirDeleteDir = deleteDir;
        return .{ .userdata = std.testing.io.userdata, .vtable = vtable };
    }

    fn reset() void {
        files = 0;
        fail_file = null;
        fail_root = false;
        late_cancel = null;
    }
};

test "permanent instance deletion stops before unlink if the source changes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var mutation: CommitFixture = .{ .dir = tmp.dir, .at = 2, .action = .change_source };
    try std.testing.expectError(error.IntegrityMismatch, testRemove(a, io, root, fixture_instance, .{ .lease = .{ .context = &mutation, .recheck = CommitFixture.recheck } }));
    try expectBytes(io, tmp.dir, ".minecraft/versions/Play/Play.json", fixture_alias);
    try expectBytes(io, tmp.dir, ".minecraft/versions/Play/saves/World/level.dat", "world");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
}

test "permanent instance deletion reports partial IO failure without removing identity or shared files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    EraseFaultIo.reset();
    defer EraseFaultIo.reset();
    EraseFaultIo.fail_file = 2;
    var vtable: std.Io.VTable = undefined;
    try std.testing.expectError(error.PermanentDeletionIncomplete, testRemove(a, EraseFaultIo.wrap(&vtable), root, fixture_instance, .{}));
    try std.testing.expectEqual(@as(usize, 2), EraseFaultIo.files);
    try expectBytes(io, tmp.dir, ".minecraft/versions/Play/Play.json", fixture_alias);
    try expectBytes(io, tmp.dir, ".minecraft/assets/shared", "asset");
    try expectBytes(io, tmp.dir, ".minecraft/libraries/shared", "library");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
}

test "permanent instance deletion never calls an empty residual root a completed deletion" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    EraseFaultIo.reset();
    defer EraseFaultIo.reset();
    EraseFaultIo.fail_root = true;
    var vtable: std.Io.VTable = undefined;
    try std.testing.expectError(error.PermanentDeletionIncomplete, testRemove(a, EraseFaultIo.wrap(&vtable), root, fixture_instance, .{}));
    const remaining = try tree.child(io, tmp.dir, ".minecraft", false);
    defer remaining.close(io);
    try tmp.dir.access(io, ".minecraft/versions/Play", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".minecraft/versions/Play/Play.json", .{}));
    try expectBytes(io, tmp.dir, ".minecraft/versions/1.21/1.21.json", fixture_base);
}

test "permanent instance deletion reports completed erasure after late cancellation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var flag = std.atomic.Value(bool).init(false);
    EraseFaultIo.reset();
    defer EraseFaultIo.reset();
    EraseFaultIo.late_cancel = &flag;
    var vtable: std.Io.VTable = undefined;
    var result = try testRemove(a, EraseFaultIo.wrap(&vtable), root, fixture_instance, .{ .cancel = &flag });
    defer result.deinit();
    try std.testing.expect(flag.load(.acquire));
    try std.testing.expectEqual(Operation.deleted, result.operation);
    try std.testing.expect(result.recovery_directory == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".minecraft/versions/Play", .{}));
}

test "permanent instance deletion can unlink readonly payload without changing unrelated data" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer fixtureWritable(io, tmp.dir);
    try fixture(io, tmp.dir);
    const payload = try tmp.dir.openFile(io, ".minecraft/versions/Play/extraMods/mod.jar", .{ .mode = .read_write });
    try payload.setPermissions(io, .fromMode(0o400));
    payload.close(io);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var result = try testRemove(a, io, root, fixture_instance, .{});
    defer result.deinit();
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".minecraft/versions/Play", .{}));
    try expectBytes(io, tmp.dir, ".minecraft/versions/1.21/1.21.json", fixture_base);
    try expectBytes(io, tmp.dir, ".minecraft/assets/shared", "asset");
}

test "instance transaction preflight rejects collision cancellation running guard and names" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.createDirPath(io, ".minecraft/versions/TAKEN");
    try std.testing.expectError(error.NameCollision, testRename(a, io, root, fixture_instance, "taken", .{}));
    try std.testing.expectError(error.SameInstanceName, testRename(a, io, root, fixture_instance, "PLAY", .{}));
    try std.testing.expectError(error.UnsafeInstance, testRename(a, io, root, fixture_instance, "../outside", .{}));
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, testRemove(a, io, root, fixture_instance, .{ .cancel = &cancel }));
    try std.testing.expectError(error.Canceled, testInspectInstalled(a, io, root, fixture_instance, .{ .cancel = &cancel }));
    try std.testing.expectError(error.InstanceRunning, testRemove(a, io, root, fixture_instance, .{ .guard = .{ .running_ids = &.{"stable-id"} } }));
    try std.testing.expectError(error.ResourceLimit, testInspectInstalled(a, io, root, fixture_instance, .{ .limits = .{ .max_files = 1 } }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
    try expectBytes(io, tmp.dir, ".minecraft/versions/Play/Play.json", fixture_alias);
}

test "instance transaction rejects symlinks hardlinks and linked root components" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.symLink(io, "../1.21/1.21.json", ".minecraft/versions/Play/link", .{});
    try std.testing.expectError(error.UnsafeFileType, testInspectInstalled(a, io, root, fixture_instance, .{}));
    try std.testing.expectError(error.UnsafeFileType, testRemove(a, io, root, fixture_instance, .{}));
    try tmp.dir.deleteFile(io, ".minecraft/versions/Play/link");
    try tmp.dir.hardLink(".minecraft/assets/shared", tmp.dir, ".minecraft/versions/Play/alias", io, .{});
    try std.testing.expectError(error.HardLinkAlias, testInspectInstalled(a, io, root, fixture_instance, .{}));
    try std.testing.expectError(error.HardLinkAlias, testRename(a, io, root, fixture_instance, "New", .{}));
    try std.testing.expectError(error.HardLinkAlias, testRemove(a, io, root, fixture_instance, .{}));
    try tmp.dir.symLink(io, ".minecraft", "linked", .{ .is_directory = true });
    const linked = try std.fs.path.join(a, &.{ root, "linked" });
    defer a.free(linked);
    if (tree.openAbsolute(io, linked)) |dir| {
        dir.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}
    try expectBytes(io, tmp.dir, ".minecraft/assets/shared", "asset");
}

test "instance transaction protects canonical versions and referenced aliases" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var canonical = fixture_instance;
    canonical.name = "1.21";
    try std.testing.expectError(error.CanonicalVersionProtected, testRemove(a, io, root, canonical, .{}));
    try tmp.dir.createDirPath(io, ".minecraft/versions/Sibling");
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Sibling/Sibling.json", .data = "{\"id\":\"Sibling\",\"inheritsFrom\":\"Play\"}" });
    try std.testing.expectError(error.CanonicalVersionProtected, testRename(a, io, root, fixture_instance, "New", .{}));
    try std.testing.expectError(error.CanonicalVersionProtected, testRemove(a, io, root, fixture_instance, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
}

test "instance transaction inspection detects Fabric and rejects unknown loader" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/Play.json", .data = "{\"id\":\"Play\",\"inheritsFrom\":\"1.21\",\"mainClass\":\"net.fabricmc.loader.impl.launch.knot.KnotClient\",\"libraries\":[{\"name\":\"net.fabricmc:fabric-loader:0.16.10\"}]}" });
    var result = try testInspectInstalled(a, io, root, fixture_instance, .{});
    defer result.deinit();
    try std.testing.expectEqual(.fabric, result.instance.loader);
    try std.testing.expectEqualStrings("0.16.10", result.instance.loader_version.?);
    try std.testing.expectEqualStrings("1.21", result.instance.minecraft_version);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/Play.json", .data = "{\"id\":\"Play\",\"inheritsFrom\":\"1.21\",\"mainClass\":\"unknown.CustomLoader\"}" });
    try std.testing.expectError(error.UnknownLoaderIdentity, testInspectInstalled(a, io, root, fixture_instance, .{}));
}

const CommitFixture = struct {
    dir: Dir,
    calls: usize = 0,
    at: usize,
    action: enum { change_source, collide, cancel },
    cancel: ?*std.atomic.Value(bool) = null,
    failure: ?anyerror = null,
    fn recheck(context: ?*anyopaque, _: []const u8) anyerror!void {
        const self: *CommitFixture = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.calls != self.at) return;
        switch (self.action) {
            .change_source => self.dir.writeFile(std.testing.io, .{ .sub_path = ".minecraft/versions/Play/config/options.txt", .data = "changed" }) catch |err| {
                self.failure = err;
            },
            .collide => self.dir.createDirPath(std.testing.io, ".minecraft/versions/New") catch |err| {
                self.failure = err;
            },
            .cancel => self.cancel.?.store(true, .release),
        }
    }
};
test "instance transaction detects changed source during backup before commit" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer fixtureWritable(io, tmp.dir);
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var mutation: CommitFixture = .{ .dir = tmp.dir, .at = 2, .action = .change_source };
    try std.testing.expectError(error.IntegrityMismatch, testRename(a, io, root, fixture_instance, "New", .{ .lease = .{ .context = &mutation, .recheck = CommitFixture.recheck } }));
    try std.testing.expect(mutation.failure == null);
    try expectBytes(io, tmp.dir, ".minecraft/versions/Play/config/options.txt", "changed");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".minecraft/versions/New", .{}));
}
test "instance transaction exclusive publish rolls original back on late collision" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer fixtureWritable(io, tmp.dir);
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var mutation: CommitFixture = .{ .dir = tmp.dir, .at = 3, .action = .collide };
    try std.testing.expectError(error.PathAlreadyExists, testRename(a, io, root, fixture_instance, "New", .{ .lease = .{ .context = &mutation, .recheck = CommitFixture.recheck } }));
    try std.testing.expect(mutation.failure == null);
    try expectBytes(io, tmp.dir, ".minecraft/versions/Play/Play.json", fixture_alias);
    try tmp.dir.access(io, ".minecraft/versions/New", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".minecraft/versions/New/New.json", .{}));
}
test "instance transaction final cancellation preserves original tree" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer fixtureWritable(io, tmp.dir);
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var cancel = std.atomic.Value(bool).init(false);
    var mutation: CommitFixture = .{ .dir = tmp.dir, .at = 3, .action = .cancel, .cancel = &cancel };
    try std.testing.expectError(error.Canceled, testRemove(a, io, root, fixture_instance, .{ .cancel = &cancel, .lease = .{ .context = &mutation, .recheck = CommitFixture.recheck } }));
    try expectBytes(io, tmp.dir, ".minecraft/versions/Play/saves/World/level.dat", "world");
}
fn allocationFixture(a: A, operation: Operation) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer fixtureWritable(io, tmp.dir);
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var result = (switch (operation) {
        .inspected => testInspectInstalled(a, io, root, fixture_instance, .{}),
        .renamed => testRename(a, io, root, fixture_instance, "New", .{}),
        .deleted => testRemove(a, io, root, fixture_instance, .{}),
    }) catch |err| {
        try expectBytes(io, tmp.dir, ".minecraft/versions/Play/Play.json", fixture_alias);
        return err;
    };
    defer result.deinit();
}
test "instance transaction allocation failures leave source and release owned memory" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{Operation.inspected});
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{Operation.renamed});
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{Operation.deleted});
}
const RenameFault = enum { first_before, first_after, publish_after, rollback_before };
var rename_fault: ?RenameFault = null;
fn faultRename(userdata: ?*anyopaque, old_dir: Dir, old_name: []const u8, new_dir: Dir, new_name: []const u8) Dir.RenamePreserveError!void {
    const fault = rename_fault.?;
    if (std.mem.eql(u8, new_name, "original") and fault == .first_before) return error.OperationUnsupported;
    if (std.mem.eql(u8, old_name, "staged") and fault == .rollback_before) return error.PathAlreadyExists;
    if (std.mem.eql(u8, old_name, "original") and fault == .rollback_before) return error.Unexpected;
    try std.testing.io.vtable.dirRenamePreserve(userdata, old_dir, old_name, new_dir, new_name);
    if ((std.mem.eql(u8, new_name, "original") and fault == .first_after) or
        (std.mem.eql(u8, old_name, "staged") and fault == .publish_after)) return error.Unexpected;
}
test "instance transaction uncertain syscall outcomes and failed rollback require recovery" {
    const a = std.testing.allocator;
    const real_io = std.testing.io;
    for ([_]RenameFault{ .first_before, .first_after, .publish_after, .rollback_before }) |fault| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        defer fixtureWritable(real_io, tmp.dir);
        try fixture(real_io, tmp.dir);
        const root = try tmp.dir.realPathFileAlloc(real_io, ".", a);
        defer a.free(root);
        var vtable = real_io.vtable.*;
        vtable.dirRenamePreserve = faultRename;
        const io: std.Io = .{ .userdata = real_io.userdata, .vtable = &vtable };
        rename_fault = fault;
        defer rename_fault = null;
        if (fault == .first_before) {
            try std.testing.expectError(error.OperationUnsupported, testRename(a, io, root, fixture_instance, "New", .{}));
            try expectBytes(real_io, tmp.dir, ".minecraft/versions/Play/Play.json", fixture_alias);
            continue;
        }
        try std.testing.expectError(error.RecoveryRequired, testRename(a, io, root, fixture_instance, "New", .{}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(real_io, ".minecraft/versions/Play", .{}));
        const vela = try tmp.dir.openDir(real_io, ".vela", .{ .iterate = true });
        defer vela.close(real_io);
        var entries = vela.iterate();
        const entry = (try entries.next(real_io)).?;
        const recovery = try vela.openDir(real_io, entry.name, .{ .iterate = true });
        defer recovery.close(real_io);
        try expectBytes(real_io, recovery, "original/Play.json", fixture_alias);
        try expectBytes(real_io, recovery, "backup/Play.json", fixture_alias);
        if (fault == .publish_after) {
            try expectBytes(real_io, tmp.dir, ".minecraft/versions/New/New.json", fixture_alias);
        } else {
            try std.testing.expectError(error.FileNotFound, tmp.dir.access(real_io, ".minecraft/versions/New", .{}));
        }
    }
}
const fixture_private_jar = "processed-client";
fn flattenedFixture(io: std.Io, dir: Dir, kind: config.Loader) !void {
    const a = std.testing.allocator;
    try fixture(io, dir);
    const coordinate: []const u8 = switch (kind) {
        .vanilla => "",
        .fabric => "net.fabricmc:fabric-loader:0.16.9",
        .quilt => "org.quiltmc:quilt-loader:0.27.1",
        .forge => "net.minecraftforge:forge:1.21-47.3.0",
        .neoforge => "net.neoforged:neoforge:21.1.1",
    };
    const version: ?[]const u8 = switch (kind) {
        .vanilla => null,
        .fabric => "0.16.9",
        .quilt => "0.27.1",
        .forge => "47.3.0",
        .neoforge => "21.1.1",
    };
    const libraries = [_]struct { name: []const u8 }{.{ .name = coordinate }};
    const document = try std.json.Stringify.valueAlloc(a, .{
        .id = "Play",
        .mainClass = if (kind == .vanilla) "net.minecraft.client.main.Main" else "cpw.mods.bootstraplauncher.BootstrapLauncher",
        .downloads = .{ .client = .{ .url = "https://example.invalid/base-client", .sha1 = "0000000000000000000000000000000000000000", .size = 4 } },
        .libraries = libraries[0..@as(usize, if (kind == .vanilla) 0 else 1)],
        .arguments = .{ .game = [_][]const u8{}, .jvm = [_][]const u8{} },
        .custom_data = .{ .keep = true, .number = 7 },
    }, .{});
    defer a.free(document);
    var metadata_hash: [32]u8 = undefined;
    var client_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(document, &metadata_hash, .{});
    std.crypto.hash.sha2.Sha256.hash(fixture_private_jar, &client_hash, .{});
    const receipt = try std.json.Stringify.valueAlloc(a, .{
        .schema_version = 1,
        .instance_id = "previous-id",
        .instance_name = "Play",
        .minecraft_version = "1.21",
        .loader = @tagName(kind),
        .loader_version = version,
        .metadata_sha256 = &std.fmt.bytesToHex(&metadata_hash, .lower),
        .client_sha256 = &std.fmt.bytesToHex(&client_hash, .lower),
        .client_size = fixture_private_jar.len,
        .source_url = "https://example.invalid/loader",
        .source_sha1 = "1111111111111111111111111111111111111111",
        .profile_sha1 = "2222222222222222222222222222222222222222",
        .audit_extra = "preserve-me",
    }, .{});
    defer a.free(receipt);
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/Play.json", .data = document });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/Play.jar", .data = fixture_private_jar });
    try dir.writeFile(io, .{ .sub_path = if (kind == .vanilla) ".minecraft/versions/Play/.vela-instance.json" else ".minecraft/versions/Play/.vela-loader.json", .data = receipt });
}
fn expectFlattenedRename(kind: config.Loader) !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer fixtureWritable(io, tmp.dir);
    try flattenedFixture(io, tmp.dir, kind);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const original = try tmp.dir.readFileAlloc(io, ".minecraft/versions/Play/Play.json", a, .limited(1024 * 1024));
    defer a.free(original);
    var inspected = try testInspectInstalled(a, io, root, fixture_instance, .{});
    defer inspected.deinit();
    try std.testing.expectEqualStrings("1.21", inspected.instance.minecraft_version);
    try std.testing.expectEqualStrings("stable-id", inspected.instance.id);
    try std.testing.expectEqual(kind, inspected.instance.loader);
    var installed = try testInspectInstalled(a, io, root, fixture_instance, .{});
    defer installed.deinit();
    try std.testing.expectEqualStrings("1.21", installed.instance.minecraft_version);
    var renamed = try testRename(a, io, root, inspected.instance, "New", .{});
    defer renamed.deinit();
    try std.testing.expectEqualStrings("New", renamed.instance.name);
    try std.testing.expectEqualStrings("1.21", renamed.instance.minecraft_version);
    const recovery = try tree.openAbsolute(io, renamed.recovery_directory.?);
    defer recovery.close(io);
    try expectBytes(io, recovery, "backup/Play.json", original);
    try expectBytes(io, recovery, "original/Play.json", original);
    try expectBytes(io, recovery, "backup/Play.jar", fixture_private_jar);
    try expectBytes(io, tmp.dir, ".minecraft/versions/New/New.jar", fixture_private_jar);
    try expectBytes(io, tmp.dir, ".minecraft/versions/New/saves/World/level.dat", "world");
    try expectBytes(io, tmp.dir, ".minecraft/versions/New/config/options.txt", "config");
    try expectBytes(io, tmp.dir, ".minecraft/versions/New/extraMods/mod.jar", "mod");
    try expectBytes(io, tmp.dir, ".minecraft/versions/1.21/1.21.json", fixture_base);
    try expectBytes(io, tmp.dir, ".minecraft/assets/shared", "asset");
    try expectBytes(io, tmp.dir, ".minecraft/libraries/shared", "library");
    const next = try tmp.dir.readFileAlloc(io, ".minecraft/versions/New/New.json", a, .limited(1024 * 1024));
    defer a.free(next);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, next, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("New", parsed.value.object.get("id").?.string);
    try std.testing.expect(!parsed.value.object.contains("jar"));
    try std.testing.expect(!parsed.value.object.contains("inheritsFrom"));
    try std.testing.expect(parsed.value.object.get("custom_data").?.object.get("keep").?.bool);
    const receipt_path = if (kind == .vanilla) ".minecraft/versions/New/.vela-instance.json" else ".minecraft/versions/New/.vela-loader.json";
    const receipt_bytes = try tmp.dir.readFileAlloc(io, receipt_path, a, .limited(receipt_limit));
    defer a.free(receipt_bytes);
    var receipt = try std.json.parseFromSlice(std.json.Value, a, receipt_bytes, .{});
    defer receipt.deinit();
    try std.testing.expectEqualStrings("New", receipt.value.object.get("instance_name").?.string);
    try std.testing.expectEqualStrings("previous-id", receipt.value.object.get("instance_id").?.string);
    try std.testing.expectEqualStrings("preserve-me", receipt.value.object.get("audit_extra").?.string);
    var reinspected = try testInspectInstalled(a, io, root, renamed.instance, .{});
    defer reinspected.deinit();
    try std.testing.expectEqualStrings("1.21", reinspected.instance.minecraft_version);
    try std.testing.expectEqual(kind, reinspected.instance.loader);
    if (kind == .forge) try std.testing.expectEqualStrings("47.3.0", reinspected.instance.loader_version.?);
    var ready = try testInspectInstalled(a, io, root, renamed.instance, .{});
    defer ready.deinit();
    const minecraft = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft);
    var loaded = try loader.load(a, io, .{ .root = minecraft, .version_id = "New" }, .{});
    defer loaded.deinit();
    try std.testing.expectEqualStrings("New", loaded.version.value.jar orelse loaded.version.value.id);
    var deleted = try testRemove(a, io, root, renamed.instance, .{});
    defer deleted.deinit();
    try std.testing.expect(deleted.recovery_directory == null);
    // Renaming retains its original recovery copy; deleting creates no new one.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".minecraft/versions/New/New.jar", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".minecraft/versions/New", .{}));
    try expectBytes(io, tmp.dir, ".minecraft/versions/1.21/1.21.json", fixture_base);
}
test "instance transaction flattened vanilla receipts prove identity rename and permanent delete" {
    try expectFlattenedRename(.vanilla);
}
test "instance transaction flattened loader receipts preserve actual base and processor client bindings" {
    for ([_]config.Loader{ .fabric, .quilt, .forge, .neoforge }) |kind| try expectFlattenedRename(kind);
}
test "instance transaction rejects missing malformed mismatched and unbound managed receipts" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Case = enum { missing, schema, name, id, base, kind, loader_version, metadata_hash, client_hash, client_size, no_metadata_hash, no_client_hash, no_client_size, duplicate, too_large, linked, hardlinked };
    inline for (std.meta.tags(Case)) |case| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try flattenedFixture(io, tmp.dir, .vanilla);
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        const path = ".minecraft/versions/Play/.vela-instance.json";
        const bytes = try tmp.dir.readFileAlloc(io, path, a, .limited(receipt_limit));
        defer a.free(bytes);
        var receipt = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer receipt.deinit();
        const ra = receipt.arena.allocator();
        switch (case) {
            .schema => try receipt.value.object.put(ra, "schema_version", .{ .integer = 2 }),
            .name => try receipt.value.object.put(ra, "instance_name", .{ .string = "Other" }),
            .id => try receipt.value.object.put(ra, "instance_id", .{ .string = "../bad" }),
            .base => try receipt.value.object.put(ra, "minecraft_version", .{ .string = "../bad" }),
            .kind => try receipt.value.object.put(ra, "loader", .{ .string = "fabric" }),
            .loader_version => try receipt.value.object.put(ra, "loader_version", .{ .string = "wrong" }),
            .metadata_hash => try receipt.value.object.put(ra, "metadata_sha256", .{ .string = "0000000000000000000000000000000000000000000000000000000000000000" }),
            .client_hash => try receipt.value.object.put(ra, "client_sha256", .{ .string = "not-a-hash" }),
            .client_size => try receipt.value.object.put(ra, "client_size", .{ .integer = -1 }),
            .no_metadata_hash => _ = receipt.value.object.swapRemove("metadata_sha256"),
            .no_client_hash => _ = receipt.value.object.swapRemove("client_sha256"),
            .no_client_size => _ = receipt.value.object.swapRemove("client_size"),
            else => {},
        }
        const changed = try std.json.Stringify.valueAlloc(a, receipt.value, .{});
        defer a.free(changed);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = changed });
        switch (case) {
            .missing => try tmp.dir.deleteFile(io, path),
            .duplicate => try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/.vela-loader.json", .data = bytes }),
            .too_large => {
                const oversized = try a.alloc(u8, receipt_limit + 1);
                defer a.free(oversized);
                @memset(oversized, ' ');
                try tmp.dir.writeFile(io, .{ .sub_path = path, .data = oversized });
            },
            .linked => {
                try tmp.dir.deleteFile(io, path);
                try tmp.dir.symLink(io, "../1.21/1.21.json", path, .{});
            },
            .hardlinked => try tmp.dir.hardLink(path, tmp.dir, "receipt-alias", io, .{}),
            else => {},
        }
        const expected = switch (case) {
            .missing => error.MissingInstallReceipt,
            .metadata_hash => error.InstallReceiptMismatch,
            .too_large => error.MetadataTooLarge,
            .linked => error.UnsafeFileType,
            .hardlinked => error.HardLinkAlias,
            else => error.InvalidInstallReceipt,
        };
        try std.testing.expectError(expected, testInspectInstalled(a, io, root, fixture_instance, .{}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
    }
}
test "instance transaction installed managed client validation rejects corrupt absent linked and aliased jars" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Case = enum { hash, size, missing, linked, hardlinked };
    inline for (std.meta.tags(Case)) |case| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try flattenedFixture(io, tmp.dir, .forge);
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        const path = ".minecraft/versions/Play/Play.jar";
        switch (case) {
            .hash => try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "corrupted-client" }),
            .size => try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "short" }),
            .missing => try tmp.dir.deleteFile(io, path),
            .linked => {
                try tmp.dir.deleteFile(io, path);
                try tmp.dir.symLink(io, "../../assets/shared", path, .{});
            },
            .hardlinked => try tmp.dir.hardLink(path, tmp.dir, "jar-alias", io, .{}),
        }
        const expected = switch (case) {
            .hash => error.ClientHashMismatch,
            .size => error.ClientSizeMismatch,
            .missing => error.FileNotFound,
            .linked => error.UnsafeFileType,
            .hardlinked => error.HardLinkAlias,
        };
        try std.testing.expectError(expected, testInspectInstalled(a, io, root, fixture_instance, .{}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
    }
}
test "instance transaction installed inherited client validation uses resolved canonical jar and SHA1" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const missing_hash = try std.json.Stringify.valueAlloc(a, .{ .id = "1.21", .mainClass = "net.minecraft.client.main.Main", .downloads = .{ .client = .{ .url = "https://example.invalid/base", .size = 4 } } }, .{});
    defer a.free(missing_hash);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/1.21/1.21.json", .data = missing_hash });
    try std.testing.expectError(error.MissingClientHash, testInspectInstalled(a, io, root, fixture_instance, .{}));
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("base", &hash, .{});
    const doc = try std.json.Stringify.valueAlloc(a, .{ .id = "1.21", .mainClass = "net.minecraft.client.main.Main", .downloads = .{ .client = .{ .url = "https://example.invalid/base", .sha1 = &std.fmt.bytesToHex(&hash, .lower), .size = 4 } } }, .{});
    defer a.free(doc);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/1.21/1.21.json", .data = doc });
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/1.21/1.21.jar", .data = "base" });
    var proof = try testInspectInstalled(a, io, root, fixture_instance, .{});
    defer proof.deinit();
    try std.testing.expectEqualStrings("1.21", proof.instance.minecraft_version);
    try std.testing.expectEqual(config.Loader.vanilla, proof.instance.loader);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/1.21/1.21.jar", .data = "evil" });
    try std.testing.expectError(error.ClientHashMismatch, testInspectInstalled(a, io, root, fixture_instance, .{}));
    try tmp.dir.deleteFile(io, ".minecraft/versions/1.21/1.21.jar");
    try tmp.dir.symLink(io, "../../assets/shared", ".minecraft/versions/1.21/1.21.jar", .{});
    try std.testing.expectError(error.UnsafeFileType, testInspectInstalled(a, io, root, fixture_instance, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
}
fn managedAllocationFixture(a: A, rename_it: bool) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer fixtureWritable(io, tmp.dir);
    try flattenedFixture(io, tmp.dir, .vanilla);
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const original = try tmp.dir.readFileAlloc(io, ".minecraft/versions/Play/Play.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(original);
    var result = (if (rename_it) testRename(a, io, root, fixture_instance, "New", .{}) else testInspectInstalled(a, io, root, fixture_instance, .{})) catch |err| {
        try expectBytes(io, tmp.dir, ".minecraft/versions/Play/Play.json", original);
        try expectBytes(io, tmp.dir, ".minecraft/versions/Play/Play.jar", fixture_private_jar);
        return err;
    };
    defer result.deinit();
}
test "instance transaction inherited base identity is independent of explicit canonical client source" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.createDirPath(io, ".minecraft/versions/JarSource");
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/Play/Play.json", .data = "{\"id\":\"Play\",\"inheritsFrom\":\"1.21\",\"jar\":\"JarSource\"}" });
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("real", &hash, .{});
    const document = try std.json.Stringify.valueAlloc(a, .{ .id = "JarSource", .downloads = .{ .client = .{ .url = "https://example.invalid/real-client", .sha1 = &std.fmt.bytesToHex(&hash, .lower), .size = 4 } } }, .{});
    defer a.free(document);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/JarSource/JarSource.json", .data = document });
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/JarSource/JarSource.jar", .data = "real" });
    var proof = try testInspectInstalled(a, io, root, fixture_instance, .{});
    defer proof.deinit();
    try std.testing.expectEqualStrings("1.21", proof.instance.minecraft_version);
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/JarSource/JarSource.jar", .data = "evil" });
    try std.testing.expectError(error.ClientHashMismatch, testInspectInstalled(a, io, root, fixture_instance, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
}
test "instance transaction managed loader receipt cannot contradict descriptor version or metadata binding" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |change_hash| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try flattenedFixture(io, tmp.dir, .forge);
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        const path = ".minecraft/versions/Play/.vela-loader.json";
        const bytes = try tmp.dir.readFileAlloc(io, path, a, .limited(receipt_limit));
        defer a.free(bytes);
        var receipt = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer receipt.deinit();
        try receipt.value.object.put(receipt.arena.allocator(), if (change_hash) "metadata_sha256" else "loader_version", .{ .string = if (change_hash) "0000000000000000000000000000000000000000000000000000000000000000" else "47.9.0" });
        const changed = try std.json.Stringify.valueAlloc(a, receipt.value, .{});
        defer a.free(changed);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = changed });
        try std.testing.expectError(error.InstallReceiptMismatch, testInspectInstalled(a, io, root, fixture_instance, .{}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
    }
}
test "instance transaction managed receipt parser inspection and rewrite allocation failures preserve source" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, managedAllocationFixture, .{false});
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, managedAllocationFixture, .{true});
}

const LeaseProbe = struct {
    checks: usize = 0,
    reads: usize = 0,
    fail_at: usize = 0,
    read_gate_mismatch: bool = false,
    recheck_gate_mismatch: bool = false,
    wrong_id: bool = false,

    fn recheck(context: ?*anyopaque, id: []const u8) anyerror!void {
        const self: *LeaseProbe = @ptrCast(@alignCast(context.?));
        self.checks += 1;
        self.wrong_id = self.wrong_id or !std.mem.eql(u8, id, fixture_instance.id);
        if (worlds.transaction_gate.tryLock()) {
            worlds.transaction_gate.unlock(std.testing.io);
        } else self.recheck_gate_mismatch = true;
        if (self.checks == self.fail_at) return error.LeaseUnavailable;
    }
};
var lease_read_probe: ?*LeaseProbe = null;
fn probeLeaseRead(userdata: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
    const probe = lease_read_probe.?;
    probe.reads += 1;
    const available = worlds.transaction_gate.tryLock();
    if (available) worlds.transaction_gate.unlock(std.testing.io);
    if (!available) probe.read_gate_mismatch = true;
    return std.testing.io.vtable.fileReadPositional(userdata, file, data, offset);
}

test "instance transaction leased installed inspection reads outside gate and rechecks held lease" {
    const a = std.testing.allocator;
    const real_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try flattenedFixture(real_io, tmp.dir, .vanilla);
    const root = try tmp.dir.realPathFileAlloc(real_io, ".", a);
    defer a.free(root);
    const bytes: [3 * 64 * 1024]u8 = @splat(0x5a);
    try tmp.dir.writeFile(real_io, .{ .sub_path = ".minecraft/versions/Play/Play.jar", .data = &bytes });
    var client_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &client_hash, .{});
    const hash_text = std.fmt.bytesToHex(&client_hash, .lower);
    const path = ".minecraft/versions/Play/.vela-instance.json";
    const receipt_bytes = try tmp.dir.readFileAlloc(real_io, path, a, .limited(receipt_limit));
    defer a.free(receipt_bytes);
    var receipt = try std.json.parseFromSlice(std.json.Value, a, receipt_bytes, .{});
    defer receipt.deinit();
    try receipt.value.object.put(receipt.arena.allocator(), "client_sha256", .{ .string = &hash_text });
    try receipt.value.object.put(receipt.arena.allocator(), "client_size", .{ .integer = bytes.len });
    const updated = try std.json.Stringify.valueAlloc(a, receipt.value, .{});
    defer a.free(updated);
    try tmp.dir.writeFile(real_io, .{ .sub_path = path, .data = updated });
    var probe: LeaseProbe = .{};
    lease_read_probe = &probe;
    defer lease_read_probe = null;
    var vtable = real_io.vtable.*;
    vtable.fileReadPositional = probeLeaseRead;
    const io: std.Io = .{ .userdata = real_io.userdata, .vtable = &vtable };
    var result = try inspectInstalledLeased(a, io, root, fixture_instance, .{}, .{ .context = &probe, .recheck = LeaseProbe.recheck });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), probe.checks);
    try std.testing.expect(probe.reads > 3);
    try std.testing.expect(!probe.read_gate_mismatch and !probe.recheck_gate_mismatch and !probe.wrong_id);
    try std.testing.expectEqualStrings("1.21", result.instance.minecraft_version);
    probe = .{};
    try std.testing.expectError(error.MissingStableScope, inspectInstalled(a, io, root, fixture_instance, .{}));
    try std.testing.expectEqual(@as(usize, 0), probe.reads);
    try std.testing.expectEqual(@as(usize, 0), probe.checks);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(real_io, ".vela", .{}));
}

test "instance transaction leased installed inspection rejects blocked and lost lease without writes" {
    const a = std.testing.allocator;
    const real_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try flattenedFixture(real_io, tmp.dir, .fabric);
    const root = try tmp.dir.realPathFileAlloc(real_io, ".", a);
    defer a.free(root);
    var probe: LeaseProbe = .{};
    lease_read_probe = &probe;
    defer lease_read_probe = null;
    var vtable = real_io.vtable.*;
    vtable.fileReadPositional = probeLeaseRead;
    const io: std.Io = .{ .userdata = real_io.userdata, .vtable = &vtable };
    for ([_]usize{ 1, 2 }) |fail_at| {
        probe = .{ .fail_at = fail_at };
        try std.testing.expectError(error.LeaseUnavailable, inspectInstalledLeased(a, io, root, fixture_instance, .{}, .{ .context = &probe, .recheck = LeaseProbe.recheck }));
        try std.testing.expectEqual(fail_at, probe.checks);
        try std.testing.expect(if (fail_at == 1) probe.reads == 0 else probe.reads > 0);
        try std.testing.expect(!probe.read_gate_mismatch and !probe.recheck_gate_mismatch and !probe.wrong_id);
        try std.testing.expect(worlds.transaction_gate.tryLock());
        worlds.transaction_gate.unlock(real_io);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(real_io, ".vela", .{}));
    }
    probe = .{};
    try std.testing.expectError(error.InstanceRunning, inspectInstalledLeased(a, io, root, fixture_instance, .{ .guard = .{ .running_ids = &.{fixture_instance.id} } }, .{ .context = &probe, .recheck = LeaseProbe.recheck }));
    try std.testing.expectEqual(@as(usize, 1), probe.checks);
    try std.testing.expectEqual(@as(usize, 0), probe.reads);
    probe = .{};
    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Canceled, inspectInstalledLeased(a, io, root, fixture_instance, .{ .cancel = &cancel }, .{ .context = &probe, .recheck = LeaseProbe.recheck }));
    try std.testing.expectEqual(@as(usize, 1), probe.checks);
    try std.testing.expectEqual(@as(usize, 0), probe.reads);
}

test "instance transaction leased installed inspection interoperates with real Coordinator Mutation" {
    const leases = @import("instance_leases.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try flattenedFixture(io, tmp.dir, .fabric);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var coordinator = leases.Coordinator.init(io);
    const mutation = coordinator.mutation(0);
    const competing = coordinator.mutation(1);
    try mutation.acquire(fixture_instance.id);
    defer {
        mutation.release(fixture_instance.id);
        coordinator.tick();
    }
    const callback: LeaseCheck = .{ .context = mutation, .recheck = leases.Mutation.recheckCallback };
    var result = try inspectInstalledLeased(a, io, root, fixture_instance, .{}, callback);
    defer result.deinit();
    try std.testing.expectEqualStrings("1.21", result.instance.minecraft_version);
    try std.testing.expectEqual(config.Loader.fabric, result.instance.loader);
    try mutation.recheck(fixture_instance.id);
    try std.testing.expectError(error.InstanceBusy, competing.acquire(fixture_instance.id));
    try std.testing.expectError(error.InstanceBusy, coordinator.reserveLaunch(fixture_instance.id));
    mutation.release(fixture_instance.id);
    coordinator.tick();
    try std.testing.expectError(error.LeaseNotHeld, inspectInstalledLeased(a, io, root, fixture_instance, .{}, callback));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
}

fn artifactReceiptFixture(a: A, io: std.Io, dir: Dir, count: usize) !void {
    try flattenedFixture(io, dir, .forge);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const path = ".minecraft/versions/Play/.vela-loader.json";
    const source = try dir.readFileAlloc(io, path, ar, .limited(receipt_limit));
    var receipt = try std.json.parseFromSlice(std.json.Value, ar, source, .{});
    defer receipt.deinit();
    const entries = try ar.alloc(ReceiptArtifact, count);
    for (entries, 0..) |*entry, index| entry.* = .{
        .path = try std.fmt.allocPrint(ar, "libraries/org/example/item-{d}/item-{d}.jar", .{ index, index }),
        .sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .size = index,
    };
    const bindings = try std.json.Stringify.valueAlloc(ar, entries, .{});
    var parsed_bindings = try std.json.parseFromSlice(std.json.Value, ar, bindings, .{});
    defer parsed_bindings.deinit();
    try receipt.value.object.put(receipt.arena.allocator(), "artifact_bindings", parsed_bindings.value);
    try receipt.value.object.put(receipt.arena.allocator(), "client_jar", .{ .string = "Play.jar" });
    try receipt.value.object.put(receipt.arena.allocator(), "future", .{ .string = "artifact_bindings" });
    const bytes = try std.json.Stringify.valueAlloc(ar, receipt.value, .{});
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

test "instance transaction accepts producer 4096 artifact receipt and preserves bindings on rename" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    defer fixtureWritable(io, tmp.dir);
    try artifactReceiptFixture(a, io, tmp.dir, 4096);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const old_path = ".minecraft/versions/Play/.vela-loader.json";
    const old_bytes = try tmp.dir.readFileAlloc(io, old_path, a, .limited(receipt_limit));
    defer a.free(old_bytes);
    try std.testing.expect(old_bytes.len > 64 * 1024 and old_bytes.len < receipt_limit);
    var inspected = try testInspectInstalled(a, io, root, fixture_instance, .{});
    defer inspected.deinit();
    var moved = try testRename(a, io, root, inspected.instance, "New", .{});
    defer moved.deinit();
    var proof = try testInspectInstalled(a, io, root, moved.instance, .{});
    defer proof.deinit();
    const changed = try tmp.dir.readFileAlloc(io, ".minecraft/versions/New/.vela-loader.json", a, .limited(receipt_limit));
    defer a.free(changed);
    var parsed = try parseReceipt(a, changed);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("New.jar", try fieldText(parsed.value.object, "client_jar"));
    try std.testing.expectEqualStrings("artifact_bindings", try fieldText(parsed.value.object, "future"));
    const artifacts = parsed.value.object.get("artifact_bindings").?.array.items;
    try std.testing.expectEqual(@as(usize, 4096), artifacts.len);
    try std.testing.expectEqualStrings("libraries/org/example/item-4095/item-4095.jar", try fieldText(artifacts[4095].object, "path"));
    const original_path = try std.fmt.allocPrint(a, "{s}/backup/.vela-loader.json", .{moved.recovery_directory.?});
    defer a.free(original_path);
    const recovered = try Dir.cwd().readFileAlloc(io, original_path, a, .limited(receipt_limit));
    defer a.free(recovered);
    try std.testing.expectEqualStrings(old_bytes, recovered);
}

test "instance transaction receipt preflight bounds bytes depth tokens strings and binding count" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = ".minecraft/versions/Play/.vela-loader.json";
    try artifactReceiptFixture(a, io, tmp.dir, 4097);
    try std.testing.expectError(error.ResourceLimit, testInspectInstalled(a, io, root, fixture_instance, .{}));
    const too_deep = "{\"unknown\":[[[[[[[[0]]]]]]]]}";
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = too_deep });
    try std.testing.expectError(error.ResourceLimit, testInspectInstalled(a, io, root, fixture_instance, .{}));
    const many = try a.alloc(u8, 2 * 65536 + 10);
    defer a.free(many);
    @memcpy(many[0..6], "{\"x\":[");
    for (0..65536) |index| @memcpy(many[6 + index * 2 ..][0..2], "0,");
    @memcpy(many[6 + 2 * 65536 ..], "0]} ");
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = many });
    try std.testing.expectError(error.ResourceLimit, testInspectInstalled(a, io, root, fixture_instance, .{}));
    try artifactReceiptFixture(a, io, tmp.dir, 0);
    const original = try tmp.dir.readFileAlloc(io, path, a, .limited(receipt_limit));
    defer a.free(original);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, original, .{});
    defer parsed.deinit();
    const long_string: [4097]u8 = @splat('a');
    for ([_]usize{ 4096, 4097 }) |length| {
        try parsed.value.object.put(parsed.arena.allocator(), "unknown", .{ .string = long_string[0..length] });
        const changed = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
        defer a.free(changed);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = changed });
        if (length == 4096) {
            var result = try testInspectInstalled(a, io, root, fixture_instance, .{});
            result.deinit();
        } else try std.testing.expectError(error.ResourceLimit, testInspectInstalled(a, io, root, fixture_instance, .{}));
    }
    const padded = try a.alloc(u8, receipt_limit + 1);
    defer a.free(padded);
    @memset(padded, ' ');
    @memcpy(padded[0..original.len], original);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = padded[0..receipt_limit] });
    var accepted = try testInspectInstalled(a, io, root, fixture_instance, .{});
    accepted.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = padded });
    try std.testing.expectError(error.MetadataTooLarge, testInspectInstalled(a, io, root, fixture_instance, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
}

test "instance transaction receipt artifacts reject aliases nonflat shapes unsafe paths and hashes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = ".minecraft/versions/Play/.vela-loader.json";
    for (0..8) |mode| {
        try artifactReceiptFixture(a, io, tmp.dir, 2);
        const bytes = try tmp.dir.readFileAlloc(io, path, a, .limited(receipt_limit));
        defer a.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer parsed.deinit();
        const ar = parsed.arena.allocator();
        const entries = parsed.value.object.getPtr("artifact_bindings").?.array.items;
        switch (mode) {
            0 => try entries[1].object.put(ar, "path", .{ .string = "libraries/org/example/item-0/item-0.jar" }),
            1 => try entries[1].object.put(ar, "path", .{ .string = "libraries/org/example/ITEM-0/ITEM-0.jar" }),
            2 => try entries[0].object.put(ar, "path", .{ .string = "libraries/../outside.jar" }),
            3 => try entries[0].object.put(ar, "sha256", .{ .string = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }),
            4 => try entries[0].object.put(ar, "size", .{ .integer = -1 }),
            5 => try entries[0].object.put(ar, "extra", .null),
            6 => try entries[0].object.put(ar, "path", .{ .array = std.json.Array.init(ar) }),
            7 => try parsed.value.object.put(ar, "client_jar", .{ .string = "Other.jar" }),
            else => unreachable,
        }
        const changed = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
        defer a.free(changed);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = changed });
        if (mode < 2) try std.testing.expectError(error.DuplicateArtifactPath, testInspectInstalled(a, io, root, fixture_instance, .{})) else try std.testing.expectError(error.InvalidInstallReceipt, testInspectInstalled(a, io, root, fixture_instance, .{}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
    }
}

fn artifactAllocationFixture(a: A) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try artifactReceiptFixture(std.testing.allocator, io, tmp.dir, 2);
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var result = try testInspectInstalled(a, io, root, fixture_instance, .{});
    defer result.deinit();
}

fn canonicalFixtureBytes(a: A) ![]u8 {
    var client_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("base", &client_hash, .{});
    return std.json.Stringify.valueAlloc(a, .{ .id = "26.3", .mainClass = "net.minecraft.client.main.Main", .javaVersion = .{ .component = "java-runtime-delta", .majorVersion = 25 }, .downloads = .{ .client = .{ .url = "https://piston-data.mojang.com/v1/objects/fixture/client.jar", .sha1 = &std.fmt.bytesToHex(&client_hash, .lower), .size = 4 } } }, .{});
}
fn canonicalFixture(io: std.Io, dir: Dir) !void {
    const a = std.testing.allocator;
    const bytes = try canonicalFixtureBytes(a);
    defer a.free(bytes);
    try dir.createDirPath(io, ".minecraft/versions/26.3/mods");
    try dir.createDirPath(io, ".minecraft/versions/26.3/saves/world");
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/26.3.json", .data = bytes });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/26.3.jar", .data = "base" });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/mods/keep.jar", .data = "mod" });
    try dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/saves/world/level.dat", .data = "world" });
}
fn canonicalPreparation(a: A, io: std.Io, root: []const u8, cancel: ?*const std.atomic.Value(bool)) !loader.PreparedVanilla {
    const bytes = try canonicalFixtureBytes(a);
    defer a.free(bytes);
    var metadata_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &metadata_hash, .{});
    const entries = [_]@import("minecraft/metadata/root.zig").manifest.Entry{.{ .id = "26.3", .kind = "release", .url = "https://piston-meta.mojang.com/v1/packages/fixture/26.3.json", .time = "", .release_time = "", .sha1 = metadata_hash, .compliance_level = null }};
    const minecraft_root = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft_root);
    return loader.prepareVanilla(a, io, .{ .target = .{ .root = root, .instance_id = "canonical-local", .instance_name = "26.3", .version_id = "26.3", .generation = 17, .environment = .{ .os_name = "linux", .arch = "x86_64" } }, .vanilla = .{ .root = minecraft_root, .version_id = "26.3", .manifest = .{ .latest = .{ .release = "26.3", .snapshot = "26.3" }, .versions = &entries }, .cancel = cancel }, .fetcher = .{} });
}
const canonical_instance: config.Instance = .{ .id = "canonical-local", .name = "26.3", .minecraft_version = "26.3" };

test "canonical registered-instance inspection requires independent official metadata pin and actual client proof without modifying local files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try canonicalFixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try std.testing.expectError(error.MissingInstallReceipt, testInspectInstalled(a, io, root, canonical_instance, .{}));
    var prepared = try canonicalPreparation(a, io, root, null);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(u64, 25), prepared.runtime_major);
    const options: Options = .{ .trusted_vanilla = .{ .prepared = &prepared, .generation = 17, .environment = prepared.target.environment } };
    var inspected = try testInspectInstalled(a, io, root, canonical_instance, options);
    defer inspected.deinit();
    try std.testing.expect(inspected.local_client_verified);
    try inspected.recheckPublication(root);
    try std.testing.expect(inspected.instance.origin == null);
    try std.testing.expectEqualStrings("26.3", inspected.instance.minecraft_version);
    inspected.releasePublicationProof();
    var installed = try testInspectInstalled(a, io, root, inspected.instance, options);
    defer installed.deinit();
    try std.testing.expect(installed.local_client_verified);
    try expectBytes(io, tmp.dir, ".minecraft/versions/26.3/mods/keep.jar", "mod");
    try expectBytes(io, tmp.dir, ".minecraft/versions/26.3/saves/world/level.dat", "world");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".minecraft/versions/26.3/.vela-instance.json", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".vela", .{}));
    installed.releasePublicationProof();
    try std.testing.expectError(error.CanonicalVersionProtected, testRename(a, io, root, inspected.instance, "New", options));
    try std.testing.expectError(error.CanonicalVersionProtected, testRemove(a, io, root, inspected.instance, options));
    var wrong = options;
    wrong.trusted_vanilla.?.generation += 1;
    try std.testing.expectError(error.PreparedMetadataGenerationMismatch, testInspectInstalled(a, io, root, canonical_instance, wrong));
    wrong = options;
    wrong.trusted_vanilla.?.environment.os_version = "changed";
    try std.testing.expectError(error.PreparedMetadataMismatch, testInspectInstalled(a, io, root, canonical_instance, wrong));
    var changed_id = canonical_instance;
    changed_id.id = "other-id";
    try std.testing.expectError(error.PreparedMetadataMismatch, testInspectInstalled(a, io, root, changed_id, options));
    var other = std.testing.tmpDir(.{ .iterate = true });
    defer other.cleanup();
    try canonicalFixture(io, other.dir);
    const other_root = try other.dir.realPathFileAlloc(io, ".", a);
    defer a.free(other_root);
    try std.testing.expectError(error.PreparedMetadataMismatch, testInspectInstalled(a, io, other_root, canonical_instance, options));
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/26.3.jar", .data = "evil" });
    try std.testing.expectError(error.ClientHashMismatch, testInspectInstalled(a, io, root, canonical_instance, options));
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/26.3.jar", .data = "large" });
    try std.testing.expectError(error.ClientSizeMismatch, testInspectInstalled(a, io, root, canonical_instance, options));
    try tmp.dir.deleteFile(io, ".minecraft/versions/26.3/26.3.jar");
    try tmp.dir.symLink(io, "mods/keep.jar", ".minecraft/versions/26.3/26.3.jar", .{});
    try std.testing.expectError(error.UnsafeFileType, testInspectInstalled(a, io, root, canonical_instance, options));
    try tmp.dir.deleteFile(io, ".minecraft/versions/26.3/26.3.jar");
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/26.3.jar", .data = "base" });
    const bytes = try canonicalFixtureBytes(a);
    defer a.free(bytes);
    const altered = try a.dupe(u8, bytes);
    defer a.free(altered);
    const major = std.mem.indexOf(u8, altered, "25") orelse return error.InvalidFixture;
    altered[major + 1] = '4';
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/26.3.json", .data = altered });
    try std.testing.expectError(error.ChecksumMismatch, canonicalPreparation(a, io, root, null));
    try std.testing.expectError(error.PreparedMetadataChanged, testInspectInstalled(a, io, root, canonical_instance, options));
    try tmp.dir.writeFile(io, .{ .sub_path = ".minecraft/versions/26.3/26.3.json", .data = bytes });
    @constCast(prepared.sources)[0].bytes = altered;
    try std.testing.expectError(error.PreparedMetadataChanged, testInspectInstalled(a, io, root, canonical_instance, options));
}
fn canonicalAllocationFixture(a: A) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try canonicalFixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var prepared = try canonicalPreparation(a, io, root, null);
    defer prepared.deinit();
    var result = try testInspectInstalled(a, io, root, canonical_instance, .{ .trusted_vanilla = .{ .prepared = &prepared, .generation = 17, .environment = prepared.target.environment } });
    defer result.deinit();
    try std.testing.expect(result.local_client_verified);
    try expectBytes(io, tmp.dir, ".minecraft/versions/26.3/26.3.jar", "base");
}
test "canonical proof allocation failures and cancellation release ownership without writing receipts" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, canonicalAllocationFixture, .{});
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try canonicalFixture(io, tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Canceled, canonicalPreparation(a, io, root, &cancel));
    cancel.store(false, .release);
    var prepared = try canonicalPreparation(a, io, root, &cancel);
    defer prepared.deinit();
    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, testInspectInstalled(a, io, root, canonical_instance, .{ .cancel = &cancel, .trusted_vanilla = .{ .prepared = &prepared, .generation = 17, .environment = prepared.target.environment } }));
    try expectBytes(io, tmp.dir, ".minecraft/versions/26.3/26.3.jar", "base");
}

test "instance transaction artifact receipt allocation failures release typed and alias scratch" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, artifactAllocationFixture, .{});
}

const ScopeIoKind = enum { directory_open, directory_stat, file_open, file_stat, read, iterate, create, write, close, rename, delete_file, delete_dir, sync };
const ScopeIoProbe = struct {
    const Leases = @import("instance_leases.zig");
    counts: [@typeInfo(ScopeIoKind).@"enum".field_names.len]usize = @splat(0),
    coordinator: ?*Leases.Coordinator = null,
    mutation: ?*Leases.Mutation = null,
    competing: ?*Leases.Mutation = null,
    id: []const u8 = fixture_instance.id,
    io: ?std.Io = null,
    guard_dir: ?Dir = null,
    checks: usize = 0,
    hook_calls: usize = 0,
    unrelated_launches: usize = 0,
    namespace_blocks: [3]usize = @splat(0),
    gate_unavailable: bool = false,
    admission_failed: bool = false,
    hook_failed: bool = false,

    fn count(self: *const ScopeIoProbe, kind: ScopeIoKind) usize {
        return self.counts[@backingInt(kind)];
    }
    fn total(self: *const ScopeIoProbe) usize {
        var n: usize = 0;
        for (self.counts) |value| n += value;
        return n;
    }
    fn observe(self: *ScopeIoProbe, kind: ScopeIoKind) void {
        self.counts[@backingInt(kind)] += 1;
        if (!worlds.transaction_gate.tryLock()) {
            self.gate_unavailable = true;
            return;
        }
        worlds.transaction_gate.unlock(std.testing.io);
        const coordinator = self.coordinator orelse return;
        self.mutation.?.recheck(self.id) catch {
            self.admission_failed = true;
        };
        if (self.competing.?.acquire(self.id)) |_| {
            self.admission_failed = true;
            self.competing.?.release(self.id);
            coordinator.tick();
        } else |err| {
            if (err != error.InstanceBusy) self.admission_failed = true;
        }
        if (coordinator.reserveLaunch(self.id)) |_| {
            self.admission_failed = true;
            coordinator.releaseLaunch();
            coordinator.tick();
        } else |err| {
            if (err != error.InstanceBusy) self.admission_failed = true;
        }
        if (coordinator.reserveLaunch("unrelated-launch")) |_| {
            self.unrelated_launches += 1;
            coordinator.releaseLaunch();
            coordinator.tick();
        } else |_| {
            self.admission_failed = true;
        }
        // All three publisher classes use the real process-wide admission API.
        for (0..self.namespace_blocks.len) |publisher| {
            if (namespace.acquire(std.testing.io)) |token| {
                self.admission_failed = true;
                token.release();
            } else |err| {
                if (err == error.InstanceNamespaceBusy) self.namespace_blocks[publisher] += 1 else self.admission_failed = true;
            }
        }
    }
    fn recheck(context: ?*anyopaque, id: []const u8) anyerror!void {
        const self: *ScopeIoProbe = @ptrCast(@alignCast(context.?));
        self.checks += 1;
        if (!worlds.transaction_gate.tryLock()) return error.CallbackUnderGate;
        worlds.transaction_gate.unlock(std.testing.io);
        try self.mutation.?.recheck(id);
        // The initial lease check precedes namespace admission.
        if (self.checks > 1 and self.guard_dir != null) {
            self.hook_calls += 1;
            _ = directoryStat(self.io.?, self.guard_dir.?) catch {
                self.hook_failed = true;
                return;
            };
        }
    }
};
var scope_io_probe: ?*ScopeIoProbe = null;
fn scopeOpenDir(context: ?*anyopaque, dir: Dir, path: []const u8, options: Dir.OpenOptions) Dir.OpenError!Dir {
    scope_io_probe.?.observe(.directory_open);
    return std.testing.io.vtable.dirOpenDir(context, dir, path, options);
}
fn scopeStatFile(context: ?*anyopaque, dir: Dir, path: []const u8, options: Dir.StatFileOptions) Dir.StatFileError!Stat {
    scope_io_probe.?.observe(.directory_stat);
    return std.testing.io.vtable.dirStatFile(context, dir, path, options);
}
fn scopeOpenFile(context: ?*anyopaque, dir: Dir, path: []const u8, options: Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
    scope_io_probe.?.observe(.file_open);
    return std.testing.io.vtable.dirOpenFile(context, dir, path, options);
}
fn scopeFileStat(context: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!Stat {
    scope_io_probe.?.observe(.file_stat);
    return std.testing.io.vtable.fileStat(context, file);
}
fn scopeRead(context: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
    scope_io_probe.?.observe(.read);
    return std.testing.io.vtable.fileReadPositional(context, file, data, offset);
}
fn scopeIterate(context: ?*anyopaque, reader: *Dir.Reader, entries: []Dir.Entry) Dir.Reader.Error!usize {
    scope_io_probe.?.observe(.iterate);
    return std.testing.io.vtable.dirRead(context, reader, entries);
}
fn scopeCreateDir(context: ?*anyopaque, dir: Dir, path: []const u8, permissions: Dir.Permissions) Dir.CreateDirError!void {
    scope_io_probe.?.observe(.create);
    return std.testing.io.vtable.dirCreateDir(context, dir, path, permissions);
}
fn scopeCreateFile(context: ?*anyopaque, dir: Dir, path: []const u8, options: Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
    scope_io_probe.?.observe(.create);
    return std.testing.io.vtable.dirCreateFile(context, dir, path, options);
}
fn scopeWrite(context: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
    scope_io_probe.?.observe(.write);
    return std.testing.io.vtable.fileWritePositional(context, file, header, data, splat, offset);
}
fn scopeCloseDirs(context: ?*anyopaque, dirs: []const Dir) void {
    scope_io_probe.?.observe(.close);
    std.testing.io.vtable.dirClose(context, dirs);
}
fn scopeCloseFiles(context: ?*anyopaque, files: []const std.Io.File) void {
    scope_io_probe.?.observe(.close);
    std.testing.io.vtable.fileClose(context, files);
}
fn scopeRename(context: ?*anyopaque, old_dir: Dir, old_path: []const u8, new_dir: Dir, new_path: []const u8) Dir.RenamePreserveError!void {
    scope_io_probe.?.observe(.rename);
    return std.testing.io.vtable.dirRenamePreserve(context, old_dir, old_path, new_dir, new_path);
}
fn scopeDeleteFile(context: ?*anyopaque, dir: Dir, path: []const u8) Dir.DeleteFileError!void {
    scope_io_probe.?.observe(.delete_file);
    return std.testing.io.vtable.dirDeleteFile(context, dir, path);
}
fn scopeDeleteDir(context: ?*anyopaque, dir: Dir, path: []const u8) Dir.DeleteDirError!void {
    scope_io_probe.?.observe(.delete_dir);
    return std.testing.io.vtable.dirDeleteDir(context, dir, path);
}
fn scopeSync(context: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
    scope_io_probe.?.observe(.sync);
    return std.testing.io.vtable.fileSync(context, file);
}
fn scopeIoVtable() std.Io.VTable {
    var vtable = std.testing.io.vtable.*;
    vtable.dirOpenDir = scopeOpenDir;
    vtable.dirStatFile = scopeStatFile;
    vtable.dirOpenFile = scopeOpenFile;
    vtable.fileStat = scopeFileStat;
    vtable.fileReadPositional = scopeRead;
    vtable.dirRead = scopeIterate;
    vtable.dirCreateDir = scopeCreateDir;
    vtable.dirCreateFile = scopeCreateFile;
    vtable.fileWritePositional = scopeWrite;
    vtable.dirClose = scopeCloseDirs;
    vtable.fileClose = scopeCloseFiles;
    vtable.dirRenamePreserve = scopeRename;
    vtable.dirDeleteFile = scopeDeleteFile;
    vtable.dirDeleteDir = scopeDeleteDir;
    vtable.fileSync = scopeSync;
    return vtable;
}

test "cold instance transaction APIs require stable scope before any filesystem or namespace admission" {
    const a = std.testing.allocator;
    var probe: ScopeIoProbe = .{};
    scope_io_probe = &probe;
    defer scope_io_probe = null;
    const vtable = scopeIoVtable();
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    const token = try namespace.acquire(io);
    defer token.release();
    // Missing scope takes precedence even with a held namespace and unavailable gate.
    try std.testing.expect(worlds.transaction_gate.tryLock());
    defer worlds.transaction_gate.unlock(io);
    for ([_]Options{ .{}, .{ .namespace_token = token } }) |options| {
        try std.testing.expectError(error.MissingStableScope, inspectInstalled(a, io, "/no-scope-io", fixture_instance, options));
        try std.testing.expectError(error.MissingStableScope, rename(a, io, "/no-scope-io", fixture_instance, "New", options));
        try std.testing.expectError(error.MissingStableScope, remove(a, io, "/no-scope-io", fixture_instance, options));
    }
    try std.testing.expectEqual(@as(usize, 0), probe.total());
}

test "cold instance transaction APIs reject dynamic guards before lease namespace and filesystem work" {
    const leases = @import("instance_leases.zig");
    const GuardCounter = struct {
        fn called(context: ?*anyopaque, _: []const u8) bool {
            const calls: *usize = @ptrCast(@alignCast(context.?));
            calls.* += 1;
            return false;
        }
    };
    const NamespaceState = enum { free, busy, lost };
    const a = std.testing.allocator;
    const real_io = std.testing.io;
    for ([_]bool{ false, true }) |gate_busy| {
        for ([_]NamespaceState{ .free, .busy, .lost }) |state| {
            var coordinator = leases.Coordinator.init(real_io);
            const mutation = coordinator.mutation(0);
            try mutation.acquire(fixture_instance.id);
            defer {
                mutation.release(fixture_instance.id);
                coordinator.tick();
            }
            var held: ?namespace.Token = null;
            var borrowed: ?namespace.Token = null;
            switch (state) {
                .free => {},
                .busy => held = try namespace.acquire(real_io),
                .lost => {
                    const stale = try namespace.acquire(real_io);
                    stale.release();
                    try std.testing.expectError(error.InstanceNamespaceLeaseLost, stale.recheck());
                    borrowed = stale;
                },
            }
            defer if (held) |token| token.release();
            var probe: ScopeIoProbe = .{ .mutation = mutation };
            scope_io_probe = &probe;
            defer scope_io_probe = null;
            const vtable = scopeIoVtable();
            const io: std.Io = .{ .userdata = real_io.userdata, .vtable = &vtable };
            var guard_calls: usize = 0;
            const lease: LeaseCheck = .{ .context = &probe, .recheck = ScopeIoProbe.recheck };
            const options: Options = .{
                .lease = lease,
                .namespace_token = borrowed,
                .guard = .{ .context = &guard_calls, .is_running = GuardCounter.called },
            };
            if (gate_busy) try std.testing.expect(worlds.transaction_gate.tryLock());
            defer if (gate_busy) worlds.transaction_gate.unlock(real_io);
            try std.testing.expectError(error.UnsupportedInstanceGuard, inspectInstalled(a, io, "/no-guard-io", fixture_instance, options));
            try std.testing.expectError(error.UnsupportedInstanceGuard, rename(a, io, "/no-guard-io", fixture_instance, "New", options));
            try std.testing.expectError(error.UnsupportedInstanceGuard, remove(a, io, "/no-guard-io", fixture_instance, options));
            try std.testing.expectError(error.UnsupportedInstanceGuard, inspectInstalledLeased(a, io, "/no-guard-io", fixture_instance, options, lease));
            var unscoped = options;
            unscoped.lease = null;
            try std.testing.expectError(error.MissingStableScope, inspectInstalled(a, io, "/no-guard-io", fixture_instance, unscoped));
            try std.testing.expectEqual(@as(usize, 0), guard_calls);
            try std.testing.expectEqual(@as(usize, 0), probe.checks);
            try std.testing.expectEqual(@as(usize, 0), probe.total());
        }
    }
}

test "instance transaction actual filesystem and hook IO retain Coordinator lease and namespace outside gate" {
    const leases = @import("instance_leases.zig");
    const a = std.testing.allocator;
    const real_io = std.testing.io;
    for ([_]TestCall{ .inspect_installed, .rename_instance, .remove_instance }) |call| {
        for ([_]bool{ false, true }) |borrowed| {
            var tmp = std.testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            defer fixtureWritable(real_io, tmp.dir);
            try flattenedFixture(real_io, tmp.dir, .fabric);
            const root = try tmp.dir.realPathFileAlloc(real_io, ".", a);
            defer a.free(root);
            var coordinator = leases.Coordinator.init(real_io);
            const mutation = coordinator.mutation(0);
            const competing = coordinator.mutation(1);
            try mutation.acquire(fixture_instance.id);
            defer {
                mutation.release(fixture_instance.id);
                coordinator.tick();
            }
            const token: ?namespace.Token = if (borrowed) try namespace.acquire(real_io) else null;
            defer if (token) |held| held.release();
            var probe: ScopeIoProbe = .{ .coordinator = &coordinator, .mutation = mutation, .competing = competing, .guard_dir = tmp.dir };
            scope_io_probe = &probe;
            defer scope_io_probe = null;
            const vtable = scopeIoVtable();
            const io: std.Io = .{ .userdata = real_io.userdata, .vtable = &vtable };
            probe.io = io;
            const options: Options = .{
                .lease = .{ .context = &probe, .recheck = ScopeIoProbe.recheck },
                .namespace_token = token,
            };
            var result = try switch (call) {
                .inspect_installed => inspectInstalledLeased(a, io, root, fixture_instance, options, options.lease.?),
                .rename_instance => rename(a, io, root, fixture_instance, "New", options),
                .remove_instance => remove(a, io, root, fixture_instance, options),
            };
            defer result.deinit();
            try std.testing.expectEqual(@as(usize, if (call == .inspect_installed) 2 else 3), probe.checks);
            try std.testing.expectEqual(probe.checks - 1, probe.hook_calls);
            try std.testing.expect(!probe.gate_unavailable and !probe.admission_failed and !probe.hook_failed);
            for ([_]ScopeIoKind{ .directory_open, .directory_stat, .file_open, .file_stat, .read, .iterate, .close }) |kind| {
                try std.testing.expect(probe.count(kind) > 0);
            }
            if (call == .rename_instance) {
                for ([_]ScopeIoKind{ .create, .write, .rename, .sync }) |kind| try std.testing.expect(probe.count(kind) > 0);
            } else if (call == .remove_instance) {
                for ([_]ScopeIoKind{ .delete_file, .delete_dir, .sync }) |kind| try std.testing.expect(probe.count(kind) > 0);
                for ([_]ScopeIoKind{ .create, .write, .rename }) |kind| try std.testing.expectEqual(@as(usize, 0), probe.count(kind));
            }
            try std.testing.expect(probe.unrelated_launches > 0);
            for (probe.namespace_blocks) |count| try std.testing.expect(count > 0);
            try mutation.recheck(fixture_instance.id);
            if (token) |held| {
                try held.recheck();
                try std.testing.expectError(error.InstanceNamespaceBusy, namespace.acquire(real_io));
            } else {
                const available = try namespace.acquire(real_io);
                available.release();
            }
        }
    }
}

test "cold instance transaction APIs reject busy namespace and lost borrowed stamps before actual IO" {
    const leases = @import("instance_leases.zig");
    const a = std.testing.allocator;
    var coordinator = leases.Coordinator.init(std.testing.io);
    const mutation = coordinator.mutation(0);
    try mutation.acquire(fixture_instance.id);
    defer {
        mutation.release(fixture_instance.id);
        coordinator.tick();
    }
    const held = try namespace.acquire(std.testing.io);
    defer held.release();
    var probe: ScopeIoProbe = .{ .mutation = mutation };
    scope_io_probe = &probe;
    defer scope_io_probe = null;
    const vtable = scopeIoVtable();
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    const lease: LeaseCheck = .{ .context = &probe, .recheck = ScopeIoProbe.recheck };
    const lost: namespace.Token = .{ .io = io, .generation = 0 };
    for ([_]Options{ .{ .lease = lease }, .{ .lease = lease, .namespace_token = lost } }, 0..) |options, index| {
        const expected = if (index == 0) error.InstanceNamespaceBusy else error.InstanceNamespaceLeaseLost;
        try std.testing.expectError(expected, inspectInstalled(a, io, "/no-namespace-io", fixture_instance, options));
        try std.testing.expectError(expected, rename(a, io, "/no-namespace-io", fixture_instance, "New", options));
        try std.testing.expectError(expected, remove(a, io, "/no-namespace-io", fixture_instance, options));
        try std.testing.expectEqual(@as(usize, 0), probe.total());
        try held.recheck();
    }
    try std.testing.expectEqual(@as(usize, 6), probe.checks);
}

test "canonical inspection retains owning namespace through publication recheck and all returned proof closes" {
    const leases = @import("instance_leases.zig");
    const a = std.testing.allocator;
    const real_io = std.testing.io;
    for ([_]bool{ false, true }) |installed| {
        for ([_]bool{ false, true }) |borrowed| {
            for ([_]bool{ false, true }) |full_cleanup| {
                var tmp = std.testing.tmpDir(.{ .iterate = true });
                defer tmp.cleanup();
                try canonicalFixture(real_io, tmp.dir);
                const root = try tmp.dir.realPathFileAlloc(real_io, ".", a);
                defer a.free(root);
                var prepared = try canonicalPreparation(a, real_io, root, null);
                defer prepared.deinit();
                var coordinator = leases.Coordinator.init(real_io);
                const mutation = coordinator.mutation(0);
                const competing = coordinator.mutation(1);
                try mutation.acquire(canonical_instance.id);
                defer {
                    mutation.release(canonical_instance.id);
                    coordinator.tick();
                }
                const token: ?namespace.Token = if (borrowed) try namespace.acquire(real_io) else null;
                defer if (token) |held| held.release();
                var probe: ScopeIoProbe = .{
                    .coordinator = &coordinator,
                    .mutation = mutation,
                    .competing = competing,
                    .id = canonical_instance.id,
                    .guard_dir = tmp.dir,
                };
                scope_io_probe = &probe;
                defer scope_io_probe = null;
                const vtable = scopeIoVtable();
                const io: std.Io = .{ .userdata = real_io.userdata, .vtable = &vtable };
                probe.io = io;
                const options: Options = .{
                    .lease = .{ .context = &probe, .recheck = ScopeIoProbe.recheck },
                    .namespace_token = token,
                    // The existing cleanup variants exercise both namespace modes.
                    .worker_checks = full_cleanup,
                    .trusted_vanilla = .{ .prepared = &prepared, .generation = 17, .environment = prepared.target.environment },
                };
                var result = try if (installed)
                    inspectInstalledLeased(a, io, root, canonical_instance, options, options.lease.?)
                else
                    inspectInstalled(a, io, root, canonical_instance, options);
                var result_live = true;
                defer if (result_live) result.deinit();
                try std.testing.expect(result.publication_proof != null);
                try std.testing.expectEqual(!borrowed, result.owned_ns != null);
                try std.testing.expectEqual(@as(usize, 2), probe.checks);
                try std.testing.expectEqual(probe.checks - 1, probe.hook_calls);
                try std.testing.expectError(error.InstanceNamespaceBusy, namespace.acquire(real_io));
                const stats_before = probe.count(.file_stat) + probe.count(.directory_stat);
                try result.recheckPublication(root);
                try std.testing.expect(probe.count(.file_stat) + probe.count(.directory_stat) > stats_before);
                const closes_before = probe.count(.close);
                if (full_cleanup) {
                    result.deinit();
                    result_live = false;
                } else {
                    result.releasePublicationProof();
                    try std.testing.expect(result.publication_proof == null and result.owned_ns == null);
                }
                try std.testing.expect(probe.count(.close) > closes_before);
                try std.testing.expect(!probe.gate_unavailable and !probe.admission_failed and !probe.hook_failed);
                try std.testing.expect(probe.unrelated_launches > 0);
                for (probe.namespace_blocks) |count| try std.testing.expect(count > 0);
                try std.testing.expectEqual(@as(usize, 2), probe.checks);
                try mutation.recheck(canonical_instance.id);
                if (token) |held| {
                    try held.recheck();
                    try std.testing.expectError(error.InstanceNamespaceBusy, namespace.acquire(real_io));
                } else {
                    const available = try namespace.acquire(real_io);
                    available.release();
                }
            }
        }
    }
}
