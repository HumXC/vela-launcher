const std = @import("std");
const builtin = @import("builtin");
const install = @import("content_install.zig");
const fs = @import("content_fs.zig");
const manifest = @import("content_manifest.zig");
const providers = @import("content_providers.zig");
const instances = @import("instances.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn fingerprint(bytes: []const u8) fs.Fingerprint {
    var sha1: [20]u8 = undefined;
    var sha256: [32]u8 = undefined;
    var sha512: [64]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &sha1, .{});
    std.crypto.hash.sha2.Sha256.hash(bytes, &sha256, .{});
    std.crypto.hash.sha2.Sha512.hash(bytes, &sha512, .{});
    return .{ .size = bytes.len, .sha1 = std.fmt.bytesToHex(sha1, .lower), .sha256 = std.fmt.bytesToHex(sha256, .lower), .sha512 = std.fmt.bytesToHex(sha512, .lower) };
}
fn record(hash: *const fs.Fingerprint, path: []const u8, version: []const u8) manifest.ManagedFile {
    return .{ .path = path, .provider = .modrinth, .project_id = "project", .version_id = version, .hashes = hash.hashes(), .size = hash.size };
}
const Guard = struct {
    held: bool = false,
    running: bool = false,
    acquired: usize = 0,
    released: usize = 0,
    fn acquire(context: ?*anyopaque, _: []const u8) !void {
        const self: *Guard = @ptrCast(@alignCast(context.?));
        if (self.running) return error.InstanceRunning;
        if (self.held) return error.InstanceBusy;
        self.held = true;
        self.acquired += 1;
    }
    fn recheck(context: ?*anyopaque, _: []const u8) !void {
        const self: *Guard = @ptrCast(@alignCast(context.?));
        if (!self.held) return error.LeaseNotHeld;
        if (self.running) return error.InstanceRunning;
    }
    fn release(context: ?*anyopaque, _: []const u8) void {
        const self: *Guard = @ptrCast(@alignCast(context.?));
        self.held = false;
        self.released += 1;
    }
    fn lease(self: *Guard) install.Lease {
        return .{ .context = self, .acquire = acquire, .recheck = recheck, .release = release };
    }
};
const Fixture = struct {
    tmp: std.testing.TmpDir,
    paths: instances.Paths,
    guard: Guard = .{},
    old_hash: fs.Fingerprint = undefined,
    new_hash: fs.Fingerprint = undefined,
    old_records: [2]manifest.ManagedFile = undefined,
    new_records: [2]manifest.ManagedFile = undefined,
    original_manifest: ?[]u8 = null,
    fetches: usize = 0,
    fetch_body: []const u8 = "new",
    cancel: std.atomic.Value(bool) = .init(false),
    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io, &buffer);
        return .{ .tmp = tmp, .paths = try instances.Paths.init(a, io, buffer[0..len]) };
    }
    fn seed(self: *Fixture) !void {
        self.old_hash = fingerprint("old");
        self.new_hash = fingerprint("new");
        self.old_records = .{ record(&self.old_hash, "mods/replace.jar", "old"), record(&self.old_hash, "mods/remove.jar", "old") };
        self.new_records = .{ record(&self.new_hash, "mods/replace.jar", "new"), record(&self.new_hash, "mods/new.jar", "new") };
        try self.tmp.dir.createDirPath(io, ".minecraft/versions/Test/mods");
        try self.tmp.dir.createDirPath(io, ".vela/instances/instance");
        try self.write(".minecraft/versions/Test/mods/replace.jar", "old");
        try self.write(".minecraft/versions/Test/mods/remove.jar", "old");
        self.original_manifest = try manifest.serialize(a, self.oldManifest());
        try self.write(".vela/instances/instance/content.json", self.original_manifest.?);
    }
    fn deinit(self: *Fixture) void {
        if (self.original_manifest) |bytes| a.free(bytes);
        self.paths.deinit();
        self.tmp.cleanup();
    }
    fn write(self: *Fixture, path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = path, .data = data });
    }
    fn read(self: *Fixture, path: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(io, path, a, .limited(8 * 1024 * 1024));
    }
    fn oldManifest(self: *Fixture) manifest.Manifest {
        return .{ .instance_id = "instance", .pack_version = "old", .files = &self.old_records };
    }
    fn desired(self: *Fixture) manifest.Manifest {
        return .{ .instance_id = "instance", .pack_version = "new", .files = &self.new_records };
    }
    fn plan(self: *Fixture) !providers.Owned(manifest.UpdatePlan) {
        const observed = [_]manifest.ObservedFile{
            .{ .path = "mods/replace.jar", .hashes = self.old_hash.hashes(), .size = self.old_hash.size },
            .{ .path = "mods/remove.jar", .hashes = self.old_hash.hashes(), .size = self.old_hash.size },
        };
        return manifest.buildUpdatePlan(a, self.oldManifest(), self.desired(), &observed, &.{}, .{ .instance_id = "instance", .running = false });
    }
    fn files(self: *Fixture) [2]manifest.InstallFile {
        return .{
            .{ .record = self.new_records[0], .download = .{ .remote = "https://cdn.modrinth.com/replace" } },
            .{ .record = self.new_records[1], .download = .{ .remote = "https://cdn.modrinth.com/new" } },
        };
    }
    fn fetch(context: ?*anyopaque, actual_io: std.Io, request: install.FetchRequest) !void {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        try std.testing.expect(self.guard.held);
        self.fetches += 1;
        try fs.cancelled(actual_io, request.cancel, request.deadline_ns);
        try fs.write(request.directory, actual_io, request.name, self.fetch_body);
    }
    fn options(self: *Fixture, plan_value: manifest.UpdatePlan, files_value: []const manifest.InstallFile) install.Options {
        return .{ .paths = &self.paths, .instance_id = "instance", .instance_name = "Test", .plan = plan_value, .files = files_value, .lease = self.guard.lease(), .cancel = &self.cancel, .fetcher = .{ .context = self, .fetchToFile = fetch } };
    }
    fn assertBefore(self: *Fixture) !void {
        for ([_][]const u8{ "mods/replace.jar", "mods/remove.jar" }) |path| {
            const full = try std.fmt.allocPrint(a, ".minecraft/versions/Test/{s}", .{path});
            defer a.free(full);
            const bytes = try self.read(full);
            defer a.free(bytes);
            try std.testing.expectEqualStrings("old", bytes);
        }
        try std.testing.expectError(error.FileNotFound, self.tmp.dir.statFile(io, ".minecraft/versions/Test/mods/new.jar", .{}));
        const bytes = try self.read(".vela/instances/instance/content.json");
        defer a.free(bytes);
        try std.testing.expectEqualStrings(self.original_manifest.?, bytes);
        try std.testing.expect(!self.guard.held);
        try std.testing.expectEqual(self.guard.acquired, self.guard.released);
    }
    fn recovery(self: *Fixture, id: []const u8) install.RecoverOptions {
        return .{ .paths = &self.paths, .instance_id = "instance", .instance_name = "Test", .transaction_id = id, .lease = self.guard.lease() };
    }
};
const Inject = struct {
    point: install.FaultPoint,
    index: usize = 0,
    hits: usize = 0,
    crash: bool = false,
    block_rollback: bool = false,
    cancel: ?*std.atomic.Value(bool) = null,
    fn boundary(context: ?*anyopaque, point: install.FaultPoint, index: usize) !void {
        const self: *Inject = @ptrCast(@alignCast(context.?));
        if (self.block_rollback and (point == .rollback_mutation or point == .rollback_manifest)) return error.AccessDenied;
        if (point != self.point or index != self.index) return;
        self.hits += 1;
        if (self.cancel) |flag| {
            flag.store(true, .release);
            return;
        }
        return if (self.crash) error.SimulatedCrash else error.InjectedFailure;
    }
    fn fault(self: *Inject) install.Fault {
        return .{ .context = self, .boundary = boundary };
    }
};

