//! Standalone state-only tests: direnv exec . zig test src/instances_view_tests.zig -lc
const std = @import("std");
const config = @import("core/config.zig");
const view = @import("ui/instances_view.zig");
const manager_module = @import("application/instances_manager.zig");
const Phase = manager_module.Phase;
const FixtureManager = struct {
    phase: Phase = .idle,
    operation: manager_module.Operation = .none,
    failure: ?anyerror = null,
    selects: usize = 0,
    saves: usize = 0,
    starts: usize = 0,
    publishes: usize = 0,
    renames: usize = 0,
    rename_options_starts: usize = 0,
    deletes: usize = 0,
    loads: usize = 0,
    refreshes: usize = 0,
    connections: usize = 0,
    cancellations: usize = 0,
    task_id: ?u64 = null,
    captured_loader_base: [201]u8 = @splat(0),
    captured_loader_kind: config.Loader = .vanilla,
    fail_start: bool = false,
    fail_save: bool = false,
    fail_publish: bool = false,
    captured_id: [201]u8 = @splat(0),
    captured_name: [201]u8 = @splat(0),
    captured_base: [201]u8 = @splat(0),
    captured_java: [4097]u8 = @splat(0),
    captured_min_memory: ?u32 = null,
    captured_memory: ?u32 = null,
    captured_debug: bool = false,
    rename_pending: bool = false,
    pub fn setDownloadConnections(self: *FixtureManager, _: u16) void {
        self.connections += 1;
    }
    pub fn isBusy(self: *FixtureManager) bool {
        return self.phase == .working;
    }
    pub fn snapshot(self: *FixtureManager) manager_module.Snapshot {
        return .{ .phase = self.phase, .operation = self.operation, .task_id = self.task_id, .failure = self.failure, .instance = null, .recovery_directory = null, .completed = 0, .total = 0 };
    }
    pub fn cancel(self: *FixtureManager) void {
        self.cancellations += 1;
        self.phase = .canceled;
    }
    pub fn select(self: *FixtureManager, store: *config.Store, id: []const u8) !void {
        self.selects += 1;
        store.state.value.selected_instance = try store.state.arena.allocator().dupe(u8, id);
    }
    pub fn saveOptionsChecked(self: *FixtureManager, store: *config.Store, original: config.Instance, instance: config.Instance) !void {
        for (store.snapshot().instances) |entry| if (std.mem.eql(u8, entry.id, instance.id)) {
            if (!manager_module.sameInstance(entry, original)) return error.InstanceConfigurationChanged;
            break;
        };
        self.saves += 1;
        if (self.fail_save) return error.DiskFailure;
        capture(&self.captured_java, instance.java_path orelse "");
        self.captured_min_memory = instance.min_memory_mb;
        self.captured_memory = instance.max_memory_mb;
        self.captured_debug = instance.debug_launch;
        for (@constCast(store.state.value.instances)) |*entry| if (std.mem.eql(u8, entry.id, instance.id)) {
            entry.java_path = if (instance.java_path) |java| try store.state.arena.allocator().dupe(u8, java) else null;
            entry.min_memory_mb = instance.min_memory_mb;
            entry.max_memory_mb = instance.max_memory_mb;
            entry.debug_launch = instance.debug_launch;
        };
    }
    pub fn startCreate(self: *FixtureManager, instance: config.Instance) !void {
        self.starts += 1;
        capture(&self.captured_id, instance.id);
        capture(&self.captured_name, instance.name);
        capture(&self.captured_base, instance.minecraft_version);
        if (self.fail_start) return error.InstallAdapterUnavailable;
        self.phase = .working;
    }
    pub fn startRenameWithOptions(self: *FixtureManager, original: config.Instance, updated: config.Instance) !void {
        self.rename_options_starts += 1;
        if (self.fail_start) return error.WorkerUnavailable;
        self.renames += 1;
        capture(&self.captured_name, updated.name);
        self.phase = .working;
        capture(&self.captured_id, original.id);
        capture(&self.captured_java, updated.java_path orelse "");
        self.captured_min_memory = updated.min_memory_mb;
        self.captured_memory = updated.max_memory_mb;
        self.captured_debug = updated.debug_launch;
        self.rename_pending = true;
    }
    pub fn startDelete(self: *FixtureManager, _: config.Instance) !void {
        self.deletes += 1;
        self.phase = .working;
    }
    pub fn publish(self: *FixtureManager, store: *config.Store) !void {
        self.publishes += 1;
        if (self.fail_publish) return error.DiskFailure;
        if (self.rename_pending) {
            for (@constCast(store.state.value.instances)) |*entry| if (std.mem.eql(u8, entry.id, string(&self.captured_id))) {
                entry.name = try store.state.arena.allocator().dupe(u8, string(&self.captured_name));
                const java = string(&self.captured_java);
                entry.java_path = if (java.len == 0) null else try store.state.arena.allocator().dupe(u8, java);
                entry.min_memory_mb = self.captured_min_memory;
                entry.max_memory_mb = self.captured_memory;
                entry.debug_launch = self.captured_debug;
            };
            self.rename_pending = false;
        }
        self.phase = .complete;
    }
    pub fn loadLoaders(self: *FixtureManager, base: []const u8, kind: config.Loader) !void {
        self.loads += 1;
        capture(&self.captured_loader_base, base);
        self.captured_loader_kind = kind;
    }
    pub fn refreshLoaders(self: *FixtureManager, base: []const u8, kind: config.Loader) !void {
        self.refreshes += 1;
        capture(&self.captured_loader_base, base);
        self.captured_loader_kind = kind;
    }
};
fn capture(buffer: []u8, s: []const u8) void {
    @memset(buffer, 0);
    @memcpy(buffer[0..s.len], s);
}
fn string(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}
fn storeFixture() !config.Store {
    return .{ .a = std.testing.allocator, .io = std.testing.io, .root = "", .file = "", .state = try std.json.parseFromSlice(config.Document, std.testing.allocator,
        \\{"instances":[{"id":"first","name":"First","minecraft_version":"1.21.1","loader":"fabric","loader_version":"0.16.0","origin":{"kind":"modrinth","project_id":"project","version_id":"release"}},{"id":"second","name":"Second","minecraft_version":"1.20.1"}]}
    , .{ .allocate = .alloc_always }) };
}

test "deferred loader retry refreshes only its owned pending intent" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.mode = .create;
    ui.create_step = .loader;
    ui.draft.base = try std.testing.allocator.dupe(u8, "1.21.1");
    ui.browse_loader = .neoforge;

    ui.queue(.load_loaders, null);
    try std.testing.expect(ui.pending != null);
    try std.testing.expect(!ui.pending.?.force_refresh);
    try std.testing.expectEqual(@as(usize, 0), manager.loads);
    try std.testing.expectEqual(@as(usize, 0), manager.refreshes);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.loads);
    try std.testing.expectEqual(@as(usize, 0), manager.refreshes);
    try std.testing.expectEqualStrings("1.21.1", string(&manager.captured_loader_base));
    try std.testing.expectEqual(config.Loader.neoforge, manager.captured_loader_kind);
    try std.testing.expect(ui.pending == null);
    try std.testing.expect(ui.failure == null);

    ui.queue(.load_loaders, null);
    ui.pending.?.force_refresh = true;
    try std.testing.expectEqual(view.Action.load_loaders, ui.pending.?.action);
    try std.testing.expect(ui.pending.?.force_refresh);
    try std.testing.expectEqual(@as(usize, 1), manager.loads);
    try std.testing.expectEqual(@as(usize, 0), manager.refreshes);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.loads);
    try std.testing.expectEqual(@as(usize, 1), manager.refreshes);
    try std.testing.expectEqualStrings("1.21.1", string(&manager.captured_loader_base));
    try std.testing.expectEqual(config.Loader.neoforge, manager.captured_loader_kind);
    try std.testing.expect(ui.pending == null);
    try std.testing.expect(ui.failure == null);

    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.loads);
    try std.testing.expectEqual(@as(usize, 1), manager.refreshes);
    ui.queue(.load_loaders, null);
    try std.testing.expect(!ui.pending.?.force_refresh);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 2), manager.loads);
    try std.testing.expectEqual(@as(usize, 1), manager.refreshes);
    try std.testing.expect(ui.pending == null);
}

