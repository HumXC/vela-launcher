//! Pack files execute in a private root, then join the verified game stage before
//! its one atomic publication. No ordinary instance is ever published first.
const std = @import("std");
const config = @import("config.zig");
const instances = @import("instances.zig");
const packs = @import("pack_import.zig");
const manifest = @import("content_manifest.zig");
const install = @import("content_install.zig");
const providers = @import("content_providers.zig");
const transport = @import("content_transport.zig");
const authorization = @import("pack_source_authorization.zig");
const download_session = @import("pack_download_session.zig");
const fs = @import("content_fs.zig");
const tasks = @import("tasks.zig");
const diagnostic_log = @import("diagnostic_log.zig");
const A = std.mem.Allocator;
const Io = std.Io;
pub const CancelToken = std.atomic.Value(bool);
pub const OptionalChoice = struct { path: []const u8, include: bool };
pub const Source = union(enum) { local: []const u8, online: providers.Version };
pub const Options = struct {
    transport_options: transport.Adapter.Options = .{},
    download_connections: u16 = 8,
    /// Borrowed sink; its owner must join inspection/creation before destroying it.
    telemetry: ?*tasks.Task = null,
    diagnostics: ?*packs.Diagnostics = null,
    source_policy: authorization.Policy = .{},
    fixture_credential_store: ?@import("credentials.zig").Store = null,
    fn sourceOptions(self: Options) authorization.Options {
        return .{ .transport_options = self.transport_options, .policy = self.source_policy, .fixture_credential_store = self.fixture_credential_store };
    }
};
pub const sidecar = "pack-content.json";

pub fn clone(comptime T: type, a: A, value: T) anyerror!T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, FT| @field(result, name) = try clone(FT, a, @field(value, name));
            return result;
        },
        .@"union" => |info| {
            inline for (info.field_names, info.field_types) |name, FT| if (std.mem.eql(u8, name, @tagName(std.meta.activeTag(value)))) return @unionInit(T, name, try clone(FT, a, @field(value, name)));
            unreachable;
        },
        .optional => |info| {
            if (@typeInfo(info.child) == .error_set) return value;
            return if (value) |v| try clone(info.child, a, v) else null;
        },
        .pointer => |info| {
            if (info.size != .slice) return value;
            const result = try a.alloc(info.child, value.len);
            for (value, result) |v, *out| out.* = try clone(info.child, a, v);
            return result;
        },
        else => return value,
    }
}

pub fn inspect(a: A, io: Io, paths: *const instances.Paths, source: Source, options: Options, cancel: *const CancelToken) !packs.Inspection {
    var diagnostic: packs.Diagnostics = .{};
    var effective = options;
    if (effective.diagnostics == null) effective.diagnostics = &diagnostic;
    effective.diagnostics.?.len = 0;
    defer stopTelemetry(effective.telemetry);
    return inspectImpl(a, io, paths, source, effective, cancel) catch |err| {
        failTelemetry(effective.telemetry, effective.diagnostics, err);
        return err;
    };
}

