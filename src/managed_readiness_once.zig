//! Explicit, bounded local prerequisite audit; never installs or launches Minecraft.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("core/config.zig");
const instances = @import("core/instances.zig");
const metadata = @import("core/minecraft/metadata/root.zig");
const loader = @import("core/minecraft/metadata_loader.zig");
const planner = @import("core/minecraft/install_plan.zig");
const safe = @import("core/install/safe_fs.zig");
const content_fs = @import("core/content_fs.zig");
const native = @import("core/minecraft/native_extract.zig");
const library = @import("ui/game_library.zig");
const java = @import("ui/java_manager.zig");

const root = "/home/HumXC/vela-launcher";
const version = "26.3";
const instance_id = "instance-f080ccdb023c69330676f851fae5e9b7";
const metadata_sha1 = "4fe1aa1ef8da1cb95c5bad1fb98890ca56dd8ca3";
const metadata_size = 44992;
const client_sha1 = "e877b6a07acd633fb3bb475002175cec036e7b87";
const client_size = 41483720;
const required_java_major = 25;
const max_index_bytes = 16 * 1024 * 1024;
const max_files = 100000;
const max_file_bytes: u64 = 512 * 1024 * 1024;
const max_total_bytes: u64 = 16 * 1024 * 1024 * 1024;
const max_failures = 64;
const audit_duration_ms = 300000;

const Status = enum { not_audited, verified, failed };
const Failure = struct { phase: []const u8, path: ?[]const u8, error_name: []const u8 };
const KindCounts = struct {
    client: usize = 0,
    library: usize = 0,
    native: usize = 0,
    asset_index: usize = 0,
    asset: usize = 0,
    logging: usize = 0,

    fn add(self: *KindCounts, kind: planner.Kind) void {
        switch (kind) {
            .client => self.client += 1,
            .library => self.library += 1,
            .native => self.native += 1,
            .asset_index => self.asset_index += 1,
            .asset => self.asset += 1,
            .logging => self.logging += 1,
        }
    }
};
const Summary = struct {
    schema_version: u32 = 1,
    mode: []const u8 = "read-only-prerequisites",
    launcher_root: []const u8 = root,
    minecraft_version: []const u8 = version,
    expected_instance_id: []const u8 = instance_id,
    cpu_arch: []const u8 = @tagName(builtin.cpu.arch),
    snapshot_only: bool = true,
    configuration: struct {
        status: Status = .not_audited,
        registered_instance_present: bool = false,
    } = .{},
    accounts: struct {
        status: enum { unverified, empty } = .unverified,
        count: ?usize = null,
        selected_account_present: ?bool = null,
    } = .{},
    metadata: struct {
        status: Status = .not_audited,
        pinned_sha1: []const u8 = metadata_sha1,
        pinned_size: usize = metadata_size,
        advertised_java_major: ?u64 = null,
    } = .{},
    asset_index: struct { status: Status = .not_audited } = .{},
    enumeration: enum { blocked, complete } = .blocked,
    enumeration_blocked: bool = true,
    assets_count: ?usize = null,
    unique_asset_files: ?usize = null,
    artifacts: struct {
        status: Status = .not_audited,
        required_files: ?usize = null,
        attempted_files: usize = 0,
        unattempted_files: ?usize = null,
        verified_files: usize = 0,
        failed_files: usize = 0,
        missing_files: usize = 0,
        hash_mismatches: usize = 0,
        size_mismatches: usize = 0,
        unsafe_or_changed_files: usize = 0,
        unverifiable_files: usize = 0,
        other_failures: usize = 0,
        bytes_verified: u64 = 0,
        required_by_kind: KindCounts = .{},
        verified_by_kind: KindCounts = .{},
    } = .{},
    natives: struct {
        required_archives: ?usize = null,
        inspected_archives: usize = 0,
        failed_archives: usize = 0,
        extraction_tasks_planned: ?usize = null,
        extraction_performed: bool = false,
    } = .{},
    asset_materializations: struct {
        required_destinations: ?usize = null,
        attempted_destinations: usize = 0,
        verified_destinations: usize = 0,
        failed_destinations: usize = 0,
        materialization_performed: bool = false,
    } = .{},
    java_probe: struct {
        status: enum { not_probed, verified, failed, incompatible } = .not_probed,
        source: []const u8 = "explicit_VELA_AUDIT_JAVA_PATH_only",
        path: ?[]const u8 = null,
        major: ?u32 = null,
        vendor: ?[]const u8 = null,
        required_major: u32 = required_java_major,
    } = .{},
    local_artifacts_ready: bool = false,
    launch_readiness: []const u8 = "unverified",
    game_launched: bool = false,
    downloads_performed: bool = false,
    config_writes_performed: bool = false,
    limits: struct {
        asset_index_bytes: usize = max_index_bytes,
        logical_assets: usize = max_files,
        planned_files: usize = max_files,
        file_bytes: u64 = max_file_bytes,
        total_expected_bytes: u64 = max_total_bytes,
        failure_examples: usize = max_failures,
        cooperative_audit_duration_ms: usize = audit_duration_ms,
    } = .{},
};
const Report = struct {
    summary: Summary = .{},
    failures: std.ArrayList(Failure) = .empty,
    omitted_failure_examples: usize = 0,

    fn fail(self: *Report, a: std.mem.Allocator, phase: []const u8, path: ?[]const u8, err: anyerror) !void {
        if (self.failures.items.len == max_failures) {
            self.omitted_failure_examples += 1;
            return;
        }
        const owned_path = if (path) |p| try a.dupe(u8, p) else null;
        errdefer if (owned_path) |p| a.free(p);
        try self.failures.append(a, .{ .phase = phase, .path = owned_path, .error_name = @errorName(err) });
    }

    fn deinit(self: *Report, a: std.mem.Allocator) void {
        for (self.failures.items) |failure| if (failure.path) |p| a.free(p);
        self.failures.deinit(a);
        if (self.summary.java_probe.path) |p| a.free(p);
        if (self.summary.java_probe.vendor) |v| a.free(v);
    }
};