test "view declarations stay lazy without DVUI or production manager" {
    _ = view.Ui;
    _ = view.Draft;
    _ = view.finish;
}
test "owned draft copies all instance strings and survives source mutation" {
    var store = try storeFixture();
    defer store.state.deinit();
    var draft = try view.Draft.fromInstance(std.testing.allocator, store.snapshot().instances[0]);
    defer draft.deinit(std.testing.allocator);
    const source = store.snapshot().instances[0];
    try std.testing.expect(draft.id.?.ptr != source.id.ptr);
    try std.testing.expect(draft.base.?.ptr != source.minecraft_version.ptr);
    try std.testing.expect(draft.loader_version.?.ptr != source.loader_version.?.ptr);
    try std.testing.expect(draft.origin.?.project_id.ptr != source.origin.?.project_id.ptr);
    try std.testing.expect(draft.origin.?.version_id.ptr != source.origin.?.version_id.ptr);
    @constCast(source.minecraft_version)[0] = '9';
    try std.testing.expectEqualStrings("1.21.1", draft.base.?);
    try std.testing.expectEqualStrings("First", string(&draft.name));
}
test "edit select and options mutate only during finish and retain failed draft" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.edit, "first");
    try std.testing.expectEqual(view.Mode.none, ui.mode);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    capture(&ui.draft.java_path, "/jdk/bin/java");
    capture(&ui.draft.memory, "4096");
    ui.draft.debug_launch = true;
    manager.fail_save = true;
    ui.queue(.submit, null);
    try std.testing.expectEqual(@as(usize, 0), manager.saves);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.DiskFailure, ui.failure.?);
    try std.testing.expectEqualStrings("/jdk/bin/java", string(&ui.draft.java_path));
    manager.fail_save = false;
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(?u32, 4096), manager.captured_memory);
    try std.testing.expect(manager.captured_debug);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    var id = [_]u8{ 's', 'e', 'c', 'o', 'n', 'd' };
    ui.queue(.select, &id);
    id[0] = 'X';
    try std.testing.expectEqual(@as(usize, 0), manager.selects);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqualStrings("second", store.snapshot().selected_instance.?);
}
test "secure 128 bit stable draft id is retained across installation retries" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{ .fail_start = true };
    ui.queue(.create, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 41), ui.draft.id.?.len);
    try std.testing.expect(std.mem.startsWith(u8, ui.draft.id.?, "instance-"));
    for (ui.draft.id.?[9..]) |ch| try std.testing.expect(std.ascii.isHex(ch));
    const original_id = try std.testing.allocator.dupe(u8, ui.draft.id.?);
    defer std.testing.allocator.free(original_id);
    capture(&ui.draft.name, "Portable");
    ui.queue(.choose_base, "1.21.1");
    view.finishWithManager(&ui, &store, &manager);
    ui.queue(.next_step, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.CreateStep.loader, ui.create_step);
    ui.queue(.next_step, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.CreateStep.confirm, ui.create_step);
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.InstallAdapterUnavailable, ui.failure.?);
    try std.testing.expectEqualStrings(original_id, ui.draft.id.?);
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 2), manager.starts);
    try std.testing.expectEqualStrings(original_id, string(&manager.captured_id));
    try std.testing.expectEqualStrings("Portable", string(&ui.draft.name));
    var other: view.Draft = .{};
    defer other.deinit(std.testing.allocator);
    try other.ensureId(std.testing.allocator, std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, original_id, other.id.?));
}
test "base and loader selection copy borrowed catalogues and defer replacement" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.create, null);
    view.finishWithManager(&ui, &store, &manager);
    var base = [_]u8{ '1', '.', '2', '1' };
    ui.queue(.choose_base, &base);
    base[0] = '9';
    try std.testing.expect(ui.draft.base == null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqualStrings("1.21", ui.draft.base.?);
    ui.queue(.next_step, null);
    view.finishWithManager(&ui, &store, &manager);
    ui.queue(.choose_loader, "0.16.0");
    ui.pending.?.kind = .fabric;
    view.finishWithManager(&ui, &store, &manager);
    const previous = ui.draft.loader_version.?;
    ui.queue(.previous_step, null);
    view.finishWithManager(&ui, &store, &manager);
    ui.queue(.choose_base, "1.20.1");
    try std.testing.expectEqualStrings("0.16.0", previous);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.draft.loader_version == null);
}
test "failed publication is latched until explicit retry without per frame disk attempts" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{ .phase = .awaiting_publication, .task_id = 39, .fail_publish = true };
    var snapshot = taskSnapshot(39);
    snapshot.phase = .awaiting_publication;
    view.syncTaskSnapshot(&ui, snapshot);
    ui.draft.id = try std.testing.allocator.dupe(u8, "stable-id");
    ui.mode = .create;
    ui.submitted = true;
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.publishes);
    for (0..8) |_| view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.publishes);
    try std.testing.expectEqualStrings("stable-id", ui.draft.id.?);
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 2), manager.publishes);
    manager.fail_publish = false;
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 3), manager.publishes);
    try std.testing.expectEqual(view.Mode.none, ui.mode);
    try std.testing.expect(ui.failure == null);
}
test "settings rename submits once without second confirmation and keeps failures inline" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.edit, "first");
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.name, "Renamed");
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.renames);
    try std.testing.expect(ui.submitted);
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.renames);
    manager.phase = .failed;
    manager.operation = .renaming;
    manager.task_id = 99;
    manager.failure = error.InvalidInstallReceipt;
    view.syncTaskSnapshot(&ui, manager.snapshot());
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.InvalidInstallReceipt, ui.failure.?);
    try std.testing.expect(!ui.submitted and !ui.task.visible);
    try std.testing.expectEqualStrings("Renamed", string(&ui.draft.name));
}

test "settings rename publication retry stays in form and retains exact task identity" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.edit, "first");
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.name, "Renamed");
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    manager.operation = .renaming;
    manager.task_id = 100;
    manager.phase = .awaiting_publication;
    manager.fail_publish = true;
    view.syncTaskSnapshot(&ui, manager.snapshot());
    view.finishWithManager(&ui, &store, &manager);
    view.syncTaskSnapshot(&ui, manager.snapshot());
    try std.testing.expect(ui.task_can_retry and ui.submitted and !ui.task.visible);
    try std.testing.expectEqual(error.DiskFailure, ui.failure.?);
    manager.fail_publish = false;
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    view.syncTaskSnapshot(&ui, manager.snapshot());
    try std.testing.expect(ui.failure == null and !ui.submitted and !ui.task.visible);
    try std.testing.expectEqual(@as(usize, 2), manager.publishes);
}
fn expectNoBackendCalls(manager: FixtureManager) !void {
    try std.testing.expectEqual(@as(usize, 0), manager.selects);
    try std.testing.expectEqual(@as(usize, 0), manager.saves);
    try std.testing.expectEqual(@as(usize, 0), manager.starts);
    try std.testing.expectEqual(@as(usize, 0), manager.publishes);
    try std.testing.expectEqual(@as(usize, 0), manager.renames);
    try std.testing.expectEqual(@as(usize, 0), manager.rename_options_starts);
    try std.testing.expectEqual(@as(usize, 0), manager.deletes);
    try std.testing.expectEqual(@as(usize, 0), manager.loads);
    try std.testing.expectEqual(@as(usize, 0), manager.refreshes);
    try std.testing.expectEqual(@as(usize, 0), manager.connections);
    try std.testing.expectEqual(@as(usize, 0), manager.cancellations);
}

