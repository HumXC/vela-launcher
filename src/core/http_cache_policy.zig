//! Allocation-free response-header policy for a private HTTP cache.
//! The caller owns method/status eligibility, request directives, validator use,
//! Vary key matching, and merging headers after a 304 response. Header slices are
//! borrowed; combine repeated Cache-Control/Vary lines before calling evaluate.
const std = @import("std");

pub const Headers = struct {
    cache_control: ?[]const u8 = null,
    date: ?[]const u8 = null,
    age: ?[]const u8 = null,
    expires: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    vary: ?[]const u8 = null,
};

pub const Decision = struct {
    /// Header policy permits storage; this is not complete response eligibility.
    store: bool,
    /// Exclusive deadline: fresh only while now < fresh_until.
    fresh_until: i64,
    /// Reuse at the supplied now needs synchronous validation (or a new fetch).
    /// False during permitted SWR, when the caller must revalidate in background.
    requires_validation: bool,
    /// Once stale, reuse without successful validation is forbidden.
    must_revalidate: bool,
    /// Exclusive SWR deadline; equals fresh_until when SWR is not permitted.
    stale_while_revalidate_until: i64,
};

/// All timestamps are Unix seconds. No clock access, allocation, or heuristics.
/// Missing Date uses response_time. Invalid Age/Date, duplicate max-age (even
/// equal values), or invalid max-age force staleness without Expires fallback.
/// Unknown directives (including shared-cache-only s-maxage) are ignored.
pub fn evaluate(headers: Headers, request_time: i64, response_time: i64, now: i64) Decision {
    const policy = parseCacheControl(headers.cache_control orelse "");
    const store = !policy.no_store and !varyStar(headers.vary orelse "");
    var invalid = policy.invalid_freshness or response_time < request_time or now < response_time;
    const date: i64 = if (headers.date) |raw| parseDate(trim(raw)) orelse blk: {
        invalid = true;
        break :blk response_time;
    } else response_time;
    const age: i64 = if (headers.age) |raw| seconds(trim(raw)) orelse blk: {
        invalid = true;
        break :blk 0;
    } else 0;

    var lifetime: ?i128 = null;
    if (policy.max_age) |value| {
        lifetime = value;
    } else if (!policy.seen_max_age) {
        if (headers.expires) |raw| {
            if (parseDate(trim(raw))) |expiry| {
                lifetime = @max(0, @as(i128, expiry) - date);
            } else {
                invalid = true;
            }
        }
    }

    // RFC 9111 corrected_initial_age: response delay is added to Age before
    // comparing against apparent age, not added after the maximum.
    const apparent_age = @max(0, @as(i128, response_time) - date);
    const response_delay = @max(0, @as(i128, response_time) - request_time);
    const initial_age = @max(apparent_age, @as(i128, age) + response_delay);
    const reusable = store and !policy.no_cache and !invalid and lifetime != null;
    const fresh_deadline: i128 = if (reusable)
        @as(i128, response_time) + lifetime.? - initial_age
    else
        @min(response_time, now);
    const swr: i128 = if (reusable and !policy.must_revalidate and !policy.invalid_swr)
        policy.swr orelse 0
    else
        0;
    const fresh_until = clampTimestamp(fresh_deadline);
    const swr_until = clampTimestamp(fresh_deadline + swr);
    return .{
        .store = store,
        .fresh_until = fresh_until,
        .requires_validation = !reusable or now >= swr_until,
        .must_revalidate = policy.must_revalidate,
        .stale_while_revalidate_until = swr_until,
    };
}

const Policy = struct {
    no_store: bool = false,
    no_cache: bool = false,
    must_revalidate: bool = false,
    max_age: ?i64 = null,
    seen_max_age: bool = false,
    invalid_freshness: bool = false,
    swr: ?i64 = null,
    seen_swr: bool = false,
    invalid_swr: bool = false,
};

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}

