//! Main-thread task registry; services own and join their std.Io.Future workers.
//! Only report(), progress(), and canceled() may be called from worker threads.
//! Call finish() only after joining every worker that references the task, and
//! deinit() only after all workers have joined. Terminal tasks may be pruned.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    game_install,
    java_download,
    mod_install,
    modpack_install,
    modpack_update,
    java_scan,
    save_backup,
    save_restore,
    save_copy,
    credential_update,
};

pub const State = enum { queued, running, canceling, canceled, succeeded, failed };
pub const Stage = enum {
    queued,
    metadata,
    downloading,
    verifying,
    extracting,
    installing,
    scanning,
    backing_up,
    restoring,
    copying,
    finalizing,
};
pub const Outcome = union(enum) { succeeded, canceled, failed: anyerror };
pub const Progress = struct { stage: Stage, completed: u64, total: ?u64 };

pub const Task = struct {
    // Main-thread fields. The registry owns title; callers must not mutate it.
    id: u64,
    title: []const u8,
    kind: Kind,
    state: State = .queued,
    failure: ?anyerror = null,
    cancellation: std.atomic.Value(bool) = .init(false),

    progress_lock: std.atomic.Mutex = .unlocked,
    reported: Progress = .{ .stage = .queued, .completed = 0, .total = null },

    pub fn canceled(self: *const Task) bool {
        return self.cancellation.load(.acquire);
    }

    /// Allocation-free, coherent publication. Known totals clamp UI overflow.
    pub fn report(self: *Task, stage: Stage, completed: u64, total: ?u64) void {
        self.lockProgress();
        defer self.progress_lock.unlock();
        self.reported = .{
            .stage = stage,
            .completed = if (total) |limit| @min(completed, limit) else completed,
            .total = total,
        };
    }

    pub fn progress(self: *Task) Progress {
        self.lockProgress();
        defer self.progress_lock.unlock();
        return self.reported;
    }

    fn lockProgress(self: *Task) void {
        // The lock protects only a fixed-size copy, never I/O or allocation.
        while (!self.progress_lock.tryLock()) std.atomic.spinLoopHint();
    }
};

pub const Registry = struct {
    allocator: Allocator,
    entries: std.ArrayList(*Task) = .empty,
    next_id: u64 = 1, // Zero marks exhaustion, so IDs never wrap or get reused.

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator };
    }

    /// All service workers must have joined before destroying the registry.
    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |task| self.destroy(task);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Copies title. Entry pointers survive list growth until prune or deinit.
    pub fn create(self: *Registry, kind: Kind, title: []const u8) !*Task {
        if (self.next_id == 0) return error.IdExhausted;
        const task = try self.allocator.create(Task);
        errdefer self.allocator.destroy(task);
        const owned_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned_title);
        task.* = .{ .id = self.next_id, .title = owned_title, .kind = kind };
        try self.entries.append(self.allocator, task);
        self.next_id = if (self.next_id == std.math.maxInt(u64)) 0 else self.next_id + 1;
        return task;
    }

    pub fn start(self: *Registry, task: *Task) !void {
        if (!self.contains(task)) return error.UnknownTask;
        if (task.state != .queued) return error.InvalidState;
        task.state = .running;
    }

    /// True for an active matching task, including an existing cancel request.
    /// Queued tasks have no workers; running tasks need finish(.canceled) to ack.
    pub fn cancel(self: *Registry, id: u64) bool {
        for (self.entries.items) |task| {
            if (task.id != id) continue;
            switch (task.state) {
                .queued => task.state = .canceled,
                .running => task.state = .canceling,
                .canceling => {},
                .canceled, .succeeded, .failed => return false,
            }
            task.cancellation.store(true, .release);
            return true;
        }
        return false;
    }

    /// Call only after joining all task workers. Explicit outcome wins over a
    /// late cancel token. Queued setup failures are allowed; terminal is final.
    pub fn finish(self: *Registry, task: *Task, outcome: Outcome) void {
        std.debug.assert(self.contains(task));
        if (terminal(task.state)) return;
        switch (outcome) {
            .succeeded => task.state = .succeeded,
            .canceled => task.state = .canceled,
            .failed => |failure| {
                task.state = .failed;
                task.failure = failure;
            },
        }
    }

    /// Borrowed list slice, invalidated by create/prune/deinit; task pointers
    /// themselves remain stable. Access this slice only on the main thread.
    pub fn tasks(self: *const Registry) []const *Task {
        return self.entries.items;
    }

    pub fn hasActive(self: *const Registry) bool {
        for (self.entries.items) |task| {
            if (!terminal(task.state)) return true;
        }
        return false;
    }

    /// Keep the newest `keep` terminal entries in creation order, preserving
    /// every active entry and survivor order. finish's join contract is required.
    pub fn pruneFinished(self: *Registry, keep: usize) void {
        var finished: usize = 0;
        for (self.entries.items) |task| {
            if (terminal(task.state)) finished += 1;
        }
        var remaining = finished -| keep;
        var write_index: usize = 0;
        for (self.entries.items) |task| {
            if (remaining > 0 and terminal(task.state)) {
                self.destroy(task);
                remaining -= 1;
            } else {
                self.entries.items[write_index] = task;
                write_index += 1;
            }
        }
        self.entries.items.len = write_index;
    }

    fn contains(self: *const Registry, task: *const Task) bool {
        for (self.entries.items) |entry| {
            if (entry == task) return true;
        }
        return false;
    }

    fn destroy(self: *Registry, task: *Task) void {
        self.allocator.free(task.title);
        self.allocator.destroy(task);
    }
};

