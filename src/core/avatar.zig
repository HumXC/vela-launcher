//! Public Minecraft avatar resolution; no authentication or rendering dependencies.
//! Name lookup: https://minecraft.wiki/w/Mojang_API#Username_to_UUID
const std = @import("std");
const Allocator = std.mem.Allocator;
const Cancellation = std.atomic.Value(bool);

pub const Response = struct {
    status: u16,
    /// Owned by the allocator passed to Transport.get; resolver frees it.
    body: []u8,
};

pub const Transport = struct {
    ctx: *anyopaque,
    /// Must disable redirects, verify HTTPS certificates, and bound downloads.
    /// Metadata responses are limited to 64 KiB; skin responses to 128 KiB.
    /// Resolver rechecks lengths, but cannot limit allocation inside this callback.
    get: *const fn (*anyopaque, Allocator, []const u8, *const Cancellation) anyerror!Response,
};

pub const Result = union(enum) {
    /// Complete PNG bytes, owned by the caller. Decode/crop in the UI layer.
    skin: []u8,
    /// Online identity when the official profile has no custom skin.
    default_uuid: [32]u8,
    /// Only an explicit missing NAME lookup; caller selects its offline UUID face.
    not_found,

    pub fn deinit(self: *Result, a: Allocator) void {
        switch (self.*) {
            .skin => |bytes| a.free(bytes),
            else => {},
        }
        self.* = .not_found;
    }
};

const json_limit = 64 * 1024;
const skin_limit = 128 * 1024;
const name_endpoint = "https://api.minecraftservices.com/minecraft/profile/lookup/name/";
const session_endpoint = "https://sessionserver.mojang.com/session/minecraft/profile/";
const texture_endpoint = "https://textures.minecraft.net/texture/";

/// Canonical lowercase hex. Dashed input must use exactly the UUID 8-4-4-4-12 form.
pub fn canonicalUuid(input: []const u8) ![32]u8 {
    if (input.len != 32 and input.len != 36) return error.InvalidUuid;
    var result: [32]u8 = undefined;
    var index: usize = 0;
    for (input, 0..) |char, offset| {
        if (input.len == 36 and (offset == 8 or offset == 13 or offset == 18 or offset == 23)) {
            if (char != '-') return error.InvalidUuid;
            continue;
        }
        if (!std.ascii.isHex(char)) return error.InvalidUuid;
        result[index] = std.ascii.toLower(char);
        index += 1;
    }
    return result;
}

/// Stable nine-character selection using floorMod(java.util.UUID.hashCode(), 9).
/// Bad persisted configuration uses a stable FNV-1a fallback rather than trapping.
pub fn defaultIndex(uuid: []const u8) usize {
    const canonical = canonicalUuid(uuid) catch {
        var fallback: u32 = 2166136261;
        for (uuid) |byte| fallback = (fallback ^ byte) *% 16777619;
        return @intCast(fallback % 9);
    };
    var hash: u32 = 0;
    var word: u32 = 0;
    for (canonical, 0..) |char, index| {
        word = (word << 4) | hexNibble(char);
        if (index % 8 == 7) {
            hash ^= word;
            word = 0;
        }
    }
    const signed_hash: i32 = @bitCast(hash);
    return @intCast(@mod(signed_hash, 9));
}

