const std = @import("std");
const metadata = @import("metadata/root.zig");
const safe_fs = @import("../install/safe_fs.zig");
const A = std.mem.Allocator;
const Version = metadata.version.Version;
const Owned = metadata.Owned;

/// Authenticated official sources. Cache ownership belongs to the fetcher adapter.
pub const FetchOptions = struct {
    version_id: []const u8,
    manifest: metadata.manifest.Manifest,
    cancel: ?*const std.atomic.Value(bool) = null,
    limits: metadata.version.inheritance.Limits = .{},
};
/// Local instance documents only; absent documents never trigger network access.
pub const InstalledOptions = struct {
    root: []const u8 = ".minecraft",
    version_id: []const u8,
    metadata_path: ?[]const u8 = null,
    cancel: ?*const std.atomic.Value(bool) = null,
    limits: metadata.version.inheritance.Limits = .{},
};
pub const Request = struct {
    id: []const u8,
    url: []const u8,
    sha1: ?metadata.Sha1,
    size: ?u64 = null,
    max_bytes: usize,
};
pub const Fetcher = struct {
    context: ?*anyopaque = null,
    fetch: ?*const fn (context: ?*anyopaque, a: A, io: std.Io, request: Request) anyerror![]u8 = null,
};
pub const Source = struct { id: []const u8, bytes: []const u8 };
pub const Loaded = struct {
    version: Owned(Version),
    sources: Owned([]const Source),
    pub fn deinit(self: *Loaded) void {
        self.version.deinit();
        self.sources.deinit();
        self.* = undefined;
    }
};

/// Launcher identity, not the private stage used by installation.
pub const VanillaTarget = struct {
    root: []const u8,
    instance_id: []const u8,
    instance_name: []const u8,
    version_id: []const u8,
    generation: u64,
    environment: metadata.rules.Environment,
};
/// Keep the approved manifest and fetcher context frozen until preparation returns.
pub const VanillaMetadataOptions = struct {
    target: VanillaTarget,
    vanilla: FetchOptions,
    fetcher: Fetcher = .{},
};
pub const VanillaSourceBinding = struct {
    id: []const u8,
    url: []const u8,
    sha1: metadata.Sha1,
    bytes: []const u8,
};

/// Move-only owner. Keep the matcher context frozen until the worker joins.
pub const PreparedVanilla = struct {
    arena: *std.heap.ArenaAllocator,
    backing: A,
    target: VanillaTarget,
    base: Owned(Version),
    sources: []const VanillaSourceBinding,
    runtime_major: u64,
    limits: metadata.version.inheritance.Limits,
    replay_digest: [32]u8,

    pub fn deinit(self: *PreparedVanilla) void {
        self.base.deinit();
        self.arena.deinit();
        self.backing.destroy(self.arena);
        self.* = undefined;
    }

    pub fn validateBinding(self: *const PreparedVanilla, a: A, io: std.Io, target: VanillaTarget) !void {
        if (target.generation == 0 or target.generation != self.target.generation) return error.PreparedMetadataGenerationMismatch;
        try validateVanillaTarget(target);
        const root = try vanillaRoot(a, io, target.root);
        defer a.free(root);
        if (!std.mem.eql(u8, root, self.target.root) or
            !std.mem.eql(u8, target.instance_id, self.target.instance_id) or
            !std.mem.eql(u8, target.instance_name, self.target.instance_name) or
            !std.mem.eql(u8, target.version_id, self.target.version_id) or
            !sameVanillaEnvironment(target.environment, self.target.environment)) return error.PreparedMetadataMismatch;
        const digest = try vanillaDigest(a, self);
        if (!std.mem.eql(u8, &digest, &self.replay_digest)) return error.PreparedMetadataChanged;
    }

    /// Independently owned replay; no fetch, Java execution, or filesystem writes.
    pub fn replayBase(self: *const PreparedVanilla, a: A, io: std.Io, target: VanillaTarget, cancel: ?*const std.atomic.Value(bool)) !Loaded {
        try safe_fs.canceled(cancel);
        try self.validateBinding(a, io, target);
        try safe_fs.canceled(cancel);
        const parsed = try a.alloc(Owned(Version), self.sources.len);
        defer a.free(parsed);
        var count: usize = 0;
        defer for (parsed[0..count]) |*doc| doc.deinit();
        const documents = try a.alloc(Version, self.sources.len);
        defer a.free(documents);
        for (self.sources, 0..) |source, i| {
            try safe_fs.canceled(cancel);
            parsed[i] = try metadata.version.parseSlice(a, source.bytes);
            count += 1;
            documents[i] = parsed[i].value;
            if (!std.mem.eql(u8, source.id, documents[i].id)) return error.PreparedMetadataChanged;
        }
        var resolved = try metadata.version.inheritance.resolve(a, self.target.version_id, documents, self.limits);
        errdefer resolved.deinit();
        const expected = try std.json.Stringify.valueAlloc(a, self.base.value, .{});
        defer a.free(expected);
        const actual = try std.json.Stringify.valueAlloc(a, resolved.value, .{});
        defer a.free(actual);
        if (!std.mem.eql(u8, expected, actual)) return error.PreparedMetadataChanged;
        try safe_fs.canceled(cancel);
        const arena = try a.create(std.heap.ArenaAllocator);
        arena.* = .init(a);
        errdefer {
            arena.deinit();
            a.destroy(arena);
        }
        const sa = arena.allocator();
        const sources = try sa.alloc(Source, self.sources.len);
        for (self.sources, sources) |source, *copy| {
            try safe_fs.canceled(cancel);
            copy.* = .{ .id = try sa.dupe(u8, source.id), .bytes = try sa.dupe(u8, source.bytes) };
        }
        try safe_fs.canceled(cancel);
        return .{ .version = resolved, .sources = .{ .value = sources, .arena = arena, .backing = a } };
    }
};

