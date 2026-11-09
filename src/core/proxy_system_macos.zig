//! Requires CoreFoundation and CFNetwork frameworks. CFNetwork evaluates
//! native exclusions for each URL; PAC entries fail explicitly (no JS runtime).
//! Keychain credentials and proxy failover are not provided by this interface.
const std = @import("std");
const common = @import("proxy_system.zig");
const A = std.mem.Allocator;
const Ref = *const anyopaque;
const utf8_encoding: u32 = 0x08000100;

extern fn CFNetworkCopySystemProxySettings() ?Ref;
extern fn CFNetworkCopyProxiesForURL(Ref, Ref) ?Ref;
extern fn CFURLCreateWithBytes(?Ref, [*]const u8, isize, u32, ?Ref) ?Ref;
extern fn CFRelease(Ref) void;
extern fn CFEqual(Ref, Ref) u8;
extern fn CFGetTypeID(Ref) usize;
extern fn CFArrayGetTypeID() usize;
extern fn CFDictionaryGetTypeID() usize;
extern fn CFStringGetTypeID() usize;
extern fn CFNumberGetTypeID() usize;
extern fn CFArrayGetCount(Ref) isize;
extern fn CFArrayGetValueAtIndex(Ref, isize) ?Ref;
extern fn CFDictionaryGetValue(Ref, Ref) ?Ref;
extern fn CFStringGetLength(Ref) isize;
extern fn CFStringGetMaximumSizeForEncoding(isize, u32) isize;
extern fn CFStringGetCString(Ref, [*]u8, isize, u32) u8;
extern fn CFNumberGetValue(Ref, c_int, *anyopaque) u8;
extern const kCFProxyTypeKey: Ref;
extern const kCFProxyHostNameKey: Ref;
extern const kCFProxyPortNumberKey: Ref;
extern const kCFProxyUsernameKey: Ref;
extern const kCFProxyPasswordKey: Ref;
extern const kCFProxyTypeNone: Ref;
extern const kCFProxyTypeHTTP: Ref;
extern const kCFProxyTypeHTTPS: Ref;
extern const kCFProxyTypeSOCKS: Ref;
extern const kCFProxyTypeAutoConfigurationURL: Ref;
extern const kCFProxyTypeAutoConfigurationJavaScript: Ref;

pub fn resolve(a: A, url: []const u8) !common.Resolved {
    _ = try common.parseUrl(url);
    const settings = CFNetworkCopySystemProxySettings() orelse return error.ProxyDetectionFailed;
    defer CFRelease(settings);
    if (CFGetTypeID(settings) != CFDictionaryGetTypeID()) return error.ProxyDetectionFailed;
    const native_url = CFURLCreateWithBytes(null, url.ptr, @intCast(url.len), utf8_encoding, null) orelse return error.InvalidProxyUrl;
    defer CFRelease(native_url);
    const proxies = CFNetworkCopyProxiesForURL(native_url, settings) orelse return error.ProxyDetectionFailed;
    defer CFRelease(proxies);
    if (CFGetTypeID(proxies) != CFArrayGetTypeID() or CFArrayGetCount(proxies) < 1) return error.ProxyDetectionFailed;
    // CFNetwork orders entries by preference. A single-result API selects the
    // first and must never retry an implicit DIRECT after a connection failure.
    const proxy = CFArrayGetValueAtIndex(proxies, 0) orelse return error.ProxyDetectionFailed;
    if (CFGetTypeID(proxy) != CFDictionaryGetTypeID()) return error.ProxyDetectionFailed;
    const kind = CFDictionaryGetValue(proxy, kCFProxyTypeKey) orelse return error.ProxyDetectionFailed;
    if (CFEqual(kind, kCFProxyTypeNone) != 0) return common.owned(a, "", "", .macos);
    if (CFEqual(kind, kCFProxyTypeAutoConfigurationURL) != 0 or CFEqual(kind, kCFProxyTypeAutoConfigurationJavaScript) != 0)
        return error.UnsupportedProxyAutoConfig;
    const is_http = CFEqual(kind, kCFProxyTypeHTTP) != 0 or CFEqual(kind, kCFProxyTypeHTTPS) != 0;
    const is_socks = CFEqual(kind, kCFProxyTypeSOCKS) != 0;
    if (!is_http and !is_socks) return error.UnsupportedSystemProxy;
    if (CFDictionaryGetValue(proxy, kCFProxyUsernameKey) != null or CFDictionaryGetValue(proxy, kCFProxyPasswordKey) != null)
        return error.UnsupportedProxyAuthentication;
    const host_ref = CFDictionaryGetValue(proxy, kCFProxyHostNameKey) orelse return error.ProxyDetectionFailed;
    const port_ref = CFDictionaryGetValue(proxy, kCFProxyPortNumberKey) orelse return error.ProxyDetectionFailed;
    if (CFGetTypeID(port_ref) != CFNumberGetTypeID()) return error.ProxyDetectionFailed;
    var port: i32 = 0;
    // kCFNumberSInt32Type = 3.
    if (CFNumberGetValue(port_ref, 3, &port) == 0 or port < 1 or port > 65535) return error.InvalidProxyConfiguration;
    const host = try string(a, host_ref);
    defer a.free(host);
    // macOS's "Secure Web Proxy (HTTPS)" is an HTTP CONNECT proxy for HTTPS
    // destinations, not a declaration of TLS transport to the proxy itself.
    const endpoint = try common.endpoint(a, if (is_socks) "socks5h" else "http", host, @intCast(port));
    defer a.free(endpoint);
    return common.owned(a, endpoint, "", .macos);
}
fn string(a: A, ref: Ref) ![]u8 {
    if (CFGetTypeID(ref) != CFStringGetTypeID()) return error.ProxyDetectionFailed;
    const length = CFStringGetLength(ref);
    if (length < 0 or length > 16 * 1024) return error.ProxyConfigurationTooLarge;
    const capacity = CFStringGetMaximumSizeForEncoding(length, utf8_encoding);
    if (capacity < 0 or capacity > 64 * 1024) return error.ProxyConfigurationTooLarge;
    const buffer = try a.alloc(u8, @intCast(capacity + 1));
    defer a.free(buffer);
    if (CFStringGetCString(ref, buffer.ptr, @intCast(buffer.len), utf8_encoding) == 0) return error.ProxyDetectionFailed;
    const end = std.mem.findScalar(u8, buffer, 0) orelse return error.ProxyDetectionFailed;
    return a.dupe(u8, buffer[0..end]);
}
