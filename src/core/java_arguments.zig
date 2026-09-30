//! Recognizes JVM option tokens before command merging. No Minecraft or downloader dependency.
//! Input is an already tokenized JVM-only section, excluding the executable and main class.
const std = @import("std");
const command = @import("command.zig");

/// Import in precedence order. Unknown options remain raw and are never implicitly overridden.
/// On error, preceding arguments remain imported; discard/rebuild the builder if desired.
pub fn append(builder: *command.Builder, tokens: []const []const u8) !void {
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (std.mem.eql(u8, token, "-jar") or std.mem.eql(u8, token, "-m") or
            std.mem.eql(u8, token, "--module") or std.mem.startsWith(u8, token, "--module="))
            return error.LaunchTargetNotAllowed;
        var recognized = false;
        for ([_][]const u8{ "-Xmx", "-Xms", "-Xss" }) |prefix| {
            if (std.mem.startsWith(u8, token, prefix)) {
                const value = token[prefix.len..];
                if (value.len == 0) return error.MissingValue;
                try builder.add(.{ .key = .{ .namespace = "java.option", .name = prefix }, .canonical = prefix, .arity = .value, .merge = .replace, .layout = .joined }, value);
                recognized = true;
                break;
            }
        }
        if (recognized) continue;
        if (std.mem.startsWith(u8, token, "-D")) {
            const property = token[2..];
            const end = std.mem.indexOfScalar(u8, property, '=') orelse property.len;
            if (end == 0) return error.EmptyPropertyName;
            // The spelling includes the key; the stored identity excludes the value.
            try builder.add(.{ .key = .{ .namespace = "java.property", .name = property[0..end] }, .canonical = token[0 .. 2 + end], .arity = .value, .merge = .replace, .layout = .eq }, if (end < property.len) property[end + 1 ..] else "");
            continue;
        }
        if (std.mem.startsWith(u8, token, "-XX:")) {
            const option = token[4..];
            if (option.len == 0) return error.MissingValue;
            const toggle = option[0] == '+' or option[0] == '-';
            const end = std.mem.indexOfScalar(u8, option, '=') orelse option.len;
            const name = if (toggle) option[1..] else option[0..end];
            if (name.len == 0 or (toggle and end != option.len)) return error.InvalidXXOption;
            if (!toggle and end == option.len) {
                try builder.addRaw(token);
                continue;
            }
            const merge: command.Merge = if (std.mem.eql(u8, name, "CompileCommand")) .append else .replace;
            try builder.add(.{ .key = .{ .namespace = "java.xx", .name = name }, .canonical = "-XX:", .arity = .value, .merge = merge, .layout = .joined }, option);
            continue;
        }
        if (std.mem.startsWith(u8, token, "-javaagent:")) {
            const value = token[11..];
            if (value.len == 0) return error.MissingValue;
            try builder.add(.{ .key = .{ .namespace = "java.option", .name = "javaagent" }, .canonical = "-javaagent", .arity = .value, .merge = .append, .layout = .colon }, value);
            continue;
        }
        if (std.mem.eql(u8, token, "-cp") or std.mem.eql(u8, token, "-classpath") or std.mem.eql(u8, token, "--class-path")) {
            i += 1;
            if (i == tokens.len) return error.MissingValue;
            try classPath(builder, tokens[i]);
            continue;
        }
        if (std.mem.startsWith(u8, token, "--class-path=")) {
            try classPath(builder, token[13..]);
            continue;
        }
        // Preserve operands of known separate options even when an operand looks
        // like a JVM option (for example a module path named "-Dfoo").
        for ([_][]const u8{ "-p", "--module-path", "--upgrade-module-path", "--add-modules", "--limit-modules", "--add-reads", "--add-exports", "--add-opens", "--patch-module", "--enable-native-access", "--source" }) |name| {
            if (std.mem.eql(u8, token, name)) {
                i += 1;
                if (i == tokens.len) return error.MissingValue;
                try builder.addRaw(token);
                try builder.addRaw(tokens[i]);
                recognized = true;
                break;
            }
        }
        if (!recognized) try builder.addRaw(token);
    }
}
fn classPath(builder: *command.Builder, value: []const u8) !void {
    try builder.add(.{ .key = .{ .namespace = "java.option", .name = "classpath" }, .canonical = "-cp", .arity = .value, .merge = .replace, .layout = .separate }, value);
}

test "JVM layers override dynamic keys and preserve repeated agent order" {
    const a = std.testing.allocator;
    var b = try command.Builder.init(a, "java");
    defer b.deinit();
    try append(&b, &.{ "-Xmx2G", "-Dfoo=one", "-Dbar=two", "-XX:+UseG1GC", "-javaagent:a.jar", "-Xms1G", "-javaagent:b.jar", "-classpath", "old" });
    try append(&b, &.{ "-Xmx4G", "-Dfoo=three", "-XX:-UseG1GC", "--class-path=new", "-Dempty", "--unknown" });
    const argv = try b.render(a);
    defer a.free(argv);
    const expected = [_][]const u8{ "java", "-Xmx4G", "-Dfoo=three", "-Dbar=two", "-XX:-UseG1GC", "-javaagent:a.jar", "-Xms1G", "-javaagent:b.jar", "-cp", "new", "-Dempty=", "--unknown" };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, actual| try std.testing.expectEqualStrings(want, actual);
    try std.testing.expectEqualStrings("three", b.get(.{ .namespace = "java.property", .name = "foo" }).?);
    try std.testing.expectEqual(@as(usize, 1), b.remove(.{ .namespace = "java.property", .name = "foo" }));
}

test "JVM parsing validates values and excludes launch target selectors" {
    const a = std.testing.allocator;
    var b = try command.Builder.init(a, "java");
    defer b.deinit();
    try std.testing.expectError(error.MissingValue, append(&b, &.{"-Xmx"}));
    try std.testing.expectError(error.MissingValue, append(&b, &.{"-cp"}));
    try std.testing.expectError(error.EmptyPropertyName, append(&b, &.{"-D=bad"}));
    try std.testing.expectError(error.InvalidXXOption, append(&b, &.{"-XX:+"}));
    try std.testing.expectError(error.LaunchTargetNotAllowed, append(&b, &.{ "-jar", "game.jar" }));
}

test "known separate option operands remain opaque to JVM normalization" {
    const a = std.testing.allocator;
    var b = try command.Builder.init(a, "java");
    defer b.deinit();
    try append(&b, &.{ "--module-path", "-Dfoo", "-Dfoo=value", "-XX:MaxGCPauseMillis=200" });
    try append(&b, &.{ "-Dfoo=override", "-XX:MaxGCPauseMillis=100" });
    const argv = try b.render(a);
    defer a.free(argv);
    const expected = [_][]const u8{ "java", "--module-path", "-Dfoo", "-Dfoo=override", "-XX:MaxGCPauseMillis=100" };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, actual| try std.testing.expectEqualStrings(want, actual);
}

test "CompileCommand retains accumulating directives in insertion order" {
    const a = std.testing.allocator;
    var b = try command.Builder.init(a, "java");
    defer b.deinit();
    try append(&b, &.{ "-XX:CompileCommand=exclude,java/lang/String.indexOf", "-Xmx2G", "-XX:CompileCommand=exclude,java/lang/String.charAt" });
    const argv = try b.render(a);
    defer a.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("-XX:CompileCommand=exclude,java/lang/String.indexOf", argv[1]);
    try std.testing.expectEqualStrings("-Xmx2G", argv[2]);
    try std.testing.expectEqualStrings("-XX:CompileCommand=exclude,java/lang/String.charAt", argv[3]);
}