pub fn prepareVanilla(a: A, io: std.Io, options: VanillaMetadataOptions) !PreparedVanilla {
    try safe_fs.canceled(options.vanilla.cancel);
    try validateVanillaTarget(options.target);
    if (!std.mem.eql(u8, options.target.version_id, options.vanilla.version_id)) return error.PreparedMetadataMismatch;
    const root = try vanillaRoot(a, io, options.target.root);
    defer a.free(root);
    try safe_fs.canceled(options.vanilla.cancel);
    var loaded = try fetchSources(a, io, options.vanilla, options.fetcher);
    errdefer loaded.deinit();
    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = .init(a);
    errdefer {
        arena.deinit();
        a.destroy(arena);
    }
    const sa = arena.allocator();
    var target = options.target;
    target.root = try sa.dupe(u8, root);
    target.instance_id = try sa.dupe(u8, target.instance_id);
    target.instance_name = try sa.dupe(u8, target.instance_name);
    target.version_id = try sa.dupe(u8, target.version_id);
    target.environment.os_name = try sa.dupe(u8, target.environment.os_name);
    target.environment.arch = try sa.dupe(u8, target.environment.arch);
    target.environment.os_version = try sa.dupe(u8, target.environment.os_version);
    const features = try sa.alloc(metadata.rules.Feature, target.environment.features.len);
    for (target.environment.features, features) |feature, *copy| {
        try safe_fs.canceled(options.vanilla.cancel);
        copy.* = .{ .name = try sa.dupe(u8, feature.name), .enabled = feature.enabled };
    }
    target.environment.features = features;
    const sources = try sa.alloc(VanillaSourceBinding, loaded.sources.value.len);
    for (loaded.sources.value, sources) |source, *copy| {
        try safe_fs.canceled(options.vanilla.cancel);
        const request = try trustedRequest(options.vanilla, source.id, options.vanilla.limits.max_bytes);
        // Bind the copied manifest fields to the exact bytes we approved.
        try verifyBody(source.bytes, request);
        copy.* = .{
            .id = try sa.dupe(u8, source.id),
            .url = try sa.dupe(u8, request.url),
            .sha1 = request.sha1.?,
            .bytes = try sa.dupe(u8, source.bytes),
        };
    }
    var result: PreparedVanilla = .{
        .arena = arena,
        .backing = a,
        .target = target,
        .base = loaded.version,
        .sources = sources,
        .runtime_major = metadata.version.requiredJavaMajor(loaded.version.value),
        .limits = options.vanilla.limits,
        .replay_digest = undefined,
    };
    result.replay_digest = try vanillaDigest(a, &result);
    try safe_fs.canceled(options.vanilla.cancel);
    loaded.sources.deinit();
    return result;
}

fn validateVanillaTarget(target: VanillaTarget) !void {
    if (target.generation == 0) return error.InvalidPreparationGeneration;
    try metadata.version.validateId(target.instance_id);
    try metadata.version.validateId(target.instance_name);
    try metadata.version.validateId(target.version_id);
}
fn vanillaRoot(a: A, io: std.Io, root: []const u8) ![]const u8 {
    if (root.len == 0 or std.mem.indexOfScalar(u8, root, 0) != null) return error.InvalidLauncherRoot;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    defer a.free(cwd);
    return std.fs.path.resolve(a, &.{ cwd, root });
}
fn sameVanillaEnvironment(left: metadata.rules.Environment, right: metadata.rules.Environment) bool {
    if (!std.mem.eql(u8, left.os_name, right.os_name) or !std.mem.eql(u8, left.arch, right.arch) or
        !std.mem.eql(u8, left.os_version, right.os_version) or !std.meta.eql(left.version_matcher, right.version_matcher) or
        left.features.len != right.features.len) return false;
    for (left.features, right.features) |l, r| {
        if (l.enabled != r.enabled or !std.mem.eql(u8, l.name, r.name)) return false;
    }
    return true;
}
const VanillaDigest = struct {
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    fn field(self: *VanillaDigest, bytes: []const u8) void {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        self.hash.update(&digest);
    }
    fn number(self: *VanillaDigest, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.field(&bytes);
    }
};
// Process-local mutation detection; manifest SHA1 remains the source authority.
fn vanillaDigest(a: A, prepared: *const PreparedVanilla) ![32]u8 {
    var digest: VanillaDigest = .{};
    digest.field("vela-prepared-vanilla-v1");
    const target = prepared.target;
    inline for (.{ "root", "instance_id", "instance_name", "version_id" }) |field| digest.field(@field(target, field));
    digest.number(target.generation);
    digest.field(target.environment.os_name);
    digest.field(target.environment.arch);
    digest.field(target.environment.os_version);
    digest.number(@intCast(target.environment.features.len));
    for (target.environment.features) |feature| {
        digest.field(feature.name);
        digest.number(@intFromBool(feature.enabled));
    }
    digest.number(@intFromBool(target.environment.version_matcher != null));
    if (target.environment.version_matcher) |matcher| {
        digest.number(if (matcher.context) |context| @intCast(@intFromPtr(context)) else 0);
        digest.number(@intCast(@intFromPtr(matcher.matches)));
    }
    const base = try std.json.Stringify.valueAlloc(a, prepared.base.value, .{});
    defer a.free(base);
    digest.field(base);
    const limits = try std.json.Stringify.valueAlloc(a, prepared.limits, .{});
    defer a.free(limits);
    digest.field(limits);
    digest.number(prepared.runtime_major);
    digest.number(@intCast(prepared.sources.len));
    for (prepared.sources) |source| {
        digest.field(source.id);
        digest.field(source.url);
        digest.field(&source.sha1);
        digest.field(source.bytes);
    }
    var result: [32]u8 = undefined;
    digest.hash.final(&result);
    return result;
}

