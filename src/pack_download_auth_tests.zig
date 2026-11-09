const std = @import("std");
const transport = @import("core/content_transport.zig");
const http = @import("core/http_transport.zig");
const install = @import("core/content_install.zig");
const providers = @import("core/content_providers.zig");
const fs = @import("core/content_fs.zig");
const fixture_key = "offline-fixture-only";
const good_url = "https://edge.forgecdn.net/files/1234/567/pack.zip";

const Fixture = struct {
    calls: usize = 0,
    keyed: bool = false,
    status: u16 = 200,
    url: []const u8 = good_url,
    fn execute(raw: ?*anyopaque, a: std.mem.Allocator, _: std.Io, request: http.Request) !http.Response {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        try std.testing.expect(std.mem.eql(u8, self.url, request.url));
        try std.testing.expect(!request.follow_redirects and request.require_public_address and !request.allow_http_loopback);
        try std.testing.expectEqual(self.keyed, request.sensitive);
        try std.testing.expectEqual(@as(usize, if (self.keyed) 1 else 0), request.headers.len);
        if (self.keyed) {
            try std.testing.expect(std.mem.eql(u8, "x-api-key", request.headers[0].name));
            // Boolean comparison avoids printing credentials on failure.
            try std.testing.expect(std.mem.eql(u8, fixture_key, request.headers[0].value));
        }
        const body = try a.dupe(u8, "payload");
        return .{ .allocator = a, .status = self.status, .body = body, .allocation = body };
    }
};

fn requestFor(dir: std.Io.Dir, absolute: []const u8, url: []const u8) install.FetchRequest {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("payload", &digest, .{});
    return .{ .url = url, .directory = dir, .name = "download.bin", .absolute_path = absolute, .max_bytes = 64, .expected_size = 7, .expected_sha1 = digest, .deadline_ns = null, .cancel = null };
}

