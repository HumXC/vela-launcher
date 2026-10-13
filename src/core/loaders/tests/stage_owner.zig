//! Real filesystem faults shared by stage and production transaction regressions.
const std = @import("std");
const tree = @import("../../worlds_tree.zig");
const io = std.testing.io;

pub const FaultIo = struct {
    pub const Mode = enum { cancel_create, fail_open, fail_sync, fail_cleanup, cancel_commit };
    var active: ?*FaultIo = null;
    mode: Mode,
    prefix: []const u8 = "stage",
    vtable: std.Io.VTable = undefined,
    protection: std.Io.CancelProtection = .unblocked,
    pending: bool = false,
    created: bool = false,
    injected: bool = false,
    removed: bool = false,
    committed: bool = false,
    protected_stats: usize = 0,

    pub fn start(self: *FaultIo) std.Io {
        std.debug.assert(active == null);
        active = self;
        self.vtable = io.vtable.*;
        self.vtable.swapCancelProtection = swapProtection;
        self.vtable.checkCancel = check;
        self.vtable.dirCreateDir = create;
        self.vtable.dirOpenDir = open;
        self.vtable.dirStatFile = stat;
        self.vtable.dirDeleteDir = remove;
        self.vtable.fileSync = sync;
        self.vtable.dirRenamePreserve = rename;
        return .{ .userdata = io.userdata, .vtable = &self.vtable };
    }
    pub fn stop(self: *FaultIo) void {
        std.debug.assert(active == self);
        active = null;
    }
    fn swapProtection(raw: ?*anyopaque, new: std.Io.CancelProtection) std.Io.CancelProtection {
        active.?.protection = new;
        return io.vtable.swapCancelProtection(raw, new);
    }
    fn check(raw: ?*anyopaque) std.Io.Cancelable!void {
        const self = active.?;
        if (self.pending and self.protection == .unblocked) return error.Canceled;
        try io.vtable.checkCancel(raw);
    }
    fn create(raw: ?*anyopaque, parent: std.Io.Dir, name: []const u8, permissions: std.Io.Dir.Permissions) std.Io.Dir.CreateDirError!void {
        try check(raw);
        try io.vtable.dirCreateDir(raw, parent, name, permissions);
        const self = active.?;
        if (std.mem.startsWith(u8, name, self.prefix)) {
            self.created = true;
            if (self.mode == .cancel_create) self.pending = true;
        }
    }
    fn open(raw: ?*anyopaque, parent: std.Io.Dir, name: []const u8, options: std.Io.Dir.OpenOptions) std.Io.Dir.OpenError!std.Io.Dir {
        try check(raw);
        const self = active.?;
        if (self.created and !self.injected and self.mode == .fail_open and std.mem.startsWith(u8, name, self.prefix)) {
            self.injected = true;
            return error.AccessDenied;
        }
        return io.vtable.dirOpenDir(raw, parent, name, options);
    }
    fn stat(raw: ?*anyopaque, parent: std.Io.Dir, name: []const u8, options: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
        try check(raw);
        const self = active.?;
        if (self.created and self.protection == .blocked) self.protected_stats += 1;
        return io.vtable.dirStatFile(raw, parent, name, options);
    }
    fn remove(raw: ?*anyopaque, parent: std.Io.Dir, name: []const u8) std.Io.Dir.DeleteDirError!void {
        try check(raw);
        const self = active.?;
        if (self.created and self.mode == .fail_cleanup and std.mem.startsWith(u8, name, self.prefix)) return error.AccessDenied;
        try io.vtable.dirDeleteDir(raw, parent, name);
        if (std.mem.startsWith(u8, name, self.prefix)) self.removed = true;
    }
    fn sync(raw: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        try check(raw);
        const self = active.?;
        if (self.created and !self.injected and self.mode == .fail_sync) {
            self.injected = true;
            return error.InputOutput;
        }
        try io.vtable.fileSync(raw, file);
    }
    fn rename(raw: ?*anyopaque, old: std.Io.Dir, old_name: []const u8, new: std.Io.Dir, new_name: []const u8) std.Io.Dir.RenamePreserveError!void {
        try check(raw);
        try io.vtable.dirRenamePreserve(raw, old, old_name, new, new_name);
        const self = active.?;
        if (self.mode == .cancel_commit and std.mem.startsWith(u8, old_name, self.prefix)) {
            self.pending = true;
            self.committed = true;
        }
    }
};