pub fn docPath(a: A, root: []const u8, id: []const u8) ![]const u8 {
    try metadata.version.validateId(id);
    const filename = try std.fmt.allocPrint(a, "{s}.json", .{id});
    defer a.free(filename);
    return std.fs.path.join(a, &.{ root, "versions", id, filename });
}

/// Never reads installed versions. Every source must match the official manifest.
pub fn fetchSources(a: A, io: std.Io, options: FetchOptions, fetcher: Fetcher) !Loaded {
    return resolveDocuments(a, io, options.version_id, options.cancel, options.limits, SourceReader{ .options = options, .fetcher = fetcher });
}

/// Resolves the explicit leaf and local inheritance/jar documents without refetch.
pub fn loadInstalled(a: A, io: std.Io, options: InstalledOptions) !Loaded {
    return resolveDocuments(a, io, options.version_id, options.cancel, options.limits, InstalledReader{ .options = options });
}

const SourceReader = struct {
    options: FetchOptions,
    fetcher: Fetcher,
    fn allowsLeafId(_: SourceReader) bool {
        return false;
    }
    fn read(self: SourceReader, a: A, io: std.Io, id: []const u8, _: usize, max_bytes: usize) ![]u8 {
        const request = try trustedRequest(self.options, id, max_bytes);
        const callback = self.fetcher.fetch orelse return error.MissingVersionMetadata;
        const body = try callback(self.fetcher.context, a, io, request);
        errdefer a.free(body);
        try safe_fs.canceled(self.options.cancel);
        try verifyBody(body, request);
        return body;
    }
};
const InstalledReader = struct {
    options: InstalledOptions,
    fn allowsLeafId(self: InstalledReader) bool {
        return self.options.metadata_path != null;
    }
    fn read(self: InstalledReader, a: A, io: std.Io, id: []const u8, depth: usize, max_bytes: usize) ![]u8 {
        if (depth == 0) if (self.options.metadata_path) |path| {
            return safe_fs.read(a, io, path, max_bytes, self.options.cancel) catch |err| switch (err) {
                error.FileNotFound => error.MissingVersionMetadata,
                else => err,
            };
        };
        const path = try docPath(a, self.options.root, id);
        defer a.free(path);
        return safe_fs.read(a, io, path, max_bytes, self.options.cancel) catch |err| switch (err) {
            error.FileNotFound => error.MissingVersionMetadata,
            else => err,
        };
    }
};

fn resolveDocuments(a: A, io: std.Io, version_id: []const u8, cancel: ?*const std.atomic.Value(bool), limits: metadata.version.inheritance.Limits, reader: anytype) !Loaded {
    if (limits.max_depth == 0 or limits.max_depth > 64 or limits.max_documents == 0 or limits.max_documents > 256 or limits.max_bytes == 0 or limits.max_bytes > 64 * 1024 * 1024) return error.InvalidInheritanceLimits;
    try safe_fs.canceled(cancel);
    try metadata.version.validateId(version_id);
    var context: Context(@TypeOf(reader)) = .{ .a = a, .io = io, .cancel = cancel, .limits = limits, .reader = reader };
    defer context.deinit();
    _ = try context.visit(version_id, 0);
    try safe_fs.canceled(cancel);
    var resolved = try metadata.version.inheritance.resolve(a, context.documents[0].id, context.documents[0..context.count], limits);
    errdefer resolved.deinit();
    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = .init(a);
    errdefer {
        arena.deinit();
        a.destroy(arena);
    }
    const sa = arena.allocator();
    const sources = try sa.alloc(Source, context.count);
    for (sources, 0..) |*source, i| {
        try safe_fs.canceled(cancel);
        source.* = .{ .id = try sa.dupe(u8, context.documents[i].id), .bytes = try sa.dupe(u8, context.bytes[i]) };
    }
    return .{ .version = resolved, .sources = .{ .value = sources, .arena = arena, .backing = a } };
}