fn terminal(state: State) bool {
    return switch (state) {
        .queued, .running, .canceling => false,
        .canceled, .succeeded, .failed => true,
    };
}

test "queued lifecycle, cancellation, and invalid starts" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expect(!registry.hasActive());
    try std.testing.expect(!registry.cancel(999));
    const task = try registry.create(.game_install, "Install game");
    try std.testing.expectEqual(State.queued, task.state);
    try std.testing.expectEqual(@as(?anyerror, null), task.failure);
    try std.testing.expect(!task.canceled());
    try std.testing.expect(!task.cancellation.load(.acquire));
    try std.testing.expect(registry.hasActive());
    try std.testing.expect(registry.cancel(task.id));
    try std.testing.expectEqual(State.canceled, task.state);
    try std.testing.expect(task.canceled());
    try std.testing.expect(!registry.cancel(task.id));
    try std.testing.expectError(error.InvalidState, registry.start(task));
    registry.finish(task, .succeeded);
    try std.testing.expectEqual(State.canceled, task.state);
    try std.testing.expect(!registry.hasActive());
}

test "running outcomes and cancellation acknowledgement" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const outcomes = [_]Outcome{ .succeeded, .canceled, .{ .failed = error.TestFailure } };
    const states = [_]State{ .succeeded, .canceled, .failed };
    for ([_]bool{ false, true }) |request_cancel| {
        for (outcomes, states) |outcome, expected| {
            const task = try registry.create(.java_download, "Download Java");
            try registry.start(task);
            try std.testing.expectEqual(State.running, task.state);
            try std.testing.expectError(error.InvalidState, registry.start(task));
            if (request_cancel) {
                try std.testing.expect(registry.cancel(task.id));
                try std.testing.expect(registry.cancel(task.id));
                try std.testing.expect(task.canceled());
                try std.testing.expectEqual(State.canceling, task.state);
                try std.testing.expect(registry.hasActive());
                try std.testing.expectError(error.InvalidState, registry.start(task));
            }
            registry.finish(task, outcome);
            try std.testing.expectEqual(expected, task.state);
            try std.testing.expectEqual(request_cancel, task.canceled());
            try std.testing.expectEqual(
                @as(?anyerror, if (expected == .failed) error.TestFailure else null),
                task.failure,
            );
            try std.testing.expect(!registry.cancel(task.id));
            try std.testing.expectError(error.InvalidState, registry.start(task));
            registry.finish(task, .{ .failed = error.OtherFailure });
            try std.testing.expectEqual(expected, task.state);
            try std.testing.expectEqual(
                @as(?anyerror, if (expected == .failed) error.TestFailure else null),
                task.failure,
            );
            try std.testing.expect(!registry.hasActive());
        }
    }
}