test "portable case folded names and strict optional memory validation" {
    var store = try storeFixture();
    defer store.state.deinit();
    try std.testing.expectError(error.DuplicateInstanceName, view.validateName(store.snapshot(), "fIRST", null));
    try view.validateName(store.snapshot(), "first", "first");
    for ([_][]const u8{ "", "../escape", "/absolute", "name/child", "name\\child", "CON", "trailing.", "trailing " }) |name| try std.testing.expectError(error.InvalidInstanceName, view.validateName(store.snapshot(), name, null));
    try std.testing.expectEqual(@as(?u32, null), try view.parseMemory(""));
    try std.testing.expectEqual(@as(?u32, 256), try view.parseMemory("256"));
    try std.testing.expectEqual(@as(?u32, 1048576), try view.parseMemory("1048576"));
    for ([_][]const u8{ "0", "255", "1048577", "4294967296", "-1", "+512", "512 ", "1.5", "MiB" }) |memory| try std.testing.expectError(error.InvalidMemory, view.parseMemory(memory));
}
test "delete waits for explicit confirmation and can be dismissed" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.ask_delete, "first");
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.delete_confirm, ui.mode);
    try std.testing.expectEqual(@as(usize, 0), manager.deletes);
    ui.queue(.close, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    try std.testing.expectEqual(@as(usize, 0), manager.deletes);
    ui.queue(.ask_delete, "first");
    view.finishWithManager(&ui, &store, &manager);
    ui.queue(.confirm, null);
    try std.testing.expectEqual(@as(usize, 0), manager.deletes);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.deletes);
}
test "awaiting publication preserves the draft even when manager is not busy" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.edit, "first");
    view.finishWithManager(&ui, &store, &manager);
    manager.phase = .awaiting_publication;
    manager.task_id = 40;
    manager.fail_publish = true;
    var snapshot = taskSnapshot(40);
    snapshot.phase = .awaiting_publication;
    view.syncTaskSnapshot(&ui, snapshot);
    try std.testing.expect(!manager.isBusy());
    ui.queue(.create, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    try std.testing.expectEqualStrings("first", ui.draft.id.?);
    try std.testing.expectEqual(@as(anyerror, error.Busy), ui.failure.?);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.publication_failed);
    try std.testing.expectEqual(@as(usize, 1), manager.publishes);
    ui.queue(.edit, "second");
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqualStrings("first", ui.draft.id.?);
    try std.testing.expectEqual(@as(usize, 1), manager.publishes);
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.publication_failed);
    try std.testing.expectEqual(@as(usize, 2), manager.publishes);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 2), manager.publishes);
}

test "selected installed form initializes once and semantic memory comparison ignores leading zeroes" {
    var store = try storeFixture();
    defer store.state.deinit();
    store.state.value.selected_instance = "first";
    @constCast(store.state.value.instances)[0].max_memory_mb = 2048;
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    const owned_id = ui.draft.id.?.ptr;
    capture(&ui.draft.memory, "02048");
    try std.testing.expect(!ui.draft.dirty());
    for (0..3) |_| view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.draft.id.?.ptr == owned_id);
    try std.testing.expectEqualStrings("02048", string(&ui.draft.memory));
    capture(&ui.draft.memory, "invalid");
    try std.testing.expect(ui.draft.dirty());
}

test "create draft jumps directly to installed selection and clean installed draft switches without prompt" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.create, null);
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.name, "Incomplete create");
    ui.queue(.select, "first");
    try std.testing.expect(store.snapshot().selected_instance == null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
    try std.testing.expect(ui.navigation == null and !ui.navigation_prompt);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    ui.queue(.select, "second");
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqualStrings("second", ui.draft.id.?);
    try std.testing.expect(ui.navigation == null and manager.saves == 0);
}

test "dirty installed navigation prompts before mutation and Cancel retains draft focus and selection" {
    for ([_]view.Action{ .select, .create, .leave }) |action| {
        var store = try storeFixture();
        defer store.state.deinit();
        var ui = view.Ui.init(std.testing.allocator);
        defer ui.deinit();
        var manager: FixtureManager = .{};
        ui.queue(.select, "first");
        view.finishWithManager(&ui, &store, &manager);
        capture(&ui.draft.name, "Changed first");
        capture(&ui.draft.java_path, "/edited/java");
        capture(&ui.draft.min_memory, "512");
        ui.form_focus = 42;
        ui.form_subwindow = 7;
        const serial = ui.navigation_serial;
        ui.queue(action, if (action == .select) "second" else null);
        view.finishWithManager(&ui, &store, &manager);
        try std.testing.expect(ui.navigation_prompt and ui.navigation != null);
        try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
        try std.testing.expect(manager.saves == 0 and manager.renames == 0 and manager.selects == 1);
        try std.testing.expectEqual(serial, ui.navigation_serial);
        ui.queue(.cancel_navigation, null);
        view.finishWithManager(&ui, &store, &manager);
        try std.testing.expect(ui.navigation == null and !ui.navigation_prompt and ui.restore_form_focus);
        try std.testing.expectEqual(@as(?u64, 42), ui.form_focus);
        try std.testing.expectEqual(@as(?u64, 7), ui.form_subwindow);
        try std.testing.expectEqualStrings("Changed first", string(&ui.draft.name));
        try std.testing.expectEqualStrings("/edited/java", string(&ui.draft.java_path));
        try std.testing.expectEqualStrings("512", string(&ui.draft.min_memory));
        try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
        ui.queue(action, if (action == .select) "second" else null);
        view.finishWithManager(&ui, &store, &manager);
        ui.queue(.discard_navigation, null);
        view.finishWithManager(&ui, &store, &manager);
        try std.testing.expect(ui.navigation == null and !ui.navigation_prompt);
        try std.testing.expectEqual(serial + 1, ui.navigation_serial);
        try std.testing.expect(manager.saves == 0 and manager.renames == 0);
        switch (action) {
            .select => try std.testing.expectEqualStrings("second", store.snapshot().selected_instance.?),
            .create => try std.testing.expectEqual(view.Mode.create, ui.mode),
            .leave => try std.testing.expect(ui.exit_requested),
            else => unreachable,
        }
    }
}

test "Save before navigation failure retains destination and draft then success saves before switching" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.select, "first");
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.java_path, "/updated/java");
    capture(&ui.draft.min_memory, "1024");
    capture(&ui.draft.memory, "4096");
    ui.draft.debug_launch = true;
    var destination = "second".*;
    ui.queue(.select, &destination);
    @memset(&destination, 'x');
    view.finishWithManager(&ui, &store, &manager);
    manager.fail_save = true;
    ui.queue(.save_navigation, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.DiskFailure, ui.failure.?);
    try std.testing.expect(ui.navigation_prompt and ui.navigation != null);
    try std.testing.expectEqualStrings("second", ui.navigation.?.text.?);
    try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
    try std.testing.expect(store.snapshot().instances[0].java_path == null);
    try std.testing.expectEqualStrings("/updated/java", string(&ui.draft.java_path));
    try std.testing.expectEqualStrings("1024", string(&ui.draft.min_memory));
    try std.testing.expect(store.snapshot().instances[0].min_memory_mb == null);
    for (0..3) |_| view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.saves);
    manager.fail_save = false;
    ui.queue(.save_navigation, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.failure == null and ui.navigation == null);
    try std.testing.expectEqualStrings("second", store.snapshot().selected_instance.?);
    try std.testing.expectEqualStrings("/updated/java", store.snapshot().instances[0].java_path.?);
    try std.testing.expectEqual(@as(?u32, 1024), store.snapshot().instances[0].min_memory_mb);
    try std.testing.expectEqual(@as(?u32, 4096), store.snapshot().instances[0].max_memory_mb);
    try std.testing.expectEqual(@as(?u32, 1024), manager.captured_min_memory);
    try std.testing.expect(store.snapshot().instances[0].debug_launch);
}

