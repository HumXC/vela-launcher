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
        .root_source_file = b.path("src/ui/curseforge_key_editor.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("dvui", dvui.module("dvui_testing"));
    const tests = b.addTest(.{ .root_module = module, .filters = &.{"CF key editor"} });
    const run = b.addRunArtifact(tests);
    b.default_step.dependOn(&run.step);
}
