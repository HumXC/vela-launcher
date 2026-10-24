//! Owned launcher configuration at <launcher root>/.vela/config.json.
//! This module stores credential references only, never credentials.
const std = @import("std");
const windows_fs = @import("windows_durable_fs.zig");
const builtin = @import("builtin");
const credentials = @import("credentials.zig");
pub const appearance = @import("appearance.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const max_json = 4 * 1024 * 1024;
const max_entries = 4096;
const min_memory_mb = 256;
const max_memory_mb = 1024 * 1024;

pub const GameExitBehavior = enum { restore_launcher, exit_launcher };
pub const Loader = enum { vanilla, fabric, forge, neoforge, quilt };
pub const SourceKind = enum { modrinth, curseforge };
pub const Origin = struct {
    kind: SourceKind,
    project_id: []const u8,
    version_id: []const u8,
};
pub const Instance = struct {
    id: []const u8,
    name: []const u8,
    minecraft_version: []const u8,
    loader: Loader = .vanilla,
    loader_version: ?[]const u8 = null,
    java_path: ?[]const u8 = null,
    min_memory_mb: ?u32 = null,
    max_memory_mb: ?u32 = null,
    debug_launch: bool = false,
    origin: ?Origin = null,
};
pub const Server = struct {
    id: []const u8,
    name: []const u8,
    address: []const u8,
    port: u16 = 25565,
    instance_id: ?[]const u8 = null,
    show_on_home: bool = false,
};
pub const AccountKind = enum { offline, microsoft };
pub const Account = struct {
    id: []const u8,
    name: []const u8,
    uuid: []const u8,
    kind: AccountKind = .offline,
    credential_ref: ?[]const u8 = null,
};
pub const Settings = struct {
    game_exit_behavior: GameExitBehavior = .restore_launcher,
    default_memory_mb: u32 = 2048,
    download_connections: u16 = 8,
    microsoft_client_id: []const u8 = "",
    curseforge_enabled: bool = false,
    curseforge_credential_ref: ?[]const u8 = null,
    curseforge_terms_approved: bool = false,
    resource_list_view: bool = false,
};
pub const Document = struct {
    schema_version: u32 = 1,
    settings: Settings = .{},
    appearance: appearance.Settings = .{},
    instances: []const Instance = &.{},
    servers: []const Server = &.{},
    accounts: []const Account = &.{},
    selected_instance: ?[]const u8 = null,
    selected_account: ?[]const u8 = null,
    selected_server: ?[]const u8 = null,
};

/// A portable directory component, with a 200-byte UTF-8 limit.
/// ASCII case folding is used separately for uniqueness, not Unicode folding.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 200 or !std.unicode.utf8ValidateSlice(id)) return false;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    if (id[id.len - 1] == '.' or id[id.len - 1] == ' ') return false;
    var it = std.unicode.Utf8View.initUnchecked(id).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return false;
        if (cp < 128 and std.mem.indexOfScalar(u8, "<>:\"/\\|?*", @intCast(cp)) != null) return false;
    }
    // Device names remain reserved before an extension and with stem spaces.
    const end = std.mem.indexOfScalar(u8, id, '.') orelse id.len;
    const stem = std.mem.trimEnd(u8, id[0..end], " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$" }) |name| {
        if (std.ascii.eqlIgnoreCase(stem, name)) return false;
    }
    if (stem.len >= 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) {
        if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9') return false;
        // Windows also reserves the superscript digits 1, 2, and 3.
        if (stem.len == 5 and stem[3] == 0xc2 and (stem[4] == 0xb9 or stem[4] == 0xb2 or stem[4] == 0xb3)) return false;
    }
    return true;
}

fn validText(text: []const u8, limit: usize, allow_empty: bool) bool {
    if ((!allow_empty and text.len == 0) or text.len > limit or !std.unicode.utf8ValidateSlice(text)) return false;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return false;
    return true;
}

fn validMemory(memory: u32) bool {
    return memory >= min_memory_mb and memory <= max_memory_mb;
}

fn checkIds(comptime T: type, items: []const T) !void {
    if (items.len > max_entries) return error.TooManyEntries;
    for (items, 0..) |item, i| {
        if (!validId(item.id)) return error.InvalidId;
        for (items[0..i]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous.id, item.id)) return error.DuplicateId;
        }
    }
}

fn containsId(comptime T: type, items: []const T, id: []const u8) bool {
    // References use exact spelling; case folding only prevents collisions.
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return true;
    return false;
}

fn validate(doc: Document) !void {
    if (doc.schema_version != 1) return error.UnsupportedSchemaVersion;
    try appearance.validate(doc.appearance);
    if (!validMemory(doc.settings.default_memory_mb)) return error.InvalidMemory;
    if (doc.settings.download_connections == 0 or doc.settings.download_connections > 64) return error.InvalidDownloadConnections;
    if (!validText(doc.settings.microsoft_client_id, 4096, true)) return error.InvalidClientId;
    if (doc.settings.curseforge_credential_ref) |ref| {
        if (!credentials.validateReference(ref)) return error.InvalidCredentialRef;
    }
    try checkIds(Instance, doc.instances);
    try checkIds(Server, doc.servers);
    try checkIds(Account, doc.accounts);
    for (doc.instances, 0..) |instance, i| {
        if (!validId(instance.name)) return error.InvalidInstanceName;
        for (doc.instances[0..i]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous.name, instance.name)) return error.DuplicateInstanceName;
        }
        if (!validText(instance.minecraft_version, 200, false)) return error.InvalidMinecraftVersion;
        if (instance.loader_version) |version| {
            if (!validText(version, 200, false)) return error.InvalidLoaderVersion;
        } else if (instance.loader != .vanilla) return error.InvalidLoaderVersion;
        if (instance.java_path) |path| if (!validText(path, 4096, false)) return error.InvalidJavaPath;
        if (instance.min_memory_mb) |memory| if (!validMemory(memory)) return error.InvalidMemory;
        if (instance.max_memory_mb) |memory| if (!validMemory(memory)) return error.InvalidMemory;
        if (instance.min_memory_mb) |minimum| {
            if (minimum > (instance.max_memory_mb orelse doc.settings.default_memory_mb)) return error.InvalidMemory;
        }
        if (instance.origin) |origin| {
            if (!validText(origin.project_id, 4096, false) or !validText(origin.version_id, 4096, false)) return error.InvalidOrigin;
        }
    }
    for (doc.servers) |server| {
        if (!validText(server.name, 200, false)) return error.InvalidServerName;
        if (!validText(server.address, 4096, false) or std.mem.indexOfAny(u8, server.address, " /\\") != null) return error.InvalidServerAddress;
        if (server.port == 0) return error.InvalidServerPort;
        if (server.instance_id) |id| if (!containsId(Instance, doc.instances, id)) return error.DanglingServerInstance;
    }
    for (doc.accounts) |account| {
        if (!validText(account.name, 200, false)) return error.InvalidAccountName;
        if (!validText(account.uuid, 200, false)) return error.InvalidAccountUuid;
        if (account.credential_ref) |ref| if (!validText(ref, 4096, false)) return error.InvalidCredentialRef;
    }
    if (doc.selected_instance) |id| if (!containsId(Instance, doc.instances, id)) return error.InvalidSelectedInstance;
    if (doc.selected_server) |id| if (!containsId(Server, doc.servers, id)) return error.InvalidSelectedServer;
    if (doc.selected_account) |id| if (!containsId(Account, doc.accounts, id)) return error.InvalidSelectedAccount;
}

