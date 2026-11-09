//! Launcher-wide defaults are published by the application. Transfers copy them
//! before starting; no process environment or game launch settings are modified.
const std = @import("std");
const config = @import("proxy_config.zig");
const system = @import("proxy_system.zig");
const credentials = @import("credentials.zig");
const public_network = @import("public_network.zig");
const c = @import("curl").libcurl;
const A = std.mem.Allocator;

pub const Source = enum { none, environment, windows, macos, gnome, kde, manual, explicit };
pub const Route = struct {
    allocator: A,
    proxy: [:0]u8,
    bypass: [:0]u8,
    username: [:0]u8,
    password: [:0]u8,
    source: Source,
    pub fn deinit(self: *Route) void {
        for ([_][:0]u8{ self.proxy, self.bypass, self.username, self.password }) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        self.* = undefined;
    }
};

pub const Policy = struct {
    allocator: A,
    io: std.Io,
    settings: config.Settings,
    /// Immutable process-start environment. Owner must outlive this policy.
    environ: ?*const std.process.Environ.Map,
    explicit: ?[:0]u8,
    password_override: ?credentials.Secret = null,

    pub fn init(a: A, io: std.Io, settings: config.Settings, environ: ?*const std.process.Environ.Map, explicit: ?[]const u8) !Policy {
        try config.validate(settings);
        if (explicit) |value| try validateProxy(value);
        const copied = try config.clone(a, settings);
        errdefer config.deinit(a, copied);
        const copied_explicit = if (explicit) |value| try a.dupeSentinel(u8, value, 0) else null;
        errdefer if (copied_explicit) |value| a.free(value);
        if (explicit == null and settings.mode == .manual) if (settings.credential_ref) |reference| try retainCredential(io, reference);
        return .{ .allocator = a, .io = io, .settings = copied, .environ = environ, .explicit = copied_explicit };
    }
    pub fn clone(self: *const Policy, a: A) !Policy {
        var copied = try init(a, self.io, self.settings, self.environ, self.explicit);
        errdefer copied.deinit();
        if (self.password_override) |secret| try copied.setPassword(secret.bytes);
        return copied;
    }
    pub fn setPassword(self: *Policy, password: []const u8) !void {
        if (password.len > 512 or std.mem.indexOfScalar(u8, password, 0) != null) return error.InvalidProxyPassword;
        const bytes = try self.allocator.dupe(u8, password);
        if (self.password_override) |*old| old.deinit();
        self.password_override = .{ .allocator = self.allocator, .bytes = bytes };
    }
    pub fn deinit(self: *Policy) void {
        if (self.explicit == null and self.settings.mode == .manual) if (self.settings.credential_ref) |reference| releaseCredential(self.io, reference);
        config.deinit(self.allocator, self.settings);
        if (self.password_override) |*secret| secret.deinit();
        if (self.explicit) |value| {
            std.crypto.secureZero(u8, value);
            self.allocator.free(value);
        }
        self.* = undefined;
    }
    /// Worker-only: platform discovery and credential access may block.
    pub fn resolve(self: *const Policy, io: std.Io, url: []const u8) !Route {
        const a = self.allocator;
        var proxy: [:0]u8 = undefined;
        var bypass: [:0]u8 = undefined;
        var source: Source = .none;
        if (self.explicit) |value| {
            proxy = try a.dupeSentinel(u8, value, 0);
            errdefer a.free(proxy);
            bypass = try a.dupeSentinel(u8, "", 0);
            source = .explicit;
        } else switch (self.settings.mode) {
            .direct => {
                proxy = try a.dupeSentinel(u8, "", 0);
                errdefer a.free(proxy);
                bypass = try a.dupeSentinel(u8, "", 0);
            },
            .system => {
                const resolved = try system.resolve(a, io, self.environ, url);
                proxy = resolved.proxy;
                bypass = resolved.bypass;
                source = switch (resolved.source) {
                    .none => .none,
                    .environment => .environment,
                    .windows => .windows,
                    .macos => .macos,
                    .gnome => .gnome,
                    .kde => .kde,
                };
            },
            .manual => {
                const scheme = switch (self.settings.protocol) {
                    .http => "http",
                    .https => "https",
                    .socks5 => "socks5h",
                };
                const host = self.settings.host;
                const ipv6 = std.mem.indexOfScalar(u8, host, ':') != null and !std.mem.startsWith(u8, host, "[");
                proxy = try std.fmt.allocPrintSentinel(a, "{s}://{s}{s}{s}:{d}", .{ scheme, if (ipv6) "[" else "", host, if (ipv6) "]" else "", self.settings.port }, 0);
                errdefer a.free(proxy);
                bypass = try a.dupeSentinel(u8, self.settings.bypass, 0);
                source = .manual;
            },
        }
        errdefer {
            std.crypto.secureZero(u8, proxy);
            a.free(proxy);
            a.free(bypass);
        }
        try validateProxy(proxy);
        if (proxy.len != 0 and try bypasses(url, bypass)) {
            const direct = try a.dupeSentinel(u8, "", 0);
            std.crypto.secureZero(u8, proxy);
            a.free(proxy);
            proxy = direct;
        }
        // Bypass has been resolved for this URL. Never let curl reinterpret the
        // route and accidentally skip the direct public-socket guard.
        const no_bypass = try a.dupeSentinel(u8, "", 0);
        a.free(bypass);
        bypass = no_bypass;
        const username = try a.dupeSentinel(u8, if (source == .manual and proxy.len != 0) self.settings.username else "", 0);
        errdefer a.free(username);
        var secret: ?credentials.Secret = null;
        defer if (secret) |*value| value.deinit();
        if (source == .manual and proxy.len != 0 and self.password_override == null) if (self.settings.credential_ref) |reference| {
            var native = credentials.Native.init() catch return error.ProxyCredentialsUnavailable;
            defer native.deinit();
            secret = native.store().get(a, reference) catch return error.ProxyCredentialsUnavailable;
        };
        const password = try a.dupeSentinel(u8, if (source == .manual and proxy.len != 0 and self.password_override != null) self.password_override.?.bytes else if (secret) |value| value.bytes else "", 0);
        return .{ .allocator = a, .proxy = proxy, .bypass = bypass, .username = username, .password = password, .source = source };
    }
};

