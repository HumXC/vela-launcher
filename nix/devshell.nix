{
  mkShellNoCC,
  zig,
  zls,
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
}: let
  # 去除 zig 输出的 "failed command" 信息
  wrap-zig = writeShellScriptBin "zig" ''
    if [ "$#" -eq 0 ]; then
      exec ${zig}/bin/zig
    fi

    cmd="$1"
    shift

    case "$cmd" in
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
    nix run github:nix-community/zon2nix > "$tmp"
    mv -- "$tmp" deps.nix
  '';
in
  mkShellNoCC {
    packages = [
      wrap-zig
      zig
      zls
      pkg-config
      python3
      zulu21
      zulu25
      wayland-scanner
      wayland
      glslang
      libxkbcommon
      zenity
      generate-nix-deps
    ];
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
    shellHook = ''
      export PATH="$PWD/zig-out/bin:$PATH"
    '';
  }