fn serialize(a: Allocator, doc: Document) ![]u8 {
    const bytes = try std.json.Stringify.valueAlloc(a, doc, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    errdefer a.free(bytes);
    if (bytes.len > max_json) return error.ConfigTooLarge;
    return bytes;
}

fn parse(a: Allocator, bytes: []const u8) !std.json.Parsed(Document) {
    // Check the version before decoding newer fields or enum values.
    const header = try std.json.parseFromSlice(struct { schema_version: u32 }, a, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer header.deinit();
    if (header.value.schema_version != 1) return error.UnsupportedSchemaVersion;
    const parsed = try std.json.parseFromSlice(Document, a, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = max_json,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

fn initDefaults(a: Allocator) !std.json.Parsed(Document) {
    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(a);
    return .{ .arena = arena, .value = .{} };
}

// Keep the lock inode forever; unlinking it would split cooperating writers.
// flock is attached to this open description on POSIX and released on crash/close.
const RootWriter = struct {
    directory: Dir,
    file: std.Io.File,
    const leaf = ".vela-writer.lock";

    fn acquire(io: std.Io, path: []const u8) !RootWriter {
        const directory = try Dir.cwd().openDir(io, path, .{});
        errdefer directory.close(io);
        const file = directory.openFile(io, leaf, .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false }) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            break :blk directory.createFile(io, leaf, .{ .read = true, .exclusive = true }) catch |create_err| {
                if (create_err != error.PathAlreadyExists) return create_err;
                break :blk try directory.openFile(io, leaf, .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false });
            };
        };
        errdefer file.close(io);
        if ((try file.stat(io)).kind != .file) return error.InvalidRootWriterLock;
        if (!try file.tryLock(io, .exclusive)) return error.LauncherRootInUse;
        const writer: RootWriter = .{ .directory = directory, .file = file };
        try writer.recheckLock(io);
        return writer;
    }

    fn recheckLock(self: RootWriter, io: std.Io) !void {
        const named = try self.directory.statFile(io, leaf, .{ .follow_symlinks = false });
        if (named.kind != .file or named.inode != (try self.file.stat(io)).inode) return error.RootWriterLockChanged;
    }

    fn recheck(self: RootWriter, io: std.Io, root: []const u8) !void {
        try self.recheckLock(io);
        const named = try Dir.cwd().statFile(io, root, .{ .follow_symlinks = false });
        if (named.kind != .directory or named.inode != (try self.directory.stat(io)).inode) return error.LauncherRootChanged;
    }

    fn close(self: RootWriter, io: std.Io) void {
        self.file.close(io);
        self.directory.close(io);
    }
};

/// Single-owner root writer. Calls must be serialized by the caller.
/// The lifetime lock also protects reference publication through vault cleanup.
pub const Store = struct {
    a: Allocator,
    io: std.Io,
    root: []const u8,
    file: []const u8,
    state: std.json.Parsed(Document),
    publication_uncertain: bool = false,
    initial_defaults: bool = false,
    windows_root: ?windows_fs.Root = null,
    writer: ?RootWriter = null,

    /// Owns the canonical launcher root, all parsed data, and its exclusive writer.
    /// Creates/opens only the persistent root lock; never creates or rewrites config.
    /// A competing Store fails with LauncherRootInUse before reading any references.
    /// Only a missing config gives defaults; all other load errors propagate.
    pub fn init(a: Allocator, io: std.Io, root: []const u8) !Store {
        if (!validText(root, 4096, false)) return error.InvalidRoot;
        if (builtin.os.tag == .windows) {
            var owned: ?windows_fs.Root = windows_fs.openRoot(a, io, root, .ordinary_config) catch |err| return windowsError(err);
            return initWithOwnedRoot(a, io, &owned);
        }
        const writer = try RootWriter.acquire(io, root);
        errdefer writer.close(io);
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try writer.directory.realPath(io, &root_buffer);
        const owned_root = try a.dupe(u8, root_buffer[0..root_len]);
        errdefer a.free(owned_root);
        const file = try std.fs.path.join(a, &.{ owned_root, ".vela", "config.json" });
        errdefer a.free(file);
        const stat = Dir.cwd().statFile(io, file, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                return .{ .a = a, .io = io, .root = owned_root, .file = file, .state = try initDefaults(a), .writer = writer, .initial_defaults = true };
            },
            else => return err,
        };
        if (stat.kind != .file) return error.InvalidConfigFile;
        if (stat.size > max_json) return error.ConfigTooLarge;
        const bytes = try Dir.cwd().readFileAlloc(io, file, a, .limited(max_json));
        defer a.free(bytes);
        return .{ .a = a, .io = io, .root = owned_root, .file = file, .state = try parse(a, bytes), .writer = writer };
    }

    /// Consumes the optional capability immediately, including on every error.
    /// Explicit native-ops fixtures use this same Windows path without POSIX resolution.
    pub fn initWithOwnedRoot(a: Allocator, io: std.Io, owned: *?windows_fs.Root) !Store {
        var capability = owned.* orelse return error.InvalidRoot;
        owned.* = null;
        errdefer windows_fs.deinit(&capability);
        if (capability.privacy != .ordinary_config) return error.InvalidRoot;
        try windows_fs.acquireWriter(&capability);
        const root = try a.dupe(u8, capability.normalized);
        errdefer a.free(root);
        const file = try std.fmt.allocPrint(a, "{s}\\.vela\\config.json", .{root});
        errdefer a.free(file);
        var loaded = windows_fs.load(&capability, a, "config.json", max_json) catch |err| return windowsError(err);
        defer if (loaded) |*bytes| bytes.deinit();
        return .{ .a = a, .io = io, .root = root, .file = file, .state = if (loaded) |bytes| try parse(a, bytes.bytes) else try initDefaults(a), .windows_root = capability, .publication_uncertain = capability.publication_uncertain, .initial_defaults = loaded == null };
    }

    /// Separate from read-only init. App calls this before any worker or consumer.
    pub fn prepareStorage(self: *Store) !void {
        if (self.publication_uncertain) return error.ConfigPublicationUncertain;
        try self.recheckWriter();
        if (self.windows_root) |*root| {
            windows_fs.prepareStorage(root) catch |err| {
                self.publication_uncertain = true;
                return windowsError(err);
            };
            return;
        }
        if (builtin.os.tag == .windows) return error.UnsupportedDurability;
    }

    fn windowsError(err: anyerror) anyerror {
        return switch (err) {
            error.FileTooLarge => error.ConfigTooLarge,
            error.InvalidLeaf => error.InvalidConfigFile,
            else => err,
        };
    }

    pub fn deinit(self: *Store) void {
        self.state.deinit();
        if (self.writer) |writer| writer.close(self.io);
        if (self.windows_root) |*root| windows_fs.deinit(root);
        self.a.free(self.file);
        self.a.free(self.root);
        self.* = undefined;
    }

    /// Borrowed snapshot, valid until a successful update, reconcile, or deinit.
    /// While publication is uncertain this may differ from the disk document.
    pub fn snapshot(self: *const Store) *const Document {
        return &self.state.value;
    }

    pub fn publicationUncertain(self: *const Store) bool {
        return self.publication_uncertain;
    }

    /// Clones before writing; errors leave the in-memory snapshot untouched.
    /// Any save error blocks further updates until explicit disk reconciliation.
    pub fn update(self: *Store, document: Document) !void {
        if (self.publication_uncertain) return error.ConfigPublicationUncertain;
        try validate(document);
        const bytes = try serialize(self.a, document);
        defer self.a.free(bytes);
        const next = try parse(self.a, bytes);
        errdefer next.deinit();
        self.save(bytes) catch |err| {
            self.publication_uncertain = true;
            return err;
        };
        self.state.deinit();
        self.state = next;
        self.publication_uncertain = false;
        self.initial_defaults = false;
    }

    /// Reloads only an existing valid disk document, never defaults or a draft.
    /// Even an explicit reconcile on a certain store blocks updates on failure.
    /// Readback alone is not durability: confirm the existing save pipeline first.
    /// Windows reconciles the exact loaded bytes through the durable adapter.
    pub fn reconcile(self: *Store) !void {
        self.publication_uncertain = true;
        try self.recheckWriter();
        if (self.windows_root) |*root| {
            root.publication_uncertain = true;
            var loaded = (windows_fs.load(root, self.a, "config.json", max_json) catch |err| return windowsError(err)) orelse return error.FileNotFound;
            defer loaded.deinit();
            const next = try parse(self.a, loaded.bytes);
            errdefer next.deinit();
            windows_fs.reconcile(root, "config.json", loaded.bytes, .none) catch |err| return windowsError(err);
            self.state.deinit();
            self.state = next;
            self.publication_uncertain = false;
            self.initial_defaults = false;
            return;
        }
        if (builtin.os.tag == .windows) return error.UnsupportedDurability;
        const stat = try Dir.cwd().statFile(self.io, self.file, .{});
        if (stat.kind != .file) return error.InvalidConfigFile;
        if (stat.size > max_json) return error.ConfigTooLarge;
        const bytes = try Dir.cwd().readFileAlloc(self.io, self.file, self.a, .limited(max_json));
        defer self.a.free(bytes);
        const next = try parse(self.a, bytes);
        errdefer next.deinit();
        try self.save(bytes);
        self.state.deinit();
        self.state = next;
        self.publication_uncertain = false;
        self.initial_defaults = false;
    }

    /// Explicit recovery may durably recreate the known initial baseline only when
    /// this Store has never loaded or successfully published a saved document.
    /// Existing configurations always use the normal reconciliation contract.
    pub fn recover(self: *Store) !void {
        if (!self.initial_defaults) return self.reconcile();
        self.publication_uncertain = true;
        try self.recheckWriter();
        if (self.windows_root) |*root| {
            var loaded = (windows_fs.load(root, self.a, "config.json", max_json) catch |err| return windowsError(err));
            if (loaded) |*bytes| {
                bytes.deinit();
                return self.reconcile();
            }
        } else {
            if (Dir.cwd().statFile(self.io, self.file, .{})) |_| {
                return self.reconcile();
            } else |err| if (err != error.FileNotFound) return err;
        }
        const bytes = try serialize(self.a, self.state.value);
        defer self.a.free(bytes);
        if (self.windows_root) |*root| {
            windows_fs.reconcile(root, "config.json", bytes, .none) catch |err| return windowsError(err);
        } else try self.save(bytes);
        self.publication_uncertain = false;
        self.initial_defaults = false;
    }

    fn recheckWriter(self: *Store) !void {
        if (self.writer) |writer| try writer.recheck(self.io, self.root);
    }

    fn save(self: *Store, bytes: []const u8) !void {
        try self.recheckWriter();
        if (self.windows_root) |*root| {
            windows_fs.publish(root, "config.json", bytes, .none) catch |err| return windowsError(err);
            return;
        }
        if (builtin.os.tag == .windows) return error.UnsupportedDurability;
        const base = try Dir.cwd().createDirPathOpen(self.io, self.root, .{ .open_options = .{ .iterate = true } });
        defer base.close(self.io);
        const dir = try base.createDirPathOpen(self.io, ".vela", .{ .open_options = .{ .iterate = true } });
        defer dir.close(self.io);
        var atomic = try dir.createFileAtomic(self.io, "config.json", .{ .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, bytes);
        try atomic.file.sync(self.io);
        try syncDir(base, self.io);
        try atomic.replace(self.io);
        try syncDir(dir, self.io);
    }
};

fn syncDir(dir: Dir, io: std.Io) !void {
    // Windows does not support directory fsync. File data is still flushed.
    if (builtin.os.tag == .windows) return;
    const file: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try file.sync(io);
}

fn testRoot(tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    return std.testing.allocator.dupe(u8, buffer[0..len]);
}

const sample: Document = .{
    .settings = .{ .game_exit_behavior = .exit_launcher, .curseforge_enabled = true, .microsoft_client_id = "client-id" },
    .instances = &.{.{
        .id = "game",
        .name = "My World",
        .minecraft_version = "1.21.5",
        .loader = .fabric,
        .loader_version = "0.16.10",
        .java_path = "/java/bin/java",
        .min_memory_mb = 1024,
        .max_memory_mb = 4096,
        .debug_launch = true,
        .origin = .{ .kind = .modrinth, .project_id = "project", .version_id = "release" },
    }},
    .servers = &.{.{ .id = "game", .name = "Friends", .address = "localhost", .instance_id = "game", .show_on_home = true }},
    .accounts = &.{.{ .id = "game", .name = "Player", .uuid = "uuid", .kind = .microsoft, .credential_ref = "vault:player" }},
    .selected_instance = "game",
    .selected_server = "game",
    .selected_account = "game",
};

test "portable IDs permit Unicode and reject unsafe directory components" {
    for ([_][]const u8{ "world", "My World", "\xe4\xb8\x96\xe7\x95\x8c", "com0", "lpt10", "console", "ok.name" }) |id| try std.testing.expect(validId(id));
    for ([_][]const u8{ "", ".", "..", "a/b", "a\\b", "a:b", "a*", "a?", "a|", "a<", "a>", "a\"", "name.", "name ", "a\x00b", "a\x1fb", "a\x7fb", "a\xc2\x85b", "\xff", "CON", "nul.txt", "PrN", "AUX", "COM1", "lPt9.txt", "CON .txt", "COM\xc2\xb9", "LPT\xc2\xb2.txt", "CONIN$", "CLOCK$" }) |id| try std.testing.expect(!validId(id));
    try std.testing.expect(validId(&(@as([200]u8, @splat('a')))));
    try std.testing.expect(!validId(&(@as([201]u8, @splat('a')))));
}

test "fresh defaults do not create files and root is owned" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try Store.init(a, io, root);
    defer store.deinit();
    @memset(root, 'x');
    try std.testing.expectEqual(@as(u32, 1), store.snapshot().schema_version);
    try std.testing.expectEqual(@as(u32, 2048), store.snapshot().settings.default_memory_mb);
    try std.testing.expectEqual(@as(u16, 8), store.snapshot().settings.download_connections);
    try std.testing.expectEqual(GameExitBehavior.restore_launcher, store.snapshot().settings.game_exit_behavior);
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().instances.len);
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().servers.len);
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().accounts.len);
    try std.testing.expect(store.snapshot().selected_instance == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".vela/config.json", .{}));
    try store.update(.{});
    _ = try tmp.dir.statFile(io, ".vela/config.json", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".minecraft", .{}));
}

