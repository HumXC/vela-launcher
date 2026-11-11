{
  mkShellNoCC,
  zig,
  zls,
  dependency-generator,
  pkg-config,
  python3,
  wayland,
  dbus,
  zenity,
  libglvnd,
  lib,
  stdenv,
  vulkan-loader,
  libdecor,
  libusb1,
  alsa-lib,
  udev,
  libxkbcommon,
  zulu21,
  zulu25,
  wayland-scanner,
  glslang,
  writeShellScriptBin,
  apple-sdk,
  pkgsStatic,
}:
let
  # Zig 0.17 crashes when linking the Nix Apple iconv dylib; its static build works.
  libiconv = pkgsStatic.libiconv;
  # 去除 zig 输出的 "failed command" 信息
  wrap-zig = writeShellScriptBin "zig" ''
    if [ "$#" -eq 0 ]; then
      exec ${zig}/bin/zig
    fi

    cmd="$1"
    shift

    case "$cmd" in
      ${lib.optionalString stdenv.hostPlatform.isDarwin ''
        build)
          exec ${zig}/bin/zig build -Dmacos-sdk=${apple-sdk.sdkroot} \
            --search-prefix ${lib.getLib libiconv} --search-prefix ${lib.getDev libiconv} "$@"
          ;;
      ''}
      build|build-exe|build-lib|build-obj|test|run|translate-c)
        exec ${zig}/bin/zig "$cmd" --color on "$@" \
          2> >(sed '/failed command:/d' >&2)
        ;;
      *)
        exec ${zig}/bin/zig "$cmd" "$@" \
          2> >(sed '/failed command:/d' >&2)
        ;;
    esac
  '';

  generate-nix-deps = writeShellScriptBin "generate-nix-deps" ''
    set -euo pipefail
    tmp=$(mktemp ./deps.nix.XXXXXXXX)
    trap 'rm -f -- "$tmp"' EXIT
    ${dependency-generator}/bin/zon2nix > "$tmp"
    mv -- "$tmp" deps.nix
  '';
in
mkShellNoCC (
  {
    packages = [
      wrap-zig
      zig
      zls
      pkg-config
      python3
      zulu21
      zulu25
      generate-nix-deps
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      wayland-scanner
      wayland
      glslang
      libxkbcommon
      zenity
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      apple-sdk
      libiconv
    ];
    shellHook = ''
      export PATH="$PWD/zig-out/bin:$PATH"
    '';
  }
  // lib.optionalAttrs stdenv.hostPlatform.isLinux {
    LD_LIBRARY_PATH = lib.makeLibraryPath [
      stdenv.cc.cc.lib
      alsa-lib
      dbus
      libdecor
      libusb1
      libxkbcommon
      vulkan-loader
      wayland
      udev
      libglvnd
    ];
  }
  // lib.optionalAttrs stdenv.hostPlatform.isDarwin {
    SDKROOT = apple-sdk.sdkroot;
  }
)