fn inspectImpl(a: A, io: Io, paths: *const instances.Paths, source: Source, options: Options, cancel: *const CancelToken) !packs.Inspection {
    reportStage(options.telemetry, .metadata);
    if (source == .local) {
        reportStage(options.telemetry, .extracting);
        var local = try packs.inspect(a, io, paths, source.local, cancel, options.diagnostics);
        errdefer {
            local.cleanup(io) catch {};
            local.deinit();
        }
        try authorization.resolveInspection(a, io, &local, options.sourceOptions(), cancel);
        return local;
    }
    var authorized = try authorization.authorizeArchive(a, io, source.online, options.sourceOptions(), cancel);
    defer authorized.deinit();
    const version = authorized.value;
    if (version.provider != .modrinth and version.provider != .curseforge) return error.ProviderDisabled;
    if (version.files.len == 0) return error.MissingArchive;
    var selected: ?providers.File = null;
    for (version.files) |file| if (file.primary) {
        if (selected != null) return error.MultiplePrimaryFiles;
        selected = file;
    };
    const file = selected orelse version.files[0];
    if (file.download != .remote) return error.ManualArchiveRequired;
    try providers.validateHashes(file.hashes);
    if (version.provider == .curseforge) try providers.validateRemoteAuthorization(version.provider, version.project_id, version.id, file, .{ .enabled = options.transport_options.allow_curseforge, .approved_download_hosts = options.transport_options.approved_download_hosts });
    var adapter = try download_session.open(a, io, cancel, options.download_connections, options.sourceOptions(), version.provider == .curseforge);
    defer adapter.deinit();
    adapter.telemetry = options.telemetry;
    const root = try fs.openAbsolute(io, paths.root);
    defer root.close(io);
    const vela = try fs.child(root, io, ".vela", true, false);
    defer vela.close(io);
    const downloads = try fs.child(vela, io, "pack-downloads", true, true);
    defer downloads.close(io);
    var nonce: [16]u8 = undefined;
    try Io.randomSecure(io, &nonce);
    const name = try std.fmt.allocPrint(a, "archive-{s}{s}", .{ std.fmt.bytesToHex(nonce, .lower), if (version.provider == .modrinth) @as([]const u8, ".mrpack") else ".zip" });
    defer a.free(name);
    const absolute = try std.fs.path.join(a, &.{ paths.vela, "pack-downloads", name });
    defer a.free(absolute);
    defer downloads.deleteFile(io, name) catch {};
    const fetcher = adapter.fetcher();
    const limit = packs.archive_limit;
    if (file.size) |size| if (size > limit) return error.ArchiveTooLarge;
    const fetch_started = Io.Clock.awake.now(io).nanoseconds;
    try fetcher.fetchToFile(fetcher.context, io, .{ .url = file.download.remote, .directory = downloads, .name = name, .absolute_path = absolute, .max_bytes = limit, .expected_size = file.size, .expected_sha1 = try @import("artifact_cache.zig").parseHex(20, file.hashes.sha1), .expected_sha256 = try @import("artifact_cache.zig").parseHex(32, file.hashes.sha256), .expected_sha512 = try @import("artifact_cache.zig").parseHex(64, file.hashes.sha512), .deadline_ns = null, .cancel = cancel });
    diagnostic_log.write(.info, .pack, "archive_ready elapsed_ms={d} file={s}", .{ @divTrunc(Io.Clock.awake.now(io).nanoseconds - fetch_started, std.time.ns_per_ms), absolute });
    reportStage(options.telemetry, .verifying);
    // The private staging copy verifies callback output before extraction, avoiding
    // a separate full-archive fingerprint pass (including on cache hits).
    if (try fs.inspectEntry(downloads, io, name) == null) return error.MissingArchive;
    reportStage(options.telemetry, .extracting);
    var result = try packs.inspectVerified(a, io, paths, absolute, file.hashes, file.size, cancel, options.diagnostics);
    errdefer {
        result.cleanup(io) catch {};
        result.deinit();
    }
    if (result.provider != version.provider) return error.ProviderMismatch;
    result.pack.identity = try clone(manifest.PackIdentity, result.arena.allocator(), .{ .provider = version.provider, .project_id = version.project_id, .version_id = version.id });
    try authorization.resolveInspection(a, io, &result, options.sourceOptions(), cancel);
    return result;
}

pub const Request = struct {
    paths: *const instances.Paths,
    inspection: *const packs.Inspection,
    instance: config.Instance,
    manual_files: []const install.ManualFile = &.{},
    optional: []const OptionalChoice = &.{},
    options: Options = .{},
};
// content_install verifies hashes immediately after each fetch callback returns.
// Publish that boundary without changing the shared transport or transaction.
const PackFetcher = struct {
    inner: install.Fetcher,
    telemetry: ?*tasks.Task,

    fn fetch(raw: ?*anyopaque, io: Io, request: install.FetchRequest) anyerror!void {
        const self: *PackFetcher = @ptrCast(@alignCast(raw.?));
        try self.inner.fetchToFile(self.inner.context, io, request);
        reportStage(self.telemetry, .verifying);
    }
};

fn leaseCheck(_: ?*anyopaque, _: []const u8) !void {}
fn leaseRelease(_: ?*anyopaque, _: []const u8) void {}

fn reportStage(sink: ?*tasks.Task, stage: tasks.Stage) void {
    if (sink) |task| task.report(stage, 0, null);
}

fn stopTelemetry(sink: ?*tasks.Task) void {
    if (sink) |task| {
        var details = task.details();
        details.stop();
        task.reportDetails(details);
    }
}

