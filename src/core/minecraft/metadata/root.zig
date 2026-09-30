//! Independent owned Minecraft metadata. No network, downloader or UI dependencies.

/// Official version manifest. Version document URLs come from its entries;
/// asset index URLs come from each version document.
pub const version_manifest_url = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

pub const manifest = @import("manifest.zig");
pub const version = @import("version.zig");
pub const asset_index = @import("asset_index.zig");
pub const rules = @import("rules.zig");
pub const Owned = @import("owned.zig").Owned;
pub const Sha1 = @import("json.zig").Sha1;
test {
    _ = @import("tests.zig");
    _ = rules;
}
