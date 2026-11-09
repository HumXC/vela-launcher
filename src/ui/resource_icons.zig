//! UI-owned bounded image cache. Public artwork loads independently of content mutations.
const std = @import("std");
const dvui = @import("dvui");
const transport = @import("../core/content_transport.zig");
const http = @import("../core/http_transport.zig");
const cache_client = @import("../core/http_cache_client.zig");
const cache_policy = @import("../core/http_cache_policy.zig");
const proxy_policy = @import("../core/proxy_policy.zig");
const providers = @import("../core/content_providers.zig");
const local = @import("../core/local_content.zig");
const theme = @import("theme.zig");
const A = std.mem.Allocator;
pub const side = 64;
pub const Bitmap = [side * side]dvui.Color.PMA;
const max_bytes = 2 * 1024 * 1024;
const capacity = 48;
extern fn WebPGetInfo([*]const u8, usize, *c_int, *c_int) c_int;
const webp_decoder = @import("../core/webp_decode.zig");
extern fn stbi_info_from_memory([*]const u8, c_int, *c_int, *c_int, *c_int) c_int;

pub fn allowedUrl(url: []const u8) bool {
    if (url.len > 4096 or !providers.safeHttpsUrl(url)) return false;
    const uri = std.Uri.parse(url) catch return false;
    const host = uri.host.?.percent_encoded;
    return std.ascii.eqlIgnoreCase(host, "cdn.modrinth.com") or std.ascii.eqlIgnoreCase(host, "media.forgecdn.net") or std.ascii.eqlIgnoreCase(host, "mediafilez.forgecdn.net") or std.ascii.eqlIgnoreCase(host, "edge.forgecdn.net");
}

/// Decodes on the worker. Every cache entry retains only a 64x64 thumbnail.
pub fn decode(a: A, io: std.Io, bytes: []const u8) !Bitmap {
    if (bytes.len < 12 or bytes.len > max_bytes) return error.InvalidIcon;
    var width: c_int = 0;
    var height: c_int = 0;
    const webp = std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP");
    var channels: c_int = 0;
    if (webp) {
        if (WebPGetInfo(bytes.ptr, bytes.len, &width, &height) == 0) return error.InvalidIcon;
    } else if (stbi_info_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height, &channels) == 0) return error.InvalidIcon;
    if (width <= 0 or height <= 0 or width > 1024 or height > 1024) return error.InvalidIcon;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) {
        try local.validatePng(bytes);
        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(a);
        var offset: usize = 8;
        while (offset < bytes.len) {
            const len = std.mem.readInt(u32, bytes[offset..][0..4], .big);
            if (std.mem.eql(u8, bytes[offset + 4 ..][0..4], "IDAT")) try compressed.appendSlice(a, bytes[offset + 8 ..][0..len]);
            offset += len + 12;
        }
        const raw = try @import("nbt_compression").decompress(a, compressed.items, .zlib, 9 * 1024 * 1024, true);
        a.free(raw);
    }
    var result: Bitmap = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    if (webp) {
        const rgba = try a.alloc(u8, w * h * 4);
        defer a.free(rgba);
        webp_decoder.rgbaInto(io, bytes, rgba, @intCast(w * 4)) catch |err| return if (err == error.Canceled) err else error.InvalidIcon;
        for (&result, 0..) |*pixel, i| {
            const at = (sampleIndex(i, w, h) orelse continue) * 4;
            const alpha: u16 = rgba[at + 3];
            pixel.* = .{ .r = @intCast((@as(u16, rgba[at]) * alpha + 127) / 255), .g = @intCast((@as(u16, rgba[at + 1]) * alpha + 127) / 255), .b = @intCast((@as(u16, rgba[at + 2]) * alpha + 127) / 255), .a = @intCast(alpha) };
        }
    } else {
        const image = try dvui.Color.PMAImage.fromImageFile("resource-icon", a, bytes);
        defer a.free(image.pma);
        for (&result, 0..) |*pixel, i| if (sampleIndex(i, w, h)) |at| {
            pixel.* = image.pma[at];
        };
    }
    return result;
}