pub fn resolve(
    a: Allocator,
    transport: Transport,
    name: []const u8,
    online_uuid: ?[]const u8,
    cancel: *const Cancellation,
) !Result {
    try checkpoint(cancel);
    var uuid: [32]u8 = undefined;
    if (online_uuid) |online| {
        uuid = try canonicalUuid(online);
    } else {
        try validateName(name);
        var url_buffer: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ name_endpoint, name });
        const response = try fetch(a, transport, url, json_limit, cancel);
        defer a.free(response.body);
        if (response.status == 204 or response.status == 404) return .not_found;
        if (response.status != 200) return error.NameLookupUnavailable;
        const parsed = try parseJson(a, response.body);
        defer parsed.deinit();
        const id = try stringField(parsed.value, "id");
        if (id.len != 32) return error.InvalidProfile;
        uuid = canonicalUuid(id) catch return error.InvalidProfile;
        const returned_name = try stringField(parsed.value, "name");
        if (!std.ascii.eqlIgnoreCase(name, returned_name)) return error.ProfileMismatch;
    }

    try checkpoint(cancel);
    var session_url_buffer: [128]u8 = undefined;
    const session_url = try std.fmt.bufPrint(&session_url_buffer, "{s}{s}", .{ session_endpoint, uuid });
    const response = try fetch(a, transport, session_url, json_limit, cancel);
    defer a.free(response.body);
    // A missing session profile is a service failure, never evidence of a missing name.
    if (response.status != 200) return error.SessionUnavailable;
    const session = try parseJson(a, response.body);
    defer session.deinit();
    try matchUuid(try stringField(session.value, "id"), uuid);
    const properties = try field(session.value, "properties");
    if (properties != .array) return error.InvalidProfile;
    var encoded: ?[]const u8 = null;
    for (properties.array.items) |property| {
        const property_name = try stringField(property, "name");
        if (std.mem.eql(u8, property_name, "textures")) {
            if (encoded != null) return error.InvalidTextures;
            encoded = try stringField(property, "value");
        }
    }
    try checkpoint(cancel);
    const base64 = encoded orelse return .{ .default_uuid = uuid };
    if (base64.len == 0 or base64.len > json_limit) return error.InvalidTextures;
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(base64) catch return error.InvalidTextures;
    if (decoded_len > json_limit) return error.ResponseTooLarge;
    const decoded = try a.alloc(u8, decoded_len);
    defer a.free(decoded);
    decoder.decode(decoded, base64) catch return error.InvalidTextures;
    try checkpoint(cancel);
    const textures_profile = try parseJson(a, decoded);
    defer textures_profile.deinit();
    if (textures_profile.value != .object) return error.InvalidProfile;
    if (textures_profile.value.object.get("profileId")) |profile_id| {
        if (profile_id != .string) return error.InvalidProfile;
        try matchUuid(profile_id.string, uuid);
    }
    const textures = try field(textures_profile.value, "textures");
    if (textures != .object) return error.InvalidTextures;
    const skin = textures.object.get("SKIN") orelse return .{ .default_uuid = uuid };
    const raw_url = try stringField(skin, "url");
    const texture_hash = try validateTextureUrl(raw_url);
    var skin_url_buffer: [128]u8 = undefined;
    // Even the legacy official HTTP URL is fetched only using HTTPS.
    const skin_url = try std.fmt.bufPrint(&skin_url_buffer, "{s}{s}", .{ texture_endpoint, texture_hash });
    const skin_response = try fetch(a, transport, skin_url, skin_limit, cancel);
    errdefer a.free(skin_response.body);
    if (skin_response.status != 200) return error.SkinUnavailable;
    try validateSkin(skin_response.body);
    try checkpoint(cancel);
    return .{ .skin = skin_response.body };
}

fn checkpoint(cancel: *const Cancellation) !void {
    if (cancel.load(.acquire)) return error.Cancelled;
}

fn fetch(a: Allocator, transport: Transport, url: []const u8, limit: usize, cancel: *const Cancellation) !Response {
    try checkpoint(cancel);
    const response = try transport.get(transport.ctx, a, url, cancel);
    errdefer a.free(response.body);
    try checkpoint(cancel);
    if (response.body.len > limit) return error.ResponseTooLarge;
    return response;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 16) return error.InvalidName;
    for (name) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '_')) return error.InvalidName;
    }
}

fn parseJson(a: Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    if (bytes.len > json_limit) return error.ResponseTooLarge;
    return std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = json_limit,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidProfile,
    };
}

fn field(value: std.json.Value, key: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidProfile;
    return value.object.get(key) orelse error.InvalidProfile;
}

fn stringField(value: std.json.Value, key: []const u8) ![]const u8 {
    const result = try field(value, key);
    if (result != .string) return error.InvalidProfile;
    return result.string;
}

fn matchUuid(input: []const u8, expected: [32]u8) !void {
    const actual = canonicalUuid(input) catch return error.InvalidProfile;
    if (!std.mem.eql(u8, &actual, &expected)) return error.ProfileMismatch;
}

fn hexNibble(char: u8) u32 {
    return if (char <= '9') @as(u32, char - '0') else @as(u32, char - 'a' + 10);
}

