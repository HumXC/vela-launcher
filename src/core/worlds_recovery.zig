//! Enumerates retained recovery artifacts without claiming payload integrity.
const std = @import("std");
const w = @import("worlds.zig");
const tree = @import("worlds_tree.zig");
const config = @import("config.zig");
const instances = @import("instances.zig");
const A = std.mem.Allocator;
pub const Backup = struct {
    id: []const u8,
    part: @FieldType(w.BackupRef, "part"),
    directory: []const u8,
    source_folder: ?[]const u8 = null,
    source_instance: ?[]const u8 = null,
    operation: ?w.Operation = null,
    manifest_error: ?anyerror = null,
    created_ms: i64,
    pub fn deinit(self: *Backup, a: A) void {
        a.free(self.id);
        a.free(self.directory);
        if (self.source_folder) |s| a.free(s);
        if (self.source_instance) |s| a.free(s);
        self.* = undefined;
    }
};
pub const BackupList = struct {
    allocator: A,
    items: []Backup,
    pub fn deinit(self: *BackupList) void {
        for (self.items) |*b| b.deinit(self.allocator);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};
fn append(a: A, io: std.Io, items: *std.ArrayList(Backup), dir: std.Io.Dir, id: []const u8, part: @FieldType(w.BackupRef, "part"), directory: []const u8, options: w.Options) !void {
    const stat = try dir.stat(io);
    var item: Backup = .{ .id = try a.dupe(u8, id), .part = part, .directory = undefined, .created_ms = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)) };
    item.directory = a.dupe(u8, directory) catch |err| {
        a.free(item.id);
        return err;
    };
    errdefer item.deinit(a);
    const bytes = tree.readBounded(a, io, dir, "manifest.json", options.limits.max_manifest_bytes) catch |err| blk: {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        item.manifest_error = err;
        break :blk null;
    };
    if (bytes) |data| {
        defer a.free(data);
        const parsed = std.json.parseFromSlice(w.Manifest, a, data, .{ .allocate = .alloc_always }) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            item.manifest_error = err;
            break :blk null;
        };
        if (parsed) |value| {
            defer value.deinit();
            if (value.value.format != 1 or !config.validId(value.value.source_instance) or !w.validFolder(value.value.source_folder)) {
                item.manifest_error = error.InvalidManifest;
            } else {
                item.source_folder = try a.dupe(u8, value.value.source_folder);
                item.source_instance = try a.dupe(u8, value.value.source_instance);
                item.operation = value.value.operation;
            }
        }
    }
    try items.append(a, item);
}
fn less(_: void, x: Backup, y: Backup) bool {
    if (x.created_ms != y.created_ms) return x.created_ms > y.created_ms;
    return std.mem.lessThan(u8, x.id, y.id);
}
pub fn list(a: A, io: std.Io, paths: *const instances.Paths, instance: config.Instance, options: w.Options) !BackupList {
    try w.transaction_gate.lock(io);
    defer w.transaction_gate.unlock(io);
    if (!config.validId(instance.id) or !config.validId(instance.name)) return error.UnsafeInstance;
    const directory = try std.fs.path.join(a, &.{ paths.root, ".minecraft", "versions", instance.name, "saves", ".vela-worlds" });
    defer a.free(directory);
    const repo = tree.openAbsolute(io, directory) catch |err| switch (err) {
        error.FileNotFound => return .{ .allocator = a, .items = try a.alloc(Backup, 0) },
        else => return err,
    };
    defer repo.close(io);
    var items: std.ArrayList(Backup) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(a);
        items.deinit(a);
    }
    var iterator = repo.iterate();
    while (try iterator.next(io)) |entry| {
        try options.hooks.check(io);
        if (entry.kind != .directory or !w.validRecoveryId(entry.name)) continue;
        if (items.items.len >= options.limits.max_files) return error.ResourceLimit;
        const artifact = try tree.child(io, repo, entry.name, false);
        defer artifact.close(io);
        const path = try std.fs.path.join(a, &.{ directory, entry.name });
        defer a.free(path);
        try append(a, io, &items, artifact, entry.name, .original, path, options);
        const overwritten = tree.child(io, artifact, "overwritten", false) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer overwritten.close(io);
        if (items.items.len >= options.limits.max_files) return error.ResourceLimit;
        const nested_path = try std.fs.path.join(a, &.{ path, "overwritten" });
        defer a.free(nested_path);
        try append(a, io, &items, overwritten, entry.name, .overwritten, nested_path, options);
    }
    std.mem.sort(Backup, items.items, {}, less);
    return .{ .allocator = a, .items = try items.toOwnedSlice(a) };
}
