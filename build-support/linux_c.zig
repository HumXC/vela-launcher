const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const translated = Translator.init(b.dependency("translate_c", .{}), .{
        .name = "linux_c",
        .c_source_file = b.path("build-support/linux_c.h"),
        .target = target,
        .optimize = optimize,
    });
    return translated.mod;
}