test "save reload and snapshot alias updates own every string and collection" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try Store.init(a, io, root);
    defer store.deinit();
    const bytes = try serialize(a, sample);
    const input = try parse(a, bytes);
    a.free(bytes);
    try store.update(input.value);
    input.deinit();
    try std.testing.expectEqualStrings("My World", store.snapshot().instances[0].name);
    try std.testing.expectEqualStrings("project", store.snapshot().instances[0].origin.?.project_id);
    try std.testing.expectEqualStrings("release", store.snapshot().instances[0].origin.?.version_id);
    try std.testing.expectEqualStrings("/java/bin/java", store.snapshot().instances[0].java_path.?);
    try std.testing.expectEqualStrings("vault:player", store.snapshot().accounts[0].credential_ref.?);
    try store.update(store.snapshot().*);
    try store.reconcile();
    const reloaded = &store;
    const expected = try serialize(a, sample);
    defer a.free(expected);
    const actual = try serialize(a, reloaded.snapshot().*);
    defer a.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    const saved = try tmp.dir.readFileAlloc(io, ".vela/config.json", a, .limited(max_json));
    defer a.free(saved);
    try std.testing.expectEqualStrings(expected, saved);
}

test "serialization omits all null optionals but retains non-null values" {
    const a = std.testing.allocator;
    const doc: Document = .{
        .instances = &.{.{ .id = "world", .name = "World", .minecraft_version = "1.21" }},
        .accounts = &.{.{ .id = "player", .name = "Player", .uuid = "uuid" }},
    };
    const bytes = try serialize(a, doc);
    defer a.free(bytes);
    for ([_][]const u8{ "null", "loader_version", "java_path", "min_memory_mb", "max_memory_mb", "origin", "credential_ref", "selected_instance", "selected_account", "selected_server" }) |key| try std.testing.expect(std.mem.indexOf(u8, bytes, key) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "vanilla") != null);
    const parsed = try parse(a, bytes);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.instances[0].origin == null);
}

