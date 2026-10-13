//! UI-owned faces with one isolated worker; sync/cancel never join running work.
//! Cache files are untrusted, fixed-size, identity-bound snapshots, not account data.
const std = @import("std");
const config = @import("../core/config.zig");
const avatar = @import("../core/avatar.zig");
const http = @import("../core/http_transport.zig");
const image = @import("avatar_image.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const Face = image.Face;
const Key = [32]u8;
const positive_ttl: u64 = 24 * 60 * 60;
const missing_ttl: u64 = 60 * 60;
const transient_retry_ms: i64 = 5 * 60 * 1000;
const capacity = 32;

const Identity = struct {
    key: Key,
    uuid: [32]u8,
    kind: config.AccountKind,
    name: [200]u8,
    name_len: usize,

    fn from(account: config.Account) !Identity {
        if (account.name.len == 0 or account.name.len > 200) return error.InvalidAccountName;
        const uuid = try avatar.canonicalUuid(account.uuid);
        var result: Identity = .{ .key = undefined, .uuid = uuid, .kind = account.kind, .name = undefined, .name_len = account.name.len };
        @memcpy(result.name[0..account.name.len], account.name);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(&uuid);
        hash.update(&.{@backingInt(account.kind)});
        for (account.name) |byte| hash.update(&.{std.ascii.toLower(byte)});
        hash.final(&result.key);
        return result;
    }
};

const Semantic = enum(u8) { online = 1, not_found = 2, default = 3 };
const Cached = struct { face: Face, timestamp: u64, kind: Semantic };
const Entry = struct {
    key: Key,
    face: Face,
    cache_checked: bool = false,
    next_ms: i64 = 0,
    touched: u64 = 0,
};
const Mode = enum { cache, network };

const Job = struct {
    arena: std.heap.ArenaAllocator,
    io: Io,
    identity: Identity,
    root: []const u8,
    options: http.Options,
    transport: ?avatar.Transport,
    defaults: [9]Face,
    mode: Mode,
    prefetch: bool = false,
    cancellation: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    future: ?Io.Future(void) = null,
    value: ?Cached = null,
    failure: ?anyerror = null,

    fn create(manager: *const Manager, identity: Identity, mode: Mode) !*Job {
        const a = std.heap.page_allocator;
        const job = try a.create(Job);
        errdefer a.destroy(job);
        job.* = .{ .arena = .init(a), .io = manager.io, .identity = identity, .root = undefined, .options = .{}, .transport = manager.transport, .defaults = manager.defaults, .mode = mode };
        errdefer job.arena.deinit();
        const owned = job.arena.allocator();
        job.root = try owned.dupe(u8, manager.root);
        if (manager.options.proxy) |proxy| job.options.proxy = try owned.dupe(u8, proxy);
        if (manager.options.ca_bundle) |ca| job.options.ca_bundle = try owned.dupe(u8, ca);
        return job;
    }

    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        if (self.cancellation.load(.acquire)) return;
        if (self.mode == .cache) {
            self.value = readCache(self.io, self.root, self.identity.key) catch null;
            return;
        }
        self.value = self.fetch() catch |err| {
            self.failure = err;
            return;
        };
        if (self.cancellation.load(.acquire)) {
            self.value = null;
            return;
        }
        // Errors and cancellations never create negative cache records.
        writeCache(self.io, self.root, self.identity.key, self.value.?, &self.cancellation) catch {};
    }

    fn fetch(self: *Job) !Cached {
        const a = std.heap.page_allocator;
        const deadline = Io.Clock.awake.now(self.io).nanoseconds + 12 * std.time.ns_per_s;
        if (self.transport) |transport| return self.resolve(transport);
        var client = try http.Client.init(a, self.io, self.options);
        defer client.deinit();
        var adapter: HttpAdapter = .{ .client = &client, .deadline = deadline };
        return self.resolve(.{ .ctx = &adapter, .get = HttpAdapter.get });
    }

    fn resolve(self: *Job, transport: avatar.Transport) !Cached {
        const a = std.heap.page_allocator;
        var result = try avatar.resolve(a, transport, self.identity.name[0..self.identity.name_len], if (self.identity.kind == .microsoft) &self.identity.uuid else null, &self.cancellation);
        defer result.deinit(a);
        if (self.cancellation.load(.acquire)) return error.Canceled;
        const timestamp = realSeconds(self.io);
        return switch (result) {
            .skin => |png| .{ .face = try image.decodeFace(a, png), .timestamp = timestamp, .kind = .online },
            .default_uuid => |uuid| .{ .face = self.defaults[avatar.defaultIndex(&uuid)], .timestamp = timestamp, .kind = .default },
            .not_found => .{ .face = self.defaults[avatar.defaultIndex(&self.identity.uuid)], .timestamp = timestamp, .kind = .not_found },
        };
    }

    fn destroy(self: *Job) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

const HttpAdapter = struct {
    client: *http.Client,
    deadline: i96,

    fn get(context: *anyopaque, a: Allocator, url: []const u8, cancellation: *const std.atomic.Value(bool)) !avatar.Response {
        const self: *HttpAdapter = @ptrCast(@alignCast(context));
        var response = try self.client.execute(.{
            .url = url,
            .max_response_bytes = if (std.mem.startsWith(u8, url, "https://textures.minecraft.net/texture/")) 128 * 1024 else 64 * 1024,
            .timeout_ms = 8000,
            .deadline_ns = self.deadline,
            .cancel = cancellation,
            .follow_redirects = false,
            .require_public_address = self.client.proxy.len == 0,
        });
        defer response.deinit();
        return .{ .status = response.status, .body = try a.dupe(u8, response.body) };
    }
};

pub const Manager = struct {
    allocator: Allocator,
    io: Io,
    root: []const u8,
    options: http.Options,
    defaults: [9]Face,
    allow_network: bool,
    /// Test transport context must outlive the manager and every worker.
    transport: ?avatar.Transport = null,
    entries: [capacity]?Entry = @splat(null),
    selected: ?Key = null,
    picker_open: bool = false,
    visible: [capacity]Key = undefined,
    visible_count: usize = 0,
    active: ?*Job = null,
    enabled: bool = false,
    serial: u64 = 0,

    pub fn init(a: Allocator, io: Io, cache_root: []const u8, options: http.Options, allow_network: bool) !Manager {
        const root = try a.dupe(u8, cache_root);
        errdefer a.free(root);
        var copied: http.Options = .{};
        if (options.proxy) |proxy| copied.proxy = try a.dupe(u8, proxy);
        errdefer if (copied.proxy) |proxy| a.free(proxy);
        if (options.ca_bundle) |ca| copied.ca_bundle = try a.dupe(u8, ca);
        errdefer if (copied.ca_bundle) |ca| a.free(ca);
        return .{ .allocator = a, .io = io, .root = root, .options = copied, .defaults = try image.defaultFaces(a), .allow_network = allow_network };
    }

    pub fn initWithTransport(a: Allocator, io: Io, cache_root: []const u8, options: http.Options, allow_network: bool, transport: avatar.Transport) !Manager {
        var manager = try init(a, io, cache_root, options, allow_network);
        manager.transport = transport;
        return manager;
    }

    pub fn deinit(self: *Manager) void {
        self.cancel();
        if (self.active) |job| {
            if (job.future) |*future| future.cancel(self.io);
            job.destroy();
        }
        self.allocator.free(self.root);
        if (self.options.proxy) |proxy| self.allocator.free(proxy);
        if (self.options.ca_bundle) |ca| self.allocator.free(ca);
        self.* = undefined;
    }

    /// Cooperative, nonblocking cancellation. Only deinit joins running work.
    pub fn cancel(self: *Manager) void {
        self.enabled = false;
        if (self.active) |job| job.cancellation.store(true, .release);
    }

    pub fn tick(self: *Manager) void {
        const job = self.active orelse return;
        if (!job.done.load(.acquire)) return;
        if (job.future) |*future| future.await(self.io);
        self.active = null;
        defer job.destroy();
        if (!self.enabled or job.cancellation.load(.acquire)) return;
        if (job.prefetch) {
            if (!self.picker_open or !self.hasInterest(job.identity.key)) return;
        } else {
            const selected = self.selected orelse return;
            if (!sameKey(selected, job.identity.key)) return;
        }
        const entry = self.lookup(job.identity.key) orelse return;
        if (job.mode == .cache) entry.cache_checked = true;
        if (job.value) |value| {
            entry.face = value.face;
            entry.next_ms = monotonicMs(self.io) + @as(i64, @intCast(remainingTtl(value, realSeconds(self.io)))) * 1000;
        } else if (job.mode == .network) {
            // Keep any successful/stale face; retry is relative to monotonic time.
            entry.next_ms = monotonicMs(self.io) + transient_retry_ms;
        }
    }

    pub fn isBusy(self: *const Manager) bool {
        return self.active != null;
    }

    pub fn sync(self: *Manager, document: *const config.Document, enabled: bool) !void {
        if (!enabled) {
            self.cancel();
            self.tick();
            return;
        }
        var identity: ?Identity = null;
        if (document.selected_account) |id| {
            for (document.accounts) |account| {
                if (std.mem.eql(u8, account.id, id)) {
                    identity = Identity.from(account) catch null;
                    break;
                }
            }
        }
        const next_key: ?Key = if (identity) |value| value.key else null;
        if (!optionalSameKey(self.selected, next_key)) {
            if (self.active) |job| job.cancellation.store(true, .release);
        }
        self.selected = next_key;
        self.enabled = true;
        self.tick();
        const target = identity orelse return;
        const entry = self.ensureEntry(target);
        if (self.active) |job| {
            if (job.prefetch and !sameKey(job.identity.key, target.key) and self.workMode(entry) != null) job.cancellation.store(true, .release);
            return;
        }
        try self.start(target, entry, false);
    }

    /// Begin each picker frame before registering only the rows actually visible.
    pub fn beginPicker(self: *Manager, open: bool) void {
        self.picker_open = open;
        self.visible_count = 0;
        if (!open) {
            if (self.active) |job| if (job.prefetch) job.cancellation.store(true, .release);
        }
    }

    /// Register one visible row. A request never joins or borrows account fields.
    pub fn request(self: *Manager, account: config.Account) !void {
        if (!self.picker_open) return;
        const identity = try Identity.from(account);
        self.registerInterest(identity.key);
        const entry = self.ensureEntry(identity);
        if (!self.enabled or self.active != null) return;
        // tick is intentionally separate: all visible rows must register before
        // a completed prefetch is checked against this frame's interests.
        try self.start(identity, entry, true);
    }

    fn workMode(self: *const Manager, entry: *const Entry) ?Mode {
        if (!entry.cache_checked) return .cache;
        if (self.allow_network and monotonicMs(self.io) >= entry.next_ms) return .network;
        return null;
    }

    fn start(self: *Manager, identity: Identity, entry: *Entry, prefetch: bool) !void {
        const mode = self.workMode(entry) orelse return;
        const job = try Job.create(self, identity, mode);
        errdefer job.destroy();
        job.prefetch = prefetch;
        job.future = self.io.concurrent(Job.run, .{job}) catch |err| {
            // Back off an unavailable executor too; never spin a UI frame.
            entry.cache_checked = true;
            entry.next_ms = monotonicMs(self.io) + transient_retry_ms;
            return err;
        };
        self.active = job;
    }

    fn hasInterest(self: *const Manager, key: Key) bool {
        for (self.visible[0..self.visible_count]) |interest| if (sameKey(interest, key)) return true;
        return false;
    }

    fn registerInterest(self: *Manager, key: Key) void {
        if (self.hasInterest(key)) return;
        // Reserve one entry for selection, keeping interests within the entry
        // budget even when the selected account is outside the viewport.
        const limit: usize = capacity - @as(usize, @intFromBool(self.selected != null));
        while (self.visible_count >= limit) {
            var victim: usize = 0;
            if (self.active) |job| {
                if (job.prefetch and sameKey(self.visible[0], job.identity.key)) victim = 1;
            }
            for (victim..self.visible_count - 1) |index| self.visible[index] = self.visible[index + 1];
            self.visible_count -= 1;
        }
        self.visible[self.visible_count] = key;
        self.visible_count += 1;
    }

    /// Borrowed until manager mutation; use/copy face pixels in the current frame.
    pub fn face(self: *Manager, account: config.Account) *Face {
        const identity = Identity.from(account) catch return &self.defaults[avatar.defaultIndex(account.uuid)];
        if (self.lookup(identity.key)) |entry| return &entry.face;
        return &self.defaults[avatar.defaultIndex(&identity.uuid)];
    }

    /// Delay until selected/visible work is due; inspect at most 32 interests.
    pub fn retryDelayMilliseconds(self: *const Manager) u32 {
        if (self.active != null) return 50;
        if (!self.enabled) return std.math.maxInt(u32);
        var delay: u32 = std.math.maxInt(u32);
        if (self.selected) |key| delay = self.delayFor(key);
        if (self.picker_open) {
            for (self.visible[0..self.visible_count]) |key| delay = @min(delay, self.delayFor(key));
        }
        return delay;
    }

    fn delayFor(self: *const Manager, key: Key) u32 {
        for (self.entries) |slot| {
            const entry = slot orelse continue;
            if (!sameKey(entry.key, key)) continue;
            if (!entry.cache_checked) return 1;
            if (!self.allow_network) return std.math.maxInt(u32);
            return @intCast(@min(std.math.maxInt(u32), @max(1, entry.next_ms - monotonicMs(self.io))));
        }
        return 1;
    }

    fn lookup(self: *Manager, key: Key) ?*Entry {
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| if (sameKey(entry.key, key)) return entry;
        }
        return null;
    }

    fn ensureEntry(self: *Manager, identity: Identity) *Entry {
        self.serial +|= 1;
        if (self.lookup(identity.key)) |entry| {
            entry.touched = self.serial;
            return entry;
        }
        var victim: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (self.entries, 0..) |slot, index| {
            const entry = slot orelse {
                victim = index;
                break;
            };
            // Keep selected and active faces. Jobs own identities, not entries.
            if (self.selected) |key| if (sameKey(entry.key, key)) continue;
            if (self.active) |job| if (sameKey(entry.key, job.identity.key)) continue;
            if (entry.touched <= oldest) {
                oldest = entry.touched;
                victim = index;
            }
        }
        self.entries[victim] = .{ .key = identity.key, .face = self.defaults[avatar.defaultIndex(&identity.uuid)], .touched = self.serial };
        return &self.entries[victim].?;
    }

    /// Tests join deterministic simulated work directly, with no sleeps/poll loops.
    fn finishActive(self: *Manager) void {
        if (self.active) |job| if (job.future) |*future| future.await(self.io);
        self.tick();
    }
};