test "queued setup outcome and foreign task start" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var other = Registry.init(std.testing.allocator);
    defer other.deinit();
    const foreign = try other.create(.mod_install, "Other");
    try std.testing.expectError(error.UnknownTask, registry.start(foreign));
    for ([_]Outcome{ .succeeded, .canceled, .{ .failed = error.SetupFailed } }) |outcome| {
        const task = try registry.create(.modpack_install, "Setup");
        registry.finish(task, outcome);
        try std.testing.expect(terminal(task.state));
    }
    try std.testing.expect(!registry.hasActive());
}

test "owned title, unique ids, and stable task and token pointers across growth" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var title = [_]u8{ 'J', 'a', 'v', 'a' };
    const first = try registry.create(.java_scan, &title);
    const token = &first.cancellation;
    const lock = &first.progress_lock;
    title[0] = 'L';
    var previous_id = first.id;
    for (0..256) |_| {
        const task = try registry.create(.save_copy, "Copy");
        try std.testing.expect(task.id > previous_id);
        previous_id = task.id;
    }
    try std.testing.expectEqual(@as(usize, 257), registry.tasks().len);
    try std.testing.expect(first == registry.tasks()[0]);
    try std.testing.expect(token == &first.cancellation);
    try std.testing.expect(lock == &first.progress_lock);
    try std.testing.expectEqualStrings("Java", first.title);
    try std.testing.expectEqual(Kind.java_scan, first.kind);
    try registry.start(first);
    try std.testing.expect(registry.cancel(first.id));
    try std.testing.expect(token.load(.acquire));
}

test "pruning retains active pointers and newest terminal entries" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const old = try registry.create(.save_backup, "Old");
    const queued = try registry.create(.save_restore, "Queued");
    const running = try registry.create(.modpack_update, "Running");
    const canceled = try registry.create(.game_install, "Canceled");
    const canceling = try registry.create(.java_download, "Canceling");
    const failed = try registry.create(.mod_install, "Failed");
    const newest = try registry.create(.java_scan, "Newest");
    try registry.start(old);
    registry.finish(old, .succeeded);
    try registry.start(running);
    try std.testing.expect(registry.cancel(canceled.id));
    try registry.start(canceling);
    try std.testing.expect(registry.cancel(canceling.id));
    registry.finish(failed, .{ .failed = error.TestFailure });
    registry.finish(newest, .succeeded);
    const last_id = newest.id;
    registry.pruneFinished(999);
    try std.testing.expectEqual(@as(usize, 7), registry.tasks().len);
    registry.pruneFinished(2);
    const expected = [_]*Task{ queued, running, canceling, failed, newest };
    try std.testing.expectEqualSlices(*Task, &expected, registry.tasks());
    try std.testing.expect(registry.hasActive());
    registry.pruneFinished(0);
    const active = [_]*Task{ queued, running, canceling };
    try std.testing.expectEqualSlices(*Task, &active, registry.tasks());
    try std.testing.expect(canceling.canceled());
    registry.finish(running, .succeeded);
    registry.finish(canceling, .canceled);
    try std.testing.expect(registry.cancel(queued.id));
    try std.testing.expect(!registry.hasActive());
    registry.pruneFinished(0);
    try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
    const after = try registry.create(.save_backup, "After prune");
    try std.testing.expect(after.id > last_id);
}

