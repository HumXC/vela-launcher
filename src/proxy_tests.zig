const std = @import("std");
const curl = @import("curl");
const http = @import("core/http_transport.zig");
const downloader = @import("core/downloader.zig");
const proxy = @import("core/proxy_policy.zig");
const config = @import("core/proxy_config.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const body = "verified HTTPS proxy fixture";

fn env(name: []const u8) ![]u8 {
    return std.testing.environ.getAlloc(a, name) catch return error.SkipZigTest;
}
fn port(name: []const u8) !u16 {
    const value = try env(name);
    defer a.free(value);
    return std.fmt.parseInt(u16, value, 10);
}
fn url(host: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "https://{s}:{d}{s}", .{ host, try port("VELA_PROXY_ORIGIN_PORT"), path });
}
fn manual(protocol: config.Protocol, password: []const u8) !proxy.Policy {
    var value = try proxy.Policy.init(a, io, .{ .mode = .manual, .protocol = protocol, .port = try port(switch (protocol) {
        .http => "VELA_PROXY_HTTP_PORT",
        .https => "VELA_PROXY_HTTPS_PORT",
        .socks5 => "VELA_PROXY_SOCKS_PORT",
    }), .username = "fixture-user", .bypass = "127.0.0.1" }, null, null);
    errdefer value.deinit();
    try value.setPassword(password);
    return value;
}
fn fetch(policy: *const proxy.Policy, target: []const u8, follow: bool) !void {
    const ca = try env("VELA_PROXY_CA");
    defer a.free(ca);
    var client = try http.Client.init(a, io, .{ .proxy_policy = policy, .ca_bundle = ca });
    defer client.deinit();
    var response = try client.execute(.{ .url = target, .follow_redirects = follow, .timeout_ms = 5000 });
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings(body, response.body);
}
fn download(policy: *const proxy.Policy, target: []const u8, follow: bool) !void {
    const ca = try env("VELA_PROXY_CA");
    defer a.free(ca);
    var budget = try downloader.Budget.init(io, 1);
    defer budget.deinit();
    const service = try downloader.Service.init(a, io, &budget, 1);
    defer service.deinit();
    const task = try service.submit(.{ .url = target, .proxy_policy = policy, .ca_bundle = ca, .https_only = true, .follow_redirects = follow, .timeout_ms = 5000 });
    defer task.release() catch unreachable;
    task.join();
    const snapshot = task.snapshot();
    if (snapshot.failure) |failure| return failure;
    try std.testing.expectEqualStrings(body, snapshot.result.?.bytes);
}

test "proxy fixture authenticated HTTP and SOCKS5 tunnel HTTPS for metadata and downloads" {
    try curl.globalInit();
    defer curl.globalDeinit();
    const target = try url("proxy-fixture.test", "/ok");
    defer a.free(target);
    for ([_]config.Protocol{ .http, .https, .socks5 }) |protocol| {
        var policy = try manual(protocol, "fixture-password");
        defer policy.deinit();
        try fetch(&policy, target, false);
        try download(&policy, target, false);
    }
}

test "proxy fixture redirects re-evaluate bypass and direct ignores ambient environment" {
    try curl.globalInit();
    defer curl.globalDeinit();
    const redirect = try url("proxy-fixture.test", "/redirect");
    defer a.free(redirect);
    var policy = try manual(.http, "fixture-password");
    defer policy.deinit();
    try fetch(&policy, redirect, true);
    try download(&policy, redirect, true);
    const target = try url("127.0.0.1", "/ok");
    defer a.free(target);
    var direct = try proxy.Policy.init(a, io, .{}, null, null);
    defer direct.deinit();
    try fetch(&direct, target, false);
    try download(&direct, target, false);
}

test "proxy fixture system environment authentication and NO_PROXY are applied per URL" {
    try curl.globalInit();
    defer curl.globalDeinit();
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    const address = try std.fmt.allocPrint(a, "http://fixture-user:fixture-password@127.0.0.1:{d}", .{try port("VELA_PROXY_HTTP_PORT")});
    defer a.free(address);
    try environment.put("https_proxy", address);
    try environment.put("NO_PROXY", "127.0.0.1");
    var policy = try proxy.Policy.init(a, io, .{ .mode = .system }, &environment, null);
    defer policy.deinit();
    const target = try url("proxy-fixture.test", "/redirect");
    defer a.free(target);
    try fetch(&policy, target, true);
    try download(&policy, target, true);
}

test "proxy fixture rejects incorrect authentication and TLS hostname mismatch" {
    try curl.globalInit();
    defer curl.globalDeinit();
    const target = try url("proxy-fixture.test", "/ok");
    defer a.free(target);
    var wrong_password = try manual(.http, "incorrect");
    defer wrong_password.deinit();
    try std.testing.expectError(error.TransportFailed, fetch(&wrong_password, target, false));
    var policy = try manual(.http, "fixture-password");
    defer policy.deinit();
    const wrong_host = try url("wrong.test", "/ok");
    defer a.free(wrong_host);
    try std.testing.expectError(error.TlsFailure, fetch(&policy, wrong_host, false));
}
