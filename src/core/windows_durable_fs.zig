//! Isolated Windows filesystem publication adapter. No caller is wired to it yet.
//! Root has one worker owner. Journal parsing/reference policy stays with callers.
//! Production is local NTFS only; UNC/mapped/unknown volumes fail closed.
//! Microsoft MoveFileExW documents MOVEFILE_WRITE_THROUGH as waiting until the
//! file is moved on disk. We use same-directory moves, never COPY_ALLOWED/DELAY.
//! This is an API contract, not observed Windows/power-loss acceptance evidence.
//! https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw
//! ReplaceFileW WRITE_THROUGH is unsupported and is deliberately not used.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const journal_limit = 64 * 1024;
pub const config_limit = 4 * 1024 * 1024;
pub const Privacy = enum { private_journal, ordinary_config };
pub const Error = error{
    OutOfMemory,
    InvalidRoot,
    InvalidLeaf,
    LauncherRootInUse,
    FileTooLarge,
    InsecureJournal,
    JournalChanged,
    PersistenceFailure,
    CommitUncertain,
    UnsupportedDurability,
    Cancelled,
    OperationInProgress,
    TemporaryNameCollision,
};
pub const Identity = struct {
    volume: u32,
    file: u64,
    pub fn eql(a: Identity, b: Identity) bool {
        return a.volume == b.volume and a.file == b.file;
    }
};
pub const OwnedBytes = struct {
    bytes: []const u8,
    allocation: []u8,
    allocator: Allocator,
    pub fn deinit(self: *OwnedBytes) void {
        self.allocator.free(self.allocation);
        self.* = undefined;
    }
};
pub const Temporary = struct { handle: usize, identity: Identity };

/// Every operation is required: injection is explicit and has no production
/// fallback. open rolls back its resources on error; close ends context ownership.
/// A successful ensure_directory establishes durable, validated storage. An
/// attempted namespace mutation with an unknown outcome returns CommitUncertain.
pub const NativeOps = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, []const u8, Privacy) Error!void,
    close: *const fn (*anyopaque) void,
    /// Lifetime root writer, released by close. Absent implementations fail closed.
    acquire_writer: ?*const fn (*anyopaque) Error!void = null,
    check_cancel: *const fn (*anyopaque) Error!void,
    validate_root: *const fn (*anyopaque) Error!void,
    load: *const fn (*anyopaque, Allocator, []const u8, usize, Privacy) Error!?OwnedBytes,
    ensure_directory: *const fn (*anyopaque) Error!void,
    random: *const fn (*anyopaque, []u8) Error!void,
    create_temp: *const fn (*anyopaque, []const u8) Error!Temporary,
    write: *const fn (*anyopaque, usize, []const u8) Error!void,
    flush: *const fn (*anyopaque, usize) Error!void,
    verify_temp: *const fn (*anyopaque, Temporary, usize) Error!void,
    move: *const fn (*anyopaque, []const u8, []const u8) Error!void,
    verify_final: *const fn (*anyopaque, []const u8, Identity, usize) Error!void,
    close_file: *const fn (*anyopaque, usize) void,
    discard_temp: *const fn (*anyopaque, []const u8, Identity) void,
};

pub const PrecommitCheck = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque, *Root) anyerror!void = noop,
    pub const none: PrecommitCheck = .{};
    fn noop(_: ?*anyopaque, _: *Root) anyerror!void {}
};

pub const Root = struct {
    allocator: Allocator,
    normalized: []u8,
    privacy: Privacy,
    ops: NativeOps,
    publication_uncertain: bool = false,
    busy: bool = false,

    pub fn publicationUncertain(self: *const Root) bool {
        return self.publication_uncertain;
    }
};

/// absolute_root is the existing LAUNCHER root; .vela is never created by open
/// or load. open holds native handles to each drive-path ancestor without
/// following reparses. ordinary_config does not require private ancestor DACLs.
pub fn openRoot(a: Allocator, io: Io, absolute_root: []const u8, privacy: Privacy) Error!Root {
    if (builtin.os.tag != .windows) return error.UnsupportedDurability;
    const native = try a.create(Windows);
    errdefer a.destroy(native);
    native.* = .{ .allocator = a, .io = io };
    return openRootWithOps(a, absolute_root, privacy, native.operations());
}

/// Explicit seam for hermetic protocol tests. The caller supplies the complete
/// native-operation contract, including capability and privacy validation.
pub fn openRootWithOps(a: Allocator, absolute_root: []const u8, privacy: Privacy, ops: NativeOps) Error!Root {
    const normalized = try normalizeRoot(a, absolute_root);
    errdefer a.free(normalized);
    try ops.open(ops.context, normalized, privacy);
    return .{ .allocator = a, .normalized = normalized, .privacy = privacy, .ops = ops };
}

/// Acquire before loading config; retain through reference/vault cleanup.
/// Journal capabilities do not independently acquire the config writer.
pub fn acquireWriter(root: *Root) Error!void {
    if (root.privacy != .ordinary_config) return error.InvalidRoot;
    try root.ops.check_cancel(root.ops.context);
    try root.ops.validate_root(root.ops.context);
    const acquire = root.ops.acquire_writer orelse return error.UnsupportedDurability;
    try acquire(root.ops.context);
    try root.ops.validate_root(root.ops.context);
}