fn validateTextureUrl(url: []const u8) ![]const u8 {
    const https = texture_endpoint;
    const http = "http://textures.minecraft.net/texture/";
    const hash = if (std.mem.startsWith(u8, url, https)) url[https.len..] else if (std.mem.startsWith(u8, url, http)) url[http.len..] else return error.InvalidTextureUrl;
    if (hash.len != 64) return error.InvalidTextureUrl;
    for (hash) |char| {
        if (!((char >= '0' and char <= '9') or (char >= 'a' and char <= 'f'))) return error.InvalidTextureUrl;
    }
    return hash;
}

/// Shared bounded PNG container guard for downloaded and persisted skins.
/// The image decoder must still validate compressed pixel data.
pub fn validateSkin(bytes: []const u8) !void {
    if (bytes.len > skin_limit) return error.ResponseTooLarge;
    const signature = "\x89PNG\r\n\x1a\n";
    if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], signature)) return error.InvalidPng;
    if (std.mem.readInt(u32, bytes[8..12], .big) != 13 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return error.InvalidPng;
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (width != 64 or (height != 32 and height != 64)) return error.InvalidSkinDimensions;
    // Require valid IHDR fields before exposing any compressed pixels to a decoder.
    const depth = bytes[24];
    const valid_depth = switch (bytes[25]) {
        0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
        2, 4, 6 => depth == 8 or depth == 16,
        3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
        else => false,
    };
    if (!valid_depth or bytes[26] != 0 or bytes[27] != 0 or bytes[28] > 1) return error.InvalidPng;
    var offset: usize = 8;
    var first = true;
    var palette = false;
    var pixels = false;
    var pixel_bytes: usize = 0;
    var after_pixels = false;
    while (offset <= bytes.len - 12) {
        const length: usize = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (length > bytes.len - offset - 12) return error.InvalidPng;
        const kind = bytes[offset + 4 ..][0..4];
        for (kind) |char| if (!std.ascii.isAlphabetic(char)) return error.InvalidPng;
        if (std.ascii.isLower(kind[2])) return error.InvalidPng;
        const data = bytes[offset + 8 ..][0..length];
        const crc = std.mem.readInt(u32, bytes[offset + 8 + length ..][0..4], .big);
        if (std.hash.crc.@"CRC-32/ISO-HDLC".hash(bytes[offset + 4 ..][0 .. length + 4]) != crc) return error.InvalidPng;
        if (first) {
            if (!std.mem.eql(u8, kind, "IHDR") or length != 13) return error.InvalidPng;
            first = false;
        } else if (std.mem.eql(u8, kind, "IHDR")) {
            return error.InvalidPng;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (palette or pixels or length == 0 or length > 768 or length % 3 != 0 or bytes[25] == 0 or bytes[25] == 4) return error.InvalidPng;
            if (bytes[25] == 3 and length / 3 > (@as(usize, 1) << @intCast(depth))) return error.InvalidPng;
            palette = true;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            if (after_pixels or (bytes[25] == 3 and !palette)) return error.InvalidPng;
            pixels = true;
            pixel_bytes += data.len;
        } else if (std.mem.eql(u8, kind, "IEND")) {
            if (length != 0 or !pixels or pixel_bytes == 0 or offset + 12 != bytes.len) return error.InvalidPng;
            return;
        } else {
            if (!std.ascii.isLower(kind[0])) return error.InvalidPng;
            if (pixels) after_pixels = true;
        }
        offset += length + 12;
    }
    return error.InvalidPng;
}

const TestStep = struct {
    url: []const u8,
    status: u16 = 200,
    body: []const u8 = "",
    network_failure: bool = false,
    cancel_after: bool = false,
};

const TestTransport = struct {
    steps: []const TestStep,
    calls: usize = 0,
    cancel: ?*Cancellation = null,

    fn transport(self: *TestTransport) Transport {
        return .{ .ctx = self, .get = get };
    }

    fn get(ctx: *anyopaque, a: Allocator, url: []const u8, _: *const Cancellation) anyerror!Response {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        if (self.calls >= self.steps.len) return error.UnexpectedRequest;
        const step = self.steps[self.calls];
        self.calls += 1;
        try std.testing.expectEqualStrings(step.url, url);
        if (step.network_failure) return error.NetworkFailure;
        const body = try a.dupe(u8, step.body);
        if (step.cancel_after) self.cancel.?.store(true, .release);
        return .{ .status = step.status, .body = body };
    }
};