test "combined rename and options save navigates only after successful publication and explicit retry" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.select, "first");
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.name, "Renamed first");
    capture(&ui.draft.java_path, "/combined/java");
    capture(&ui.draft.min_memory, "2048");
    capture(&ui.draft.memory, "8192");
    ui.draft.debug_launch = true;
    ui.queue(.select, "second");
    view.finishWithManager(&ui, &store, &manager);
    ui.queue(.save_navigation, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.renames);
    try std.testing.expectEqual(@as(usize, 0), manager.saves);
    try std.testing.expectEqualStrings("/combined/java", string(&manager.captured_java));
    try std.testing.expectEqual(@as(?u32, 2048), manager.captured_min_memory);
    try std.testing.expectEqual(@as(?u32, 8192), manager.captured_memory);
    try std.testing.expect(manager.captured_debug);
    try std.testing.expect(ui.submitted and ui.saving_navigation and ui.navigation != null);
    try std.testing.expectEqualStrings("First", store.snapshot().instances[0].name);
    try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
    manager.phase = .awaiting_publication;
    manager.task_id = 42;
    manager.fail_publish = true;
    var snapshot = taskSnapshot(42);
    snapshot.phase = .awaiting_publication;
    view.syncTaskSnapshot(&ui, snapshot);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.publication_failed and ui.navigation != null);
    try std.testing.expectEqualStrings("Renamed first", string(&ui.draft.name));
    try std.testing.expectEqualStrings("/combined/java", string(&ui.draft.java_path));
    try std.testing.expectEqualStrings("2048", string(&ui.draft.min_memory));
    try std.testing.expectEqualStrings("8192", string(&ui.draft.memory));
    try std.testing.expect(ui.draft.debug_launch and ui.draft.dirty());
    try std.testing.expect(store.snapshot().instances[0].min_memory_mb == null);
    try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
    for (0..4) |_| view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.publishes);
    manager.fail_publish = false;
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.navigation == null and ui.failure == null);
    try std.testing.expectEqualStrings("second", store.snapshot().selected_instance.?);
    const saved = store.snapshot().instances[0];
    try std.testing.expectEqualStrings("Renamed first", saved.name);
    try std.testing.expectEqualStrings("/combined/java", saved.java_path.?);
    try std.testing.expectEqual(@as(?u32, 2048), saved.min_memory_mb);
    try std.testing.expectEqual(@as(?u32, 8192), saved.max_memory_mb);
    try std.testing.expect(saved.debug_launch);
    try std.testing.expectEqualStrings("first", saved.id);
    try std.testing.expectEqualStrings("project", saved.origin.?.project_id);
    try std.testing.expectEqualStrings("0.16.0", saved.loader_version.?);
}

test "external options edit invalidates original draft and keeps queued navigation" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.select, "first");
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.memory, "4096");
    ui.queue(.create, null);
    view.finishWithManager(&ui, &store, &manager);
    @constCast(store.state.value.instances)[0].debug_launch = true;
    ui.queue(.save_navigation, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.InstanceChanged, ui.failure.?);
    try std.testing.expect(ui.navigation_prompt and ui.navigation != null);
    try std.testing.expect(manager.saves == 0 and manager.renames == 0);
    try std.testing.expectEqualStrings("4096", string(&ui.draft.memory));
}

test "minimum memory draft copies saved value and preserves original baseline" {
    var store = try storeFixture();
    defer store.state.deinit();
    const source = &@constCast(store.state.value.instances)[0];
    source.java_path = "/saved/java";
    source.min_memory_mb = 512;
    source.max_memory_mb = 4096;
    source.debug_launch = true;
    var draft = try view.Draft.fromInstance(std.testing.allocator, source.*);
    defer draft.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("512", string(&draft.min_memory));
    try std.testing.expectEqual(@as(?u32, 512), draft.original_min_memory);
    source.min_memory_mb = 1024;
    capture(&draft.name, "Edited first");
    capture(&draft.java_path, "/edited/java");
    capture(&draft.min_memory, "2048");
    capture(&draft.memory, "8192");
    draft.debug_launch = false;
    const original = try draft.original();
    try std.testing.expectEqualStrings("First", original.name);
    try std.testing.expectEqualStrings("/saved/java", original.java_path.?);
    try std.testing.expectEqual(@as(?u32, 512), original.min_memory_mb);
    try std.testing.expectEqual(@as(?u32, 4096), original.max_memory_mb);
    try std.testing.expect(original.debug_launch);
    const edited = try draft.value(.options, store.snapshot());
    try std.testing.expectEqualStrings("Edited first", edited.name);
    try std.testing.expectEqualStrings("/edited/java", edited.java_path.?);
    try std.testing.expectEqual(@as(?u32, 2048), edited.min_memory_mb);
    try std.testing.expectEqual(@as(?u32, 8192), edited.max_memory_mb);
    try std.testing.expect(!edited.debug_launch);
}

test "minimum memory dirty comparison is numeric and distinguishes blank invalid and changed values" {
    var store = try storeFixture();
    defer store.state.deinit();
    @constCast(store.state.value.instances)[0].min_memory_mb = 512;
    var draft = try view.Draft.fromInstance(std.testing.allocator, store.snapshot().instances[0]);
    defer draft.deinit(std.testing.allocator);
    capture(&draft.min_memory, "000512");
    try std.testing.expect(!draft.dirty());
    for ([_][]const u8{ "513", "", "invalid", "000", "4294967296" }) |minimum| {
        capture(&draft.min_memory, minimum);
        try std.testing.expect(draft.dirty());
        try std.testing.expectEqual(@as(?u32, 512), (try draft.original()).min_memory_mb);
    }
    capture(&draft.min_memory, "512");
    try std.testing.expect(!draft.dirty());
    var defaults = try view.Draft.fromInstance(std.testing.allocator, store.snapshot().instances[1]);
    defer defaults.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", string(&defaults.min_memory));
    try std.testing.expect(defaults.original_min_memory == null and !defaults.dirty());
    capture(&defaults.min_memory, "256");
    try std.testing.expect(defaults.dirty());
    capture(&defaults.min_memory, "");
    try std.testing.expect(!defaults.dirty());
    try std.testing.expect((try defaults.original()).min_memory_mb == null);
}

