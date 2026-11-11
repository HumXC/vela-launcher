{
  lib,
  stdenv,
  zig,
  callPackage,
  fetchgit,
  linkFarm,
  pkg-config,
  wayland-scanner,
  glslang,
}:
let
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../ui_layout_test_build.zig
      ../build-support
      ../src
      ../scripts
    ];
  };
  deps = callPackage ../deps.nix {
    # Keep disabled backends out of Zig's eager cached-package scan.
    # These optional packages still use pre-0.17 build APIs or hashes.
    linkFarm =
      name: entries:
      linkFarm name (
        builtins.filter (
          entry:
          !(builtins.elem entry.name [
            "tree_sitter-0.25.0-8heIf51vAQConvVIgvm-9mVIbqh7yabZYqPXfOpS3YoG"
            "pugl-0.1.0-CUvtTqRjAQAQ2sX-zW39HvOnN8MLoyJQneShRiBG8F4n"
          ])
        ) entries
      );
    # Match zon2nix's prefetch semantics with current nixpkgs fetchgit.
    fetchgit =
      args:
      fetchgit (
        builtins.removeAttrs args [ "ref" ]
        // lib.optionalAttrs (args ? ref) { tag = args.ref; }
        // {
          url = builtins.head (lib.splitString "?" args.url);
          fetchSubmodules = false;
        }
      );
  };
  runtime = callPackage ./runtime.nix { };
in
stdenv.mkDerivation {
  pname = "vela";
  inherit version src;
  nativeBuildInputs = [
    zig
    pkg-config
    wayland-scanner
    glslang
  ]
  ++ runtime.nativeBuildInputs;
  buildInputs = runtime.libraries;
  dontConfigure = true;
  strictDeps = true;
  # Zig owns C compilation and optimization flags.
  dontUseZigBuild = true;
  dontUseZigInstall = true;

  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    export ZIG_LOCAL_PKG_DIR=${deps}
    # Keep bundled-library defaults; the Nix sandbox provides offline isolation.
    zig build compile-app \
      -Doptimize=ReleaseSmall -Dcpu=baseline -j2 --prefix "$TMPDIR/vela-install"
    runHook postBuild
  '';

  installPhase = runtime.install "$TMPDIR/vela-install/bin/vela";

  # Preserve the Zig-linked ELF; the wrapper supplies its loader and libraries.
  dontPatchELF = true;
  dontStrip = true;
  passthru = { inherit deps; };
  meta = {
    description = "Minecraft launcher built with Zig and DVUI";
    homepage = "https://github.com/HumXC/vela-launcher";
    mainProgram = "vela";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