fn sameKey(a: Key, b: Key) bool {
    return std.mem.eql(u8, &a, &b);
}
fn optionalSameKey(a: ?Key, b: ?Key) bool {
    if (a) |left| return if (b) |right| sameKey(left, right) else false;
    return b == null;
}
fn monotonicMs(io: Io) i64 {
    return @intCast(Io.Clock.awake.now(io).toMilliseconds());
}
fn realSeconds(io: Io) u64 {
    return @intCast(@max(0, @divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s)));
}
fn remainingTtl(value: Cached, now: u64) u64 {
    if (value.timestamp > now) return 0;
    const ttl: u64 = if (value.kind == .not_found) missing_ttl else positive_ttl;
    return ttl -| (now - value.timestamp);
}

// Portable bytes, not native struct layout: magic8/version1/kind1/time8/key32/
// RGBA256/SHA25632. A checksum binds every field including the identity key.
const cache_size = 338;
const cache_magic = "VELAFACE";
fn encodeCache(key: Key, value: Cached) [cache_size]u8 {
    var bytes: [cache_size]u8 = undefined;
    @memcpy(bytes[0..8], cache_magic);
    bytes[8] = 1;
    bytes[9] = @backingInt(value.kind);
    std.mem.writeInt(u64, bytes[10..18], value.timestamp, .little);
    @memcpy(bytes[18..50], &key);
    for (value.face, 0..) |pixel, index| {
        const offset = 50 + index * 4;
        bytes[offset..][0..4].* = .{ pixel.r, pixel.g, pixel.b, pixel.a };
    }
    std.crypto.hash.sha2.Sha256.hash(bytes[0..306], bytes[306..338], .{});
    return bytes;
}
fn decodeCache(bytes: []const u8, key: Key, now: u64) ?Cached {
    if (bytes.len != cache_size or !std.mem.eql(u8, bytes[0..8], cache_magic) or bytes[8] != 1) return null;
    if (!std.mem.eql(u8, bytes[18..50], &key)) return null;
    var checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..306], &checksum, .{});
    if (!std.mem.eql(u8, bytes[306..338], &checksum)) return null;
    const kind = std.enums.fromInt(Semantic, bytes[9]) orelse return null;
    const timestamp = std.mem.readInt(u64, bytes[10..18], .little);
    if (timestamp == 0 or timestamp > now) return null;
    var face: Face = undefined;
    for (&face, 0..) |*pixel, index| {
        const offset = 50 + index * 4;
        const p = bytes[offset..][0..4];
        if (p[0] > p[3] or p[1] > p[3] or p[2] > p[3]) return null;
        pixel.* = .{ .r = p[0], .g = p[1], .b = p[2], .a = p[3] };
    }
    return .{ .kind = kind, .timestamp = timestamp, .face = face };
}
fn cacheFilename(key: Key) [68]u8 {
    var result: [68]u8 = undefined;
    const hex = "0123456789abcdef";
    for (key, 0..) |byte, index| {
        result[index * 2] = hex[byte >> 4];
        result[index * 2 + 1] = hex[byte & 15];
    }
    @memcpy(result[64..68], ".bin");
    return result;
}
fn readCache(io: Io, root: []const u8, key: Key) !?Cached {
    const base = try Io.Dir.cwd().openDir(io, root, .{});
    defer base.close(io);
    const dir = try base.openDir(io, "avatars", .{});
    defer dir.close(io);
    const filename = cacheFilename(key);
    const bytes = try dir.readFileAlloc(io, &filename, std.heap.page_allocator, .limited(cache_size + 1));
    defer std.heap.page_allocator.free(bytes);
    return decodeCache(bytes, key, realSeconds(io));
}
fn writeCache(io: Io, root: []const u8, key: Key, value: Cached, cancellation: *const std.atomic.Value(bool)) !void {
    if (cancellation.load(.acquire)) return error.Canceled;
    const base = try Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer base.close(io);
    const dir = try base.createDirPathOpen(io, "avatars", .{});
    defer dir.close(io);
    const filename = cacheFilename(key);
    var atomic = try dir.createFileAtomic(io, &filename, .{ .replace = true });
    defer atomic.deinit(io);
    const bytes = encodeCache(key, value);
    try atomic.file.writeStreamingAll(io, &bytes);
    if (cancellation.load(.acquire)) return error.Canceled;
    try atomic.replace(io);
}