test "existing config requires an explicit schema marker" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "{}",
        "{\"instances\":[{\"id\":\"world\",\"name\":\"World\",\"minecraft_version\":\"1.21\",\"max_memory_mb\":4096}]}",
    }) |bytes| try std.testing.expectError(error.MissingField, parse(a, bytes));
}

test "current schema optional heap values roundtrip" {
    const a = std.testing.allocator;
    const current = try parse(a, "{\"schema_version\":1,\"instances\":[{\"id\":\"world\",\"name\":\"World\",\"minecraft_version\":\"1.21\",\"max_memory_mb\":4096}]}");
    defer current.deinit();
    try std.testing.expectEqual(@as(?u32, null), current.value.instances[0].min_memory_mb);
    var instance = current.value.instances[0];
    instance.min_memory_mb = 1024;
    var doc = current.value;
    doc.instances = (&instance)[0..1];
    const bytes = try serialize(a, doc);
    defer a.free(bytes);
    const decoded = try parse(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 1), decoded.value.schema_version);
    try std.testing.expectEqual(@as(?u32, 1024), decoded.value.instances[0].min_memory_mb);
    try std.testing.expectEqual(@as(?u32, 4096), decoded.value.instances[0].max_memory_mb);
}

test "instance heap endpoints and effective maximum are validated together" {
    var instance: Instance = .{ .id = "world", .name = "World", .minecraft_version = "1.21" };
    var doc: Document = .{ .instances = (&instance)[0..1] };
    for ([_]u32{ 0, min_memory_mb - 1, max_memory_mb + 1 }) |invalid| {
        instance.min_memory_mb = invalid;
        try std.testing.expectError(error.InvalidMemory, validate(doc));
        instance.min_memory_mb = null;
        instance.max_memory_mb = invalid;
        try std.testing.expectError(error.InvalidMemory, validate(doc));
        instance.max_memory_mb = null;
    }
    instance.min_memory_mb = min_memory_mb;
    instance.max_memory_mb = min_memory_mb;
    try validate(doc);
    instance.min_memory_mb = max_memory_mb;
    instance.max_memory_mb = max_memory_mb;
    try validate(doc);
    instance.min_memory_mb = 4096;
    instance.max_memory_mb = 2048;
    try std.testing.expectError(error.InvalidMemory, validate(doc));
    instance.max_memory_mb = null;
    try std.testing.expectError(error.InvalidMemory, validate(doc));
    doc.settings.default_memory_mb = 4096;
    try validate(doc);
    instance.min_memory_mb = null;
    doc.settings.default_memory_mb = 2048;
    try validate(doc);
}

test "reducing global heap maximum preserves persisted instances when minimum would exceed it" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try Store.init(a, io, root);
    defer store.deinit();
    try store.update(.{
        .settings = .{ .default_memory_mb = 4096 },
        .instances = &.{.{ .id = "world", .name = "World", .minecraft_version = "1.21", .min_memory_mb = 3072 }},
    });
    const before = try tmp.dir.readFileAlloc(io, ".vela/config.json", a, .limited(max_json));
    defer a.free(before);
    var reduced = store.snapshot().*;
    reduced.settings.default_memory_mb = 2048;
    try std.testing.expectError(error.InvalidMemory, store.update(reduced));
    try std.testing.expectEqual(@as(u32, 4096), store.snapshot().settings.default_memory_mb);
    try std.testing.expectEqual(@as(?u32, 3072), store.snapshot().instances[0].min_memory_mb);
    const after = try tmp.dir.readFileAlloc(io, ".vela/config.json", a, .limited(max_json));
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    var explicit = reduced.instances[0];
    explicit.max_memory_mb = 4096;
    reduced.instances = (&explicit)[0..1];
    try store.update(reduced);
    try std.testing.expectEqual(@as(u32, 2048), store.snapshot().settings.default_memory_mb);
    try store.reconcile();
    const reloaded = &store;
    try std.testing.expectEqual(@as(?u32, 3072), reloaded.snapshot().instances[0].min_memory_mb);
    try std.testing.expectEqual(@as(?u32, 4096), reloaded.snapshot().instances[0].max_memory_mb);
}

test "validation bounds versions names and namespaces" {
    try validate(sample);
    try validate(.{ .settings = .{ .default_memory_mb = min_memory_mb, .download_connections = 1 } });
    try validate(.{ .settings = .{ .default_memory_mb = max_memory_mb, .download_connections = 64 } });
    for ([_]u32{ 0, min_memory_mb - 1, max_memory_mb + 1 }) |memory| try std.testing.expectError(error.InvalidMemory, validate(.{ .settings = .{ .default_memory_mb = memory } }));
    for ([_]u16{ 0, 65 }) |connections| try std.testing.expectError(error.InvalidDownloadConnections, validate(.{ .settings = .{ .download_connections = connections } }));
    var instance = sample.instances[0];
    var doc = sample;
    doc.instances = (&instance)[0..1];
    instance.minecraft_version = "";
    try std.testing.expectError(error.InvalidMinecraftVersion, validate(doc));
    instance = sample.instances[0];
    instance.loader_version = null;
    try std.testing.expectError(error.InvalidLoaderVersion, validate(doc));
    for ([_]Loader{ .fabric, .forge, .neoforge, .quilt }) |loader| {
        instance.loader = loader;
        try std.testing.expectError(error.InvalidLoaderVersion, validate(doc));
    }
    instance.loader = .vanilla;
    try validate(doc);
    instance.loader_version = "";
    try std.testing.expectError(error.InvalidLoaderVersion, validate(doc));
    instance = sample.instances[0];
    instance.name = "../unsafe";
    try std.testing.expectError(error.InvalidInstanceName, validate(doc));
    instance = sample.instances[0];
    instance.max_memory_mb = 1;
    try std.testing.expectError(error.InvalidMemory, validate(doc));
    instance = sample.instances[0];
    instance.java_path = "";
    try std.testing.expectError(error.InvalidJavaPath, validate(doc));
    instance = sample.instances[0];
    instance.origin.?.project_id = "";
    try std.testing.expectError(error.InvalidOrigin, validate(doc));
    instance = sample.instances[0];
    instance.id = "CON";
    try std.testing.expectError(error.InvalidId, validate(doc));
    var instances = [_]Instance{ sample.instances[0], sample.instances[0] };
    instances[1].id = "GAME";
    instances[1].name = "Other";
    try std.testing.expectError(error.DuplicateId, validate(.{ .instances = &instances }));
    instances[1].id = "other";
    instances[1].name = "my world";
    try std.testing.expectError(error.DuplicateInstanceName, validate(.{ .instances = &instances }));
    var servers = [_]Server{ sample.servers[0], sample.servers[0] };
    servers[1].id = "GAME";
    try std.testing.expectError(error.DuplicateId, validate(.{ .instances = sample.instances, .servers = &servers }));
    var accounts = [_]Account{ sample.accounts[0], sample.accounts[0] };
    accounts[1].id = "GAME";
    try std.testing.expectError(error.DuplicateId, validate(.{ .accounts = &accounts }));
}

test "bindings selections and server ports must be valid" {
    var server = sample.servers[0];
    var doc = sample;
    doc.servers = (&server)[0..1];
    server.port = 0;
    try std.testing.expectError(error.InvalidServerPort, validate(doc));
    server.port = 65535;
    try validate(doc);
    server.instance_id = "missing";
    try std.testing.expectError(error.DanglingServerInstance, validate(doc));
    server.instance_id = "GAME";
    try std.testing.expectError(error.DanglingServerInstance, validate(doc));
    server.instance_id = null;
    doc.instances = &.{};
    doc.selected_instance = null;
    try validate(doc);
    const bytes = try serialize(std.testing.allocator, doc);
    defer std.testing.allocator.free(bytes);
    var parsed = try parse(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.servers[0].instance_id == null);
    try std.testing.expectEqualStrings(doc.selected_server.?, parsed.value.selected_server.?);
    doc = sample;
    doc.servers = (&server)[0..1];
    server = sample.servers[0];
    server.address = "https://example.com";
    try std.testing.expectError(error.InvalidServerAddress, validate(doc));
    doc = sample;
    doc.selected_instance = "missing";
    try std.testing.expectError(error.InvalidSelectedInstance, validate(doc));
    doc = sample;
    doc.selected_account = "missing";
    try std.testing.expectError(error.InvalidSelectedAccount, validate(doc));
    doc = sample;
    doc.selected_server = "missing";
    try std.testing.expectError(error.InvalidSelectedServer, validate(doc));
}