fn absent(dir: std.Io.Dir, name: []const u8) !void {
    try std.testing.expectError(error.FileNotFound, dir.statFile(io, name, .{ .follow_symlinks = false }));
}

test "stage acquisition survives pending native cancellation and protected cleanup removes its tree" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fault: FaultIo = .{ .mode = .cancel_create };
    const fault_io = fault.start();
    defer fault.stop();
    var owner = try tree.StageOwner.create(fault_io, tmp.dir, "stage-owned", .default_dir);
    defer owner.close(io);
    try std.testing.expectError(error.Canceled, fault_io.checkCancel());
    try owner.cleanup(fault_io);
    try absent(tmp.dir, "stage-owned");
    try std.testing.expect(fault.removed and fault.protected_stats >= 3);
    try std.testing.expectEqual(std.Io.CancelProtection.unblocked, fault.protection);
}

test "child undoes new directories on open and sync failure without deleting preexisting data" {
    for ([_]FaultIo.Mode{ .fail_open, .fail_sync }) |mode| {
        if (mode == .fail_sync and !tree.directory_sync_supported) continue;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var fault: FaultIo = .{ .mode = mode };
        const fault_io = fault.start();
        defer fault.stop();
        if (mode == .fail_open) try std.testing.expectError(error.AccessDenied, tree.child(fault_io, tmp.dir, "stage-new", true)) else try std.testing.expectError(error.InputOutput, tree.child(fault_io, tmp.dir, "stage-new", true));
        try absent(tmp.dir, "stage-new");
        try tmp.dir.createDir(io, "stage-existing", .default_dir);
        fault.created = true;
        fault.injected = false;
        if (mode == .fail_open) try std.testing.expectError(error.AccessDenied, tree.child(fault_io, tmp.dir, "stage-existing", true)) else try std.testing.expectError(error.InputOutput, tree.child(fault_io, tmp.dir, "stage-existing", true));
        _ = try tmp.dir.statFile(io, "stage-existing", .{});
        try std.testing.expectError(error.PathAlreadyExists, tree.StageOwner.create(io, tmp.dir, "stage-existing", .default_dir));
    }
}

test "stage cleanup refuses replacement directories and reports real removal failure" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var owner = try tree.StageOwner.create(io, tmp.dir, "stage-owned", .default_dir);
    defer owner.close(io);
    try tmp.dir.rename("stage-owned", tmp.dir, "moved-original", io);
    try tmp.dir.createDir(io, "stage-owned", .default_dir);
    try std.testing.expectError(error.TreeChanged, owner.cleanup(io));
    _ = try tmp.dir.statFile(io, "stage-owned", .{});
    _ = try tmp.dir.statFile(io, "moved-original", .{});
    var other = try tree.StageOwner.create(io, tmp.dir, "stage-failure", .default_dir);
    defer other.close(io);
    var fault: FaultIo = .{ .mode = .fail_cleanup, .created = true };
    const fault_io = fault.start();
    defer fault.stop();
    try std.testing.expectError(error.AccessDenied, other.cleanup(fault_io));
    _ = try tmp.dir.statFile(io, "stage-failure", .{});
}

const NativeCancel = struct {
    parent: std.Io.Dir,
    ready: std.atomic.Value(bool) = .init(false),
    fn run(self: *NativeCancel) !void {
        var owner = try tree.StageOwner.create(io, self.parent, "stage-future", .default_dir);
        defer owner.close(io);
        self.ready.store(true, .release);
        io.sleep(.fromSeconds(30), .awake) catch |err| {
            // Preserve the outstanding native request while rollback owns I/O.
            io.recancel();
            try owner.cleanup(io);
            return err;
        };
        return error.ExpectedCancellation;
    }
};

test "future cancellation joins only after the owned stage is removed" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var worker: NativeCancel = .{ .parent = tmp.dir };
    var future = try io.concurrent(NativeCancel.run, .{&worker});
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    while (!worker.ready.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds - started > 3 * std.time.ns_per_s) {
            _ = future.cancel(io) catch {};
            return error.FixtureTimeout;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try absent(tmp.dir, "stage-future");
}
