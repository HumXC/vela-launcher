//! Verified JVM architecture metadata, independent of runtime discovery and I/O.
const std = @import("std");
const builtin = @import("builtin");

pub const Architecture = enum {
    x86,
    x86_64,
    aarch64,

    pub fn cpuName(self: Architecture) []const u8 {
        return @tagName(self);
    }

    pub fn bitWidth(self: Architecture) u16 {
        return switch (self) {
            .x86 => 32,
            .x86_64, .aarch64 => 64,
        };
    }

    pub fn label(self: Architecture) []const u8 {
        return switch (self) {
            .x86 => "x86",
            .x86_64 => "x86_64",
            .aarch64 => "ARM64",
        };
    }

    pub fn requireHost(self: Architecture) !void {
        if (self != host()) return error.JavaArchitectureMismatch;
    }
};

pub fn host() Architecture {
    return switch (builtin.cpu.arch) {
        .x86 => .x86,
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        else => @compileError("Unsupported host architecture for Java runtimes"),
    };
}

fn normalize(value: []const u8) !Architecture {
    if (std.ascii.eqlIgnoreCase(value, "amd64") or
        std.ascii.eqlIgnoreCase(value, "x86_64") or
        std.ascii.eqlIgnoreCase(value, "x86-64") or
        std.ascii.eqlIgnoreCase(value, "x64")) return .x86_64;
    if (std.ascii.eqlIgnoreCase(value, "aarch64") or
        std.ascii.eqlIgnoreCase(value, "arm64")) return .aarch64;
    if (std.ascii.eqlIgnoreCase(value, "x86")) return .x86;
    inline for (.{ "i386", "i486", "i586", "i686" }) |alias| {
        if (std.ascii.eqlIgnoreCase(value, alias)) return .x86;
    }
    return error.UnsupportedJavaArchitecture;
}

/// Reads -XshowSettings:properties output. Neither version banners nor the
/// launcher's architecture provide evidence of the JVM's architecture.
pub fn parse(output: []const u8) !Architecture {
    var architecture: ?Architecture = null;
    var data_model: ?u16 = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\r");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "os.arch")) {
            const parsed = try normalize(value);
            if (architecture) |previous| {
                if (previous != parsed) return error.ConflictingJavaArchitecture;
            }
            architecture = parsed;
        } else if (std.mem.eql(u8, key, "sun.arch.data.model")) {
            const parsed: u16 = if (std.mem.eql(u8, value, "32"))
                32
            else if (std.mem.eql(u8, value, "64"))
                64
            else
                return error.InvalidJavaDataModel;
            if (data_model) |previous| {
                if (previous != parsed) return error.ConflictingJavaDataModel;
            }
            data_model = parsed;
        }
    }
    const parsed = architecture orelse return error.MissingJavaArchitecture;
    if (data_model) |bits| {
        if (bits != parsed.bitWidth()) return error.JavaArchitectureDataModelMismatch;
    }
    return parsed;
}

test "JVM architecture aliases normalize to verified CPU architectures" {
    const cases = .{
        .{ "x86", Architecture.x86 },
        .{ "i386", Architecture.x86 },
        .{ "i486", Architecture.x86 },
        .{ "i586", Architecture.x86 },
        .{ "i686", Architecture.x86 },
        .{ "amd64", Architecture.x86_64 },
        .{ "x86_64", Architecture.x86_64 },
        .{ "AMD64", Architecture.x86_64 },
        .{ "aarch64", Architecture.aarch64 },
        .{ "arm64", Architecture.aarch64 },
        .{ "ARM64", Architecture.aarch64 },
    };
    inline for (cases) |case| {
        try std.testing.expectEqual(case[1], try parse("Property settings:\r\n    os.arch = " ++ case[0] ++ "\r\n"));
    }
    try std.testing.expectEqual(Architecture.x86, try parse("os.arch = i686\nsun.arch.data.model = 32\n"));
    try std.testing.expectEqual(Architecture.x86_64, try parse("sun.arch.data.model = 64\nos.arch = amd64\n"));
    try std.testing.expectEqual(Architecture.aarch64, try parse("os.arch = arm64\nsun.arch.data.model = 64\n"));
}

test "JVM architecture requires explicit known os.arch evidence" {
    try std.testing.expectError(error.MissingJavaArchitecture, parse("openjdk version \"21.0.7\"\nOpenJDK 64-Bit Server VM\n"));
    try std.testing.expectError(error.MissingJavaArchitecture, parse("sun.arch.data.model = 64\n"));
    try std.testing.expectError(error.MissingJavaArchitecture, parse("other.os.arch = amd64\n"));
    try std.testing.expectError(error.UnsupportedJavaArchitecture, parse("os.arch = riscv64\n"));
    try std.testing.expectError(error.UnsupportedJavaArchitecture, parse("os.arch = \n"));
}

test "JVM architecture and data model must agree" {
    try std.testing.expectError(error.JavaArchitectureDataModelMismatch, parse("os.arch = x86\nsun.arch.data.model = 64\n"));
    try std.testing.expectError(error.JavaArchitectureDataModelMismatch, parse("os.arch = amd64\nsun.arch.data.model = 32\n"));
    try std.testing.expectError(error.JavaArchitectureDataModelMismatch, parse("os.arch = aarch64\nsun.arch.data.model = 32\n"));
    try std.testing.expectError(error.InvalidJavaDataModel, parse("os.arch = amd64\nsun.arch.data.model = unknown\n"));
    try std.testing.expectError(error.ConflictingJavaArchitecture, parse("os.arch = amd64\nos.arch = arm64\n"));
    try std.testing.expectError(error.ConflictingJavaDataModel, parse("os.arch = amd64\nsun.arch.data.model = 64\nsun.arch.data.model = 32\n"));
    try std.testing.expectEqual(Architecture.x86_64, try parse("os.arch = amd64\nos.arch = x86_64\n"));
}

test "architecture names widths labels and host guard are explicit" {
    try std.testing.expectEqualStrings("x86", Architecture.x86.cpuName());
    try std.testing.expectEqualStrings("x86_64", Architecture.x86_64.cpuName());
    try std.testing.expectEqualStrings("aarch64", Architecture.aarch64.cpuName());
    try std.testing.expectEqual(@as(u16, 32), Architecture.x86.bitWidth());
    try std.testing.expectEqual(@as(u16, 64), Architecture.x86_64.bitWidth());
    try std.testing.expectEqual(@as(u16, 64), Architecture.aarch64.bitWidth());
    try std.testing.expectEqualStrings("ARM64", Architecture.aarch64.label());
    try host().requireHost();
    inline for (.{ Architecture.x86, Architecture.x86_64, Architecture.aarch64 }) |architecture| {
        if (architecture != host()) try std.testing.expectError(error.JavaArchitectureMismatch, architecture.requireHost());
    }
}