const test_uuid = "069a79f444e94726a5befca90e38aaf5";
const test_other_uuid = "853c80ef3c3749fdaa49938b674adae6";
const test_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const test_name_url = name_endpoint ++ "Notch";
const test_session_url = session_endpoint ++ test_uuid;
const test_skin_url = texture_endpoint ++ test_hash;
const test_name_profile = "{\"id\":\"" ++ test_uuid ++ "\",\"name\":\"nOtCh\"}";
const test_skin_payload = "{\"profileId\":\"" ++ test_uuid ++ "\",\"textures\":{\"SKIN\":{\"url\":\"http://textures.minecraft.net/texture/" ++ test_hash ++ "\"}}}";

fn testSession(a: Allocator, uuid: []const u8, payload: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(payload.len));
    defer a.free(encoded);
    _ = encoder.encode(encoded, payload);
    return std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"properties\":[{{\"name\":\"textures\",\"value\":\"{s}\"}}]}}", .{ uuid, encoded });
}

fn testPng(width: u32, height: u32) [108]u8 {
    // Complete PNGs with real zlib streams for transparent RGBA 64x64 and 64x32.
    const square = [_]u8{ 120, 156, 237, 193, 1, 13, 0, 0, 0, 194, 160, 247, 79, 109, 14, 55, 160, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 119, 3, 64, 64, 0, 1 };
    const legacy = [_]u8{ 120, 156, 237, 193, 1, 13, 0, 0, 0, 194, 160, 247, 79, 109, 15, 7, 20, 0, 0, 0, 0, 0, 0, 0, 240, 110, 32, 32, 0, 1 };
    const compressed: []const u8 = if (height == 32) &legacy else &square;
    var bytes: [108]u8 = @splat(0);
    @memcpy(bytes[0..8], "\x89PNG\r\n\x1a\n");
    var header: [13]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8] = 8;
    header[9] = 6;
    var offset = testChunk(&bytes, 8, "IHDR", &header);
    const padding: [9]u8 = @splat(0);
    // Private ancillary padding keeps both fixture variants the same array length.
    offset = testChunk(&bytes, offset, "npAd", padding[0 .. square.len - compressed.len]);
    offset = testChunk(&bytes, offset, "IDAT", compressed);
    _ = testChunk(&bytes, offset, "IEND", "");
    return bytes;
}

fn testChunk(bytes: []u8, offset: usize, kind: []const u8, data: []const u8) usize {
    std.mem.writeInt(u32, bytes[offset..][0..4], @intCast(data.len), .big);
    @memcpy(bytes[offset + 4 ..][0..4], kind);
    @memcpy(bytes[offset + 8 ..][0..data.len], data);
    const crc = std.hash.crc.@"CRC-32/ISO-HDLC".hash(bytes[offset + 4 ..][0 .. data.len + 4]);
    std.mem.writeInt(u32, bytes[offset + 8 + data.len ..][0..4], crc, .big);
    return offset + data.len + 12;
}

test "avatar: offline existing name resolves official skin and upgrades HTTP" {
    const a = std.testing.allocator;
    const session = try testSession(a, test_uuid, test_skin_payload);
    defer a.free(session);
    const png = testPng(64, 64);
    var mock: TestTransport = .{ .steps = &.{
        .{ .url = test_name_url, .body = test_name_profile },
        .{ .url = test_session_url, .body = session },
        .{ .url = test_skin_url, .body = &png },
    } };
    var cancel = Cancellation.init(false);
    var result = try resolve(a, mock.transport(), "Notch", null, &cancel);
    defer result.deinit(a);
    try std.testing.expect(result == .skin);
    try std.testing.expectEqualSlices(u8, &png, result.skin);
    try std.testing.expectEqual(@as(usize, 3), mock.calls);
}

test "avatar: only explicit missing name statuses yield not_found" {
    for ([_]u16{ 204, 404 }) |status| {
        var mock: TestTransport = .{ .steps = &.{.{ .url = test_name_url, .status = status }} };
        var cancel = Cancellation.init(false);
        var result = try resolve(std.testing.allocator, mock.transport(), "Notch", null, &cancel);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result == .not_found);
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
    }
}