// Track every live manual policy, including clones made by existing tasks. Vault
// cleanup waits for the last policy using an old reference; new references never
// delay that cleanup. The registry owns no plaintext and performs no vault I/O.
const CredentialUse = struct { reference: credentials.Reference, users: usize, next: ?*CredentialUse };
var credential_mutex: std.Io.Mutex = .init;
var credential_uses: ?*CredentialUse = null;
fn retainCredential(io: std.Io, reference: []const u8) !void {
    credential_mutex.lockUncancelable(io);
    defer credential_mutex.unlock(io);
    var item = credential_uses;
    while (item) |entry| : (item = entry.next) {
        if (std.mem.eql(u8, &entry.reference, reference)) {
            entry.users += 1;
            return;
        }
    }
    const entry = try std.heap.page_allocator.create(CredentialUse);
    entry.* = .{ .reference = reference[0..32].*, .users = 1, .next = credential_uses };
    credential_uses = entry;
}
fn releaseCredential(io: std.Io, reference: []const u8) void {
    credential_mutex.lockUncancelable(io);
    defer credential_mutex.unlock(io);
    var link = &credential_uses;
    while (link.*) |entry| : (link = &entry.next) {
        if (!std.mem.eql(u8, &entry.reference, reference)) continue;
        entry.users -= 1;
        if (entry.users == 0) {
            link.* = entry.next;
            std.heap.page_allocator.destroy(entry);
        }
        return;
    }
    unreachable;
}
pub fn credentialInUse(io: std.Io, reference: []const u8) bool {
    credential_mutex.lockUncancelable(io);
    defer credential_mutex.unlock(io);
    var item = credential_uses;
    while (item) |entry| : (item = entry.next) {
        if (std.mem.eql(u8, &entry.reference, reference)) return true;
    }
    return false;
}
var mutex: std.Io.Mutex = .init;
var current: ?Policy = null;
/// Application-owned publication. Environment is immutable and outlives workers.
pub fn setDefault(io: std.Io, settings: config.Settings, environ: ?*const std.process.Environ.Map) !void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (current) |*old| if (config.same(old.settings, settings) and old.environ == environ) return;
    const next = try Policy.init(std.heap.page_allocator, io, settings, environ, null);
    if (current) |*old| old.deinit();
    current = next;
}
pub fn clearDefault(io: std.Io) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (current) |*old| old.deinit();
    current = null;
}
pub fn capture(a: A, io: std.Io, explicit: ?[]const u8) !Policy {
    if (explicit) |value| return Policy.init(a, io, .{}, null, value);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (current) |*value| return value.clone(a);
    return Policy.init(a, io, .{}, null, null);
}