test "installed footer Cancel restores all saved fields while delete dismissal retains the draft" {
    var store = try storeFixture();
    defer store.state.deinit();
    const saved = &@constCast(store.state.value.instances)[0];
    saved.java_path = "/saved/java";
    saved.min_memory_mb = 512;
    saved.max_memory_mb = 4096;
    saved.debug_launch = true;
    store.state.value.selected_instance = "first";
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.name, "Unsaved name");
    capture(&ui.draft.java_path, "/unsaved/java");
    capture(&ui.draft.min_memory, "1024");
    capture(&ui.draft.memory, "8192");
    ui.draft.debug_launch = false;
    ui.queue(.ask_delete, "first");
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.delete_confirm, ui.mode);
    ui.queue(.close, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    try std.testing.expect(ui.draft.dirty());
    try std.testing.expectEqualStrings("Unsaved name", string(&ui.draft.name));
    try std.testing.expectEqualStrings("/unsaved/java", string(&ui.draft.java_path));
    try std.testing.expectEqualStrings("1024", string(&ui.draft.min_memory));
    try std.testing.expectEqualStrings("8192", string(&ui.draft.memory));
    try std.testing.expect(!ui.draft.debug_launch);
    ui.queue(.close, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    try std.testing.expectEqualStrings("first", ui.draft.id.?);
    try std.testing.expectEqualStrings("First", string(&ui.draft.name));
    try std.testing.expectEqualStrings("/saved/java", string(&ui.draft.java_path));
    try std.testing.expectEqualStrings("512", string(&ui.draft.min_memory));
    try std.testing.expectEqualStrings("4096", string(&ui.draft.memory));
    try std.testing.expectEqual(@as(?u32, 512), ui.draft.original_min_memory);
    try std.testing.expect(ui.draft.debug_launch and !ui.draft.dirty());
    try std.testing.expectEqualStrings("first", store.snapshot().selected_instance.?);
    try std.testing.expectEqual(@as(?u32, 512), saved.min_memory_mb);
    try expectNoBackendCalls(manager);
    ui.draft.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(view.Draft{}, ui.draft);
}

test "minimum memory validates against explicit maximum or the default when maximum is blank" {
    var store = try storeFixture();
    defer store.state.deinit();
    store.state.value.settings.default_memory_mb = 2048;
    var draft = try view.Draft.fromInstance(std.testing.allocator, store.snapshot().instances[0]);
    defer draft.deinit(std.testing.allocator);
    const Case = struct { minimum: []const u8, maximum: []const u8, valid: bool, min_value: ?u32 = null, max_value: ?u32 = null };
    for ([_]Case{
        .{ .minimum = "", .maximum = "", .valid = true },
        .{ .minimum = "256", .maximum = "", .valid = true, .min_value = 256 },
        .{ .minimum = "02048", .maximum = "", .valid = true, .min_value = 2048 },
        .{ .minimum = "2049", .maximum = "", .valid = false },
        .{ .minimum = "4096", .maximum = "", .valid = false },
        .{ .minimum = "4096", .maximum = "4096", .valid = true, .min_value = 4096, .max_value = 4096 },
        .{ .minimum = "4096", .maximum = "4095", .valid = false },
        .{ .minimum = "256", .maximum = "256", .valid = true, .min_value = 256, .max_value = 256 },
        .{ .minimum = "1048576", .maximum = "1048576", .valid = true, .min_value = 1048576, .max_value = 1048576 },
        .{ .minimum = "", .maximum = "256", .valid = true, .max_value = 256 },
    }) |case| {
        capture(&draft.min_memory, case.minimum);
        capture(&draft.memory, case.maximum);
        if (case.valid) {
            const value = try draft.value(.options, store.snapshot());
            try std.testing.expectEqual(case.min_value, value.min_memory_mb);
            try std.testing.expectEqual(case.max_value, value.max_memory_mb);
        } else try std.testing.expectError(error.InvalidMemory, draft.value(.options, store.snapshot()));
    }
    capture(&draft.memory, "1048576");
    for ([_][]const u8{ "0", "255", "1048577", "4294967296", "-1", "+512", "512 ", "1.5", "MiB" }) |minimum| {
        capture(&draft.min_memory, minimum);
        try std.testing.expectError(error.InvalidMemory, draft.value(.options, store.snapshot()));
    }
}

test "installed options save persists and clears optional minimum memory" {
    var store = try storeFixture();
    defer store.state.deinit();
    store.state.value.selected_instance = "first";
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.min_memory, "00512");
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.failure == null and !ui.draft.dirty());
    try std.testing.expectEqual(@as(usize, 1), manager.saves);
    try std.testing.expectEqual(@as(?u32, 512), manager.captured_min_memory);
    try std.testing.expectEqual(@as(?u32, 512), store.snapshot().instances[0].min_memory_mb);
    try std.testing.expectEqual(@as(?u32, 512), ui.draft.original_min_memory);
    capture(&ui.draft.min_memory, "");
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 2), manager.saves);
    try std.testing.expect(manager.captured_min_memory == null);
    try std.testing.expect(store.snapshot().instances[0].min_memory_mb == null);
    try std.testing.expect(ui.draft.original_min_memory == null and !ui.draft.dirty());
    try std.testing.expectEqualStrings("", string(&ui.draft.min_memory));
}

test "installed footer Save combines name Java minimum maximum and debug and retains failed start" {
    var store = try storeFixture();
    defer store.state.deinit();
    store.state.value.selected_instance = "first";
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{ .fail_start = true };
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.name, "Saved together");
    capture(&ui.draft.java_path, "/combined/java");
    capture(&ui.draft.min_memory, "1024");
    capture(&ui.draft.memory, "4096");
    ui.draft.debug_launch = true;
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.WorkerUnavailable, ui.failure.?);
    try std.testing.expect(!ui.submitted and ui.draft.dirty());
    try std.testing.expectEqualStrings("Saved together", string(&ui.draft.name));
    try std.testing.expectEqualStrings("/combined/java", string(&ui.draft.java_path));
    try std.testing.expectEqualStrings("1024", string(&ui.draft.min_memory));
    try std.testing.expectEqualStrings("4096", string(&ui.draft.memory));
    try std.testing.expect(ui.draft.debug_launch);
    try std.testing.expectEqual(@as(usize, 1), manager.rename_options_starts);
    for (0..4) |_| view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.rename_options_starts);
    try std.testing.expectEqual(@as(usize, 0), manager.renames);
    try std.testing.expectEqual(@as(usize, 0), manager.saves);
    try std.testing.expectEqualStrings("First", store.snapshot().instances[0].name);
    try std.testing.expect(store.snapshot().instances[0].min_memory_mb == null);
    manager.fail_start = false;
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.submitted and ui.failure == null);
    try std.testing.expectEqual(@as(usize, 1), manager.renames);
    try std.testing.expectEqual(@as(usize, 2), manager.rename_options_starts);
    try std.testing.expectEqual(@as(usize, 0), manager.saves);
    try std.testing.expectEqualStrings("Saved together", string(&manager.captured_name));
    try std.testing.expectEqualStrings("/combined/java", string(&manager.captured_java));
    try std.testing.expectEqual(@as(?u32, 1024), manager.captured_min_memory);
    try std.testing.expectEqual(@as(?u32, 4096), manager.captured_memory);
    try std.testing.expect(manager.captured_debug);
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.Busy, ui.failure.?);
    try std.testing.expectEqual(@as(usize, 1), manager.renames);
    manager.phase = .awaiting_publication;
    view.finishWithManager(&ui, &store, &manager);
    const saved = store.snapshot().instances[0];
    try std.testing.expectEqualStrings("Saved together", saved.name);
    try std.testing.expectEqualStrings("/combined/java", saved.java_path.?);
    try std.testing.expectEqual(@as(?u32, 1024), saved.min_memory_mb);
    try std.testing.expectEqual(@as(?u32, 4096), saved.max_memory_mb);
    try std.testing.expect(saved.debug_launch);
    try std.testing.expectEqual(@as(?u32, 1024), ui.draft.original_min_memory);
    try std.testing.expect(!ui.draft.dirty() and !ui.submitted and ui.failure == null);
}

