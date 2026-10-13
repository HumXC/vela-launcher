//! Version documents only: no inheritance resolution, IO or host filtering.
const std = @import("std");
const j = @import("json.zig");
const own = @import("owned.zig");
pub const rules = @import("rules.zig");
pub const Download = struct { url: []const u8, sha1: ?j.Sha1, size: ?u64, path: ?[]const u8 };
pub const DownloadEntry = struct { name: []const u8, download: Download };
pub const LibraryDownloads = struct { artifact: ?Download, classifiers: []const DownloadEntry };
pub const Library = struct {
    name: []const u8,
    url: ?[]const u8,
    downloads: ?LibraryDownloads,
    rules: ?[]const rules.Rule,
    natives: []const j.StringEntry,
    extract_exclude: ?[]const []const u8,
};
pub const Argument = union(enum) {
    literal: []const u8,
    conditional: struct { rules: []const rules.Rule, values: []const []const u8 },
};
pub const Arguments = struct { game: ?[]const Argument, jvm: ?[]const Argument };
pub const AssetIndexReference = struct { id: []const u8, url: []const u8, sha1: ?j.Sha1, size: ?u64, total_size: ?u64 };
pub const JavaVersion = struct { component: []const u8, major_version: u64 };
pub const Logging = struct { name: []const u8, argument: []const u8, kind: []const u8, file: struct { id: []const u8, url: []const u8, sha1: ?j.Sha1, size: ?u64 } };
pub const Version = struct {
    id: []const u8,
    kind: ?[]const u8,
    main_class: ?[]const u8,
    inherits_from: ?[]const u8,
    jar: ?[]const u8,
    time: ?[]const u8,
    release_time: ?[]const u8,
    minimum_launcher_version: ?u64,
    compliance_level: ?u64,
    java_version: ?JavaVersion,
    downloads: []const DownloadEntry,
    libraries: ?[]const Library,
    arguments: ?Arguments,
    minecraft_arguments: ?[]const u8,
    asset_index: ?AssetIndexReference,
    assets: ?[]const u8,
    logging: []const Logging,
};
pub const max_document_bytes = 8 * 1024 * 1024;
pub fn parseSlice(a: j.A, bytes: []const u8) !own.Owned(Version) {
    if (bytes.len > max_document_bytes) return error.MetadataTooLarge;
    return own.fromSlice(Version, a, bytes, decode);
}
pub fn parseValue(a: j.A, v: j.V) !own.Owned(Version) {
    return own.fromValue(Version, a, v, decode);
}
fn download(a: j.A, v: j.V) !Download {
    return .{ .url = try j.text(a, v, "url"), .sha1 = try j.maybeSha1(v, "sha1"), .size = try j.maybeUint(v, "size"), .path = try j.maybeText(a, v, "path") };
}
fn downloadMap(a: j.A, v: j.V) ![]const DownloadEntry {
    const map = try j.object(v);
    const out = try a.alloc(DownloadEntry, map.count());
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) out[i] = .{ .name = try a.dupe(u8, e.key_ptr.*), .download = try download(a, e.value_ptr.*) };
    return out;
}
fn library(a: j.A, v: j.V) !Library {
    var downloads: ?LibraryDownloads = null;
    if (try j.optional(v, "downloads")) |d| downloads = .{ .artifact = if (try j.optional(d, "artifact")) |x| try download(a, x) else null, .classifiers = if (try j.optional(d, "classifiers")) |x| try downloadMap(a, x) else &.{} };
    var exclude: ?[]const []const u8 = null;
    if (try j.optional(v, "extract")) |e| if (try j.optional(e, "exclude")) |x| {
        exclude = try j.strings(a, x);
    };
    return .{ .name = try j.text(a, v, "name"), .url = try j.maybeText(a, v, "url"), .downloads = downloads, .rules = if (try j.optional(v, "rules")) |r| try rules.decodeList(a, r) else null, .natives = if (try j.optional(v, "natives")) |n| try j.stringMap(a, n) else &.{}, .extract_exclude = exclude };
}
fn argument(a: j.A, v: j.V) !Argument {
    if (v == .string) return .{ .literal = try j.string(a, v) };
    const value = try j.required(v, "value");
    const values = if (value == .string) blk: {
        const result = try a.alloc([]const u8, 1);
        result[0] = try j.string(a, value);
        break :blk result;
    } else try j.strings(a, value);
    return .{ .conditional = .{ .rules = try rules.decodeList(a, try j.required(v, "rules")), .values = values } };
}
fn logging(a: j.A, v: j.V) ![]const Logging {
    const map = try j.object(v);
    const out = try a.alloc(Logging, map.count());
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        const file = try j.required(e.value_ptr.*, "file");
        out[i] = .{ .name = try a.dupe(u8, e.key_ptr.*), .argument = try j.text(a, e.value_ptr.*, "argument"), .kind = try j.text(a, e.value_ptr.*, "type"), .file = .{ .id = try j.text(a, file, "id"), .url = try j.text(a, file, "url"), .sha1 = try j.maybeSha1(file, "sha1"), .size = try j.maybeUint(file, "size") } };
    }
    return out;
}
fn decode(a: j.A, v: j.V) !Version {
    var java: ?JavaVersion = null;
    if (try j.optional(v, "javaVersion")) |x| {
        const major = try j.uint(try j.required(x, "majorVersion"));
        if (major == 0) return error.InvalidJavaVersion;
        java = .{ .component = try j.text(a, x, "component"), .major_version = major };
    }
    var args: ?Arguments = null;
    if (try j.optional(v, "arguments")) |x| args = .{ .game = if (try j.optional(x, "game")) |g| try j.list(Argument, a, g, argument) else null, .jvm = if (try j.optional(x, "jvm")) |g| try j.list(Argument, a, g, argument) else null };
    var index: ?AssetIndexReference = null;
    if (try j.optional(v, "assetIndex")) |x| index = .{ .id = try j.text(a, x, "id"), .url = try j.text(a, x, "url"), .sha1 = try j.maybeSha1(x, "sha1"), .size = try j.maybeUint(x, "size"), .total_size = try j.maybeUint(x, "totalSize") };
    const id = try j.text(a, v, "id");
    try validateId(id);
    const parent = try j.maybeText(a, v, "inheritsFrom");
    const jar = try j.maybeText(a, v, "jar");
    if (parent) |x| try validateId(x);
    if (jar) |x| try validateId(x);
    return .{
        .id = id,
        .kind = try j.maybeText(a, v, "type"),
        .main_class = try j.maybeText(a, v, "mainClass"),
        .inherits_from = parent,
        .jar = jar,
        .time = try j.maybeText(a, v, "time"),
        .release_time = try j.maybeText(a, v, "releaseTime"),
        .minimum_launcher_version = try j.maybeUint(v, "minimumLauncherVersion"),
        .compliance_level = try j.maybeUint(v, "complianceLevel"),
        .java_version = java,
        .downloads = if (try j.optional(v, "downloads")) |x| try downloadMap(a, x) else &.{},
        .libraries = if (try j.optional(v, "libraries")) |x| try j.list(Library, a, x, library) else null,
        .arguments = args,
        .minecraft_arguments = try j.maybeText(a, v, "minecraftArguments"),
        .asset_index = index,
        .assets = try j.maybeText(a, v, "assets"),
        .logging = if (try j.optional(v, "logging")) |x| try logging(a, x) else &.{},
    };
}

