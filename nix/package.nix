{
  lib,
  stdenv,
  zig,
  callPackage,
  fetchgit,
  linkFarm,
  makeWrapper,
  makeDesktopItem,
  pkg-config,
  wayland,
  wayland-scanner,
  glslang,
  alsa-lib,
  dbus,
  libdecor,
  libusb1,
  libxkbcommon,
  libglvnd,
  vulkan-loader,
  udev,
  libsecret,
  libx11,
  libxcursor,
  libxi,
  libxrandr,
  libxfixes,
  libxext,
  libxrender,
  libxscrnsaver,
  fontconfig,
  zenity,
  xdg-utils,
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
        builtins.filter
          (
            entry:
            !(builtins.elem entry.name [
              "tree_sitter-0.25.0-8heIf51vAQConvVIgvm-9mVIbqh7yabZYqPXfOpS3YoG"
              "pugl-0.1.0-CUvtTqRjAQAQ2sX-zW39HvOnN8MLoyJQneShRiBG8F4n"
            ])
          )
          (
            map (
              entry:
              if entry.name == "N-V-__8AAGkrewARcKiSyLfJKsaW0ZoqHh4hzi4mTGwekxjk" then
                entry
                // {
                  # fetchzip strips the directory expected by webp.zig.
                  path = linkFarm "webp-zig-layout" [
                    {
                      name = "libwebp-1.6.0";
                      path = entry.path;
                    }
                  ];
                }
              else
                entry
            ) entries
          )
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
  runtimeLibraries = [
    stdenv.cc.cc.lib
    stdenv.cc.libc
    alsa-lib
    dbus
    libdecor
    libusb1
    libxkbcommon
    wayland
    libglvnd
    vulkan-loader
    udev
    libsecret
    libx11
    libxcursor
    libxi
    libxrandr
    libxfixes
    libxext
    libxrender
    libxscrnsaver
  ];
  desktopItem = makeDesktopItem {
    name = "vela";
    desktopName = "Vela Launcher";
    comment = "Minecraft launcher";
    exec = "vela";
    terminal = false;
    categories = [ "Game" ];
    startupWMClass = "vela";
  };
in
stdenv.mkDerivation {
  pname = "vela";
  inherit version src;
  nativeBuildInputs = [
    zig
    makeWrapper
    pkg-config
    wayland-scanner
    glslang
  ];
  buildInputs = runtimeLibraries;
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

  installPhase = ''
    runHook preInstall
    install -Dm755 "$TMPDIR/vela-install/bin/vela" "$out/libexec/vela"
    mkdir -p "$out/bin"
    # Scope library lookup to this process without rewriting Zig ELF metadata.
    makeWrapper ${stdenv.cc.bintools.dynamicLinker} "$out/bin/vela" \
      --add-flags "--library-path ${lib.makeLibraryPath runtimeLibraries} $out/libexec/vela" \
      --prefix PATH : ${
        lib.makeBinPath [
          fontconfig
          zenity
          xdg-utils
        ]
      } \
      --add-flags '--default-data-dir "''${XDG_DATA_HOME:-$HOME/.local/share}/vela"'
    install -Dm644 ${desktopItem}/share/applications/vela.desktop \
      "$out/share/applications/vela.desktop"
    runHook postInstall
  '';

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
