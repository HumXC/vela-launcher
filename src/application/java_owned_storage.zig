//! Receipt-backed Java storage. All traversal is component-wise and NOFOLLOW.
//! The UI decides confirmation; this module never removes registry entries.
const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../core/java_download.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

pub const max_depth: usize = 64;
pub const max_entries: usize = 100_000;
const max_receipt_bytes: usize = 16 * 1024;
const max_path_bytes: usize = 4096;
const receipt_name = ".vela-runtime.json";

const Receipt = struct {
    schema: u8,
    vendor: backend.Vendor,
    major: u8,
    version: []const u8,
    os: backend.Os,
    arch: backend.Arch,
    url: []const u8,
    sha256: []const u8,
    java: []const u8,
};
const Candidate = struct { name: []const u8, java: []const u8 };
const Owned = struct {
    parent: Dir,
    directory: Dir,
    name: []const u8,
    identity: Io.File.Stat,
    receipt_identity: Io.File.Stat,

    fn close(self: Owned, io: Io) void {
        self.directory.close(io);
        self.parent.close(io);
    }
};

fn separators() []const u8 {
    return if (builtin.os.tag == .windows) "/\\" else "/";
}
fn absoluteStart(path: []const u8) !usize {
    if (path.len == 0 or path.len > max_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.UnsafeOwnedPath;
    if (builtin.os.tag == .windows) {
        // Device, UNC and drive-relative paths cannot be deletion roots.
        if (path.len < 3 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or
            std.mem.indexOfScalar(u8, separators(), path[2]) == null) return error.UnsafeOwnedPath;
        return 3;
    }
    if (path[0] != '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return error.UnsafeOwnedPath;
    return 1;
}
fn components(path: []const u8) !std.mem.SplitIterator(u8, .any) {
    const start = try absoluteStart(path);
    var it = std.mem.splitAny(u8, path[start..], separators());
    var count: usize = 0;
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or
            std.mem.indexOfScalar(u8, part, ':') != null) return error.UnsafeOwnedPath;
        count += 1;
        if (count > max_depth) return error.OwnedStorageLimit;
    }
    return std.mem.splitAny(u8, path[start..], separators());
}
fn candidate(root: []const u8, java_path: []const u8) !Candidate {
    var roots = try components(root);
    var paths = try components(java_path);
    const root_start = try absoluteStart(root);
    const java_start = try absoluteStart(java_path);
    if (!std.mem.eql(u8, root[0..root_start], java_path[0..java_start])) return error.NotOwnedJava;
    const first = roots.next() orelse return error.UnsafeOwnedPath;
    for ([_][]const u8{ "bin", "sbin", "usr", "lib", "lib64", "etc", "dev", "proc", "sys", "boot", "run", "nix", "opt", "var", "Windows", "Program Files", "Program Files (x86)", "ProgramData", "System", "Library" }) |system| {
        if (std.ascii.eqlIgnoreCase(first, system)) return error.UnsafeOwnedPath;
    }
    var root_count: usize = 0;
    var previous: []const u8 = "";
    var last: []const u8 = "";
    roots = try components(root);
    while (roots.next()) |part| {
        previous = last;
        last = part;
        root_count += 1;
    }
    if (root_count < 3 or !std.mem.eql(u8, previous, ".vela") or !std.mem.eql(u8, last, "jdks")) return error.UnsafeOwnedPath;
    roots = try components(root);
    while (roots.next()) |part| {
        if (!std.mem.eql(u8, part, paths.next() orelse return error.NotOwnedJava)) return error.NotOwnedJava;
    }
    const name = paths.next() orelse return error.NotOwnedJava;
    const java_relative = paths.rest();
    if (java_relative.len == 0 or name[0] == '.') return error.NotOwnedJava;
    return .{ .name = name, .java = java_relative };
}
fn relativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes or path[0] == '/' or
        std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or
            std.mem.indexOfScalar(u8, part, ':') != null) return false;
        depth += 1;
        if (depth > max_depth) return false;
    }
    return true;
}
fn openAbsolute(io: Io, path: []const u8) !Dir {
    const start = try absoluteStart(path);
    var parts = try components(path);
    var current = try Dir.openDirAbsolute(io, path[0..start], .{ .follow_symlinks = false });
    errdefer current.close(io);
    while (parts.next()) |part| {
        const next = try current.openDir(io, part, .{ .follow_symlinks = false });
        current.close(io);
        current = next;
    }
    return current;
}
fn sameFile(a: Io.File.Stat, b: Io.File.Stat) bool {
    return a.inode == b.inode and a.kind == b.kind;
}
fn regular(stat: Io.File.Stat) !void {
    if (stat.kind != .file or stat.nlink != 1) return error.UnsafeOwnedLink;
}
fn checkJava(io: Io, dir: Dir, relative: []const u8) !void {
    var parts = std.mem.splitAny(u8, relative, separators());
    var current = try dir.openDir(io, ".", .{ .follow_symlinks = false });
    defer current.close(io);
    while (parts.next()) |part| {
        if (parts.rest().len == 0) {
            const stat = try current.statFile(io, part, .{ .follow_symlinks = false });
            try regular(stat);
            if (stat.size == 0) return error.InvalidOwnedReceipt;
            return;
        }
        const next = try current.openDir(io, part, .{ .follow_symlinks = false });
        current.close(io);
        current = next;
    }
    return error.InvalidOwnedReceipt;
}
fn inspect(a: Allocator, io: Io, root: []const u8, java_path: []const u8) !Owned {
    const target = try candidate(root, java_path);
    const parent = try openAbsolute(io, root);
    errdefer parent.close(io);
    const identity = try parent.statFile(io, target.name, .{ .follow_symlinks = false });
    if (identity.kind != .directory) return error.UnsafeOwnedLink;
    const directory = try parent.openDir(io, target.name, .{ .iterate = true, .follow_symlinks = false });
    errdefer directory.close(io);
    if (!sameFile(identity, try directory.stat(io))) return error.OwnedStorageChanged;
    const receipt_identity = try directory.statFile(io, receipt_name, .{ .follow_symlinks = false });
    try regular(receipt_identity);
    if (receipt_identity.size == 0 or receipt_identity.size > max_receipt_bytes) return error.InvalidOwnedReceipt;
    const file = try directory.openFile(io, receipt_name, .{ .follow_symlinks = false });
    defer file.close(io);
    const opened = try file.stat(io);
    try regular(opened);
    if (!sameFile(receipt_identity, opened) or opened.size != receipt_identity.size) return error.OwnedStorageChanged;
    const bytes = try a.alloc(u8, @as(usize, @intCast(opened.size)) + 1);
    defer a.free(bytes);
    const size = try file.readPositionalAll(io, bytes, 0);
    if (size != opened.size) return error.OwnedStorageChanged;
    var parsed = try std.json.parseFromSlice(Receipt, a, bytes[0..size], .{});
    defer parsed.deinit();
    const receipt = parsed.value;
    if (receipt.schema != 1 or !backend.supported(receipt.vendor, receipt.major) or
        receipt.version.len == 0 or receipt.version.len > 128 or !relativePath(receipt.java) or
        receipt.sha256.len != 64) return error.InvalidOwnedReceipt;
    for (receipt.sha256) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidOwnedReceipt;
    const expected_name = try std.fmt.allocPrint(a, "{s}-{d}-{s}-{s}-{s}", .{ @tagName(receipt.vendor), receipt.major, @tagName(receipt.os), @tagName(receipt.arch), receipt.sha256 });
    defer a.free(expected_name);
    if (!std.mem.eql(u8, expected_name, target.name)) return error.InvalidOwnedReceipt;
    if (!std.mem.startsWith(u8, receipt.url, if (receipt.vendor == .azul) "https://cdn.azul.com/zulu/bin/" else "https://aka.ms/download-jdk/")) return error.InvalidOwnedReceipt;
    const expected_java = if (receipt.os == .windows) "bin/java.exe" else "bin/java";
    if (!(std.mem.eql(u8, receipt.java, expected_java) or
        (std.mem.endsWith(u8, receipt.java, expected_java) and receipt.java[receipt.java.len - expected_java.len - 1] == '/'))) return error.InvalidOwnedReceipt;
    var recorded = std.mem.splitScalar(u8, receipt.java, '/');
    var requested = std.mem.splitAny(u8, target.java, separators());
    while (recorded.next()) |part| if (!std.mem.eql(u8, part, requested.next() orelse return error.NotOwnedJava)) return error.NotOwnedJava;
    if (requested.next() != null) return error.NotOwnedJava;
    // A canceled deletion may already have removed Java or one of its parents.
    // The receipt must still match exactly; checkJava rejects every existing link.
    checkJava(io, directory, target.java) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    return .{ .parent = parent, .directory = directory, .name = target.name, .identity = identity, .receipt_identity = receipt_identity };
}