fn same(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn parseCacheControl(raw: []const u8) Policy {
    var result: Policy = .{};
    var start: usize = 0;
    var quoted = false;
    var escaped = false;
    for (raw, 0..) |byte, index| {
        if (escaped) {
            escaped = false;
        } else if (quoted and byte == '\\') {
            escaped = true;
        } else if (byte == '"') {
            quoted = !quoted;
        } else if (byte == ',' and !quoted) {
            parseDirective(trim(raw[start..index]), &result);
            start = index + 1;
        }
    }
    parseDirective(trim(raw[start..]), &result);
    if (quoted or escaped) {
        // A broken quoted string can conceal a subsequent no-store directive.
        result.no_store = true;
        result.invalid_freshness = true;
    }
    return result;
}

fn parseDirective(raw: []const u8, result: *Policy) void {
    if (raw.len == 0) return;
    const equal = std.mem.indexOfScalar(u8, raw, '=');
    const name = trim(raw[0 .. equal orelse raw.len]);
    const value: ?[]const u8 = if (equal) |index| trim(raw[index + 1 ..]) else null;
    if (same(name, "no-store")) {
        result.no_store = true;
    } else if (same(name, "no-cache")) {
        // Field-name-qualified no-cache is conservatively applied to all fields.
        result.no_cache = true;
    } else if (same(name, "must-revalidate")) {
        result.must_revalidate = true;
    } else if (same(name, "max-age")) {
        if (result.seen_max_age) result.invalid_freshness = true;
        result.seen_max_age = true;
        result.max_age = if (value) |v| directiveSeconds(v) else null;
        if (result.max_age == null) result.invalid_freshness = true;
    } else if (same(name, "stale-while-revalidate")) {
        if (result.seen_swr) result.invalid_swr = true;
        result.seen_swr = true;
        result.swr = if (value) |v| directiveSeconds(v) else null;
        if (result.swr == null) result.invalid_swr = true;
    }
}

fn directiveSeconds(raw: []const u8) ?i64 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return seconds(raw[1 .. raw.len - 1]);
    }
    return seconds(raw);
}

fn seconds(raw: []const u8) ?i64 {
    if (raw.len == 0) return null;
    var value: i64 = 0;
    for (raw) |byte| {
        if (byte < '0' or byte > '9') return null;
        const digit: i64 = byte - '0';
        if (value > @divTrunc(std.math.maxInt(i64) - digit, 10)) return null;
        value = value * 10 + digit;
    }
    return value;
}

fn varyStar(raw: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, raw, ',');
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, trim(token), "*")) return true;
    }
    return false;
}

fn clampTimestamp(value: i128) i64 {
    return @intCast(@max(std.math.minInt(i64), @min(std.math.maxInt(i64), value)));
}