test "real disk install retains backups and publishes complete manifest last" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    const files = fixture.files();
    var options = fixture.options(plan.value, &files);
    options.pack = .{ .identity = .{ .provider = .modrinth, .project_id = "project", .version_id = "new" }, .name = "Pack", .version = "new", .minecraft_version = "1.20.1", .files = &files };
    options.prerequisites = .{ .overrides_processed = true, .dependencies_resolved = true, .loader_ready = true };
    var report = try install.execute(a, io, options);
    defer report.deinit();
    try std.testing.expect(report.committed and report.fully_applied and report.complete);
    try std.testing.expectEqual(@as(usize, 3), report.applied_files);
    try std.testing.expectEqual(@as(usize, 2), fixture.fetches);
    const content = try fixture.read(".minecraft/versions/Test/mods/replace.jar");
    defer a.free(content);
    try std.testing.expectEqualStrings("new", content);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft/versions/Test/mods/remove.jar", .{}));
    const txn = try fs.openAbsolute(io, report.backup_directory);
    defer txn.close(io);
    const backup = try fs.read(a, txn, io, "before-0", 10);
    defer a.free(backup);
    try std.testing.expectEqualStrings("old", backup);
    const removed_backup = try fs.read(a, txn, io, "before-2", 10);
    defer a.free(removed_backup);
    try std.testing.expectEqualStrings("old", removed_backup);
    var recovered = try install.recover(a, io, fixture.recovery(report.transaction_id));
    defer recovered.deinit();
    try std.testing.expect(recovered.committed and !recovered.complete);
}

test "every precommit disk boundary rolls back exact content and manifest" {
    for ([_]install.FaultPoint{ .before_backup, .after_backup, .before_journal, .after_journal, .before_mutation, .after_mutation, .before_manifest, .after_manifest, .before_commit_marker }) |point| {
        const count: usize = if (point == .before_mutation or point == .after_mutation) 3 else 1;
        for (0..count) |index| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            try fixture.seed();
            var plan = try fixture.plan();
            defer plan.deinit();
            const files = fixture.files();
            var inject: Inject = .{ .point = point, .index = index };
            var options = fixture.options(plan.value, &files);
            options.fault = inject.fault();
            try std.testing.expectError(error.InjectedFailure, install.execute(a, io, options));
            try std.testing.expectEqual(@as(usize, 1), inject.hits);
            try fixture.assertBefore();
            if (point != .before_backup and point != .after_backup and point != .before_journal) {
                var transactions = try install.listTransactions(a, io, &fixture.paths, "instance", "Test");
                defer transactions.deinit();
                try std.testing.expectEqual(@as(usize, 1), transactions.value.len);
                var recovered = try install.recover(a, io, fixture.recovery(transactions.value[0]));
                defer recovered.deinit();
                try std.testing.expect(!recovered.committed);
                try fixture.assertBefore();
            }
        }
    }
}

test "journal recovers all interrupted commit boundaries and durable commit wins" {
    for ([_]install.FaultPoint{ .after_journal, .before_mutation, .after_mutation, .before_manifest, .after_manifest, .before_commit_marker, .after_commit_marker }) |point| {
        const count: usize = if (point == .before_mutation or point == .after_mutation) 3 else 1;
        for (0..count) |index| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            try fixture.seed();
            var plan = try fixture.plan();
            defer plan.deinit();
            const files = fixture.files();
            var inject: Inject = .{ .point = point, .index = index, .crash = true };
            var options = fixture.options(plan.value, &files);
            options.fault = inject.fault();
            try std.testing.expectError(error.SimulatedCrash, install.execute(a, io, options));
            var transactions = try install.listTransactions(a, io, &fixture.paths, "instance", "Test");
            defer transactions.deinit();
            try std.testing.expectEqual(@as(usize, 1), transactions.value.len);
            var recovered = try install.recover(a, io, fixture.recovery(transactions.value[0]));
            defer recovered.deinit();
            try std.testing.expectEqual(point == .after_commit_marker, recovered.committed);
            if (!recovered.committed) try fixture.assertBefore();
            var again = try install.recover(a, io, fixture.recovery(transactions.value[0]));
            defer again.deinit();
            try std.testing.expectEqual(recovered.committed, again.committed);
        }
    }
}

test "cancellation restores originals before durable commit" {
    for ([_]install.FaultPoint{ .after_journal, .after_mutation, .before_manifest, .after_manifest, .before_commit_marker, .after_commit_marker }) |point| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.seed();
        var plan = try fixture.plan();
        defer plan.deinit();
        const files = fixture.files();
        var inject: Inject = .{ .point = point, .cancel = &fixture.cancel };
        var options = fixture.options(plan.value, &files);
        options.fault = inject.fault();
        if (point == .after_commit_marker) {
            var report = try install.execute(a, io, options);
            defer report.deinit();
            try std.testing.expect(report.committed);
        } else {
            try std.testing.expectError(error.Canceled, install.execute(a, io, options));
            try fixture.assertBefore();
        }
    }
}

test "running lease unresolved plan hash and host failures never mutate managed files" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    var files = fixture.files();
    var options = fixture.options(plan.value, &files);
    fixture.guard.running = true;
    try std.testing.expectError(error.InstanceRunning, install.execute(a, io, options));
    try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
    fixture.guard.running = false;
    options.plan.ready = false;
    try std.testing.expectError(error.UnresolvedConflicts, install.execute(a, io, options));
    options.plan.ready = true;
    fixture.fetch_body = "bad";
    try std.testing.expectError(error.HashMismatch, install.execute(a, io, options));
    try fixture.assertBefore();
    fixture.fetch_body = "new";
    files[0].download = .{ .remote = "https://unapproved.example/download" };
    try std.testing.expectError(error.UnapprovedDownloadHost, install.execute(a, io, options));
    try fixture.assertBefore();
}

test "failed rollback is recoverable and external edits cannot be overwritten" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    const files = fixture.files();
    var inject: Inject = .{ .point = .after_mutation, .block_rollback = true };
    var options = fixture.options(plan.value, &files);
    options.fault = inject.fault();
    try std.testing.expectError(error.RecoveryRequired, install.execute(a, io, options));
    var transactions = try install.listTransactions(a, io, &fixture.paths, "instance", "Test");
    defer transactions.deinit();
    try fixture.write(".minecraft/versions/Test/mods/replace.jar", "user changed after failure");
    try std.testing.expectError(error.RecoveryConflict, install.recover(a, io, fixture.recovery(transactions.value[0])));
    const actual = try fixture.read(".minecraft/versions/Test/mods/replace.jar");
    defer a.free(actual);
    try std.testing.expectEqualStrings("user changed after failure", actual);
    try fixture.write(".minecraft/versions/Test/mods/replace.jar", "new");
    var recovered = try install.recover(a, io, fixture.recovery(transactions.value[0]));
    defer recovered.deinit();
    try fixture.assertBefore();
}