fn fatal(err: anyerror) bool {
    return err == error.OutOfMemory or err == error.Canceled or err == error.Cancelled;
}

fn checkDeadline(io: std.Io, deadline: i96, cancel: safe.Cancel) !void {
    try safe.canceled(cancel);
    if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.TimedOut;
}

fn sameStat(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.kind == .file and b.kind == .file and a.nlink == 1 and b.nlink == 1 and
        a.inode == b.inode and a.size == b.size and
        a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}

fn verifyOne(a: std.mem.Allocator, io: std.Io, path: []const u8, expected_sha1: [20]u8, expected_size: u64, native_arch: ?[]const u8, cancel: safe.Cancel, deadline: i96) !content_fs.Fingerprint {
    return verifyOneWithFamily(a, io, path, expected_sha1, expected_size, native_arch, cancel, deadline, null);
}
fn verifyOneWithFamily(a: std.mem.Allocator, io: std.Io, path: []const u8, expected_sha1: [20]u8, expected_size: u64, native_arch: ?[]const u8, cancel: safe.Cancel, deadline: i96, family: ?native.ClassicFamily) !content_fs.Fingerprint {
    try checkDeadline(io, deadline, cancel);
    if (expected_size > max_file_bytes) return error.AuditFileLimitExceeded;
    const parent = try safe.openParent(io, path, false);
    defer parent.close(io);
    const name = std.fs.path.basename(path);
    const named = try parent.statFile(io, name, .{ .follow_symlinks = false });
    if (named.kind != .file or named.nlink != 1) return error.UnsafeFileType;
    const file = try parent.openFile(io, name, .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(io);
    const before = try file.stat(io);
    if (!sameStat(named, before)) return error.TreeChanged;
    if (before.size != expected_size) return error.SizeMismatch;
    const result = try content_fs.stream(file, null, io, expected_size, cancel, deadline);
    const hex = std.fmt.bytesToHex(expected_sha1, .lower);
    try result.verify(.{ .sha1 = &hex }, expected_size);
    if (native_arch) |arch| try native.inspectFileWithFamily(a, io, file, arch, cancel, family);
    try checkDeadline(io, deadline, cancel);
    const after = try file.stat(io);
    const final_named = try parent.statFile(io, name, .{ .follow_symlinks = false });
    if (!sameStat(before, after) or !sameStat(before, final_named)) return error.TreeChanged;
    return result;
}

fn readConfiguration(a: std.mem.Allocator, io: std.Io, report: *Report) !void {
    var store = config.Store.init(a, io, root) catch |err| {
        if (fatal(err)) return err;
        report.summary.configuration.status = .failed;
        try report.fail(a, "configuration", null, err);
        return;
    };
    defer store.deinit();
    const doc = store.snapshot();
    report.summary.configuration.status = .verified;
    report.summary.accounts.count = doc.accounts.len;
    report.summary.accounts.status = if (doc.accounts.len == 0) .empty else .unverified;
    report.summary.accounts.selected_account_present = doc.selected_account != null;
    const row = instances.findById(doc, instance_id) orelse {
        try report.fail(a, "configuration", null, error.RegisteredInstanceMissing);
        return;
    };
    if (!std.mem.eql(u8, row.name, version) or !std.mem.eql(u8, row.minecraft_version, version) or
        row.loader != .vanilla or row.loader_version != null)
    {
        try report.fail(a, "configuration", null, error.RegisteredInstanceMismatch);
        return;
    }
    report.summary.configuration.registered_instance_present = true;
}

fn pinMetadata(loaded: *const loader.Loaded) ![20]u8 {
    if (loaded.sources.value.len != 1) return error.MetadataPinMismatch;
    const source = loaded.sources.value[0];
    if (!std.mem.eql(u8, source.id, version) or source.bytes.len != metadata_size) return error.MetadataPinMismatch;
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(source.bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, metadata_sha1)) return error.MetadataPinMismatch;
    const base = loaded.version.value;
    if (!std.mem.eql(u8, base.id, version) or base.inherits_from != null or base.jar != null or
        !std.mem.eql(u8, base.main_class orelse return error.MetadataPinMismatch, "net.minecraft.client.main.Main"))
        return error.MetadataPinMismatch;
    const runtime = base.java_version orelse return error.MetadataPinMismatch;
    if (runtime.major_version != required_java_major or !std.mem.eql(u8, runtime.component, "java-runtime-epsilon"))
        return error.MetadataPinMismatch;
    var client_found = false;
    for (base.downloads) |entry| {
        if (!std.mem.eql(u8, entry.name, "client")) continue;
        if (client_found) return error.MetadataPinMismatch;
        const hash = entry.download.sha1 orelse return error.MetadataPinMismatch;
        const client_hex = std.fmt.bytesToHex(hash, .lower);
        if (!std.mem.eql(u8, &client_hex, client_sha1) or entry.download.size != client_size)
            return error.MetadataPinMismatch;
        client_found = true;
    }
    if (!client_found) return error.MetadataPinMismatch;
    return digest;
}