test "external minimum memory edit invalidates the saved baseline and retains queued navigation" {
    var store = try storeFixture();
    defer store.state.deinit();
    @constCast(store.state.value.instances)[0].min_memory_mb = 512;
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.select, "first");
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.min_memory, "768");
    ui.queue(.leave, null);
    view.finishWithManager(&ui, &store, &manager);
    @constCast(store.state.value.instances)[0].min_memory_mb = 1024;
    ui.queue(.save_navigation, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.InstanceChanged, ui.failure.?);
    try std.testing.expect(ui.navigation_prompt and ui.navigation != null);
    try std.testing.expectEqual(view.Action.leave, ui.navigation.?.action);
    try std.testing.expectEqual(view.Mode.options, ui.mode);
    try std.testing.expectEqualStrings("768", string(&ui.draft.min_memory));
    try std.testing.expectEqual(@as(?u32, 512), ui.draft.original_min_memory);
    try std.testing.expectEqual(@as(?u32, 1024), store.snapshot().instances[0].min_memory_mb);
    try std.testing.expect(manager.saves == 0 and manager.renames == 0);
}

fn taskSnapshot(id: u64) @import("application/instances_manager.zig").Snapshot {
    return .{
        .task_id = id,
        .phase = .working,
        .operation = .creating,
        .instance = .{ .id = "task-instance", .name = "Task instance", .minecraft_version = "1.21.1" },
        .failure = null,
        .recovery_directory = null,
        .completed = 2,
        .total = 4,
        .details = .{ .stage = .downloading, .completed = 2, .total = 4, .received = 1024, .total_bytes = 2048, .bytes_per_second = 512 },
    };
}

test "working task cannot dismiss and explicit cancellation closes without resetting the draft" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.edit, "first");
    view.finishWithManager(&ui, &store, &manager);
    capture(&ui.draft.name, "Unsaved name");
    const before = ui.draft;
    manager.phase = .working;
    manager.task_id = 17;
    view.syncTaskSnapshot(&ui, taskSnapshot(17));
    ui.queue(.close_task, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.task.visible);
    try std.testing.expectEqual(@as(usize, 0), manager.cancellations);
    try std.testing.expectEqualDeep(before, ui.draft);
    ui.queue(.cancel, null);
    try std.testing.expect(ui.task.visible);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.cancellations);
    try std.testing.expect(!ui.task.visible);
    try std.testing.expectEqualDeep(before, ui.draft);
    view.syncTaskSnapshot(&ui, taskSnapshot(17));
    try std.testing.expect(!ui.task.visible);
}

test "task identity retains terminal result without reopening and opens the next operation" {
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var snapshot = taskSnapshot(21);
    snapshot.details.addFile(@import("core/tasks.zig").File.init("libraries/example.jar", 1024, 2048, 512, .downloading, null));
    view.syncTaskSnapshot(&ui, snapshot);
    ui.task.visible = false;
    snapshot.phase = .failed;
    snapshot.failure = error.ConnectionResetByPeer;
    snapshot.durability_uncertain = true;
    snapshot.recovery_directory = "/tmp/retained-recovery";
    view.syncTaskSnapshot(&ui, snapshot);
    try std.testing.expect(!ui.task.visible);
    try std.testing.expectEqual(error.ConnectionResetByPeer, ui.task.failure.?);
    try std.testing.expectEqual(@as(f64, 0), ui.task.details.bytes_per_second);
    try std.testing.expectEqual(@as(f64, 0), ui.task.details.files[0].bytes_per_second);
    try std.testing.expectEqual(@as(u64, 1024), ui.task.details.files[0].received);
    try std.testing.expectEqualStrings("example.jar", ui.task.details.files[0].name());
    try std.testing.expectEqualStrings("/tmp/retained-recovery", ui.task.recovery_directory.?);
    try std.testing.expect(ui.task.durability_uncertain);
    snapshot.phase = .canceled;
    view.syncTaskSnapshot(&ui, snapshot);
    try std.testing.expect(!ui.task.visible);
    snapshot.phase = .complete;
    snapshot.failure = null;
    view.syncTaskSnapshot(&ui, snapshot);
    try std.testing.expect(!ui.task.visible);
    view.syncTaskSnapshot(&ui, taskSnapshot(22));
    try std.testing.expect(ui.task.visible and ui.task.failure == null);
    try std.testing.expectEqual(@as(?u64, 22), ui.task.task_id);
    try std.testing.expect(ui.task.recovery_directory == null);
}

test "retained task text and file details own their bytes across source mutation and loader jobs" {
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var name = [_]u8{ 'N', 'a', 'm', 'e' };
    var recovery = [_]u8{ '/', 't', 'm', 'p' };
    var snapshot = taskSnapshot(31);
    snapshot.instance.?.name = &name;
    snapshot.recovery_directory = &recovery;
    snapshot.details.addFile(@import("core/tasks.zig").File.init("assets/object.bin", 4, 8, 100, .downloading, null));
    view.syncTaskSnapshot(&ui, snapshot);
    @memset(&name, 'x');
    @memset(&recovery, 'y');
    snapshot.details.files[0] = .{};
    try std.testing.expectEqualStrings("Name", ui.task.instance_name.?);
    try std.testing.expectEqualStrings("/tmp", ui.task.recovery_directory.?);
    try std.testing.expectEqualStrings("object.bin", ui.task.details.files[0].name());
    snapshot.operation = .loading_loaders;
    snapshot.task_id = 32;
    view.syncTaskSnapshot(&ui, snapshot);
    try std.testing.expectEqual(@as(?u64, 31), ui.task.task_id);
    try std.testing.expect(!ui.task_can_cancel and !ui.task_can_retry);
    try std.testing.expectEqualStrings("Name", ui.task.instance_name.?);
}

test "form validation stays in the form while attempted slow-operation admission errors open details" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    ui.queue(.create, null);
    view.finishWithManager(&ui, &store, &manager);
    ui.create_step = .confirm;
    ui.draft.base = try ui.allocator.dupe(u8, "1.21.1");
    capture(&ui.draft.name, "First");
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(error.DuplicateInstanceName, ui.failure.?);
    try std.testing.expect(!ui.task.available() and !ui.task.visible);
    try std.testing.expectEqual(@as(usize, 0), manager.starts);
    capture(&ui.draft.name, "New instance");
    manager.fail_start = true;
    ui.queue(.submit, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.task.visible and ui.task.admission_failure);
    try std.testing.expectEqual(error.InstallAdapterUnavailable, ui.task.failure.?);
    try std.testing.expectEqualStrings("New instance", ui.task.instance_name.?);
    try std.testing.expect(ui.task.task_id == null);
    try std.testing.expectEqual(view.Mode.create, ui.mode);
    try std.testing.expect(!ui.submitted);
}

test "publication failure waits in front until explicit retry and completion acknowledgement" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{ .phase = .awaiting_publication, .task_id = 41, .fail_publish = true };
    view.finishWithManager(&ui, &store, &manager);
    var snapshot = taskSnapshot(41);
    snapshot.phase = .awaiting_publication;
    view.syncTaskSnapshot(&ui, snapshot);
    try std.testing.expect(ui.task_can_retry);
    try std.testing.expectEqual(error.DiskFailure, ui.task.failure.?);
    ui.queue(.close_task, null);
    view.finishWithManager(&ui, &store, &manager);
    view.syncTaskSnapshot(&ui, snapshot);
    try std.testing.expect(ui.task.visible);
    try std.testing.expectEqual(error.DiskFailure, ui.failure.?);
    try std.testing.expectEqual(@as(usize, 1), manager.publishes);
    manager.fail_publish = false;
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 2), manager.publishes);
    try std.testing.expect(!ui.publication_failed);
    snapshot.phase = .complete;
    view.syncTaskSnapshot(&ui, snapshot);
    try std.testing.expect(ui.task.visible and ui.task.failure == null and !ui.task_can_retry);
    ui.queue(.close_task, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(!ui.task.visible);
}

