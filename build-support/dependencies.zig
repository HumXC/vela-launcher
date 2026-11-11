//! Shared dependency policy. Root modules always own their mutable build containers.
const std = @import("std");
const linux_c = @import("linux_c.zig");

pub fn curl(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Dependency {
    const dependency = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .link_vendor = true,
        .mbedtls_pthreads = target.result.os.tag == .linux or target.result.os.tag.isDarwin(),
    });
    // A fresh configuration may not have fetched the C-binding dependencies yet.
    if (target.result.os.tag == .windows and b.graph.needed_lazy_dependencies.count() == 0)
        disableWindowsTranslationFortify(dependency.module("curl").import_table.get("c").?);
    return dependency;
}

pub const Core = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    curl_dep: *std.Build.Dependency,
    nbt_dep: *std.Build.Dependency,
    compression: *std.Build.Module,
    linux: ?*std.Build.Module,
    cache_hash: *std.Build.Module,
    server_icon_native: *std.Build.Step.Compile,

    pub fn init(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Core {
        return .{
            .b = b,
            .target = target,
            .optimize = optimize,
            .curl_dep = curl(b, target, optimize),
            .nbt_dep = b.dependency("nbt", .{ .target = target, .optimize = optimize }),
            .compression = b.createModule(.{ .root_source_file = b.path("src/core/worlds_gzip.zig"), .target = target, .optimize = optimize }),
            .linux = if (target.result.os.tag == .linux) linux_c.create(b, target, optimize) else null,
            .cache_hash = createCacheHash(b, target),
            .server_icon_native = createServerIcon(b, target, optimize),
        };
    }

    pub fn createModule(self: Core, source: std.Build.LazyPath) *std.Build.Module {
        const module = self.b.createModule(.{
            .root_source_file = source,
            .target = self.target,
            .optimize = self.optimize,
            .imports = &.{
                .{ .name = "curl", .module = self.curl_dep.module("curl") },
                .{ .name = "nbt", .module = self.nbt_dep.module("nbt") },
                .{ .name = "nbt_compression", .module = self.compression },
                .{ .name = "cache_hash", .module = self.cache_hash },
            },
        });
        if (self.linux) |bindings| module.addImport("linux_c", bindings);
        linkNetworkPlatform(module, self.target);
        module.linkLibrary(self.server_icon_native);
        return module;
    }
};

fn createServerIcon(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const vendor = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3, .@"tree-sitter" = false });
    const module = b.createModule(.{ .target = target, .optimize = .ReleaseSafe, .link_libc = true });
    module.addIncludePath(vendor.path("vendor/stb"));
    module.addCSourceFile(.{ .file = b.path("src/core/server_icon_stb.c"), .flags = &.{"-std=c11"} });
    return b.addLibrary(.{ .name = "vela-server-icon", .linkage = .static, .root_module = module });
}

fn createCacheHash(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    const kernels = b.addLibrary(.{ .name = "vela-cache-hash", .linkage = .static, .root_module = b.createModule(.{ .root_source_file = b.path("src/core/cache_hash_backend.zig"), .target = target, .optimize = .ReleaseSafe }) });
    const api = b.createModule(.{ .root_source_file = b.path("src/core/cache_hash.zig"), .target = target });
    api.linkLibrary(kernels);
    return api;
}

/// Native proxy discovery and credential storage are shared by every transport.
pub fn linkNetworkPlatform(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .windows => {
            module.linkSystemLibrary("winhttp", .{});
            module.linkSystemLibrary("advapi32", .{});
            module.linkSystemLibrary("kernel32", .{});
            module.linkSystemLibrary("iphlpapi", .{});
        },
        .macos => {
            module.linkFramework("Security", .{});
            module.linkFramework("CoreFoundation", .{});
            module.linkFramework("CFNetwork", .{});
        },
        else => {},
    }
}

pub const App = struct {
    core: Core,
    dvui: *std.Build.Module,
    sdk: ?[]const u8,

    pub fn createModule(self: App, source: std.Build.LazyPath) *std.Build.Module {
        const module = self.core.createModule(source);
        module.addImport("dvui", self.dvui);
        if (self.core.target.result.os.tag == .macos) {
            module.linkFramework("Security", .{});
            module.linkFramework("CoreFoundation", .{});
        }
        // Shared dependency graphs receive SDK translation paths once at setup.
        // Each new root still needs its own include/framework/link search paths.
        if (self.sdk) |sdk| {
            const b = self.core.b;
            module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
            module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            module.addLibraryPath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/lib" })));
        }
        return module;
    }
};

pub fn disableWindowsTranslationFortify(module: *std.Build.Module) void {
    const source = module.root_source_file orelse @panic("C binding module has no source");
    const generated = switch (source) {
        .generated => |generated| generated,
        else => @panic("C binding module is not generated"),
    };
    const step = module.owner.graph.generated_files.items[@backingInt(generated.index)];
    if (step.cast(std.Build.Step.TranslateC)) |translate| {
        translate.defineCMacro("_FORTIFY_SOURCE", "0");
    } else if (step.cast(std.Build.Step.Run)) |translate| {
        translate.addArg("-D_FORTIFY_SOURCE=0");
    } else @panic("C binding module is not generated by a C translator");
}