pub fn deinit(root: *Root) void {
    std.debug.assert(!root.busy);
    root.ops.close(root.ops.context);
    root.allocator.free(root.normalized);
    root.* = undefined;
}

fn leafLimit(privacy: Privacy, leaf: []const u8) Error!usize {
    if (privacy == .ordinary_config and std.mem.eql(u8, leaf, "config.json")) return config_limit;
    if (privacy == .private_journal and
        (std.mem.eql(u8, leaf, "auth-cleanup.json") or std.mem.eql(u8, leaf, "curseforge-credentials.json"))) return journal_limit;
    return error.InvalidLeaf;
}

/// Loads validated authoritative bytes even while publication is uncertain, so
/// the caller can parse/reconcile them. Missing .vela/file is null, never defaults.
pub fn load(root: *Root, a: Allocator, leaf: []const u8, max_bytes: usize) Error!?OwnedBytes {
    const cap = try leafLimit(root.privacy, leaf);
    if (max_bytes == 0 or max_bytes > cap) return error.FileTooLarge;
    try root.ops.check_cancel(root.ops.context);
    try root.ops.validate_root(root.ops.context);
    return root.ops.load(root.ops.context, a, leaf, max_bytes, root.privacy);
}

/// Explicit startup operation: create only the storage directory, never a file.
/// Existing ordinary config ACLs are retained; private journal validation stays strict.
pub fn prepareStorage(root: *Root) Error!void {
    if (root.publication_uncertain) return error.CommitUncertain;
    if (root.busy) return error.OperationInProgress;
    root.busy = true;
    defer root.busy = false;
    try root.ops.check_cancel(root.ops.context);
    try root.ops.validate_root(root.ops.context);
    root.ops.ensure_directory(root.ops.context) catch |err| {
        if (err == error.CommitUncertain) root.publication_uncertain = true;
        return err;
    };
    root.ops.validate_root(root.ops.context) catch {
        root.publication_uncertain = true;
        return error.CommitUncertain;
    };
    root.ops.check_cancel(root.ops.context) catch {
        root.publication_uncertain = true;
        return error.CommitUncertain;
    };
}

/// Caller validation executes both before creating storage and just before move.
/// Before a possible target mutation errors keep their original classification.
/// Once move is invoked, every failure/cancellation maps to CommitUncertain.
/// Journals must still poison on prepublication persistence errors as they do now.
pub fn publish(root: *Root, leaf: []const u8, bytes: []const u8, check: PrecommitCheck) anyerror!void {
    if (root.publication_uncertain) return error.CommitUncertain;
    try publishInner(root, leaf, bytes, check);
}

/// Caller must parse/validate these authoritative bytes first. The adapter also
/// rereads and compares disk before staging and again before replacement; a
/// retained draft, missing file or changed disk cannot clear the barrier.
/// Removal is an authoritative references-only document rewrite, never unlink.
pub fn reconcile(root: *Root, leaf: []const u8, authoritative_bytes: []const u8, check: PrecommitCheck) anyerror!void {
    const cap = try leafLimit(root.privacy, leaf);
    if (authoritative_bytes.len > cap) return error.FileTooLarge;
    if (root.busy) return error.OperationInProgress;
    root.publication_uncertain = true;
    var validation: ReconcileCheck = .{ .leaf = leaf, .bytes = authoritative_bytes, .inner = check };
    try publishInner(root, leaf, authoritative_bytes, .{ .context = &validation, .run = ReconcileCheck.run });
    // publishInner clears uncertainty only after native publication, final
    // identity/security verification, final file flush and cancellation check.
}

const ReconcileCheck = struct {
    leaf: []const u8,
    bytes: []const u8,
    inner: PrecommitCheck,
    fn run(context: ?*anyopaque, root: *Root) anyerror!void {
        const self: *const ReconcileCheck = @ptrCast(@alignCast(context.?));
        var disk = (try load(root, root.allocator, self.leaf, try leafLimit(root.privacy, self.leaf))) orelse return error.JournalChanged;
        defer disk.deinit();
        if (!std.mem.eql(u8, disk.bytes, self.bytes)) return error.JournalChanged;
        try self.inner.run(self.inner.context, root);
    }
};

fn publishInner(root: *Root, leaf: []const u8, bytes: []const u8, check: PrecommitCheck) anyerror!void {
    const cap = try leafLimit(root.privacy, leaf);
    if (bytes.len > cap) return error.FileTooLarge;
    if (root.busy) return error.OperationInProgress;
    root.busy = true;
    defer root.busy = false;
    const ops = root.ops;
    try ops.check_cancel(ops.context);
    try ops.validate_root(ops.context);
    try check.run(check.context, root);
    ops.ensure_directory(ops.context) catch |err| {
        if (err == error.CommitUncertain) root.publication_uncertain = true;
        return err;
    };
    var name_buffer: [64]u8 = undefined;
    var temp_name: []const u8 = undefined;
    const temporary: Temporary = blk: {
        for (0..8) |_| {
            try ops.check_cancel(ops.context);
            var random: [16]u8 = undefined;
            try ops.random(ops.context, &random);
            temp_name = std.fmt.bufPrint(&name_buffer, ".vela-txn-{s}.tmp", .{std.fmt.bytesToHex(random, .lower)}) catch unreachable;
            const temp = ops.create_temp(ops.context, temp_name) catch |err| switch (err) {
                error.TemporaryNameCollision => continue,
                else => return err,
            };
            break :blk temp;
        }
        return error.PersistenceFailure;
    };
    var attempted = false;
    defer {
        ops.close_file(ops.context, temporary.handle);
        // After a possible move, this handle may be the authoritative file.
        // Never delete it by handle or guess that its old pathname is still ours.
        if (!attempted) ops.discard_temp(ops.context, temp_name, temporary.identity);
    }
    try ops.write(ops.context, temporary.handle, bytes);
    try ops.flush(ops.context, temporary.handle);
    try ops.verify_temp(ops.context, temporary, bytes.len);
    try ops.validate_root(ops.context);
    try check.run(check.context, root);
    try ops.check_cancel(ops.context);
    attempted = true;
    root.publication_uncertain = true;
    ops.move(ops.context, temp_name, leaf) catch return error.CommitUncertain;
    // Complete required final validation/flush even if cancellation arrived.
    ops.verify_final(ops.context, leaf, temporary.identity, bytes.len) catch return error.CommitUncertain;
    ops.check_cancel(ops.context) catch return error.CommitUncertain;
    root.publication_uncertain = false;
}

