//! Conservative FreeType driver trimming; keep modern outlines, hinting and bitmap strikes.
//! Override the module registry in the build cache without modifying package sources.
const std = @import("std");

const removed_sources = [_][]const u8{
    "src/type1/type1.c", "src/cid/type1cid.c", "src/type42/type42.c",   "src/pfr/pfr.c",
    "src/bdf/bdf.c",     "src/pcf/pcf.c",      "src/winfonts/winfnt.c", "src/sdf/sdf.c",
};
const removed_modules = [_][]const u8{
    "FT_USE_MODULE( FT_Driver_ClassRec, t1_driver_class )",
    "FT_USE_MODULE( FT_Driver_ClassRec, t1cid_driver_class )",
    "FT_USE_MODULE( FT_Driver_ClassRec, t42_driver_class )",
    "FT_USE_MODULE( FT_Driver_ClassRec, pfr_driver_class )",
    "FT_USE_MODULE( FT_Driver_ClassRec, bdf_driver_class )",
    "FT_USE_MODULE( FT_Driver_ClassRec, pcf_driver_class )",
    "FT_USE_MODULE( FT_Driver_ClassRec, winfnt_driver_class )",
    "FT_USE_MODULE( FT_Renderer_Class, ft_sdf_renderer_class )",
    "FT_USE_MODULE( FT_Renderer_Class, ft_bitmap_sdf_renderer_class )",
};

pub fn apply(b: *std.Build, dvui: *std.Build.Module) void {
    var matched: usize = 0;
    for (dvui.link_objects.items) |object| switch (object) {
        .other_step => |lib| {
            if (!std.mem.eql(u8, lib.name, "freetype")) continue;
            trim(b, lib.root_module);
            matched += 1;
        },
        else => {},
    };
    if (matched != 1) @panic("Expected exactly one bundled FreeType library");
}

fn trim(b: *std.Build, module: *std.Build.Module) void {
    var counts: [removed_sources.len]usize = @splat(0);
    var root: ?std.Build.LazyPath = null;
    for (module.link_objects.items) |object| switch (object) {
        .c_source_files => |group| {
            var kept: std.ArrayList([]const u8) = .empty;
            for (group.files) |file| {
                var remove = false;
                for (removed_sources, 0..) |candidate, i| {
                    if (std.mem.eql(u8, candidate, file)) {
                        counts[i] += 1;
                        remove = true;
                        root = group.root;
                    }
                }
                if (!remove) kept.append(b.allocator, file) catch @panic("OOM");
            }
            group.files = kept.toOwnedSlice(b.allocator) catch @panic("OOM");
        },
        else => {},
    };
    for (counts) |count| if (count != 1) @panic("Pinned FreeType source list changed");
    const patcher = b.addExecutable(.{ .name = "trim-freetype-modules", .root_module = b.createModule(.{
        .root_source_file = b.path("build-support/freetype.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const run = b.addRunArtifact(patcher);
    run.addFileArg(root.?.path(b, "include/freetype/config/ftmodule.h"));
    const header = run.addOutputFileArg("vela_ftmodule.h");
    module.addIncludePath(header.dirname());
    module.addCMacro("FT_CONFIG_MODULES_H", "\"vela_ftmodule.h\"");
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.ExpectedInputAndOutput;
    var header = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(128 * 1024));
    for (removed_modules) |line| {
        if (std.mem.count(u8, header, line) != 1) return error.PinnedFreeTypeModulesChanged;
        header = try std.mem.replaceOwned(u8, a, header, line, "");
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = header });
}