const fixture_offline: config.Account = .{ .id = "first", .name = "PlayerOne", .uuid = "00000000000000000000000000000000" };
const fixture_online_uuid = "00000000000000000000000000000001";
const fixture_png = @embedFile("../assets/default_skins/alex.png");
const Fixture = struct {
    mode: enum { skin, default, missing, failure } = .skin,
    calls: std.atomic.Value(u32) = .init(0),
    gate: bool = false,
    started: Io.Event = .unset,
    release: Io.Event = .unset,

    fn transport(self: *Fixture) avatar.Transport {
        return .{ .ctx = self, .get = get };
    }
    fn get(context: *anyopaque, a: Allocator, url: []const u8, cancellation: *const std.atomic.Value(bool)) !avatar.Response {
        const self: *Fixture = @ptrCast(@alignCast(context));
        _ = self.calls.fetchAdd(1, .monotonic);
        if (self.gate) {
            self.started.set(std.testing.io);
            try self.release.wait(std.testing.io);
            // Deliberately return after cancellation: resolver/manager must discard.
        } else if (cancellation.load(.acquire)) return error.Canceled;
        if (self.mode == .failure) return error.FixtureUnavailable;
        if (std.mem.startsWith(u8, url, "https://api.minecraftservices.com/")) {
            if (self.mode == .missing) return .{ .status = 404, .body = try a.dupe(u8, "") };
            return .{ .status = 200, .body = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"name\":\"PlayerOne\"}}", .{fixture_online_uuid}) };
        }
        if (std.mem.startsWith(u8, url, "https://sessionserver.mojang.com/")) {
            const uuid = url[url.len - 32 ..];
            if (self.mode == .default) return .{ .status = 200, .body = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"properties\":[]}}", .{uuid}) };
            const textures = "{\"textures\":{\"SKIN\":{\"url\":\"https://textures.minecraft.net/texture/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}}";
            var encoded: [std.base64.standard.Encoder.calcSize(textures.len)]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(&encoded, textures);
            return .{ .status = 200, .body = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"properties\":[{{\"name\":\"textures\",\"value\":\"{s}\"}}]}}", .{ uuid, encoded }) };
        }
        if (std.mem.startsWith(u8, url, "https://textures.minecraft.net/texture/")) return .{ .status = 200, .body = try a.dupe(u8, fixture_png) };
        return error.UnexpectedFixtureUrl;
    }
};
fn fixtureRoot(tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    return std.testing.allocator.dupe(u8, buffer[0..len]);
}
fn fixtureDocument(accounts: []const config.Account, selected: []const u8) config.Document {
    return .{ .accounts = accounts, .selected_account = selected };
}
fn expectFace(expected: Face, actual: Face) !void {
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(&actual));
}
fn fixtureFace() Face {
    return @splat(.{ .r = 20, .g = 40, .b = 60, .a = 255 });
}