fn failTelemetry(sink: ?*tasks.Task, diagnostic: ?*const packs.Diagnostics, err: anyerror) void {
    if (sink) |task| {
        var details = task.details();
        var has_failure = false;
        for (details.files[0..details.file_count]) |file| {
            if (file.failure != null) has_failure = true;
        }
        // Copy the offending path before failed preparation arenas are released.
        if (!has_failure and err != error.Canceled) {
            if (diagnostic) |value| if (value.len != 0) {
                details.addFile(tasks.File.init(value.pathSlice(), 0, null, 0, .failed, err));
                has_failure = true;
            };
        }
        // Otherwise retain the downloaded archive and its measured bytes.
        if (!has_failure and details.file_count != 0) {
            const file = &details.files[details.file_count - 1];
            file.state = if (err == error.Canceled) .canceled else .failed;
            file.failure = err;
        }
        details.stop();
        task.reportDetails(details);
    }
}

pub fn precommit(raw: ?*anyopaque, a: A, io: Io, stage_path: []const u8, cancel: *const CancelToken) !void {
    const source: *const Request = @ptrCast(@alignCast(raw orelse return error.MissingContext));
    var request = source.*;
    var diagnostic: packs.Diagnostics = .{};
    if (request.options.diagnostics == null) request.options.diagnostics = &diagnostic;
    request.options.diagnostics.?.len = 0;
    defer stopTelemetry(request.options.telemetry);
    return precommitImpl(&request, a, io, stage_path, cancel) catch |err| {
        failTelemetry(request.options.telemetry, request.options.diagnostics, err);
        return err;
    };
}