fn Context(comptime Reader: type) type {
    return struct {
        a: A,
        io: std.Io,
        cancel: ?*const std.atomic.Value(bool),
        limits: metadata.version.inheritance.Limits,
        reader: Reader,
        documents: [256]Version = undefined,
        parsed: [256]Owned(Version) = undefined,
        bytes: [256][]u8 = undefined,
        done: [256]bool = undefined,
        heights: [256]usize = undefined,
        count: usize = 0,
        raw_bytes: usize = 0,

        fn deinit(self: *@This()) void {
            for (0..self.count) |i| {
                self.parsed[i].deinit();
                self.a.free(self.bytes[i]);
            }
        }

        fn visit(self: *@This(), id: []const u8, depth: usize) anyerror!usize {
            try safe_fs.canceled(self.cancel);
            try metadata.version.validateId(id);
            for (self.documents[0..self.count], 0..) |doc, i| {
                if (std.mem.eql(u8, id, doc.id)) {
                    if (!self.done[i]) return error.InheritanceCycle;
                    if (depth + self.heights[i] > self.limits.max_depth) return error.InheritanceDepthExceeded;
                    return self.heights[i];
                }
            }
            if (depth >= self.limits.max_depth) return error.InheritanceDepthExceeded;
            if (self.count >= self.limits.max_documents) return error.TooManyVersionDocuments;
            const max_bytes = @min(metadata.version.max_document_bytes, self.limits.max_bytes - self.raw_bytes);
            const body = try self.reader.read(self.a, self.io, id, depth, max_bytes);
            var retained = false;
            defer if (!retained) self.a.free(body);
            try safe_fs.canceled(self.cancel);
            if (body.len > max_bytes) return error.MetadataTooLarge;
            var parsed = try metadata.version.parseSlice(self.a, body);
            errdefer if (!retained) parsed.deinit();
            try metadata.version.validateId(parsed.value.id);
            if (!(depth == 0 and self.reader.allowsLeafId()) and !std.mem.eql(u8, parsed.value.id, id)) return error.VersionIdMismatch;
            const index = self.count;
            self.documents[index] = parsed.value;
            self.parsed[index] = parsed;
            self.bytes[index] = body;
            self.done[index] = false;
            self.count += 1;
            self.raw_bytes += body.len;
            retained = true;
            var height: usize = 1;
            if (parsed.value.inherits_from) |parent| height = @max(height, 1 + try self.visit(parent, depth + 1));
            if (parsed.value.jar) |jar| height = @max(height, 1 + try self.visit(jar, depth + 1));
            self.heights[index] = height;
            self.done[index] = true;
            return height;
        }
    };
}

fn trustedRequest(options: FetchOptions, id: []const u8, max_bytes: usize) !Request {
    const manifest = options.manifest;
    const entry = manifest.find(id) orelse return error.MissingVersionMetadata;
    const hash = entry.sha1 orelse return error.MissingMetadataChecksum;
    const prefixes = [_][]const u8{ "https://piston-meta.mojang.com/", "https://launchermeta.mojang.com/" };
    var path: ?[]const u8 = null;
    for (prefixes) |prefix| if (std.mem.startsWith(u8, entry.url, prefix)) {
        path = entry.url[prefix.len..];
        break;
    };
    const relative = path orelse return error.UntrustedMetadataUrl;
    if (relative.len == 0 or std.mem.indexOfAny(u8, relative, "%?#\\\r\n") != null) return error.UntrustedMetadataUrl;
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| metadata.version.validateId(part) catch return error.UntrustedMetadataUrl;
    return .{ .id = id, .url = entry.url, .sha1 = hash, .max_bytes = max_bytes };
}

fn verifyBody(body: []const u8, request: Request) !void {
    if (body.len > request.max_bytes) return error.MetadataTooLarge;
    if (request.size) |size| if (body.len != size) return error.SizeMismatch;
    if (request.sha1) |expected| {
        var digest: metadata.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(body, &digest, .{});
        if (!std.mem.eql(u8, &digest, &expected)) {
            if (!@import("builtin").is_test) std.log.scoped(.minecraft_metadata).warn("SHA-1 mismatch for version {s}: expected={s}, actual={s}, bytes={d}", .{ request.id, std.fmt.bytesToHex(expected, .lower), std.fmt.bytesToHex(digest, .lower), body.len });
            return error.ChecksumMismatch;
        }
    }
}

const fixture_base =
    "{\"id\":\"base\",\"mainClass\":\"Main\",\"downloads\":{\"client\":{\"url\":\"https://example.invalid/base.jar\"}}}";
const fixture_leaf =
    "{\"id\":\"leaf\",\"inheritsFrom\":\"base\",\"jar\":\"jar\"}";
const fixture_jar =
    "{\"id\":\"jar\",\"downloads\":{\"client\":{\"url\":\"https://example.invalid/real.jar\"}}}";

fn fixtureWrite(a: A, io: std.Io, root: []const u8, id: []const u8, bytes: []const u8) !void {
    const path = try docPath(a, root, id);
    defer a.free(path);
    try safe_fs.writeAtomic(a, io, path, bytes, null);
}

test "loader local inheritance and explicit jar own every source independently" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try fixtureWrite(a, io, root, "base", fixture_base);
    try fixtureWrite(a, io, root, "leaf", fixture_leaf);
    try fixtureWrite(a, io, root, "jar", fixture_jar);
    var loaded = try loadInstalled(a, io, .{ .root = root, .version_id = "leaf" });
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 3), loaded.sources.value.len);
    try std.testing.expectEqualStrings("Main", loaded.version.value.main_class.?);
    try std.testing.expectEqualStrings("jar", loaded.version.value.jar.?);
    try std.testing.expectEqualStrings(fixture_leaf, loaded.sources.value[0].bytes);
    loaded.version.deinit();
    loaded.version = try metadata.version.parseSlice(a, fixture_base);
    try std.testing.expectEqualStrings("leaf", loaded.sources.value[0].id);
    try std.testing.expectError(error.InheritanceDepthExceeded, loadInstalled(a, io, .{ .root = root, .version_id = "leaf", .limits = .{ .max_depth = 1 } }));
    try std.testing.expectError(error.TooManyVersionDocuments, loadInstalled(a, io, .{ .root = root, .version_id = "leaf", .limits = .{ .max_documents = 1 } }));
    try std.testing.expectError(error.MetadataTooLarge, loadInstalled(a, io, .{ .root = root, .version_id = "leaf", .limits = .{ .max_bytes = 10 } }));
}