test "nofollow rejects leaves ancestors metadata and native case aliases" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for (0..4) |kind| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.seed();
        var plan = try fixture.plan();
        defer plan.deinit();
        const files = fixture.files();
        switch (kind) {
            0 => {
                try fixture.tmp.dir.deleteFile(io, ".minecraft/versions/Test/mods/replace.jar");
                try fixture.tmp.dir.symLink(io, "remove.jar", ".minecraft/versions/Test/mods/replace.jar", .{});
            },
            1 => {
                try fixture.tmp.dir.rename(".minecraft/versions/Test/mods", fixture.tmp.dir, ".minecraft/versions/Test/real-mods", io);
                try fixture.tmp.dir.symLink(io, "real-mods", ".minecraft/versions/Test/mods", .{ .is_directory = true });
            },
            2 => {
                try fixture.tmp.dir.rename(".vela", fixture.tmp.dir, "real-vela", io);
                try fixture.tmp.dir.symLink(io, "real-vela", ".vela", .{ .is_directory = true });
            },
            3 => try fixture.tmp.dir.rename(".minecraft/versions/Test/mods", fixture.tmp.dir, ".minecraft/versions/Test/Mods", io),
            else => unreachable,
        }
        try std.testing.expectError(if (kind == 3) error.NativePathAlias else error.UnsafeFileType, install.execute(a, io, fixture.options(plan.value, &files)));
        try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
        try std.testing.expect(!fixture.guard.held);
    }
}

test "incremental copy verifies all digests size limit and cancellation" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var data: [196613]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index);
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = &data });
    const source = try fs.openRegular(tmp.dir, io, "source");
    defer source.close(io);
    const copied = try fs.copy(source, tmp.dir, io, "copy", data.len, null, null);
    const expected = fingerprint(&data);
    try std.testing.expect(copied.eql(expected));
    var bad = expected;
    bad.sha512[0] = if (bad.sha512[0] == '0') '1' else '0';
    try std.testing.expectError(error.HashMismatch, copied.verify(bad.hashes(), bad.size));
    if (@hasField(providers.Hashes, "sha256")) {
        bad = expected;
        bad.sha256[0] = if (bad.sha256[0] == '0') '1' else '0';
        try std.testing.expectError(error.HashMismatch, copied.verify(bad.hashes(), bad.size));
    }
    try std.testing.expectError(error.SizeMismatch, copied.verify(expected.hashes(), data.len + 1));
    try std.testing.expectError(error.BodyTooLarge, fs.copy(source, tmp.dir, io, "too-big", data.len - 1, null, null));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "too-big", .{}));
    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Canceled, fs.copy(source, tmp.dir, io, "canceled", data.len, &cancel, null));
}

test "CurseForge requires manual supplied files and all hashes and limits" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    fixture.new_records[0].provider = .curseforge;
    var plan = try fixture.plan();
    defer plan.deinit();
    var files = fixture.files();
    var options = fixture.options(plan.value, &files);
    try std.testing.expectError(error.CurseForgeManualRequired, install.execute(a, io, options));
    try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
    files[0].download = .{ .manual_required = .{ .official_page = "https://www.curseforge.com/minecraft/mc-mods/project", .reason = .provider_disabled } };
    try std.testing.expectError(error.ManualFileRequired, install.execute(a, io, options));
    const source = try std.fs.path.join(a, &.{ fixture.paths.root, "manual.jar" });
    defer a.free(source);
    const manual = [_]install.ManualFile{.{ .path = "mods/replace.jar", .source_absolute_path = source }};
    options.manual_files = &manual;
    try fixture.write("manual.jar", "bad");
    try std.testing.expectError(error.HashMismatch, install.execute(a, io, options));
    try fixture.assertBefore();
    try fixture.write("manual.jar", "long");
    try std.testing.expectError(error.BodyTooLarge, install.execute(a, io, options));
    try fixture.assertBefore();
    try fixture.write("manual.jar", "new");
    var report = try install.execute(a, io, options);
    defer report.deinit();
    try std.testing.expect(report.committed and !report.complete);
    try std.testing.expectEqual(@as(usize, 1), fixture.fetches);
}

test "keep local partial plans need consent and report incomplete" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    try fixture.write(".minecraft/versions/Test/mods/replace.jar", "local");
    const local = fingerprint("local");
    const observed = [_]manifest.ObservedFile{
        .{ .path = "mods/replace.jar", .hashes = local.hashes(), .size = local.size },
        .{ .path = "mods/remove.jar", .hashes = fixture.old_hash.hashes(), .size = fixture.old_hash.size },
    };
    var plan = try manifest.buildUpdatePlan(a, fixture.oldManifest(), fixture.desired(), &observed, &.{.{ .path = "mods/replace.jar", .choice = .keep_local }}, .{ .instance_id = "instance", .running = false });
    defer plan.deinit();
    const files = fixture.files();
    var options = fixture.options(plan.value, &files);
    options.pack = .{ .identity = .{ .provider = .modrinth, .project_id = "project", .version_id = "new" }, .name = "Pack", .version = "new", .minecraft_version = "1.20.1", .files = &files };
    options.prerequisites = .{ .overrides_processed = true, .dependencies_resolved = true, .loader_ready = true };
    try std.testing.expectError(error.PartialPlanNeedsConsent, install.execute(a, io, options));
    try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
    options.allow_partial = true;
    var report = try install.execute(a, io, options);
    defer report.deinit();
    try std.testing.expect(report.committed and !report.fully_applied and !report.complete);
    try std.testing.expectEqual(@as(usize, 1), report.kept_local);
    try std.testing.expectEqual(@as(usize, 1), report.completeness.?.hash_mismatches);
    const bytes = try fixture.read(".minecraft/versions/Test/mods/replace.jar");
    defer a.free(bytes);
    try std.testing.expectEqualStrings("local", bytes);
}

test "pack missing manual optional dependency and loader state cannot claim completion" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    const files = fixture.files();
    var required = record(&fixture.new_hash, "mods/blocked.jar", "new");
    required.provider = .curseforge;
    const optional = record(&fixture.new_hash, "mods/optional.jar", "new");
    const pack_files = [_]manifest.InstallFile{
        files[0],                                                                                                                                                                files[1],
        .{ .record = required, .download = .{ .manual_required = .{ .official_page = "https://www.curseforge.com/minecraft/mc-mods/project", .reason = .provider_disabled } } }, .{ .record = optional, .download = .{ .remote = "https://cdn.modrinth.com/optional" }, .required = false },
    };
    var options = fixture.options(plan.value, &files);
    options.pack = .{ .identity = .{ .provider = .modrinth, .project_id = "project", .version_id = "new" }, .name = "Pack", .version = "new", .minecraft_version = "1.20.1", .files = &pack_files, .unresolved = &.{.{ .project_id = "dependency", .file_id = "dependency-file", .required = true }} };
    var report = try install.execute(a, io, options);
    defer report.deinit();
    try std.testing.expect(report.committed and !report.complete);
    const completion = report.completeness.?;
    try std.testing.expectEqual(@as(usize, 2), completion.verified_files);
    try std.testing.expectEqual(@as(usize, 1), completion.missing_manual);
    try std.testing.expectEqual(@as(usize, 1), completion.missing_required);
    try std.testing.expectEqual(@as(usize, 1), completion.undecided_optional);
    try std.testing.expectEqual(@as(usize, 1), completion.unresolved_references);
}