fn countFileFailure(report: *Report, err: anyerror) void {
    const counts = &report.summary.artifacts;
    counts.failed_files += 1;
    switch (err) {
        error.FileNotFound => counts.missing_files += 1,
        error.HashMismatch => counts.hash_mismatches += 1,
        error.SizeMismatch, error.BodyTooLarge => counts.size_mismatches += 1,
        error.UnsafePath, error.UnsafeFileType, error.TreeChanged, error.SymLinkLoop, error.NotDir => counts.unsafe_or_changed_files += 1,
        error.UnverifiableGamePrerequisite => counts.unverifiable_files += 1,
        else => counts.other_failures += 1,
    }
}

fn expectedBytes(total: *u64, size: ?u64) !void {
    const n = size orelse return;
    if (n > max_file_bytes) return error.AuditFileLimitExceeded;
    if (n > max_total_bytes - total.*) return error.AuditTotalLimitExceeded;
    total.* += n;
}

fn auditGame(a: std.mem.Allocator, io: std.Io, paths: *const instances.Paths, report: *Report, cancel: safe.Cancel, deadline: i96) !void {
    var loaded = try loader.load(a, io, .{
        .root = paths.minecraft,
        .version_id = version,
        .cancel = cancel,
        // This budget also bounds the resolved model, not only raw JSON bytes.
        // pinMetadata still requires the exact 44992-byte authenticated snapshot.
        .limits = .{ .max_depth = 1, .max_documents = 1, .max_bytes = metadata.version.max_document_bytes },
    }, .{});
    defer loaded.deinit();
    const source_sha1 = try pinMetadata(&loaded);
    const metadata_path = try paths.versionDocument(version);
    defer a.free(metadata_path);
    _ = try verifyOne(a, io, metadata_path, source_sha1, metadata_size, null, cancel, deadline);
    report.summary.metadata.status = .verified;
    report.summary.metadata.advertised_java_major = loaded.version.value.java_version.?.major_version;

    const index = loaded.version.value.asset_index orelse return error.MissingAssetIndex;
    const index_sha1 = index.sha1 orelse return error.UnverifiableGamePrerequisite;
    const index_size = index.size orelse return error.UnverifiableGamePrerequisite;
    if (index_size > max_index_bytes) return error.AuditIndexLimitExceeded;
    try safe.component(index.id);
    const index_name = try std.fmt.allocPrint(a, "{s}.json", .{index.id});
    defer a.free(index_name);
    const index_path = try std.fs.path.join(a, &.{ paths.assets, "indexes", index_name });
    defer a.free(index_path);
    try checkDeadline(io, deadline, cancel);
    const index_bytes = try safe.read(a, io, index_path, max_index_bytes, cancel);
    defer a.free(index_bytes);
    if (index_bytes.len != index_size) return error.SizeMismatch;
    var index_digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(index_bytes, &index_digest, .{});
    if (!std.mem.eql(u8, &index_digest, &index_sha1)) return error.HashMismatch;
    var assets = try metadata.asset_index.parseSlice(a, index_bytes);
    defer assets.deinit();
    if (assets.value.objects.len > max_files) return error.AuditFileLimitExceeded;
    report.summary.asset_index.status = .verified;

    const game_directory = try paths.instanceDirectory(version);
    defer a.free(game_directory);
    var plan = try planner.buildInstalled(a, loaded.version.value, assets.value, try library.hostEnvironment(), .{
        .root = paths.minecraft,
        .instance_name = version,
        .game_directory = game_directory,
        .native_arch = if (@bitSizeOf(usize) == 64) .bits64 else .bits32,
        .cpu_arch = @tagName(builtin.cpu.arch),
    });
    defer plan.deinit();
    if (plan.value.files.len == 0) return error.EmptyAuditPlan;
    if (plan.value.files.len > max_files or plan.value.asset_materializations.len > max_files or
        plan.value.native_checks.len > max_files or plan.value.native_extractions.len > max_files)
        return error.AuditFileLimitExceeded;

    var native_paths = std.StringHashMap(?native.ClassicFamily).init(a);
    defer native_paths.deinit();
    for (plan.value.native_checks) |check| try native_paths.put(check.archive_path, check.classic_family);
    for (plan.value.native_extractions) |task| try native_paths.put(task.archive_path, task.classic_family);
    report.summary.enumeration = .complete;
    report.summary.enumeration_blocked = false;
    report.summary.assets_count = assets.value.objects.len;
    report.summary.artifacts.required_files = plan.value.files.len;
    report.summary.natives.required_archives = native_paths.count();
    report.summary.natives.extraction_tasks_planned = plan.value.native_extractions.len;
    report.summary.asset_materializations.required_destinations = plan.value.asset_materializations.len;
    report.summary.artifacts.status = .failed;
    for (plan.value.files) |file| report.summary.artifacts.required_by_kind.add(file.kind);
    report.summary.unique_asset_files = report.summary.artifacts.required_by_kind.asset;
    var total_expected: u64 = metadata_size;
    for (plan.value.files) |file| try expectedBytes(&total_expected, file.size);
    for (plan.value.asset_materializations) |destination| try expectedBytes(&total_expected, destination.size);

    for (plan.value.files) |file| {
        try checkDeadline(io, deadline, cancel);
        report.summary.artifacts.attempted_files += 1;
        const native_arch: ?[]const u8 = if (native_paths.contains(file.path)) @tagName(builtin.cpu.arch) else null;
        const hash = file.sha1 orelse {
            countFileFailure(report, error.UnverifiableGamePrerequisite);
            if (native_arch != null) report.summary.natives.failed_archives += 1;
            try report.fail(a, "artifact", file.path, error.UnverifiableGamePrerequisite);
            continue;
        };
        const size = file.size orelse {
            countFileFailure(report, error.UnverifiableGamePrerequisite);
            if (native_arch != null) report.summary.natives.failed_archives += 1;
            try report.fail(a, "artifact", file.path, error.UnverifiableGamePrerequisite);
            continue;
        };
        const verified = verifyOneWithFamily(a, io, file.path, hash, size, native_arch, cancel, deadline, native_paths.get(file.path) orelse null) catch |err| {
            if (fatal(err)) return err;
            countFileFailure(report, err);
            if (native_arch != null) report.summary.natives.failed_archives += 1;
            try report.fail(a, if (native_arch != null) "native_archive" else "artifact", file.path, err);
            if (err == error.TimedOut) return err;
            continue;
        };
        report.summary.artifacts.verified_files += 1;
        report.summary.artifacts.verified_by_kind.add(file.kind);
        report.summary.artifacts.bytes_verified += verified.size;
        if (native_arch != null) report.summary.natives.inspected_archives += 1;
    }
    for (plan.value.asset_materializations) |destination| {
        try checkDeadline(io, deadline, cancel);
        report.summary.asset_materializations.attempted_destinations += 1;
        _ = verifyOne(a, io, destination.destination, destination.sha1, destination.size, null, cancel, deadline) catch |err| {
            if (fatal(err)) return err;
            report.summary.asset_materializations.failed_destinations += 1;
            try report.fail(a, "asset_materialization", destination.destination, err);
            if (err == error.TimedOut) return err;
            continue;
        };
        report.summary.asset_materializations.verified_destinations += 1;
    }
    if (report.summary.natives.inspected_archives + report.summary.natives.failed_archives != native_paths.count())
        return error.IncompleteNativeAuditPlan;
    report.summary.local_artifacts_ready = report.summary.artifacts.failed_files == 0 and
        report.summary.artifacts.verified_files == plan.value.files.len and
        report.summary.natives.inspected_archives == native_paths.count() and
        report.summary.asset_materializations.verified_destinations == plan.value.asset_materializations.len;
    report.summary.artifacts.status = if (report.summary.local_artifacts_ready) .verified else .failed;
}

