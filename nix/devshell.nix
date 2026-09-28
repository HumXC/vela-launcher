{
  mkShellNoCC,
  zig,
  zls,
  pkg-config,
  wayland,
  lib,
  vulkan-loader,
  libdecor,
  libusb1,
  alsa-lib,
  udev,
  libxkbcommon,
}:
mkShellNoCC {
  packages = [
    zig
    zls
    pkg-config
  ];
  LD_LIBRARY_PATH = lib.makeLibraryPath [
    alsa-lib
    libdecor
    libusb1
    libxkbcommon
    vulkan-loader
    wayland
    udev
  ];
  shellHook = ''
    export PATH="$PWD/zig-out/bin:$PATH"
  '';
}