test "admission failure remains readable until a new task identity and progress clamps known totals" {
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    view.syncTaskSnapshot(&ui, taskSnapshot(51));
    ui.task.failAdmission(ui.allocator, .renaming, "Attempted rename", error.WorkerUnavailable);
    view.syncTaskSnapshot(&ui, taskSnapshot(51));
    try std.testing.expectEqual(error.WorkerUnavailable, ui.task.failure.?);
    try std.testing.expectEqualStrings("Attempted rename", ui.task.instance_name.?);
    try std.testing.expect(ui.task.task_id == null and !ui.task_can_cancel);
    view.syncTaskSnapshot(&ui, taskSnapshot(52));
    try std.testing.expect(ui.task.visible and !ui.task.admission_failure and ui.task.failure == null);
    const percent = @import("ui/instance_task_view.zig").percent;
    try std.testing.expectEqual(@as(?f64, 100), percent(9, 4));
    try std.testing.expectEqual(@as(?f64, 50), percent(2, 4));
    try std.testing.expect(percent(0, null) == null and percent(0, 0) == null);
}

test "task terminal states stay visible until manual acknowledgement" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    for ([_]@import("application/instances_manager.zig").Phase{ .complete, .failed, .canceled }, 0..) |phase, index| {
        var snapshot = taskSnapshot(60 + index);
        view.syncTaskSnapshot(&ui, snapshot);
        snapshot.phase = phase;
        snapshot.failure = if (phase == .failed) error.SizeMismatch else null;
        view.syncTaskSnapshot(&ui, snapshot);
        try std.testing.expect(ui.task.visible);
        ui.queue(.close_task, null);
        view.finishWithManager(&ui, &store, &manager);
        try std.testing.expect(!ui.task.visible);
        view.syncTaskSnapshot(&ui, snapshot);
        try std.testing.expect(!ui.task.visible);
    }
}

test "cancel stays available when source page is hidden and task identity must match" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{ .phase = .working, .task_id = 72 };
    view.syncTaskSnapshot(&ui, taskSnapshot(71));
    ui.mode = .none;
    ui.queue(.cancel, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.task.visible and manager.cancellations == 0);
    manager.task_id = 71;
    ui.queue(.cancel, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(!ui.task.visible and manager.cancellations == 1);
    try std.testing.expectEqual(view.Mode.none, ui.mode);
}

test "queued cancel after worker completion keeps publication error and acknowledgement accessible" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{ .phase = .awaiting_publication, .task_id = 81, .fail_publish = true };
    view.syncTaskSnapshot(&ui, taskSnapshot(81));
    ui.publication_failed = true;
    ui.failure = error.DiskFailure;
    ui.queue(.cancel, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.task.visible and manager.cancellations == 0);
    try std.testing.expectEqual(error.DiskFailure, ui.failure.?);
    var snapshot = taskSnapshot(81);
    snapshot.phase = .awaiting_publication;
    view.syncTaskSnapshot(&ui, snapshot);
    try std.testing.expect(ui.task_can_retry and ui.task.visible);
    try std.testing.expectEqual(error.DiskFailure, ui.task.failure.?);
    manager.phase = .complete;
    ui.queue(.cancel, null);
    view.finishWithManager(&ui, &store, &manager);
    snapshot.phase = .complete;
    view.syncTaskSnapshot(&ui, snapshot);
    try std.testing.expect(ui.task.visible and manager.cancellations == 0);
}

test "compact task byte and speed formatting caps units at MB and stops invalid speeds" {
    const task = @import("ui/instance_task_view.zig");
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", try task.formatBytes(&buffer, 0));
    try std.testing.expectEqualStrings("1023 B", try task.formatBytes(&buffer, 1023));
    try std.testing.expectEqualStrings("1.0 KB", try task.formatBytes(&buffer, 1024));
    try std.testing.expectEqualStrings("1.5 KB", try task.formatBytes(&buffer, 1536));
    try std.testing.expectEqualStrings("2.0 MB", try task.formatBytes(&buffer, 2 * 1024 * 1024));
    try std.testing.expectEqualStrings("2048.0 MB", try task.formatBytes(&buffer, 2 * 1024 * 1024 * 1024));
    try std.testing.expectEqualStrings("512 B/s", try task.formatSpeed(&buffer, 512, true));
    try std.testing.expectEqualStrings("512.0 KB/s", try task.formatSpeed(&buffer, 512 * 1024, true));
    try std.testing.expectEqualStrings("2.0 MB/s", try task.formatSpeed(&buffer, 2 * 1024 * 1024, true));
    try std.testing.expectEqualStrings("0 B/s", try task.formatSpeed(&buffer, 0, true));
    for ([_]f64{ -1, std.math.nan(f64), std.math.inf(f64) }) |speed| try std.testing.expectEqualStrings("—", try task.formatSpeed(&buffer, speed, true));
    try std.testing.expectEqualStrings("—", try task.formatSpeed(&buffer, 512, false));
    _ = try task.formatBytes(&buffer, std.math.maxInt(u64));
}

test "task filename extraction handles both separators and progress fraction clamps edge totals" {
    const task = @import("ui/instance_task_view.zig");
    try std.testing.expectEqualStrings("example.jar", task.basename("libraries/net/example.jar"));
    const windows_path = [_]u8{ 'C', ':', 92, 'l', 'i', 'b', 92, 'a', '.', 'j', 'a', 'r' };
    try std.testing.expectEqualStrings("a.jar", task.basename(&windows_path));
    try std.testing.expectEqualStrings("文件.jar", task.basename("assets/文件.jar/"));
    try std.testing.expectEqualStrings("a.jar", task.basename("a.jar"));
    try std.testing.expectEqualStrings("", task.basename(""));
    try std.testing.expectEqual(@as(f32, 0), task.fraction(200, null));
    try std.testing.expectEqual(@as(f32, 0), task.fraction(1, 0));
    try std.testing.expectEqual(@as(f32, 0.5), task.fraction(1, 2));
    try std.testing.expectEqual(@as(f32, 1), task.fraction(200, 20));
    try std.testing.expectEqual(@as(f32, 1), task.fraction(std.math.maxInt(u64), std.math.maxInt(u64)));
}

test "publication retry rejects stale task identity and finishes from a hidden source page" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{ .phase = .awaiting_publication, .task_id = 92 };
    var snapshot = taskSnapshot(91);
    snapshot.phase = .awaiting_publication;
    ui.publication_failed = true;
    ui.failure = error.DiskFailure;
    view.syncTaskSnapshot(&ui, snapshot);
    ui.mode = .none;
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 0), manager.publishes);
    try std.testing.expectEqual(error.NoPendingPublication, ui.failure.?);
    try std.testing.expect(ui.task.visible);
    manager.task_id = 91;
    manager.phase = .complete;
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 0), manager.publishes);
    try std.testing.expectEqual(error.NoPendingPublication, ui.failure.?);
    manager.phase = .awaiting_publication;
    ui.queue(.retry_publication, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.publishes);
    try std.testing.expect(!ui.publication_failed);
    snapshot.phase = .complete;
    view.syncTaskSnapshot(&ui, snapshot);
    try std.testing.expect(ui.task.visible);
    try std.testing.expectEqual(view.Mode.none, ui.mode);
}