fn sampleIndex(index: usize, width: usize, height: usize) ?usize {
    const fit_w = if (width >= height) side else @max(1, width * side / height);
    const fit_h = if (height >= width) side else @max(1, height * side / width);
    const x = index % side;
    const y = index / side;
    const left = (side - fit_w) / 2;
    const top = (side - fit_h) / 2;
    if (x < left or x >= left + fit_w or y < top or y >= top + fit_h) return null;
    return (y - top) * height / fit_h * width + (x - left) * width / fit_w;
}
const Job = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    url: []const u8,
    options: transport.Adapter.Options,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    bitmap: ?Bitmap = null,
    fresh_until: i64 = 0,
    policy: ?proxy_policy.Policy = null,
    fn create(io: std.Io, url: []const u8, options: transport.Adapter.Options) !*Job {
        const job = try std.heap.page_allocator.create(Job);
        errdefer std.heap.page_allocator.destroy(job);
        job.* = .{ .arena = .init(std.heap.page_allocator), .io = io, .url = undefined, .options = options };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        job.url = try a.dupe(u8, url);
        if (options.http.proxy) |proxy| job.options.http.proxy = try a.dupe(u8, proxy);
        if (options.http.ca_bundle) |ca| job.options.http.ca_bundle = try a.dupe(u8, ca);
        if (options.cache_root) |root| job.options.cache_root = try a.dupe(u8, root);
        if (options.http.proxy_policy) |policy| {
            job.policy = try policy.clone(a);
            job.options.http.proxy_policy = &job.policy.?;
        }
        // Icons never consume private download credentials or host configuration.
        job.options.curseforge_download_key = null;
        job.options.approved_download_hosts = &.{};
        job.options.download_budget = null;
        return job;
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        if (self.cancel.load(.acquire)) return;
        self.fetch() catch {};
    }
    fn fetch(self: *Job) !void {
        const a = self.arena.allocator();
        const request: http.Request = .{ .url = self.url, .max_response_bytes = max_bytes, .timeout_ms = 5000, .cancel = &self.cancel, .require_public_address = true, .headers = &.{.{ .name = "User-Agent", .value = transport.user_agent }} };
        const started = realSeconds(self.io);
        var response = if (self.options.cache_root) |root| response: {
            const client: cache_client.Client = .{ .allocator = a, .io = self.io, .root = root, .backend = .{ .context = self, .execute = execute } };
            break :response try client.execute(request, self.options.cache_mode, "public-icons");
        } else try execute(self, request);
        defer response.deinit();
        if (response.status != 200 or self.cancel.load(.acquire)) return error.IconUnavailable;
        const bitmap = try decode(a, self.io, response.body);
        if (!self.cancel.load(.acquire)) {
            self.bitmap = bitmap;
            const finished = realSeconds(self.io);
            const decision = cache_policy.evaluate(response.cache_headers.view(), started, finished, finished);
            // Cached response timestamps belong to the coordinator. Reconsult it
            // on the next presentation rather than extending its original TTL.
            self.fresh_until = if (response.source == .network and decision.store and !decision.requires_validation) decision.fresh_until else 0;
        }
    }
    fn execute(context: ?*anyopaque, request: http.Request) anyerror!http.Response {
        const self: *Job = @ptrCast(@alignCast(context.?));
        const a = self.arena.allocator();
        if (self.options.fixture_http) |get| return get(self.options.fixture_context, a, self.io, request);
        var client = try http.Client.init(a, self.io, self.options.http);
        defer client.deinit();
        return client.executeBinary(request);
    }
    fn destroy(self: *Job) void {
        if (self.policy) |*policy| policy.deinit();
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};
const Entry = struct { url: []const u8, bitmap: ?*Bitmap = null, disabled_bitmap: ?*Bitmap = null, touched: u64 = 0, retry_at: i64 = 0, pending: bool = true, fresh_until: i64 = 0 };
pub const Manager = struct {
    allocator: A,
    io: std.Io,
    entries: std.ArrayList(Entry) = .empty,
    active: [4]?*Job = @splat(null),
    connections: ?*http.ConnectionPool = null,
    clock: u64 = 0,
    polled_clock: u64 = 0,
    pub fn init(a: A, io: std.Io) Manager {
        return .{ .allocator = a, .io = io };
    }
    pub fn deinit(self: *Manager) void {
        self.cancelAll();
        for (&self.active) |*slot| if (slot.*) |job| {
            if (job.future) |*future| future.cancel(self.io);
            job.destroy();
            slot.* = null;
        };
        for (self.entries.items) |entry| self.freeEntry(entry);
        self.entries.deinit(self.allocator);
        if (self.connections) |pool| pool.destroy(self.allocator);
    }
    fn freeEntry(self: *Manager, entry: Entry) void {
        self.allocator.free(entry.url);
        if (entry.bitmap) |bitmap| self.allocator.destroy(bitmap);
        if (entry.disabled_bitmap) |bitmap| self.allocator.destroy(bitmap);
    }
    pub fn localDisabled(self: *Manager, bytes: []const u8) ?*const Bitmap {
        const original = self.local(bytes) orelse return null;
        for (self.entries.items) |*entry| {
            if (entry.bitmap != original) continue;
            if (entry.disabled_bitmap) |bitmap| return bitmap;
            const bitmap = self.allocator.create(Bitmap) catch return null;
            for (original, bitmap) |pixel, *gray| {
                const luminance = (@as(u32, pixel.r) * 54 + @as(u32, pixel.g) * 183 + @as(u32, pixel.b) * 19) * 85 / 25600;
                gray.* = .{ .r = @intCast(luminance), .g = @intCast(luminance), .b = @intCast(luminance), .a = pixel.a };
            }
            entry.disabled_bitmap = bitmap;
            return bitmap;
        }
        return null;
    }
    pub fn local(self: *Manager, bytes: []const u8) ?*const Bitmap {
        var storage: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&storage, "local:{x}", .{std.hash.Wyhash.hash(0, bytes)}) catch return null;
        self.clock +%= 1;
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.url, key)) {
            entry.touched = self.clock;
            return entry.bitmap;
        };
        if (self.entries.items.len == capacity) {
            var victim: ?usize = null;
            for (self.entries.items, 0..) |entry, i| {
                if (self.isActive(entry.url)) continue;
                if (victim == null or entry.touched < self.entries.items[victim.?].touched) victim = i;
            }
            if (victim) |i| self.freeEntry(self.entries.swapRemove(i)) else return null;
        }
        const value = decode(self.allocator, self.io, bytes) catch null;
        const bitmap = if (value) |image| block: {
            const owned = self.allocator.create(Bitmap) catch return null;
            owned.* = image;
            break :block owned;
        } else null;
        const owned = self.allocator.dupe(u8, key) catch {
            if (bitmap) |image| self.allocator.destroy(image);
            return null;
        };
        self.entries.append(self.allocator, .{ .url = owned, .bitmap = bitmap, .touched = self.clock, .pending = false, .retry_at = std.math.maxInt(i64) }) catch {
            self.freeEntry(.{ .url = owned, .bitmap = bitmap });
            return null;
        };
        return bitmap;
    }
    pub fn get(self: *Manager, url: ?[]const u8) ?*const Bitmap {
        const value = url orelse return null;
        if (!allowedUrl(value)) return null;
        self.clock +%= 1;
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.url, value)) {
            entry.touched = self.clock;
            if (entry.bitmap == null and now(self.io) >= entry.retry_at) entry.pending = true;
            return entry.bitmap;
        };
        if (self.entries.items.len == capacity) {
            var victim: ?usize = null;
            for (self.entries.items, 0..) |entry, i| {
                if (self.isActive(entry.url)) continue;
                if (victim == null or entry.touched < self.entries.items[victim.?].touched) victim = i;
            }
            if (victim) |i| self.freeEntry(self.entries.swapRemove(i)) else return null;
        }
        const owned = self.allocator.dupe(u8, value) catch return null;
        self.entries.append(self.allocator, .{ .url = owned, .touched = self.clock }) catch {
            self.allocator.free(owned);
        };
        return null;
    }
    /// Signal every lane before joining anywhere; poll/deinit reaps their futures.
    pub fn cancelAll(self: *Manager) void {
        for (self.active) |slot| if (slot) |job| job.cancel.store(true, .release);
        for (self.entries.items) |*entry| entry.pending = false;
    }
    /// Start a new browse presentation (navigation, not a render frame).
    /// Current images remain displayed without per-frame revalidation; a future
    /// presentation must validate expired/no-cache/no-store responses again.
    pub fn resetRequests(self: *Manager) void {
        self.cancelAll();
        const timestamp = realSeconds(self.io);
        for (self.entries.items) |*entry| {
            if (std.mem.startsWith(u8, entry.url, "local:")) continue;
            entry.retry_at = 0;
            if (timestamp < entry.fresh_until) continue;
            if (entry.bitmap) |bitmap| self.allocator.destroy(bitmap);
            if (entry.disabled_bitmap) |bitmap| self.allocator.destroy(bitmap);
            entry.bitmap = null;
            entry.disabled_bitmap = null;
        }
    }
    fn isActive(self: *const Manager, url: []const u8) bool {
        for (self.active) |slot| if (slot) |job| {
            if (std.mem.eql(u8, job.url, url)) return true;
        };
        return false;
    }
    pub fn poll(self: *Manager, options: transport.Adapter.Options) void {
        for (&self.active) |*slot| {
            const job = slot.* orelse continue;
            if (!job.done.load(.acquire)) continue;
            if (job.future) |*future| future.await(self.io);
            if (!job.cancel.load(.acquire)) {
                for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.url, job.url)) {
                    if (job.bitmap) |bitmap| {
                        if (self.allocator.create(Bitmap)) |owned| {
                            owned.* = bitmap;
                            if (entry.bitmap) |old| self.allocator.destroy(old);
                            if (entry.disabled_bitmap) |old| self.allocator.destroy(old);
                            entry.bitmap = owned;
                            entry.disabled_bitmap = null;
                            entry.fresh_until = job.fresh_until;
                        } else |_| {}
                    }
                    entry.pending = false;
                    entry.retry_at = now(self.io) + 30_000;
                    break;
                };
            }
            job.destroy();
            slot.* = null;
        }
        // Only entries requested since the preceding poll remain eligible.
        // Rows that scrolled out of view cannot leave a whole-page backlog.
        for (self.entries.items) |*entry| {
            if (entry.touched <= self.polled_clock) entry.pending = false;
        }
        self.polled_clock = self.clock;
        for (&self.active) |*slot| {
            if (slot.* != null) continue;
            var candidate: ?usize = null;
            for (self.entries.items, 0..) |entry, i| {
                if (!entry.pending or self.isActive(entry.url)) continue;
                if (candidate == null or entry.touched > self.entries.items[candidate.?].touched) candidate = i;
            }
            const entry = &self.entries.items[candidate orelse break];
            entry.pending = false;
            entry.retry_at = now(self.io) + 30_000;
            var job_options = options;
            if (options.fixture_http == null) {
                if (self.connections == null) self.connections = http.ConnectionPool.create(self.allocator) catch continue;
                job_options.http.connections = self.connections;
            }
            const job = Job.create(self.io, entry.url, job_options) catch continue;
            job.future = self.io.concurrent(Job.run, .{job}) catch {
                job.destroy();
                continue;
            };
            slot.* = job;
        }
    }
    pub fn busy(self: *const Manager) bool {
        for (self.active) |slot| if (slot != null) return true;
        for (self.entries.items) |entry| if (entry.pending) return true;
        return false;
    }
};
fn realSeconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}
fn now(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).toMilliseconds());
}