test "avatar identity binds canonical uuid, account kind, and folded name only" {
    const original = try Identity.from(fixture_offline);
    var renamed = fixture_offline;
    renamed.id = "different-id";
    renamed.name = "PLAYERONE";
    renamed.uuid = "00000000-0000-0000-0000-000000000000";
    try std.testing.expect(sameKey(original.key, (try Identity.from(renamed)).key));
    renamed.kind = .microsoft;
    try std.testing.expect(!sameKey(original.key, (try Identity.from(renamed)).key));
    renamed = fixture_offline;
    renamed.name = "PlayerTwo";
    try std.testing.expect(!sameKey(original.key, (try Identity.from(renamed)).key));
    renamed = fixture_offline;
    renamed.uuid = fixture_online_uuid;
    try std.testing.expect(!sameKey(original.key, (try Identity.from(renamed)).key));
    renamed.uuid = "bad-uuid";
    try std.testing.expectError(error.InvalidUuid, Identity.from(renamed));
}

test "avatar positive and confirmed missing TTL boundaries and future timestamps" {
    var cached: Cached = .{ .face = fixtureFace(), .timestamp = 1000, .kind = .online };
    try std.testing.expectEqual(positive_ttl, remainingTtl(cached, 1000));
    try std.testing.expectEqual(@as(u64, 1), remainingTtl(cached, 1000 + positive_ttl - 1));
    try std.testing.expectEqual(@as(u64, 0), remainingTtl(cached, 1000 + positive_ttl));
    cached.kind = .default;
    try std.testing.expectEqual(positive_ttl, remainingTtl(cached, 1000));
    cached.kind = .not_found;
    try std.testing.expectEqual(missing_ttl, remainingTtl(cached, 1000));
    try std.testing.expectEqual(@as(u64, 1), remainingTtl(cached, 1000 + missing_ttl - 1));
    try std.testing.expectEqual(@as(u64, 0), remainingTtl(cached, 1000 + missing_ttl));
    try std.testing.expectEqual(@as(u64, 0), remainingTtl(cached, 999));
}