test "avatar: online UUID bypasses name and missing SKIN selects online default" {
    const a = std.testing.allocator;
    const session = try testSession(a, test_uuid, "{\"profileId\":\"" ++ test_uuid ++ "\",\"textures\":{}}");
    defer a.free(session);
    var mock: TestTransport = .{ .steps = &.{.{ .url = test_session_url, .body = session }} };
    var cancel = Cancellation.init(false);
    var result = try resolve(a, mock.transport(), "ignored invalid name!", "069A79F4-44E9-4726-A5BE-FCA90E38AAF5", &cancel);
    defer result.deinit(a);
    try std.testing.expect(result == .default_uuid);
    try std.testing.expectEqualStrings(test_uuid, &result.default_uuid);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
}

test "avatar: empty session properties select online default" {
    var mock: TestTransport = .{ .steps = &.{.{ .url = test_session_url, .body = "{\"id\":\"" ++ test_uuid ++ "\",\"properties\":[]}" }} };
    var cancel = Cancellation.init(false);
    var result = try resolve(std.testing.allocator, mock.transport(), "Notch", test_uuid, &cancel);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(test_uuid, &result.default_uuid);
}

test "avatar: name network and non-200 failures are errors" {
    var cancel = Cancellation.init(false);
    var network: TestTransport = .{ .steps = &.{.{ .url = test_name_url, .network_failure = true }} };
    try std.testing.expectError(error.NetworkFailure, resolve(std.testing.allocator, network.transport(), "Notch", null, &cancel));
    for ([_]u16{ 201, 301, 400, 403, 429, 500, 503 }) |status| {
        var mock: TestTransport = .{ .steps = &.{.{ .url = test_name_url, .status = status }} };
        try std.testing.expectError(error.NameLookupUnavailable, resolve(std.testing.allocator, mock.transport(), "Notch", null, &cancel));
    }
}

test "avatar: missing or unavailable session never yields not_found" {
    for ([_]u16{ 204, 301, 404, 429, 500 }) |status| {
        var mock: TestTransport = .{ .steps = &.{.{ .url = test_session_url, .status = status }} };
        var cancel = Cancellation.init(false);
        try std.testing.expectError(error.SessionUnavailable, resolve(std.testing.allocator, mock.transport(), "Notch", test_uuid, &cancel));
    }
}

test "avatar: one and two character account names resolve an existing online default" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "a", "ab" }) |name| {
        const url = try std.mem.concat(a, u8, &.{ name_endpoint, name });
        defer a.free(url);
        const profile = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"name\":\"{s}\"}}", .{ test_uuid, name });
        defer a.free(profile);
        var mock: TestTransport = .{ .steps = &.{ .{ .url = url, .body = profile }, .{ .url = test_session_url, .body = "{\"id\":\"" ++ test_uuid ++ "\",\"properties\":[]}" } } };
        var cancel = Cancellation.init(false);
        var result = try resolve(a, mock.transport(), name, null, &cancel);
        defer result.deinit(a);
        try std.testing.expectEqualStrings(test_uuid, &result.default_uuid);
        try std.testing.expectEqual(@as(usize, 2), mock.calls);
    }
}

test "avatar: name validation precedes any network request" {
    for ([_][]const u8{ "", "abcdefghijklmnopq", "Not/ch", "Not?ch", "Not ch", "Nótch", "Not%63h" }) |name| {
        var mock: TestTransport = .{ .steps = &.{} };
        var cancel = Cancellation.init(false);
        try std.testing.expectError(error.InvalidName, resolve(std.testing.allocator, mock.transport(), name, null, &cancel));
        try std.testing.expectEqual(@as(usize, 0), mock.calls);
    }
}