test "pack download auth scopes key to approved exact CDN and owns its copy" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const absolute = try std.fs.path.join(a, &.{ root, "download.bin" });
    defer a.free(absolute);
    var fixture: Fixture = .{};
    var caller_key = fixture_key.*;
    var adapter = try transport.Adapter.init(a, io, null, 1, .{ .allow_curseforge = true, .curseforge_download_key = &caller_key, .approved_download_hosts = &.{ "edge.forgecdn.net", "cdn.modrinth.com", "edge.forgecdn.net.evil.example", "other.example" }, .fixture_http = Fixture.execute, .fixture_context = &fixture });
    defer adapter.deinit();
    @memset(&caller_key, 'X');
    const fetch = adapter.fetcher();
    for ([_]struct { url: []const u8, enabled: bool, keyed: bool }{
        .{ .url = good_url, .enabled = true, .keyed = true },
        .{ .url = good_url, .enabled = false, .keyed = false },
        .{ .url = "https://cdn.modrinth.com/files/1234/567/pack.zip", .enabled = true, .keyed = false },
        .{ .url = "https://edge.forgecdn.net.evil.example/files/1234/567/pack.zip", .enabled = true, .keyed = false },
        .{ .url = "https://other.example/files/1234/567/pack.zip", .enabled = true, .keyed = false },
        .{ .url = "https://edge.forgecdn.net/files/1234/567/pack.zip?x-api-key=not-a-secret", .enabled = true, .keyed = false },
        .{ .url = "https://edge.forgecdn.net/files/1234/567/%2e%2e", .enabled = true, .keyed = false },
        .{ .url = "https://edge.forgecdn.net/other/pack.zip", .enabled = true, .keyed = false },
    }) |case| {
        adapter.allow_curseforge = case.enabled;
        fixture.url = case.url;
        fixture.keyed = case.keyed;
        try fetch.fetchToFile(fetch.context, io, requestFor(tmp.dir, absolute, case.url));
        const contents = try tmp.dir.readFileAlloc(io, "download.bin", a, .limited(64));
        defer a.free(contents);
        try std.testing.expectEqualStrings("payload", contents);
        try tmp.dir.deleteFile(io, "download.bin");
    }
    // A server redirect is terminal: only the original approved host sees a key.
    fixture = .{ .keyed = true, .status = 302 };
    adapter.allow_curseforge = true;
    try std.testing.expectError(error.HttpStatus, fetch.fetchToFile(fetch.context, io, requestFor(tmp.dir, absolute, good_url)));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(try fs.inspectEntry(tmp.dir, io, "download.bin") == null);
    for ([_][]const u8{
        "http://edge.forgecdn.net/files/1/2/a",
        "https://user@edge.forgecdn.net/files/1/2/a",
        "https://edge.forgecdn.net:443/files/1/2/a",
        "https://edge.forgecdn.net/files/1/2/a#fragment",
    }) |url| {
        try std.testing.expectError(error.UnapprovedDownloadHost, fetch.fetchToFile(fetch.context, io, requestFor(tmp.dir, absolute, url)));
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    // Exact host still needs explicit approval.
    var unapproved = try transport.Adapter.init(a, io, null, 1, .{ .allow_curseforge = true, .curseforge_download_key = fixture_key, .fixture_http = Fixture.execute, .fixture_context = &fixture });
    defer unapproved.deinit();
    const denied = unapproved.fetcher();
    try std.testing.expectError(error.UnapprovedDownloadHost, denied.fetchToFile(denied.context, io, requestFor(tmp.dir, absolute, good_url)));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "pack download auth rejects ambiguous URLs and keeps metadata scope separate" {
    try std.testing.expect(transport.curseforgeDownloadUrlAllowed(good_url));
    try std.testing.expect(transport.curseforgeDownloadUrlAllowed("https://edge.forgecdn.net/files/1234/567/pack%20name.zip"));
    for ([_][]const u8{
        "http://edge.forgecdn.net/files/1/2/a",               "https://EDGE.forgecdn.net/files/1/2/a",
        "https://edge.forgecdn.net.evil.example/files/1/2/a", "https://edge.forgecdn.net./files/1/2/a",
        "https://user@edge.forgecdn.net/files/1/2/a",         "https://edge.forgecdn.net:443/files/1/2/a",
        "https://edge.forgecdn.net/files/1/2/a#x",            "https://edge.forgecdn.net/files/1/2/a?key=x",
        "https://edge.forgecdn.net/files/1/2/..",             "https://edge.forgecdn.net/files/1/2/%2e%2e",
        "https://edge.forgecdn.net/files/1/2/a%2fb",          "https://edge.forgecdn.net/files/1/2/a%5cb",
        "https://edge.forgecdn.net/files/1/2/a%00b",          "https://edge.forgecdn.net/files/1/2/%252e%252e",
        "https://edge.forgecdn.net/files/1/2/%GG",            "https://edge.forgecdn.net/files/1/2/%",
        "https://edge.forgecdn.net/files/1/2/",               "https://edge.forgecdn.net/files/1/2/a/b",
        "https://edge.forgecdn.net/files/x/2/a",              "https://cdn.modrinth.com/files/1/2/a",
    }) |url| try std.testing.expect(!transport.curseforgeDownloadUrlAllowed(url));
    try std.testing.expect(!providers.credentialScopeAllowed(.{ .url = good_url, .user_agent = "fixture", .credential_header = .{ .name = "x-api-key", .value = fixture_key } }));
}

test "pack download auth rejects malformed key before HTTP" {
    for ([_][]const u8{ "", "a\r\nb", "a b" }) |key| {
        try std.testing.expectError(error.InvalidCredential, transport.Adapter.init(std.testing.allocator, std.testing.io, null, 1, .{ .curseforge_download_key = key }));
    }
    const oversized: [513]u8 = @splat('x');
    try std.testing.expectError(error.InvalidCredential, transport.Adapter.init(std.testing.allocator, std.testing.io, null, 1, .{ .curseforge_download_key = &oversized }));
}
