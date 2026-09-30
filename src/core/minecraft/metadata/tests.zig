const std = @import("std");
const m = @import("root.zig");
const a = std.testing.allocator;
const expect = std.testing.expect;
const eq = std.testing.expectEqual;
const modern = "{\"id\":\"26.3\",\"type\":\"snapshot\",\"mainClass\":\"net.minecraft.client.Main\",\"inheritsFrom\":\"parent\",\"javaVersion\":{\"component\":\"java-runtime\",\"majorVersion\":25},\"assets\":\"26\",\"assetIndex\":{\"id\":\"26\",\"url\":\"https://example/index\",\"sha1\":\"abababababababababababababababababababab\",\"size\":42,\"totalSize\":100},\"arguments\":{\"game\":[\"--username\",{\"rules\":[{\"action\":\"allow\",\"features\":{\"demo\":true}}],\"value\":[\"--demo\",\"yes\"]}],\"jvm\":[{\"rules\":[],\"value\":\"-Xmx2G\"}]},\"libraries\":[{\"name\":\"org:test:1\",\"downloads\":{\"classifiers\":{\"natives-any\":{\"url\":\"https://example/native\",\"sha1\":\"ABABABABABABABABABABABABABABABABABABABAB\",\"size\":20,\"path\":\"org/test.jar\"}}},\"natives\":{\"linux\":\"natives-${arch}\"},\"extract\":{\"exclude\":[\"META-INF/\"]},\"rules\":[{\"action\":\"allow\",\"os\":{\"name\":\"linux\"}}]}],\"downloads\":{\"client\":{\"url\":\"https://example/client\",\"size\":123}},\"logging\":{\"client\":{\"argument\":\"-Dlog=config\",\"type\":\"log4j2-xml\",\"file\":{\"id\":\"log.xml\",\"url\":\"https://example/log\",\"size\":10}}},\"unknown_future\":{\"anything\":true}}";
test "modern version supports conditionals classifiers logging and extension fields" {
    var p = try m.version.parseSlice(a, modern);
    defer p.deinit();
    const v = p.value;
    try eq(@as(u64, 25), v.java_version.?.major_version);
    try std.testing.expectEqualStrings("parent", v.inherits_from.?);
    try eq(@as(usize, 2), v.arguments.?.game.?.len);
    try eq(@as(usize, 2), v.arguments.?.game.?[1].conditional.values.len);
    try std.testing.expectEqualStrings("-Xmx2G", v.arguments.?.jvm.?[0].conditional.values[0]);
    try expect(v.libraries.?[0].downloads.?.artifact == null);
    try std.testing.expectEqualStrings("natives-any", v.libraries.?[0].downloads.?.classifiers[0].name);
    try std.testing.expectEqualStrings("natives-${arch}", v.libraries.?[0].natives[0].value);
    try eq(@as(u8, 0xab), v.libraries.?[0].downloads.?.classifiers[0].download.sha1.?[0]);
    try std.testing.expectEqualStrings("log.xml", v.logging[0].file.id);
    try expect(try m.rules.allows(v.libraries.?[0].rules, .{ .os_name = "linux", .arch = "x86_64" }));
}
test "parseValue deeply owns keys values and nested rules after input destruction" {
    var p: m.Owned(m.version.Version) = undefined;
    {
        const input = try a.dupe(u8, modern);
        defer a.free(input);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, input, .{});
        defer parsed.deinit();
        p = try m.version.parseValue(a, parsed.value);
    }
    defer p.deinit();
    try std.testing.expectEqualStrings("26.3", p.value.id);
    try std.testing.expectEqualStrings("linux", p.value.libraries.?[0].natives[0].key);
    try std.testing.expectEqualStrings("natives-any", p.value.libraries.?[0].downloads.?.classifiers[0].name);
    try std.testing.expectEqualStrings("demo", p.value.arguments.?.game.?[1].conditional.rules[0].features[0].name);
}
test "legacy and inherited partial documents retain absent fields" {
    var p = try m.version.parseSlice(a, "{\"id\":\"old\",\"minecraftArguments\":\"--username ${auth_player_name}\",\"libraries\":[],\"assets\":\"legacy\"}");
    defer p.deinit();
    try expect(p.value.arguments == null);
    try expect(p.value.java_version == null);
    try eq(@as(usize, 0), p.value.downloads.len);
    try eq(@as(usize, 0), p.value.libraries.?.len);
    try std.testing.expectEqualStrings("--username ${auth_player_name}", p.value.minecraft_arguments.?);
    var child = try m.version.parseSlice(a, "{\"id\":\"child\",\"inheritsFrom\":\"parent\",\"arguments\":{\"game\":[],\"jvm\":[]}}");
    defer child.deinit();
    try expect(child.value.main_class == null);
    try expect(child.value.libraries == null);
    try eq(@as(usize, 0), child.value.arguments.?.game.?.len);
}
test "asset index exact u64 SHA1 and independent legacy flags" {
    var p = try m.asset_index.parseSlice(a, "{\"objects\":{\"minecraft/sound.ogg\":{\"hash\":\"ABABABABABABABABABABABABABABABABABABABAB\",\"size\":18446744073709551615}},\"virtual\":true,\"map_to_resources\":true}");
    defer p.deinit();
    try eq(std.math.maxInt(u64), p.value.objects[0].size);
    try expect(p.value.virtual.? and p.value.map_to_resources.?);
    try eq(@as(u8, 0xab), p.value.objects[0].hash[0]);
    try expect(p.value.find("minecraft/sound.ogg") != null);
    try expect(p.value.find("missing") == null);
}
test "manifest lookup ignores unknown fields but validates known metadata" {
    const bytes = "{\"latest\":{\"release\":\"1\",\"snapshot\":\"2\"},\"versions\":[{\"id\":\"1\",\"type\":\"release\",\"url\":\"https://example\",\"time\":\"2020\",\"releaseTime\":\"2020\",\"sha1\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"complianceLevel\":1,\"extra\":5}],\"future\":true}";
    var p = try m.manifest.parseSlice(a, bytes);
    defer p.deinit();
    try expect(p.value.find("1") != null);
    try expect(p.value.find("2") == null);
    try eq(@as(u8, 0xaa), p.value.versions[0].sha1.?[0]);
    try std.testing.expectError(error.MissingField, m.manifest.parseSlice(a, "{}"));
    try std.testing.expectError(error.ExpectedArray, m.manifest.parseSlice(a, "{\"latest\":{\"release\":\"x\",\"snapshot\":\"y\"},\"versions\":null}"));
}
test "strict known fields reject null strings fractional sizes and invalid SHA1" {
    const bad_versions = [_][]const u8{ "{\"id\":1}", "{\"id\":\"x\",\"libraries\":false}", "{\"id\":\"x\",\"arguments\":{\"game\":[true]}}", "{\"id\":\"x\",\"javaVersion\":null}", "{\"id\":\"x\",\"downloads\":{\"client\":{\"url\":\"u\",\"sha1\":\"no\"}}}", "{\"id\":\"x\",\"libraries\":[{\"name\":\"n\",\"rules\":[{\"action\":\"deny\"}]}]}" };
    for (bad_versions) |bytes| {
        if (m.version.parseSlice(a, bytes)) |success| {
            var p = success;
            p.deinit();
            return error.InvalidInputAccepted;
        } else |_| {}
    }
    const sizes = [_][]const u8{ "-1", "1.5", "1e3", "18446744073709551616", "\"12\"" };
    for (sizes) |size| {
        const bytes = try std.mem.concat(a, u8, &.{ "{\"objects\":{\"x\":{\"hash\":\"abababababababababababababababababababab\",\"size\":", size, "}}}" });
        defer a.free(bytes);
        try std.testing.expectError(if (std.mem.eql(u8, size, "\"12\"")) error.ExpectedInteger else error.InvalidInteger, m.asset_index.parseSlice(a, bytes));
    }
    try std.testing.expectError(error.ExpectedObject, m.version.parseValue(a, .{ .float = 3.5 }));
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    var p = try m.version.parseSlice(allocator, modern);
    defer p.deinit();
}
test "owned nested parse cleans all allocation failure paths" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}
