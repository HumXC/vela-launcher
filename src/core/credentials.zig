//! Native credential storage. No plaintext fallback and no subprocesses.
//! Link Linux with libc (libdl on older glibc), Windows with advapi32/kernel32,
//! and macOS with Security/CoreFoundation. Linux requires libsecret-1.so.0 at runtime.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Error = error{ Unavailable, Denied, NotFound, InvalidReference, InvalidSecret, TooLarge, StorageFailure, OutOfMemory };
pub const Reference = [32]u8;
pub const max_secret_bytes = 16 * 1024;

pub fn validateReference(reference: []const u8) bool {
    if (reference.len != 32) return false;
    for (reference) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

fn validateSecret(bytes: []const u8) Error!void {
    if (bytes.len > max_secret_bytes) return error.TooLarge;
    if (bytes.len == 0 or std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidSecret;
}

pub const Secret = struct {
    allocator: Allocator,
    bytes: []u8,

    pub fn deinit(self: *Secret) void {
        std.crypto.secureZero(u8, self.bytes);
        // Allocator.free poisons bytes in Debug; preserve the wipe through the free hook.
        if (self.bytes.len != 0) self.allocator.rawFree(self.bytes, .fromByteUnits(@alignOf(u8)), @returnAddress());
        self.bytes = &.{};
    }
};

pub const Store = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (*anyopaque, []const u8, []const u8) Error!void,
        get: *const fn (*anyopaque, Allocator, []const u8) Error!Secret,
        delete: *const fn (*anyopaque, []const u8) Error!void,
    };

    /// A native write error is commit-ambiguous: the vault may have stored the
    /// value before cancellation or a failed reply. Keep the reference for retry
    /// or explicit cleanup; never infer that an error means nothing was written.
    pub fn put(self: Store, reference: []const u8, secret: []const u8) Error!void {
        if (!validateReference(reference)) return error.InvalidReference;
        try validateSecret(secret);
        return self.vtable.put(self.ctx, reference, secret);
    }

    pub fn get(self: Store, allocator: Allocator, reference: []const u8) Error!Secret {
        if (!validateReference(reference)) return error.InvalidReference;
        var result = try self.vtable.get(self.ctx, allocator, reference);
        validateSecret(result.bytes) catch |err| {
            result.deinit();
            return err;
        };
        return result;
    }

    /// Deletion errors can likewise be commit-ambiguous; retain the reference
    /// until a retry succeeds or reports NotFound.
    pub fn delete(self: Store, reference: []const u8) Error!void {
        if (!validateReference(reference)) return error.InvalidReference;
        return self.vtable.delete(self.ctx, reference);
    }
};

const Backend = switch (builtin.os.tag) {
    .windows => Windows,
    .macos => MacOS,
    .linux => Linux,
    else => Unsupported,
};

