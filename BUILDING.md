# Building and testing

Use Zig 0.17.0 (the manifest minimum), a C toolchain and the platform libraries required by SDL3. Python 3 is needed for managed local fixtures; override its executable with `-Dpython=/absolute/path/to/python3`. The source-package verifier requires Python 3.12 or newer for safe tar extraction. Dependency downloads require network access on a cold package cache. Test fixtures use loopback servers and temporary directories, not public Minecraft services. Nix environment configuration is outside this build change.

## Commands

```sh
zig build compile-app -j2
zig build test-unit -j2
zig build test-ui -j2
zig build test-workflows -j2
zig build test-integration -j2
zig build test-all -j2
```

| Target | Coverage |
| --- | --- |
| `test-unit` | Allocation checks, foundation, parsers, worlds, metadata, filesystem and picker tests |
| `test-ui` | Testing-renderer layouts, preview state, resource pages and UI workflows; native DVUI test roots use dummy SDL video and software rendering |
| `test-workflows` | Application state, Java lifecycle, installation, credentials, pack authorization and transaction ownership |
| `test-integration` | Managed downloader, HTTP, public-address guard, archive and Minecraft module fixtures |
| `test` | All four local suites above |
| `check-platforms` | Existing Windows durable-filesystem and supported installation API compile checks; not native execution on those platforms |
| `test-all` | `test`, `compile-app` and `check-platforms` |
| `test-graphics` | Separate OpenGL and software pixel regressions; requires working native graphics drivers |

Individual targets remain available through `zig build --help`. Narrow a relevant target with `-Dtest-filter=...`, `-Dmods-test-filter=...`, `-Dlayout-test-filter=...` or `-Dgui-test-filter=...`. A filtered run is not full-suite validation. Native Java/loader acceptance and interactive GUI acceptance remain explicit environment-dependent commands; they are not implied by `test-all`. The historical `scripts/test-minecraft.py` CLI acceptance expects HTTP metadata that current production URL policy rejects; use the managed Minecraft module fixture target for automated regression coverage.

The build graph compiles test executables once. Python fixture runners accept `--test-exe PATH`, start their servers, run that executable and clean up. They do not invoke nested builds in this mode. Network fixture run steps always execute even when compilation is cached. The raw `test-downloader` and `test-http-transport` targets remain useful with caller-supplied fixture environment variables; use the `-fixture` targets to own the full lifecycle. Guard tests check both forbidden socket contacts and forbidden requests after connection reuse. Unsupported IPv6 and platform-specific tests may skip and are reported by the runners.

## Dependency policy

Direct dependencies are pinned by immutable version/commit URLs and Zig content hashes in `build.zig.zon`. Update the URL and hash together; do not replace these with branch URLs or remove hash validation. Review upstream changes, local patches and platform compile checks on every update. No dependency versions were changed for this build refactor.

`build-support/dependencies.zig` owns shared curl vendor/TLS-thread settings, NBT/compression, Linux bindings and fresh application-root construction. Root modules own their import/link/configuration containers; only dependency module handles are shared. Tests and previews must not mutate production roots. Configuration-time assertions enforce that their private imports do not leak.

Local compatibility patches live in `build-support`: DVUI backdrop/rendering adjustments, SDL software renderer changes, WebP decoding integration, Windows C-translation fortify settings and macOS SDK compatibility. The DVUI/SDL patchers check expected source text and write generated files into the build cache instead of modifying downloaded packages. A dependency update that changes expected text must be reviewed, not made to silently ignore patch failures. Remove each workaround only when its upstream equivalent is present and the corresponding UI/pixel or platform regression passes.

Production DVUI builds disable Tree-sitter and embed no fonts. The pinned DVUI patch removes Adwaita font collections and resolves the final fallback to the first validated system font registered by Vela. Startup requires automatic system font discovery (including `fc-match` on Linux) or a valid font file selected by `VELA_FONT_PATH`; missing or invalid fonts produce an initialization error. Native pixel fixtures load system fonts through the same installer.

`build-support/freetype.zig` trims the bundled FreeType driver sources and generates a matching module registry. It removes Type 1, standalone CID Type 1, Type 42, PFR, BDF, PCF, Windows FNT and SDF renderers. TrueType/SFNT, CFF and its helpers, variable fonts, hinting, embedded bitmap strikes and the normal renderers remain enabled. Exact source/module checks fail on dependency drift; package sources stay immutable.

macOS requires an existing SDK supplied with `-Dmacos-sdk=/absolute/MacOSX.sdk`; SDK acquisition is separate. Platform compile checks do not prove native macOS/Windows linking or runtime behavior.

## Source packages

The manifest includes the root layout build entry, all build support, source files and an explicit fixture-script allowlist. `zig fetch .` applies this allowlist; an ordinary checkout build alone does not prove package completeness. Run `python3 scripts/check-source-package.py --cache-dir /tmp/vela-package-build-cache` to fetch the actual package, check required files and excluded local state, then configure it, compile the app and execute its archive fixtures. Pass `--pkg-dir PATH` for an existing dependency package directory; it defaults to the checkout’s `zig-pkg`. On macOS also pass `--macos-sdk /absolute/MacOSX.sdk`. The checker forwards its own Python interpreter to the fixture build steps. Build caches and installed outputs remain outside the fetched source tree. Do not include local caches, credentials or generated outputs in the allowlist.