test "persisted ownership rejects forged unmanaged replacement and protected paths" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    const files = fixture.files();
    const empty = try manifest.serialize(a, .{ .instance_id = "instance", .pack_version = "old" });
    defer a.free(empty);
    try fixture.write(".vela/instances/instance/content.json", empty);
    try std.testing.expectError(error.UnmanagedFile, install.execute(a, io, fixture.options(plan.value, &files)));
    try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
    var options = fixture.options(plan.value, &files);
    const invalid_actions = [_]manifest.Action{.{ .kind = .install, .path = "saves/world/level.dat", .desired = files[0].record }};
    options.plan.actions = &invalid_actions;
    try std.testing.expectError(error.ProtectedPath, install.execute(a, io, options));
    for ([_][]const u8{ "LONGNA~1.jar", "NUL.jar", "file.jar:stream", "file.jar." }) |path| try std.testing.expect(!fs.safeComponent(path));
}

test "managed manual install streams beyond metadata transport 64MiB limit" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    const length: u64 = 65 * 1024 * 1024 + 3;
    const source = try fixture.tmp.dir.createFile(io, "large-manual.jar", .{ .read = true, .exclusive = true });
    defer source.close(io);
    const chunk: [64 * 1024]u8 = @splat(17);
    var offset: u64 = 0;
    while (offset < length) {
        const count: usize = @intCast(@min(length - offset, chunk.len));
        try source.writePositionalAll(io, chunk[0..count], offset);
        offset += count;
    }
    try source.sync(io);
    const hash = try fs.stream(source, null, io, length, null, null);
    var large = record(&hash, "mods/large.jar", "large");
    large.provider = .curseforge;
    const desired_files = [_]manifest.ManagedFile{ fixture.old_records[0], fixture.old_records[1], large };
    const observed = [_]manifest.ObservedFile{
        .{ .path = fixture.old_records[0].path, .hashes = fixture.old_hash.hashes(), .size = fixture.old_hash.size },
        .{ .path = fixture.old_records[1].path, .hashes = fixture.old_hash.hashes(), .size = fixture.old_hash.size },
    };
    var plan = try manifest.buildUpdatePlan(a, fixture.oldManifest(), .{ .instance_id = "instance", .pack_version = "large", .files = &desired_files }, &observed, &.{}, .{ .instance_id = "instance", .running = false });
    defer plan.deinit();
    const files = [_]manifest.InstallFile{.{ .record = large, .download = .{ .manual_required = .{ .official_page = "https://www.curseforge.com/minecraft/mc-mods/project", .reason = .provider_disabled } } }};
    const absolute = try std.fs.path.join(a, &.{ fixture.paths.root, "large-manual.jar" });
    defer a.free(absolute);
    const manual = [_]install.ManualFile{.{ .path = large.path, .source_absolute_path = absolute }};
    var options = fixture.options(plan.value, &files);
    options.manual_files = &manual;
    var report = try install.execute(a, io, options);
    defer report.deinit();
    try std.testing.expect(report.committed and report.fully_applied);
    try std.testing.expectEqual(@as(usize, 1), report.applied_files);
    try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
    const actual = (try fs.fingerprint(fixture.tmp.dir, io, ".minecraft/versions/Test/mods/large.jar", null, null)).?;
    try std.testing.expectEqual(length, actual.size);
    try std.testing.expect(hash.eql(actual));
}

test "pending recovery blocks new installs before transport and completed recovery permits retry" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    const files = fixture.files();
    var inject: Inject = .{ .point = .after_mutation, .crash = true };
    var options = fixture.options(plan.value, &files);
    options.fault = inject.fault();
    try std.testing.expectError(error.SimulatedCrash, install.execute(a, io, options));
    {
        fixture.guard.held = true;
        defer fixture.guard.held = false;
        const acquired = fixture.guard.acquired;
        try std.testing.expectError(error.RecoveryRequired, install.requireRecoveryClear(a, io, &fixture.paths, "instance", "Test"));
        var pending = try install.listPendingTransactions(a, io, &fixture.paths, "instance", "Test");
        defer pending.deinit();
        try std.testing.expectEqual(@as(usize, 1), pending.value.len);
        try std.testing.expectEqual(acquired, fixture.guard.acquired);
        try std.testing.expect(fixture.guard.held);
    }
    const fetches_before = fixture.fetches;
    options.fault = null;
    try std.testing.expectError(error.RecoveryRequired, install.execute(a, io, options));
    try std.testing.expectEqual(fetches_before, fixture.fetches);
    try std.testing.expect(!fixture.guard.held);
    var transactions = try install.listTransactions(a, io, &fixture.paths, "instance", "Test");
    defer transactions.deinit();
    try std.testing.expectEqual(@as(usize, 1), transactions.value.len);
    var recovered = try install.recover(a, io, fixture.recovery(transactions.value[0]));
    defer recovered.deinit();
    try fixture.assertBefore();
    try install.requireRecoveryClear(a, io, &fixture.paths, "instance", "Test");
    var pending_after_rollback = try install.listPendingTransactions(a, io, &fixture.paths, "instance", "Test");
    defer pending_after_rollback.deinit();
    try std.testing.expectEqual(@as(usize, 0), pending_after_rollback.value.len);
    var report = try install.execute(a, io, options);
    defer report.deinit();
    try std.testing.expect(report.committed);
    try install.requireRecoveryClear(a, io, &fixture.paths, "instance", "Test");
    var pending_after_commit = try install.listPendingTransactions(a, io, &fixture.paths, "instance", "Test");
    defer pending_after_commit.deinit();
    try std.testing.expectEqual(@as(usize, 0), pending_after_commit.value.len);
}

fn expectRecoveryBlocked(fixture: *Fixture) !void {
    try std.testing.expectError(error.RecoveryRequired, install.requireRecoveryClear(a, io, &fixture.paths, "instance", "Test"));
    try std.testing.expectError(error.RecoveryRequired, install.listPendingTransactions(a, io, &fixture.paths, "instance", "Test"));
}

test "read-only recovery gate creates no directories and does not acquire a lease" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.guard.held = true;
    defer fixture.guard.held = false;
    try install.requireRecoveryClear(a, io, &fixture.paths, "instance", "Absent");
    var pending = try install.listPendingTransactions(a, io, &fixture.paths, "instance", "Absent");
    defer pending.deinit();
    try std.testing.expectEqual(@as(usize, 0), pending.value.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.guard.acquired);
    try std.testing.expect(fixture.guard.held);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft/versions/Absent", .{}));
    try std.testing.expectError(error.RecoveryRequired, install.requireRecoveryClear(a, io, &fixture.paths, "../instance", "Absent"));
}

