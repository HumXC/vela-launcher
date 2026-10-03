//! Canonical Mojang version JSON for resolved custom-instance metadata.
const std = @import("std");
const metadata = @import("metadata/root.zig");
const v = metadata.version;
const Json = std.json.Stringify;

/// Borrows every field in version. The caller owns the returned bytes and frees
/// them with a. This preserves modeled metadata; inheritance is not resolved here.
pub fn serialize(a: std.mem.Allocator, version: @import("metadata/root.zig").version.Version) ![]u8 {
    return Json.valueAlloc(a, VersionJson{ .version = version }, .{ .emit_null_optional_fields = false });
}

const VersionJson = struct {
    version: v.Version,

    pub fn jsonStringify(self: @This(), j: *Json) Json.Error!void {
        const version = self.version;
        try j.beginObject();
        try field(j, "id", version.id);
        try optionalField(j, "type", version.kind);
        try optionalField(j, "mainClass", version.main_class);
        try optionalField(j, "inheritsFrom", version.inherits_from);
        try optionalField(j, "jar", version.jar);
        try optionalField(j, "time", version.time);
        try optionalField(j, "releaseTime", version.release_time);
        try optionalField(j, "minimumLauncherVersion", version.minimum_launcher_version);
        try optionalField(j, "complianceLevel", version.compliance_level);
        if (version.java_version) |java| {
            try field(j, "javaVersion", .{ .component = java.component, .majorVersion = java.major_version });
        }
        if (version.downloads.len != 0) {
            try j.objectField("downloads");
            try downloadMap(j, version.downloads);
        }
        if (version.libraries) |libraries| {
            try j.objectField("libraries");
            try j.beginArray();
            for (libraries) |lib| try library(j, lib);
            try j.endArray();
        }
        if (version.arguments) |arguments| {
            try j.objectField("arguments");
            try j.beginObject();
            if (arguments.game) |game| {
                try j.objectField("game");
                try argumentList(j, game);
            }
            if (arguments.jvm) |jvm| {
                try j.objectField("jvm");
                try argumentList(j, jvm);
            }
            try j.endObject();
        }
        try optionalField(j, "minecraftArguments", version.minecraft_arguments);
        if (version.asset_index) |index| {
            try j.objectField("assetIndex");
            try j.beginObject();
            try field(j, "id", index.id);
            try field(j, "url", index.url);
            try sha1Field(j, index.sha1);
            try optionalField(j, "size", index.size);
            try optionalField(j, "totalSize", index.total_size);
            try j.endObject();
        }
        try optionalField(j, "assets", version.assets);
        if (version.logging.len != 0) {
            try j.objectField("logging");
            try j.beginObject();
            for (version.logging) |log| {
                try j.objectField(log.name);
                try j.beginObject();
                try field(j, "argument", log.argument);
                try field(j, "type", log.kind);
                try j.objectField("file");
                try j.beginObject();
                try field(j, "id", log.file.id);
                try field(j, "url", log.file.url);
                try sha1Field(j, log.file.sha1);
                try optionalField(j, "size", log.file.size);
                try j.endObject();
                try j.endObject();
            }
            try j.endObject();
        }
        try j.endObject();
    }
};

fn field(j: *Json, name: []const u8, value: anytype) Json.Error!void {
    try j.objectField(name);
    try j.write(value);
}

fn optionalField(j: *Json, name: []const u8, value: anytype) Json.Error!void {
    if (value) |present| try field(j, name, present);
}

fn sha1Field(j: *Json, value: ?metadata.Sha1) Json.Error!void {
    if (value) |hash| {
        const hex = std.fmt.bytesToHex(hash, .lower);
        try field(j, "sha1", &hex);
    }
}

fn download(j: *Json, item: v.Download) Json.Error!void {
    try j.beginObject();
    try field(j, "url", item.url);
    try sha1Field(j, item.sha1);
    try optionalField(j, "size", item.size);
    try optionalField(j, "path", item.path);
    try j.endObject();
}

fn downloadMap(j: *Json, entries: []const v.DownloadEntry) Json.Error!void {
    try j.beginObject();
    for (entries) |entry| {
        try j.objectField(entry.name);
        try download(j, entry.download);
    }
    try j.endObject();
}