/// Keep this object at a stable address after store(); it must outlive every Store.
/// Serialize operations against deinit. init does not read/write/unlock a vault.
pub const Native = struct {
    backend: Backend,

    pub fn init() Error!Native {
        return .{ .backend = try Backend.init() };
    }

    pub fn deinit(self: *Native) void {
        self.backend.deinit();
    }

    pub fn store(self: *Native) Store {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Store.VTable = .{ .put = put, .get = get, .delete = delete };

    fn put(ctx: *anyopaque, reference: []const u8, secret: []const u8) Error!void {
        const self: *Native = @ptrCast(@alignCast(ctx));
        return self.backend.put(reference, secret);
    }

    fn get(ctx: *anyopaque, allocator: Allocator, reference: []const u8) Error!Secret {
        const self: *Native = @ptrCast(@alignCast(ctx));
        return self.backend.get(allocator, reference);
    }

    fn delete(ctx: *anyopaque, reference: []const u8) Error!void {
        const self: *Native = @ptrCast(@alignCast(ctx));
        return self.backend.delete(reference);
    }
};

fn copySecret(allocator: Allocator, bytes: []const u8) Error!Secret {
    try validateSecret(bytes);
    return .{ .allocator = allocator, .bytes = allocator.dupe(u8, bytes) catch return error.OutOfMemory };
}

const Unsupported = struct {
    fn init() Error!Unsupported {
        return error.Unavailable;
    }
    fn deinit(_: *Unsupported) void {}
    fn put(_: *Unsupported, _: []const u8, _: []const u8) Error!void {
        return error.Unavailable;
    }
    fn get(_: *Unsupported, _: Allocator, _: []const u8) Error!Secret {
        return error.Unavailable;
    }
    fn delete(_: *Unsupported, _: []const u8) Error!void {
        return error.Unavailable;
    }
};

const Windows = struct {
    const winapi: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86) .{ .x86_stdcall = .{} } else .c;
    const Credential = extern struct {
        flags: u32 = 0,
        kind: u32 = 1,
        target: ?[*:0]u16 = null,
        comment: ?[*:0]u16 = null,
        last_written: extern struct { low: u32 = 0, high: u32 = 0 } = .{},
        blob_size: u32 = 0,
        blob: ?[*]u8 = null,
        persist: u32 = 2,
        attribute_count: u32 = 0,
        attributes: ?*anyopaque = null,
        alias: ?[*:0]u16 = null,
        username: ?[*:0]u16 = null,
    };
    extern "advapi32" fn CredWriteW(*const Credential, u32) callconv(winapi) i32;
    extern "advapi32" fn CredReadW([*:0]const u16, u32, u32, *?*Credential) callconv(winapi) i32;
    extern "advapi32" fn CredDeleteW([*:0]const u16, u32, u32) callconv(winapi) i32;
    extern "advapi32" fn CredFree(*anyopaque) callconv(winapi) void;
    extern "kernel32" fn GetLastError() callconv(winapi) u32;
    const prefix = "VelaLauncher:auth:";
    const Target = [prefix.len + 32:0]u16;

    fn target(reference: []const u8) Target {
        var value: Target = undefined;
        for (prefix, 0..) |c, i| value[i] = c;
        for (reference, prefix.len..) |c, i| value[i] = c;
        value[value.len] = 0;
        return value;
    }
    fn failure() Error {
        return switch (GetLastError()) {
            5, 1314 => error.Denied,
            1168 => error.NotFound,
            1312, 1058 => error.Unavailable,
            8, 14 => error.OutOfMemory,
            else => error.StorageFailure,
        };
    }
    fn init() Error!Windows {
        return .{};
    }
    fn deinit(_: *Windows) void {}
    fn put(_: *Windows, reference: []const u8, bytes: []const u8) Error!void {
        if (bytes.len > 2560) return error.TooLarge;
        var name = target(reference);
        var credential: Credential = .{ .target = &name, .blob_size = @intCast(bytes.len), .blob = @constCast(bytes.ptr) };
        if (CredWriteW(&credential, 0) == 0) return failure();
    }
    fn get(_: *Windows, allocator: Allocator, reference: []const u8) Error!Secret {
        const name = target(reference);
        var credential: ?*Credential = null;
        if (CredReadW(&name, 1, 0, &credential) == 0) return failure();
        const result = credential orelse return error.StorageFailure;
        defer CredFree(result);
        const ptr = result.blob orelse return error.InvalidSecret;
        const bytes = ptr[0..result.blob_size];
        defer std.crypto.secureZero(u8, bytes);
        if (bytes.len > 2560) return error.TooLarge;
        return copySecret(allocator, bytes);
    }
    fn delete(_: *Windows, reference: []const u8) Error!void {
        const name = target(reference);
        if (CredDeleteW(&name, 1, 0) == 0) return failure();
    }
};

