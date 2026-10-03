//! Live Linux acceptance. ONLY the separate filtered wrapper may select this test.
//! The runner supplies a private stdin capability after verifying its owned bus.
//! No production HTTP transport is reachable in this test build.
const std = @import("std");
const builtin = @import("builtin");
const credentials = @import("core/credentials.zig");
const config = @import("core/config.zig");
const cf = @import("core/curseforge_credentials_manager.zig");
const cleanup = @import("core/auth_cleanup.zig");
const auth = @import("core/auth.zig");
const accounts = @import("ui/accounts_manager.zig");
const c = @cImport({
    // Translate libc declarations directly; glibc's fortified inline open wrappers fail C translation.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
});
const A = std.mem.Allocator;
var wipe_regions: usize = 0; // This driver observes buffers on its coordinator thread only.
var isolation_rejected = std.atomic.Value(bool).init(false);
const FailureStage = enum { native_init, crud, cf_rollback, cf_commit, cf_ambiguous, cf_valid_invalid, auth_seed, auth_cleanup, vault_cleanup, report };
const FailureClass = enum { backend_unavailable, denied, not_found, invalid_reference, invalid_secret, too_large, storage_failure, out_of_memory, isolation_failed, assertion_failed, io_failure, unknown };
const PreGateStage = enum {
    opt_in,
    input,
    json,
    platform,
    uid,
    bus_env,
    address,
    root_path,
    runtime_path,
    socket_stat,
    bus_stat,
    bus_start,
    bus_uids,
    bus_exe,
    owner_stat,
    owner_start,
    owner_uids,
    owner_exe,
    grant_shape,
    nonce_path,
    nonce_read,
    capability_path,
    capability_read,
    references,
    environment,
    system_bus,
    case_paths,
};
const DiagnosticKind = enum { pregate_failure, native_failure, report_write_failure };
const DiagnosticStage = union(enum) { pregate: PreGateStage, native: FailureStage };
fn progressAt(progress: ?*PreGateStage, stage: PreGateStage) void {
    if (progress) |p| p.* = stage;
}
const Diagnostic = struct {
    fd: c_int = -1,
    emitted: bool = false,

    fn init() !Diagnostic {
        const raw = c.getenv("VELA_NATIVE_VAULT_DIAGNOSTIC");
        if (raw == null) return .{};
        var n: usize = 0;
        while (n < 32 and raw[n] != 0) : (n += 1) {}
        if (n == 0) return .{};
        const text = raw[0..n];
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return .{};
        for (text[0..colon]) |ch| if (ch < '0' or ch > '9') return .{};
        const fd = std.fmt.parseInt(c_int, text[0..colon], 10) catch return .{};
        if (fd <= 2) return .{};
        // Hygiene only: an identifiable candidate is not an accepted diagnostic.
        // Never close/write/adopt it until the unchanged ownership proof succeeds.
        const flags = c.fcntl(fd, c.F_GETFD);
        if (flags < 0 or c.fcntl(fd, c.F_SETFD, @as(c_int, flags | c.FD_CLOEXEC)) != 0)
            return error.DiagnosticDescriptorFlagsFailed;
        if (n >= 32) return .{};
        for (text[colon + 1 ..]) |ch| if (ch < '0' or ch > '9') return .{};
        const inode = std.fmt.parseInt(u64, text[colon + 1 ..], 10) catch return .{};
        if (inode == 0) return .{};
        var info: c.struct_stat = undefined;
        if (c.fstat(fd, &info) != 0 or info.st_mode & 0o170000 != 0o010000 or
            info.st_uid != c.geteuid() or info.st_ino != inode) return .{};
        const mode = c.fcntl(fd, c.F_GETFL);
        if (mode < 0 or mode & c.O_ACCMODE != c.O_WRONLY or mode & c.O_NONBLOCK == 0) {
            _ = c.close(fd);
            return .{};
        }
        return .{ .fd = fd };
    }

    fn deinit(self: *Diagnostic) void {
        if (self.fd > 2) _ = c.close(self.fd);
        self.fd = -1;
    }

    fn emit(self: *Diagnostic, kind: DiagnosticKind, stage: DiagnosticStage, class: FailureClass, secondary: ?FailureClass) void {
        if (self.fd <= 2 or self.emitted) return;
        self.emitted = true;
        const stage_name = switch (stage) {
            .pregate => |value| @tagName(value),
            .native => |value| @tagName(value),
        };
        const quote: []const u8 = if (secondary != null) "\"" else "";
        const secondary_name = if (secondary) |value| @tagName(value) else "null";
        var buffer: [512]u8 = undefined;
        const bytes = std.fmt.bufPrint(&buffer, "{{\"version\":1,\"kind\":\"{s}\",\"stage\":\"{s}\",\"class\":\"{s}\",\"secondary\":{s}{s}{s}}}", .{ @tagName(kind), stage_name, @tagName(class), quote, secondary_name, quote }) catch return;
        // One nonblocking <= PIPE_BUF write; short/failed writes are never retried.
        _ = c.write(self.fd, bytes.ptr, bytes.len);
    }
};
fn failureClass(err: anyerror) FailureClass {
    if (isolation_rejected.load(.acquire)) return .isolation_failed;
    return switch (err) {
        error.Unavailable => .backend_unavailable,
        error.Denied => .denied,
        error.NotFound => .not_found,
        error.InvalidReference => .invalid_reference,
        error.InvalidSecret => .invalid_secret,
        error.TooLarge => .too_large,
        error.StorageFailure => .storage_failure,
        error.OutOfMemory => .out_of_memory,
        error.OwnedAcceptanceInvariant => .assertion_failed,
        error.AccessDenied, error.FileNotFound, error.NotDir, error.IsDir, error.InputOutput, error.NoSpaceLeft, error.ReadOnlyFileSystem, error.SystemResources => .io_failure,
        else => .unknown,
    };
}
const io = std.testing.io;
const a = std.testing.allocator;
const Grant = struct {
    nonce: []const u8,
    root: []const u8,
    prefix: []const u8,
    phase: enum { seed, recover, cleanup },
    refs: []const []const u8,
    address: []const u8,
    bus_id: []const u8,
    socket: []const u8,
    socket_inode: u64,
    bus_pid: i32,
    bus_start: u64,
    bus_exe: []const u8,
    owner: []const u8,
    owner_pid: i32,
    owner_start: u64,
    owner_exe: []const u8,
    uid: u32,
};
fn require(ok: bool) !void {
    if (!ok) return error.OwnedAcceptanceInvariant;
}
fn env(name: [*:0]const u8) ![]const u8 {
    return std.mem.span(c.getenv(name) orelse return error.OwnedAcceptanceOptInRequired);
}
fn path(parts: []const []const u8) ![]u8 {
    return std.fs.path.join(a, parts);
}
fn fileBytes(name: []const u8, max: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, name, a, .limited(max));
}
fn procFileBytes(name: []const u8, max: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, name, .{ .allow_directory = true });
    defer file.close(io);
    // procfs regular files report size zero; read until kernel EOF, not stat size.
    var reader = file.readerStreaming(io, &.{});
    return reader.interface.allocRemaining(a, .limited(max)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}