/// Pure Windows normalization, equally testable on Linux. No device namespace,
/// ADS, reserved DOS names, dot-dot, trailing-dot/space aliases or embedded NUL.
/// UNC roots normalize here; production rejects their unverified remote contract.
pub fn normalizeRoot(a: Allocator, path: []const u8) Error![]u8 {
    if (path.len == 0 or path.len > 32760 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidRoot;
    const converted = try a.dupe(u8, path);
    defer a.free(converted);
    for (converted) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    if (std.mem.startsWith(u8, converted, "\\\\?\\") or std.mem.startsWith(u8, converted, "\\\\.\\")) return error.InvalidRoot;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var start: usize = undefined;
    var required: usize = 0;
    if (converted.len >= 3 and std.ascii.isAlphabetic(converted[0]) and converted[1] == ':' and converted[2] == '\\') {
        try out.append(a, std.ascii.toUpper(converted[0]));
        try out.appendSlice(a, ":\\");
        start = 3;
    } else if (std.mem.startsWith(u8, converted, "\\\\")) {
        try out.appendSlice(a, "\\\\");
        start = 2;
        required = 2;
    } else return error.InvalidRoot;
    var components: usize = 0;
    var it = std.mem.splitScalar(u8, converted[start..], '\\');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, ".")) {
            if (components < required) return error.InvalidRoot;
            continue;
        }
        if (part.len > 255 or std.mem.eql(u8, part, "..") or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.InvalidRoot;
        for (part) |c| if (c < 32 or c == ':' or c == '<' or c == '>' or c == '"' or c == '|' or c == '?' or c == '*') return error.InvalidRoot;
        const stem_end = std.mem.indexOfScalar(u8, part, '.') orelse part.len;
        const stem = part[0..stem_end];
        if (std.ascii.eqlIgnoreCase(stem, "CON") or std.ascii.eqlIgnoreCase(stem, "PRN") or
            std.ascii.eqlIgnoreCase(stem, "AUX") or std.ascii.eqlIgnoreCase(stem, "NUL") or
            (stem.len == 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT")) and stem[3] >= '1' and stem[3] <= '9')) return error.InvalidRoot;
        if (out.items[out.items.len - 1] != '\\') try out.append(a, '\\');
        try out.appendSlice(a, part);
        components += 1;
    }
    if (components < required) return error.InvalidRoot;
    // Validate WTF-8 without changing the path or allocating a native handle.
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(a, out.items) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRoot;
    defer a.free(wide);
    if (wide.len > 32760) return error.InvalidRoot;
    return out.toOwnedSlice(a);
}

// ABI declarations below are isolated/lazy on non-Windows. Source references:
// fileapi: CreateFileW, BY_HANDLE_FILE_INFORMATION, GetFileInformationByHandle,
// GetDriveTypeW, GetVolumeInformationByHandleW, CreateDirectoryW.
// processthreadsapi/securitybaseapi: OpenProcessToken, GetTokenInformation,
// TOKEN_USER/SID_AND_ATTRIBUTES, GetSecurityDescriptorControl, GetAclInformation,
// ACL_SIZE_INFORMATION, GetAce, ACCESS_ALLOWED_ACE/ACE_HEADER, EqualSid.
// aclapi: GetSecurityInfo; sddl: ConvertSidToStringSidW and
// ConvertStringSecurityDescriptorToSecurityDescriptorW; winbase: LocalFree.
// All are documented at https://learn.microsoft.com/en-us/windows/win32/api/.
const Windows = struct {
    const w = std.os.windows;
    const Handle = w.HANDLE;
    const Guard = struct { handle: Handle, identity: Identity, prefix_len: usize };
    const FileInfo = extern struct {
        attributes: u32,
        creation: w.FILETIME,
        access: w.FILETIME,
        write_time: w.FILETIME,
        volume: u32,
        size_high: u32,
        size_low: u32,
        links: u32,
        index_high: u32,
        index_low: u32,
        fn identity(self: FileInfo) Identity {
            return .{ .volume = self.volume, .file = (@as(u64, self.index_high) << 32) | self.index_low };
        }
        fn size(self: FileInfo) u64 {
            return (@as(u64, self.size_high) << 32) | self.size_low;
        }
    };
    const SidAndAttributes = extern struct { sid: ?*anyopaque, attributes: u32 };
    const TokenUser = extern struct { user: SidAndAttributes };
    const AclSize = extern struct { count: u32, used: u32, free: u32 };
    const AceHeader = extern struct { kind: u8, flags: u8, size: u16 };
    const AllowedAce = extern struct { header: AceHeader, mask: u32, sid_start: u32 };
    comptime {
        std.debug.assert(@sizeOf(FileInfo) == 52);
        std.debug.assert(@sizeOf(AclSize) == 12);
        std.debug.assert(@sizeOf(AceHeader) == 4);
        std.debug.assert(@offsetOf(AllowedAce, "sid_start") == 8);
        std.debug.assert(@sizeOf(TokenUser) == (if (@sizeOf(usize) == 8) 16 else 8));
    }
    extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*const w.SECURITY_ATTRIBUTES, u32, u32, ?Handle) callconv(.winapi) Handle;
    extern "kernel32" fn CreateDirectoryW([*:0]const u16, ?*const w.SECURITY_ATTRIBUTES) callconv(.winapi) i32;
    extern "kernel32" fn GetFileInformationByHandle(Handle, *FileInfo) callconv(.winapi) i32;
    extern "kernel32" fn GetFileType(Handle) callconv(.winapi) u32;
    extern "kernel32" fn GetDriveTypeW(?[*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GetVolumeInformationByHandleW(Handle, ?[*]u16, u32, ?*u32, ?*u32, ?*u32, ?[*]u16, u32) callconv(.winapi) i32;
    extern "kernel32" fn MoveFileExW([*:0]const u16, ?[*:0]const u16, u32) callconv(.winapi) i32;
    extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "advapi32" fn OpenProcessToken(Handle, u32, *Handle) callconv(.winapi) i32;
    extern "advapi32" fn GetTokenInformation(Handle, u32, ?*anyopaque, u32, *u32) callconv(.winapi) i32;
    extern "advapi32" fn ConvertSidToStringSidW(*anyopaque, *?[*:0]u16) callconv(.winapi) i32;
    extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW([*:0]const u16, u32, *?*anyopaque, ?*u32) callconv(.winapi) i32;
    extern "advapi32" fn GetSecurityInfo(Handle, u32, u32, ?*?*anyopaque, ?*?*anyopaque, ?*?*anyopaque, ?*?*anyopaque, *?*anyopaque) callconv(.winapi) u32;
    extern "advapi32" fn GetSecurityDescriptorControl(*anyopaque, *u16, *u32) callconv(.winapi) i32;
    extern "advapi32" fn GetAclInformation(*anyopaque, *anyopaque, u32, u32) callconv(.winapi) i32;
    extern "advapi32" fn GetAce(*anyopaque, u32, *?*anyopaque) callconv(.winapi) i32;
    extern "advapi32" fn EqualSid(*anyopaque, *anyopaque) callconv(.winapi) i32;
    extern "advapi32" fn IsValidSid(*anyopaque) callconv(.winapi) i32;
    extern "advapi32" fn GetLengthSid(*anyopaque) callconv(.winapi) u32;

    allocator: Allocator,
    io: Io,
    privacy: Privacy = .private_journal,
    root_utf8: []const u8 = "",
    root_wide: ?[:0]u16 = null,
    storage_wide: ?[:0]u16 = null,
    ancestors: std.ArrayList(Guard) = .empty,
    directory: ?Guard = null,
    writer: ?Handle = null,
    token_buffer: []u64 = &.{},
    user_sid: ?*anyopaque = null,
    file_sd: ?*anyopaque = null,
    dir_sd: ?*anyopaque = null,

    fn cast(ctx: *anyopaque) *Windows {
        return @ptrCast(@alignCast(ctx));
    }
    fn operations(self: *Windows) NativeOps {
        return .{ .context = self, .open = open, .close = close, .acquire_writer = acquireWriterNative, .check_cancel = checkCancel, .validate_root = validateRoot, .load = read, .ensure_directory = ensureDirectory, .random = random, .create_temp = createTemp, .write = write, .flush = flush, .verify_temp = verifyTemp, .move = move, .verify_final = verifyFinal, .close_file = closeFile, .discard_temp = discardTemp };
    }
    fn checkCancel(ctx: *anyopaque) Error!void {
        cast(ctx).io.checkCancel() catch return error.Cancelled;
    }
    fn lastError() u32 {
        return @backingInt(w.GetLastError());
    }
    fn failure() Error {
        return switch (lastError()) {
            8, 14 => error.OutOfMemory,
            else => error.PersistenceFailure,
        };
    }
    fn asFile(handle: usize) Io.File {
        return .{ .handle = @ptrFromInt(handle), .flags = .{ .nonblocking = false } };
    }
    fn freeLocal(ptr: ?*anyopaque) void {
        if (ptr) |p| {
            _ = LocalFree(p);
        }
    }
    fn cleanup(self: *Windows) void {
        if (self.writer) |handle| w.CloseHandle(handle);
        if (self.directory) |g| w.CloseHandle(g.handle);
        var i = self.ancestors.items.len;
        while (i != 0) {
            i -= 1;
            w.CloseHandle(self.ancestors.items[i].handle);
        }
        self.ancestors.deinit(self.allocator);
        if (self.root_wide) |p| self.allocator.free(p);
        if (self.storage_wide) |p| self.allocator.free(p);
        self.allocator.free(self.token_buffer);
        freeLocal(self.file_sd);
        freeLocal(self.dir_sd);
    }
    fn acquireWriterNative(ctx: *anyopaque) Error!void {
        const self = cast(ctx);
        if (self.writer != null) return;
        // OPEN_ALWAYS, OPEN_REPARSE_POINT; deny write and delete sharing for the
        // complete lifetime. Ancestor handles already prevent root substitution.
        const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\.vela-writer.lock");
        const root = self.root_wide.?;
        const separator: usize = if (root.len != 0 and root[root.len - 1] == '\\') 1 else 0;
        const wide = try self.allocator.allocSentinel(u16, root.len + suffix.len - separator, 0);
        defer self.allocator.free(wide);
        @memcpy(wide[0..root.len], root);
        @memcpy(wide[root.len..], suffix[separator..]);
        const handle = CreateFileW(wide, 0xc0000000 | 0x20000, 1, null, 4, 0x200000 | 0x80, null);
        if (handle == w.INVALID_HANDLE_VALUE) return if (lastError() == 32 or lastError() == 33) error.LauncherRootInUse else failure();
        errdefer w.CloseHandle(handle);
        _ = try self.inspect(handle, false);
        self.writer = handle;
    }

    fn close(ctx: *anyopaque) void {
        const self = cast(ctx);
        const a = self.allocator;
        self.cleanup();
        a.destroy(self);
    }
    fn open(ctx: *anyopaque, normalized: []const u8, privacy: Privacy) Error!void {
        const self = cast(ctx);
        errdefer self.cleanup();
        self.privacy = privacy;
        self.root_utf8 = normalized;
        try checkCancel(ctx);
        // A UNC path or mapped network drive has no admitted durability contract.
        if (std.mem.startsWith(u8, normalized, "\\\\")) return error.UnsupportedDurability;
        const drive = [_:0]u16{ normalized[0], ':', '\\' };
        if (GetDriveTypeW(&drive) != 3) return error.UnsupportedDurability; // DRIVE_FIXED
        const prefixed = try std.fmt.allocPrint(self.allocator, "\\\\?\\{s}", .{normalized});
        defer self.allocator.free(prefixed);
        self.root_wide = std.unicode.wtf8ToWtf16LeAllocZ(self.allocator, prefixed) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRoot;
        const storage = try std.fmt.allocPrint(self.allocator, "{s}{s}.vela", .{ prefixed, if (std.mem.endsWith(u8, prefixed, "\\")) "" else "\\" });
        defer self.allocator.free(storage);
        self.storage_wide = std.unicode.wtf8ToWtf16LeAllocZ(self.allocator, storage) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRoot;
        const wide = self.root_wide.?;
        // Native drive-root and component prefixes. Retain all handles to prevent
        // a directory substitution while a later Win32 path-based move is running.
        var end: usize = 7; // internally generated \\?\C:\ prefix
        while (true) {
            const prefix = try self.allocator.dupeSentinel(u16, wide[0..end], 0);
            defer self.allocator.free(prefix);
            const handle = (try self.openDirectory(prefix, 1)) orelse return error.InvalidRoot;
            errdefer w.CloseHandle(handle);
            const info = try self.inspect(handle, true);
            try self.ancestors.append(self.allocator, .{ .handle = handle, .identity = info.identity(), .prefix_len = end });
            if (end == wide.len) break;
            const next_start = if (wide[end] == '\\') end + 1 else end;
            end = if (std.mem.indexOfScalar(u16, wide[next_start..], '\\')) |n| next_start + n else wide.len;
        }
        var fs: [32]u16 = @splat(0);
        var flags: u32 = 0;
        var serial: u32 = 0;
        const launcher = self.ancestors.items[self.ancestors.items.len - 1];
        if (GetVolumeInformationByHandleW(launcher.handle, null, 0, &serial, null, &flags, &fs, fs.len) == 0) return error.UnsupportedDurability;
        if (!std.mem.eql(u16, std.mem.sliceTo(&fs, 0), &[_]u16{ 'N', 'T', 'F', 'S' }) or flags & 8 == 0 or serial != launcher.identity.volume) return error.UnsupportedDurability;
        try self.initSecurity();
        _ = try self.existingDirectory();
        try checkCancel(ctx);
    }
    fn initSecurity(self: *Windows) Error!void {
        var token: Handle = undefined;
        if (OpenProcessToken(w.GetCurrentProcess(), 8, &token) == 0) return failure(); // TOKEN_QUERY
        defer w.CloseHandle(token);
        var length: u32 = 0;
        if (GetTokenInformation(token, 1, null, 0, &length) != 0 or lastError() != 122 or length < @sizeOf(TokenUser) or length > 64 * 1024) return error.InsecureJournal;
        self.token_buffer = try self.allocator.alloc(u64, (@as(usize, length) + 7) / 8);
        if (GetTokenInformation(token, 1, @ptrCast(self.token_buffer.ptr), length, &length) == 0) return failure();
        const user: *const TokenUser = @ptrCast(self.token_buffer.ptr);
        self.user_sid = user.user.sid orelse return error.InsecureJournal;
        if (IsValidSid(self.user_sid.?) == 0) return error.InsecureJournal;
        var sid_text: ?[*:0]u16 = null;
        if (ConvertSidToStringSidW(self.user_sid.?, &sid_text) == 0) {
            if (sid_text) |allocated| freeLocal(@ptrCast(allocated));
            return failure();
        }
        const text = sid_text orelse return error.InsecureJournal;
        defer freeLocal(@ptrCast(text));
        const sid_utf8 = try std.unicode.wtf16LeToWtf8Alloc(self.allocator, std.mem.span(text));
        defer self.allocator.free(sid_utf8);
        self.file_sd = try self.makeDescriptor(sid_utf8, "");
        self.dir_sd = try self.makeDescriptor(sid_utf8, "OICI");
    }
    fn makeDescriptor(self: *Windows, sid: []const u8, inheritance: []const u8) Error!*anyopaque {
        const text = try std.fmt.allocPrint(self.allocator, "O:{s}D:P(A;{s};FA;;;{s})", .{ sid, inheritance, sid });
        defer self.allocator.free(text);
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(self.allocator, text) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InsecureJournal;
        defer self.allocator.free(wide);
        var descriptor: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(wide, 1, &descriptor, null) == 0) {
            freeLocal(descriptor);
            return failure();
        }
        return descriptor orelse error.InsecureJournal;
    }
    fn securityAttributes(descriptor: *anyopaque) w.SECURITY_ATTRIBUTES {
        return .{ .nLength = @sizeOf(w.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = descriptor, .bInheritHandle = .FALSE };
    }
    fn inspect(_: *Windows, handle: Handle, directory: bool) Error!FileInfo {
        var info: FileInfo = undefined;
        if (GetFileType(handle) != 1 or GetFileInformationByHandle(handle, &info) == 0) return error.InsecureJournal;
        if (info.attributes & (0x400 | 0x40) != 0 or (info.attributes & 0x10 != 0) != directory) return error.InsecureJournal;
        if (!directory and info.links != 1) return error.InsecureJournal;
        return info;
    }
    fn inspectPrivate(self: *Windows, handle: Handle, directory: bool) Error!void {
        var owner: ?*anyopaque = null;
        var acl: ?*anyopaque = null;
        var descriptor: ?*anyopaque = null;
        const status = GetSecurityInfo(handle, 1, 1 | 4, &owner, null, &acl, null, &descriptor);
        defer freeLocal(descriptor);
        if (status != 0) return if (status == 8 or status == 14) error.OutOfMemory else error.InsecureJournal;
        const sd = descriptor orelse return error.InsecureJournal;
        const sid = owner orelse return error.InsecureJournal;
        const dacl = acl orelse return error.InsecureJournal; // never null/unrestricted
        if (IsValidSid(sid) == 0 or EqualSid(sid, self.user_sid.?) == 0) return error.InsecureJournal;
        var control: u16 = 0;
        var revision: u32 = 0;
        if (GetSecurityDescriptorControl(sd, &control, &revision) == 0 or control & 0x1004 != 0x1004) return error.InsecureJournal;
        var size: AclSize = undefined;
        if (GetAclInformation(dacl, &size, @sizeOf(AclSize), 2) == 0 or size.count != 1) return error.InsecureJournal;
        var ace_ptr: ?*anyopaque = null;
        if (GetAce(dacl, 0, &ace_ptr) == 0) return error.InsecureJournal;
        const ace: *const AllowedAce = @ptrCast(@alignCast(ace_ptr orelse return error.InsecureJournal));
        if (ace.header.kind != 0 or ace.header.flags != @as(u8, if (directory) 3 else 0) or ace.header.size < 16) return error.InsecureJournal;
        if (ace.mask != @as(u32, @bitCast(w.ACCESS_MASK.Specific.File.ALL_ACCESS))) return error.InsecureJournal;
        const ace_sid: *anyopaque = @ptrCast(@constCast(&ace.sid_start));
        if (IsValidSid(ace_sid) == 0 or GetLengthSid(ace_sid) > @as(u32, ace.header.size) - 8 or EqualSid(ace_sid, self.user_sid.?) == 0) return error.InsecureJournal;
    }
    fn openDirectory(self: *Windows, path: [:0]const u16, share: u32) Error!?Handle {
        _ = self;
        const handle = CreateFileW(path, 0x20000 | 0x80, share, null, 3, 0x2000000 | 0x200000, null);
        if (handle == w.INVALID_HANDLE_VALUE) return switch (lastError()) {
            2, 3 => null,
            8, 14 => error.OutOfMemory,
            else => error.InsecureJournal,
        };
        return handle;
    }
    fn existingDirectory(self: *Windows) Error!?Guard {
        if (self.directory) |guard| return guard;
        const handle = (try self.openDirectory(self.storage_wide.?, 1)) orelse return null;
        errdefer w.CloseHandle(handle);
        const info = try self.inspect(handle, true);
        if (info.volume != self.ancestors.items[self.ancestors.items.len - 1].identity.volume) return error.UnsupportedDurability;
        if (self.privacy == .private_journal) try self.inspectPrivate(handle, true);
        const guard: Guard = .{ .handle = handle, .identity = info.identity(), .prefix_len = self.storage_wide.?.len };
        self.directory = guard;
        return guard;
    }
    fn validateRoot(ctx: *anyopaque) Error!void {
        const self = cast(ctx);
        const drive = [_:0]u16{ self.root_utf8[0], ':', '\\' };
        if (GetDriveTypeW(&drive) != 3) return error.UnsupportedDurability;
        for (self.ancestors.items) |guard| {
            const info = try self.inspect(guard.handle, true);
            if (!Identity.eql(info.identity(), guard.identity)) return error.JournalChanged;
            // Win32 moves resolve paths again. Confirm that each path still
            // names the held object, including after a drive mapping change.
            const prefix = try self.allocator.dupeSentinel(u16, self.root_wide.?[0..guard.prefix_len], 0);
            defer self.allocator.free(prefix);
            const current = (try self.openDirectory(prefix, 1)) orelse return error.JournalChanged;
            defer w.CloseHandle(current);
            const named = try self.inspect(current, true);
            if (!Identity.eql(named.identity(), guard.identity)) return error.JournalChanged;
        }
        if (self.directory) |guard| {
            const info = try self.inspect(guard.handle, true);
            if (!Identity.eql(info.identity(), guard.identity)) return error.JournalChanged;
            const current = (try self.openDirectory(self.storage_wide.?, 1)) orelse return error.JournalChanged;
            defer w.CloseHandle(current);
            const named = try self.inspect(current, true);
            if (!Identity.eql(named.identity(), guard.identity)) return error.JournalChanged;
            if (self.privacy == .private_journal) {
                try self.inspectPrivate(guard.handle, true);
                try self.inspectPrivate(current, true);
            }
        }
    }
    fn pathInStorage(self: *Windows, leaf: []const u8) Error![:0]u16 {
        const name = std.unicode.wtf8ToWtf16LeAllocZ(self.allocator, leaf) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidLeaf;
        defer self.allocator.free(name);
        const directory = self.storage_wide.?;
        const result = try self.allocator.allocSentinel(u16, directory.len + 1 + name.len, 0);
        @memcpy(result[0..directory.len], directory);
        result[directory.len] = '\\';
        @memcpy(result[directory.len + 1 ..], name);
        return result;
    }
    fn read(ctx: *anyopaque, a: Allocator, leaf: []const u8, max_bytes: usize, privacy: Privacy) Error!?OwnedBytes {
        const self = cast(ctx);
        if (try self.existingDirectory() == null) return null;
        const path = try self.pathInStorage(leaf);
        defer self.allocator.free(path);
        const handle = CreateFileW(path, 0x80000000 | 0x20000, 1, null, 3, 0x200000, null);
        if (handle == w.INVALID_HANDLE_VALUE) return switch (lastError()) {
            2 => null,
            8, 14 => error.OutOfMemory,
            else => error.InsecureJournal,
        };
        defer w.CloseHandle(handle);
        const before = try self.inspect(handle, false);
        if (before.volume != self.directory.?.identity.volume) return error.UnsupportedDurability;
        if (privacy == .private_journal) try self.inspectPrivate(handle, false);
        if (before.size() > max_bytes) return error.FileTooLarge;
        const buffer = try a.alloc(u8, max_bytes + 1);
        errdefer a.free(buffer);
        const n = asFile(@intFromPtr(handle)).readPositionalAll(self.io, buffer, 0) catch |err| return if (err == error.Cancelled) error.Cancelled else error.PersistenceFailure;
        if (n > max_bytes) return error.FileTooLarge;
        const after = try self.inspect(handle, false);
        if (!Identity.eql(before.identity(), after.identity()) or after.size() != n or before.size() != after.size()) return error.JournalChanged;
        if (privacy == .private_journal) try self.inspectPrivate(handle, false);
        try validateRoot(ctx);
        try checkCancel(ctx);
        return .{ .bytes = buffer[0..n], .allocation = buffer, .allocator = a };
    }
    fn random(ctx: *anyopaque, bytes: []u8) Error!void {
        cast(ctx).io.randomSecure(bytes) catch |err| return if (err == error.Cancelled) error.Cancelled else error.PersistenceFailure;
    }
    fn ensureDirectory(ctx: *anyopaque) Error!void {
        const self = cast(ctx);
        try validateRoot(ctx);
        if (try self.existingDirectory() != null) return;
        var bytes: [16]u8 = undefined;
        try random(ctx, &bytes);
        const name = try std.fmt.allocPrint(self.allocator, ".vela-dir-{s}.tmp", .{std.fmt.bytesToHex(bytes, .lower)});
        defer self.allocator.free(name);
        const utf8 = try std.fmt.allocPrint(self.allocator, "\\\\?\\{s}{s}{s}", .{ self.root_utf8, if (std.mem.endsWith(u8, self.root_utf8, "\\")) "" else "\\", name });
        defer self.allocator.free(utf8);
        const path = std.unicode.wtf8ToWtf16LeAllocZ(self.allocator, utf8) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRoot;
        defer self.allocator.free(path);
        const attributes = securityAttributes(self.dir_sd.?);
        if (CreateDirectoryW(path, &attributes) == 0) return failure();
        const handle = CreateFileW(path, 0x10000 | 0x20000 | 0x80, 7, null, 3, 0x2000000 | 0x200000, null);
        if (handle == w.INVALID_HANDLE_VALUE) return failure();
        var attempted = false;
        var handle_open = true;
        defer if (handle_open) {
            if (!attempted) markDelete(handle);
            w.CloseHandle(handle);
        };
        const original = try self.inspect(handle, true);
        try self.inspectPrivate(handle, true);
        try checkCancel(ctx);
        attempted = true;
        // No replacement of an existing directory and no copy across volumes.
        if (MoveFileExW(path, self.storage_wide.?, 8) == 0) return error.CommitUncertain;
        // Release the temporary DELETE access before locking the final directory
        // without share-delete. Never delete the moved directory on an error.
        w.CloseHandle(handle);
        handle_open = false;
        const final = self.existingDirectory() catch return error.CommitUncertain;
        const guard = final orelse return error.CommitUncertain;
        if (!Identity.eql(guard.identity, original.identity())) return error.CommitUncertain;
        self.inspectPrivate(guard.handle, true) catch return error.CommitUncertain;
        checkCancel(ctx) catch return error.CommitUncertain;
    }
    fn createTemp(ctx: *anyopaque, name: []const u8) Error!Temporary {
        const self = cast(ctx);
        const path = try self.pathInStorage(name);
        defer self.allocator.free(path);
        const attributes = securityAttributes(self.file_sd.?);
        // CREATE_NEW; protected descriptor supplied before the name is visible.
        // Retain the handle across MoveFileExW; share-delete permits that move.
        const handle = CreateFileW(path, 0xc0000000 | 0x20000 | 0x10000, 7, &attributes, 1, 0x80000000 | 0x200000 | 0x80, null);
        if (handle == w.INVALID_HANDLE_VALUE) return switch (lastError()) {
            80, 183 => error.TemporaryNameCollision,
            else => failure(),
        };
        errdefer {
            markDelete(handle);
            w.CloseHandle(handle);
        }
        const info = try self.inspect(handle, false);
        try self.inspectPrivate(handle, false);
        if (info.volume != self.directory.?.identity.volume or info.size() != 0) return error.InsecureJournal;
        return .{ .handle = @intFromPtr(handle), .identity = info.identity() };
    }
    fn write(ctx: *anyopaque, handle: usize, bytes: []const u8) Error!void {
        asFile(handle).writeStreamingAll(cast(ctx).io, bytes) catch |err| return if (err == error.Cancelled) error.Cancelled else error.PersistenceFailure;
    }
    fn flush(ctx: *anyopaque, handle: usize) Error!void {
        asFile(handle).sync(cast(ctx).io) catch |err| return if (err == error.Cancelled) error.Cancelled else error.PersistenceFailure;
    }
    fn verifyTemp(ctx: *anyopaque, temp: Temporary, size: usize) Error!void {
        const self = cast(ctx);
        const handle: Handle = @ptrFromInt(temp.handle);
        const info = try self.inspect(handle, false);
        if (!Identity.eql(info.identity(), temp.identity) or info.size() != size) return error.JournalChanged;
        try self.inspectPrivate(handle, false);
    }
    fn move(ctx: *anyopaque, source: []const u8, target: []const u8) Error!void {
        const self = cast(ctx);
        const from = try self.pathInStorage(source);
        defer self.allocator.free(from);
        const to = try self.pathInStorage(target);
        defer self.allocator.free(to);
        // MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH. No copy/delay.
        if (MoveFileExW(from, to, 1 | 8) == 0) return error.CommitUncertain;
    }
    fn verifyFinal(ctx: *anyopaque, leaf: []const u8, identity: Identity, size: usize) Error!void {
        const self = cast(ctx);
        const path = try self.pathInStorage(leaf);
        defer self.allocator.free(path);
        const handle = CreateFileW(path, 0xc0000000 | 0x20000, 7, null, 3, 0x200000, null);
        if (handle == w.INVALID_HANDLE_VALUE) return failure();
        defer w.CloseHandle(handle);
        const info = try self.inspect(handle, false);
        if (!Identity.eql(info.identity(), identity) or info.size() != size) return error.JournalChanged;
        try self.inspectPrivate(handle, false);
        try flush(ctx, @intFromPtr(handle));
        const after = try self.inspect(handle, false);
        if (!Identity.eql(after.identity(), identity) or after.size() != size) return error.JournalChanged;
        try self.inspectPrivate(handle, false);
        try validateRoot(ctx);
    }
    fn closeFile(_: *anyopaque, handle: usize) void {
        w.CloseHandle(@ptrFromInt(handle));
    }
    fn markDelete(handle: Handle) void {
        var disposition: w.FILE.DISPOSITION.INFORMATION = .{ .DeleteFile = .TRUE };
        var status: w.IO_STATUS_BLOCK = undefined;
        _ = w.ntdll.NtSetInformationFile(handle, &status, &disposition, @sizeOf(@TypeOf(disposition)), .Disposition);
    }
    fn discardTemp(ctx: *anyopaque, name: []const u8, identity: Identity) void {
        const self = cast(ctx);
        const path = self.pathInStorage(name) catch return;
        defer self.allocator.free(path);
        // Original handle was closed first. Deny share-delete on this reopened
        // identity-checked temp, so markDelete cannot erase a substituted target.
        const handle = CreateFileW(path, 0x10000 | 0x20000 | 0x80, 3, null, 3, 0x200000, null);
        if (handle == w.INVALID_HANDLE_VALUE) return;
        defer w.CloseHandle(handle);
        const info = self.inspect(handle, false) catch return;
        if (!Identity.eql(info.identity(), identity)) return;
        self.inspectPrivate(handle, false) catch return;
        markDelete(handle);
    }
};