test "avatar: successful name response must have matching name and 32 hex ID" {
    var cancel = Cancellation.init(false);
    const cases = [_]struct { body: []const u8, expected: anyerror }{
        .{ .body = "not JSON", .expected = error.InvalidProfile },
        .{ .body = "{}", .expected = error.InvalidProfile },
        .{ .body = "{\"id\":\"" ++ test_uuid ++ "\",\"name\":\"SomeoneElse\"}", .expected = error.ProfileMismatch },
        .{ .body = "{\"id\":\"069a79f4-44e9-4726-a5be-fca90e38aaf5\",\"name\":\"Notch\"}", .expected = error.InvalidProfile },
        .{ .body = "{\"id\":\"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\",\"name\":\"Notch\"}", .expected = error.InvalidProfile },
    };
    for (cases) |case| {
        var mock: TestTransport = .{ .steps = &.{.{ .url = test_name_url, .body = case.body }} };
        try std.testing.expectError(case.expected, resolve(std.testing.allocator, mock.transport(), "Notch", null, &cancel));
    }
}

test "avatar: session and nested texture identities must match" {
    const a = std.testing.allocator;
    const wrong_outer = try testSession(a, test_other_uuid, test_skin_payload);
    defer a.free(wrong_outer);
    const wrong_inner = try testSession(a, test_uuid, "{\"profileId\":\"" ++ test_other_uuid ++ "\",\"textures\":{}}");
    defer a.free(wrong_inner);
    for ([_][]const u8{ wrong_outer, wrong_inner }) |session| {
        var mock: TestTransport = .{ .steps = &.{.{ .url = test_session_url, .body = session }} };
        var cancel = Cancellation.init(false);
        try std.testing.expectError(error.ProfileMismatch, resolve(a, mock.transport(), "Notch", test_uuid, &cancel));
    }
}

test "avatar: invalid base64 and malformed texture JSON are errors" {
    const a = std.testing.allocator;
    const malformed = try testSession(a, test_uuid, "not JSON");
    defer a.free(malformed);
    var cancel = Cancellation.init(false);
    var invalid: TestTransport = .{ .steps = &.{.{ .url = test_session_url, .body = "{\"id\":\"" ++ test_uuid ++ "\",\"properties\":[{\"name\":\"textures\",\"value\":\"%%%\"}]}" }} };
    try std.testing.expectError(error.InvalidTextures, resolve(a, invalid.transport(), "Notch", test_uuid, &cancel));
    var json: TestTransport = .{ .steps = &.{.{ .url = test_session_url, .body = malformed }} };
    try std.testing.expectError(error.InvalidProfile, resolve(a, json.transport(), "Notch", test_uuid, &cancel));
}

test "avatar: hostile texture URLs are rejected before download" {
    const a = std.testing.allocator;
    const urls = [_][]const u8{
        "https://example.com/texture/" ++ test_hash,
        "https://textures.minecraft.net.evil.test/texture/" ++ test_hash,
        "https://user@textures.minecraft.net/texture/" ++ test_hash,
        "https://textures.minecraft.net:443/texture/" ++ test_hash,
        test_skin_url ++ "?x=1",
        test_skin_url ++ "#fragment",
        "https://textures.minecraft.net/texture/../" ++ test_hash,
        "https://textures.minecraft.net/texture/%2e%2e/" ++ test_hash,
        "https://textures.minecraft.net/texture/ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab",
        "https://textures.minecraft.net/texture/short",
        "ftp://textures.minecraft.net/texture/" ++ test_hash,
    };
    for (urls) |url| {
        const payload = try std.fmt.allocPrint(a, "{{\"textures\":{{\"SKIN\":{{\"url\":\"{s}\"}}}}}}", .{url});
        defer a.free(payload);
        const session = try testSession(a, test_uuid, payload);
        defer a.free(session);
        var mock: TestTransport = .{ .steps = &.{.{ .url = test_session_url, .body = session }} };
        var cancel = Cancellation.init(false);
        try std.testing.expectError(error.InvalidTextureUrl, resolve(a, mock.transport(), "Notch", test_uuid, &cancel));
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
    }
}

test "avatar: skin redirects and failed downloads remain errors" {
    const a = std.testing.allocator;
    const session = try testSession(a, test_uuid, test_skin_payload);
    defer a.free(session);
    for ([_]u16{ 301, 302, 404, 429, 500 }) |status| {
        var mock: TestTransport = .{ .steps = &.{
            .{ .url = test_session_url, .body = session },
            .{ .url = test_skin_url, .status = status },
        } };
        var cancel = Cancellation.init(false);
        try std.testing.expectError(error.SkinUnavailable, resolve(a, mock.transport(), "Notch", test_uuid, &cancel));
    }
}

