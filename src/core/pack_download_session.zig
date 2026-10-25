//! Worker-only credential lookup; keys never enter retained UI/options snapshots.
const std = @import("std");
const credentials = @import("credentials.zig");
const authorization = @import("pack_source_authorization.zig");
const transport = @import("content_transport.zig");
const fs = @import("content_fs.zig");
/// The Adapter owns and wipes its copy. Native-store handles and the temporary
/// Secret are always destroyed before this function returns.
pub fn open(a: std.mem.Allocator, io: std.Io, cancel: ?*const transport.CancelToken, connections: u16, options: authorization.Options, curseforge: bool) !transport.Adapter {
    var download = options.transport_options;
    download.curseforge_download_key = null;
    if (!curseforge) return transport.Adapter.initWithOptions(a, io, cancel, connections, download);
    if (!options.policy.enabled or !options.policy.terms_approved or !download.allow_curseforge) return error.ProviderDisabled;
    const reference = options.policy.credential_ref orelse return error.ProviderDisabled;
    if (!credentials.validateReference(&reference)) return error.InvalidReference;
    try fs.cancelled(io, cancel, null);
    var native: ?credentials.Native = null;
    defer if (native) |*value| value.deinit();
    const store = options.fixture_credential_store orelse blk: {
        native = try credentials.Native.init();
        break :blk native.?.store();
    };
    var secret = try store.get(a, &reference);
    defer secret.deinit();
    try fs.cancelled(io, cancel, null);
    download.curseforge_download_key = secret.bytes;
    return transport.Adapter.initWithOptions(a, io, cancel, connections, download);
}
