# Building and testing

Use Zig 0.17.0 (the manifest minimum), a C toolchain and the platform libraries required by SDL3. Python 3 is needed for managed local fixtures; override its executable with `-Dpython=/absolute/path/to/python3`. The source-package verifier requires Python 3.12 or newer for safe tar extraction. Dependency downloads require network access on a cold package cache. Test fixtures use loopback servers and temporary directories, not public Minecraft services.

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

## Nix packages

The locked flake exposes native packages and apps for x86_64-linux and
aarch64-linux. Nix must have the nix-command and flakes features enabled.

~~~sh
nix build .#vela             # also the default: nix build
nix run .#vela               # also the default: nix run
nix flake check              # build and isolated startup check for this system
nix develop                 # development shell and dependency generator
~~~

The result includes the launcher, a desktop entry, X11/Wayland runtime libraries,
libsecret, and the fontconfig/zenity/xdg-utils commands. The wrapper invokes the
Nix glibc loader with a process-local library search path, preserving the Zig ELF
without patchelf/strip rewriting. It does not set LD_LIBRARY_PATH for Java or
other child processes. The wrapper defaults data to
$XDG_DATA_HOME/vela, or ~/.local/share/vela when XDG_DATA_HOME is unset. An explicit
--data-dir takes precedence over VELA_DATA_DIR and this package default.

The package uses system fonts; install a suitable Chinese font through your
normal system configuration, or pass VELA_FONT_PATH pointing to a font file.
Persistent credentials require a running Secret Service provider. Graphics drivers
and desktop services belong to the host. A Nix package is a Nix store closure,
not a portable standalone executable: do not copy just result/bin/vela to another
machine. Java is not bundled, and downloaded upstream JDKs/game native libraries
may still need NixOS compatibility support; packaging the launcher alone does not
establish that every Minecraft version runs on NixOS. Configure a suitable Nix JDK
when needed. Nix on non-NixOS Linux may additionally require host driver integration.

deps.nix pins the complete Zig dependency closure with Nix content hashes.
nix/package.nix compiles in the Nix sandbox with a prefilled dependency cache, ReleaseSmall and baseline CPU
features, using the same pinned Zig 0.17.0 as the development shell. No local Zig
caches, docs, game data or credentials are included in the package source. The
flake excludes the unused Pugl backend and a legacy Tree-sitter wrapper from the
build cache because their manifests/build APIs are incompatible with Zig 0.17;
both remain in the generated lock.
After changing build.zig.zon, run nix develop --command generate-nix-deps to
regenerate deps.nix with the pinned zon2nix generator, review the dependency diff,
and run nix flake check. Downloads use Nix fetchers rather than Zig's HTTP client.
The Nix package version currently follows the source manifest's 0.1.0; Ubuntu's
manual release label does not rewrite it.

The Nix packages Actions workflow builds and checks both architectures on native
runners. The startup check runs the installed wrapper with dummy SDL video,
software rendering, an explicit fixture font and a temporary user data directory,
without development-shell library paths. It does not test real graphics drivers,
Microsoft login, Secret Service interaction or Minecraft launches. The workflow
validates packages; it does not upload a binary cache or a standalone Nix archive.

## GitHub Actions: Ubuntu CI and releases

The Ubuntu build and release workflow runs on pushes to main and pull requests.
It installs Zig 0.17.0 and Ubuntu dependencies, runs the local test suites, builds
Linux x86_64 with ReleaseSmall, baseline CPU features and a glibc 2.35 target,
and performs an isolated dummy-video/software-renderer smoke test. This is not
an interactive desktop or real Minecraft launch test.

To publish, first push the workflow to the repository's default branch. In GitHub,
open Actions → Ubuntu build and release → Run workflow, select the branch, and
enter a version such as 0.2.0, v0.2.0 or 0.2.0-rc.1. The workflow normalizes the
version to a v-prefixed tag and builds the exact selected commit. Existing tags
are rejected. The version labels the release, archive, VERSION and build-info.json;
it does not rewrite the source manifest or embed a new application UI version.

Only manual runs publish. Successful builds create a draft release with the
archive and SHA-256 checksum, then publish it; prerelease suffixes automatically
mark the release as a prerelease. A failure during upload/publication may leave a
draft: inspect it and delete that incomplete draft/tag before retrying the same
version. No existing release assets or tags are overwritten. Only the publishing
job receives contents: write; no personal access token is required. Repository
rules that prohibit tag creation or release writes must allow this workflow.

Assets are named vela-v<VERSION>-linux-x86_64.tar.gz and the matching .sha256.
PR and push runs upload the same format as temporary Actions artifacts, without
creating tags or releases. The archive contains a native executable, VERSION and
build-info.json; it is not an AppImage and does not bundle Java, desktop services
or graphics drivers. ELF inspection rejects a Nix loader/RPATH and glibc symbol
requirements newer than 2.35. Windows, macOS and ARM64 release jobs are not included
in this workflow.

On Ubuntu 22.04, install runtime dependencies with:

~~~sh
sudo apt-get install ca-certificates fontconfig fonts-dejavu-core zenity libsecret-1-0 libasound2 libdbus-1-3 libdecor-0-0 libusb-1.0-0 libxkbcommon0 libwayland-client0 libwayland-cursor0 libwayland-egl1 libudev1 libgl1 libegl1 libvulkan1 libx11-6 libxcursor1 libxi6 libxrandr2 libxfixes3 libxext6 libxrender1 libxss1
~~~

Extract the archive into a writable directory and run ./vela. Persistent credentials
require a running Secret Service provider, such as GNOME Keyring. Use your normal
graphics drivers and configure or download a suitable JDK in the launcher. Verify
the archive with sha256sum -c vela-v<VERSION>-linux-x86_64.tar.gz.sha256 before extraction.

To reproduce packaging in an Ubuntu 22.04 environment with the workflow's tools:

~~~sh
zig build compile-app -Doptimize=ReleaseSmall -Dtarget=x86_64-linux-gnu.2.35 -Dcpu=baseline -j2
strip --strip-unneeded zig-out/bin/vela
python3 scripts/package-linux.py 0.2.0
~~~

## Source packages

The manifest includes the root layout build entry, all build support, source files and an explicit fixture-script allowlist. `zig fetch .` applies this allowlist; an ordinary checkout build alone does not prove package completeness. Run `python3 scripts/check-source-package.py --cache-dir /tmp/vela-package-build-cache` to fetch the actual package, check required files and excluded local state, then configure it, compile the app and execute its archive fixtures. Pass `--pkg-dir PATH` for an existing dependency package directory; it defaults to the checkout’s `zig-pkg`. On macOS also pass `--macos-sdk /absolute/MacOSX.sdk`. The checker forwards its own Python interpreter to the fixture build steps. Build caches and installed outputs remain outside the fetched source tree. Do not include local caches, credentials or generated outputs in the allowlist.