test "avatar cache rejects corruption, wrong binding, truncation, oversize and future" {
    const key = (try Identity.from(fixture_offline)).key;
    const cached: Cached = .{ .face = fixtureFace(), .timestamp = 1000, .kind = .online };
    const valid = encodeCache(key, cached);
    try expectFace(cached.face, decodeCache(&valid, key, 1001).?.face);
    var broken = valid;
    broken[70] ^= 1;
    try std.testing.expect(decodeCache(&broken, key, 1001) == null);
    var other_key = key;
    other_key[0] ^= 1;
    try std.testing.expect(decodeCache(&valid, other_key, 1001) == null);
    try std.testing.expect(decodeCache(valid[0 .. cache_size - 1], key, 1001) == null);
    var oversized: [cache_size + 1]u8 = undefined;
    @memcpy(oversized[0..cache_size], &valid);
    oversized[cache_size] = 0;
    try std.testing.expect(decodeCache(&oversized, key, 1001) == null);
    try std.testing.expect(decodeCache(&valid, key, 999) == null);
    broken = valid;
    broken[8] = 2;
    std.crypto.hash.sha2.Sha256.hash(broken[0..306], broken[306..338], .{});
    try std.testing.expect(decodeCache(&broken, key, 1001) == null);
    broken = valid;
    broken[9] = 255;
    std.crypto.hash.sha2.Sha256.hash(broken[0..306], broken[306..338], .{});
    try std.testing.expect(decodeCache(&broken, key, 1001) == null);
}

test "avatar cache-only phase then skin succeeds and survives new offline manager" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    var fixture: Fixture = .{};
    const doc = fixtureDocument(&.{fixture_offline}, fixture_offline.id);
    var manager = try Manager.initWithTransport(std.testing.allocator, std.testing.io, root, .{}, true, fixture.transport());
    defer manager.deinit();
    try manager.sync(&doc, true);
    manager.finishActive();
    try std.testing.expectEqual(@as(u32, 0), fixture.calls.load(.acquire));
    try expectFace(manager.defaults[avatar.defaultIndex(fixture_offline.uuid)], manager.face(fixture_offline).*);
    try manager.sync(&doc, true);
    manager.finishActive();
    try std.testing.expectEqual(@as(u32, 3), fixture.calls.load(.acquire));
    const expected = try image.decodeFace(std.testing.allocator, fixture_png);
    try expectFace(expected, manager.face(fixture_offline).*);
    try std.testing.expect(manager.retryDelayMilliseconds() > 23 * 60 * 60 * 1000);
    try manager.sync(&doc, true);
    try std.testing.expect(!manager.isBusy());
    var offline = try Manager.initWithTransport(std.testing.allocator, std.testing.io, root, .{}, false, fixture.transport());
    defer offline.deinit();
    try offline.sync(&doc, true);
    offline.finishActive();
    try expectFace(expected, offline.face(fixture_offline).*);
    try offline.sync(&doc, true);
    try std.testing.expect(!offline.isBusy());
    try std.testing.expectEqual(@as(u32, 3), fixture.calls.load(.acquire));
    try std.testing.expectEqual(std.math.maxInt(u32), offline.retryDelayMilliseconds());
}

test "avatar confirmed missing caches one hour and online empty skin uses online UUID" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    var fixture: Fixture = .{ .mode = .missing };
    const doc = fixtureDocument(&.{fixture_offline}, fixture_offline.id);
    var manager = try Manager.initWithTransport(std.testing.allocator, std.testing.io, root, .{}, true, fixture.transport());
    defer manager.deinit();
    try manager.sync(&doc, true);
    manager.finishActive();
    try manager.sync(&doc, true);
    manager.finishActive();
    const key = (try Identity.from(fixture_offline)).key;
    const cached = (try readCache(std.testing.io, root, key)).?;
    try std.testing.expectEqual(Semantic.not_found, cached.kind);
    try std.testing.expectEqual(@as(u32, 1), fixture.calls.load(.acquire));
    try std.testing.expect(manager.retryDelayMilliseconds() > 59 * 60 * 1000);
    try std.testing.expect(manager.retryDelayMilliseconds() <= 60 * 60 * 1000);
    // Expire in memory without sleeping, then resolve an existing online profile.
    manager.lookup(key).?.next_ms = 0;
    fixture.mode = .default;
    try manager.sync(&doc, true);
    manager.finishActive();
    try expectFace(manager.defaults[avatar.defaultIndex(fixture_online_uuid)], manager.face(fixture_offline).*);
    try std.testing.expectEqual(Semantic.default, (try readCache(std.testing.io, root, key)).?.kind);
    try std.testing.expectEqualSlices(u8, fixture_offline.uuid, doc.accounts[0].uuid);
    // Microsoft profiles skip name lookup even if the name service would say missing.
    var microsoft = fixture_offline;
    microsoft.kind = .microsoft;
    microsoft.uuid = fixture_online_uuid;
    const microsoft_doc = fixtureDocument(&.{microsoft}, microsoft.id);
    const before = fixture.calls.load(.acquire);
    try manager.sync(&microsoft_doc, true);
    manager.finishActive();
    try manager.sync(&microsoft_doc, true);
    manager.finishActive();
    try std.testing.expectEqual(before + 1, fixture.calls.load(.acquire));
}

