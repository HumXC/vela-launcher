const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dvui = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .testing,
        .libc = true,
        .freetype = false,
        .@"tiny-file-dialogs" = false,
        .@"stb-image" = true,
        .@"tree-sitter" = false,
        .tvg = false,
    });
    const module = b.createModule(.{
        .root_source_file = b.path("src/ui_layout_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("dvui", dvui.module("dvui_testing"));
    const curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .link_vendor = true,
        .mbedtls_pthreads = target.result.os.tag == .linux or target.result.os.tag.isDarwin(),
    });
    module.addImport("curl", curl.module("curl"));
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    module.addImport("zio", zio.module("zio"));
    const nbt = b.dependency("nbt", .{ .target = target, .optimize = optimize });
    module.addImport("nbt", nbt.module("nbt"));
    module.addImport("nbt_compression", b.createModule(.{
        .root_source_file = b.path("src/core/worlds_gzip.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const filter = b.option([]const u8, "test-filter", "Run a focused testing-renderer test group") orelse "UI layout";
    const tests = b.addTest(.{ .root_module = module, .filters = &.{filter} });
    const run = b.addRunArtifact(tests);
    b.default_step.dependOn(&run.step);
}