test "loader missing metadata cycle mismatched id and custom leaf path" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try std.testing.expectError(error.MissingVersionMetadata, loadInstalled(a, io, .{ .root = root, .version_id = "missing" }));
    try fixtureWrite(a, io, root, "leaf", "{\"id\":\"leaf\",\"inheritsFrom\":\"leaf\"}");
    try std.testing.expectError(error.InheritanceCycle, loadInstalled(a, io, .{ .root = root, .version_id = "leaf" }));
    try fixtureWrite(a, io, root, "leaf", fixture_base);
    try std.testing.expectError(error.VersionIdMismatch, loadInstalled(a, io, .{ .root = root, .version_id = "leaf" }));
    const path = try std.fs.path.join(a, &.{ root, "custom.json" });
    defer a.free(path);
    try safe_fs.writeAtomic(a, io, path, fixture_base, null);
    var loaded = try loadInstalled(a, io, .{ .root = root, .version_id = "Custom Instance", .metadata_path = path });
    defer loaded.deinit();
    try std.testing.expectEqualStrings("base", loaded.version.value.id);
    try std.testing.expectError(error.InvalidInheritanceLimits, loadInstalled(a, io, .{ .root = root, .version_id = "base", .limits = .{ .max_depth = 65 } }));
}

const SourceFixture = struct {
    bytes: []const u8 = fixture_base,
    calls: usize = 0,
    cancel: ?*std.atomic.Value(bool) = null,
    failure: ?anyerror = null,
    fn fetch(raw: ?*anyopaque, a: A, _: std.Io, request: Request) ![]u8 {
        const self: *SourceFixture = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        try std.testing.expect(request.sha1 != null);
        if (self.cancel) |flag| flag.store(true, .release);
        if (self.failure) |err| return err;
        return a.dupe(u8, self.bytes);
    }
};
fn sourceFixtureManifest(entries: *[1]metadata.manifest.Entry) metadata.manifest.Manifest {
    var hash: metadata.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(fixture_base, &hash, .{});
    entries.* = .{.{ .id = "base", .kind = "release", .url = "https://piston-meta.mojang.com/v1/packages/fixture/base.json", .time = "", .release_time = "", .sha1 = hash, .compliance_level = null }};
    return .{ .latest = .{ .release = "base", .snapshot = "base" }, .versions = entries };
}

test "source fetch ignores same-name installed instances including unreadable documents" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const minecraft_root = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(minecraft_root);
    // This instance happens to share the requested source ID but runs another MC version.
    const installed_bytes = "{\"id\":\"base\",\"mainClass\":\"WrongMinecraftVersion\",\"downloads\":{\"client\":{\"url\":\"https://example.invalid/other-minecraft.jar\"}}}";
    try fixtureWrite(a, io, minecraft_root, "base", installed_bytes);
    var entries: [1]metadata.manifest.Entry = undefined;
    const options: FetchOptions = .{ .version_id = "base", .manifest = sourceFixtureManifest(&entries) };
    var callback: SourceFixture = .{};
    const fetcher: Fetcher = .{ .context = &callback, .fetch = SourceFixture.fetch };
    var source = try fetchSources(a, io, options, fetcher);
    defer source.deinit();
    try std.testing.expectEqualStrings(fixture_base, source.sources.value[0].bytes);
    try std.testing.expectEqualStrings("Main", source.version.value.main_class.?);
    var installed = try loadInstalled(a, io, .{ .root = minecraft_root, .version_id = "base" });
    defer installed.deinit();
    try std.testing.expectEqualStrings("WrongMinecraftVersion", installed.version.value.main_class.?);
    try std.testing.expectError(error.MissingVersionMetadata, fetchSources(a, io, options, .{}));
    // Exercise the target-bound preparation while the colliding instance file exists.
    var fixture: VanillaFixture = .{};
    var prepared_options = fixture.options(root);
    prepared_options.target.version_id = "base";
    prepared_options.vanilla.version_id = "base";
    var prepared_file = try prepareVanilla(a, io, prepared_options);
    defer prepared_file.deinit();
    try std.testing.expectEqualStrings(fixture_base, prepared_file.sources[0].bytes);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    // A directory at the document path must not block source fetching either.
    const path = try docPath(a, minecraft_root, "base");
    defer a.free(path);
    try std.Io.Dir.cwd().deleteFile(io, path);
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    var second = try fetchSources(a, io, options, fetcher);
    defer second.deinit();
    try std.testing.expectEqualStrings(fixture_base, second.sources.value[0].bytes);
    try std.testing.expectEqual(@as(usize, 2), callback.calls);
    var prepared_directory = try prepareVanilla(a, io, prepared_options);
    defer prepared_directory.deinit();
    try std.testing.expectEqualStrings(fixture_base, prepared_directory.sources[0].bytes);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "source fetch requires official provenance for every document and validates returned bytes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var entries: [1]metadata.manifest.Entry = undefined;
    var options: FetchOptions = .{ .version_id = "base", .manifest = sourceFixtureManifest(&entries) };
    var callback: SourceFixture = .{};
    const fetcher: Fetcher = .{ .context = &callback, .fetch = SourceFixture.fetch };
    options.version_id = "unknown";
    try std.testing.expectError(error.MissingVersionMetadata, fetchSources(a, io, options, fetcher));
    options.version_id = "base";
    const hash = entries[0].sha1;
    entries[0].sha1 = null;
    try std.testing.expectError(error.MissingMetadataChecksum, fetchSources(a, io, options, fetcher));
    entries[0].sha1 = hash;
    const url = entries[0].url;
    for ([_][]const u8{ "https://example.invalid/base.json", "https://piston-meta.mojang.com.evil/base.json", "https://piston-meta.mojang.com/../base.json", "https://piston-meta.mojang.com/base.json?redirect=1" }) |bad_url| {
        entries[0].url = bad_url;
        try std.testing.expectError(error.UntrustedMetadataUrl, fetchSources(a, io, options, fetcher));
    }
    entries[0].url = url;
    try std.testing.expectEqual(@as(usize, 0), callback.calls);
    callback.bytes = "not-json";
    try std.testing.expectError(error.ChecksumMismatch, fetchSources(a, io, options, fetcher));
    callback.bytes = "{\"id\":\"other\"}";
    var other_hash: metadata.Sha1 = undefined;
    std.crypto.hash.Sha1.hash(callback.bytes, &other_hash, .{});
    entries[0].sha1 = other_hash;
    try std.testing.expectError(error.VersionIdMismatch, fetchSources(a, io, options, fetcher));
    callback.bytes = "{\"id\":\"base\",\"inheritsFrom\":\"unknown\"}";
    std.crypto.hash.Sha1.hash(callback.bytes, &other_hash, .{});
    entries[0].sha1 = other_hash;
    try std.testing.expectError(error.MissingVersionMetadata, fetchSources(a, io, options, fetcher));
    try std.testing.expectEqual(@as(usize, 3), callback.calls);
}