test "write failure and validation failure preserve borrowed snapshot" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try Store.init(a, io, root);
    defer store.deinit();
    try store.update(sample);
    const old = store.snapshot();
    const old_name = old.instances[0].name;
    try std.testing.expectError(error.InvalidSelectedInstance, store.update(.{ .selected_instance = "missing" }));
    try std.testing.expect(old.instances[0].name.ptr == old_name.ptr);
    try std.testing.expect(!store.publicationUncertain());
    // Block replacement after the temporary file has been written and synced.
    try tmp.dir.rename(".vela/config.json", tmp.dir, ".vela/previous.json", io);
    try tmp.dir.createDir(io, ".vela/config.json", .default_dir);
    if (store.update(.{})) |_| return error.ExpectedWriteFailure else |_| {}
    try std.testing.expect(store.publicationUncertain());
    try std.testing.expectEqualStrings("My World", old.instances[0].name);
    try std.testing.expect(old.instances[0].name.ptr == old_name.ptr);
    const backup = try tmp.dir.readFileAlloc(io, ".vela/previous.json", a, .limited(max_json));
    defer a.free(backup);
    const expected = try serialize(a, sample);
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, backup);
}

test "invalid existing files are preserved without fallback or rewriting" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    try tmp.dir.createDir(io, ".vela", .default_dir);
    for ([_][]const u8{
        "",                                                                                                                                        "{broken",                                                  "[]",                                         "{}",                                          "{\"schema_version\":0}",
        "{\"schema_version\":1,\"settings\":{\"default_memory_mb\":0}}",                                                                           "{\"schema_version\":1,\"selected_instance\":\"missing\"}", "{\"schema_version\":1,\"unknown_field\":1}", "{\"schema_version\":1,\"schema_version\":1}", "{\"schema_version\":1,\"accounts\":[{\"id\":\"p\",\"name\":\"P\",\"uuid\":\"u\",\"access_token\":\"not-a-real-token\"}]}",
        "{\"schema_version\":1,\"servers\":[{\"id\":\"s\",\"name\":\"S\",\"address\":\"localhost\",\"port\":65536,\"instance_id\":\"missing\"}]}",
    }) |bad| {
        try tmp.dir.writeFile(io, .{ .sub_path = ".vela/config.json", .data = bad });
        if (Store.init(a, io, root)) |loaded| {
            var unexpected = loaded;
            unexpected.deinit();
            return error.ExpectedLoadFailure;
        } else |_| {}
        const after = try tmp.dir.readFileAlloc(io, ".vela/config.json", a, .limited(max_json));
        defer a.free(after);
        try std.testing.expectEqualStrings(bad, after);
    }
}

test "unknown schema is rejected before newer fields and remains untouched" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    try tmp.dir.createDir(io, ".vela", .default_dir);
    const newer = "{\"schema_version\":2,\"settings\":{\"game_exit_behavior\":\"new_behavior\"},\"new_field\":true}";
    try tmp.dir.writeFile(io, .{ .sub_path = ".vela/config.json", .data = newer });
    try std.testing.expectError(error.UnsupportedSchemaVersion, Store.init(a, io, root));
    const after = try tmp.dir.readFileAlloc(io, ".vela/config.json", a, .limited(max_json));
    defer a.free(after);
    try std.testing.expectEqualStrings(newer, after);
    try std.testing.expectError(error.UnsupportedSchemaVersion, validate(.{ .schema_version = 2 }));
}

// Keep the real Io userdata: untouched callbacks still reach the real temp FS.
// A thread-local owner instruments only the callbacks used by these serial tests.
const SaveFaultIo = struct {
    threadlocal var active: ?*SaveFaultIo = null;
    real: std.Io = std.testing.io,
    vtable: std.Io.VTable = undefined,
    creates: usize = 0,
    writes: usize = 0,
    renames: usize = 0,
    syncs: usize = 0,
    fail_sync: ?usize = null,
    deny_read: bool = false,

    fn start(self: *SaveFaultIo) std.Io {
        std.debug.assert(active == null);
        active = self;
        self.vtable = self.real.vtable.*;
        self.vtable.dirCreateFile = create;
        self.vtable.dirOpenFile = open;
        self.vtable.dirRename = rename;
        self.vtable.fileSync = sync;
        self.vtable.operate = operate;
        return .{ .userdata = self.real.userdata, .vtable = &self.vtable };
    }

    fn stop(self: *SaveFaultIo) void {
        std.debug.assert(active == self);
        active = null;
    }

    fn reset(self: *SaveFaultIo) void {
        self.creates = 0;
        self.writes = 0;
        self.renames = 0;
        self.syncs = 0;
        self.fail_sync = null;
        self.deny_read = false;
    }

    fn create(ctx: ?*anyopaque, dir: Dir, path: []const u8, options: Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
        const self = active.?;
        self.creates += 1;
        return self.real.vtable.dirCreateFile(ctx, dir, path, options);
    }

    fn open(ctx: ?*anyopaque, dir: Dir, path: []const u8, options: Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
        const self = active.?;
        if (self.deny_read) return error.AccessDenied;
        return self.real.vtable.dirOpenFile(ctx, dir, path, options);
    }

    fn rename(ctx: ?*anyopaque, old_dir: Dir, old_path: []const u8, new_dir: Dir, new_path: []const u8) Dir.RenameError!void {
        const self = active.?;
        self.renames += 1;
        return self.real.vtable.dirRename(ctx, old_dir, old_path, new_dir, new_path);
    }

    fn sync(ctx: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        const self = active.?;
        self.syncs += 1;
        if (self.fail_sync == self.syncs) return error.InputOutput;
        return self.real.vtable.fileSync(ctx, file);
    }

    fn operate(ctx: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const self = active.?;
        switch (operation) {
            .file_write_streaming => self.writes += 1,
            else => {},
        }
        return self.real.vtable.operate(ctx, operation);
    }

    fn expectBlocked(self: *SaveFaultIo, store: *Store) !void {
        const creates = self.creates;
        const writes = self.writes;
        const renames = self.renames;
        // Even invalid drafts are rejected before validation or any IO.
        try std.testing.expectError(error.ConfigPublicationUncertain, store.update(.{ .selected_instance = "missing" }));
        try std.testing.expectError(error.ConfigPublicationUncertain, store.update(store.snapshot().*));
        try std.testing.expectEqual(creates, self.creates);
        try std.testing.expectEqual(writes, self.writes);
        try std.testing.expectEqual(renames, self.renames);
        try std.testing.expect(store.publicationUncertain());
    }
};