test "progress defaults, every stage, totals, and overflow clamping" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const task = try registry.create(.save_copy, "Copy");
    try std.testing.expectEqualDeep(Progress{ .stage = .queued, .completed = 0, .total = null }, task.progress());
    inline for (std.meta.tags(Stage)) |stage| {
        task.report(stage, 5, 10);
        try std.testing.expectEqualDeep(Progress{ .stage = stage, .completed = 5, .total = 10 }, task.progress());
    }
    task.report(.downloading, 20, 10);
    try std.testing.expectEqualDeep(Progress{ .stage = .downloading, .completed = 10, .total = 10 }, task.progress());
    task.report(.verifying, 20, 0);
    try std.testing.expectEqualDeep(Progress{ .stage = .verifying, .completed = 0, .total = 0 }, task.progress());
    task.report(.finalizing, std.math.maxInt(u64), null);
    try std.testing.expectEqualDeep(Progress{ .stage = .finalizing, .completed = std.math.maxInt(u64), .total = null }, task.progress());
    try std.testing.expectEqual(State.queued, task.state);
    try std.testing.expect(!task.canceled());
}

test "concurrent progress snapshots remain coherent and worker sees cancellation" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const Worker = struct {
        fn run(task: *Task, done: *std.atomic.Value(bool)) void {
            for (0..20_000) |_| {
                task.report(.downloading, 10, 100);
                task.report(.verifying, 20, 200);
            }
            while (!task.canceled()) std.atomic.spinLoopHint();
            done.store(true, .release);
        }
    };
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const task = try registry.create(.game_install, "Concurrent");
    try registry.start(task);
    var done: std.atomic.Value(bool) = .init(false);
    const worker = try std.Thread.spawn(.{}, Worker.run, .{ task, &done });
    // Ensure even a failed assertion joins before registry cleanup.
    defer worker.join();
    _ = registry.cancel(task.id);
    for (0..20_000) |_| {
        const snapshot = task.progress();
        switch (snapshot.stage) {
            .queued => try std.testing.expectEqualDeep(Progress{ .stage = .queued, .completed = 0, .total = null }, snapshot),
            .downloading => try std.testing.expectEqualDeep(Progress{ .stage = .downloading, .completed = 10, .total = 100 }, snapshot),
            .verifying => try std.testing.expectEqualDeep(Progress{ .stage = .verifying, .completed = 20, .total = 200 }, snapshot),
            else => return error.IncoherentProgress,
        }
    }
    while (!done.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expectEqual(State.canceling, task.state);
}

test "create allocation failures roll back title, task, list, and id" {
    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var registry = Registry.init(failing.allocator());
        defer registry.deinit();
        try std.testing.expectError(error.OutOfMemory, registry.create(.game_install, "Owned title"));
        try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
        try std.testing.expectEqual(@as(u64, 1), registry.next_id);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        failing.fail_index = std.math.maxInt(usize);
        const recovered = try registry.create(.java_scan, "Recovered");
        try std.testing.expectEqual(@as(u64, 1), recovered.id);
    }
}

fn allocationExercise(allocator: Allocator) !void {
    var registry = Registry.init(allocator);
    defer registry.deinit();
    for (0..32) |_| _ = try registry.create(.save_copy, "Growth title");
    for (registry.tasks()) |task| registry.finish(task, .succeeded);
    registry.pruneFinished(1);
    try std.testing.expectEqual(@as(usize, 1), registry.tasks().len);
}

test "all create and list-growth allocation failures are leak-free" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}

test "id exhaustion never wraps or reuses an id" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    registry.next_id = std.math.maxInt(u64);
    const last = try registry.create(.save_copy, "Last");
    try std.testing.expectEqual(std.math.maxInt(u64), last.id);
    try std.testing.expectError(error.IdExhausted, registry.create(.save_copy, "No wrap"));
    registry.finish(last, .succeeded);
    registry.pruneFinished(0);
    try std.testing.expectError(error.IdExhausted, registry.create(.save_copy, "No reuse"));
}