/// Explicit-click ownership check. Receipt and every path component must be safe.
pub fn check(a: Allocator, io: Io, root: []const u8, java_path: []const u8) !void {
    const owned = try inspect(a, io, root, java_path);
    owned.close(io);
}
fn checkCancel(cancel: *const std.atomic.Value(bool)) !void {
    if (cancel.load(.acquire)) return error.Canceled;
}
const Budget = struct {
    entries: usize = 0,
    fn take(self: *Budget, depth: usize) !void {
        if (depth > max_depth or self.entries >= max_entries) return error.OwnedStorageLimit;
        self.entries += 1;
    }
};
fn walk(io: Io, dir: Dir, depth: usize, budget: *Budget, cancel: *const std.atomic.Value(bool), removing: bool) anyerror!void {
    try checkCancel(cancel);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        try checkCancel(cancel);
        try budget.take(depth);
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        switch (stat.kind) {
            .file => {
                try regular(stat);
                // Preserve proof of ownership until all other contents are gone.
                if (removing and !(depth == 0 and std.mem.eql(u8, entry.name, receipt_name))) {
                    try checkCancel(cancel);
                    try dir.deleteFile(io, entry.name);
                }
            },
            .sym_link => {
                // Only unlink the directory entry; never open or follow its target.
                if (removing) {
                    try checkCancel(cancel);
                    if (!sameFile(stat, try dir.statFile(io, entry.name, .{ .follow_symlinks = false }))) return error.OwnedStorageChanged;
                    try dir.deleteFile(io, entry.name);
                }
            },
            .directory => {
                const child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                {
                    defer child.close(io);
                    if (!sameFile(stat, try child.stat(io))) return error.OwnedStorageChanged;
                    try walk(io, child, depth + 1, budget, cancel, removing);
                    if (!sameFile(stat, try dir.statFile(io, entry.name, .{ .follow_symlinks = false }))) return error.OwnedStorageChanged;
                }
                if (removing) {
                    try checkCancel(cancel);
                    try dir.deleteDir(io, entry.name);
                }
            },
            else => return error.UnsafeOwnedLink,
        }
    }
}