test "save failures before commit and after rename block all stale updates until disk reconciliation" {
    const a = std.testing.allocator;
    for ([_]usize{ 1, 3 }) |failure| {
        if (builtin.os.tag == .windows and failure == 3) continue;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);
        defer a.free(root);
        var fault: SaveFaultIo = .{};
        const io = fault.start();
        defer fault.stop();
        var store = try Store.init(a, io, root);
        defer store.deinit();
        try store.update(.{});
        const old = store.snapshot();
        const old_client = old.settings.microsoft_client_id;
        fault.reset();
        fault.fail_sync = failure;
        try std.testing.expectError(error.InputOutput, store.update(sample));
        try std.testing.expectEqual(@as(usize, if (failure == 3) 1 else 0), fault.renames);
        try std.testing.expectEqual(@as(usize, 0), old.instances.len);
        try std.testing.expect(old.settings.microsoft_client_id.ptr == old_client.ptr);
        const bytes = try tmp.dir.readFileAlloc(std.testing.io, ".vela/config.json", a, .limited(max_json));
        defer a.free(bytes);
        const disk = try parse(a, bytes);
        defer disk.deinit();
        try std.testing.expectEqual(@as(usize, if (failure == 3) 1 else 0), disk.value.instances.len);
        try fault.expectBlocked(&store);

        // Recovery uses current disk bytes, not old memory or the attempted sample.
        const authoritative = "{\"schema_version\":1,\"settings\":{\"download_connections\":7}}\n";
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".vela/config.json", .data = authoritative });
        fault.reset();
        try store.reconcile();
        try std.testing.expect(!store.publicationUncertain());
        try std.testing.expectEqual(@as(u16, 7), store.snapshot().settings.download_connections);
        try std.testing.expectEqual(@as(usize, 1), fault.renames);
        try std.testing.expect(fault.writes > 0);
        const confirmed = try tmp.dir.readFileAlloc(std.testing.io, ".vela/config.json", a, .limited(max_json));
        defer a.free(confirmed);
        try std.testing.expectEqualStrings(authoritative, confirmed);
        try store.update(sample);
        try std.testing.expectEqualStrings("My World", store.snapshot().instances[0].name);
    }
}

test "failed reconcile publication retains old memory and barrier despite authoritative new disk" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var fault: SaveFaultIo = .{};
    const io = fault.start();
    defer fault.stop();
    var store = try Store.init(a, io, root);
    defer store.deinit();
    try store.update(.{});
    fault.reset();
    fault.fail_sync = 3;
    try std.testing.expectError(error.InputOutput, store.update(sample));
    const old = store.snapshot();
    for ([_]usize{ 1, 3 }) |failure| {
        fault.reset();
        fault.fail_sync = failure;
        try std.testing.expectError(error.InputOutput, store.reconcile());
        try std.testing.expectEqual(@as(usize, 0), old.instances.len);
        try fault.expectBlocked(&store);
        const bytes = try tmp.dir.readFileAlloc(std.testing.io, ".vela/config.json", a, .limited(max_json));
        defer a.free(bytes);
        const disk = try parse(a, bytes);
        defer disk.deinit();
        try std.testing.expectEqualStrings("My World", disk.value.instances[0].name);
    }
    fault.reset();
    try store.reconcile();
    try std.testing.expect(!store.publicationUncertain());
    try std.testing.expectEqualStrings("My World", store.snapshot().instances[0].name);
}

test "reconcile rejects missing nonregular invalid oversized and unreadable disk without writes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var fault: SaveFaultIo = .{};
    const io = fault.start();
    defer fault.stop();
    var store = try Store.init(a, io, root);
    defer store.deinit();
    const old = store.snapshot();
    fault.reset(); // init may create only the persistent writer lock.
    // Explicit reconciliation is not a defaults initialization path.
    try std.testing.expect(!store.publicationUncertain());
    try std.testing.expectError(error.FileNotFound, store.reconcile());
    try fault.expectBlocked(&store);
    try tmp.dir.createDir(std.testing.io, ".vela", .default_dir);
    try tmp.dir.createDir(std.testing.io, ".vela/config.json", .default_dir);
    try std.testing.expectError(error.InvalidConfigFile, store.reconcile());
    try tmp.dir.deleteDir(std.testing.io, ".vela/config.json");
    for ([_][]const u8{ "", "{broken", "[]", "{}", "{\"schema_version\":2}", "{\"schema_version\":1,\"selected_instance\":\"missing\"}" }) |bad| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".vela/config.json", .data = bad });
        if (store.reconcile()) |_| return error.ExpectedLoadFailure else |_| {}
        try std.testing.expectEqual(@as(usize, 0), old.instances.len);
        const after = try tmp.dir.readFileAlloc(std.testing.io, ".vela/config.json", a, .limited(max_json));
        defer a.free(after);
        try std.testing.expectEqualStrings(bad, after);
        try fault.expectBlocked(&store);
    }
    const oversized = try tmp.dir.createFile(std.testing.io, ".vela/config.json", .{});
    defer oversized.close(std.testing.io);
    try oversized.setLength(std.testing.io, max_json + 1);
    try std.testing.expectError(error.ConfigTooLarge, store.reconcile());
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".vela/config.json", .data = "{\"schema_version\":1}" });
    fault.deny_read = true;
    try std.testing.expectError(error.AccessDenied, store.reconcile());
    try fault.expectBlocked(&store);
    try std.testing.expectEqual(@as(usize, 0), fault.creates);
    try std.testing.expectEqual(@as(usize, 0), fault.writes);
    try std.testing.expectEqual(@as(usize, 0), fault.renames);
    fault.reset();
    try store.reconcile();
    try std.testing.expect(!store.publicationUncertain());
}

fn configAllocationFailures(a: Allocator, reconcile: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer std.testing.allocator.free(root);
    var fault: SaveFaultIo = .{};
    const io = fault.start();
    defer fault.stop();
    var store = try Store.init(std.testing.allocator, io, root);
    defer store.deinit();
    try store.update(.{});
    if (reconcile) {
        const bytes = try serialize(std.testing.allocator, sample);
        defer std.testing.allocator.free(bytes);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".vela/config.json", .data = bytes });
        store.publication_uncertain = true;
    }
    const old_client = store.snapshot().settings.microsoft_client_id;
    fault.reset();
    // Root/path retain their original allocator; parsed arenas own theirs.
    store.a = a;
    defer store.a = std.testing.allocator;
    const result = if (reconcile) store.reconcile() else store.update(sample);
    result catch |err| {
        try std.testing.expectError(error.OutOfMemory, result);
        try std.testing.expect(store.snapshot().settings.microsoft_client_id.ptr == old_client.ptr);
        try std.testing.expectEqual(reconcile, store.publicationUncertain());
        try std.testing.expectEqual(@as(usize, 0), fault.creates);
        try std.testing.expectEqual(@as(usize, 0), fault.writes);
        try std.testing.expectEqual(@as(usize, 0), fault.renames);
        return err;
    };
    try std.testing.expect(!store.publicationUncertain());
    try std.testing.expectEqualStrings("My World", store.snapshot().instances[0].name);
}

test "update preparation and reconcile allocation failures clean up without publishing" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, configAllocationFailures, .{false});
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, configAllocationFailures, .{true});
}

