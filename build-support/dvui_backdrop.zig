//! Persistent, fail-closed patch of the pinned DVUI renderer. Package sources stay immutable.
const std = @import("std");

pub fn apply(b: *std.Build, module: *std.Build.Module) void {
    const source = module.root_source_file.?.dirname();
    const patcher = b.addExecutable(.{ .name = "patch-dvui-backdrop", .root_module = b.createModule(.{
        .root_source_file = b.path("build-support/dvui_backdrop.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const run = b.addRunArtifact(patcher);
    run.addFileArg(source.path(b, "render.zig"));
    run.addFileArg(source.path(b, "Window.zig"));
    const render = run.addOutputFileArg("render.zig");
    const window = run.addOutputFileArg("Window.zig");
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(source, "", .{ .exclude_extensions = &.{ "render.zig", "Window.zig" } });
    _ = files.addCopyFile(render, "render.zig");
    _ = files.addCopyFile(window, "Window.zig");
    _ = files.addCopyFile(b.path("build-support/DeferredBackdrop.zig"), "DeferredBackdrop.zig");
    module.root_source_file = files.getDirectory().path(b, "dvui.zig");
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 5) return error.ExpectedTwoInputsAndOutputs;
    const render = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(1024 * 1024));
    const window = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], a, .limited(1024 * 1024));
    const patched_render = try replaceExact(a, render, "    pub const Command = union(enum) {", "    pub const Command = union(enum) {\n        backdrop: @import(\"DeferredBackdrop.zig\").Options,");
    const replay_window = try replaceExact(a, window, "        switch (drc.cmd) {", "        switch (drc.cmd) {\n            .backdrop => |options| @import(\"DeferredBackdrop.zig\").draw(options) catch |err| {\n                dvui.logError(@src(), err, \"Deferred backdrop failed\", .{});\n            },");
    const state_window = try replaceExact(a, replay_window, "\ngpa: std.mem.Allocator,", "\ndeferred_backdrop: @import(\"DeferredBackdrop.zig\").State = .{},\ngpa: std.mem.Allocator,");
    const lifecycle_window = try replaceExact(a, state_window, "pub fn deinit(self: *Self) void {", "pub fn deinit(self: *Self) void {\n    self.deferred_backdrop.deinit(self.gpa, self.backend);");
    const patched_window = try replaceExact(a, lifecycle_window, "pub fn endRendering(self: *Self, opts: endOptions) void {", "pub fn endRendering(self: *Self, opts: endOptions) void {\n    self.deferred_backdrop.begin();");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[3], .data = patched_render });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[4], .data = patched_window });
}

fn replaceExact(a: std.mem.Allocator, source: []const u8, before: []const u8, after: []const u8) ![]u8 {
    if (std.mem.count(u8, source, before) != 1) return error.PinnedDvuiSourceChanged;
    return std.mem.replaceOwned(u8, a, source, before, after);
}
