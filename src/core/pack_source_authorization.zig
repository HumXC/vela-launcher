//! Worker-only authorization. Options and fixture stores are borrowed for the call.
//! Credential bytes remain scoped here and are wiped on every exit.
const std = @import("std");
const providers = @import("content_providers.zig");
const transport = @import("content_transport.zig");
const credentials = @import("credentials.zig");
const manifest = @import("content_manifest.zig");
const pack_import = @import("pack_import.zig");
const config = @import("config.zig");
const fs = @import("content_fs.zig");
const A = std.mem.Allocator;
pub const Policy = struct {
    enabled: bool = false,
    terms_approved: bool = false,
    credential_ref: ?credentials.Reference = null,
};
pub const Options = struct {
    transport_options: transport.Adapter.Options = .{},
    policy: Policy = .{},
    fixture_credential_store: ?credentials.Store = null,
};
const Cancel = transport.CancelToken;
fn copy(comptime T: type, a: A, value: T) anyerror!T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var out: T = undefined;
            inline for (info.field_names, info.field_types) |name, F| @field(out, name) = try copy(F, a, @field(value, name));
            return out;
        },
        .@"union" => |info| {
            inline for (info.field_names, info.field_types) |name, F| if (std.meta.activeTag(value) == @field(info.tag_type.?, name)) return @unionInit(T, name, try copy(F, a, @field(value, name)));
            unreachable;
        },
        .optional => |info| return if (value) |v| try copy(info.child, a, v) else null,
        .pointer => |info| {
            if (info.size != .slice) return value;
            const out = try a.alloc(info.child, value.len);
            for (value, out) |v, *dest| dest.* = try copy(info.child, a, v);
            return out;
        },
        else => return value,
    }
}
const Metadata = struct {
    allocator: A = undefined,
    native: ?credentials.Native = null,
    secret: ?credentials.Secret = null,
    adapter: ?transport.Adapter = null,
    fn open(self: *Metadata, a: A, io: std.Io, options: Options, cancel: ?*const Cancel) !void {
        self.allocator = a;
        errdefer self.deinit();
        try fs.cancelled(io, cancel, null);
        const ref = options.policy.credential_ref orelse return error.ProviderDisabled;
        if (!options.policy.enabled or !options.policy.terms_approved or !options.transport_options.allow_curseforge) return error.ProviderDisabled;
        if (!credentials.validateReference(&ref)) return error.InvalidReference;
        const store = options.fixture_credential_store orelse blk: {
            self.native = try credentials.Native.init();
            break :blk self.native.?.store();
        };
        try fs.cancelled(io, cancel, null);
        self.secret = try store.get(a, &ref);
        try fs.cancelled(io, cancel, null);
        self.adapter = try transport.Adapter.initWithOptions(a, io, cancel, 1, options.transport_options);
    }
    fn deinit(self: *Metadata) void {
        if (self.secret) |*secret| secret.deinit();
        if (self.adapter) |*adapter| adapter.deinit();
        if (self.native) |*native| native.deinit();
        self.secret = null;
        self.adapter = null;
        self.native = null;
    }
    fn client(self: *Metadata) providers.CurseForgeClient {
        return .{ .allocator = self.allocator, .transport = self.adapter.?.providerTransport(), .user_agent = transport.user_agent, .options = .{ .enabled = true, .terms_approved = true, .api_key = self.secret.?.bytes } };
    }
    fn remotePolicy(self: *Metadata) providers.RemotePolicy {
        return .{ .enabled = true, .approved_download_hosts = self.adapter.?.approved_download_hosts };
    }
};
fn validateMrFile(file: providers.File, options: Options) !void {
    if (!config.validId(file.filename)) return error.UnsafeFilename;
    try providers.validateHashes(file.hashes);
    const size = file.size orelse return error.MissingFileSize;
    if (size > providers.max_file_bytes) return error.InvalidFileSize;
    if (file.download != .remote) return error.InvalidRemoteAuthorization;
    if (!providers.approvedDownloadUrl(file.download.remote, options.transport_options.approved_download_hosts)) return error.UnapprovedDownloadHost;
}
/// CF ignores all incoming metadata except project/file identity. MR retains its
/// official catalog metadata after URL, filename, integrity and bounds checks.
pub fn authorizeArchive(a: A, io: std.Io, version: providers.Version, options: Options, cancel: ?*const Cancel) !providers.Owned(providers.Version) {
    try fs.cancelled(io, cancel, null);
    if (!providers.validToken(version.project_id) or !providers.validToken(version.id)) return error.InvalidContentId;
    if (version.provider == .curseforge) {
        var scope: Metadata = .{};
        try scope.open(a, io, options, cancel);
        defer scope.deinit();
        var result = try scope.client().authorizedVersion(version.project_id, version.id, null, scope.remotePolicy());
        errdefer result.deinit();
        try fs.cancelled(io, cancel, null);
        if (result.value.versions.len != 1) return error.UnknownVersion;
        return .{ .arena = result.arena, .value = result.value.versions[0] };
    }
    if (version.files.len == 0 or version.files.len > providers.max_items) return error.AmbiguousFiles;
    for (version.files) |file| {
        try validateMrFile(file, options);
        if (file.size.? == 0) return error.InvalidFileSize;
    }
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const value = try copy(providers.Version, arena.allocator(), version);
    try fs.cancelled(io, cancel, null);
    return .{ .arena = arena, .value = value };
}
/// Atomically publish resolved data into the inspection arena. Existing official
/// files are reauthorized too; stale proofs and external download URLs never win.
pub fn resolveInspection(a: A, io: std.Io, inspection: *pack_import.Inspection, options: Options, cancel: ?*const Cancel) !void {
    try fs.cancelled(io, cancel, null);
    if (inspection.provider != inspection.pack.identity.provider) return error.ProviderMismatch;
    if (inspection.provider == .modrinth) {
        for (inspection.pack.files) |file| {
            try manifest.checkedPathForInstance(file.record.path, null);
            if (file.record.identity_provenance == .pack_override and file.record.role == .override and file.download == .manual_required) continue;
            try validateMrFile(.{ .filename = std.fs.path.basename(file.record.path), .hashes = file.record.hashes, .size = file.record.size, .download = file.download }, options);
            for (file.alternatives) |url| if (!providers.approvedDownloadUrl(url, options.transport_options.approved_download_hosts)) return error.UnapprovedDownloadHost;
        }
        return;
    }
    if (inspection.pack.unresolved.len > providers.max_items or inspection.pack.files.len > providers.max_items) return error.TooManyItems;
    var scope: Metadata = .{};
    try scope.open(a, io, options, cancel);
    defer scope.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const refreshed = try copy(manifest.PackPlan, sa, inspection.pack);
    var refs: std.ArrayList(manifest.PackReference) = .empty;
    try refs.appendSlice(sa, refreshed.unresolved);
    for (refreshed.files) |file| if (file.record.provider == .curseforge and file.record.identity_provenance == .official_file) {
        try refs.append(sa, .{ .project_id = file.record.project_id, .file_id = file.record.version_id, .required = file.required, .selected = file.selected });
    };
    var candidates: std.ArrayList(providers.Version) = .empty;
    var queried: std.StringHashMapUnmanaged(void) = .{};
    for (refs.items) |ref| {
        try fs.cancelled(io, cancel, null);
        const key = try std.fmt.allocPrint(sa, "{s}:{s}", .{ ref.project_id, ref.file_id });
        if (queried.contains(key)) continue;
        try queried.put(sa, key, {});
        var found = try scope.client().authorizedVersion(ref.project_id, ref.file_id, .{ .minecraft_version = refreshed.minecraft_version, .loader = refreshed.loader }, scope.remotePolicy());
        defer found.deinit();
        if (found.value.versions.len != 1) return error.UnknownVersion;
        const v = found.value.versions[0];
        if (v.files.len != 1) return error.AmbiguousFiles;
        if (v.files[0].size == null) return error.MissingSize;
        try candidates.append(sa, try copy(providers.Version, sa, v));
    }
    for (@constCast(refreshed.files)) |*file| {
        if (file.record.provider != .curseforge or file.record.identity_provenance != .official_file) continue;
        for (candidates.items) |v| if (std.mem.eql(u8, v.project_id, file.record.project_id) and std.mem.eql(u8, v.id, file.record.version_id)) {
            const fresh = v.files[0];
            if (!std.mem.eql(u8, std.fs.path.basename(file.record.path), fresh.filename)) return error.VersionMismatch;
            file.record.hashes = fresh.hashes;
            file.record.size = fresh.size;
            file.download = fresh.download;
            file.authorization = fresh.authorization;
            file.alternatives = &.{};
            break;
        };
    }
    var resolved = try manifest.resolveCurseForgePackAuthorized(a, refreshed, candidates.items, scope.remotePolicy());
    defer resolved.deinit();
    try fs.cancelled(io, cancel, null);
    const next = try copy(manifest.PackPlan, inspection.arena.allocator(), resolved.value);
    try fs.cancelled(io, cancel, null);
    inspection.pack = next;
}
