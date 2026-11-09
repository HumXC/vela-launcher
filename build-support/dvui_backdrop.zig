//! Fail-closed patches of pinned DVUI rendering and theme fonts. Package sources stay immutable.
const std = @import("std");

pub fn apply(b: *std.Build, module: *std.Build.Module) void {
    const source = module.root_source_file.?.dirname();
    const patcher = b.addExecutable(.{ .name = "patch-dvui-backdrop", .root_module = b.createModule(.{
        .root_source_file = b.path("build-support/dvui_backdrop.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const run = b.addRunArtifact(patcher);
    run.addFileArg(source.path(b, "render.zig"));
    run.addFileArg(source.path(b, "Window.zig"));
    run.addFileArg(source.path(b, "themes/Adwaita.zig"));
    run.addFileArg(source.path(b, "Font.zig"));
    run.addFileArg(source.path(b, "FontCache.zig"));
    const render = run.addOutputFileArg("render.zig");
    const window = run.addOutputFileArg("Window.zig");
    const adwaita = run.addOutputFileArg("Adwaita.zig");
    const font = run.addOutputFileArg("Font.zig");
    const font_cache = run.addOutputFileArg("FontCache.zig");
    run.addFileArg(source.path(b, "widgets/MenuItemWidget.zig"));
    const menu_item = run.addOutputFileArg("MenuItemWidget.zig");
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(source, "", .{ .exclude_extensions = &.{ "render.zig", "Window.zig", "Adwaita.zig", "Font.zig", "FontCache.zig", "MenuItemWidget.zig" } });
    _ = files.addCopyFile(menu_item, "widgets/MenuItemWidget.zig");
    _ = files.addCopyFile(font, "Font.zig");
    _ = files.addCopyFile(font_cache, "FontCache.zig");
    _ = files.addCopyFile(adwaita, "themes/Adwaita.zig");
    _ = files.addCopyFile(render, "render.zig");
    _ = files.addCopyFile(window, "Window.zig");
    _ = files.addCopyFile(b.path("build-support/DeferredBackdrop.zig"), "DeferredBackdrop.zig");
    module.root_source_file = files.getDirectory().path(b, "dvui.zig");
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 13) return error.ExpectedSixInputsAndOutputs;
    const render = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(1024 * 1024));
    const window = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], a, .limited(1024 * 1024));
    const adwaita = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], a, .limited(1024 * 1024));
    // Both default themes otherwise retain ten Vera faces even when Vela loads a system font.
    // The final fallback uses the first validated system font registered by Vela.
    const embedded = ".embedded_fonts = fonts,";
    if (std.mem.count(u8, adwaita, embedded) != 2) return error.PinnedDvuiSourceChanged;
    const patched_adwaita = try std.mem.replaceOwned(u8, a, adwaita, embedded, ".embedded_fonts = &.{},");
    const font = try std.Io.Dir.cwd().readFileAlloc(init.io, args[4], a, .limited(1024 * 1024));
    const font_cache = try std.Io.Dir.cwd().readFileAlloc(init.io, args[5], a, .limited(1024 * 1024));
    const patched_font = try replaceExact(a, font, "    pub const fallback = Source{\n        .family = array(\"Vera\"),\n        .bytes = @embedFile(\"fonts/bitstream-vera/Vera.ttf\"),\n    };", "    pub fn fallback() Source {\n        const sources = dvui.currentWindow().fonts.database.items;\n        if (sources.len == 0) @panic(\"No system UI font registered\");\n        return sources[0];\n    }");
    if (std.mem.count(u8, font_cache, "Source.fallback") != 2) return error.PinnedDvuiSourceChanged;
    const dynamic_cache = try std.mem.replaceOwned(u8, a, font_cache, "Source.fallback", "Source.fallback()");
    const patched_cache = try replaceExact(a, dynamic_cache, "        return self.getOrCreate(gpa, Source.fallback().font());", "        const fallback_font = Source.fallback().font();\n        if (font.hash() == fallback_font.hash()) @panic(\"System fallback font could not be rendered\");\n        return self.getOrCreate(gpa, fallback_font);");
    const patched_render = try replaceExact(a, render, "    pub const Command = union(enum) {", "    pub const Command = union(enum) {\n        backdrop: @import(\"DeferredBackdrop.zig\").Options,");
    const replay_window = try replaceExact(a, window, "        switch (drc.cmd) {", "        switch (drc.cmd) {\n            .backdrop => |options| @import(\"DeferredBackdrop.zig\").draw(options) catch |err| {\n                dvui.logError(@src(), err, \"Deferred backdrop failed\", .{});\n            },");
    const state_window = try replaceExact(a, replay_window, "\ngpa: std.mem.Allocator,", "\ndeferred_backdrop: @import(\"DeferredBackdrop.zig\").State = .{},\ngpa: std.mem.Allocator,");
    const lifecycle_window = try replaceExact(a, state_window, "pub fn deinit(self: *Self) void {", "pub fn deinit(self: *Self) void {\n    self.deferred_backdrop.deinit(self.gpa, self.backend);");
    const patched_window = try replaceExact(a, lifecycle_window, "pub fn endRendering(self: *Self, opts: endOptions) void {", "pub fn endRendering(self: *Self, opts: endOptions) void {\n    self.deferred_backdrop.begin();");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[6], .data = patched_render });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[7], .data = patched_window });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[8], .data = patched_adwaita });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[9], .data = patched_font });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[10], .data = patched_cache });
    const menu_item = try std.Io.Dir.cwd().readFileAlloc(init.io, args[11], a, .limited(1024 * 1024));
    // Initialization owns border/shadow; drawBackground owns exactly one state fill.
    const outline_only = try replaceExact(a, menu_item, "    self.data().borderAndBackground(.{});", "    self.data().borderAndBackground(.{ .fill_color = .{ .color = dvui.Color.transparent } });");
    const single_fill = try replaceExact(a, outline_only, "                if (self.highlight) {\n                    rs.r.fill(cr, .{ .color = cols.color(.fill), .fade = 1.0 });\n                }", "                rs.r.fill(cr, .{ .color = cols.color(.fill), .fade = 1.0 });");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[12], .data = single_fill });
}

fn replaceExact(a: std.mem.Allocator, source: []const u8, before: []const u8, after: []const u8) ![]u8 {
    if (std.mem.count(u8, source, before) != 1) return error.PinnedDvuiSourceChanged;
    return std.mem.replaceOwned(u8, a, source, before, after);
}