fn auditJava(a: std.mem.Allocator, io: std.Io, explicit_path: ?[]const u8, report: *Report, cancel: safe.Cancel) !void {
    const path = explicit_path orelse return;
    report.summary.java_probe.status = .failed;
    if (path.len == 0 or path.len > 4096) {
        try report.fail(a, "java_probe", null, error.InvalidJavaPath);
        return;
    }
    report.summary.java_probe.path = try a.dupe(u8, path);
    const runtime = java.probe(a, io, path, cancel) catch |err| {
        if (fatal(err)) return err;
        try report.fail(a, "java_probe", path, err);
        return;
    };
    defer java.freeRuntime(a, runtime);
    a.free(report.summary.java_probe.path.?);
    report.summary.java_probe.path = null;
    report.summary.java_probe.path = try a.dupe(u8, runtime.path);
    report.summary.java_probe.vendor = try a.dupe(u8, runtime.vendor);
    report.summary.java_probe.major = runtime.major;
    report.summary.java_probe.status = if (runtime.major == required_java_major) .verified else .incompatible;
    if (runtime.major != required_java_major) try report.fail(a, "java_probe", runtime.path, error.JavaMajorMismatch);
}

pub fn main(init: std.process.Init) !void {
    const opt_in = init.environ_map.get("VELA_AUDIT_EXISTING_26_3") orelse return error.AuditOptInRequired;
    if (!std.mem.eql(u8, opt_in, "read-only-prerequisites")) return error.AuditOptInRequired;
    const a = init.gpa;
    const io = init.io;
    var paths = try instances.Paths.init(a, io, root);
    defer paths.deinit();
    var report: Report = .{};
    defer report.deinit(a);
    var canceled: std.atomic.Value(bool) = .init(false);
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + audit_duration_ms * std.time.ns_per_ms;
    try readConfiguration(a, io, &report);
    auditGame(a, io, &paths, &report, &canceled, deadline) catch |err| {
        if (fatal(err)) return err;
        report.summary.local_artifacts_ready = false;
        report.summary.artifacts.status = .failed;
        if (report.summary.metadata.status != .verified) {
            report.summary.metadata.status = .failed;
        } else if (report.summary.asset_index.status != .verified) {
            report.summary.asset_index.status = .failed;
        }
        try report.fail(a, "audit", null, err);
    };
    try auditJava(a, io, init.environ_map.get("VELA_AUDIT_JAVA_PATH"), &report, &canceled);
    if (report.summary.artifacts.required_files) |required| {
        report.summary.artifacts.unattempted_files = required - report.summary.artifacts.attempted_files;
    }
    const json = try std.json.Stringify.valueAlloc(a, .{
        .audit = report.summary,
        .failure_examples = report.failures.items,
        .omitted_failure_examples = report.omitted_failure_examples,
    }, .{});
    defer a.free(json);
    try std.Io.File.stdout().writeStreamingAll(io, json);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}
