//! Per-URL system proxy discovery. Call ONLY from an ordinary worker OS thread:
//! native PAC lookup and desktop configuration queries may block. No logging,
//! process-global environment access, or environment mutation is performed.
//! The caller must set both CURLOPT_PROXY and CURLOPT_NOPROXY explicitly and
//! resolve again after a redirect; native decisions are specific to this URL.
const std = @import("std");
const builtin = @import("builtin");
const A = std.mem.Allocator;

pub const Source = enum { none, environment, windows, macos, gnome, kde };
pub const Resolved = struct {
    proxy: [:0]u8,
    /// curl-compatible bypass list. Native per-URL bypass may already have
    /// produced an empty proxy. Supplied no_proxy/NO_PROXY is retained verbatim.
    bypass: [:0]u8,
    source: Source,

    pub fn deinit(self: *Resolved, a: A) void {
        std.crypto.secureZero(u8, self.proxy);
        std.crypto.secureZero(u8, self.bypass);
        a.free(self.proxy);
        a.free(self.bypass);
        self.* = undefined;
    }
};

/// Empty environment values are absent, as in curl. Lowercase takes precedence;
/// HTTP_PROXY is deliberately ignored, including on Windows. Unknown platforms
/// or Linux desktops fail explicitly instead of silently connecting directly.
/// The supplied environment map must stay immutable throughout the call.
pub fn resolve(a: A, io: std.Io, environ: ?*const std.process.Environ.Map, url: []const u8) !Resolved {
    const uri = try parseUrl(url);
    if (try fromEnvironment(a, environ, uri.scheme)) |result| return result;
    var result = try switch (builtin.os.tag) {
        .windows => @import("proxy_system_windows.zig").resolve(a, url),
        .macos => @import("proxy_system_macos.zig").resolve(a, url),
        .linux => @import("proxy_system_linux.zig").resolve(a, io, environ, url),
        else => error.UnsupportedSystemProxy,
    };
    errdefer result.deinit(a);
    // Environment exclusions also apply when the endpoint comes from the OS.
    if (envNonempty(environ, "no_proxy") orelse envNonempty(environ, "NO_PROXY")) |bypass| {
        try validateText(bypass);
        const combined = if (result.bypass.len == 0)
            try a.dupeSentinel(u8, bypass, 0)
        else
            try a.printSentinel("{s},{s}", .{ result.bypass, bypass }, 0);
        a.free(result.bypass);
        result.bypass = combined;
    }
    return result;
}

fn fromEnvironment(a: A, environ: ?*const std.process.Environ.Map, scheme: []const u8) !?Resolved {
    const specific = if (std.ascii.eqlIgnoreCase(scheme, "http"))
        envNonempty(environ, "http_proxy")
    else if (std.ascii.eqlIgnoreCase(scheme, "https"))
        envNonempty(environ, "https_proxy") orelse envNonempty(environ, "HTTPS_PROXY")
    else
        null;
    const proxy = specific orelse envNonempty(environ, "all_proxy") orelse envNonempty(environ, "ALL_PROXY") orelse return null;
    const bypass = envNonempty(environ, "no_proxy") orelse envNonempty(environ, "NO_PROXY") orelse "";
    return try owned(a, proxy, bypass, .environment);
}

/// Exact lookup avoids Windows Map's case-insensitive get accepting HTTP_PROXY.
pub fn env(environ: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const map = environ orelse return null;
    for (map.keys(), map.values()) |k, v| if (std.mem.eql(u8, k, key)) return v;
    return null;
}
fn envNonempty(environ: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env(environ, key) orelse return null;
    return if (value.len == 0) null else value;
}

pub fn validateText(value: []const u8) !void {
    if (value.len > 16 * 1024) return error.ProxyConfigurationTooLarge;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidProxyConfiguration;
}
pub fn owned(a: A, proxy: []const u8, bypass: []const u8, source: Source) !Resolved {
    try validateText(proxy);
    try validateText(bypass);
    const p = try a.dupeSentinel(u8, proxy, 0);
    errdefer {
        std.crypto.secureZero(u8, p);
        a.free(p);
    }
    return .{ .proxy = p, .bypass = try a.dupeSentinel(u8, bypass, 0), .source = source };
}
pub fn parseUrl(url: []const u8) !std.Uri {
    try validateText(url);
    const uri = std.Uri.parse(url) catch return error.InvalidProxyUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsupportedProxyUrlScheme;
    if (uri.host == null or uri.host.?.isEmpty()) return error.InvalidProxyUrl;
    return uri;
}

/// Construct a proxy endpoint from a native host and port, preserving IPv6.
pub fn endpoint(a: A, scheme: []const u8, host: []const u8, port: u16) ![]u8 {
    try validateText(host);
    if (host.len == 0 or port == 0) return error.InvalidProxyConfiguration;
    if (std.mem.findAny(u8, host, " /@?#,;\\") != null) return error.InvalidProxyConfiguration;
    if (host[0] == '[') {
        if (host.len < 3 or host[host.len - 1] != ']') return error.InvalidProxyConfiguration;
        _ = std.Io.net.Ip6Address.parse(host[1 .. host.len - 1], 0) catch return error.InvalidProxyConfiguration;
    } else if (std.mem.findScalar(u8, host, ':') != null) {
        _ = std.Io.net.Ip6Address.parse(host, 0) catch return error.InvalidProxyConfiguration;
        return a.print("{s}://[{s}]:{d}", .{ scheme, host, port });
    } else if (std.mem.findAny(u8, host, "[]") != null) return error.InvalidProxyConfiguration;
    return a.print("{s}://{s}:{d}", .{ scheme, host, port });
}