pub const inheritance = @import("inheritance.zig");

/// Java selection is exact: absent Mojang requirements mean Java 8, not latest.
pub fn requiredJavaMajor(version: Version) u64 {
    return if (version.java_version) |java| java.major_version else 8;
}

pub fn validateId(id: []const u8) !void {
    if (id.len == 0 or id.len > 200 or !std.unicode.utf8ValidateSlice(id)) return error.UnsafeVersionId;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return error.UnsafeVersionId;
    if (id[id.len - 1] == '.' or id[id.len - 1] == ' ') return error.UnsafeVersionId;
    var it = std.unicode.Utf8View.initUnchecked(id).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.UnsafeVersionId;
        if (cp < 128 and std.mem.indexOfScalar(u8, "<>:\"/\\|?*", @intCast(cp)) != null) return error.UnsafeVersionId;
    }
    const end = std.mem.indexOfScalar(u8, id, '.') orelse id.len;
    const stem = std.mem.trimEnd(u8, id[0..end], " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$" }) |name| {
        if (std.ascii.eqlIgnoreCase(stem, name)) return error.UnsafeVersionId;
    }
    if (stem.len >= 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) {
        if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9') return error.UnsafeVersionId;
        if (stem.len == 5 and stem[3] == 0xc2 and (stem[4] == 0xb9 or stem[4] == 0xb2 or stem[4] == 0xb3)) return error.UnsafeVersionId;
    }
}

