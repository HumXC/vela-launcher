//! Owned task presentation state; no frame-local manager strings survive synchronization.
const std = @import("std");
const manager = @import("../application/instances_manager.zig");
const tasks = @import("../core/tasks.zig");

pub const State = struct {
    visible: bool = false,
    task_id: ?u64 = null,
    observed_id: ?u64 = null,
    operation: manager.Operation = .none,
    phase: manager.Phase = .idle,
    failure: ?anyerror = null,
    admission_failure: bool = false,
    durability_uncertain: bool = false,
    instance_name: ?[]u8 = null,
    recovery_directory: ?[]u8 = null,
    details: tasks.Details = .{},

    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        if (self.instance_name) |s| a.free(s);
        if (self.recovery_directory) |s| a.free(s);
        self.* = .{};
    }

    pub fn available(self: *const State) bool {
        return self.operation != .none;
    }

    pub fn observe(self: *State, a: std.mem.Allocator, snapshot: manager.Snapshot) !void {
        if (snapshot.operation == .none or snapshot.operation == .loading_loaders) return;
        const id = snapshot.task_id orelse return;
        const is_new = self.observed_id != id;
        // An unsuccessful admission must not be overwritten by the previous task's result.
        if (!is_new and self.admission_failure) return;
        try replaceText(a, &self.instance_name, if (snapshot.instance) |instance| instance.name else null);
        try replaceText(a, &self.recovery_directory, snapshot.recovery_directory);
        if (is_new) self.visible = true;
        self.observed_id = id;
        self.task_id = id;
        self.operation = snapshot.operation;
        self.phase = snapshot.phase;
        self.failure = snapshot.failure;
        self.admission_failure = false;
        self.durability_uncertain = snapshot.durability_uncertain;
        self.details = snapshot.details;
        if (self.phase != .working) self.details.stop();
    }

    pub fn failAdmission(self: *State, a: std.mem.Allocator, operation: manager.Operation, name: []const u8, err: anyerror) void {
        replaceText(a, &self.instance_name, name) catch {};
        replaceText(a, &self.recovery_directory, null) catch {};
        self.task_id = null;
        self.operation = operation;
        self.phase = .failed;
        self.failure = err;
        self.admission_failure = true;
        self.durability_uncertain = false;
        self.details = .{};
        self.visible = true;
    }
};

fn replaceText(a: std.mem.Allocator, target: *?[]u8, value: ?[]const u8) !void {
    if (value) |s| {
        if (target.*) |old| if (std.mem.eql(u8, old, s)) return;
        const owned = try a.dupe(u8, s);
        if (target.*) |old| a.free(old);
        target.* = owned;
    } else {
        if (target.*) |old| a.free(old);
        target.* = null;
    }
}

pub fn percent(completed: u64, total: ?u64) ?f64 {
    const n = total orelse return null;
    if (n == 0) return null;
    return 100.0 * @as(f64, @floatFromInt(@min(completed, n))) / @as(f64, @floatFromInt(n));
}

/// Unknown and empty totals draw an empty track rather than inventing progress.
pub fn fraction(completed: u64, total: ?u64) f32 {
    return @floatCast((percent(completed, total) orelse 0) / 100);
}

pub fn basename(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, &.{ '/', 92 });
    const start = if (std.mem.lastIndexOfAny(u8, trimmed, &.{ '/', 92 })) |index| index + 1 else 0;
    return trimmed[start..];
}

pub fn formatBytes(buffer: []u8, bytes: u64) ![]const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes});
    return formatAmount(buffer, @floatFromInt(bytes), "");
}

pub fn formatSpeed(buffer: []u8, speed: f64, active: bool) ![]const u8 {
    if (!active or !std.math.isFinite(speed) or speed < 0) return "—";
    return formatAmount(buffer, speed, "/s");
}

fn formatAmount(buffer: []u8, amount: f64, suffix: []const u8) ![]const u8 {
    if (amount >= 1024 * 1024) return std.fmt.bufPrint(buffer, "{d:.1} MB{s}", .{ amount / (1024 * 1024), suffix });
    if (amount >= 1024) return std.fmt.bufPrint(buffer, "{d:.1} KB{s}", .{ amount / 1024, suffix });
    return std.fmt.bufPrint(buffer, "{d:.0} B{s}", .{ amount, suffix });
}