test "avatar transient failure preserves stale face and does not persist negative" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    const key = (try Identity.from(fixture_offline)).key;
    const stale: Cached = .{ .face = fixtureFace(), .timestamp = realSeconds(std.testing.io) - positive_ttl - 1, .kind = .online };
    var cancellation: std.atomic.Value(bool) = .init(false);
    try writeCache(std.testing.io, root, key, stale, &cancellation);
    var fixture: Fixture = .{ .mode = .failure };
    var manager = try Manager.initWithTransport(std.testing.allocator, std.testing.io, root, .{}, true, fixture.transport());
    defer manager.deinit();
    const doc = fixtureDocument(&.{fixture_offline}, fixture_offline.id);
    try manager.sync(&doc, true);
    manager.finishActive();
    try expectFace(stale.face, manager.face(fixture_offline).*);
    try manager.sync(&doc, true);
    manager.finishActive();
    try expectFace(stale.face, manager.face(fixture_offline).*);
    try std.testing.expect(manager.retryDelayMilliseconds() > 4 * 60 * 1000);
    try std.testing.expect(manager.retryDelayMilliseconds() <= 5 * 60 * 1000);
    const persisted = (try readCache(std.testing.io, root, key)).?;
    try std.testing.expectEqual(stale.timestamp, persisted.timestamp);
    try std.testing.expectEqual(Semantic.online, persisted.kind);
    try expectFace(stale.face, persisted.face);
    var fresh = fixture_offline;
    fresh.id = "fresh";
    fresh.name = "FreshPlayer";
    const fresh_doc = fixtureDocument(&.{fresh}, fresh.id);
    try manager.sync(&fresh_doc, true);
    manager.finishActive();
    try manager.sync(&fresh_doc, true);
    manager.finishActive();
    try std.testing.expectError(error.FileNotFound, readCache(std.testing.io, root, (try Identity.from(fresh)).key));
}

test "avatar corrupt disk cache falls back locally and network disabled never calls transport" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    const dir = try tmp.dir.createDirPathOpen(std.testing.io, "avatars", .{});
    defer dir.close(std.testing.io);
    const key = (try Identity.from(fixture_offline)).key;
    const filename = cacheFilename(key);
    const file = try dir.createFile(std.testing.io, &filename, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "corrupt cache");
    var fixture: Fixture = .{};
    var manager = try Manager.initWithTransport(std.testing.allocator, std.testing.io, root, .{}, false, fixture.transport());
    defer manager.deinit();
    const doc = fixtureDocument(&.{fixture_offline}, fixture_offline.id);
    try manager.sync(&doc, true);
    manager.finishActive();
    try expectFace(manager.defaults[avatar.defaultIndex(fixture_offline.uuid)], manager.face(fixture_offline).*);
    try manager.sync(&doc, true);
    try std.testing.expect(!manager.isBusy());
    try std.testing.expectEqual(@as(u32, 0), fixture.calls.load(.acquire));
}

test "avatar switched account cancels running worker without join and discards late response" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    var fixture: Fixture = .{ .gate = true, .mode = .default };
    var manager = try Manager.initWithTransport(std.testing.allocator, std.testing.io, root, .{}, true, fixture.transport());
    defer manager.deinit();
    // Always release the gate on assertion failure before manager shutdown joins.
    defer fixture.release.set(std.testing.io);
    const doc = fixtureDocument(&.{fixture_offline}, fixture_offline.id);
    try manager.sync(&doc, true);
    manager.finishActive();
    try manager.sync(&doc, true);
    try fixture.started.wait(std.testing.io);
    const old_job = manager.active.?;
    var second = fixture_offline;
    second.id = "second";
    second.name = "PlayerTwo";
    second.uuid = fixture_online_uuid;
    const switched = fixtureDocument(&.{ fixture_offline, second }, second.id);
    try manager.sync(&switched, true);
    try std.testing.expect(manager.active.? == old_job);
    try std.testing.expect(old_job.cancellation.load(.acquire));
    try expectFace(manager.defaults[avatar.defaultIndex(second.uuid)], manager.face(second).*);
    try manager.sync(&switched, false);
    try std.testing.expect(manager.active.? == old_job);
    try std.testing.expect(!manager.enabled);
    fixture.release.set(std.testing.io);
    manager.finishActive();
    try std.testing.expect(!manager.isBusy());
    try expectFace(manager.defaults[avatar.defaultIndex(fixture_offline.uuid)], manager.face(fixture_offline).*);
    try std.testing.expectError(error.FileNotFound, readCache(std.testing.io, root, (try Identity.from(fixture_offline)).key));
    try manager.sync(&switched, false);
    try manager.sync(&switched, false);
    try std.testing.expect(!manager.isBusy());
    try std.testing.expectEqual(std.math.maxInt(u32), manager.retryDelayMilliseconds());
}

test "avatar completed worker cannot publish to mismatched selected key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    var manager = try Manager.init(std.testing.allocator, std.testing.io, root, .{}, false);
    defer manager.deinit();
    const identity = try Identity.from(fixture_offline);
    _ = manager.ensureEntry(identity);
    const job = try Job.create(&manager, identity, .network);
    job.value = .{ .face = fixtureFace(), .timestamp = realSeconds(std.testing.io), .kind = .online };
    job.done.store(true, .release);
    manager.active = job;
    manager.enabled = true;
    var unrelated = identity.key;
    unrelated[0] ^= 1;
    manager.selected = unrelated;
    manager.tick();
    try expectFace(manager.defaults[avatar.defaultIndex(fixture_offline.uuid)], manager.face(fixture_offline).*);
}