fn library(j: *Json, lib: v.Library) Json.Error!void {
    try j.beginObject();
    try field(j, "name", lib.name);
    try optionalField(j, "url", lib.url);
    if (lib.downloads) |downloads| {
        try j.objectField("downloads");
        try j.beginObject();
        if (downloads.artifact) |artifact| {
            try j.objectField("artifact");
            try download(j, artifact);
        }
        if (downloads.classifiers.len != 0) {
            try j.objectField("classifiers");
            try downloadMap(j, downloads.classifiers);
        }
        try j.endObject();
    }
    if (lib.rules) |rules| {
        try j.objectField("rules");
        try ruleList(j, rules);
    }
    if (lib.natives.len != 0) {
        try j.objectField("natives");
        try j.beginObject();
        for (lib.natives) |native| try field(j, native.key, native.value);
        try j.endObject();
    }
    if (lib.extract_exclude) |exclude| try field(j, "extract", .{ .exclude = exclude });
    try j.endObject();
}

fn ruleList(j: *Json, rules: []const metadata.rules.Rule) Json.Error!void {
    try j.beginArray();
    for (rules) |rule| {
        try j.beginObject();
        try field(j, "action", @tagName(rule.action));
        try optionalField(j, "os", rule.os);
        if (rule.features.len != 0) {
            try j.objectField("features");
            try j.beginObject();
            for (rule.features) |feature| try field(j, feature.name, feature.enabled);
            try j.endObject();
        }
        try j.endObject();
    }
    try j.endArray();
}

fn argumentList(j: *Json, arguments: []const v.Argument) Json.Error!void {
    try j.beginArray();
    for (arguments) |argument| switch (argument) {
        .literal => |literal| try j.write(literal),
        .conditional => |conditional| {
            try j.beginObject();
            try j.objectField("rules");
            try ruleList(j, conditional.rules);
            try field(j, "value", conditional.values);
            try j.endObject();
        },
    };
    try j.endArray();
}