test "CurseForge reference settings default validate clone and roundtrip" {
    const a = std.testing.allocator;
    const defaults = try initDefaults(a);
    defer defaults.deinit();
    try std.testing.expect(defaults.value.settings.curseforge_credential_ref == null);
    try std.testing.expect(!defaults.value.settings.curseforge_terms_approved);
    for ([_][]const u8{ "", "vault:plain", "0123456789ABCDEF0123456789ABCDEF", "0123456789abcdef0123456789abcdeg", "0123456789abcdef0123456789abcdef0" }) |ref| {
        try std.testing.expectError(error.InvalidCredentialRef, validate(.{ .settings = .{ .curseforge_credential_ref = ref } }));
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try Store.init(a, std.testing.io, root);
    defer store.deinit();
    var reference = "0123456789abcdef0123456789abcdef".*;
    try store.update(.{ .settings = .{ .curseforge_enabled = true, .curseforge_terms_approved = true, .curseforge_credential_ref = &reference } });
    @memset(&reference, 'x');
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", store.snapshot().settings.curseforge_credential_ref.?);
    try store.reconcile();
    const loaded = &store;
    try std.testing.expect(loaded.snapshot().settings.curseforge_enabled);
    try std.testing.expect(loaded.snapshot().settings.curseforge_terms_approved);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", loaded.snapshot().settings.curseforge_credential_ref.?);
}

const WindowsConfigFake = @import("auth_cleanup_test.zig").WindowsFake;
fn windowsConfig(allocator: Allocator, fake: *WindowsConfigFake) !Store {
    var owned: ?windows_fs.Root = try windows_fs.openRootWithOps(allocator, "C:/owned/launcher", .ordinary_config, fake.nativeOps());
    return Store.initWithOwnedRoot(allocator, std.testing.io, &owned);
}

test "Windows config init is read only and preparation creates only storage directory" {
    const a = std.testing.allocator;
    var fake: WindowsConfigFake = .{ .directory_exists = false };
    var store = try windowsConfig(a, &fake);
    defer store.deinit();
    try std.testing.expect(!store.snapshot().settings.curseforge_enabled and !fake.directory_exists);
    try std.testing.expect(fake.ensures == 0 and fake.creates == 0 and fake.moves == 0);
    try store.prepareStorage();
    try std.testing.expect(fake.directory_exists and !fake.present and fake.ensures == 1);
    try std.testing.expect(fake.creates == 0 and fake.moves == 0);
    var missing: WindowsConfigFake = .{ .base_exists = false };
    try std.testing.expectError(error.InvalidRoot, windowsConfig(a, &missing));
    try std.testing.expect(missing.opens == 0 and missing.ensures == 0 and missing.creates == 0);
    var relative: WindowsConfigFake = .{};
    try std.testing.expectError(error.InvalidRoot, windows_fs.openRootWithOps(a, "relative", .ordinary_config, relative.nativeOps()));
    try std.testing.expect(relative.opens == 0 and relative.ensures == 0);
    var ordinary: WindowsConfigFake = .{ .directory_private = false, .file_private = false };
    ordinary.seed("{\"schema_version\":1}");
    var inherited = try windowsConfig(a, &ordinary);
    defer inherited.deinit();
    try inherited.prepareStorage();
    try std.testing.expect(!ordinary.directory_private and !ordinary.file_private and ordinary.creates == 0);
}

test "Windows config directory uncertainty and inherited poison gate bootstrap writes" {
    const a = std.testing.allocator;
    var fake: WindowsConfigFake = .{ .directory_exists = false, .failure = .ensure_after };
    var store = try windowsConfig(a, &fake);
    defer store.deinit();
    try std.testing.expectError(error.CommitUncertain, store.prepareStorage());
    try std.testing.expect(store.publicationUncertain() and store.windows_root.?.publication_uncertain);
    try std.testing.expect(fake.directory_exists and !fake.present and fake.creates == 0);
    try std.testing.expectError(error.ConfigPublicationUncertain, store.update(.{}));
    try std.testing.expectError(error.ConfigPublicationUncertain, store.prepareStorage());
    fake.failure = .none;
    try std.testing.expectError(error.FileNotFound, store.reconcile());
    try std.testing.expect(store.publicationUncertain() and store.windows_root.?.publication_uncertain);
    var other: WindowsConfigFake = .{};
    var owned: ?windows_fs.Root = try windows_fs.openRootWithOps(a, "C:/owned/launcher", .ordinary_config, other.nativeOps());
    owned.?.publication_uncertain = true;
    var poisoned = try Store.initWithOwnedRoot(a, std.testing.io, &owned);
    defer poisoned.deinit();
    try std.testing.expect(owned == null and poisoned.publicationUncertain());
    try std.testing.expectError(error.ConfigPublicationUncertain, poisoned.prepareStorage());
    try std.testing.expect(other.ensures == 0 and other.creates == 0);
}

test "Windows config save failures preserve snapshot until exact disk reconciliation" {
    const a = std.testing.allocator;
    for (0..4) |which| {
        var fake: WindowsConfigFake = .{};
        var store = try windowsConfig(a, &fake);
        defer store.deinit();
        try store.update(.{});
        const prior = store.state.arena;
        if (which == 0) fake.failure = .write;
        if (which == 1) fake.failure = .move_after;
        if (which == 2) fake.failure = .final_flush;
        if (which == 3) fake.cancel_after_move = true;
        try std.testing.expectError(if (which == 0) error.PersistenceFailure else error.CommitUncertain, store.update(.{ .settings = .{ .curseforge_enabled = true } }));
        try std.testing.expect(prior == store.state.arena and !store.snapshot().settings.curseforge_enabled);
        try std.testing.expect(store.publicationUncertain() and !fake.temp_open);
        try std.testing.expectError(error.ConfigPublicationUncertain, store.update(.{}));
        fake.failure = .none;
        fake.cancel_after_move = false;
        fake.cancelled = false;
        const disk = try a.dupe(u8, fake.diskBytes());
        defer a.free(disk);
        try store.reconcile();
        try std.testing.expectEqualStrings(disk, fake.diskBytes());
        try std.testing.expect(!store.publicationUncertain() and !store.windows_root.?.publication_uncertain);
        try std.testing.expectEqual(which != 0, store.snapshot().settings.curseforge_enabled);
    }
}

test "Windows config failed reconciliation retains both barriers and exact authoritative bytes" {
    const a = std.testing.allocator;
    for (0..7) |which| {
        var fake: WindowsConfigFake = .{};
        var store = try windowsConfig(a, &fake);
        defer store.deinit();
        try store.update(.{});
        const next = try serialize(a, .{ .settings = .{ .curseforge_enabled = true } });
        defer a.free(next);
        const disk = try std.fmt.allocPrint(a, "  {s}  ", .{next});
        defer a.free(disk);
        fake.seed(disk);
        const prior = store.state.arena;
        if (which == 0 or which == 6) {
            fake.drift_at_load = fake.load_count + (if (which == 0) @as(usize, 2) else 3);
            fake.drift_bytes = "{\"schema_version\":1}";
        }
        if (which == 1) fake.present = false;
        if (which == 2) fake.seed("{broken");
        if (which == 3) fake.hardlink = true;
        if (which == 4) fake.fail_load_at = fake.load_count + 1;
        if (which == 5) fake.failure = .final_flush;
        if (store.reconcile()) |_| return error.TestUnexpectedSuccess else |_| {}
        try std.testing.expect(prior == store.state.arena and !store.snapshot().settings.curseforge_enabled);
        try std.testing.expect(store.publicationUncertain() and store.windows_root.?.publication_uncertain and !fake.temp_open);
        try std.testing.expectError(error.ConfigPublicationUncertain, store.update(.{}));
        fake.drift_at_load = 0;
        fake.hardlink = false;
        fake.fail_load_at = 0;
        fake.failure = .none;
        fake.seed(disk);
        try store.reconcile();
        try std.testing.expect(store.snapshot().settings.curseforge_enabled and !store.publicationUncertain());
        try std.testing.expectEqualStrings(disk, fake.diskBytes());
    }
}

test "Windows config init consumes root on parser security limit load and privacy failures" {
    const a = std.testing.allocator;
    for (0..5) |which| {
        var fake: WindowsConfigFake = .{};
        fake.seed(if (which == 0) "{broken" else "{\"schema_version\":1}");
        if (which == 1) fake.hardlink = true;
        if (which == 2) fake.disk_len = max_json + 1;
        if (which == 3) fake.fail_load_at = 1;
        var owned: ?windows_fs.Root = try windows_fs.openRootWithOps(a, "C:/owned/launcher", if (which == 4) .private_journal else .ordinary_config, fake.nativeOps());
        if (Store.initWithOwnedRoot(a, std.testing.io, &owned)) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.TestUnexpectedSuccess;
        } else |err| {
            if (which == 1) try std.testing.expectEqual(error.InsecureJournal, err);
            if (which == 2) try std.testing.expectEqual(error.ConfigTooLarge, err);
            if (which == 3) try std.testing.expectEqual(error.PersistenceFailure, err);
            if (which == 4) try std.testing.expectEqual(error.InvalidRoot, err);
        }
        try std.testing.expect(owned == null and fake.closes == 1 and fake.creates == 0 and fake.ensures == 0);
    }
}

