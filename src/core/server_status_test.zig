const std = @import("std");
const model = @import("server_status.zig");
const a = std.testing.allocator;
test "MOTD retains styled translation tree and projects fallback arguments" {
    const json = "{\"version\":{\"name\":\"1.21\",\"protocol\":767},\"description\":{\"translate\":\"chat.type.text\",\"fallback\":\"<%1$s> %2$s %%\",\"with\":[{\"text\":\"§aAlex\",\"bold\":true},{\"text\":\"Hello 世界\",\"color\":\"red\"}],\"extra\":[{\"text\":\"!\"}]}}";
    var status = try model.parseStatus(a, json);
    defer status.deinit();
    try std.testing.expectEqualStrings("<Alex> Hello 世界 %!", status.motd);
    try std.testing.expect(status.motd_issue == null);
    const args = status.description.object.get("with").?.array.items;
    try std.testing.expect(args[0].object.get("bold").?.bool);
    try std.testing.expectEqualStrings("red", args[1].object.get("color").?.string);
    try std.testing.expectEqualStrings("chat.type.text", status.description.object.get("translate").?.string);
}
test "MOTD missing catalog preserves key and arguments without losing source" {
    var status = try model.parseStatus(a, "{\"version\":{\"name\":\"x\",\"protocol\":1},\"description\":{\"translate\":\"custom.key\",\"with\":[\"玩家\",4,true],\"extra\":[\"\\nReady\"]}}");
    defer status.deinit();
    try std.testing.expectEqualStrings("custom.key 玩家 4 true\nReady", status.motd);
    try std.testing.expect(status.latency_ms == null);
}
test "optional malformed MOTD and icon preserve core status" {
    for ([_][]const u8{ "{\"version\":{\"name\":\"x\",\"protocol\":1},\"players\":{\"online\":3,\"max\":20},\"description\":false,\"favicon\":42}", "{\"version\":{\"name\":\"x\",\"protocol\":1},\"players\":{\"online\":3,\"max\":20},\"description\":{\"extra\":1},\"favicon\":\"bad\"}" }) |json| {
        var status = try model.parseStatus(a, json);
        defer status.deinit();
        try std.testing.expect(status.motd_issue != null);
        try std.testing.expect(status.icon_issue != null);
        try std.testing.expect(status.icon == null);
        try std.testing.expectEqualStrings("", status.motd);
        try std.testing.expectEqual(@as(?u32, 3), status.players_online);
        try std.testing.expectEqual(@as(?u32, 20), status.players_max);
    }
    try std.testing.expectError(error.InvalidJson, model.parseStatus(a, &.{255}));
}
fn textAllocation(allocator: std.mem.Allocator) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"translate\":\"key\",\"with\":[123,true],\"extra\":[{\"text\":\"child\"}]}", .{});
    defer parsed.deinit();
    const text = try model.plainText(allocator, parsed.value);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("key 123 truechild", text);
}
test "plain MOTD conversion releases standalone and failed allocations" {
    try std.testing.checkAllAllocationFailures(a, textAllocation, .{});
}