test "avatar: PNG dimensions and signature are checked; legacy 64x32 accepted" {
    const a = std.testing.allocator;
    const session = try testSession(a, test_uuid, test_skin_payload);
    defer a.free(session);
    for ([_][2]u32{ .{ 63, 64 }, .{ 64, 63 }, .{ 4096, 4096 }, .{ 0, 0 } }) |size| {
        const png = testPng(size[0], size[1]);
        var mock: TestTransport = .{ .steps = &.{
            .{ .url = test_session_url, .body = session },
            .{ .url = test_skin_url, .body = &png },
        } };
        var cancel = Cancellation.init(false);
        try std.testing.expectError(error.InvalidSkinDimensions, resolve(a, mock.transport(), "Notch", test_uuid, &cancel));
    }
    var invalid: TestTransport = .{ .steps = &.{
        .{ .url = test_session_url, .body = session },
        .{ .url = test_skin_url, .body = "not a PNG" },
    } };
    var cancel = Cancellation.init(false);
    try std.testing.expectError(error.InvalidPng, resolve(a, invalid.transport(), "Notch", test_uuid, &cancel));
    const legacy = testPng(64, 32);
    var valid: TestTransport = .{ .steps = &.{
        .{ .url = test_session_url, .body = session },
        .{ .url = test_skin_url, .body = &legacy },
    } };
    var result = try resolve(a, valid.transport(), "Notch", test_uuid, &cancel);
    defer result.deinit(a);
    try std.testing.expect(result == .skin);
}

test "avatar: metadata and skin response size limits" {
    const a = std.testing.allocator;
    var cancel = Cancellation.init(false);
    const large_json = try a.alloc(u8, json_limit + 1);
    defer a.free(large_json);
    @memset(large_json, ' ');
    var metadata: TestTransport = .{ .steps = &.{.{ .url = test_name_url, .body = large_json }} };
    try std.testing.expectError(error.ResponseTooLarge, resolve(a, metadata.transport(), "Notch", null, &cancel));
    const session = try testSession(a, test_uuid, test_skin_payload);
    defer a.free(session);
    const large_skin = try a.alloc(u8, skin_limit + 1);
    defer a.free(large_skin);
    @memset(large_skin, 0);
    var skin: TestTransport = .{ .steps = &.{
        .{ .url = test_session_url, .body = session },
        .{ .url = test_skin_url, .body = large_skin },
    } };
    try std.testing.expectError(error.ResponseTooLarge, resolve(a, skin.transport(), "Notch", test_uuid, &cancel));
}

test "avatar: cancellation before and after name, session, and skin requests" {
    const a = std.testing.allocator;
    var cancelled = Cancellation.init(true);
    var never: TestTransport = .{ .steps = &.{} };
    try std.testing.expectError(error.Cancelled, resolve(a, never.transport(), "Notch", null, &cancelled));
    try std.testing.expectEqual(@as(usize, 0), never.calls);
    const session = try testSession(a, test_uuid, test_skin_payload);
    defer a.free(session);
    const png = testPng(64, 64);
    for (0..3) |stage| {
        var cancel = Cancellation.init(false);
        var mock: TestTransport = .{ .cancel = &cancel, .steps = &.{
            .{ .url = test_name_url, .body = test_name_profile, .cancel_after = stage == 0 },
            .{ .url = test_session_url, .body = session, .cancel_after = stage == 1 },
            .{ .url = test_skin_url, .body = &png, .cancel_after = stage == 2 },
        } };
        try std.testing.expectError(error.Cancelled, resolve(a, mock.transport(), "Notch", null, &cancel));
        try std.testing.expectEqual(stage + 1, mock.calls);
    }
}