test "avatar entries bounded at 32 and copied options do not borrow UI input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    var proxy = [_]u8{ 'p', 'r', 'o', 'x', 'y' };
    var ca = [_]u8{ 'c', 'a' };
    var manager = try Manager.init(std.testing.allocator, std.testing.io, root, .{ .proxy = &proxy, .ca_bundle = &ca }, false);
    defer manager.deinit();
    proxy[0] = 'X';
    ca[0] = 'X';
    try std.testing.expectEqualStrings("proxy", manager.options.proxy.?);
    try std.testing.expectEqualStrings("ca", manager.options.ca_bundle.?);
    const selected_identity = try Identity.from(fixture_offline);
    manager.selected = selected_identity.key;
    const selected = manager.ensureEntry(selected_identity);
    selected.face = fixtureFace();
    for (1..70) |number| {
        var uuid: [32]u8 = undefined;
        _ = try std.fmt.bufPrint(&uuid, "{x:0>32}", .{number});
        var account = fixture_offline;
        account.uuid = &uuid;
        _ = manager.ensureEntry(try Identity.from(account));
    }
    var count: usize = 0;
    for (manager.entries) |entry| {
        if (entry != null) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 32), count);
    try expectFace(fixtureFace(), manager.lookup(selected_identity.key).?.face);
}

fn primeFixtureSelection(manager: *Manager, account: config.Account) !void {
    const identity = try Identity.from(account);
    var cancellation: std.atomic.Value(bool) = .init(false);
    try writeCache(manager.io, manager.root, identity.key, .{
        .face = manager.defaults[avatar.defaultIndex(&identity.uuid)],
        .timestamp = realSeconds(manager.io),
        .kind = .default,
    }, &cancellation);
    const doc = fixtureDocument(&.{account}, account.id);
    try manager.sync(&doc, true);
    manager.finishActive();
}
fn fixtureRow() config.Account {
    var row = fixture_offline;
    row.id = "visible-row";
    row.uuid = "00000000000000000000000000000002";
    return row;
}

test "avatar visible unselected row publishes skin without changing selection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    var fixture: Fixture = .{};
    var manager = try Manager.initWithTransport(std.testing.allocator, std.testing.io, root, .{}, true, fixture.transport());
    defer manager.deinit();
    try primeFixtureSelection(&manager, fixture_offline);
    const selected_key = manager.selected.?;
    const selected_face = manager.face(fixture_offline).*;
    const row = fixtureRow();
    manager.beginPicker(true);
    try manager.request(row);
    try std.testing.expect(manager.active.?.prefetch);
    try std.testing.expectEqual(Mode.cache, manager.active.?.mode);
    manager.finishActive();
    try std.testing.expectEqual(@as(u32, 1), manager.retryDelayMilliseconds());
    manager.beginPicker(true);
    try manager.request(row);
    try std.testing.expectEqual(Mode.network, manager.active.?.mode);
    manager.finishActive();
    try expectFace(try image.decodeFace(std.testing.allocator, fixture_png), manager.face(row).*);
    try std.testing.expect(sameKey(selected_key, manager.selected.?));
    try expectFace(selected_face, manager.face(fixture_offline).*);
    try std.testing.expectEqual(@as(u32, 3), fixture.calls.load(.acquire));
    const cached = (try readCache(std.testing.io, root, (try Identity.from(row)).key)).?;
    try std.testing.expectEqual(Semantic.online, cached.kind);
    try expectFace(cached.face, manager.face(row).*);
}

test "avatar visible online default cache is shared when row later selected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    var fixture: Fixture = .{ .mode = .default };
    var manager = try Manager.initWithTransport(std.testing.allocator, std.testing.io, root, .{}, true, fixture.transport());
    defer manager.deinit();
    try primeFixtureSelection(&manager, fixture_offline);
    const row = fixtureRow();
    manager.beginPicker(true);
    try manager.request(row);
    manager.finishActive();
    manager.beginPicker(true);
    try manager.request(row);
    manager.finishActive();
    const expected = manager.defaults[avatar.defaultIndex(fixture_online_uuid)];
    try expectFace(expected, manager.face(row).*);
    const cached = (try readCache(std.testing.io, root, (try Identity.from(row)).key)).?;
    try std.testing.expectEqual(Semantic.default, cached.kind);
    manager.beginPicker(false);
    const doc = fixtureDocument(&.{ fixture_offline, row }, row.id);
    try manager.sync(&doc, true);
    try std.testing.expect(!manager.isBusy());
    try expectFace(expected, manager.face(row).*);
    try std.testing.expectEqual(@as(u32, 2), fixture.calls.load(.acquire));
    try std.testing.expectEqualStrings(row.uuid, doc.accounts[1].uuid);
    var offline = try Manager.initWithTransport(std.testing.allocator, std.testing.io, root, .{}, false, fixture.transport());
    defer offline.deinit();
    try primeFixtureSelection(&offline, fixture_offline);
    offline.beginPicker(true);
    try offline.request(row);
    offline.finishActive();
    try expectFace(expected, offline.face(row).*);
    try offline.request(row);
    try std.testing.expect(!offline.isBusy());
    try std.testing.expectEqual(@as(u32, 2), fixture.calls.load(.acquire));
}

test "avatar picker closing cancels prefetch without joining and rejects late response" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    var fixture: Fixture = .{ .gate = true, .mode = .default };
    var manager = try Manager.initWithTransport(std.testing.allocator, std.testing.io, root, .{}, true, fixture.transport());
    defer manager.deinit();
    defer fixture.release.set(std.testing.io);
    try primeFixtureSelection(&manager, fixture_offline);
    const row = fixtureRow();
    const expected = manager.face(row).*;
    manager.beginPicker(true);
    try manager.request(row);
    manager.finishActive();
    manager.beginPicker(true);
    try manager.request(row);
    try fixture.started.wait(std.testing.io);
    const job = manager.active.?;
    manager.beginPicker(false);
    try std.testing.expect(manager.active.? == job);
    try std.testing.expect(job.cancellation.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), manager.visible_count);
    try manager.request(row);
    try std.testing.expect(manager.active.? == job);
    fixture.release.set(std.testing.io);
    manager.finishActive();
    try expectFace(expected, manager.face(row).*);
    try std.testing.expectError(error.FileNotFound, readCache(std.testing.io, root, (try Identity.from(row)).key));
    try std.testing.expect(manager.retryDelayMilliseconds() > 23 * 60 * 60 * 1000);
}

