//! CPU validation of executable headers, independent of classifier naming.
const std = @import("std");
const Cpu = enum { x86, x64, arm, arm64 };

fn cpu(name: []const u8) !Cpu {
    for ([_][]const u8{ "x86_64", "amd64", "x64" }) |s| if (std.ascii.eqlIgnoreCase(name, s)) return .x64;
    for ([_][]const u8{ "x86", "i386", "i486", "i586", "i686" }) |s| if (std.ascii.eqlIgnoreCase(name, s)) return .x86;
    for ([_][]const u8{ "aarch64", "arm64" }) |s| if (std.ascii.eqlIgnoreCase(name, s)) return .arm64;
    for ([_][]const u8{ "arm", "armv7", "armv7l", "armhf", "thumb" }) |s| if (std.ascii.eqlIgnoreCase(name, s)) return .arm;
    return error.UnsupportedNativeArchitecture;
}

fn int(comptime T: type, data: []const u8, offset: usize, endian: std.builtin.Endian) !T {
    if (offset > data.len or @sizeOf(T) > data.len - offset) return error.InvalidNativePayload;
    return std.mem.readInt(T, data[offset..][0..@sizeOf(T)], endian);
}

fn range(data: []const u8, offset: u64, size: u64) !void {
    if (offset > data.len or size > data.len - offset) return error.InvalidNativePayload;
}

fn matches(actual: ?Cpu, wanted: Cpu) !void {
    if (actual == null or actual.? != wanted) return error.NativeArchitectureMismatch;
}

fn nativeName(name: []const u8) bool {
    const base = std.fs.path.basename(name);
    for ([_][]const u8{ ".dll", ".dylib", ".jnilib", ".so", ".exe" }) |suffix| {
        if (base.len >= suffix.len and std.ascii.eqlIgnoreCase(base[base.len - suffix.len ..], suffix)) return true;
    }
    if (base.len >= 4) for (0..base.len - 3) |i| {
        if (std.ascii.eqlIgnoreCase(base[i..][0..4], ".so.")) return true;
    };
    return false;
}

/// Unknown resource bytes are allowed; unknown native-library filenames are not.
/// Every recognized executable is checked, including executables renamed as resources.
pub fn validate(data: []const u8, name: []const u8, cpu_arch: []const u8) !void {
    try validateChecked(data, name, cpu_arch, null);
}

pub fn validateChecked(data: []const u8, name: []const u8, cpu_arch: []const u8, cancel: ?*const std.atomic.Value(bool)) !void {
    try checkpoint(cancel);
    const wanted = try cpu(cpu_arch);
    if (std.mem.startsWith(u8, data, "\x7fELF")) return elf(data, wanted);
    if (std.mem.startsWith(u8, data, "MZ")) return pe(data, wanted);
    if (data.len >= 4) {
        const magic = try int(u32, data, 0, .big);
        switch (magic) {
            0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe => return thin(data, wanted, cancel),
            0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca => {
                // Java class files share FAT_MAGIC, but carry a class version, not an arch count.
                if (magic == 0xcafebabe and std.mem.endsWith(u8, name, ".class") and data.len >= 11) {
                    const major = try int(u16, data, 6, .big);
                    const pool_count = try int(u16, data, 8, .big);
                    const pool_tag = data[10];
                    const valid_tag = switch (pool_tag) {
                        1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15, 16, 17, 18, 19, 20 => true,
                        else => false,
                    };
                    if (major >= 45 and major <= 100 and pool_count > 1 and valid_tag) {
                        // A valid fat image takes precedence even if renamed as a class.
                        fat(data, wanted, magic, cancel) catch |err| switch (err) {
                            error.InvalidNativePayload => return,
                            else => return err,
                        };
                        return;
                    }
                }
                return fat(data, wanted, magic, cancel);
            },
            else => {},
        }
    }
    if (nativeName(name)) return error.InvalidNativePayload;
}

fn elf(data: []const u8, wanted: Cpu) !void {
    if (data.len < 16 or (data[4] != 1 and data[4] != 2) or (data[5] != 1 and data[5] != 2) or data[6] != 1) return error.InvalidNativePayload;
    const endian: std.builtin.Endian = if (data[5] == 1) .little else .big;
    const wide = data[4] == 2;
    const header_size: u16 = if (wide) 64 else 52;
    try range(data, 0, header_size);
    const kind = try int(u16, data, 16, endian);
    if ((kind != 2 and kind != 3) or try int(u32, data, 20, endian) != 1 or try int(u16, data, if (wide) 52 else 40, endian) != header_size) return error.InvalidNativePayload;
    const machine = try int(u16, data, 18, endian);
    const actual: ?Cpu = switch (machine) {
        3 => .x86,
        62 => .x64,
        40 => .arm,
        183 => .arm64,
        else => null,
    };
    if (actual) |c| if (wide != (c == .x64 or c == .arm64)) return error.InvalidNativePayload;
    const phoff: u64 = if (wide) try int(u64, data, 32, endian) else try int(u32, data, 28, endian);
    const shoff: u64 = if (wide) try int(u64, data, 40, endian) else try int(u32, data, 32, endian);
    const phsize = try int(u16, data, if (wide) 54 else 42, endian);
    const phnum = try int(u16, data, if (wide) 56 else 44, endian);
    const shsize = try int(u16, data, if (wide) 58 else 46, endian);
    const shnum = try int(u16, data, if (wide) 60 else 48, endian);
    if (phnum != 0 and (phsize != (if (wide) @as(u16, 56) else 32) or phoff < header_size)) return error.InvalidNativePayload;
    if (shnum != 0 and (shsize != (if (wide) @as(u16, 64) else 40) or shoff < header_size)) return error.InvalidNativePayload;
    try range(data, phoff, @as(u64, phsize) * phnum);
    try range(data, shoff, @as(u64, shsize) * shnum);
    try matches(actual, wanted);
}

