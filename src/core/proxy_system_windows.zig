//! Current-user Internet Options, never the machine-wide WinHTTP defaults.
//! Requires winhttp + kernel32. Native calls belong on an ordinary worker thread.
//! Bypass matching is pure: wildcard host rules, optional scheme/port, <local>.
const std = @import("std");
const common = @import("proxy_system.zig");
const A = std.mem.Allocator;
const Handle = *anyopaque;
const ProxyInfo = extern struct { access_type: u32 = 1, proxy: ?[*:0]u16 = null, bypass: ?[*:0]u16 = null };
const UserConfig = extern struct { auto_detect: i32 = 0, auto_url: ?[*:0]u16 = null, proxy: ?[*:0]u16 = null, bypass: ?[*:0]u16 = null };
const AutoOptions = extern struct {
    flags: u32,
    detect_flags: u32,
    config_url: ?[*:0]const u16,
    reserved: ?*anyopaque = null,
    reserved_flags: u32 = 0,
    auto_logon: i32 = 0,
};
extern "winhttp" fn WinHttpGetIEProxyConfigForCurrentUser(*UserConfig) callconv(.winapi) i32;
extern "winhttp" fn WinHttpOpen(?[*:0]const u16, u32, ?[*:0]const u16, ?[*:0]const u16, u32) callconv(.winapi) ?Handle;
extern "winhttp" fn WinHttpCloseHandle(Handle) callconv(.winapi) i32;
extern "winhttp" fn WinHttpSetTimeouts(Handle, i32, i32, i32, i32) callconv(.winapi) i32;
extern "winhttp" fn WinHttpGetProxyForUrl(Handle, [*:0]const u16, *AutoOptions, *ProxyInfo) callconv(.winapi) i32;
extern "kernel32" fn GlobalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

fn freeWide(value: ?[*:0]u16) void {
    if (value) |p| {
        std.crypto.secureZero(u16, std.mem.span(p));
        _ = GlobalFree(@ptrCast(p));
    }
}
fn utf8(a: A, value: ?[*:0]u16) ![]u8 {
    const p = value orelse return a.dupe(u8, "");
    const slice = std.mem.span(p);
    if (slice.len > 16 * 1024) return error.ProxyConfigurationTooLarge;
    return std.unicode.utf16LeToUtf8Alloc(a, slice);
}
fn nativeFailure() anyerror {
    return if (GetLastError() == 12002) error.ProxyDetectionTimeout else error.ProxyDetectionFailed;
}

pub fn resolve(a: A, url: []const u8) !common.Resolved {
    _ = try common.parseUrl(url);
    var config: UserConfig = .{};
    if (WinHttpGetIEProxyConfigForCurrentUser(&config) == 0) {
        // A missing current-user settings key is absence, not a detection error.
        if (GetLastError() == 2) return common.owned(a, "", "", .none);
        return error.ProxyDetectionFailed;
    }
    defer freeWide(config.auto_url);
    defer freeWide(config.proxy);
    defer freeWide(config.bypass);
    if (config.auto_detect != 0 or config.auto_url != null) {
        const session = WinHttpOpen(null, 1, null, null, 0) orelse return nativeFailure();
        defer _ = WinHttpCloseHandle(session);
        if (WinHttpSetTimeouts(session, 5000, 5000, 5000, 5000) == 0) return nativeFailure();
        const wide_url = try std.unicode.utf8ToUtf16LeAllocZ(a, url);
        defer a.free(wide_url);
        var options: AutoOptions = .{
            .flags = (if (config.auto_detect != 0) @as(u32, 1) else 0) | (if (config.auto_url != null) @as(u32, 2) else 0),
            .detect_flags = if (config.auto_detect != 0) 3 else 0,
            .config_url = config.auto_url,
        };
        var result: ProxyInfo = .{};
        if (WinHttpGetProxyForUrl(session, wide_url.ptr, &options, &result) == 0) return nativeFailure();
        defer freeWide(result.proxy);
        defer freeWide(result.bypass);
        // Auto-logon is disabled: do not disclose ambient Windows credentials to
        // a discovered PAC server. PAC failures never fall back to static/direct.
        return fromInfo(a, url, &result);
    }
    var result: ProxyInfo = .{ .access_type = if (config.proxy == null) 1 else 3, .proxy = config.proxy, .bypass = config.bypass };
    return fromInfo(a, url, &result);
}
fn fromInfo(a: A, url: []const u8, info: *const ProxyInfo) !common.Resolved {
    if (info.access_type == 1) return common.owned(a, "", "", .windows);
    if (info.access_type != 3 or info.proxy == null) return error.ProxyDetectionFailed;
    const uri = try common.parseUrl(url);
    if (info.bypass != null) {
        const bypass = try utf8(a, info.bypass);
        defer a.free(bypass);
        if (try bypasses(bypass, url)) return common.owned(a, "", "", .windows);
    }
    const raw = try utf8(a, info.proxy);
    defer {
        std.crypto.secureZero(u8, raw);
        a.free(raw);
    }
    const proxy = try selectProxy(a, raw, uri.scheme);
    defer {
        std.crypto.secureZero(u8, proxy);
        a.free(proxy);
    }
    return common.owned(a, proxy, "", .windows);
}