fn precommitImpl(request: *const Request, a: A, io: Io, stage_path: []const u8, cancel: *const CancelToken) !void {
    reportStage(request.options.telemetry, .extracting);
    try fs.cancelled(io, cancel, null);
    var prepared = try packs.prepareNewInstance(a, io, request.paths, request.instance, request.inspection, cancel, request.options.diagnostics);
    defer prepared.deinit();
    defer prepared.cleanup(io) catch {};
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    // Reparse the hash-verified archive, then reauthorize provider records at the
    // installation boundary. Override sources remain private to Prepared.
    var fresh = request.inspection.*;
    fresh.arena = .init(a);
    defer fresh.arena.deinit();
    fresh.pack = prepared.pack;
    fresh.pack.identity = request.inspection.pack.identity;
    try authorization.resolveInspection(a, io, &fresh, request.options.sourceOptions(), cancel);
    var pack = try clone(manifest.PackPlan, aa, fresh.pack);
    if (pack.unresolved.len != 0) return error.UnresolvedPackReferences;
    const files = try clone([]const manifest.InstallFile, aa, pack.files);
    const worlds = try clone([]const manifest.InstallFile, aa, pack.initial_world_files);
    for (0..files.len + worlds.len) |index| {
        const file = if (index < files.len) &@constCast(files)[index] else &@constCast(worlds)[index - files.len];
        if (index < files.len) try manifest.checkedPathForInstance(file.record.path, request.instance.name) else try manifest.checkedInitialWorldPath(file.record.path);
        if (std.mem.startsWith(u8, file.record.path, ".vela-pack-work")) return error.ProtectedPath;
        file.record.standalone = false;
        if (file.record.identity_provenance == .pack_archive or file.record.identity_provenance == .pack_override) {
            file.record.provider = pack.identity.provider;
            file.record.project_id = pack.identity.project_id;
            file.record.version_id = pack.identity.version_id;
        }
        for (request.manual_files) |mapping| if (std.mem.eql(u8, mapping.path, file.record.path)) {
            // The user explicitly disables remote delivery for this exact record.
            // Its declared hashes and size remain authoritative.
            switch (file.download) {
                .remote => |url| file.download = .{ .manual_required = .{ .official_page = url, .reason = .provider_disabled } },
                .manual_required => {},
            }
        };
        for (request.optional) |choice| if (std.mem.eql(u8, choice.path, file.record.path)) {
            file.selected = choice.include;
        };
        if (file.required and file.selected == false) return error.RequiredFileExcluded;
        if (!file.required and file.selected == null) return error.OptionalDecisionRequired;
    }
    pack.files = files;
    // The generic content transaction receives managed content only.
    pack.initial_world_files = &.{};
    var records: std.ArrayList(manifest.ManagedFile) = .empty;
    for (files) |file| if (file.required or file.selected == true) try records.append(aa, file.record);
    var membership = try manifest.membershipForPack(aa, pack);
    defer membership.deinit();
    const desired: manifest.Manifest = .{ .instance_id = request.instance.id, .pack_version = pack.identity.version_id, .files = records.items, .pack_membership = membership.value };
    var plan = try manifest.buildUpdatePlan(aa, .{ .instance_id = request.instance.id, .pack_version = "uninstalled", .files = &.{} }, desired, &.{}, &.{}, .{ .instance_id = request.instance.id, .instance_name = request.instance.name, .running = false });
    defer plan.deinit();
    var manual: std.ArrayList(install.ManualFile) = .empty;
    try manual.appendSlice(aa, prepared.manual_files);
    for (request.manual_files) |mapping| {
        for (prepared.manual_files) |owned| if (std.mem.eql(u8, owned.path, mapping.path)) return error.OverrideSourceReplacement;
        if (!manifest.initialWorldPath(mapping.path)) try manual.append(aa, mapping);
    }
    const stage = try fs.openAbsolute(io, stage_path);
    defer stage.close(io);
    if (try fs.inspectEntry(stage, io, ".vela-pack-work") != null) return error.PathAlreadyExists;
    errdefer stage.deleteTree(io, ".vela-pack-work") catch {};
    {
        const work = try fs.child(stage, io, ".vela-pack-work", true, true);
        defer work.close(io);
        const game = try fs.descend(work, io, try std.fmt.allocPrint(aa, ".minecraft/versions/{s}", .{request.instance.name}), true);
        defer game.close(io);
        var private_paths = try instances.Paths.init(aa, io, try std.fs.path.join(aa, &.{ stage_path, ".vela-pack-work" }));
        defer private_paths.deinit();
        var adapter = try download_session.open(a, io, cancel, request.options.download_connections, request.options.sourceOptions(), pack.identity.provider == .curseforge);
        defer adapter.deinit();
        adapter.telemetry = request.options.telemetry;
        reportStage(request.options.telemetry, .installing);
        var fetcher: PackFetcher = .{ .inner = adapter.fetcher(), .telemetry = request.options.telemetry };
        var initial: std.ArrayList(packs.InitialWorldFile) = .empty;
        try initial.appendSlice(aa, prepared.initial_world_files);
        for (worlds, 0..) |file, index| {
            if (!file.required and file.selected == false) continue;
            if (request.options.diagnostics) |d| d.setPath(file.record.path);
            const name = try std.fmt.allocPrint(aa, "initial-world-{d}", .{index});
            const absolute = try std.fs.path.join(aa, &.{ stage_path, ".vela-pack-work", name });
            const hash = try stageInitialWorld(io, work, name, absolute, file, request.manual_files, .{ .context = &fetcher, .fetchToFile = PackFetcher.fetch }, cancel);
            try initial.append(aa, .{ .path = file.record.path, .source_absolute_path = absolute, .fingerprint = hash });
        }
        prepared.initial_world_files = initial.items;
        if (request.options.diagnostics) |d| d.len = 0;
        var report = try install.execute(a, io, .{ .paths = &private_paths, .instance_id = request.instance.id, .instance_name = request.instance.name, .plan = plan.value, .files = files, .pack = pack, .prerequisites = .{ .overrides_processed = true, .dependencies_resolved = true, .loader_ready = true }, .manual_files = manual.items, .lease = .{ .context = null, .acquire = leaseCheck, .recheck = leaseCheck, .release = leaseRelease }, .cancel = cancel, .fetcher = .{ .context = &fetcher, .fetchToFile = PackFetcher.fetch }, .allow_curseforge_remote = request.options.transport_options.allow_curseforge, .approved_download_hosts = request.options.transport_options.approved_download_hosts });
        defer report.deinit();
        if (!report.complete or !report.committed or !report.fully_applied) return error.IncompletePack;
        reportStage(request.options.telemetry, .verifying);
        for (desired.files) |record| {
            try fs.cancelled(io, cancel, null);
            const from = try fs.parent(game, io, record.path, false);
            defer from.deinit(io);
            const fingerprint = (try fs.fingerprint(from.dir, io, from.name, cancel, null)) orelse return error.MissingPackFile;
            try fingerprint.verify(record.hashes, record.size);
            const to = try fs.parent(stage, io, record.path, true);
            defer to.deinit(io);
            if (try fs.inspectEntry(to.dir, io, to.name) != null) return error.PackGameCollision;
            try from.dir.renamePreserve(from.name, to.dir, to.name, io);
            try fs.syncDir(to.dir, io);
        }
    }
    try packs.copyInitialWorlds(&prepared, io, stage, cancel, request.options.diagnostics);
    reportStage(request.options.telemetry, .finalizing);
    try stage.deleteTree(io, ".vela-pack-work");
    try fs.syncDir(stage, io);
    const bytes = try manifest.serialize(aa, desired);
    const receipt_dir = try fs.child(stage, io, ".vela", true, true);
    defer receipt_dir.close(io);
    try fs.write(receipt_dir, io, sidecar, bytes);
    try fs.cancelled(io, cancel, null);
}