fn pe(data: []const u8, wanted: Cpu) !void {
    try range(data, 0, 64);
    const off = try int(u32, data, 60, .little);
    if (off < 64) return error.InvalidNativePayload;
    try range(data, off, 24);
    if (!std.mem.eql(u8, data[off..][0..4], "PE\x00\x00")) return error.InvalidNativePayload;
    const machine = try int(u16, data, off + 4, .little);
    const actual: ?Cpu = switch (machine) {
        0x14c => .x86,
        0x8664 => .x64,
        0x1c0, 0x1c4 => .arm,
        0xaa64 => .arm64,
        else => null,
    };
    const optlen = try int(u16, data, off + 20, .little);
    const opt: usize = @as(usize, off) + 24;
    try range(data, opt, optlen);
    const magic = try int(u16, data, opt, .little);
    if ((magic != 0x10b and magic != 0x20b) or optlen < (if (magic == 0x20b) @as(u16, 112) else 96)) return error.InvalidNativePayload;
    if (actual) |c| if ((magic == 0x20b) != (c == .x64 or c == .arm64)) return error.InvalidNativePayload;
    const sections = try int(u16, data, off + 6, .little);
    try range(data, opt + optlen, @as(u64, sections) * 40);
    for (0..sections) |i| {
        const s = opt + optlen + i * 40;
        try range(data, try int(u32, data, s + 20, .little), try int(u32, data, s + 16, .little));
    }
    try matches(actual, wanted);
}

fn machCpu(value: u32) ?Cpu {
    return switch (value) {
        7 => .x86,
        0x01000007 => .x64,
        12 => .arm,
        0x0100000c => .arm64,
        else => null,
    };
}

fn thin(data: []const u8, wanted: Cpu, cancel: ?*const std.atomic.Value(bool)) !void {
    const magic = try int(u32, data, 0, .big);
    const endian: std.builtin.Endian = switch (magic) {
        0xfeedface, 0xfeedfacf => .big,
        0xcefaedfe, 0xcffaedfe => .little,
        else => return error.InvalidNativePayload,
    };
    const wide = magic == 0xfeedfacf or magic == 0xcffaedfe;
    const hsize: usize = if (wide) 32 else 28;
    try range(data, 0, hsize);
    const machine = try int(u32, data, 4, endian);
    const actual = machCpu(machine);
    if (wide != (machine & 0x01000000 != 0)) return error.InvalidNativePayload;
    const kind = try int(u32, data, 12, endian);
    if (kind != 2 and kind != 6 and kind != 8) return error.InvalidNativePayload;
    const count = try int(u32, data, 16, endian);
    const size = try int(u32, data, 20, endian);
    try range(data, hsize, size);
    if (count > size / 8) return error.InvalidNativePayload;
    var pos = hsize;
    for (0..count) |_| {
        try checkpoint(cancel);
        const cmdsize = try int(u32, data, pos + 4, endian);
        if (cmdsize < 8 or cmdsize % 4 != 0 or cmdsize > hsize + size - pos) return error.InvalidNativePayload;
        pos += cmdsize;
    }
    if (pos != hsize + size) return error.InvalidNativePayload;
    try matches(actual, wanted);
}

fn fat(data: []const u8, wanted: Cpu, magic: u32, cancel: ?*const std.atomic.Value(bool)) !void {
    const endian: std.builtin.Endian = if (magic == 0xcafebabe or magic == 0xcafebabf) .big else .little;
    const wide = magic == 0xcafebabf or magic == 0xbfbafeca;
    const count = try int(u32, data, 4, endian);
    if (count == 0 or count > 64) return error.InvalidNativePayload;
    const record: usize = if (wide) 32 else 20;
    const table_end = 8 + @as(usize, count) * record;
    try range(data, 0, table_end);
    var starts: [64]u64 = undefined;
    var ends: [64]u64 = undefined;
    var found = false;
    for (0..count) |i| {
        const p = 8 + i * record;
        const arch = machCpu(try int(u32, data, p, endian));
        const off: u64 = if (wide) try int(u64, data, p + 8, endian) else try int(u32, data, p + 8, endian);
        const size: u64 = if (wide) try int(u64, data, p + 16, endian) else try int(u32, data, p + 12, endian);
        const alignment = try int(u32, data, p + (if (wide) @as(usize, 24) else 16), endian);
        if (off < table_end or size < 28 or alignment > 31 or off % (@as(u64, 1) << @intCast(alignment)) != 0) return error.InvalidNativePayload;
        try range(data, off, size);
        for (0..i) |j| if (off < ends[j] and starts[j] < off + size) return error.InvalidNativePayload;
        starts[i] = off;
        ends[i] = off + size;
        const slice = data[@intCast(off)..@intCast(off + size)];
        const thin_magic = try int(u32, slice, 0, .big);
        const thin_endian: std.builtin.Endian = switch (thin_magic) {
            0xfeedface, 0xfeedfacf => .big,
            0xcefaedfe, 0xcffaedfe => .little,
            else => return error.InvalidNativePayload,
        };
        if (try int(u32, slice, 4, thin_endian) != try int(u32, data, p, endian)) return error.InvalidNativePayload;
        // Validate every slice structurally, even non-selected architectures.
        try checkpoint(cancel);
        thin(slice, arch orelse wanted, cancel) catch |err| switch (err) {
            error.NativeArchitectureMismatch => if (arch != null) return err,
            else => return err,
        };
        if (arch == wanted) found = true;
    }
    if (!found) return error.NativeArchitectureMismatch;
}

fn checkpoint(cancel: ?*const std.atomic.Value(bool)) !void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
}