fn windowsConfigAllocationScenario(allocator: Allocator) !void {
    var fake: WindowsConfigFake = .{};
    defer std.debug.assert(fake.opens == fake.closes and !fake.temp_open);
    var store = try windowsConfig(allocator, &fake);
    defer store.deinit();
    try store.prepareStorage();
    try store.update(.{ .settings = .{ .curseforge_enabled = true } });
    try store.reconcile();
}
test "Windows config allocation failures release roots snapshots and staging" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, windowsConfigAllocationScenario, .{});
}

test "root writer excludes aliases and stale credential owners until close" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var first = try Store.init(a, io, root);
    var first_open = true;
    defer if (first_open) first.deinit();
    const reference = "0123456789abcdef0123456789abcdef";
    try first.update(.{ .settings = .{ .curseforge_credential_ref = reference } });
    try std.testing.expectError(error.LauncherRootInUse, Store.init(a, io, root));
    if (builtin.os.tag == .linux) try testOtherProcessLock(root, first.writer.?.file.handle, true);
    const alias = try std.fmt.allocPrint(a, "{s}/./", .{root});
    defer a.free(alias);
    try std.testing.expectError(error.LauncherRootInUse, Store.init(a, io, alias));
    var removed = first.snapshot().*;
    removed.settings.curseforge_credential_ref = null;
    removed.settings.download_connections = 19;
    try first.update(removed);
    // No stale owner exists while cleanup removes this reference from its vault.
    try std.testing.expectError(error.LauncherRootInUse, Store.init(a, io, root));
    first.deinit();
    first_open = false;
    if (builtin.os.tag == .linux) try testOtherProcessLock(root, null, false);
    var second = try Store.init(a, io, root);
    defer second.deinit();
    try std.testing.expect(second.snapshot().settings.curseforge_credential_ref == null);
    try std.testing.expectEqual(@as(u16, 19), second.snapshot().settings.download_connections);
    var unrelated = second.snapshot().*;
    unrelated.settings.default_memory_mb = 4096;
    try second.update(unrelated);
    try second.reconcile();
    try std.testing.expect(second.snapshot().settings.curseforge_credential_ref == null);
    try std.testing.expectEqual(@as(u16, 19), second.snapshot().settings.download_connections);
}

test "Windows config writer contention consumes capability before loading and releases on failure" {
    var busy: WindowsConfigFake = .{ .writer_in_use = true };
    try std.testing.expectError(error.LauncherRootInUse, windowsConfig(std.testing.allocator, &busy));
    try std.testing.expectEqual(@as(usize, 0), busy.load_count);
    try std.testing.expectEqual(@as(usize, 1), busy.closes);
    var bad: WindowsConfigFake = .{};
    bad.seed("invalid-json");
    if (windowsConfig(std.testing.allocator, &bad)) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.ExpectedLoadFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 1), bad.writer_acquires);
    try std.testing.expect(!bad.writer_owned and bad.closes == 1);
}

fn testOtherProcessLock(root: []const u8, inherited: ?std.posix.fd_t, blocked: bool) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ root, RootWriter.leaf }, 0);
    defer std.testing.allocator.free(path);
    const linux = std.os.linux;
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Only raw syscalls after fork: the testing Io runtime can own threads.
        if (inherited) |fd| _ = linux.close(fd);
        const opened = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(opened) != .SUCCESS) linux.exit_group(41);
        const fd: linux.fd_t = @intCast(opened);
        const result = linux.errno(linux.flock(fd, 2 | 4)); // LOCK_EX | LOCK_NB
        _ = linux.close(fd);
        linux.exit_group(if (result == (if (blocked) linux.E.AGAIN else linux.E.SUCCESS)) 0 else 42);
    }
    var status: i32 = 0;
    while (true) {
        const waited = linux.waitpid(pid, &status, 0);
        if (linux.errno(waited) == .INTR) continue;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(waited));
        try std.testing.expectEqual(@as(usize, @intCast(pid)), waited);
        break;
    }
    try std.testing.expectEqual(@as(i32, 0), status);
}

test "root writer lock substitution rejects config writes without changing snapshot" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer std.testing.allocator.free(root);
    var store = try Store.init(std.testing.allocator, std.testing.io, root);
    defer store.deinit();
    try tmp.dir.rename(RootWriter.leaf, tmp.dir, "old-writer-lock", std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = RootWriter.leaf, .data = "" });
    try std.testing.expectError(error.RootWriterLockChanged, store.update(.{ .settings = .{ .download_connections = 17 } }));
    try std.testing.expectEqual(@as(u16, 8), store.snapshot().settings.download_connections);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".vela/config.json", .{}));
}

test "appearance owns its image path and survives settings updates and reload" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try Store.init(a, io, root);
    defer store.deinit();
    const image_path = try a.dupe(u8, ".vela/backgrounds/背景.webp");
    defer a.free(image_path);
    try store.update(.{ .appearance = .{ .preset = .mist, .background_mode = .image, .background_color = 0x192129, .image_path = image_path, .image_layout = .fit, .image_blur = 8, .image_dimming = 35, .corner_radius = 20, .panel_opacity = 75, .panel_blur = 8 } });
    @memset(image_path, 'x');
    try std.testing.expectEqualStrings(".vela/backgrounds/背景.webp", store.snapshot().appearance.image_path.?);
    var next = store.snapshot().*;
    next.settings.download_connections = 17;
    try store.update(next);
    try store.reconcile();
    const saved = store.snapshot();
    try std.testing.expectEqual(appearance.Preset.mist, saved.appearance.preset);
    try std.testing.expectEqual(appearance.BackgroundMode.image, saved.appearance.background_mode);
    try std.testing.expectEqual(@as(u32, 0x192129), saved.appearance.background_color);
    try std.testing.expectEqualStrings(".vela/backgrounds/背景.webp", saved.appearance.image_path.?);
    try std.testing.expectEqual(appearance.ImageLayout.fit, saved.appearance.image_layout);
    try std.testing.expectEqual(@as(u8, 8), saved.appearance.image_blur);
    try std.testing.expectEqual(@as(u8, 35), saved.appearance.image_dimming);
    try std.testing.expectEqual(@as(u8, 20), saved.appearance.corner_radius);
    try std.testing.expectEqual(@as(u8, 75), saved.appearance.panel_opacity);
    try std.testing.expectEqual(@as(u8, 8), saved.appearance.panel_blur);
    try std.testing.expectEqual(@as(u16, 17), saved.settings.download_connections);
}

test "first appearance save recovers its initial baseline after a staging failure" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    var store = try Store.init(a, io, root);
    defer store.deinit();
    const directory = try Dir.cwd().createDirPathOpen(io, std.fs.path.dirname(store.file).?, .{ .open_options = .{ .iterate = true } });
    defer directory.close(io);
    defer _ = std.os.linux.fchmod(directory.handle, 0o700);
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.fchmod(directory.handle, 0o555));
    const next: Document = .{ .appearance = .{ .preset = .frost } };
    try std.testing.expectError(error.AccessDenied, store.update(next));
    try std.testing.expect(store.publicationUncertain());
    try std.testing.expectEqual(appearance.Preset.moss, store.snapshot().appearance.preset);
    try std.testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, store.file, .{}));
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.fchmod(directory.handle, 0o700));
    try store.recover();
    try std.testing.expectEqual(appearance.Preset.moss, store.snapshot().appearance.preset);
    try store.update(next);
    try store.reconcile();
    try std.testing.expectEqual(appearance.Preset.frost, store.snapshot().appearance.preset);
}

test "initial baseline recovery never recreates a previously saved missing document" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    {
        var original = try Store.init(a, io, root);
        defer original.deinit();
        try original.update(.{ .appearance = .{ .preset = .frost } });
    }
    var store = try Store.init(a, io, root);
    defer store.deinit();
    try Dir.cwd().deleteFile(io, store.file);
    try std.testing.expectError(error.FileNotFound, store.recover());
    try std.testing.expect(store.publicationUncertain());
    try std.testing.expectEqual(appearance.Preset.frost, store.snapshot().appearance.preset);
}