test "read-only recovery enumeration never hides malformed terminal journals and markers" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    const files = fixture.files();
    var report = try install.execute(a, io, fixture.options(plan.value, &files));
    defer report.deinit();
    const txn = try fs.openAbsolute(io, report.backup_directory);
    defer txn.close(io);
    const original = try fs.read(a, txn, io, "journal.json", 16 * 1024 * 1024);
    defer a.free(original);
    for ([_][]const u8{ "{", "{}", "[]" }) |invalid| {
        try txn.deleteFile(io, "journal.json");
        try fs.write(txn, io, "journal.json", invalid);
        try expectRecoveryBlocked(&fixture);
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, a, original, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    parsed.value.object.getPtr("instance_id").?.* = .{ .string = "other-instance" };
    const wrong_instance = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    defer a.free(wrong_instance);
    try txn.deleteFile(io, "journal.json");
    try fs.write(txn, io, "journal.json", wrong_instance);
    try expectRecoveryBlocked(&fixture);
    try txn.deleteFile(io, "journal.json");
    try expectRecoveryBlocked(&fixture);
    try fs.write(txn, io, "journal.json", original);
    try txn.deleteFile(io, "committed");
    try fs.write(txn, io, "committed", "x\n");
    try expectRecoveryBlocked(&fixture);
    try txn.deleteFile(io, "committed");
    try fs.write(txn, io, "committed", "1\n");
    try fs.write(txn, io, "rolled-back", "1\n");
    try expectRecoveryBlocked(&fixture);
    try txn.deleteFile(io, "rolled-back");
    try install.requireRecoveryClear(a, io, &fixture.paths, "instance", "Test");
}

test "read-only recovery gate enforces private directories nofollow and journal byte limit" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    const files = fixture.files();
    var report = try install.execute(a, io, fixture.options(plan.value, &files));
    defer report.deinit();
    const txn = try fs.openAbsolute(io, report.backup_directory);
    defer txn.close(io);
    try txn.deleteFile(io, "journal.json");
    const oversized = try a.alloc(u8, 16 * 1024 * 1024 + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try fs.write(txn, io, "journal.json", oversized);
    try expectRecoveryBlocked(&fixture);
    try txn.deleteFile(io, "journal.json");
    if (builtin.os.tag != .windows) {
        try txn.symLink(io, "manifest-after", "journal.json", .{});
        try expectRecoveryBlocked(&fixture);
        try txn.deleteFile(io, "journal.json");
        try txn.setPermissions(io, .fromMode(0o755));
        try expectRecoveryBlocked(&fixture);
        try txn.setPermissions(io, .fromMode(0o700));
    }
}

fn statePlan(fixture: *Fixture, path: []const u8, enabled: bool) !providers.Owned(manifest.UpdatePlan) {
    const bytes = try fixture.read(".vela/instances/instance/content.json");
    defer a.free(bytes);
    var previous = try manifest.parse(a, bytes);
    defer previous.deinit();
    const game_path = try std.fs.path.join(a, &.{ fixture.paths.root, ".minecraft", "versions", "Test" });
    defer a.free(game_path);
    const game = try fs.openAbsolute(io, game_path);
    defer game.close(io);
    const fingerprints = try a.alloc(fs.Fingerprint, previous.value.files.len);
    defer a.free(fingerprints);
    const observed = try a.alloc(manifest.ObservedFile, previous.value.files.len);
    defer a.free(observed);
    var count: usize = 0;
    for (previous.value.files, 0..) |file, index| {
        const physical = try manifest.physicalPath(a, file);
        defer a.free(physical);
        fingerprints[index] = (try fs.fingerprint(game, io, physical, null, null)) orelse continue;
        observed[count] = .{ .path = file.path, .hashes = fingerprints[index].hashes(), .size = fingerprints[index].size };
        count += 1;
    }
    return manifest.buildEnabledPlan(a, previous.value, path, enabled, observed[0..count], .{ .instance_id = "instance", .running = fixture.guard.running });
}
fn expectState(fixture: *Fixture, enabled: bool, payload: []const u8) !void {
    const physical = if (enabled) ".minecraft/versions/Test/mods/replace.jar" else ".minecraft/versions/Test/mods/replace.jar.disabled";
    const absent = if (enabled) ".minecraft/versions/Test/mods/replace.jar.disabled" else ".minecraft/versions/Test/mods/replace.jar";
    const bytes = try fixture.read(physical);
    defer a.free(bytes);
    try std.testing.expectEqualStrings(payload, bytes);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, absent, .{}));
    const receipt = try fixture.read(".vela/instances/instance/content.json");
    defer a.free(receipt);
    var parsed = try manifest.parse(a, receipt);
    defer parsed.deinit();
    try std.testing.expectEqual(enabled, parsed.value.files[0].enabled);
    try std.testing.expectEqualStrings("mods/replace.jar", parsed.value.files[0].path);
    try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
    try std.testing.expect(!fixture.guard.held);
    try std.testing.expectEqual(fixture.guard.acquired, fixture.guard.released);
}

test "managed mod state round trips standalone official pack archive and override without fetch" {
    for ([_]manifest.IdentityProvenance{ .official_file, .pack_archive, .pack_override }) |provenance| {
        for ([_]bool{ true, false }) |standalone| {
            if (standalone and provenance != .official_file) continue;
            errdefer std.debug.print("mod state disk fixture {s}/standalone={}\n", .{ @tagName(provenance), standalone });
            var fixture = try Fixture.init();
            defer fixture.deinit();
            try fixture.seed();
            fixture.old_records[0].identity_provenance = provenance;
            fixture.old_records[0].role = if (provenance == .pack_override) .override else .content;
            if (provenance != .official_file) fixture.old_records[0].project_id = "pack";
            fixture.old_records[0].standalone = standalone;
            fixture.old_records[1].standalone = standalone;
            fixture.old_records[1].identity_provenance = .official_file;
            var receipt = fixture.oldManifest();
            receipt.schema_version = manifest.schema_version;
            if (!standalone) receipt.pack_membership = .{ .identity = .{ .provider = .modrinth, .project_id = "pack", .version_id = "old" }, .paths = &.{ "mods/replace.jar", "mods/remove.jar" } };
            const updated_receipt = try manifest.serialize(a, receipt);
            a.free(fixture.original_manifest.?);
            fixture.original_manifest = updated_receipt;
            try fixture.write(".vela/instances/instance/content.json", fixture.original_manifest.?);
            var disable = try statePlan(&fixture, "mods/replace.jar", false);
            defer disable.deinit();
            const expected = try manifest.serialize(a, disable.value.next_manifest);
            defer a.free(expected);
            var toggle_options = fixture.options(disable.value, &.{});
            toggle_options.allow_manifest_v2 = true;
            var report = try install.execute(a, io, toggle_options);
            defer report.deinit();
            try std.testing.expect(report.committed);
            try expectState(&fixture, false, "old");
            const actual = try fixture.read(".vela/instances/instance/content.json");
            defer a.free(actual);
            try std.testing.expectEqualStrings(expected, actual);
            // Freshly parsed persisted state makes a repeated request idempotent.
            var repeated = try statePlan(&fixture, "mods/replace.jar", false);
            defer repeated.deinit();
            try std.testing.expectEqual(@as(usize, 0), repeated.value.actions.len);
            toggle_options.plan = repeated.value;
            var unchanged = try install.execute(a, io, toggle_options);
            defer unchanged.deinit();
            try expectState(&fixture, false, "old");
            var enable = try statePlan(&fixture, "mods/replace.jar", true);
            defer enable.deinit();
            toggle_options.plan = enable.value;
            var restored = try install.execute(a, io, toggle_options);
            defer restored.deinit();
            try expectState(&fixture, true, "old");
            const final_receipt = try fixture.read(".vela/instances/instance/content.json");
            defer a.free(final_receipt);
            try std.testing.expectEqualStrings(fixture.original_manifest.?, final_receipt);
        }
    }
}

