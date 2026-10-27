const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filter = b.option([]const u8, "test-filter", "Run a focused testing-renderer test group") orelse "UI layout";
    const core = @import("build-support/dependencies.zig").Core.init(b, target, optimize);
    b.default_step.dependOn(&addTests(b, core, filter).step);
}

pub fn addTests(b: *std.Build, core: @import("build-support/dependencies.zig").Core, filter: []const u8) *std.Build.Step.Run {
    const target = core.target;
    const optimize = core.optimize;
    const dvui = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .testing,
        .libc = true,
        .freetype = false,
        .@"tiny-file-dialogs" = false,
        .@"stb-image" = true,
        .@"tree-sitter" = false,
        // Match the native icon renderer so tests can inspect real check meshes.
        .tvg = true,
    });
    const module = core.createModule(b.path("src/ui_layout_tests.zig"));
    module.addImport("dvui", dvui.module("dvui_testing"));
    @import("build-support/webp.zig").link(b, target, optimize, module);
    module.addImport("test_allocations", b.createModule(.{ .root_source_file = b.path("src/test_allocations.zig") }));
    const tests = b.addTest(.{ .root_module = module, .filters = &.{filter} });
    return b.addRunArtifact(tests);
}