const MacOS = struct {
    const Ref = *const anyopaque;
    const KeyCallbacks = extern struct { version: isize, retain: ?Ref, release: ?Ref, copy_description: ?Ref, equal: ?Ref, hash: ?Ref };
    const ValueCallbacks = extern struct { version: isize, retain: ?Ref, release: ?Ref, copy_description: ?Ref, equal: ?Ref };
    extern "Security" const kSecClass: Ref;
    extern "Security" const kSecClassGenericPassword: Ref;
    extern "Security" const kSecAttrService: Ref;
    extern "Security" const kSecAttrAccount: Ref;
    extern "Security" const kSecUseAuthenticationUI: Ref;
    extern "Security" const kSecUseAuthenticationUIFail: Ref;
    extern "Security" const kSecUseDataProtectionKeychain: Ref;
    extern "Security" const kSecReturnData: Ref;
    extern "Security" const kSecMatchLimit: Ref;
    extern "Security" const kSecMatchLimitOne: Ref;
    extern "Security" const kSecValueData: Ref;
    extern "CoreFoundation" const kCFBooleanTrue: Ref;
    extern "CoreFoundation" const kCFAllocatorNull: Ref;
    extern "CoreFoundation" const kCFTypeDictionaryKeyCallBacks: KeyCallbacks;
    extern "CoreFoundation" const kCFTypeDictionaryValueCallBacks: ValueCallbacks;
    extern "CoreFoundation" fn CFDictionaryCreate(?Ref, [*]const Ref, [*]const Ref, isize, *const KeyCallbacks, *const ValueCallbacks) callconv(.c) ?Ref;
    extern "CoreFoundation" fn CFStringCreateWithBytes(?Ref, [*]const u8, isize, u32, u8) callconv(.c) ?Ref;
    extern "CoreFoundation" fn CFDataCreateWithBytesNoCopy(?Ref, [*]const u8, isize, Ref) callconv(.c) ?Ref;
    extern "CoreFoundation" fn CFDataGetLength(Ref) callconv(.c) isize;
    extern "CoreFoundation" fn CFDataGetBytePtr(Ref) callconv(.c) ?[*]const u8;
    extern "CoreFoundation" fn CFDataGetTypeID() callconv(.c) usize;
    extern "CoreFoundation" fn CFGetTypeID(Ref) callconv(.c) usize;
    extern "CoreFoundation" fn CFRelease(Ref) callconv(.c) void;
    extern "Security" fn SecItemAdd(Ref, ?*?Ref) callconv(.c) i32;
    extern "Security" fn SecItemCopyMatching(Ref, *?Ref) callconv(.c) i32;
    extern "Security" fn SecItemUpdate(Ref, Ref) callconv(.c) i32;
    extern "Security" fn SecItemDelete(Ref) callconv(.c) i32;

    fn status(code: i32) Error!void {
        return switch (code) {
            0 => {},
            -25300 => error.NotFound,
            -25293, -25308, -128, -34018 => error.Denied,
            -25291, -25294, -25307 => error.Unavailable,
            -108 => error.OutOfMemory,
            else => error.StorageFailure,
        };
    }
    fn init() Error!MacOS {
        return .{};
    }
    fn deinit(_: *MacOS) void {}
    fn dictionary(keys: []const Ref, values: []const Ref) Error!Ref {
        return CFDictionaryCreate(null, keys.ptr, values.ptr, @intCast(keys.len), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse error.OutOfMemory;
    }
    fn string(bytes: []const u8) Error!Ref {
        return CFStringCreateWithBytes(null, bytes.ptr, @intCast(bytes.len), 0x08000100, 0) orelse error.OutOfMemory;
    }
    // Data-protection keychain supports per-request no-UI authentication. Do not
    // fall back to legacy global interaction flags or interactive keychain APIs.
    fn query(reference: []const u8, extra_keys: []const Ref, extra_values: []const Ref) Error!Ref {
        const service = try string("org.vela-launcher.auth");
        defer CFRelease(service);
        const account = try string(reference);
        defer CFRelease(account);
        var keys: [8]Ref = undefined;
        var values: [8]Ref = undefined;
        keys[0..5].* = .{ kSecClass, kSecAttrService, kSecAttrAccount, kSecUseAuthenticationUI, kSecUseDataProtectionKeychain };
        values[0..5].* = .{ kSecClassGenericPassword, service, account, kSecUseAuthenticationUIFail, kCFBooleanTrue };
        @memcpy(keys[5..][0..extra_keys.len], extra_keys);
        @memcpy(values[5..][0..extra_values.len], extra_values);
        return dictionary(keys[0 .. 5 + extra_keys.len], values[0 .. 5 + extra_values.len]);
    }
    fn put(_: *MacOS, reference: []const u8, bytes: []const u8) Error!void {
        // No-copy CFData borrows only for these synchronous operations.
        const data = CFDataCreateWithBytesNoCopy(null, bytes.ptr, @intCast(bytes.len), kCFAllocatorNull) orelse return error.OutOfMemory;
        defer CFRelease(data);
        const attributes = try dictionary(&.{kSecValueData}, &.{data});
        defer CFRelease(attributes);
        const match = try query(reference, &.{}, &.{});
        defer CFRelease(match);
        const updated = SecItemUpdate(match, attributes);
        if (updated != -25300) return status(updated);
        const add = try query(reference, &.{kSecValueData}, &.{data});
        defer CFRelease(add);
        const added = SecItemAdd(add, null);
        // A writer may have inserted the same reference since our update.
        if (added == -25299) return status(SecItemUpdate(match, attributes));
        return status(added);
    }
    fn get(_: *MacOS, allocator: Allocator, reference: []const u8) Error!Secret {
        const match = try query(reference, &.{ kSecReturnData, kSecMatchLimit }, &.{ kCFBooleanTrue, kSecMatchLimitOne });
        defer CFRelease(match);
        var result: ?Ref = null;
        try status(SecItemCopyMatching(match, &result));
        const data = result orelse return error.StorageFailure;
        // Security owns this immutable CFData; release it rather than writing
        // through its const pointer. Only our owned Secret may be securely wiped.
        defer CFRelease(data);
        if (CFGetTypeID(data) != CFDataGetTypeID()) return error.StorageFailure;
        const length = CFDataGetLength(data);
        if (length < 0) return error.InvalidSecret;
        if (length > max_secret_bytes) return error.TooLarge;
        const ptr = CFDataGetBytePtr(data) orelse return error.InvalidSecret;
        return copySecret(allocator, ptr[0..@intCast(length)]);
    }
    fn delete(_: *MacOS, reference: []const u8) Error!void {
        const match = try query(reference, &.{}, &.{});
        defer CFRelease(match);
        return status(SecItemDelete(match));
    }
};

const Linux = struct {
    library: std.DynLib,
    api: Api,
    used: bool = false,
    var library_pinned: std.atomic.Value(bool) = .init(false);
    const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]u8 };
    const Attribute = extern struct { name: ?[*:0]const u8 = null, kind: c_int = 0 };
    const Schema = extern struct {
        name: [*:0]const u8 = "org.vela-launcher.auth",
        flags: c_int = 0,
        attributes: [32]Attribute = [_]Attribute{.{ .name = "reference" }} ++ [_]Attribute{.{}} ** 31,
        reserved: c_int = 0,
        reserved1: ?*anyopaque = null,
        reserved2: ?*anyopaque = null,
        reserved3: ?*anyopaque = null,
        reserved4: ?*anyopaque = null,
        reserved5: ?*anyopaque = null,
        reserved6: ?*anyopaque = null,
        reserved7: ?*anyopaque = null,
    };
    const schema: Schema = .{};
    const Hash = *const fn (*const anyopaque) callconv(.c) c_uint;
    const Equal = *const fn (*const anyopaque, *const anyopaque) callconv(.c) c_int;
    const Ready = *const fn (?*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void;
    const SourceFunc = *const fn (?*anyopaque) callconv(.c) c_int;
    const Api = struct {
        secret_password_storev: *const fn (*const Schema, *anyopaque, [*:0]const u8, [*:0]const u8, [*:0]const u8, *anyopaque, Ready, ?*anyopaque) callconv(.c) void,
        secret_password_lookupv: *const fn (*const Schema, *anyopaque, *anyopaque, Ready, ?*anyopaque) callconv(.c) void,
        secret_password_clearv: *const fn (*const Schema, *anyopaque, *anyopaque, Ready, ?*anyopaque) callconv(.c) void,
        secret_password_store_finish: *const fn (*anyopaque, *?*GError) callconv(.c) c_int,
        secret_password_lookup_finish: *const fn (*anyopaque, *?*GError) callconv(.c) ?[*:0]u8,
        secret_password_clear_finish: *const fn (*anyopaque, *?*GError) callconv(.c) c_int,
        secret_password_free: *const fn ([*:0]u8) callconv(.c) void,
        secret_error_get_quark: *const fn () callconv(.c) u32,
        g_io_error_quark: *const fn () callconv(.c) u32,
        g_dbus_error_quark: *const fn () callconv(.c) u32,
        g_error_free: *const fn (*GError) callconv(.c) void,
        g_hash_table_new: *const fn (Hash, Equal) callconv(.c) ?*anyopaque,
        g_hash_table_insert: *const fn (*anyopaque, *const anyopaque, *const anyopaque) callconv(.c) c_int,
        g_hash_table_unref: *const fn (*anyopaque) callconv(.c) void,
        g_str_hash: Hash,
        g_str_equal: Equal,
        g_main_context_new: *const fn () callconv(.c) ?*anyopaque,
        g_main_context_push_thread_default: *const fn (*anyopaque) callconv(.c) void,
        g_main_context_pop_thread_default: *const fn (*anyopaque) callconv(.c) void,
        g_main_context_iteration: *const fn (*anyopaque, c_int) callconv(.c) c_int,
        g_main_context_unref: *const fn (*anyopaque) callconv(.c) void,
        g_cancellable_new: *const fn () callconv(.c) ?*anyopaque,
        g_cancellable_cancel: *const fn (*anyopaque) callconv(.c) void,
        g_object_unref: *const fn (*anyopaque) callconv(.c) void,
        g_timeout_source_new: *const fn (c_uint) callconv(.c) ?*anyopaque,
        g_source_set_callback: *const fn (*anyopaque, SourceFunc, ?*anyopaque, ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) void,
        g_source_attach: *const fn (*anyopaque, *anyopaque) callconv(.c) c_uint,
        g_source_destroy: *const fn (*anyopaque) callconv(.c) void,
        g_source_unref: *const fn (*anyopaque) callconv(.c) void,
    };

    fn init() Error!Linux {
        if (!builtin.link_libc) @compileError("Native Linux credentials require linking libc for the system dynamic loader");
        // Static musl cannot load the native libsecret dependency graph.
        if (builtin.abi == .musl and builtin.link_mode == .static) return error.Unavailable;
        var library = std.DynLib.open("libsecret-1.so.0") catch return error.Unavailable;
        errdefer library.close();
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".fields) |field| {
            @field(api, field.name) = library.lookup(field.type, field.name ++ "\x00") orelse return error.Unavailable;
        }
        return .{ .library = library, .api = api };
    }
    fn deinit(self: *Linux) void {
        // GObject static types retain code pointers after their instances die.
        // Pin exactly one used library handle for process lifetime.
        if (self.used and !library_pinned.swap(true, .acq_rel)) return;
        self.library.close();
    }

    fn attributes(self: *Linux, reference: *const [32:0]u8) Error!*anyopaque {
        const table = self.api.g_hash_table_new(self.api.g_str_hash, self.api.g_str_equal) orelse return error.OutOfMemory;
        _ = self.api.g_hash_table_insert(table, "reference", reference);
        return table;
    }
    fn referenceZ(reference: []const u8) [32:0]u8 {
        var result: [32:0]u8 = undefined;
        @memcpy(result[0..32], reference);
        result[32] = 0;
        return result;
    }
    fn failure(self: *Linux, err: *GError) Error {
        defer self.api.g_error_free(err);
        if (err.domain == self.api.secret_error_get_quark() and err.code == 2) return error.Denied;
        if (err.domain == self.api.g_io_error_quark() and err.code == 14) return error.Denied;
        if (err.domain == self.api.g_dbus_error_quark()) return switch (err.code) {
            1 => error.OutOfMemory,
            9, 10 => error.Denied,
            2, 3, 4, 6, 11, 12, 13, 15, 17, 20 => error.Unavailable,
            else => error.StorageFailure,
        };
        return error.StorageFailure;
    }
    const Operation = struct {
        api: *const Api,
        context: *anyopaque,
        cancellable: *anyopaque,
        timer: *anyopaque,
        kind: enum { put, get, delete },
        pushed: bool = false,
        done: bool = false,
        timed_out: bool = false,
        ok: c_int = 0,
        password: ?[*:0]u8 = null,
        err: ?*GError = null,

        fn init(api: *const Api, kind: @FieldType(Operation, "kind")) Error!Operation {
            const context = api.g_main_context_new() orelse return error.OutOfMemory;
            errdefer api.g_main_context_unref(context);
            const cancellable = api.g_cancellable_new() orelse return error.OutOfMemory;
            errdefer api.g_object_unref(cancellable);
            const timer = api.g_timeout_source_new(10_000) orelse return error.OutOfMemory;
            return .{ .api = api, .context = context, .cancellable = cancellable, .timer = timer, .kind = kind };
        }
        fn begin(self: *Operation) Error!void {
            self.api.g_main_context_push_thread_default(self.context);
            self.pushed = true;
            self.api.g_source_set_callback(self.timer, timeout, self, null);
            if (self.api.g_source_attach(self.timer, self.context) == 0) return error.Unavailable;
        }
        fn timeout(data: ?*anyopaque) callconv(.c) c_int {
            const self: *Operation = @ptrCast(@alignCast(data.?));
            self.timed_out = true;
            self.api.g_cancellable_cancel(self.cancellable);
            return 0;
        }
        fn ready(_: ?*anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
            const self: *Operation = @ptrCast(@alignCast(data.?));
            switch (self.kind) {
                .put => self.ok = self.api.secret_password_store_finish(result, &self.err),
                .get => self.password = self.api.secret_password_lookup_finish(result, &self.err),
                .delete => self.ok = self.api.secret_password_clear_finish(result, &self.err),
            }
            self.done = true;
        }
        fn wait(self: *Operation, owner: *Linux) Error!void {
            // Cancellation starts after 10s. Drain until the callback: libsecret
            // may await a D-Bus Dismiss reply using the service default timeout.
            // No hard total wall-clock guarantee is possible here. Returning
            // early would free borrowed secrets/context or unload active code.
            while (!self.done) _ = self.api.g_main_context_iteration(self.context, 1);
            if (self.timed_out) return error.Unavailable;
            if (self.err) |err| {
                self.err = null;
                return owner.failure(err);
            }
        }
        fn deinit(self: *Operation) void {
            self.api.g_source_destroy(self.timer);
            self.api.g_source_unref(self.timer);
            if (self.pushed) self.api.g_main_context_pop_thread_default(self.context);
            self.api.g_object_unref(self.cancellable);
            self.api.g_main_context_unref(self.context);
            if (self.err) |err| self.api.g_error_free(err);
            if (self.password) |password| self.api.secret_password_free(password);
        }
    };

    fn put(self: *Linux, reference: []const u8, bytes: []const u8) Error!void {
        self.used = true;
        const name = referenceZ(reference);
        const table = try self.attributes(&name);
        defer self.api.g_hash_table_unref(table);
        var buffer: [max_secret_bytes + 1]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        @memcpy(buffer[0..bytes.len], bytes);
        buffer[bytes.len] = 0;
        var op = try Operation.init(&self.api, .put);
        defer op.deinit();
        try op.begin();
        self.api.secret_password_storev(&schema, table, "default", "Vela Launcher authentication", @ptrCast(&buffer), op.cancellable, Operation.ready, &op);
        try op.wait(self);
        if (op.ok == 0) return error.StorageFailure;
    }
    fn get(self: *Linux, allocator: Allocator, reference: []const u8) Error!Secret {
        self.used = true;
        const name = referenceZ(reference);
        const table = try self.attributes(&name);
        defer self.api.g_hash_table_unref(table);
        var op = try Operation.init(&self.api, .get);
        defer op.deinit();
        try op.begin();
        self.api.secret_password_lookupv(&schema, table, op.cancellable, Operation.ready, &op);
        try op.wait(self);
        const password = op.password orelse return error.NotFound;
        var length: usize = 0;
        while (length <= max_secret_bytes and password[length] != 0) : (length += 1) {}
        if (length > max_secret_bytes) return error.TooLarge;
        return copySecret(allocator, password[0..length]);
    }
    fn delete(self: *Linux, reference: []const u8) Error!void {
        self.used = true;
        const name = referenceZ(reference);
        const table = try self.attributes(&name);
        defer self.api.g_hash_table_unref(table);
        var op = try Operation.init(&self.api, .delete);
        defer op.deinit();
        try op.begin();
        self.api.secret_password_clearv(&schema, table, op.cancellable, Operation.ready, &op);
        try op.wait(self);
        if (op.ok == 0) return error.NotFound;
    }
};