test "mod state fault cancellation crash and durable marker boundaries preserve the pair" {
    for ([_]install.FaultPoint{ .before_backup, .after_backup, .before_journal, .after_journal, .before_mutation, .after_mutation, .before_manifest, .after_manifest, .before_commit_marker, .after_commit_marker }) |point| {
        for ([_]enum { fail, cancel, crash }{ .fail, .cancel, .crash }) |mode| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            try fixture.seed();
            var plan = try statePlan(&fixture, "mods/replace.jar", false);
            defer plan.deinit();
            var inject: Inject = .{ .point = point, .crash = mode == .crash, .cancel = if (mode == .cancel) &fixture.cancel else null };
            var options = fixture.options(plan.value, &.{});
            options.fault = .{ .context = &inject, .boundary = Inject.boundary };
            if (mode == .crash) {
                try std.testing.expectError(error.SimulatedCrash, install.execute(a, io, options));
            } else if (point == .after_commit_marker) {
                var report = try install.execute(a, io, options);
                defer report.deinit();
                try std.testing.expect(report.committed);
            } else {
                const outcome = install.execute(a, io, options);
                if (mode == .cancel) try std.testing.expectError(error.Canceled, outcome) else try std.testing.expectError(error.InjectedFailure, outcome);
            }
            var transactions = try install.listTransactions(a, io, &fixture.paths, "instance", "Test");
            defer transactions.deinit();
            for (transactions.value) |id| {
                var recovered = try install.recover(a, io, fixture.recovery(id));
                defer recovered.deinit();
                var again = try install.recover(a, io, fixture.recovery(id));
                defer again.deinit();
            }
            try expectState(&fixture, point != .after_commit_marker, "old");
            try install.requireRecoveryClear(a, io, &fixture.paths, "instance", "Test");
        }
    }
}

test "mod state destination and ownership conflicts never overwrite local bytes" {
    for ([_]enum { destination, modified_source, both_after_crash, modified_target, hardlink, symlink, case_alias }{ .destination, .modified_source, .both_after_crash, .modified_target, .hardlink, .symlink, .case_alias }) |mode| {
        if (builtin.os.tag == .windows and (mode == .hardlink or mode == .symlink)) continue;
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.seed();
        var plan = try statePlan(&fixture, "mods/replace.jar", false);
        defer plan.deinit();
        const destination = ".minecraft/versions/Test/mods/replace.jar.disabled";
        if (mode == .destination) {
            try fixture.write(destination, "user-owned");
            try std.testing.expectError(error.PathAlreadyExists, install.execute(a, io, fixture.options(plan.value, &.{})));
            const bytes = try fixture.read(destination);
            defer a.free(bytes);
            try std.testing.expectEqualStrings("user-owned", bytes);
        } else if (mode == .modified_source) {
            try fixture.write(".minecraft/versions/Test/mods/replace.jar", "edited");
            try std.testing.expectError(error.SizeMismatch, install.execute(a, io, fixture.options(plan.value, &.{})));
        } else if (mode == .symlink or mode == .hardlink or mode == .case_alias) {
            if (mode == .symlink) try fixture.tmp.dir.symLink(io, "replace.jar", destination, .{}) else if (mode == .hardlink) try fixture.tmp.dir.hardLink(".minecraft/versions/Test/mods/replace.jar", fixture.tmp.dir, destination, io, .{}) else try fixture.write(".minecraft/versions/Test/mods/REPLACE.JAR.DISABLED", "user-owned");
            const outcome = install.execute(a, io, fixture.options(plan.value, &.{}));
            if (outcome) |report_value| {
                var report = report_value;
                report.deinit();
                return error.ExpectedAliasRejection;
            } else |_| {}
        } else {
            var inject: Inject = .{ .point = .after_mutation, .crash = true };
            var options = fixture.options(plan.value, &.{});
            options.fault = .{ .context = &inject, .boundary = Inject.boundary };
            try std.testing.expectError(error.SimulatedCrash, install.execute(a, io, options));
            if (mode == .both_after_crash) try fixture.write(".minecraft/versions/Test/mods/replace.jar", "user-owned") else try fixture.write(destination, "edited-target");
            var transactions = try install.listTransactions(a, io, &fixture.paths, "instance", "Test");
            defer transactions.deinit();
            try std.testing.expectEqual(@as(usize, 1), transactions.value.len);
            try std.testing.expectError(error.RecoveryConflict, install.recover(a, io, fixture.recovery(transactions.value[0])));
            try std.testing.expectError(error.RecoveryRequired, install.requireRecoveryClear(a, io, &fixture.paths, "instance", "Test"));
            const bytes = try fixture.read(if (mode == .both_after_crash) ".minecraft/versions/Test/mods/replace.jar" else destination);
            defer a.free(bytes);
            try std.testing.expectEqualStrings(if (mode == .both_after_crash) "user-owned" else "edited-target", bytes);
        }
        try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
        try std.testing.expect(!fixture.guard.held);
        try std.testing.expectEqual(fixture.guard.acquired, fixture.guard.released);
    }
}

test "disabled mod bytes update and remove at physical disabled path" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var disable = try statePlan(&fixture, "mods/replace.jar", false);
    defer disable.deinit();
    var disabled = try install.execute(a, io, fixture.options(disable.value, &.{}));
    defer disabled.deinit();
    const old_bytes = try fixture.read(".vela/instances/instance/content.json");
    defer a.free(old_bytes);
    var previous = try manifest.parse(a, old_bytes);
    defer previous.deinit();
    var desired_records = fixture.new_records;
    desired_records[0].enabled = false;
    const observed = [_]manifest.ObservedFile{
        .{ .path = "mods/replace.jar", .hashes = fixture.old_hash.hashes(), .size = fixture.old_hash.size },
        .{ .path = "mods/remove.jar", .hashes = fixture.old_hash.hashes(), .size = fixture.old_hash.size },
    };
    const desired: manifest.Manifest = .{ .instance_id = "instance", .pack_version = "new", .files = &desired_records };
    var update = try manifest.buildUpdatePlan(a, previous.value, desired, &observed, &.{}, .{ .instance_id = "instance", .running = false });
    defer update.deinit();
    var files = fixture.files();
    files[0].record.enabled = false;
    var report = try install.execute(a, io, fixture.options(update.value, &files));
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), fixture.fetches);
    const bytes = try fixture.read(".minecraft/versions/Test/mods/replace.jar.disabled");
    defer a.free(bytes);
    try std.testing.expectEqualStrings("new", bytes);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft/versions/Test/mods/replace.jar", .{}));
    const new_bytes = try fixture.read(".vela/instances/instance/content.json");
    defer a.free(new_bytes);
    var current = try manifest.parse(a, new_bytes);
    defer current.deinit();
    const remaining: manifest.Manifest = .{ .instance_id = "instance", .pack_version = "new", .files = current.value.files[1..] };
    const actual = [_]manifest.ObservedFile{
        .{ .path = "mods/replace.jar", .hashes = fixture.new_hash.hashes(), .size = fixture.new_hash.size },
        .{ .path = "mods/new.jar", .hashes = fixture.new_hash.hashes(), .size = fixture.new_hash.size },
    };
    var remove = try manifest.buildUpdatePlan(a, current.value, remaining, &actual, &.{}, .{ .instance_id = "instance", .running = false });
    defer remove.deinit();
    var removed = try install.execute(a, io, fixture.options(remove.value, &.{}));
    defer removed.deinit();
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft/versions/Test/mods/replace.jar.disabled", .{}));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft/versions/Test/mods/replace.jar", .{}));
    const backed_up = try std.fs.path.join(a, &.{ removed.backup_directory, "before-0" });
    defer a.free(backed_up);
    const backup = try std.Io.Dir.cwd().readFileAlloc(io, backed_up, a, .limited(32));
    defer a.free(backup);
    try std.testing.expectEqualStrings("new", backup);
}