fn validateMavenComponent(id: []const u8) !void {
    if (id.len == 0 or id.len > 255 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return error.UnsafeMavenCoordinate;
    if (id[id.len - 1] == '.' or id[id.len - 1] == ' ') return error.UnsafeMavenCoordinate;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_' and c != '+') return error.UnsafeMavenCoordinate;
    const base = id[0 .. std.mem.indexOfScalar(u8, id, '.') orelse id.len];
    if (std.ascii.eqlIgnoreCase(base, "con") or std.ascii.eqlIgnoreCase(base, "prn") or std.ascii.eqlIgnoreCase(base, "aux") or std.ascii.eqlIgnoreCase(base, "nul")) return error.UnsafeMavenCoordinate;
    if (base.len == 4 and (std.ascii.eqlIgnoreCase(base[0..3], "com") or std.ascii.eqlIgnoreCase(base[0..3], "lpt")) and std.ascii.isDigit(base[3])) return error.UnsafeMavenCoordinate;
}

pub const MavenCoordinate = struct {
    group: []const u8,
    artifact: []const u8,
    version: []const u8,
    classifier: ?[]const u8,
    extension: []const u8,

    pub fn path(self: MavenCoordinate, a: std.mem.Allocator, classifier: ?[]const u8) ![]const u8 {
        try mavenGroup(self.group);
        for ([_][]const u8{ self.artifact, self.version, self.extension }) |part| try mavenPart(part);
        const group = try a.dupe(u8, self.group);
        defer a.free(group);
        for (group) |*c| if (c.* == '.') {
            c.* = '/';
        };
        if (classifier orelse self.classifier) |c| {
            try mavenPart(c);
            return std.fmt.allocPrint(a, "{s}/{s}/{s}/{s}-{s}-{s}.{s}", .{ group, self.artifact, self.version, self.artifact, self.version, c, self.extension });
        }
        return std.fmt.allocPrint(a, "{s}/{s}/{s}/{s}-{s}.{s}", .{ group, self.artifact, self.version, self.artifact, self.version, self.extension });
    }
};

/// Maven fields never become arbitrary path segments or URL fragments.
pub fn mavenCoordinate(name: []const u8) !MavenCoordinate {
    if (name.len > 2048) return error.UnsafeMavenCoordinate;
    var ext_parts = std.mem.splitScalar(u8, name, '@');
    const coordinate = ext_parts.next().?;
    const extension = ext_parts.next() orelse "jar";
    if (ext_parts.next() != null) return error.UnsafeMavenCoordinate;
    var parts = std.mem.splitScalar(u8, coordinate, ':');
    const group = parts.next() orelse return error.UnsafeMavenCoordinate;
    const artifact = parts.next() orelse return error.UnsafeMavenCoordinate;
    const version = parts.next() orelse return error.UnsafeMavenCoordinate;
    const classifier = parts.next();
    if (parts.next() != null) return error.UnsafeMavenCoordinate;
    for ([_][]const u8{ group, artifact, version, extension }) |part| try mavenPart(part);
    if (classifier) |c| try mavenPart(c);
    try mavenGroup(group);
    return .{ .group = group, .artifact = artifact, .version = version, .classifier = classifier, .extension = extension };
}
fn mavenGroup(group: []const u8) !void {
    var parts = std.mem.splitScalar(u8, group, '.');
    while (parts.next()) |part| try mavenPart(part);
}
fn mavenPart(part: []const u8) !void {
    try validateMavenComponent(part);
}

/// Quotes/backslashes group argv tokens; no shell expansion or evaluation occurs.
/// Expand placeholders AFTER tokenization so identity/path spaces stay one token.
pub fn tokenizeLegacy(a: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    if (source.len > 1024 * 1024) return error.LegacyArgumentsTooLarge;
    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (tokens.items) |item| a.free(item);
        tokens.deinit(a);
    }
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(a);
    var quote: ?u8 = null;
    var active = false;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (c == 0) return error.EmbeddedNul;
        if (c == 92 and i + 1 < source.len and (source[i + 1] == 92 or source[i + 1] == 34 or source[i + 1] == 39 or std.ascii.isWhitespace(source[i + 1]))) {
            i += 1;
            try token.append(a, source[i]);
            active = true;
        } else if (quote) |q| {
            if (c == q) quote = null else try token.append(a, c);
        } else if (c == 34 or c == 39) {
            quote = c;
            active = true;
        } else if (std.ascii.isWhitespace(c)) {
            if (active) {
                try appendLegacyToken(a, &tokens, &token);
                active = false;
            }
        } else {
            try token.append(a, c);
            active = true;
        }
    }
    if (quote != null) return error.UnclosedLegacyQuote;
    if (active) try appendLegacyToken(a, &tokens, &token);
    return tokens.toOwnedSlice(a);
}
fn appendLegacyToken(a: std.mem.Allocator, tokens: *std.ArrayList([]const u8), token: *std.ArrayList(u8)) !void {
    if (tokens.items.len >= 8192) return error.TooManyArguments;
    const owned = try token.toOwnedSlice(a);
    errdefer a.free(owned);
    try tokens.append(a, owned);
}