test "avatar: UUID canonicalization strictly accepts compact or standard dashed hex" {
    const canonical = try canonicalUuid("069A79F4-44E9-4726-A5BE-FCA90E38AAF5");
    try std.testing.expectEqualStrings(test_uuid, &canonical);
    const compact = try canonicalUuid(test_uuid);
    try std.testing.expectEqualSlices(u8, &canonical, &compact);
    for ([_][]const u8{ "", "069a79f444e94726a5befca90e38aaf", "069a79f4_44e9_4726_a5be_fca90e38aaf5", "069a79f-444e9-4726-a5be-fca90e38aaf5", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" }) |invalid| {
        try std.testing.expectError(error.InvalidUuid, canonicalUuid(invalid));
    }
}

test "avatar: nine defaults use Java UUID hash and mathematical floorMod" {
    try std.testing.expectEqual(@as(usize, 0), defaultIndex("00000000000000000000000000000000"));
    try std.testing.expectEqual(@as(usize, 1), defaultIndex("00000000000000000000000000000001"));
    try std.testing.expectEqual(@as(usize, 8), defaultIndex("ffffffff000000000000000000000000"));
    try std.testing.expectEqual(@as(usize, 7), defaultIndex("80000000000000000000000000000000"));
    try std.testing.expectEqual(defaultIndex(test_uuid), defaultIndex("069A79F4-44E9-4726-A5BE-FCA90E38AAF5"));
    const malformed = [_]struct { uuid: []const u8, index: usize }{
        .{ .uuid = "", .index = 7 },
        .{ .uuid = "bad uuid", .index = 1 },
        .{ .uuid = "persisted-old-value", .index = 5 },
    };
    for (malformed) |case| try std.testing.expectEqual(case.index, defaultIndex(case.uuid));
}

test "avatar: PNG container rejects CRC corruption, duplicate headers, invalid lengths and trailing data" {
    const png = testPng(64, 64);
    try validateSkin(&png);
    var bad_crc = png;
    bad_crc[29] ^= 1;
    try std.testing.expectError(error.InvalidPng, validateSkin(&bad_crc));
    try std.testing.expectError(error.InvalidPng, validateSkin(png[0 .. png.len - 1]));
    try std.testing.expectError(error.InvalidPng, validateSkin(png[0 .. png.len - 12]));
    var bad_length = png;
    std.mem.writeInt(u32, bad_length[8..12], std.math.maxInt(u32), .big);
    try std.testing.expectError(error.InvalidPng, validateSkin(&bad_length));
    var duplicate: [133]u8 = undefined;
    @memcpy(duplicate[0..33], png[0..33]);
    @memcpy(duplicate[33..58], png[8..33]);
    @memcpy(duplicate[58..], png[33..]);
    try std.testing.expectError(error.InvalidPng, validateSkin(&duplicate));
    var trailing: [109]u8 = undefined;
    @memcpy(trailing[0..108], &png);
    trailing[108] = 0;
    try std.testing.expectError(error.InvalidPng, validateSkin(&trailing));
    var unknown_critical = png;
    _ = testChunk(&unknown_critical, 33, "ABCD", "");
    try std.testing.expectError(error.InvalidPng, validateSkin(&unknown_critical));
    var non_first = png;
    _ = testChunk(&non_first, 8, "npAd", png[16..29]);
    try std.testing.expectError(error.InvalidPng, validateSkin(&non_first));
}

test "avatar: PNG requires pixels and consecutive IDAT chunks" {
    const png = testPng(64, 64);
    var no_pixels: [45]u8 = undefined;
    @memcpy(no_pixels[0..33], png[0..33]);
    _ = testChunk(&no_pixels, 33, "IEND", "");
    try std.testing.expectError(error.InvalidPng, validateSkin(&no_pixels));
    var non_consecutive: [120]u8 = undefined;
    @memcpy(non_consecutive[0..33], png[0..33]);
    var offset = testChunk(&non_consecutive, 33, "IDAT", png[53..54]);
    offset = testChunk(&non_consecutive, offset, "npAd", "");
    offset = testChunk(&non_consecutive, offset, "IDAT", png[54..92]);
    _ = testChunk(&non_consecutive, offset, "IEND", "");
    try std.testing.expectError(error.InvalidPng, validateSkin(&non_consecutive));
}

test "avatar: persisted skin bytes have the same size bound" {
    const a = std.testing.allocator;
    const oversized = try a.alloc(u8, skin_limit + 1);
    defer a.free(oversized);
    @memset(oversized, 0);
    try std.testing.expectError(error.ResponseTooLarge, validateSkin(oversized));
}