fn statNoLink(name: []const u8) !c.struct_stat {
    const z = try a.dupeZ(u8, name);
    defer a.free(z);
    var s: c.struct_stat = undefined;
    if (c.lstat(z.ptr, &s) != 0) return error.OwnedPathUnavailable;
    try require(s.st_mode & 0o170000 != 0o120000);
    return s;
}
fn privatePath(name: []const u8, uid: u32, directory: bool) !void {
    try require(std.fs.path.isAbsolute(name) and name.len < 4096);
    var parts = std.mem.tokenizeScalar(u8, name, '/');
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(a);
    while (parts.next()) |part| {
        try require(!std.mem.eql(u8, part, ".") and !std.mem.eql(u8, part, ".."));
        try current.append(a, '/');
        try current.appendSlice(a, part);
        _ = try statNoLink(current.items);
    }
    const s = try statNoLink(name);
    try require(s.st_uid == uid and s.st_mode & 0o777 == (if (directory) @as(u32, 0o700) else 0o600));
    try require(s.st_mode & 0o170000 == (if (directory) @as(u32, 0o040000) else 0o100000));
}
fn process(pid: i32, start: u64, exe: []const u8, uid: u32, progress: ?*PreGateStage, owner: bool) !void {
    progressAt(progress, if (owner) .owner_stat else .bus_stat);
    try require(pid > 1);
    const base = try std.fmt.allocPrint(a, "/proc/{d}", .{pid});
    defer a.free(base);
    const stat_path = try path(&.{ base, "stat" });
    defer a.free(stat_path);
    const bytes = try procFileBytes(stat_path, 4096);
    defer a.free(bytes);
    progressAt(progress, if (owner) .owner_start else .bus_start);
    const close = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return error.OwnedProcessChanged;
    var fields = std.mem.tokenizeScalar(u8, bytes[close + 1 ..], ' ');
    var index: usize = 0;
    var found = false;
    while (fields.next()) |field| : (index += 1) {
        if (index == 0) try require(!std.mem.eql(u8, field, "Z"));
        if (index == 19) {
            try require(try std.fmt.parseInt(u64, field, 10) == start);
            found = true;
            break;
        }
    }
    try require(found);
    progressAt(progress, if (owner) .owner_uids else .bus_uids);
    const status_path = try path(&.{ base, "status" });
    defer a.free(status_path);
    const status = try procFileBytes(status_path, 8192);
    defer a.free(status);
    var lines = std.mem.splitScalar(u8, status, '\n');
    var matched = false;
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "Uid:")) {
        var ids = std.mem.tokenizeAny(u8, line[4..], " \t");
        var count: usize = 0;
        while (ids.next()) |id| {
            try require(try std.fmt.parseInt(u32, id, 10) == uid);
            count += 1;
        }
        try require(count == 4);
        matched = true;
    };
    try require(matched);
    progressAt(progress, if (owner) .owner_exe else .bus_exe);
    const exe_path = try path(&.{ base, "exe" });
    defer a.free(exe_path);
    const actual = try std.Io.Dir.cwd().realPathFileAlloc(io, exe_path, a);
    defer a.free(actual);
    try require(std.mem.eql(u8, actual, exe));
}
fn live(g: *const Grant) !void {
    return liveAt(g, null);
}
fn liveAt(g: *const Grant, progress: ?*PreGateStage) !void {
    progressAt(progress, .uid);
    try require(c.getuid() == g.uid and c.geteuid() == g.uid);
    progressAt(progress, .opt_in);
    try require(std.mem.eql(u8, try env("VELA_NATIVE_VAULT_ACCEPTANCE"), "owned-only"));
    progressAt(progress, .bus_env);
    try require(std.mem.eql(u8, try env("DBUS_SESSION_BUS_ADDRESS"), g.address));
    progressAt(progress, .address);
    const runtime = try path(&.{ g.root, "runtime" });
    defer a.free(runtime);
    const socket = try path(&.{ runtime, "bus" });
    defer a.free(socket);
    const expected_address = try std.fmt.allocPrint(a, "unix:path={s}", .{socket});
    defer a.free(expected_address);
    // dbus adds a GUID to the advertised address; accept only that suffix.
    try require(std.mem.eql(u8, g.socket, socket) and std.mem.startsWith(u8, g.address, expected_address));
    const suffix = g.address[expected_address.len..];
    try require(suffix.len == 0 or (std.mem.startsWith(u8, suffix, ",guid=") and suffix.len == 38));
    try require(g.bus_id.len == 32 and g.owner.len > 1 and g.owner[0] == ':');
    progressAt(progress, .root_path);
    try privatePath(g.root, g.uid, true);
    progressAt(progress, .runtime_path);
    try privatePath(runtime, g.uid, true);
    progressAt(progress, .socket_stat);
    const s = try statNoLink(socket);
    try require(s.st_mode & 0o170000 == 0o140000 and s.st_uid == g.uid and s.st_ino == g.socket_inode);
    try process(g.bus_pid, g.bus_start, g.bus_exe, g.uid, progress, false);
    try process(g.owner_pid, g.owner_start, g.owner_exe, g.uid, progress, true);
}
fn gate(g: *const Grant, input: []const u8, progress: *PreGateStage) !void {
    progress.* = .platform;
    if (builtin.os.tag != .linux or !builtin.link_libc) return error.LinuxNativeAcceptanceRequired;
    try liveAt(g, progress);
    progress.* = .grant_shape;
    try require(credentials.validateReference(g.nonce) and g.prefix.len == 8 and g.refs.len == 11);
    progress.* = .nonce_path;
    const marker = try path(&.{ g.root, "nonce" });
    defer a.free(marker);
    try privatePath(marker, g.uid, false);
    progress.* = .nonce_read;
    const nonce = try fileBytes(marker, 64);
    defer a.free(nonce);
    try require(std.mem.eql(u8, nonce, g.nonce));
    progress.* = .capability_path;
    const capability = try path(&.{ g.root, "capability.json" });
    defer a.free(capability);
    try privatePath(capability, g.uid, false);
    progress.* = .capability_read;
    const expected = try fileBytes(capability, 16384);
    defer a.free(expected);
    try require(std.mem.eql(u8, expected, input));
    progress.* = .references;
    for (g.refs, 0..) |ref, i| {
        try require(credentials.validateReference(ref) and std.mem.startsWith(u8, ref, g.prefix));
        for (g.refs[0..i]) |previous| try require(!std.mem.eql(u8, ref, previous));
    }
    progress.* = .environment;
    for ([_][2][]const u8{
        .{ "HOME", "home" },            .{ "XDG_DATA_HOME", "data" },      .{ "XDG_CONFIG_HOME", "config" },
        .{ "XDG_CACHE_HOME", "cache" }, .{ "XDG_RUNTIME_DIR", "runtime" },
    }) |entry| {
        const value = try path(&.{ g.root, entry[1] });
        defer a.free(value);
        const name = try a.dupeZ(u8, entry[0]);
        defer a.free(name);
        try require(std.mem.eql(u8, try env(name), value));
        try privatePath(value, g.uid, true);
    }
    progress.* = .system_bus;
    const system = try path(&.{ g.root, "runtime", "no-system-bus" });
    defer a.free(system);
    const system_address = try std.fmt.allocPrint(a, "unix:path={s}", .{system});
    defer a.free(system_address);
    try require(std.mem.eql(u8, try env("DBUS_SYSTEM_BUS_ADDRESS"), system_address));
    progress.* = .case_paths;
    for ([_][]const u8{ "rollback", "commit", "ambiguous", "valid", "auth" }) |case| {
        const root = try path(&.{ g.root, "launcher", case });
        defer a.free(root);
        try privatePath(root, g.uid, true);
    }
}
const Guard = struct {
    grant: *const Grant,
    native: credentials.Store,
    puts: usize = 0,
    gets: usize = 0,
    deletes: usize = 0,
    fail_after_put: bool = false,
    fn store(self: *Guard) credentials.Store {
        return .{ .ctx = self, .vtable = &.{ .put = put, .get = get, .delete = delete } };
    }
    fn check(self: *Guard, ref: []const u8) credentials.Error!void {
        live(self.grant) catch {
            isolation_rejected.store(true, .release);
            return error.Unavailable;
        };
        if (!credentials.validateReference(ref) or !std.mem.startsWith(u8, ref, self.grant.prefix)) return error.InvalidReference;
        for (self.grant.refs) |allowed| if (std.mem.eql(u8, ref, allowed)) return;
        return error.InvalidReference;
    }
    fn put(ctx: *anyopaque, ref: []const u8, secret_bytes: []const u8) credentials.Error!void {
        const self: *Guard = @ptrCast(@alignCast(ctx));
        try self.check(ref);
        self.puts += 1;
        try self.native.put(ref, secret_bytes);
        if (self.fail_after_put) return error.StorageFailure; // Real commit, explicitly synthetic failure.
    }
    fn get(ctx: *anyopaque, allocator: A, ref: []const u8) credentials.Error!credentials.Secret {
        const self: *Guard = @ptrCast(@alignCast(ctx));
        try self.check(ref);
        self.gets += 1;
        return self.native.get(allocator, ref);
    }
    fn delete(ctx: *anyopaque, ref: []const u8) credentials.Error!void {
        const self: *Guard = @ptrCast(@alignCast(ctx));
        try self.check(ref);
        self.deletes += 1;
        return self.native.delete(ref);
    }
};
const Observer = struct {
    pointers: [32]?[*]u8 = @splat(null),
    lengths: [32]usize = @splat(0),
    observed: usize = 0,
    freed: usize = 0,
    violation: bool = false,
    fn allocator(self: *Observer) A {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = A.noResize, .remap = A.noRemap, .free = free } };
    }
    fn watch(self: *Observer, bytes: []u8) void {
        if (bytes.len == 0) return;
        for (&self.pointers, 0..) |*p, i| if (p.* == null) {
            p.* = bytes.ptr;
            self.lengths[i] = bytes.len;
            self.observed += 1;
            return;
        };
        self.violation = true;
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const p = std.heap.page_allocator.rawAlloc(n, alignment, ra) orelse return null;
        const self: *Observer = @ptrCast(@alignCast(ctx));
        if (n == 2 * 1024 * 1024) self.watch(p[0..n]);
        return p;
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Observer = @ptrCast(@alignCast(ctx));
        for (&self.pointers, 0..) |*p, i| if (p.* != null and p.*.? == bytes.ptr) {
            self.violation = self.violation or bytes.len != self.lengths[i] or !std.mem.allEqual(u8, bytes, 0);
            self.freed += 1;
            p.* = null;
        };
        std.heap.page_allocator.rawFree(bytes, alignment, ra);
    }
    fn verify(self: *Observer) !void {
        try require(!self.violation and self.observed > 0 and self.freed == self.observed);
        wipe_regions += self.freed;
    }
};
fn reference(g: *const Grant, index: usize) credentials.Reference {
    var r: credentials.Reference = undefined;
    @memcpy(&r, g.refs[index]);
    return r;
}
fn secret(allocator: A, value: []const u8) !credentials.Secret {
    return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, value) };
}
fn equal(store: credentials.Store, ref: []const u8, value: []const u8) !void {
    var observer: Observer = .{};
    var found = try store.get(observer.allocator(), ref);
    observer.watch(found.bytes);
    const ok = std.mem.eql(u8, found.bytes, value);
    found.deinit();
    try observer.verify();
    try require(ok); // Never expectEqualStrings: failure must not print secret bytes.
}
fn absent(store: credentials.Store, ref: []const u8) !void {
    if (store.get(a, ref)) |value| {
        var found = value;
        found.deinit();
        return error.ExpectedNativeAbsence;
    } else |err| if (err != error.NotFound) return err;
}
fn cfRoot(g: *const Grant, name: []const u8) ![]u8 {
    return path(&.{ g.root, "launcher", name });
}
fn seedCF(g: *const Grant, guard: *Guard, name: []const u8, old: usize, new: usize, publish: bool, injected: bool) !void {
    const root = try cfRoot(g, name);
    defer a.free(root);
    try guard.store().put(g.refs[old], "owned-cf-old-fixture");
    var cfg = try config.Store.init(a, io, root);
    defer cfg.deinit();
    try cfg.update(.{ .settings = .{ .curseforge_credential_ref = g.refs[old] } });
    var manager = try cf.Manager.init(a, io, root, guard.store());
    defer manager.deinit();
    const prior = try cf.prepareConfig(&manager, &cfg);
    var input = try secret(a, "owned-cf-new-fixture");
    defer input.deinit();
    guard.fail_after_put = injected;
    defer guard.fail_after_put = false;
    if (injected) {
        if (manager.prepareSet(prior, reference(g, new), &input, .{})) |_| return error.ExpectedInjectedFailure else |err| try require(err == error.StorageFailure);
    } else {
        const receipt = try manager.prepareSet(prior, reference(g, new), &input, .{});
        if (publish) _ = try cf.publish(&manager, &cfg, receipt, .{ .enabled = true, .terms_approved = true });
        // Deliberately stop before publication or acknowledgement. Actual journal remains.
    }
    try require(input.bytes.len == 0 and manager.pending() != null);
}
fn recoverCF(g: *const Grant, guard: *Guard, name: []const u8, old: usize, new: usize, published: bool) !void {
    const root = try cfRoot(g, name);
    defer a.free(root);
    var cfg = try config.Store.init(a, io, root);
    defer cfg.deinit();
    var manager = try cf.Manager.init(a, io, root, guard.store());
    defer manager.deinit();
    try require(manager.needsRecovery());
    const proof = try cf.reconcileConfig(&cfg);
    const active = if (published) new else old;
    try require(proof.active != null and std.mem.eql(u8, &proof.active.?, g.refs[active]));
    try manager.recover(proof, .{});
    try equal(guard.store(), g.refs[active], if (published) "owned-cf-new-fixture" else "owned-cf-old-fixture");
    try absent(guard.store(), g.refs[if (published) old else new]);
    try require(!manager.needsRecovery() and manager.pending() == null and manager.journal.snapshot().cleanup.len == 0);
}
fn validAndInvalidCF(g: *const Grant, guard: *Guard) !void {
    const root = try cfRoot(g, "valid");
    defer a.free(root);
    var cfg = try config.Store.init(a, io, root);
    defer cfg.deinit();
    var manager = try cf.Manager.init(a, io, root, guard.store());
    defer manager.deinit();
    var good = try secret(a, "owned-cf-valid-fixture");
    defer good.deinit();
    const receipt = try manager.prepareSet(try cf.prepareConfig(&manager, &cfg), reference(g, 9), &good, .{});
    const publication = try cf.publish(&manager, &cfg, receipt, .{ .enabled = true, .terms_approved = true });
    try manager.acknowledge(publication, .{});
    const too_long = [_]u8{'k'} ** 513;
    for ([_][]const u8{ "", "has space", "bad\nkey", &too_long }) |bad| {
        const prior = try cf.prepareConfig(&manager, &cfg);
        var observer: Observer = .{};
        var input = try secret(observer.allocator(), bad);
        observer.watch(input.bytes);
        defer input.deinit();
        const counts = .{ guard.puts, guard.gets, guard.deletes };
        if (manager.prepareSet(prior, reference(g, 10), &input, .{})) |_| return error.ExpectedInvalidCFKey else |err| try require(err == error.InvalidKey);
        try require(std.meta.eql(counts, .{ guard.puts, guard.gets, guard.deletes }));
        try require(input.bytes.len == 0 and manager.pending() == null and manager.journal.snapshot().cleanup.len == 0);
        try require(std.mem.eql(u8, cfg.snapshot().settings.curseforge_credential_ref.?, g.refs[9]));
        if (bad.len != 0) try observer.verify();
        try equal(guard.store(), g.refs[9], "owned-cf-valid-fixture");
        try absent(guard.store(), g.refs[10]);
    }
    const removal = try manager.prepareRemove(try cf.prepareConfig(&manager, &cfg), .{});
    const removed = try cf.publish(&manager, &cfg, removal, .{ .enabled = false, .terms_approved = false });
    try manager.acknowledge(removed, .{});
    try absent(guard.store(), g.refs[9]);
    try require(cfg.snapshot().settings.curseforge_credential_ref == null);
}
// Fixture tokens only; no request is sent to any service.
const Fixture = struct {
    grant: *const Grant,
    index: usize = 0,
    fn transport(self: *Fixture) auth.Transport {
        return .{ .ctx = self, .kind = .fixture, .supports_post = true, .request = request };
    }
    fn entropy(self: *Fixture) auth.Entropy {
        return .{ .ctx = self, .fill = fill };
    }
    fn fill(ctx: *anyopaque, bytes: []u8) error{EntropyUnavailable}!void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (bytes.len != 16) return error.EntropyUnavailable;
        for (bytes, 0..) |*byte, i| byte.* = std.fmt.parseInt(u8, self.grant.refs[7][i * 2 ..][0..2], 16) catch return error.EntropyUnavailable;
    }
    fn request(ctx: *anyopaque, allocator: A, req: auth.Request) auth.TransportError!auth.Response {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        const routes = [_][]const u8{ "/devicecode", "/token", "/user/authenticate", "/xsts/authorize", "/authentication/login_with_xbox", "/entitlements/mcstore", "/minecraft/profile" };
        const bodies = [_][]const u8{
            "{\"device_code\":\"owned-device-fixture\",\"user_code\":\"DUMMY-CODE\",\"verification_uri\":\"https://microsoft.com/devicelogin\",\"expires_in\":900,\"interval\":1}",
            "{\"access_token\":\"owned-oauth-fixture\",\"refresh_token\":\"owned-refresh-fixture\",\"expires_in\":3600}",
            "{\"Token\":\"owned-xbl-fixture\",\"DisplayClaims\":{\"xui\":[{\"uhs\":\"12345\"}]}}",
            "{\"Token\":\"owned-xsts-fixture\",\"DisplayClaims\":{\"xui\":[{\"uhs\":\"12345\"}]}}",
            "{\"access_token\":\"owned-minecraft-fixture\",\"expires_in\":3600}",
            "{\"items\":[{\"name\":\"game_minecraft\"}]}",
            "{\"id\":\"0123456789abcdef0123456789abcdef\",\"name\":\"OwnedFixture\"}",
        };
        if (self.index >= routes.len or !std.mem.endsWith(u8, req.url, routes[self.index])) return error.TransportFailure;
        const body = bodies[self.index];
        self.index += 1;
        return .{ .status = 200, .body = try allocator.dupe(u8, body) };
    }
};
fn seedAuth(g: *const Grant, guard: *Guard) !void {
    const root = try cfRoot(g, "auth");
    defer a.free(root);
    var fixture: Fixture = .{ .grant = g };
    var observer: Observer = .{};
    var client = try auth.Client.init(observer.allocator(), .{ .enabled = true, .client_id = "owned-fixture", .persist_refresh = true }, fixture.transport(), guard.store(), fixture.entropy());
    defer client.deinit();
    _ = try client.beginDevice(0, null);
    observer.watch(client.device.?.code.bytes);
    observer.watch(client.device.?.user_code);
    try require(try client.poll(1000, null) == .complete);
    observer.watch(client.minecraft_token.?.bytes);
    observer.watch(client.refresh_token.?.bytes);
    try require(fixture.index == 7 and std.mem.eql(u8, &client.account.?.credential_ref.?, g.refs[7]));
    var cfg = try config.Store.init(a, io, root);
    defer cfg.deinit();
    try cfg.update(.{ .settings = .{ .microsoft_client_id = "owned-fixture" }, .accounts = &.{.{
        .id = "owned-fixture",
        .name = "OwnedFixture",
        .uuid = "0123456789abcdef0123456789abcdef",
        .kind = .microsoft,
        .credential_ref = g.refs[7],
    }}, .selected_account = "owned-fixture" });
    var journal = try cleanup.Journal.init(a, io, root);
    defer journal.deinit();
    try journal.stage(reference(g, 7));
    try journal.stage(reference(g, 8));
    try guard.store().put(g.refs[8], "owned-orphan-fixture");
    client.reset();
    try observer.verify();
}
const Hooks = struct {
    journal: *cleanup.Journal,
    fn hooks(self: *Hooks) accounts.JournalHooks {
        return .{ .ctx = self, .stage = stage, .remove = remove, .references = refs };
    }
    fn stage(ctx: *anyopaque, ref: credentials.Reference) anyerror!void {
        const self: *Hooks = @ptrCast(@alignCast(ctx));
        try self.journal.stage(ref);
    }
    fn remove(ctx: *anyopaque, ref: credentials.Reference) anyerror!void {
        const self: *Hooks = @ptrCast(@alignCast(ctx));
        try self.journal.remove(ref);
    }
    fn refs(ctx: *anyopaque) []const credentials.Reference {
        const self: *Hooks = @ptrCast(@alignCast(ctx));
        return self.journal.references();
    }
};
fn recoverAuth(g: *const Grant, guard: *Guard) !void {
    const root = try cfRoot(g, "auth");
    defer a.free(root);
    var cfg = try config.Store.init(a, io, root);
    defer cfg.deinit();
    try cfg.reconcile();
    try require(cfg.snapshot().accounts.len == 1 and std.mem.eql(u8, cfg.snapshot().accounts[0].credential_ref.?, g.refs[7]));
    var journal = try cleanup.Journal.init(a, io, root);
    defer journal.deinit();
    try require(journal.references().len == 2);
    var hooks: Hooks = .{ .journal = &journal };
    var fixture: Fixture = .{ .grant = g };
    var manager = try accounts.Manager.initWithOptions(a, io, .{ .root = root, .fixture = .{
        .transport = fixture.transport(),
        .store = guard.store(),
        .entropy = fixture.entropy(),
        .journal = hooks.hooks(),
    } });
    defer manager.deinit();
    try manager.retryCleanup(&cfg);
    var ticks: usize = 0;
    while (manager.snapshot().busy) : (ticks += 1) {
        if (ticks > 3000) return error.ControllerCleanupDeadline;
        manager.tick(&cfg);
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    try require(manager.snapshot().failure == null and fixture.index == 0);
    try equal(guard.store(), g.refs[7], "owned-refresh-fixture");
    try absent(guard.store(), g.refs[8]);
}
// Called ONLY by the post-gate errdefer. Never includes error text or secret data.
fn reportFailure(g: *const Grant, stage: FailureStage, err: anyerror) !void {
    const name = try std.fmt.allocPrint(a, "failure-{s}.json", .{@tagName(g.phase)});
    defer a.free(name);
    const full = try path(&.{ g.root, name });
    defer a.free(full);
    const z = try a.dupeZ(u8, full);
    defer a.free(z);
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .version = @as(u8, 1), .phase = @tagName(g.phase), .stage = @tagName(stage), .class = @tagName(failureClass(err)), .passed = false }, .{});
    defer a.free(bytes);
    if (bytes.len >= 1024) return error.SafeFailureReportWriteFailed;
    const fd = c.open(z.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW, @as(c.mode_t, 0o600));
    if (fd < 0) return error.SafeFailureReportWriteFailed;
    defer _ = c.close(fd);
    if (c.fchmod(fd, 0o600) != 0) return error.SafeFailureReportWriteFailed;
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (n <= 0) return error.SafeFailureReportWriteFailed;
        written += @intCast(n);
    }
    if (c.fsync(fd) != 0) return error.SafeFailureReportWriteFailed;
}
fn report(g: *const Grant, guard: *Guard) !void {
    const name = try std.fmt.allocPrint(a, "report-{s}.json", .{@tagName(g.phase)});
    defer a.free(name);
    const full = try path(&.{ g.root, name });
    defer a.free(full);
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .phase = @tagName(g.phase), .passed = true, .native_puts = guard.puts, .native_gets = guard.gets, .native_deletes = guard.deletes, .zero_before_free_regions = wipe_regions, .limits = "No power-loss, UI/worker-wide wipe, C-library/daemon wipe, or live auth network proof; no auth refresh/signout case" }, .{});
    defer a.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = bytes });
}
fn runOwnedAcceptance() anyerror!void {
    var diagnostic = try Diagnostic.init();
    defer diagnostic.deinit();
    var progress: PreGateStage = .opt_in;
    var gate_complete = false;
    errdefer |err| {
        if (!gate_complete) diagnostic.emit(.pregate_failure, .{ .pregate = progress }, failureClass(err), null);
    }
    try require(std.mem.eql(u8, try env("VELA_NATIVE_VAULT_ACCEPTANCE"), "owned-only"));
    progress = .input;
    var input: [16384]u8 = undefined;
    var used: usize = 0;
    while (used < input.len) {
        const n = c.read(0, input[used..].ptr, input.len - used);
        if (n < 0) return error.CapabilityReadFailed;
        if (n == 0) break;
        used += @intCast(n);
    }
    try require(used > 0 and used < input.len);
    progress = .json;
    const parsed = try std.json.parseFromSlice(Grant, a, input[0..used], .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const g = &parsed.value;
    try gate(g, input[0..used], &progress); // ALL native initialization stays below this boundary.
    gate_complete = true;
    var stage: FailureStage = .native_init;
    // Reporting remains best effort; the channel preserves the original failure.
    errdefer |err| {
        var secondary: ?FailureClass = null;
        reportFailure(g, stage, err) catch |write_error| {
            secondary = failureClass(write_error);
        };
        diagnostic.emit(if (secondary == null) .native_failure else .report_write_failure, .{ .native = stage }, failureClass(err), secondary);
    }
    var native = try credentials.Native.init();
    defer native.deinit();
    var guard: Guard = .{ .grant = g, .native = native.store() };
    switch (g.phase) {
        .seed => {
            stage = .crud;
            try guard.store().put(g.refs[0], "owned-crud-first-fixture");
            try equal(guard.store(), g.refs[0], "owned-crud-first-fixture");
            try guard.store().put(g.refs[0], "owned-crud-replacement-fixture");
            try equal(guard.store(), g.refs[0], "owned-crud-replacement-fixture");
            stage = .cf_rollback;
            try seedCF(g, &guard, "rollback", 1, 2, false, false);
            stage = .cf_commit;
            try seedCF(g, &guard, "commit", 3, 4, true, false);
            stage = .cf_ambiguous;
            try seedCF(g, &guard, "ambiguous", 5, 6, false, true);
            stage = .auth_seed;
            try seedAuth(g, &guard);
        },
        .recover => {
            stage = .crud;
            try equal(guard.store(), g.refs[0], "owned-crud-replacement-fixture");
            try guard.store().delete(g.refs[0]);
            try absent(guard.store(), g.refs[0]);
            stage = .cf_rollback;
            try recoverCF(g, &guard, "rollback", 1, 2, false);
            stage = .cf_commit;
            try recoverCF(g, &guard, "commit", 3, 4, true);
            stage = .cf_ambiguous;
            try recoverCF(g, &guard, "ambiguous", 5, 6, false);
            stage = .cf_valid_invalid;
            try validAndInvalidCF(g, &guard);
            stage = .auth_cleanup;
            try recoverAuth(g, &guard);
        },
        .cleanup => for (g.refs) |ref| {
            stage = .vault_cleanup;
            guard.store().delete(ref) catch |err| {
                if (err != error.NotFound) return @as(anyerror!void, err);
            };
            try absent(guard.store(), ref);
        },
    }
    stage = .report;
    try report(g, &guard);
}

test "owned native vault acceptance" {
    if (c.getenv("VELA_NATIVE_VAULT_ACCEPTANCE") == null) return error.SkipZigTest;
    try runOwnedAcceptance();
}

test "owned native vault acceptance procfs streaming regression" {
    if (builtin.os.tag != .linux or !builtin.link_libc) return error.SkipZigTest;
    const stat_path = "/proc/self/stat";
    const status_path = "/proc/self/status";
    for ([_][]const u8{ stat_path, status_path }) |name| {
        const info = try statNoLink(name);
        try std.testing.expect(info.st_mode & 0o170000 == 0o100000 and info.st_size == 0);
    }
    const stat = try procFileBytes(stat_path, 4096);
    defer a.free(stat);
    const status = try procFileBytes(status_path, 8192);
    defer a.free(status);
    try std.testing.expect(stat.len > 0 and status.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, status, "Uid:") != null);
    const pid_end = std.mem.indexOfScalar(u8, stat, ' ') orelse return error.OwnedAcceptanceInvariant;
    try std.testing.expect(try std.fmt.parseInt(i32, stat[0..pid_end], 10) == c.getpid());
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.OwnedAcceptanceInvariant;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    var start: ?u64 = null;
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        if (index == 19) {
            start = try std.fmt.parseInt(u64, field, 10);
            break;
        }
    }
    const ticks = start orelse return error.OwnedAcceptanceInvariant;
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, "/proc/self/exe", a);
    defer a.free(exe);
    try process(c.getpid(), ticks, exe, c.getuid(), null, false);
    const wrong_ticks = if (ticks == std.math.maxInt(u64)) ticks - 1 else ticks + 1;
    try std.testing.expectError(error.OwnedAcceptanceInvariant, process(c.getpid(), wrong_ticks, exe, c.getuid(), null, false));
    for ([_][]const u8{ stat_path, status_path }) |name| {
        if (procFileBytes(name, 1)) |unexpected| {
            a.free(unexpected);
            return error.OwnedAcceptanceInvariant;
        } else |err| {
            // Compare a boolean; never print a returned raw procfs buffer.
            try std.testing.expect(err == error.StreamTooLong);
        }
    }
}