const protected_roots = [_][]const u8{ ".vela-instance.json", ".VeLa-InStAnCe.JsOn/child", ".vela-loader.json", ".VELA-LOADER.JSON/child", "Test.json", "tEsT.JsOn/child", "Test.jar", "TEST.JAR/child" };

test "desired action source destination and download paths reject before conflicts or lease" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    const files = fixture.files();
    fixture.guard.running = true;
    for (protected_roots) |path| {
        const bad = record(&fixture.new_hash, path, "new");
        for (0..8) |kind| {
            var options = fixture.options(plan.value, &files);
            options.plan.ready = false;
            options.plan.fully_applied = false;
            switch (kind) {
                0 => options.plan.next_manifest.files = &.{bad},
                1 => options.plan.actions = &.{.{ .kind = .remove, .path = path }},
                2 => options.plan.actions = &.{.{ .kind = .remove, .path = "mods/replace.jar", .previous = bad }},
                3 => options.plan.actions = &.{.{ .kind = .install, .path = "mods/replace.jar", .desired = bad }},
                4 => options.files = &.{.{ .record = bad, .download = .{ .manual_required = .{ .official_page = "https://modrinth.com/mod/project", .reason = .missing_url } } }},
                5 => options.manual_files = &.{.{ .path = path, .source_absolute_path = "/unused" }},
                6 => options.pack = .{ .identity = .{ .provider = .modrinth, .project_id = "project", .version_id = "new" }, .name = "Pack", .version = "new", .minecraft_version = "1.20.1", .files = &.{.{ .record = bad, .download = .{ .manual_required = .{ .official_page = "https://modrinth.com/mod/project", .reason = .missing_url } } }} },
                7 => options.plan.conflicts = &.{.{ .path = path, .reason = .unmanaged }},
                else => unreachable,
            }
            try std.testing.expectError(error.ProtectedPath, install.execute(a, io, options));
        }
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.guard.acquired);
    try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft/versions/Test/.vela-content", .{}));
    try fixture.assertBefore();
}

test "persisted protected removals reject before conflicts lease or transaction creation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    const files = fixture.files();
    fixture.guard.running = true;
    for (protected_roots) |path| {
        const old = record(&fixture.old_hash, path, "old");
        const bytes = try std.json.Stringify.valueAlloc(a, manifest.Manifest{ .schema_version = manifest.schema_version, .instance_id = "instance", .pack_version = "old", .files = &.{old} }, .{});
        defer a.free(bytes);
        try fixture.write(".vela/instances/instance/content.json", bytes);
        var options = fixture.options(plan.value, &files);
        options.plan.ready = false;
        options.plan.actions = &.{.{ .kind = .remove, .path = "mods/remove.jar" }};
        try std.testing.expectError(error.ProtectedPath, install.execute(a, io, options));
        const retained = try fixture.read(".vela/instances/instance/content.json");
        defer a.free(retained);
        try std.testing.expectEqualStrings(bytes, retained);
        try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft/versions/Test/.vela-content", .{}));
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.guard.acquired);
    try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
    try fixture.write(".vela/instances/instance/content.json", fixture.original_manifest.?);
    try fixture.assertBefore();
}

test "recovery source destination and prior receipt protections precede lease and rollback" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    const files = fixture.files();
    var inject: Inject = .{ .point = .after_journal, .index = 0, .crash = true };
    var options = fixture.options(plan.value, &files);
    options.fault = inject.fault();
    try std.testing.expectError(error.SimulatedCrash, install.execute(a, io, options));
    var transactions = try install.listTransactions(a, io, &fixture.paths, "instance", "Test");
    defer transactions.deinit();
    try std.testing.expectEqual(@as(usize, 1), transactions.value.len);
    const txn_path = try std.fs.path.join(a, &.{ fixture.paths.root, ".minecraft", "versions", "Test", ".vela-content", transactions.value[0] });
    defer a.free(txn_path);
    const txn = try fs.openAbsolute(io, txn_path);
    defer txn.close(io);
    const original = try fs.read(a, txn, io, "journal.json", 16 * 1024 * 1024);
    defer a.free(original);
    const acquired = fixture.guard.acquired;
    fixture.guard.running = true;
    for (protected_roots) |path| {
        for ([_][]const u8{ "path", "destination" }) |field| {
            var parsed = try std.json.parseFromSlice(std.json.Value, a, original, .{ .allocate = .alloc_always });
            defer parsed.deinit();
            const entry = &parsed.value.object.getPtr("entries").?.array.items[0];
            entry.object.getPtr(field).?.* = .{ .string = path };
            const bytes = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
            defer a.free(bytes);
            try txn.deleteFile(io, "journal.json");
            try fs.write(txn, io, "journal.json", bytes);
            try std.testing.expectError(error.ProtectedPath, install.recover(a, io, fixture.recovery(transactions.value[0])));
            try std.testing.expectError(error.ProtectedPath, install.requireRecoveryClear(a, io, &fixture.paths, "instance", "Test"));
            try fixture.assertBefore();
        }
    }
    try txn.deleteFile(io, "journal.json");
    try fs.write(txn, io, "journal.json", original);
    for ([_][]const u8{ "manifest-before", "manifest-after" }) |backup_name| {
        const backup = try fs.read(a, txn, io, backup_name, providers.max_json_bytes);
        defer a.free(backup);
        for (protected_roots) |path| {
            const bad = record(&fixture.old_hash, path, "old");
            const bytes = try std.json.Stringify.valueAlloc(a, manifest.Manifest{ .schema_version = manifest.schema_version, .instance_id = "instance", .pack_version = "old", .files = &.{bad} }, .{});
            defer a.free(bytes);
            try txn.deleteFile(io, backup_name);
            try fs.write(txn, io, backup_name, bytes);
            try std.testing.expectError(error.ProtectedPath, install.recover(a, io, fixture.recovery(transactions.value[0])));
            try fixture.assertBefore();
        }
        try txn.deleteFile(io, backup_name);
        try fs.write(txn, io, backup_name, backup);
    }
    try std.testing.expectEqual(acquired, fixture.guard.acquired);
    fixture.guard.running = false;
    var recovered = try install.recover(a, io, fixture.recovery(transactions.value[0]));
    defer recovered.deinit();
    try fixture.assertBefore();
}

test "content install never creates a missing final game namespace" {
    for ([_]?[]const u8{ null, ".minecraft", ".minecraft/versions" }) |parent| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        if (parent) |path| try fixture.tmp.dir.createDirPath(io, path);
        const empty: manifest.UpdatePlan = .{ .actions = &.{}, .conflicts = &.{}, .next_manifest = .{ .instance_id = "instance", .pack_version = "empty" }, .ready = true, .fully_applied = true };
        try std.testing.expectError(error.FileNotFound, install.execute(a, io, fixture.options(empty, &.{})));
        try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft/versions/Test", .{}));
        try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".vela/instances/instance", .{}));
        if (parent == null) try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft", .{}));
        try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
        try std.testing.expect(!fixture.guard.held);
        try std.testing.expectEqual(fixture.guard.acquired, fixture.guard.released);
    }
}