const modern_fixture =
    \\{
    \\  "id": "instance-modern-custom",
    \\  "type": "release",
    \\  "mainClass": "example.loader.Main",
    \\  "inheritsFrom": "1.21.5",
    \\  "jar": "1.21.5",
    \\  "time": "2025-03-25T12:00:00Z",
    \\  "releaseTime": "2025-03-25T11:00:00Z",
    \\  "minimumLauncherVersion": 21,
    \\  "complianceLevel": 1,
    \\  "javaVersion": {
    \\    "component": "java-runtime-delta",
    \\    "majorVersion": 21
    \\  },
    \\  "downloads": {
    \\    "client": {
    \\      "url": "https://example.invalid/client.jar",
    \\      "sha1": "0123456789ABCDEF0123456789ABCDEF01234567",
    \\      "size": 18446744073709551615,
    \\      "path": "client.jar"
    \\    },
    \\    "server": {
    \\      "url": "https://example.invalid/server.jar",
    \\      "sha1": "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
    \\      "size": 0
    \\    },
    \\    "client_mappings": {
    \\      "url": "https://example.invalid/mappings.txt"
    \\    }
    \\  },
    \\  "libraries": [
    \\    {
    \\      "name": "org.example:native:1.0",
    \\      "url": "https://example.invalid/maven/",
    \\      "downloads": {
    \\        "artifact": {
    \\          "url": "https://example.invalid/lib.jar",
    \\          "sha1": "0123456789ABCDEF0123456789ABCDEF01234567",
    \\          "size": 9,
    \\          "path": "org/example/native/1.0/native-1.0.jar"
    \\        },
    \\        "classifiers": {
    \\          "natives-linux": {
    \\            "url": "https://example.invalid/linux.jar",
    \\            "sha1": "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
    \\            "size": 7,
    \\            "path": "org/example/native/1.0/native-1.0-natives-linux.jar"
    \\          },
    \\          "natives-windows-64": {
    \\            "url": "https://example.invalid/windows.jar"
    \\          }
    \\        }
    \\      },
    \\      "rules": [
    \\        {
    \\          "action": "allow"
    \\        },
    \\        {
    \\          "action": "disallow",
    \\          "os": {
    \\            "name": "windows",
    \\            "arch": "x86_64",
    \\            "version": "^10.*"
    \\          },
    \\          "features": {
    \\            "is_demo_user": true,
    \\            "has_custom_resolution": false
    \\          }
    \\        },
    \\        {
    \\          "action": "allow",
    \\          "features": {
    \\            "unknown": false
    \\          }
    \\        }
    \\      ],
    \\      "natives": {
    \\        "linux": "natives-linux",
    \\        "windows": "natives-windows-${arch}"
    \\      },
    \\      "extract": {
    \\        "exclude": [
    \\          "META-INF/",
    \\          "license.txt"
    \\        ]
    \\      }
    \\    },
    \\    {
    \\      "name": "org.example:empty:1.0",
    \\      "downloads": {},
    \\      "rules": [],
    \\      "extract": {
    \\        "exclude": []
    \\      }
    \\    },
    \\    {
    \\      "name": "org.example:plain:1.0"
    \\    }
    \\  ],
    \\  "arguments": {
    \\    "game": [
    \\      "--username",
    \\      "${auth_player_name}",
    \\      {
    \\        "rules": [
    \\          {
    \\            "action": "allow",
    \\            "features": {
    \\              "has_custom_resolution": true
    \\            }
    \\          }
    \\        ],
    \\        "value": [
    \\          "--width",
    \\          "${resolution_width}"
    \\        ]
    \\      },
    \\      {
    \\        "rules": [],
    \\        "value": "single"
    \\      },
    \\      {
    \\        "rules": [
    \\          {
    \\            "action": "allow",
    \\            "os": {}
    \\          }
    \\        ],
    \\        "value": []
    \\      }
    \\    ],
    \\    "jvm": [
    \\      "-Dquoted=\"value\"",
    \\      {
    \\        "rules": [
    \\          {
    \\            "action": "allow",
    \\            "os": {
    \\              "name": "linux"
    \\            }
    \\          }
    \\        ],
    \\        "value": [
    \\          "-Djava.library.path=${natives_directory}",
    \\          "-cp",
    \\          "${classpath}"
    \\        ]
    \\      }
    \\    ]
    \\  },
    \\  "minecraftArguments": "--username ${auth_player_name}",
    \\  "assetIndex": {
    \\    "id": "23",
    \\    "url": "https://example.invalid/assets.json",
    \\    "sha1": "0123456789ABCDEF0123456789ABCDEF01234567",
    \\    "size": 100,
    \\    "totalSize": 18446744073709551615
    \\  },
    \\  "assets": "23",
    \\  "logging": {
    \\    "client": {
    \\      "argument": "-Dlog4j.configurationFile=${path}",
    \\      "type": "log4j2-xml",
    \\      "file": {
    \\        "id": "client.xml",
    \\        "url": "https://example.invalid/client.xml",
    \\        "sha1": "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
    \\        "size": 42
    \\      }
    \\    },
    \\    "server": {
    \\      "argument": "-Dconfig=${path}",
    \\      "type": "log4j2-xml",
    \\      "file": {
    \\        "id": "server.xml",
    \\        "url": "https://example.invalid/server.xml"
    \\      }
    \\    }
    \\  }
    \\}
;

const legacy_fixture =
    \\{
    \\  "id": "instance-legacy-custom",
    \\  "type": "old_beta",
    \\  "mainClass": "net.minecraft.client.Minecraft",
    \\  "minecraftArguments": "--username ${auth_player_name} --session ${auth_session}",
    \\  "assets": "legacy",
    \\  "libraries": [
    \\    {
    \\      "name": "org.lwjgl.lwjgl:lwjgl:2.9.1",
    \\      "url": "https://example.invalid/maven/",
    \\      "natives": {
    \\        "linux": "natives-linux"
    \\      },
    \\      "extract": {
    \\        "exclude": [
    \\          "META-INF/"
    \\        ]
    \\      },
    \\      "rules": [
    \\        {
    \\          "action": "allow",
    \\          "os": {
    \\            "name": "linux"
    \\          }
    \\        }
    \\      ]
    \\    }
    \\  ]
    \\}
;

// Compare every modeled field, including optional-empty distinctions and union
// payloads, so roundtrips cannot pass by dropping the same field twice.
fn expectEquivalent(comptime T: type, expected: T, actual: T) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |f| {
            try expectEquivalent(f.type, @field(expected, f.name), @field(actual, f.name));
        },
        .optional => |info| {
            try std.testing.expectEqual(expected == null, actual == null);
            if (expected) |present| try expectEquivalent(info.child, present, actual.?);
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("fixture comparison requires slices");
            try std.testing.expectEqual(expected.len, actual.len);
            for (expected, actual) |left, right| try expectEquivalent(info.child, left, right);
        },
        .array => |info| for (expected, actual) |left, right| {
            try expectEquivalent(info.child, left, right);
        },
        .@"union" => |info| {
            try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
            inline for (info.fields) |f| {
                if (std.meta.activeTag(expected) == @field(info.tag_type.?, f.name)) {
                    try expectEquivalent(f.type, @field(expected, f.name), @field(actual, f.name));
                }
            }
        },
        else => try std.testing.expectEqual(expected, actual),
    }
}