pub fn draw(src: std.builtin.SourceLocation, bitmap: ?*const Bitmap, size: f32, rect: ?dvui.Rect) void {
    const options: dvui.Options = .{ .rect = rect, .min_size_content = .all(size), .max_size_content = .size(.all(size)), .padding = .all(0), .margin = .{ .w = if (rect == null) 16 else 0 }, .corners = .all(theme.controlRadius()), .gravity_y = 0.5 };
    if (bitmap) |pixels| {
        _ = @import("surface.zig").image(src, .{ .source = .{ .pixelsPMA = .{ .rgba = @constCast(pixels)[0..], .width = side, .height = side, .invalidation = .bytes } } }, options);
    } else dvui.icon(src, "资源图标", dvui.entypo.archive, .{}, options.override(.{ .color_text = .{ .color = theme.colors.accent } }));
}

const IconFixture = struct {
    calls: usize = 0,
    control: []const u8 = "max-age=3600",
    fn get(context: ?*anyopaque, a: A, _: std.Io, _: http.Request) !http.Response {
        const self: *IconFixture = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        // A self-contained uncompressed 1x1, 24-bit BMP; no external assets.
        const bytes = try a.alloc(u8, 58);
        errdefer a.free(bytes);
        @memset(bytes, 0);
        @memcpy(bytes[0..2], "BM");
        std.mem.writeInt(u32, bytes[2..6], 58, .little);
        std.mem.writeInt(u32, bytes[10..14], 54, .little);
        std.mem.writeInt(u32, bytes[14..18], 40, .little);
        std.mem.writeInt(u32, bytes[18..22], 1, .little);
        std.mem.writeInt(u32, bytes[22..26], 1, .little);
        std.mem.writeInt(u16, bytes[26..28], 1, .little);
        std.mem.writeInt(u16, bytes[28..30], 24, .little);
        bytes[56] = 255;
        return .{ .status = 200, .body = bytes, .allocation = bytes, .allocator = a, .cache_headers = try @import("../core/http_cache_headers.zig").Owned.clone(a, .{ .cache_control = self.control }) };
    }
    fn wait(_: ?*anyopaque, _: A, io: std.Io, request: http.Request) !http.Response {
        while (!request.cancel.?.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
        return error.Canceled;
    }
};

test "icon lanes bound concurrency deduplicate and protect active entries" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    var buffer: [128]u8 = undefined;
    for (0..8) |i| _ = manager.get(try std.fmt.bufPrint(&buffer, "https://cdn.modrinth.com/{d}.png", .{i}));
    const options: transport.Adapter.Options = .{ .fixture_http = IconFixture.wait };
    manager.poll(options);
    for (manager.active, 0..) |slot, i| {
        const job = slot orelse return error.MissingLane;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "https://cdn.modrinth.com/{d}.png", .{7 - i}), job.url);
        _ = manager.get(job.url);
    }
    manager.poll(options);
    for (manager.active, 0..) |slot, i| {
        for (manager.active[0..i]) |other| try std.testing.expect(!std.mem.eql(u8, slot.?.url, other.?.url));
    }
    for (8..80) |i| _ = manager.get(try std.fmt.bufPrint(&buffer, "https://cdn.modrinth.com/{d}.png", .{i}));
    try std.testing.expectEqual(@as(usize, capacity), manager.entries.items.len);
    for (manager.active) |slot| {
        var found = false;
        for (manager.entries.items) |entry| if (std.mem.eql(u8, entry.url, slot.?.url)) {
            found = true;
        };
        try std.testing.expect(found);
    }
    manager.cancelAll();
    for (manager.active) |slot| try std.testing.expect(slot.?.cancel.load(.acquire));
    for (manager.entries.items) |entry| try std.testing.expect(!entry.pending);
    // defer deinit must cancel and join every lane, including blocked fixtures.
}