test "avatar completed prefetch requires a visible interest in the latest picker frame" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    var manager = try Manager.init(std.testing.allocator, std.testing.io, root, .{}, false);
    defer manager.deinit();
    try primeFixtureSelection(&manager, fixture_offline);
    const row = fixtureRow();
    const identity = try Identity.from(row);
    const expected = manager.ensureEntry(identity).face;
    const job = try Job.create(&manager, identity, .cache);
    job.prefetch = true;
    job.value = .{ .face = fixtureFace(), .timestamp = realSeconds(std.testing.io), .kind = .online };
    job.done.store(true, .release);
    manager.active = job;
    manager.beginPicker(true);
    try manager.request(row);
    try std.testing.expect(manager.hasInterest(identity.key));
    manager.beginPicker(true);
    manager.tick();
    try std.testing.expect(!manager.isBusy());
    try expectFace(expected, manager.face(row).*);
    try std.testing.expect(!manager.lookup(identity.key).?.cache_checked);
}

test "avatar visible first-row failure backs off without starving another row" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    var fixture: Fixture = .{ .mode = .failure };
    var manager = try Manager.initWithTransport(std.testing.allocator, std.testing.io, root, .{}, true, fixture.transport());
    defer manager.deinit();
    try primeFixtureSelection(&manager, fixture_offline);
    const first = fixtureRow();
    var second = first;
    second.id = "second-visible";
    second.uuid = "00000000000000000000000000000003";
    manager.beginPicker(true);
    try manager.request(first);
    try manager.request(second);
    manager.finishActive();
    manager.beginPicker(true);
    try manager.request(first);
    try manager.request(second);
    manager.finishActive();
    try std.testing.expectEqual(@as(u32, 1), fixture.calls.load(.acquire));
    fixture.mode = .default;
    manager.beginPicker(true);
    try manager.request(first);
    try std.testing.expect(!manager.isBusy());
    try manager.request(second);
    try std.testing.expect(sameKey(manager.active.?.identity.key, (try Identity.from(second)).key));
    manager.finishActive();
    manager.beginPicker(true);
    try manager.request(first);
    try std.testing.expect(!manager.isBusy());
    try manager.request(second);
    manager.finishActive();
    try expectFace(manager.defaults[avatar.defaultIndex(fixture_online_uuid)], manager.face(second).*);
    try std.testing.expectEqual(@as(u32, 3), fixture.calls.load(.acquire));
    try std.testing.expect(manager.retryDelayMilliseconds() > 4 * 60 * 1000);
    try std.testing.expect(manager.retryDelayMilliseconds() <= 5 * 60 * 1000);
}

test "avatar changed selection cancels prefetch and starts selected work first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    var fixture: Fixture = .{ .gate = true, .mode = .default };
    var manager = try Manager.initWithTransport(std.testing.allocator, std.testing.io, root, .{}, true, fixture.transport());
    defer manager.deinit();
    defer fixture.release.set(std.testing.io);
    try primeFixtureSelection(&manager, fixture_offline);
    const row = fixtureRow();
    manager.beginPicker(true);
    try manager.request(row);
    manager.finishActive();
    manager.beginPicker(true);
    try manager.request(row);
    try fixture.started.wait(std.testing.io);
    const old_job = manager.active.?;
    var selected = row;
    selected.id = "new-selection";
    selected.uuid = "00000000000000000000000000000003";
    const doc = fixtureDocument(&.{ fixture_offline, row, selected }, selected.id);
    try manager.sync(&doc, true);
    try std.testing.expect(manager.active.? == old_job);
    try std.testing.expect(old_job.cancellation.load(.acquire));
    fixture.release.set(std.testing.io);
    manager.finishActive();
    try manager.sync(&doc, true);
    const selected_job = manager.active.?;
    try std.testing.expect(!selected_job.prefetch);
    try std.testing.expect(sameKey(selected_job.identity.key, (try Identity.from(selected)).key));
    manager.beginPicker(true);
    try manager.request(row);
    try std.testing.expect(manager.active.? == selected_job);
    manager.finishActive();
    try manager.sync(&doc, true);
    try std.testing.expect(!manager.active.?.prefetch);
    manager.finishActive();
    try expectFace(manager.defaults[avatar.defaultIndex(fixture_online_uuid)], manager.face(selected).*);
    try expectFace(manager.defaults[avatar.defaultIndex(row.uuid)], manager.face(row).*);
}

test "avatar many visible interests retain active prefetch and bound entry memory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureRoot(&tmp);
    defer std.testing.allocator.free(root);
    var manager = try Manager.init(std.testing.allocator, std.testing.io, root, .{}, false);
    defer manager.deinit();
    try primeFixtureSelection(&manager, fixture_offline);
    const row = fixtureRow();
    const key = (try Identity.from(row)).key;
    manager.beginPicker(true);
    try manager.request(row);
    const job = manager.active.?;
    for (10..80) |number| {
        var uuid: [32]u8 = undefined;
        _ = try std.fmt.bufPrint(&uuid, "{x:0>32}", .{number});
        var account = row;
        account.uuid = &uuid;
        try manager.request(account);
    }
    try std.testing.expect(manager.active.? == job);
    try std.testing.expect(manager.hasInterest(key));
    try std.testing.expect(manager.lookup(key) != null);
    try std.testing.expect(manager.visible_count <= capacity);
    var count: usize = 0;
    for (manager.entries) |entry| {
        if (entry != null) count += 1;
    }
    try std.testing.expectEqual(@as(usize, capacity), count);
    manager.finishActive();
    try std.testing.expect(manager.lookup(key).?.cache_checked);
    try std.testing.expectEqual(@as(u32, 1), manager.retryDelayMilliseconds());
}
