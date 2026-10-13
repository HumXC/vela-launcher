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
        .tvg = true,
    });
    const module = b.createModule(.{
        .root_source_file = b.path("src/instance_task_layout_tests.zig"),
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
    module.addImport("nbt", b.dependency("nbt", .{ .target = target, .optimize = optimize }).module("nbt"));
    module.addImport("nbt_compression", b.createModule(.{
        .root_source_file = b.path("src/core/worlds_gzip.zig"),
        .target = target,
        .optimize = optimize,
    }));
    module.addImport("test_allocations", b.createModule(.{ .root_source_file = b.path("src/test_allocations.zig") }));
    if (target.result.os.tag == .linux)
        module.addImport("linux_c", @import("build-support/linux_c.zig").create(b, target, optimize));
    const filter = b.option([]const u8, "test-filter", "Run a focused instance task modal regression") orelse "instance task modal";
    const tests = b.addTest(.{ .root_module = module, .filters = &.{filter} });
    const run = b.addRunArtifact(tests);
    b.default_step.dependOn(&run.step);
}