test "source fetch preserves cancellation transport failures and byte limits" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var entries: [1]metadata.manifest.Entry = undefined;
    var options: FetchOptions = .{ .version_id = "base", .manifest = sourceFixtureManifest(&entries) };
    var callback: SourceFixture = .{};
    const fetcher: Fetcher = .{ .context = &callback, .fetch = SourceFixture.fetch };
    var cancel: std.atomic.Value(bool) = .init(true);
    options.cancel = &cancel;
    try std.testing.expectError(error.Canceled, fetchSources(a, io, options, fetcher));
    try std.testing.expectEqual(@as(usize, 0), callback.calls);
    cancel.store(false, .release);
    callback.cancel = &cancel;
    try std.testing.expectError(error.Canceled, fetchSources(a, io, options, fetcher));
    cancel.store(false, .release);
    callback.cancel = null;
    callback.failure = error.MetadataHttpFailure;
    try std.testing.expectError(error.MetadataHttpFailure, fetchSources(a, io, options, fetcher));
    callback.failure = null;
    options.limits.max_bytes = fixture_base.len - 1;
    try std.testing.expectError(error.MetadataTooLarge, fetchSources(a, io, options, fetcher));
    const request: Request = .{ .id = "base", .url = entries[0].url, .sha1 = entries[0].sha1, .size = fixture_base.len + 1, .max_bytes = fixture_base.len };
    try std.testing.expectError(error.SizeMismatch, verifyBody(fixture_base, request));
}

test "installed loader bounds every path through shared local documents" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try fixtureWrite(a, io, root, "base", fixture_base);
    try fixtureWrite(a, io, root, "shared", "{\"id\":\"shared\",\"inheritsFrom\":\"base\"}");
    try fixtureWrite(a, io, root, "branch", "{\"id\":\"branch\",\"inheritsFrom\":\"shared\"}");
    try fixtureWrite(a, io, root, "leaf", "{\"id\":\"leaf\",\"inheritsFrom\":\"shared\",\"jar\":\"branch\"}");
    try std.testing.expectError(error.InheritanceDepthExceeded, loadInstalled(a, io, .{ .root = root, .version_id = "leaf", .limits = .{ .max_depth = 3 } }));
    var loaded = try loadInstalled(a, io, .{ .root = root, .version_id = "leaf", .limits = .{ .max_depth = 4 } });
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 4), loaded.sources.value.len);
}

fn sourceAllocationFixture(a: A) !void {
    var entries: [1]metadata.manifest.Entry = undefined;
    var callback: SourceFixture = .{};
    var loaded = try fetchSources(a, std.testing.io, .{ .version_id = "base", .manifest = sourceFixtureManifest(&entries) }, .{ .context = &callback, .fetch = SourceFixture.fetch });
    defer loaded.deinit();
}
fn installedAllocationFixture(a: A, root: []const u8) !void {
    var loaded = try loadInstalled(a, std.testing.io, .{ .root = root, .version_id = "leaf" });
    defer loaded.deinit();
}
test "source and installed loaders release every allocation on failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try fixtureWrite(a, io, root, "leaf", fixture_leaf);
    try fixtureWrite(a, io, root, "base", fixture_base);
    try fixtureWrite(a, io, root, "jar", fixture_jar);
    try @import("test_allocations").checkAllAllocationFailures(a, sourceAllocationFixture, .{});
    try @import("test_allocations").checkAllAllocationFailures(a, installedAllocationFixture, .{root});
}