fn validateProxy(value: []const u8) !void {
    if (value.len == 0) return;
    if (value.len > 16 * 1024) return error.InvalidProxy;
    for (value) |byte| if (byte <= 32 or byte == 127) return error.InvalidProxy;
    if (std.mem.indexOf(u8, value, "://") != null) {
        const uri = std.Uri.parse(value) catch return error.InvalidProxy;
        if (!(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https") or
            std.ascii.eqlIgnoreCase(uri.scheme, "socks5") or std.ascii.eqlIgnoreCase(uri.scheme, "socks5h") or
            std.ascii.eqlIgnoreCase(uri.scheme, "socks4") or std.ascii.eqlIgnoreCase(uri.scheme, "socks4a"))) return error.InvalidProxy;
        if (uri.host == null or uri.host.?.percent_encoded.len == 0 or uri.query != null or uri.fragment != null) return error.InvalidProxy;
        const path = uri.path.percent_encoded;
        if (path.len != 0 and !std.mem.eql(u8, path, "/")) return error.InvalidProxy;
    }
}

pub fn bypasses(url: []const u8, list: []const u8) !bool {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const encoded = (uri.host orelse return error.InvalidUrl).percent_encoded;
    var buffer: [1024]u8 = undefined;
    const raw = (std.Uri.Component{ .percent_encoded = encoded }).toRaw(&buffer) catch return error.InvalidUrl;
    const host = std.mem.trimEnd(u8, std.mem.trim(u8, raw, "[]"), ".");
    var entries = std.mem.tokenizeAny(u8, list, ",;");
    while (entries.next()) |entry| {
        const pattern = std.mem.trim(u8, entry, " ");
        if (std.mem.eql(u8, pattern, "*")) return true;
        if (std.ascii.eqlIgnoreCase(pattern, "<local>") and std.mem.indexOfScalar(u8, host, '.') == null and std.mem.indexOfScalar(u8, host, ':') == null) return true;
        if (std.mem.indexOfScalar(u8, pattern, '/')) |slash| {
            if (cidrMatches(host, pattern[0..slash], pattern[slash + 1 ..])) return true;
            continue;
        }
        const suffix = if (std.mem.startsWith(u8, pattern, "*.")) pattern[2..] else if (std.mem.startsWith(u8, pattern, ".")) pattern[1..] else pattern;
        if (suffix.len == 0 or std.mem.indexOfScalar(u8, suffix, '*') != null) continue;
        const unbracketed = std.mem.trimEnd(u8, std.mem.trim(u8, suffix, "[]"), ".");
        if (unbracketed.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(host, unbracketed)) return true;
        if (host.len > unbracketed.len and host[host.len - unbracketed.len - 1] == '.' and std.ascii.eqlIgnoreCase(host[host.len - unbracketed.len ..], unbracketed)) return true;
    }
    return false;
}
fn cidrMatches(host: []const u8, network: []const u8, bits_text: []const u8) bool {
    const ip = std.Io.net.IpAddress.parse(host, 0) catch return false;
    const net = std.Io.net.IpAddress.parse(network, 0) catch return false;
    const bits = std.fmt.parseInt(u8, bits_text, 10) catch return false;
    return switch (ip) {
        .ip4 => |v| if (net == .ip4) prefixMatches(&v.bytes, &net.ip4.bytes, bits) else false,
        .ip6 => |v| if (net == .ip6) prefixMatches(&v.bytes, &net.ip6.bytes, bits) else false,
    };
}
fn prefixMatches(a: []const u8, b: []const u8, bits: u8) bool {
    if (bits > a.len * 8) return false;
    const full = bits / 8;
    if (!std.mem.eql(u8, a[0..full], b[0..full])) return false;
    const remaining: u3 = @intCast(bits % 8);
    if (remaining == 0) return true;
    const mask: u8 = @as(u8, 255) << @as(u3, @intCast(8 - @as(u4, remaining)));
    return a[full] & mask == b[full] & mask;
}

