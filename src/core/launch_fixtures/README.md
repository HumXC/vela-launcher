# Retained authentic launch metadata

These offline regression inputs preserve the full upstream version documents. Tests parse them, resolve inheritance, assemble installation plans, and call `launch.build`; they do not only check JSON shape. The Forge 1.7.10 installer profile retains its original `versionInfo` object, which the launch test extracts without altering its arguments.

| Fixture | Upstream source |
| --- | --- |
| vanilla_1_7_10_version.json | https://piston-meta.mojang.com/v1/packages/ed5d8789ed29872ea2ef1c348302b0c55e3f3468/1.7.10.json |
| vanilla_1_12_2_version.json | https://piston-meta.mojang.com/v1/packages/832d95b9f40699d4961394dcf6cf549e65f15dc5/1.12.2.json |
| vanilla_1_20_1_version.json | https://piston-meta.mojang.com/v1/packages/760a390e336b2b6202ec5906757cee3a929a7c85/1.20.1.json |
| vanilla_1_21_1_version.json | https://piston-meta.mojang.com/v1/packages/cedfc3b6dcbca34e2b478d498bf1d56a8fa2f404/1.21.1.json |
| fabric_1_20_1_version.json | https://meta.fabricmc.net/v2/versions/loader/1.20.1/0.16.0/profile/json |
| quilt_1_20_1_version.json | https://meta.quiltmc.org/v3/versions/loader/1.20.1/0.26.3/profile/json |
| forge_1_7_10_install_profile.json | Forge 10.13.4.1614 installer, embedded install_profile.json |
| forge_1_12_2_version.json | Forge 14.23.5.2860 installer, embedded version.json |
| neoforge_1_21_1_version.json | NeoForge 21.1.1 installer, embedded version.json |

The modern Forge 47.2.0 launch regression also uses the already retained authentic `../minecraft/loaders_fixtures/forge_1_20_1_version.json` from its installer.

Runtime contract: `Options.root` is the shared Minecraft directory. `${library_directory}` expands to `<root>/libraries`. Forge generated client/SRG/extra runtime artifacts must already have been published at the canonical Maven paths used by its launch handler; their publication belongs to processor execution. They are discovered via `LibraryFinder` and need no extra metadata classpath entries. The launch builder receives the installation plan and does not execute installers or processors.

The old Forge installer owns its universal jar, whose launch metadata download URL can be empty. That regression supplies its published path plus LaunchWrapper to the runtime plan while keeping the authentic metadata unchanged.