/// Select the first applicable proxy. A single result cannot express WinHTTP's
/// ordered failover list; callers must not retry DIRECT if this endpoint fails.
fn selectProxy(a: A, text: []const u8, scheme: []const u8) ![]u8 {
    try common.validateText(text);
    if (text.len == 0) return error.InvalidProxyConfiguration;
    var fallback: ?[]const u8 = null;
    var matching: ?[]const u8 = null;
    var socks: ?[]const u8 = null;
    var has_mapping = false;
    var entries = std.mem.tokenizeAny(u8, text, "; ");
    while (entries.next()) |entry| {
        if (std.mem.findScalar(u8, entry, '=')) |equal| {
            has_mapping = true;
            const protocol = entry[0..equal];
            const value = entry[equal + 1 ..];
            if (protocol.len == 0 or value.len == 0) return error.InvalidProxyConfiguration;
            if (std.ascii.eqlIgnoreCase(protocol, scheme)) {
                if (matching == null) matching = value;
            } else if (std.ascii.eqlIgnoreCase(protocol, "socks")) {
                if (socks == null) socks = value;
            } else if (!std.ascii.eqlIgnoreCase(protocol, "http") and !std.ascii.eqlIgnoreCase(protocol, "https") and !std.ascii.eqlIgnoreCase(protocol, "ftp")) return error.UnsupportedSystemProxy;
        } else if (fallback == null) {
            fallback = entry;
        }
    }
    const selected = matching orelse fallback orelse socks orelse {
        if (has_mapping) return a.dupe(u8, "");
        return error.InvalidProxyConfiguration;
    };
    if (std.mem.find(u8, selected, "://") != null) return a.dupe(u8, selected);
    const is_socks = matching == null and fallback == null and socks != null;
    return a.print("{s}://{s}", .{ if (is_socks) "socks4" else "http", selected });
}

test "Windows current-user static per-scheme selection" {
    const a = std.testing.allocator;
    const https = try selectProxy(a, "http=plain:80;https=secure:8080;socks=socks:1080", "https");
    defer a.free(https);
    try std.testing.expectEqualStrings("http://secure:8080", https);
    const direct = try selectProxy(a, "http=plain:80", "https");
    defer a.free(direct);
    try std.testing.expectEqualStrings("", direct);
    const socks = try selectProxy(a, "http=plain:80;socks=socks:1080", "https");
    defer a.free(socks);
    try std.testing.expectEqualStrings("socks4://socks:1080", socks);
    const first = try selectProxy(a, "first:80;second:81", "http");
    defer a.free(first);
    try std.testing.expectEqualStrings("http://first:80", first);
    try std.testing.expectError(error.InvalidProxyConfiguration, selectProxy(a, "https=", "https"));
    try std.testing.expectError(error.InvalidProxyConfiguration, selectProxy(a, "", "https"));
}

fn bypasses(text: []const u8, url: []const u8) !bool {
    try common.validateText(text);
    const uri = try common.parseUrl(url);
    var host_buf: [2048]u8 = undefined;
    const host = try uri.host.?.toRaw(&host_buf);
    const port = uri.port orelse (if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) @as(u16, 443) else 80);
    var matched = false;
    var entries = std.mem.tokenizeAny(u8, text, "; ");
    while (entries.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry, "<local>")) {
            if (std.mem.findAny(u8, host, ".:") == null) matched = true;
            continue;
        }
        var pattern = entry;
        var scheme_matches = true;
        if (std.mem.find(u8, pattern, "://")) |n| {
            scheme_matches = std.ascii.eqlIgnoreCase(pattern[0..n], uri.scheme);
            pattern = pattern[n + 3 ..];
        }
        if (std.mem.findAny(u8, pattern, "/<>@,?") != null) return error.UnsupportedProxyBypass;
        var port_matches = true;
        // Bracketed IPv6 may have a port; unbracketed IPv6 has no port suffix.
        const colon = if (pattern.len != 0 and pattern[0] == '[') blk: {
            const close = std.mem.findScalar(u8, pattern, ']') orelse return error.InvalidProxyConfiguration;
            break :blk if (close + 1 < pattern.len and pattern[close + 1] == ':') close + 1 else null;
        } else if (std.mem.countScalar(u8, pattern, ':') == 1) std.mem.findScalar(u8, pattern, ':') else null;
        if (colon) |n| {
            const pattern_port = std.fmt.parseInt(u16, pattern[n + 1 ..], 10) catch return error.InvalidProxyConfiguration;
            port_matches = pattern_port == port;
            pattern = pattern[0..n];
        }
        if (pattern.len == 0) return error.InvalidProxyConfiguration;
        if (scheme_matches and port_matches and wildcard(pattern, host)) matched = true;
    }
    return matched;
}
/// Nonrecursive wildcard matching, bounded by configuration and URL limits.
fn wildcard(pattern: []const u8, host: []const u8) bool {
    var p: usize = 0;
    var h: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (h < host.len) {
        if (p < pattern.len and pattern[p] != '*' and std.ascii.toLower(pattern[p]) == std.ascii.toLower(host[h])) {
            p += 1;
            h += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = h;
        } else if (star) |s| {
            retry += 1;
            h = retry;
            p = s + 1;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
    return p == pattern.len;
}
test "Windows bypass respects wildcard local scheme and port rules" {
    try std.testing.expect(try bypasses("<local>;*.example.org", "https://printer/"));
    try std.testing.expect(try bypasses("<local>;*.example.org", "https://www.EXAMPLE.org/"));
    try std.testing.expect(!try bypasses("<local>;*.example.org", "https://example.org/"));
    try std.testing.expect(try bypasses("https://example.org:443", "https://example.org/"));
    try std.testing.expect(!try bypasses("https://example.org:8443", "https://example.org/"));
    try std.testing.expect(!try bypasses("http://example.org", "https://example.org/"));
    try std.testing.expectError(error.UnsupportedProxyBypass, bypasses("<-loopback>", "https://example.org/"));
}