/// Worker-only deletion; bounded preflight rejects special files and hard links.
/// Interior symlinks are unlinked as entries, never traversed.
/// Cancellation or failure may leave partial storage, and must never publish success.
pub fn delete(a: Allocator, io: Io, root: []const u8, java_path: []const u8, cancel: *const std.atomic.Value(bool)) !void {
    try checkCancel(cancel);
    const owned = try inspect(a, io, root, java_path);
    defer owned.close(io);
    var preflight: Budget = .{};
    try walk(io, owned.directory, 0, &preflight, cancel, false);
    try checkCancel(cancel);
    var removal: Budget = .{};
    try walk(io, owned.directory, 0, &removal, cancel, true);
    try checkCancel(cancel);
    if (!sameFile(owned.identity, try owned.parent.statFile(io, owned.name, .{ .follow_symlinks = false })) or
        !sameFile(owned.receipt_identity, try owned.directory.statFile(io, receipt_name, .{ .follow_symlinks = false }))) return error.OwnedStorageChanged;
    // The last two unlinks are the commit. Cancellation after this point cannot
    // undo removed storage; success still requires the directory unlink to succeed.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    try owned.directory.deleteFile(io, receipt_name);
    try owned.parent.deleteDir(io, owned.name);
}

test "owned storage rejects system roots traversal prefix collisions and malformed paths" {
    for ([_][]const u8{ "/", "/.vela/jdks", "/usr/local/.vela/jdks", "/nix/store/launcher/.vela/jdks", "/safe/../.vela/jdks", "/safe//.vela/jdks" }) |root| {
        try std.testing.expectError(error.UnsafeOwnedPath, candidate(root, "/safe/.vela/jdks/runtime/bin/java"));
    }
    if (builtin.os.tag != .windows) {
        try std.testing.expectError(error.NotOwnedJava, candidate("/safe/.vela/jdks", "/safe/.vela/jdks-else/runtime/bin/java"));
        try std.testing.expectError(error.NotOwnedJava, candidate("/safe/.vela/jdks", "/safe/.vela/jdks"));
        try std.testing.expectError(error.UnsafeOwnedPath, candidate("/safe/.vela/jdks", "/safe/.vela/jdks/runtime/../bin/java"));
    }
}
test "owned deletion canceled before inspection cannot modify an unsafe target" {
    const cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, delete(std.testing.allocator, std.testing.io, "/", "/usr/bin/java", &cancel));
}

test "owned walk budgets bound entry counts and recursion and cancellation wins" {
    var budget: Budget = .{};
    try std.testing.expectError(error.OwnedStorageLimit, budget.take(max_depth + 1));
    try std.testing.expectEqual(@as(usize, 0), budget.entries);
    budget.entries = max_entries;
    try std.testing.expectError(error.OwnedStorageLimit, budget.take(0));
    try std.testing.expectEqual(max_entries, budget.entries);
    const cancel = std.atomic.Value(bool).init(true);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var canceled_budget: Budget = .{};
    try std.testing.expectError(error.Canceled, walk(std.testing.io, tmp.dir, 0, &canceled_budget, &cancel, true));
    try std.testing.expectEqual(@as(usize, 0), canceled_budget.entries);
}