/// Downloads only into the private new-instance work directory. Authorization is
/// checked by resolveInspection; every delivered byte is verified again here.
fn stageInitialWorld(io: Io, work: Io.Dir, name: []const u8, absolute: []const u8, file: manifest.InstallFile, manual: []const install.ManualFile, fetcher: install.Fetcher, cancel: *const CancelToken) !fs.Fingerprint {
    try manifest.checkedInitialWorldPath(file.record.path);
    try fs.cancelled(io, cancel, null);
    if (try fs.inspectEntry(work, io, name) != null) return error.PathAlreadyExists;
    const limit = file.record.size orelse return error.MissingFileSize;
    switch (file.download) {
        .remote => |url| {
            var sha1: [20]u8 = undefined;
            const digest: ?[20]u8 = if (file.record.hashes.sha1) |hash| blk: {
                _ = try std.fmt.hexToBytes(&sha1, hash);
                break :blk sha1;
            } else null;
            try fetcher.fetchToFile(fetcher.context, io, .{ .url = url, .directory = work, .name = name, .absolute_path = absolute, .max_bytes = limit, .expected_size = limit, .expected_sha1 = digest, .expected_sha256 = try @import("artifact_cache.zig").parseHex(32, file.record.hashes.sha256), .expected_sha512 = try @import("artifact_cache.zig").parseHex(64, file.record.hashes.sha512), .deadline_ns = null, .cancel = cancel });
        },
        .manual_required => {
            var source_path: ?[]const u8 = null;
            for (manual) |mapping| if (std.mem.eql(u8, mapping.path, file.record.path)) {
                if (source_path != null) return error.DuplicateManualFile;
                source_path = mapping.source_absolute_path;
            };
            const path = source_path orelse return error.ManualFileRequired;
            const parent = try fs.openAbsolute(io, std.fs.path.dirname(path) orelse return error.UnsafePath);
            defer parent.close(io);
            const source = try fs.openRegular(parent, io, std.fs.path.basename(path));
            defer source.close(io);
            _ = try fs.copy(source, work, io, name, limit, cancel, null);
        },
    }
    const staged = try fs.openRegularForSeal(work, io, name);
    defer staged.close(io);
    const hash = try fs.stream(staged, null, io, limit, cancel, null);
    try hash.verify(file.record.hashes, file.record.size);
    try staged.setPermissions(io, fs.privatePermissions(false));
    try staged.sync(io);
    try fs.syncDir(work, io);
    return hash;
}

/// Small, idempotent publication of the complete content receipt, before config
/// publication. The committed game sidecar is retained for retry/recovery.
pub fn publishManifest(a: A, io: Io, paths: *const instances.Paths, instance: config.Instance) !void {
    const game_path = try paths.instanceDirectory(instance.name);
    defer paths.allocator.free(game_path);
    const game = try fs.openAbsolute(io, game_path);
    defer game.close(io);
    const receipt_dir = try fs.child(game, io, ".vela", false, true);
    defer receipt_dir.close(io);
    const bytes = try fs.read(a, receipt_dir, io, sidecar, providers.max_json_bytes);
    defer a.free(bytes);
    var parsed = try manifest.parseForInstance(a, bytes, instance.name);
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.instance_id, instance.id)) return error.InstanceMismatch;
    const origin = instance.origin orelse return error.MissingPackOrigin;
    const identity = (parsed.value.pack_membership orelse return error.MissingPackMembership).identity;
    if (identity.provider != origin.kind or !std.mem.eql(u8, identity.project_id, origin.project_id) or !std.mem.eql(u8, identity.version_id, origin.version_id)) return error.PackIdentityMismatch;
    const root = try fs.openAbsolute(io, paths.root);
    defer root.close(io);
    const relative = try std.fmt.allocPrint(a, ".vela/instances/{s}", .{instance.id});
    defer a.free(relative);
    const metadata = try fs.descend(root, io, relative, true);
    defer metadata.close(io);
    if (try fs.inspectEntry(metadata, io, "content.json") != null) {
        const existing = try fs.read(a, metadata, io, "content.json", providers.max_json_bytes);
        defer a.free(existing);
        if (!std.mem.eql(u8, bytes, existing)) return error.ExistingContentManifest;
        try fs.syncDir(metadata, io);
        return;
    }
    try fs.atomicWrite(metadata, io, "content.json", bytes);
}