const FixturePreflight = struct {
    value: @import("application/instances_manager.zig").Snapshot = taskSnapshot(101),
    starts: usize = 0,
    publishes: usize = 0,
    cancels: usize = 0,
    fail_start: bool = false,
    fail_publish: bool = false,
    captured_java: [4097]u8 = @splat(0),
    pub fn startOrdinary(self: *FixturePreflight, instance: config.Instance, _: void) !void {
        self.starts += 1;
        if (self.fail_start) return error.InstallAdapterUnavailable;
        capture(&self.captured_java, instance.java_path orelse "");
        self.value = taskSnapshot(self.value.task_id.? + 1);
        self.value.details = .{ .stage = .metadata };
    }
    pub fn creationSnapshot(self: *FixturePreflight) @import("application/instances_manager.zig").Snapshot {
        return self.value;
    }
    pub fn cancel(self: *FixturePreflight, _: void) void {
        self.cancels += 1;
    }
    pub fn publishOrdinary(self: *FixturePreflight, _: void, allowed: bool) !void {
        if (!allowed) return error.MutationsDisabled;
        self.publishes += 1;
        if (self.fail_publish) return error.DiskFailure;
        self.value.phase = .complete;
    }
};

fn prepareOrdinaryUi(ui: *view.Ui, store: *config.Store, manager: *FixtureManager) !void {
    ui.queue(.create, null);
    view.finishWithManager(ui, store, manager);
    ui.create_step = .confirm;
    ui.draft.base = try ui.allocator.dupe(u8, "1.21.1");
    capture(&ui.draft.name, "Ordinary instance");
}

test "ordinary preflight keeps one foreground identity through Java and artifacts with manual Close" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    var controller: FixturePreflight = .{};
    try prepareOrdinaryUi(&ui, &store, &manager);
    capture(&ui.draft.java_path, "/manual/java");
    ui.queue(.submit, null);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    try std.testing.expect(ui.creation_active and ui.submitted and ui.task.visible and ui.task_can_cancel);
    try std.testing.expectEqual(@as(usize, 0), manager.starts);
    try std.testing.expectEqualStrings("/manual/java", string(&controller.captured_java));
    const task_id = ui.task.task_id;
    controller.value.details = .{ .stage = .downloading, .received = 4096, .total_bytes = 8192 };
    manager.task_id = 900;
    manager.phase = .working;
    ui.mode = .none;
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    try std.testing.expectEqual(task_id, ui.task.task_id);
    try std.testing.expect(ui.task.visible and ui.task_can_cancel);
    try std.testing.expectEqual(@as(u64, 4096), ui.task.details.received);
    controller.value.phase = .awaiting_publication;
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    try std.testing.expectEqual(@as(usize, 1), controller.publishes);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    try std.testing.expect(!ui.creation_active and !ui.submitted);
    try std.testing.expect(ui.task.visible and ui.task.phase == .complete);
    ui.queue(.close_task, null);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    view.syncTaskSnapshot(&ui, controller.value);
    try std.testing.expect(!ui.task.visible);
}

test "ordinary cancel hides foreground without discarding draft and mutation gate blocks queued actions" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    var controller: FixturePreflight = .{};
    try prepareOrdinaryUi(&ui, &store, &manager);
    ui.queue(.submit, null);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, false);
    try std.testing.expectEqual(@as(usize, 0), controller.starts);
    ui.queue(.submit, null);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    const draft_id = ui.draft.id.?;
    ui.queue(.cancel, null);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, false);
    try std.testing.expect(controller.cancels == 0 and ui.task.visible);
    ui.queue(.cancel, null);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    try std.testing.expect(controller.cancels == 1 and !ui.task.visible);
    controller.value.phase = .canceled;
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    try std.testing.expect(!ui.submitted and !ui.creation_active and !ui.task.visible);
    try std.testing.expectEqualStrings(draft_id, ui.draft.id.?);
    try std.testing.expectEqualStrings("Ordinary instance", string(&ui.draft.name));
}

test "ordinary publication waits for explicit matching retry and never publishes while mutations disabled" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    var controller: FixturePreflight = .{ .fail_publish = true };
    try prepareOrdinaryUi(&ui, &store, &manager);
    ui.queue(.submit, null);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    controller.value.phase = .awaiting_publication;
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, false);
    try std.testing.expectEqual(@as(usize, 0), controller.publishes);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    try std.testing.expectEqual(@as(usize, 1), controller.publishes);
    try std.testing.expect(ui.publication_failed and ui.task.visible and ui.task_can_retry);
    controller.value.task_id = 103;
    ui.queue(.retry_publication, null);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    try std.testing.expectEqual(@as(usize, 1), controller.publishes);
    try std.testing.expectEqual(error.NoPendingPublication, ui.failure.?);
    controller.fail_publish = false;
    ui.queue(.retry_publication, null);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    try std.testing.expectEqual(@as(usize, 2), controller.publishes);
    try std.testing.expect(!ui.publication_failed and ui.failure == null);
}

test "ordinary form failures stay local and admission failures keep original error" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{};
    var controller: FixturePreflight = .{ .fail_start = true };
    try prepareOrdinaryUi(&ui, &store, &manager);
    capture(&ui.draft.name, "First");
    ui.queue(.submit, null);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    try std.testing.expectEqual(error.DuplicateInstanceName, ui.failure.?);
    try std.testing.expect(controller.starts == 0 and !ui.task.available());
    capture(&ui.draft.name, "Ordinary instance");
    ui.queue(.submit, null);
    view.finishWithPreflight(&ui, &store, &manager, &controller, {}, true);
    try std.testing.expectEqual(error.InstallAdapterUnavailable, ui.task.failure.?);
    try std.testing.expect(ui.task.visible and ui.task.admission_failure and !ui.submitted);
}

test "catalogue navigation waits for cancellation and retains the pending destination" {
    var store = try storeFixture();
    defer store.state.deinit();
    var ui = view.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var manager: FixtureManager = .{ .phase = .working, .operation = .loading_loaders };
    ui.mode = .create;
    ui.create_step = .loader;
    ui.draft.base = try std.testing.allocator.dupe(u8, "1.21.1");
    ui.queue(.previous_step, null);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expectEqual(@as(usize, 1), manager.cancellations);
    try std.testing.expect(ui.pending != null);
    try std.testing.expectEqual(view.CreateStep.loader, ui.create_step);
    view.finishWithManager(&ui, &store, &manager);
    try std.testing.expect(ui.pending == null);
    try std.testing.expectEqual(view.CreateStep.version, ui.create_step);
}

test "submitted worker failures retain the draft and restore unsaved navigation" {
    for ([_]Phase{ .failed, .canceled }) |phase| {
        var store = try storeFixture();
        defer store.state.deinit();
        var ui = view.Ui.init(std.testing.allocator);
        defer ui.deinit();
        var manager: FixtureManager = .{};
        ui.queue(.edit, "first");
        view.finishWithManager(&ui, &store, &manager);
        capture(&ui.draft.name, "Updated name");
        ui.queue(.select, "second");
        view.finishWithManager(&ui, &store, &manager);
        ui.queue(.save_navigation, null);
        view.finishWithManager(&ui, &store, &manager);
        try std.testing.expect(ui.submitted and ui.saving_navigation and ui.navigation != null);
        manager.phase = phase;
        manager.failure = if (phase == .failed) error.WorkerUnavailable else error.Canceled;
        view.finishWithManager(&ui, &store, &manager);
        try std.testing.expect(!ui.submitted and !ui.saving_navigation);
        try std.testing.expect(ui.navigation != null and ui.navigation_prompt);
        try std.testing.expectEqual(manager.failure.?, ui.failure.?);
        try std.testing.expectEqualStrings("Updated name", string(&ui.draft.name));
        try std.testing.expectEqual(@as(usize, 0), manager.selects);
    }
}