/// Convert the supported desktop exclusion syntax into curl's syntax. Unlike
/// curl, desktop lists may contain '*.domain' and '<local>'. Other wildcard or
/// URL/port patterns fail explicitly rather than applying incorrect semantics.
pub fn desktopBypass(a: A, text: []const u8, url: []const u8) ![]u8 {
    try validateText(text);
    const uri = try parseUrl(url);
    var host_buf: [2048]u8 = undefined;
    const host = try uri.host.?.toRaw(&host_buf);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var tokens = std.mem.tokenizeAny(u8, text, ",; ");
    while (tokens.next()) |raw| {
        var token = raw;
        if (std.mem.eql(u8, token, "<local>")) {
            if (std.mem.findAny(u8, host, ".:") == null) {
                if (out.items.len != 0) try out.append(a, ',');
                try out.appendSlice(a, host);
            }
            continue;
        }
        if (std.mem.startsWith(u8, token, "*.")) token = token[1..];
        if (!std.mem.eql(u8, token, "*") and std.mem.findAny(u8, token, "*?<>@") != null)
            return error.UnsupportedProxyBypass;
        // Validate literal CIDRs rather than silently ignoring malformed rules.
        const slash = std.mem.findScalar(u8, token, '/');
        const address = if (slash) |n| token[0..n] else token;
        const ipv6 = std.mem.findScalar(u8, address, ':') != null;
        if (ipv6) {
            _ = std.Io.net.Ip6Address.parse(address, 0) catch return error.UnsupportedProxyBypass;
        }
        if (slash) |n| {
            const bits = std.fmt.parseInt(u8, token[n + 1 ..], 10) catch return error.InvalidProxyConfiguration;
            if (ipv6) {
                if (bits > 128) return error.InvalidProxyConfiguration;
            } else {
                _ = std.Io.net.Ip4Address.parse(address, 0) catch return error.UnsupportedProxyBypass;
                if (bits > 32) return error.InvalidProxyConfiguration;
            }
        }
        if (out.items.len != 0) try out.append(a, ',');
        try out.appendSlice(a, token);
    }
    return out.toOwnedSlice(a);
}

test "environment scheme precedence ignores HTTP_PROXY and empty values" {
    const a = std.testing.allocator;
    var map = std.process.Environ.Map.init(a);
    defer map.deinit();
    try map.put("HTTP_PROXY", "http://unsafe:1");
    try std.testing.expect((try fromEnvironment(a, &map, "http")) == null);
    try map.put("ALL_PROXY", "socks5h://fallback:1080");
    try map.put("https_proxy", "http://lower:8080");
    try map.put("HTTPS_PROXY", "http://upper:8081");
    try map.put("no_proxy", ".example.com,localhost");
    var r = (try fromEnvironment(a, &map, "HTTPS")).?;
    defer r.deinit(a);
    try std.testing.expectEqualStrings("http://lower:8080", r.proxy);
    try std.testing.expectEqualStrings(".example.com,localhost", r.bypass);
    try map.put("https_proxy", "");
    var upper = (try fromEnvironment(a, &map, "https")).?;
    defer upper.deinit(a);
    try std.testing.expectEqualStrings("http://upper:8081", upper.proxy);
    var fallback = (try fromEnvironment(a, &map, "http")).?;
    defer fallback.deinit(a);
    try std.testing.expectEqualStrings("socks5h://fallback:1080", fallback.proxy);
}

test "allocated explicit direct and configuration validation" {
    const a = std.testing.allocator;
    var direct = try owned(a, "", "", .none);
    defer direct.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), direct.proxy.len);
    try std.testing.expectEqual(@as(u8, 0), direct.proxy[direct.proxy.len]);
    try std.testing.expectError(error.InvalidProxyConfiguration, owned(a, "a\x00b", "", .environment));
    try std.testing.expectError(error.UnsupportedProxyUrlScheme, parseUrl("file:///tmp/a"));
}

test "desktop bypass normalizes domains and handles local hosts" {
    const a = std.testing.allocator;
    const list = try desktopBypass(a, "localhost;*.example.org;<local>;10.0.0.0/8;::1", "https://printer/a");
    defer a.free(list);
    try std.testing.expectEqualStrings("localhost,.example.org,printer,10.0.0.0/8,::1", list);
    try std.testing.expectError(error.UnsupportedProxyBypass, desktopBypass(a, "foo*bar", "https://example.org"));
    try std.testing.expectError(error.UnsupportedProxyBypass, desktopBypass(a, "host:8080", "https://example.org"));
}

test "native endpoint handles IPv6 and rejects malformed hosts" {
    const a = std.testing.allocator;
    const value = try endpoint(a, "http", "::1", 8080);
    defer a.free(value);
    try std.testing.expectEqualStrings("http://[::1]:8080", value);
    try std.testing.expectError(error.InvalidProxyConfiguration, endpoint(a, "http", "a/b", 80));
}

test {
    _ = @import("proxy_system_windows.zig");
    _ = @import("proxy_system_linux.zig");
}

test "resolve selects supplied environment without native discovery" {
    const a = std.testing.allocator;
    var map = std.process.Environ.Map.init(a);
    defer map.deinit();
    try map.put("https_proxy", "http://proxy.example:8080");
    var result = try resolve(a, std.testing.io, &map, "https://example.org");
    defer result.deinit(a);
    try std.testing.expectEqual(Source.environment, result.source);
    try std.testing.expectEqualStrings("http://proxy.example:8080", result.proxy);
}
