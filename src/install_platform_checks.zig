//! Compile-only reachability for the installation APIs; never link or execute these exports.
const std = @import("std");
const content = @import("core/content_install.zig");
const transactions = @import("core/instance_transactions.zig");
const config = @import("core/config.zig");
const java = @import("application/java_manager.zig");
const files = @import("core/loaders/files.zig");
const planner = @import("core/minecraft/install_plan.zig");
const metadata = @import("core/minecraft/metadata/root.zig");

export fn force_content_install(a: *const std.mem.Allocator, io: *const std.Io, options: *const content.Options) void {
    var report = content.execute(a.*, io.*, options.*) catch return;
    defer report.deinit();
}
export fn force_content_recovery(a: *const std.mem.Allocator, io: *const std.Io, options: *const content.RecoverOptions) void {
    var report = content.recover(a.*, io.*, options.*) catch return;
    defer report.deinit();
}
export fn force_instance_mutation(a: *const std.mem.Allocator, io: *const std.Io, path: [*]const u8, len: usize, instance: *const config.Instance, options: *const transactions.Options, rename: bool) void {
    var report = if (rename) transactions.rename(a.*, io.*, path[0..len], instance.*, "compile-only", options.*) catch return else transactions.remove(a.*, io.*, path[0..len], instance.*, options.*) catch return;
    defer report.deinit();
}
export fn force_java_registry(a: *const std.mem.Allocator, io: *const std.Io, path: [*]const u8, len: usize) void {
    const runtime = java.probe(a.*, io.*, path[0..len], null) catch return;
    defer a.free(runtime.path);
    defer a.free(runtime.vendor);
    var manager = java.Manager.init(a.*, io.*, path[0..len]) catch return;
    defer manager.deinit();
    manager.addDownloaded(runtime) catch {};
    _ = manager.resolve(runtime.major);
}
export fn force_loader_directory(io: *const std.Io, path: [*]const u8, len: usize) void {
    const dir = files.directory(io.*, path[0..len], true) catch return;
    defer dir.close(io.*);
}
export fn force_native_plan(a: *const std.mem.Allocator, version: *const metadata.version.Version, assets: *const metadata.asset_index.AssetIndex, environment: *const metadata.rules.Environment, directories: *const planner.Directories) void {
    var plan = planner.buildInstalled(a.*, version.*, assets.*, environment.*, directories.*) catch return;
    defer plan.deinit();
}