test "Linux async timeout drains callback before freeing native operation resources" {
    const Fake = struct {
        var operation: *Linux.Operation = undefined;
        var callback: Linux.SourceFunc = undefined;
        var callback_data: ?*anyopaque = null;
        var token: usize = 0;
        var timed: bool = false;
        var ticks: usize = 0;
        var cancellations: usize = 0;
        var unrefs: usize = 0;
        var password_frees: usize = 0;
        var error_frees: usize = 0;
        var early_release: bool = false;
        var interval: c_uint = 0;
        var password: [7:0]u8 = "fixture".*;
        var native_error: Linux.GError = .{ .domain = 1, .code = 19, .message = null };

        fn create() callconv(.c) ?*anyopaque {
            return &token;
        }
        fn timer(ms: c_uint) callconv(.c) ?*anyopaque {
            interval = ms;
            return &token;
        }
        fn context(_: *anyopaque) callconv(.c) void {}
        fn setCallback(_: *anyopaque, cb: Linux.SourceFunc, data: ?*anyopaque, _: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) void {
            callback = cb;
            callback_data = data;
        }
        fn attach(_: *anyopaque, _: *anyopaque) callconv(.c) c_uint {
            return 1;
        }
        fn cancel(_: *anyopaque) callconv(.c) void {
            cancellations += 1;
        }
        fn iteration(_: *anyopaque, _: c_int) callconv(.c) c_int {
            const tick = ticks;
            ticks += 1;
            if (timed and tick == 0) {
                _ = callback(callback_data);
            } else Linux.Operation.ready(null, &token, operation);
            return 1;
        }
        fn finish(_: *anyopaque, err: *?*Linux.GError) callconv(.c) c_int {
            if (timed) err.* = &native_error;
            return 1;
        }
        fn lookup(result: *anyopaque, err: *?*Linux.GError) callconv(.c) ?[*:0]u8 {
            _ = finish(result, err);
            return &password;
        }
        fn unref(_: *anyopaque) callconv(.c) void {
            if (!operation.done) early_release = true;
            unrefs += 1;
        }
        fn freePassword(ptr: [*:0]u8) callconv(.c) void {
            std.crypto.secureZero(u8, std.mem.span(ptr));
            password_frees += 1;
        }
        fn freeError(_: *Linux.GError) callconv(.c) void {
            error_frees += 1;
        }
    };
    // Every function used below is an injected fake; no library or vault is opened.
    var api: Linux.Api = undefined;
    api.g_main_context_new = Fake.create;
    api.g_cancellable_new = Fake.create;
    api.g_timeout_source_new = Fake.timer;
    api.g_main_context_push_thread_default = Fake.context;
    api.g_main_context_pop_thread_default = Fake.context;
    api.g_source_set_callback = Fake.setCallback;
    api.g_source_attach = Fake.attach;
    api.g_cancellable_cancel = Fake.cancel;
    api.g_main_context_iteration = Fake.iteration;
    api.g_source_destroy = Fake.unref;
    api.g_source_unref = Fake.unref;
    api.g_object_unref = Fake.unref;
    api.g_main_context_unref = Fake.unref;
    api.secret_password_store_finish = Fake.finish;
    api.secret_password_lookup_finish = Fake.lookup;
    api.secret_password_clear_finish = Fake.finish;
    api.secret_password_free = Fake.freePassword;
    api.g_error_free = Fake.freeError;
    var owner: Linux = .{ .api = api, .library = undefined };
    const kinds = [_]@FieldType(Linux.Operation, "kind"){ .put, .get, .delete };
    for (kinds) |kind| {
        for ([_]bool{ false, true }) |timed| {
            Fake.timed = timed;
            Fake.ticks = 0;
            Fake.cancellations = 0;
            Fake.unrefs = 0;
            Fake.password_frees = 0;
            Fake.error_frees = 0;
            Fake.early_release = false;
            Fake.password = "fixture".*;
            var op = try Linux.Operation.init(&owner.api, kind);
            Fake.operation = &op;
            try op.begin();
            if (timed) try std.testing.expectError(error.Unavailable, op.wait(&owner)) else try op.wait(&owner);
            try std.testing.expect(op.done);
            try std.testing.expectEqual(@as(c_uint, 10_000), Fake.interval);
            try std.testing.expectEqual(@as(usize, if (timed) 1 else 0), Fake.cancellations);
            try std.testing.expectEqual(@as(usize, if (timed) 2 else 1), Fake.ticks);
            try std.testing.expectEqual(@as(usize, 0), Fake.unrefs);
            op.deinit();
            try std.testing.expect(!Fake.early_release);
            try std.testing.expectEqual(@as(usize, 4), Fake.unrefs);
            try std.testing.expectEqual(@as(usize, if (timed) 1 else 0), Fake.error_frees);
            try std.testing.expectEqual(@as(usize, if (kind == .get) 1 else 0), Fake.password_frees);
            if (kind == .get) for (Fake.password) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }
}
