//! Main-thread task registry; services own and join their std.Io.Future workers.
//! Only report(), reportDetails(), progress(), details(), and canceled() may be called from workers.
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
pub const FileState = enum { queued, downloading, verifying, complete, failed, canceled };
pub const File = struct {
    name_bytes: [160]u8 = @splat(0),
    name_len: usize = 0,
    path_bytes: [512]u8 = @splat(0),
    path_len: usize = 0,
    received: u64 = 0,
    total: ?u64 = null,
    bytes_per_second: f64 = 0,
    state: FileState = .queued,
    failure: ?anyerror = null,

    pub fn init(path_value: []const u8, received: u64, total: ?u64, speed: f64, state: FileState, failure: ?anyerror) File {
        var result: File = .{ .received = received, .total = total, .bytes_per_second = validSpeed(speed), .state = state, .failure = failure };
        // URLs are labels too: avoid retaining query credentials in diagnostic text.
        const is_url = std.mem.startsWith(u8, path_value, "https://") or std.mem.startsWith(u8, path_value, "http://");
        const label = if (is_url) path_value[0 .. std.mem.indexOfAny(u8, path_value, "?#") orelse path_value.len] else path_value;
        result.path_len = copyText(&result.path_bytes, label);
        result.name_len = copyText(&result.name_bytes, std.fs.path.basename(label));
        if (state == .complete or state == .failed or state == .canceled) result.bytes_per_second = 0;
        return result;
    }
    pub fn name(self: *const File) []const u8 {
        return self.name_bytes[0..self.name_len];
    }
    pub fn path(self: *const File) []const u8 {
        return self.path_bytes[0..self.path_len];
    }
};

fn validSpeed(speed: f64) f64 {
    return if (std.math.isFinite(speed) and speed > 0) speed else 0;
}
fn copyText(destination: []u8, source: []const u8) usize {
    var n = @min(destination.len, source.len);
    // Never split a UTF-8 codepoint. Invalid input is rendered as bounded ASCII.
    const valid_utf8 = std.unicode.utf8ValidateSlice(source);
    if (valid_utf8) {
        while (n > 0 and !std.unicode.utf8ValidateSlice(source[0..n])) n -= 1;
    }
    for (source[0..n], destination[0..n]) |byte, *out| out.* = if (byte < 32 or byte == 127 or (!valid_utf8 and byte >= 128)) '?' else byte;
    return n;
}

/// Owns every displayed byte. Transfer totals describe the current transfer batch.
pub const Details = struct {
    stage: Stage = .queued,
    completed: u64 = 0,
    total: ?u64 = null,
    received: u64 = 0,
    total_bytes: ?u64 = null,
    bytes_per_second: f64 = 0,
    file_count: usize = 0,
    omitted_files: usize = 0,
    files: [8]File = @splat(.{}),

    pub fn addFile(self: *Details, file: File) void {
        if (self.file_count < self.files.len) {
            self.files[self.file_count] = file;
            self.file_count += 1;
        } else {
            self.omitted_files += 1;
            // Cleanup cancellation must not hide an earlier genuine failure.
            if (file.failure) |failure| {
                const retained = self.files[self.files.len - 1].failure;
                const retained_failure = if (retained) |previous| previous != error.Canceled else false;
                if (failure != error.Canceled or !retained_failure)
                    self.files[self.files.len - 1] = file;
            }
        }
    }
    pub fn stop(self: *Details) void {
        self.bytes_per_second = 0;
        for (self.files[0..self.file_count]) |*file| file.bytes_per_second = 0;
    }
};

