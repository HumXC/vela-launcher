const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filter = b.option([]const u8, "test-filter", "Run a focused testing-renderer test group") orelse "UI layout";
    b.default_step.dependOn(&addTests(b, target, optimize, filter).step);
}

pub fn addTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, filter: []const u8) *std.Build.Step.Run {
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
    const module = b.createModule(.{
        .root_source_file = b.path("src/ui_layout_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("dvui", dvui.module("dvui_testing"));
    @import("build-support/webp.zig").link(b, target, optimize, module);
    const curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .link_vendor = true,
        .mbedtls_pthreads = target.result.os.tag == .linux or target.result.os.tag.isDarwin(),
    });
    module.addImport("curl", curl.module("curl"));
    const nbt = b.dependency("nbt", .{ .target = target, .optimize = optimize });
    module.addImport("nbt", nbt.module("nbt"));
    module.addImport("nbt_compression", b.createModule(.{
        .root_source_file = b.path("src/core/worlds_gzip.zig"),
        .target = target,
        .optimize = optimize,
    }));
    module.addImport("test_allocations", b.createModule(.{ .root_source_file = b.path("src/test_allocations.zig") }));
    if (target.result.os.tag == .linux)
        module.addImport("linux_c", @import("build-support/linux_c.zig").create(b, target, optimize));
    const tests = b.addTest(.{ .root_module = module, .filters = &.{filter} });
    return b.addRunArtifact(tests);
}