/// Strict IMF-fixdate (RFC 1123): canonical English spelling, GMT, matching
/// weekday, Gregorian calendar, years 1601..9999. Obsolete date formats and
/// leap seconds are rejected rather than guessed.
fn parseDate(raw: []const u8) ?i64 {
    if (raw.len != 29) return null;
    if (!std.mem.eql(u8, raw[3..5], ", ") or raw[7] != ' ' or
        raw[11] != ' ' or raw[16] != ' ' or raw[19] != ':' or
        raw[22] != ':' or !std.mem.eql(u8, raw[25..], " GMT")) return null;
    const day = seconds(raw[5..7]) orelse return null;
    const year = seconds(raw[12..16]) orelse return null;
    const hour = seconds(raw[17..19]) orelse return null;
    const minute = seconds(raw[20..22]) orelse return null;
    const second = seconds(raw[23..25]) orelse return null;
    if (year < 1601 or hour > 23 or minute > 59 or second > 59) return null;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month = for (months, 0..) |name, index| {
        if (std.mem.eql(u8, raw[8..11], name)) break index;
    } else return null;
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const month_days = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const max_day = month_days[month] + @as(i64, if (month == 1 and leap) 1 else 0);
    if (day < 1 or day > max_day) return null;
    const previous = year - 1;
    var days = 365 * previous + @divTrunc(previous, 4) - @divTrunc(previous, 100) + @divTrunc(previous, 400) - 719162;
    for (month_days[0..month]) |count| days += count;
    if (month > 1 and leap) days += 1;
    days += day - 1;
    const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const weekday: usize = @intCast(@mod(days + 4, 7));
    if (!std.mem.eql(u8, raw[0..3], weekdays[weekday])) return null;
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

const testing = std.testing;
const epoch_date = "Thu, 01 Jan 1970 00:00:00 GMT";

test "no-store and Vary star prevent storage; private and named Vary permit it" {
    const forbidden = evaluate(.{ .cache_control = "private, max-age=60, NO-STORE" }, 0, 0, 0);
    try testing.expect(!forbidden.store);
    try testing.expect(forbidden.requires_validation);
    try testing.expect(!evaluate(.{ .vary = "Accept-Encoding, *" }, 0, 0, 0).store);
    const allowed = evaluate(.{ .cache_control = "private, max-age=60", .vary = "Accept-Language" }, 0, 0, 0);
    try testing.expect(allowed.store);
    try testing.expect(!allowed.requires_validation);
}

test "no-cache permits storage but requires validation even with validators and SWR" {
    const result = evaluate(.{
        .cache_control = "max-age=60, no-cache=\"Set-Cookie, X-Private\", stale-while-revalidate=30",
        .etag = "\"v1\"",
        .last_modified = epoch_date,
    }, 0, 0, 10);
    try testing.expect(result.store);
    try testing.expect(result.requires_validation);
    try testing.expect(result.fresh_until <= 10);
    try testing.expectEqual(result.fresh_until, result.stale_while_revalidate_until);
}

test "corrected age includes Age plus response delay and resident time" {
    const headers: Headers = .{ .cache_control = "max-age=100", .date = epoch_date, .age = "20" };
    const fresh = evaluate(headers, 5, 10, 84);
    try testing.expectEqual(@as(i64, 85), fresh.fresh_until);
    try testing.expect(!fresh.requires_validation);
    try testing.expect(evaluate(headers, 5, 10, 85).requires_validation);
    // apparent age dominates: do not add response delay twice.
    const apparent = evaluate(.{ .cache_control = "max-age=100", .date = epoch_date, .age = "1" }, 5, 20, 20);
    try testing.expectEqual(@as(i64, 100), apparent.fresh_until);
}

test "Expires fallback and max-age precedence" {
    const expires = "Thu, 01 Jan 1970 00:02:00 GMT";
    const fallback = evaluate(.{ .date = epoch_date, .expires = expires }, 0, 10, 20);
    try testing.expectEqual(@as(i64, 120), fallback.fresh_until);
    const precedence = evaluate(.{ .cache_control = "max-age=30", .expires = "invalid" }, 0, 0, 0);
    try testing.expectEqual(@as(i64, 30), precedence.fresh_until);
    const missing_date = evaluate(.{ .expires = expires }, 10, 10, 10);
    try testing.expectEqual(@as(i64, 120), missing_date.fresh_until);
    try testing.expect(evaluate(.{}, 0, 0, 0).requires_validation);
    try testing.expect(evaluate(.{ .last_modified = epoch_date, .etag = "v1" }, 0, 0, 0).requires_validation);
}

test "invalid and duplicate freshness is stale without fallback or SWR" {
    const directives = [_][]const u8{
        "max-age=-1",                  "max-age=+1",             "max-age=",                "max-age",                 "max-age=1.5",
        "max-age=9223372036854775808", "max-age=60, max-age=60", "max-age=60, MAX-AGE=120", "max-age=bad, max-age=60", "max-age=60, max-age=bad",
        "max-age=\"60",
    };
    for (directives) |directive| {
        const result = evaluate(.{ .cache_control = directive, .expires = "Thu, 01 Jan 1970 00:02:00 GMT" }, 0, 0, 0);
        try testing.expect(result.requires_validation);
        try testing.expect(result.fresh_until <= 0);
        try testing.expectEqual(result.fresh_until, result.stale_while_revalidate_until);
    }
    for ([_][]const u8{ "-1", "garbage", "1, 2", "9223372036854775808" }) |age| {
        try testing.expect(evaluate(.{ .cache_control = "max-age=60, stale-while-revalidate=30", .age = age }, 0, 0, 0).requires_validation);
    }
    try testing.expect(evaluate(.{ .cache_control = "max-age=60", .date = "not a date" }, 0, 0, 0).requires_validation);
    try testing.expect(evaluate(.{ .expires = "0" }, 0, 0, 0).requires_validation);
}

test "SWR boundaries and must-revalidate prohibition" {
    const headers: Headers = .{ .cache_control = "max-age=10, stale-while-revalidate=20" };
    const stale = evaluate(headers, 0, 0, 10);
    try testing.expectEqual(@as(i64, 10), stale.fresh_until);
    try testing.expectEqual(@as(i64, 30), stale.stale_while_revalidate_until);
    try testing.expect(!stale.requires_validation);
    try testing.expect(!evaluate(headers, 0, 0, 29).requires_validation);
    try testing.expect(evaluate(headers, 0, 0, 30).requires_validation);
    const strict = evaluate(.{ .cache_control = "max-age=10, stale-while-revalidate=20, must-revalidate" }, 0, 0, 10);
    try testing.expect(strict.must_revalidate);
    try testing.expect(strict.requires_validation);
    try testing.expectEqual(strict.fresh_until, strict.stale_while_revalidate_until);
    try testing.expect(!evaluate(.{ .cache_control = "max-age=10, must-revalidate" }, 0, 0, 9).requires_validation);
    for ([_][]const u8{
        "max-age=10, stale-while-revalidate=bad",
        "max-age=10, stale-while-revalidate=20, stale-while-revalidate=20",
        "stale-while-revalidate=20",
    }) |directive| {
        try testing.expect(evaluate(.{ .cache_control = directive }, 0, 0, 10).requires_validation);
    }
}

test "quoted values and unknown extensions do not inject directives" {
    const result = evaluate(.{ .cache_control = "extension=\"no-store, max-age=0\", MaX-aGe = \"60\", private" }, 0, 0, 0);
    try testing.expect(result.store);
    try testing.expectEqual(@as(i64, 60), result.fresh_until);
    try testing.expect(evaluate(.{ .cache_control = "s-maxage=60" }, 0, 0, 0).requires_validation);
}

test "HTTP date validates calendar and weekday" {
    try testing.expectEqual(@as(?i64, 0), parseDate(epoch_date));
    try testing.expectEqual(@as(?i64, 784111777), parseDate("Sun, 06 Nov 1994 08:49:37 GMT"));
    try testing.expectEqual(@as(?i64, -1), parseDate("Wed, 31 Dec 1969 23:59:59 GMT"));
    try testing.expect(parseDate("Tue, 29 Feb 2000 00:00:00 GMT") != null);
    for ([_][]const u8{
        "Mon, 29 Feb 1900 00:00:00 GMT",    "Thu, 32 Jan 1970 00:00:00 GMT",
        "Fri, 01 Jan 1970 00:00:00 GMT",    "Thu, 01 Jan 1970 24:00:00 GMT",
        "Thu, 01 Jan 1970 00:00:60 GMT",    "Thu, 01 Jan 1970 00:00:00 UTC",
        "Thursday, 01-Jan-70 00:00:00 GMT", "Thu Jan  1 00:00:00 1970",
    }) |date| try testing.expectEqual(@as(?i64, null), parseDate(date));
}

test "extreme timestamps cannot overflow and clock reversal forces validation" {
    const headers: Headers = .{ .cache_control = "max-age=9223372036854775807, stale-while-revalidate=9223372036854775807" };
    const high: i64 = std.math.maxInt(i64);
    const low: i64 = std.math.minInt(i64);
    try testing.expectEqual(high, evaluate(headers, high - 1, high - 1, high - 1).fresh_until);
    try testing.expect(evaluate(headers, low, high, high).requires_validation);
    try testing.expect(evaluate(headers, 10, 9, 10).requires_validation);
    try testing.expect(evaluate(headers, 0, 10, 9).requires_validation);
}