fn roundtrip(allocator: std.mem.Allocator, version: v.Version) !void {
    const bytes = try serialize(allocator, version);
    defer allocator.free(bytes);
    var parsed = try v.parseSlice(std.testing.allocator, bytes);
    defer parsed.deinit();
    try expectEquivalent(v.Version, version, parsed.value);
    const again = try serialize(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings(bytes, again);
}

test "modern Mojang JSON preserves every metadata field and custom id" {
    const a = std.testing.allocator;
    var input = try v.parseSlice(a, modern_fixture);
    defer input.deinit();
    try roundtrip(a, input.value);
    const bytes = try serialize(a, input.value);
    defer a.free(bytes);
    var json = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer json.deinit();
    const root = json.value.object;
    try std.testing.expectEqualStrings("instance-modern-custom", root.get("id").?.string);
    try std.testing.expect(root.get("main_class") == null);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", root.get("downloads").?.object.get("client").?.object.get("sha1").?.string);
    try std.testing.expectEqualStrings("ffffffffffffffffffffffffffffffffffffffff", root.get("logging").?.object.get("client").?.object.get("file").?.object.get("sha1").?.string);
    const game = root.get("arguments").?.object.get("game").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), game[3].object.get("value").?.array.items.len);
    const lib = root.get("libraries").?.array.items[0].object;
    try std.testing.expectEqualStrings("natives-windows-${arch}", lib.get("natives").?.object.get("windows").?.string);
    const rules = lib.get("rules").?.array.items;
    try std.testing.expectEqualStrings("disallow", rules[1].object.get("action").?.string);
    try std.testing.expect(!rules[1].object.get("features").?.object.get("has_custom_resolution").?.bool);
    try std.testing.expectEqual(@as(usize, 2), lib.get("extract").?.object.get("exclude").?.array.items.len);
}

test "legacy metadata and absent optional fields retain semantics" {
    const a = std.testing.allocator;
    var input = try v.parseSlice(a, legacy_fixture);
    defer input.deinit();
    try roundtrip(a, input.value);
    const bytes = try serialize(a, input.value);
    defer a.free(bytes);
    var json = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer json.deinit();
    const root = json.value.object;
    try std.testing.expectEqualStrings("instance-legacy-custom", root.get("id").?.string);
    inline for (.{ "javaVersion", "arguments", "downloads", "logging", "assetIndex", "inheritsFrom", "releaseTime" }) |name| {
        try std.testing.expect(root.get(name) == null);
    }
}

test "present empty collections and optional asset fields roundtrip" {
    const a = std.testing.allocator;
    inline for (.{
        \\{"id":"empty","libraries":[],"arguments":{"game":[],"jvm":[]},"assetIndex":{"id":"legacy","url":"https://example.invalid/index.json"}}
        ,
        \\{"id":"missing-modes","arguments":{},"libraries":[{"name":"org.example:lib:1.0","downloads":{"classifiers":{}},"rules":[],"extract":{"exclude":[]}}]}
        ,
        \\{"id":"minimal"}
        ,
    }) |fixture| {
        var input = try v.parseSlice(a, fixture);
        defer input.deinit();
        try roundtrip(a, input.value);
    }
}

test "serialization allocation failures clean up without taking input ownership" {
    const a = std.testing.allocator;
    inline for (.{ modern_fixture, legacy_fixture }) |fixture| {
        var input = try v.parseSlice(a, fixture);
        defer input.deinit();
        try std.testing.checkAllAllocationFailures(a, roundtrip, .{input.value});
        try roundtrip(a, input.value);
    }
}

test "returned JSON remains valid after borrowed input is destroyed" {
    const a = std.testing.allocator;
    const bytes = blk: {
        var input = try v.parseSlice(a, modern_fixture);
        defer input.deinit();
        break :blk try serialize(a, input.value);
    };
    defer a.free(bytes);
    var expected = try v.parseSlice(a, modern_fixture);
    defer expected.deinit();
    var actual = try v.parseSlice(a, bytes);
    defer actual.deinit();
    try expectEquivalent(v.Version, expected.value, actual.value);
}