test "icon fixture disk cache survives independent jobs without real networking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var fixture: IconFixture = .{};
    const options: transport.Adapter.Options = .{ .cache_root = root, .fixture_http = IconFixture.get, .fixture_context = &fixture };
    for (0..2) |_| {
        const job = try Job.create(std.testing.io, "https://cdn.modrinth.com/cached.bmp", options);
        defer job.destroy();
        try std.testing.expect(job.options.cache_root.?.ptr != root.ptr);
        try job.fetch();
        try std.testing.expect(job.bitmap != null);
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "icon no-store and no-cache pixels last one presentation" {
    for ([_][]const u8{ "no-store", "no-cache" }) |control| {
        var fixture: IconFixture = .{ .control = control };
        const url = "https://cdn.modrinth.com/presentation.bmp";
        const job = try Job.create(std.testing.io, url, .{ .fixture_http = IconFixture.get, .fixture_context = &fixture });
        defer job.destroy();
        try job.fetch();
        try std.testing.expectEqual(@as(i64, 0), job.fresh_until);
        var manager = Manager.init(std.testing.allocator, std.testing.io);
        defer manager.deinit();
        const bitmap = try std.testing.allocator.create(Bitmap);
        bitmap.* = job.bitmap.?;
        try manager.entries.append(std.testing.allocator, .{ .url = try std.testing.allocator.dupe(u8, url), .bitmap = bitmap, .pending = false, .fresh_until = job.fresh_until });
        try std.testing.expect(manager.get(url).? == bitmap);
        try std.testing.expect(!manager.busy());
        manager.resetRequests();
        try std.testing.expect(manager.get(url) == null);
        try std.testing.expect(manager.busy());
    }
}
