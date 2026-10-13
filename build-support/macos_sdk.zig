const std = @import("std");

/// SDK acquisition is separate: accept an existing SDK and validate its layout.
pub fn choose(b: *std.Build, target: std.Target.Os.Tag) ?[]const u8 {
    const supplied = b.option([]const u8, "macos-sdk", "Absolute path to an existing macOS SDK");
    if (target != .macos) return null;
    const root = supplied orelse
        @panic("macOS builds require an existing SDK: pass -Dmacos-sdk=/absolute/MacOSX.sdk");
    // SDK layout is inspected during configuration, outside the package graph.
    b.graph.poisonCache();
    if (!std.fs.path.isAbsolute(root) or std.mem.indexOfScalar(u8, root, 0) != null)
        @panic("macOS SDK path must be absolute and contain no NUL");
    const io = b.graph.io;
    for ([_][]const u8{ "usr/include", "usr/lib", "System/Library/Frameworks" }) |relative| {
        const path = b.pathJoin(&.{ root, relative });
        var directory = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| {
            std.debug.print("Invalid macOS SDK directory {s}: {s}\n", .{ path, @errorName(err) });
            @panic("macOS SDK layout is incomplete");
        };
        directory.close(io);
    }
    for ([_][]const u8{
        "usr/include/AvailabilityMacros.h",
        "usr/include/TargetConditionals.h",
        "usr/lib/libSystem.tbd",
        "System/Library/Frameworks/Foundation.framework/Foundation.tbd",
    }) |relative| {
        const path = b.pathJoin(&.{ root, relative });
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            std.debug.print("Invalid macOS SDK file {s}: {s}\n", .{ path, @errorName(err) });
            @panic("macOS SDK headers or link stubs are missing");
        };
        file.close(io);
    }
    return root;
}

/// Walk imports and linked C libraries, including generated C translations.
pub fn apply(b: *std.Build, root_module: *std.Build.Module, sdk: []const u8) void {
    var seen: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    defer seen.deinit(b.allocator);
    var pending: std.ArrayList(*std.Build.Module) = .empty;
    defer pending.deinit(b.allocator);
    pending.append(b.allocator, root_module) catch @panic("OOM");
    const include: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) };
    const frameworks: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) };
    const libraries = b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/lib" }));
    while (pending.pop()) |module| {
        const entry = seen.getOrPut(b.allocator, module) catch @panic("OOM");
        if (entry.found_existing) continue;
        if (module.resolved_target) |target| {
            if (target.result.os.tag == .macos) {
                module.addSystemIncludePath(include);
                module.addSystemFrameworkPath(frameworks);
                module.addLibraryPath(libraries);
                for (module.include_dirs.items) |directory| {
                    if (directory == .config_header_step) {
                        const header = directory.config_header_step;
                        if (std.mem.eql(u8, header.include_path, "SDL_build_config.h")) {
                            // SDL 3.4.16 removed these CMake keys; its Zig wrapper
                            // still sets them. Zig 0.17 rejects unused values.
                            for ([_][]const u8{ "HAVE_CALLOC", "HAVE_REALLOC", "HAVE_FREE", "HAVE_MPROTECT", "HAVE_SYSCTL" }) |key|
                                _ = header.values.swapRemove(key);
                        }
                    }
                }
            }
        }
        if (module.root_source_file) |source| {
            switch (source) {
                .generated => |generated| {
                    const step = b.graph.generated_files.items[@backingInt(generated.index)];
                    if (step.cast(std.Build.Step.TranslateC)) |translate| {
                        if (translate.target.result.os.tag == .macos) {
                            translate.addSystemIncludePath(include);
                            translate.addSystemFrameworkPath(frameworks);
                        }
                    } else if (step.cast(std.Build.Step.Run)) |translate| {
                        translate.addArg("-isystem");
                        translate.addDirectoryArg(include);
                        translate.addArg("-iframework");
                        translate.addDirectoryArg(frameworks);
                    }
                },
                else => {},
            }
        }
        for (module.import_table.values()) |imported|
            pending.append(b.allocator, imported) catch @panic("OOM");
        for (module.link_objects.items) |object| {
            switch (object) {
                .other_step => |compile| pending.append(b.allocator, compile.root_module) catch @panic("OOM"),
                else => {},
            }
        }
    }
}