test "ordinary root configuration JSON installs and publishes a valid receipt" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(io, ".minecraft/versions/Test");
    fixture.new_hash = fingerprint("new");
    var config_file = record(&fixture.new_hash, "settings.json", "new");
    config_file.role = .configuration;
    const desired: manifest.Manifest = .{ .instance_id = "instance", .pack_version = "new", .files = &.{config_file} };
    const previous: manifest.Manifest = .{ .instance_id = "instance", .pack_version = "old" };
    var plan = try manifest.buildUpdatePlan(a, previous, desired, &.{}, &.{}, .{ .instance_id = "instance", .instance_name = "Test", .running = false });
    defer plan.deinit();
    const files = [_]manifest.InstallFile{.{ .record = config_file, .download = .{ .remote = "https://cdn.modrinth.com/settings.json" } }};
    var report = try install.execute(a, io, fixture.options(plan.value, &files));
    defer report.deinit();
    try std.testing.expect(report.committed and report.fully_applied);
    const bytes = try fixture.read(".minecraft/versions/Test/settings.json");
    defer a.free(bytes);
    try std.testing.expectEqualStrings("new", bytes);
    const receipt_bytes = try fixture.read(".vela/instances/instance/content.json");
    defer a.free(receipt_bytes);
    var receipt = try manifest.parseForInstance(a, receipt_bytes, "Test");
    defer receipt.deinit();
    try std.testing.expectEqualStrings("settings.json", receipt.value.files[0].path);
    try std.testing.expectEqual(@as(usize, 1), fixture.fetches);
}
test "installer collection bounds reject uninitialized inputs before conflicts lease or mutation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    const files = fixture.files();
    const oversized_files = try a.alloc(manifest.InstallFile, providers.max_items + 1);
    defer a.free(oversized_files);
    const oversized_manual = try a.alloc(install.ManualFile, providers.max_items + 1);
    defer a.free(oversized_manual);
    const oversized_actions = try a.alloc(manifest.Action, providers.max_items * 2 + 1);
    defer a.free(oversized_actions);
    const oversized_conflicts = try a.alloc(manifest.Conflict, providers.max_items * 2 + 1);
    defer a.free(oversized_conflicts);
    const oversized_records = try a.alloc(manifest.ManagedFile, providers.max_items + 1);
    defer a.free(oversized_records);
    const oversized_paths = try a.alloc([]const u8, providers.max_items + 1);
    defer a.free(oversized_paths);
    const identity: manifest.PackIdentity = .{ .provider = .modrinth, .project_id = "project", .version_id = "new" };
    fixture.guard.running = true;
    for (0..7) |kind| {
        var options = fixture.options(plan.value, &files);
        options.plan.ready = false;
        switch (kind) {
            0 => options.files = oversized_files,
            1 => options.manual_files = oversized_manual,
            2 => options.plan.actions = oversized_actions,
            3 => options.plan.conflicts = oversized_conflicts,
            4 => options.pack = .{ .identity = identity, .name = "Pack", .version = "new", .minecraft_version = "1.20.1", .files = oversized_files },
            5 => options.plan.next_manifest.files = oversized_records,
            6 => options.plan.next_manifest.pack_membership = .{ .identity = identity, .paths = oversized_paths },
            else => unreachable,
        }
        try std.testing.expectError(error.TooManyItems, install.execute(a, io, options));
        try fixture.assertBefore();
        try std.testing.expectEqual(@as(usize, 0), fixture.guard.acquired);
        try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
        try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, ".minecraft/versions/Test/.vela-content", .{}));
    }
}

test "terminal history beyond pending capacity stays launchable with bounded scan memory" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed();
    var plan = try fixture.plan();
    defer plan.deinit();
    const files = fixture.files();
    var report = try install.execute(a, io, fixture.options(plan.value, &files));
    defer report.deinit();
    const original = try fs.openAbsolute(io, report.backup_directory);
    defer original.close(io);
    const journal = try fs.read(a, original, io, "journal.json", 16 * 1024 * 1024);
    defer a.free(journal);
    const before = try fs.read(a, original, io, "manifest-before", providers.max_json_bytes);
    defer a.free(before);
    const after = try fs.read(a, original, io, "manifest-after", providers.max_json_bytes);
    defer a.free(after);
    const transactions = try fixture.tmp.dir.openDir(io, ".minecraft/versions/Test/.vela-content", .{ .iterate = true });
    defer transactions.close(io);
    // Include committed and rolled-back receipts, all with validated journal identity.
    for (0..providers.max_items + 1) |index| {
        var buffer: [36]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "txn-{x:0>32}", .{index});
        const txn = try fs.child(transactions, io, id, true, true);
        defer txn.close(io);
        const renamed = try std.mem.replaceOwned(u8, a, journal, report.transaction_id, id);
        defer a.free(renamed);
        try txn.writeFile(io, .{ .sub_path = "journal.json", .data = renamed });
        try txn.writeFile(io, .{ .sub_path = "manifest-before", .data = before });
        try txn.writeFile(io, .{ .sub_path = "manifest-after", .data = after });
        try txn.writeFile(io, .{ .sub_path = if (index % 2 == 0) "committed" else "rolled-back", .data = "1\n" });
    }
    // An arena-backed caller must not retain all parsed history. This tiny caller
    // budget is independent of history size; scanner scratch dies after each entry.
    var buffer: [8192]u8 = undefined;
    var bounded = std.heap.FixedBufferAllocator.init(&buffer);
    try install.requireRecoveryClear(bounded.allocator(), io, &fixture.paths, "instance", "Test");
    var pending = try install.listPendingTransactions(bounded.allocator(), io, &fixture.paths, "instance", "Test");
    defer pending.deinit();
    try std.testing.expectEqual(@as(usize, 0), pending.value.len);
    try std.testing.expect(bounded.end_index < buffer.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.guard.acquired);
    try std.testing.expectEqual(@as(usize, 2), fixture.fetches);
    const first = try fs.child(transactions, io, "txn-00000000000000000000000000000000", false, true);
    defer first.close(io);
    try first.deleteFile(io, "committed");
    try std.testing.expectError(error.RecoveryRequired, install.requireRecoveryClear(a, io, &fixture.paths, "instance", "Test"));
    var one = try install.listPendingTransactions(a, io, &fixture.paths, "instance", "Test");
    defer one.deinit();
    try std.testing.expectEqual(@as(usize, 1), one.value.len);
    try std.testing.expectEqualStrings("txn-00000000000000000000000000000000", one.value[0]);
    try first.writeFile(io, .{ .sub_path = "committed", .data = "x\n" });
    try expectRecoveryBlocked(&fixture);
    // Pending capacity still bounds owned recovery IDs, even amid retained history.
    for (0..providers.max_items + 1) |index| {
        var id_buffer: [36]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "txn-{x:0>32}", .{index});
        const txn = try fs.child(transactions, io, id, false, true);
        defer txn.close(io);
        try txn.deleteFile(io, if (index % 2 == 0) "committed" else "rolled-back");
    }
    try expectRecoveryBlocked(&fixture);
}
