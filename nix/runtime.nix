{
  lib,
  stdenv,
  makeWrapper,
  makeDesktopItem,
  alsa-lib,
  dbus,
  libdecor,
  libusb1,
  libxkbcommon,
  wayland,
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
  libraries = [
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
{
  inherit libraries;
  nativeBuildInputs = [ makeWrapper ];
  install = executable: ''
    runHook preInstall
    install -Dm755 "${executable}" "$out/libexec/vela"
    mkdir -p "$out/bin"
    # Scope library lookup to this process without rewriting Zig ELF metadata.
    makeWrapper ${stdenv.cc.bintools.dynamicLinker} "$out/bin/vela" \
      --add-flags "--library-path ${lib.makeLibraryPath libraries} $out/libexec/vela" \
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
}