/// With a trusted proxy, DNS and connection checks belong to the proxy. Keep
/// rejecting explicitly local/private targets; direct routes retain socket checks.
/// curl's URL parser normalizes unusual IPv4 forms (127.1, decimal, octal).
pub fn guardTarget(a: A, url: []const u8) !void {
    const handle = c.curl_url() orelse return error.OutOfMemory;
    defer c.curl_url_cleanup(handle);
    const input = try a.dupeSentinel(u8, url, 0);
    defer a.free(input);
    if (c.curl_url_set(handle, c.CURLUPART_URL, input.ptr, 0) != c.CURLUE_OK) return error.InvalidUrl;
    var result: [*c]u8 = null;
    if (c.curl_url_get(handle, c.CURLUPART_HOST, &result, 0) != c.CURLUE_OK) return error.InvalidUrl;
    defer c.curl_free(result);
    const host = std.mem.trimEnd(u8, std.mem.trim(u8, std.mem.span(result), "[]"), ".");
    if (std.Io.net.IpAddress.parse(host, 0)) |ip| {
        const allowed = switch (ip) {
            .ip4 => |v| public_network.isPublicV4(v.bytes),
            .ip6 => |v| public_network.isPublicV6(v.bytes),
        };
        if (!allowed) return error.NonPublicAddress;
    } else |_| {
        if (std.mem.indexOfScalar(u8, host, '.') == null or
            std.ascii.eqlIgnoreCase(host, "localhost") or endsWithIgnoreCase(host, ".localhost") or
            endsWithIgnoreCase(host, ".local") or endsWithIgnoreCase(host, ".internal")) return error.NonPublicAddress;
    }
}
fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

test "proxy bypass respects domain boundaries IPv6 CIDR and local names" {
    try std.testing.expect(try bypasses("https://sub.example.com/file", ".example.com"));
    try std.testing.expect(try bypasses("https://sub.example.com./file", "example.com"));
    try std.testing.expect(!(try bypasses("https://example.com/file", "**example.com")));
    try std.testing.expect(!(try bypasses("https://badexample.com/file", "example.com")));
    try std.testing.expect(try bypasses("http://[::1]/", "localhost,::1"));
    try std.testing.expect(try bypasses("http://10.42.0.1/", "10.0.0.0/8"));
    try std.testing.expect(!(try bypasses("http://11.42.0.1/", "10.0.0.0/8")));
    try std.testing.expect(try bypasses("http://printer/", "<local>"));
}
test "default publication preserves existing policy and explicit direct overrides it" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    defer clearDefault(io);
    try setDefault(io, .{ .mode = .manual, .port = 7888 }, null);
    var old = try capture(a, io, null);
    defer old.deinit();
    try setDefault(io, .{ .mode = .manual, .port = 7999 }, null);
    var old_route = try old.resolve(io, "https://example.com/");
    defer old_route.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:7888", old_route.proxy);
    var direct = try capture(a, io, "");
    defer direct.deinit();
    var route = try direct.resolve(io, "https://example.com/");
    defer route.deinit();
    try std.testing.expectEqualStrings("", route.proxy);
}

fn policyAllocations(a: A) !void {
    var policy = try Policy.init(a, std.testing.io, .{ .mode = .manual, .username = "fixture-user" }, null, null);
    defer policy.deinit();
    try policy.setPassword("fixture-password");
    var copied = try policy.clone(a);
    defer copied.deinit();
    var route = try copied.resolve(std.testing.io, "https://example.com/");
    defer route.deinit();
    try std.testing.expectEqualStrings("fixture-password", route.password);
    var direct = try copied.resolve(std.testing.io, "https://localhost/");
    defer direct.deinit();
    try std.testing.expectEqualStrings("", direct.proxy);
    try std.testing.expectEqualStrings("", direct.password);
}
test "proxy policy clones credentials and releases all allocations on failure" {
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, policyAllocations, .{});
}
