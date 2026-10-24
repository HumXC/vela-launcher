//! SDL 3.4.16 software textured triangles omit premultiplied blend modes.
//! Generate a corrected translation unit in the build cache; never mutate packages.
const std = @import("std");

pub fn apply(b: *std.Build, root: *std.Build.Module) void {
    const patcher = b.addExecutable(.{
        .name = "patch-sdl-software",
        .root_module = b.createModule(.{ .root_source_file = b.path("build-support/sdl_software.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }),
    });
    var pending: std.ArrayList(*std.Build.Module) = .empty;
    defer pending.deinit(b.allocator);
    var seen: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    defer seen.deinit(b.allocator);
    pending.append(b.allocator, root) catch @panic("OOM");
    var patched: usize = 0;
    while (pending.pop()) |module| {
        const entry = seen.getOrPut(b.allocator, module) catch @panic("OOM");
        if (entry.found_existing) continue;
        for (module.import_table.values()) |imported| pending.append(b.allocator, imported) catch @panic("OOM");
        var replacement: ?std.Build.Module.CSourceFile = null;
        for (module.link_objects.items) |object| switch (object) {
            .other_step => |compile| pending.append(b.allocator, compile.root_module) catch @panic("OOM"),
            .c_source_files => |group| {
                for (group.files, 0..) |file, index| {
                    if (!std.mem.eql(u8, file, "render/software/SDL_triangle.c")) continue;
                    const original = group.root.path(b, file);
                    const run = b.addRunArtifact(patcher);
                    run.addFileArg(original);
                    const corrected = run.addOutputFileArg("SDL_triangle.c");
                    replacement = .{ .file = corrected, .flags = group.flags, .language = group.language };
                    const files = b.allocator.alloc([]const u8, group.files.len - 1) catch @panic("OOM");
                    @memcpy(files[0..index], group.files[0..index]);
                    @memcpy(files[index..], group.files[index + 1 ..]);
                    group.files = files;
                    module.addIncludePath(original.dirname());
                    patched += 1;
                }
            },
            else => {},
        };
        if (replacement) |source| module.addCSourceFile(source);
    }
    if (patched == 0) @panic("Pinned SDL software triangle source was not found");
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedInputAndOutput;
    const a = init.arena.allocator();
    const original = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(128 * 1024));
    const mask = try replaceExact(a, original, "SDL_COPY_BLEND | SDL_COPY_ADD | SDL_COPY_MOD | SDL_COPY_MUL", "SDL_COPY_BLEND_MASK", 2);
    const over = try replaceExact(a, mask, "        case SDL_COPY_BLEND:\n", "        case SDL_COPY_BLEND_PREMULTIPLIED:\n        case SDL_COPY_BLEND:\n", 1);
    const add = try replaceExact(a, over, "        case SDL_COPY_ADD:\n", "        case SDL_COPY_ADD_PREMULTIPLIED:\n        case SDL_COPY_ADD:\n", 1);
    const output = try std.mem.concat(a, u8, &.{ "/* Vela patch: honor premultiplied blend modes in software textured triangles. */\n", add });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = output });
}

fn replaceExact(a: std.mem.Allocator, source: []const u8, before: []const u8, after: []const u8, count: usize) ![]u8 {
    if (std.mem.count(u8, source, before) != count) return error.PinnedSdlSourceChanged;
    return std.mem.replaceOwned(u8, a, source, before, after);
}
