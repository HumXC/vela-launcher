//! Build-bound adapter smoke test: no network request or JDK download.
const std = @import("std");
const downloader = @import("downloader.zig");
const curl = @import("curl");
const java = @import("java_download.zig");

test "Java Service adapter typechecks real downloader and rejects non HTTP transport" {
    try curl.globalInit();
    defer curl.globalDeinit();
    const service = try downloader.Service.init(std.testing.allocator, std.testing.io, 1);
    defer service.deinit();
    var adapter: java.ServiceTransport(downloader.Service) = .{ .service = service, .io = std.testing.io };
    const transport = adapter.transport();
    try std.testing.expectError(error.InvalidUrl, transport.get(transport.context, std.testing.allocator, "file:///unused", 4096, .{}));
    const release: java.RuntimeRelease = .{
        .allocator = std.testing.allocator,
        .vendor = .microsoft,
        .major = 21,
        .platform = .{ .os = .linux, .arch = .x64 },
        .version = "21.0.1",
        .url = "file:///unused",
        .archive = .tar_gz,
        .sha256 = @splat(0),
    };
    try std.testing.expectError(error.InvalidUrl, transport.download(transport.context, std.testing.io, &release, "unused", .{}));
}