const vanilla_fixture_leaf = "{\"id\":\"leaf\",\"inheritsFrom\":\"base\",\"javaVersion\":{\"component\":\"java-runtime-delta\",\"majorVersion\":21}}";
const VanillaFixture = struct {
    entries: [2]metadata.manifest.Entry = undefined,
    calls: usize = 0,
    base_bytes: []const u8 = fixture_base,
    cancel_during_fetch: ?*std.atomic.Value(bool) = null,
    fn options(self: *VanillaFixture, root: []const u8) VanillaMetadataOptions {
        self.entries = .{
            .{ .id = "leaf", .kind = "release", .url = "https://piston-meta.mojang.com/v1/packages/fixture/leaf.json", .time = "", .release_time = "", .sha1 = undefined, .compliance_level = null },
            .{ .id = "base", .kind = "release", .url = "https://launchermeta.mojang.com/v1/packages/fixture/base.json", .time = "", .release_time = "", .sha1 = undefined, .compliance_level = null },
        };
        var leaf_sha: metadata.Sha1 = undefined;
        var base_sha: metadata.Sha1 = undefined;
        std.crypto.hash.Sha1.hash(vanilla_fixture_leaf, &leaf_sha, .{});
        std.crypto.hash.Sha1.hash(fixture_base, &base_sha, .{});
        self.entries[0].sha1 = leaf_sha;
        self.entries[1].sha1 = base_sha;
        return .{
            .target = .{ .root = root, .instance_id = "vanilla-id", .instance_name = "vanilla-game", .version_id = "leaf", .generation = 17, .environment = .{ .os_name = "linux", .arch = "x86_64" } },
            .vanilla = .{ .version_id = "leaf", .manifest = .{ .latest = .{ .release = "leaf", .snapshot = "leaf" }, .versions = &self.entries } },
            .fetcher = .{ .context = self, .fetch = fetch },
        };
    }
    fn fetch(raw: ?*anyopaque, a: A, _: std.Io, request: Request) ![]u8 {
        const self: *VanillaFixture = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.cancel_during_fetch) |cancel| cancel.store(true, .release);
        return a.dupe(u8, if (std.mem.eql(u8, request.id, "leaf")) vanilla_fixture_leaf else if (std.mem.eql(u8, request.id, "base")) self.base_bytes else return error.MissingVersionMetadata);
    }
};

test "vanilla prepared inherited metadata owns bindings and replay survives owner destruction" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const metadata_root = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(metadata_root);
    var fixture: VanillaFixture = .{};
    var options = fixture.options(root);
    var feature_name = [_]u8{ 'q', 'u', 'i', 'c', 'k' };
    var features = [_]metadata.rules.Feature{.{ .name = &feature_name, .enabled = true }};
    options.target.environment.features = &features;
    var matcher_context: u8 = 0;
    options.target.environment.version_matcher = .{ .context = &matcher_context, .matches = vanillaFixtureMatcher };
    var prepared = try prepareVanilla(a, io, options);
    var alive = true;
    defer if (alive) prepared.deinit();
    try std.testing.expectEqual(@as(u64, 21), prepared.runtime_major);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    feature_name[0] = 'X';
    features[0].enabled = false;
    fixture.entries[0].url = "https://example.invalid/mutated.json";
    try std.testing.expectEqualStrings("quick", prepared.target.environment.features[0].name);
    try std.testing.expect(prepared.target.environment.features[0].enabled);
    try prepared.validateBinding(a, io, prepared.target);
    try std.testing.expectError(error.PreparedMetadataMismatch, prepared.validateBinding(a, io, options.target));
    const matcher = prepared.target.environment.version_matcher;
    prepared.target.environment.version_matcher.?.context = null;
    try std.testing.expectError(error.PreparedMetadataChanged, prepared.validateBinding(a, io, prepared.target));
    prepared.target.environment.version_matcher = matcher;
    prepared.target.environment.version_matcher.?.matches = vanillaFixtureOtherMatcher;
    try std.testing.expectError(error.PreparedMetadataChanged, prepared.validateBinding(a, io, prepared.target));
    prepared.target.environment.version_matcher = matcher;
    var loaded = try prepared.replayBase(a, io, prepared.target, null);
    defer loaded.deinit();
    prepared.deinit();
    alive = false;
    try std.testing.expectEqualStrings("leaf", loaded.version.value.id);
    try std.testing.expectEqualStrings("base", loaded.version.value.jar.?);
    try std.testing.expectEqual(@as(u64, 21), metadata.version.requiredJavaMajor(loaded.version.value));
    try std.testing.expectEqual(@as(usize, 2), loaded.sources.value.len);
    try std.testing.expectEqualStrings(vanilla_fixture_leaf, loaded.sources.value[0].bytes);
    try std.testing.expectEqualStrings(fixture_base, loaded.sources.value[1].bytes);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    const path = try docPath(a, metadata_root, "leaf");
    defer a.free(path);
    try std.testing.expectError(error.FileNotFound, safe_fs.openFile(io, path));
    options = fixture.options(root);
    options.target.version_id = "base";
    options.vanilla.version_id = "base";
    var baseline = try prepareVanilla(a, io, options);
    defer baseline.deinit();
    try std.testing.expectEqual(@as(u64, 8), baseline.runtime_major);
}