pub const Task = struct {
    // Main-thread fields. The registry owns title; callers must not mutate it.
    id: u64,
    title: []const u8,
    kind: Kind,
    state: State = .queued,
    failure: ?anyerror = null,
    cancellation: std.atomic.Value(bool) = .init(false),

    progress_lock: std.atomic.Mutex = .unlocked,
    reported: Details = .{},

    pub fn canceled(self: *const Task) bool {
        return self.cancellation.load(.acquire);
    }

    /// Allocation-free, coherent publication. Known totals clamp UI overflow.
    pub fn report(self: *Task, stage: Stage, completed: u64, total: ?u64) void {
        self.lockProgress();
        defer self.progress_lock.unlock();
        const continuing_transfer = self.reported.stage == stage and (stage == .downloading or stage == .metadata);
        self.reported.stage = stage;
        self.reported.completed = if (total) |limit| @min(completed, limit) else completed;
        self.reported.total = total;
        if (!continuing_transfer) self.reported.stop();
    }

    pub fn progress(self: *Task) Progress {
        self.lockProgress();
        defer self.progress_lock.unlock();
        return .{ .stage = self.reported.stage, .completed = self.reported.completed, .total = self.reported.total };
    }

    pub fn reportDetails(self: *Task, value: Details) void {
        self.lockProgress();
        defer self.progress_lock.unlock();
        self.reported = value;
        self.reported.file_count = @min(value.file_count, value.files.len);
        self.reported.bytes_per_second = validSpeed(value.bytes_per_second);
        for (self.reported.files[0..self.reported.file_count]) |*file| {
            file.name_len = @min(file.name_len, file.name_bytes.len);
            file.path_len = @min(file.path_len, file.path_bytes.len);
            file.bytes_per_second = switch (file.state) {
                .complete, .failed, .canceled => 0,
                else => validSpeed(file.bytes_per_second),
            };
        }
        if (value.total) |total| self.reported.completed = @min(value.completed, total);
    }

    pub fn details(self: *Task) Details {
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

    /// Copies title. Entry pointers survive growth until terminal dismissal/prune or deinit.
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
        task.lockProgress();
        task.reported.stop();
        for (task.reported.files[0..task.reported.file_count]) |*file| {
            switch (file.state) {
                .queued, .downloading, .verifying => file.state = if (task.state == .succeeded) .complete else .canceled,
                .complete, .failed, .canceled => {},
            }
        }
        task.progress_lock.unlock();
    }

    /// Borrowed list slice, invalidated by create/dismiss/prune/deinit. Surviving
    /// task pointers remain stable. Access this slice only on the main thread.
    pub fn tasks(self: *const Registry) []const *Task {
        return self.entries.items;
    }

    pub fn hasActive(self: *const Registry) bool {
        for (self.entries.items) |task| {
            if (!terminal(task.state)) return true;
        }
        return false;
    }

    /// Dismiss one terminal notification after UI borrows end. Like pruneFinished,
    /// this requires finish's worker-join contract; active entries are never freed.
    /// Returns false for an active task or an unknown ID, preserving survivor order.
    pub fn dismiss(self: *Registry, id: u64) bool {
        for (self.entries.items, 0..) |task, index| {
            if (task.id != id) continue;
            if (!terminal(task.state)) return false;
            _ = self.entries.orderedRemove(index);
            self.destroy(task);
            return true;
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
    try @import("test_allocations").checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
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

test "dismiss removes only terminal IDs and preserves unrelated entries and order" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const queued = try registry.create(.java_scan, "Queued");
    const succeeded = try registry.create(.game_install, "Succeeded");
    const running = try registry.create(.java_download, "Running");
    const canceled = try registry.create(.save_copy, "Canceled");
    const failed = try registry.create(.save_backup, "Failed");
    const canceling = try registry.create(.java_download, "Canceling");
    const tail = try registry.create(.java_scan, "Tail");
    try registry.start(succeeded);
    registry.finish(succeeded, .succeeded);
    try registry.start(running);
    try registry.start(canceled);
    registry.finish(canceled, .canceled);
    registry.finish(failed, .{ .failed = error.FixtureFailure });
    try registry.start(canceling);
    try std.testing.expect(registry.cancel(canceling.id));
    const succeeded_id = succeeded.id;
    const canceled_id = canceled.id;
    const failed_id = failed.id;
    const next_id = registry.next_id;

    try std.testing.expect(!registry.dismiss(0));
    try std.testing.expect(!registry.dismiss(std.math.maxInt(u64)));
    for ([_]*Task{ queued, running, canceling, tail }) |task|
        try std.testing.expect(!registry.dismiss(task.id));
    try std.testing.expectEqual(@as(usize, 7), registry.tasks().len);
    try std.testing.expect(registry.dismiss(succeeded_id));
    try std.testing.expect(registry.dismiss(canceled_id));
    try std.testing.expect(registry.dismiss(failed_id));
    try std.testing.expect(!registry.dismiss(succeeded_id));
    try std.testing.expectEqual(@as(usize, 4), registry.tasks().len);
    for ([_]*Task{ queued, running, canceling, tail }, registry.tasks()) |expected, actual|
        try std.testing.expectEqual(expected, actual);
    try std.testing.expectEqual(next_id, registry.next_id);
    try std.testing.expectEqualStrings("Running", running.title);
    running.report(.downloading, 4, 10);
    try std.testing.expectEqual(@as(u64, 4), running.progress().completed);
    try std.testing.expectEqual(State.canceling, canceling.state);
    const later = try registry.create(.java_scan, "Later");
    try std.testing.expectEqual(next_id, later.id);
}

test "dismiss retains a worker-owned task until join and terminal acknowledgement" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    const task = try registry.create(.java_download, "Worker-owned");
    const id = task.id;
    try registry.start(task);
    const Worker = struct {
        fn run(owned: *Task) void {
            while (!owned.canceled()) std.atomic.spinLoopHint();
            owned.report(.downloading, 7, 10);
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{task});
    var joined = false;
    defer if (!joined) {
        _ = registry.cancel(id);
        worker.join();
    };
    try std.testing.expect(!registry.dismiss(id));
    try std.testing.expect(registry.cancel(id));
    try std.testing.expectEqual(State.canceling, task.state);
    try std.testing.expect(!registry.dismiss(id));
    worker.join();
    joined = true;
    // Joining alone does not publish a terminal state or free the notification.
    try std.testing.expect(!registry.dismiss(id));
    try std.testing.expectEqual(@as(u64, 7), task.progress().completed);
    registry.finish(task, .canceled);
    try std.testing.expect(registry.dismiss(id));
    try std.testing.expectEqual(@as(usize, 0), registry.tasks().len);
}

test "bounded telemetry owns UTF8 labels and preserves failure beyond display bound" {
    var label: [600]u8 = @splat('x');
    @memcpy(label[159..165], "世界");
    const copied = File.init(&label, 64, null, 25, .downloading, null);
    @memset(&label, 'z');
    try std.testing.expectEqual(@as(usize, 159), copied.name_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(copied.name()));
    try std.testing.expect(copied.path_len <= copied.path_bytes.len);
    try std.testing.expectEqual(@as(u8, 'x'), copied.path()[0]);
    const sanitized = File.init("https://example.invalid/bad\n.jar?secret=value", 0, null, std.math.nan(f64), .queued, null);
    try std.testing.expectEqualStrings("bad?.jar", sanitized.name());
    try std.testing.expectEqualStrings("https://example.invalid/bad?.jar", sanitized.path());
    try std.testing.expectEqual(@as(f64, 0), sanitized.bytes_per_second);
    const local = File.init("/folder/l#q?.jar", 0, null, 0, .queued, null);
    try std.testing.expectEqualStrings("l#q?.jar", local.name());
    try std.testing.expectEqualStrings("/folder/l#q?.jar", local.path());
    var details: Details = .{};
    for (0..12) |_| details.addFile(copied);
    details.addFile(File.init("early-canceled.jar", 12, 128, 0, .canceled, error.Canceled));
    try std.testing.expectEqualStrings("early-canceled.jar", details.files[7].name());
    details.addFile(File.init("offending.jar", 64, 128, 999, .failed, error.ChecksumMismatch));
    try std.testing.expectEqual(@as(usize, 8), details.file_count);
    try std.testing.expectEqual(@as(usize, 6), details.omitted_files);
    try std.testing.expectEqualStrings("offending.jar", details.files[7].name());
    try std.testing.expectEqual(@as(?anyerror, error.ChecksumMismatch), details.files[7].failure);
    try std.testing.expectEqual(@as(f64, 0), details.files[7].bytes_per_second);
    for (0..3) |_| details.addFile(File.init("cleanup-canceled.jar", 16, 128, 0, .canceled, error.Canceled));
    try std.testing.expectEqual(@as(usize, 8), details.file_count);
    try std.testing.expectEqual(@as(usize, 9), details.omitted_files);
    try std.testing.expectEqualStrings("offending.jar", details.files[7].name());
    try std.testing.expectEqual(@as(?anyerror, error.ChecksumMismatch), details.files[7].failure);
}

test "terminal telemetry stops every transfer and survives value copy after dismissal" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    for ([_]Outcome{ .succeeded, .canceled, .{ .failed = error.ChecksumMismatch } }) |outcome| {
        const task = try registry.create(.game_install, "Files");
        try registry.start(task);
        var details: Details = .{ .stage = .downloading, .received = 90, .total_bytes = null, .bytes_per_second = 50 };
        details.addFile(File.init("active.jar", 64, 128, 25, .downloading, null));
        details.addFile(File.init("failed.jar", 26, null, 25, .failed, error.ChecksumMismatch));
        task.reportDetails(details);
        const live = task.details();
        try std.testing.expectEqual(@as(u64, 0), live.completed);
        try std.testing.expectEqual(@as(f64, 25), live.files[0].bytes_per_second);
        task.report(.downloading, 1, 10);
        try std.testing.expectEqual(@as(f64, 50), task.details().bytes_per_second);
        try std.testing.expectEqual(@as(f64, 25), task.details().files[0].bytes_per_second);
        task.report(.verifying, 1, 10);
        try std.testing.expectEqual(@as(f64, 0), task.details().bytes_per_second);
        registry.finish(task, outcome);
        const retained = task.details();
        const id = task.id;
        try std.testing.expectEqual(@as(f64, 0), retained.bytes_per_second);
        try std.testing.expectEqual(@as(f64, 0), retained.files[0].bytes_per_second);
        try std.testing.expectEqual(if (task.state == .succeeded) FileState.complete else FileState.canceled, retained.files[0].state);
        try std.testing.expectEqual(FileState.failed, retained.files[1].state);
        try std.testing.expect(registry.dismiss(id));
        try std.testing.expectEqualStrings("failed.jar", retained.files[1].name());
        try std.testing.expectEqual(@as(?anyerror, error.ChecksumMismatch), retained.files[1].failure);
    }
}
