//! Opt-in public Modrinth production-path smoke test. No mod/game installation.
//! Run: VELA_PACK_LIVE_TEST=1 nix develop -c zig build test-pack-install
const std = @import("std");
const providers = @import("core/content_providers.zig");
const http = @import("core/http_transport.zig");
const backend = @import("core/pack_install.zig");
const tasks = @import("core/tasks.zig");
const fixtures = @import("pack_install_fixture.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const archive_limit = 16 * 1024 * 1024;

fn elapsed(start: i96) i96 {
    return @divTrunc(std.Io.Clock.awake.now(io).nanoseconds - start, std.time.ns_per_ms);
}

// Only enums, counters and error names reach stderr: never response bodies/URLs.
fn report(task: *tasks.Task, start: i96, failure: ?anyerror) void {
    const detail = task.details();
    std.debug.print("[pack-live] stage={s} elapsed_ms={d} received={d} total={?d} error={s}\n", .{
        @tagName(detail.stage),                         elapsed(start), detail.received, detail.total_bytes,
        if (failure) |err| @errorName(err) else "none",
    });
}

const Watchdog = struct {
    done: std.atomic.Value(bool) = .init(false),
    task: *tasks.Task,
    start: i96,
    transfer_check: bool = false,
    progressed_after_deadline: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watchdog) void {
        var ticks: usize = 0;
        var received_at_deadline: ?u64 = null;
        while (!self.done.load(.acquire)) : (ticks += 1) {
            if (ticks % 10 == 0) report(self.task, self.start, null);
            if (self.transfer_check and elapsed(self.start) >= 120_000 and received_at_deadline == null) received_at_deadline = self.task.details().received;
            if (elapsed(self.start) >= (if (self.transfer_check) @as(i96, 150_000) else 180_000)) {
                if (received_at_deadline) |before| self.progressed_after_deadline.store(self.task.details().received > before, .release);
                report(self.task, self.start, if (self.transfer_check) error.LiveTransferCheckComplete else error.LiveInspectionTimeout);
                self.task.cancellation.store(true, .release);
                return;
            }
            std.Io.sleep(io, .fromMilliseconds(1000), .awake) catch return;
        }
    }
};

test "opt-in live Modrinth archive download and production inspection" {
    const enabled = std.testing.environ.getAlloc(a, "VELA_PACK_LIVE_TEST") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;

    const version_id = std.testing.environ.getAlloc(a, "VELA_PACK_LIVE_VERSION") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
    defer if (version_id) |id| a.free(id);
    if (version_id) |id| {
        if (id.len == 0 or id.len > 64) return error.InvalidVersionId;
        for (id) |character| if (!std.ascii.isAlphanumeric(character)) return error.InvalidVersionId;
    }
    const metadata_url = if (version_id) |id| try std.fmt.allocPrint(a, "https://api.modrinth.com/v2/version/{s}", .{id}) else try a.dupe(u8, "https://api.modrinth.com/v2/project/fabulously-optimized/version?game_versions=%5B%221.21.1%22%5D");
    defer a.free(metadata_url);
    const selected_limit: u64 = if (version_id != null) 256 * 1024 * 1024 else archive_limit;
    const transfer_mode = std.testing.environ.getAlloc(a, "VELA_PACK_LIVE_TRANSFER_CHECK") catch null;
    defer if (transfer_mode) |mode| a.free(mode);
    const transfer_check = if (transfer_mode) |mode| std.mem.eql(u8, mode, "1") else false;

    const start = std.Io.Clock.awake.now(io).nanoseconds;
    std.debug.print("[pack-live] stage=metadata timeout_ms=120000\n", .{});
    var client = try http.Client.init(a, io, .{});
    defer client.deinit();
    var response = client.execute(.{
        .url = metadata_url,
        .headers = &.{.{ .name = "User-Agent", .value = "Vela/0.1.0 (opt-in pack inspection test)" }},
        .timeout_ms = 120_000,
        .max_response_bytes = 4 * 1024 * 1024,
        .require_public_address = true,
    }) catch |err| {
        std.debug.print("[pack-live] stage=metadata elapsed_ms={d} error={s}\n", .{ elapsed(start), @errorName(err) });
        return err;
    };
    defer response.deinit();
    std.debug.print("[pack-live] stage=metadata elapsed_ms={d} status={d} bytes={d}\n", .{ elapsed(start), response.status, response.body.len });
    try std.testing.expectEqual(@as(u16, 200), response.status);
    var versions = try providers.parseModrinthVersions(a, response.body, version_id != null, null);
    defer versions.deinit();
    var chosen: ?providers.Version = null;
    var smallest: u64 = selected_limit + 1;
    for (versions.value.versions) |version| {
        // Preserve the production primary-file selection and metadata unchanged.
        if (version.provider != .modrinth or version.files.len != 1) continue;
        const file = version.files[0];
        const size = file.size orelse continue;
        if (size == 0 or size > selected_limit or size >= smallest) continue;
        if (!std.mem.endsWith(u8, file.filename, ".mrpack") or file.download != .remote) continue;
        if (!providers.approvedDownloadUrl(file.download.remote, &.{"cdn.modrinth.com"})) continue;
        chosen = version;
        smallest = size;
    }
    const version = chosen orelse return error.NoSmallPublicMrpack;
    std.debug.print("[pack-live] stage=inspect archive_bytes={d} elapsed_ms={d}\n", .{ smallest, elapsed(start) });
    var fixture = try fixtures.Fixture.init();
    defer fixture.deinit();
    var task: tasks.Task = .{ .id = 1, .title = "Live archive inspection", .kind = .modpack_install };
    var watchdog: Watchdog = .{ .task = &task, .start = std.Io.Clock.awake.now(io).nanoseconds, .transfer_check = transfer_check };
    const monitor = try std.Thread.spawn(.{}, Watchdog.run, .{&watchdog});
    defer {
        watchdog.done.store(true, .release);
        monitor.join();
    }
    var inspection = backend.inspect(a, io, &fixture.paths, .{ .online = version }, .{
        .telemetry = &task,
        .download_connections = 1,
    }, &task.cancellation) catch |err| {
        report(&task, start, err);
        if (transfer_check and err == error.Canceled and watchdog.progressed_after_deadline.load(.acquire)) {
            try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, fixture.paths.minecraft, .{}));
            std.debug.print("[pack-live] transfer continued past 120s and canceled cleanly at 150s; full archive inspection NOT completed\n", .{});
            return;
        }
        return err;
    };
    defer inspection.deinit();
    defer inspection.cleanup(io) catch {};
    report(&task, start, null);
    try std.testing.expectEqual(.modrinth, inspection.provider);
    try std.testing.expectEqualStrings(version.id, inspection.pack.identity.version_id);
    try std.testing.expect(inspection.pack.files.len > 0);
    try std.testing.expectEqual(@as(usize, 0), inspection.pack.unresolved.len);
    // Inspection must leave the game and instance tree completely untouched.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, fixture.paths.minecraft, .{}));
    std.debug.print("[pack-live] stage=complete elapsed_ms={d} planned_files={d}; no mods/game installed\n", .{ elapsed(start), inspection.pack.files.len });
}
