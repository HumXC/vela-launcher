{
  mkShellNoCC,
  zig,
  zls,
  pkg-config,
  wayland,
  libglvnd,
  lib,
  vulkan-loader,
  libdecor,
  libusb1,
  alsa-lib,
  udev,
  libxkbcommon,
  zulu21,
  zulu25,
}:
mkShellNoCC {
  packages = [
    zig
    zls
    pkg-config
    zulu21
    zulu25
  ];
  LD_LIBRARY_PATH = lib.makeLibraryPath [
    alsa-lib
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