test "legacy tokenization and portable IDs are bounded and literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenizeLegacy(arena.allocator(), "--tweakClass cpw.mods.fml.common.launcher.FMLTweaker --name \"A B\" --literal '$(no-shell)' --empty \"\"");
    try std.testing.expectEqualStrings("A B", tokens[3]);
    try std.testing.expectEqualStrings("$(no-shell)", tokens[5]);
    try std.testing.expectEqualStrings("", tokens[7]);
    try std.testing.expectError(error.UnclosedLegacyQuote, tokenizeLegacy(arena.allocator(), "'open"));
    for ([_][]const u8{ "../bad", "C:drive", "nul.json", "bad/child", "trailing." }) |id| try std.testing.expectError(error.UnsafeVersionId, validateId(id));
    try std.testing.expectError(error.UnsafeMavenCoordinate, mavenCoordinate("org.example:../bad:1"));
    const c = try mavenCoordinate("org.example:lib:1.2:natives-linux-arm64");
    try std.testing.expectEqualStrings("org/example/lib/1.2/lib-1.2-natives-linux-arm64.jar", try c.path(arena.allocator(), null));
}

test "portable instance names permit Unicode and spaces without loosening Maven paths" {
    try validateId("My Forge 1.7.10");
    try validateId("实例 世界");
    for ([_][]const u8{ "bad ", "bad.", "clock$.json", "CON .json", "COM¹", "LPT²", "CONIN$", "CONOUT$", "bad\x7fname", "bad\xc2\x80name", "bad\xffname" }) |id|
        try std.testing.expectError(error.UnsafeVersionId, validateId(id));
    try std.testing.expectError(error.UnsafeMavenCoordinate, mavenCoordinate("org.example:My Forge:1"));
    try std.testing.expectError(error.UnsafeMavenCoordinate, mavenCoordinate("org.example:实例:1"));
}

test {
    _ = inheritance;
}

fn tokenAllocationCase(a: std.mem.Allocator) !void {
    const tokens = try tokenizeLegacy(a, "one '' \"two three\" four");
    defer {
        for (tokens) |token| a.free(token);
        a.free(tokens);
    }
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
}
test "legacy tokenizer allocation cleanup and bounds" {
    const a = std.testing.allocator;
    try @import("test_allocations").checkAllAllocationFailures(a, tokenAllocationCase, .{});
    const excessive = try a.alloc(u8, 8193 * 2);
    defer a.free(excessive);
    for (excessive, 0..) |*c, i| c.* = if (i % 2 == 0) 'x' else ' ';
    try std.testing.expectError(error.TooManyArguments, tokenizeLegacy(a, excessive));
    const document = try a.alloc(u8, max_document_bytes + 1);
    defer a.free(document);
    try std.testing.expectError(error.MetadataTooLarge, parseSlice(a, document));
    try std.testing.expectError(error.UnsafeMavenCoordinate, mavenCoordinate("org.con:lib:1"));
    try std.testing.expectError(error.UnsafeMavenCoordinate, mavenCoordinate("org..example:lib:1"));
}