fn vanillaFixtureMatcher(_: ?*anyopaque, _: []const u8, _: []const u8) !bool {
    return true;
}
fn vanillaFixtureOtherMatcher(_: ?*anyopaque, _: []const u8, _: []const u8) !bool {
    return false;
}
test "vanilla preparation rejects wrong identity corrupt provenance tampering and cancellation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const metadata_root = try std.fs.path.join(a, &.{ root, ".minecraft" });
    defer a.free(metadata_root);
    var fixture: VanillaFixture = .{};
    const options = fixture.options(root);
    var wrong = options;
    wrong.target.generation = 0;
    try std.testing.expectError(error.InvalidPreparationGeneration, prepareVanilla(a, io, wrong));
    wrong = options;
    wrong.target.root = "";
    try std.testing.expectError(error.InvalidLauncherRoot, prepareVanilla(a, io, wrong));
    wrong = options;
    wrong.vanilla.version_id = "other";
    try std.testing.expectError(error.PreparedMetadataMismatch, prepareVanilla(a, io, wrong));
    try fixtureWrite(a, io, metadata_root, "leaf", "not JSON");
    var refreshed = try prepareVanilla(a, io, options);
    defer refreshed.deinit();
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try refreshed.validateBinding(a, io, refreshed.target);
    try fixtureWrite(a, io, metadata_root, "leaf", vanilla_fixture_leaf);
    fixture.base_bytes = "malformed parent";
    try std.testing.expectError(error.ChecksumMismatch, prepareVanilla(a, io, options));
    fixture.base_bytes = fixture_base;
    const parent_sha = fixture.entries[1].sha1;
    fixture.entries[1].sha1 = null;
    const parent_calls = fixture.calls;
    try std.testing.expectError(error.MissingMetadataChecksum, prepareVanilla(a, io, options));
    try std.testing.expectEqual(parent_calls + 1, fixture.calls);
    fixture.entries[1].sha1 = parent_sha;
    var prepared = try prepareVanilla(a, io, options);
    defer prepared.deinit();
    var target = prepared.target;
    target.generation += 1;
    try std.testing.expectError(error.PreparedMetadataGenerationMismatch, prepared.replayBase(a, io, target, null));
    inline for (.{ "instance_id", "instance_name", "version_id" }) |field| {
        target = prepared.target;
        @field(target, field) = "other";
        try std.testing.expectError(error.PreparedMetadataMismatch, prepared.validateBinding(a, io, target));
    }
    target = prepared.target;
    target.root = metadata_root;
    try std.testing.expectError(error.PreparedMetadataMismatch, prepared.validateBinding(a, io, target));
    target = prepared.target;
    target.environment.os_version = "changed";
    try std.testing.expectError(error.PreparedMetadataMismatch, prepared.validateBinding(a, io, target));
    prepared.runtime_major += 1;
    try std.testing.expectError(error.PreparedMetadataChanged, prepared.replayBase(a, io, prepared.target, null));
    prepared.runtime_major -= 1;
    const main_class = prepared.base.value.main_class;
    prepared.base.value.main_class = "changed";
    try std.testing.expectError(error.PreparedMetadataChanged, prepared.validateBinding(a, io, prepared.target));
    prepared.base.value.main_class = main_class;
    const bindings = @constCast(prepared.sources);
    const source_url = bindings[0].url;
    bindings[0].url = "https://piston-meta.mojang.com/v1/other.json";
    try std.testing.expectError(error.PreparedMetadataChanged, prepared.validateBinding(a, io, prepared.target));
    bindings[0].url = source_url;
    bindings[0].sha1[0] ^= 1;
    try std.testing.expectError(error.PreparedMetadataChanged, prepared.validateBinding(a, io, prepared.target));
    bindings[0].sha1[0] ^= 1;
    const bytes = @constCast(bindings[0].bytes);
    const first = bytes[0];
    bytes[0] = '!';
    try std.testing.expectError(error.PreparedMetadataChanged, prepared.replayBase(a, io, prepared.target, null));
    bytes[0] = first;
    prepared.limits.max_depth += 1;
    try std.testing.expectError(error.PreparedMetadataChanged, prepared.validateBinding(a, io, prepared.target));
    prepared.limits.max_depth -= 1;
    const saved_sources = prepared.sources;
    prepared.sources = saved_sources[1..];
    try std.testing.expectError(error.PreparedMetadataChanged, prepared.validateBinding(a, io, prepared.target));
    prepared.sources = saved_sources;
    prepared.target.environment.version_matcher = .{ .matches = vanillaFixtureMatcher };
    try std.testing.expectError(error.PreparedMetadataChanged, prepared.validateBinding(a, io, prepared.target));
    prepared.target.environment.version_matcher = null;
    try prepared.validateBinding(a, io, prepared.target);
    var cancel = std.atomic.Value(bool).init(true);
    const calls = fixture.calls;
    wrong = options;
    wrong.vanilla.cancel = &cancel;
    try std.testing.expectError(error.Canceled, prepareVanilla(a, io, wrong));
    target = prepared.target;
    target.generation = 0;
    try std.testing.expectError(error.Canceled, prepared.replayBase(a, io, target, &cancel));
    try std.testing.expectEqual(calls, fixture.calls);
    cancel.store(false, .release);
    fixture.cancel_during_fetch = &cancel;
    try std.testing.expectError(error.Canceled, prepareVanilla(a, io, wrong));
}

fn vanillaAllocationFixture(a: A, root: []const u8) !void {
    var fixture: VanillaFixture = .{};
    var prepared = try prepareVanilla(a, std.testing.io, fixture.options(root));
    defer prepared.deinit();
    var loaded = try prepared.replayBase(a, std.testing.io, prepared.target, null);
    defer loaded.deinit();
}
test "vanilla preparation and independent inherited replay clean up every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, vanillaAllocationFixture, .{root});
}
