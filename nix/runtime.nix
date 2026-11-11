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
  libraries = lib.optionals stdenv.hostPlatform.isLinux [
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
  install =
    executable: version:
    if stdenv.hostPlatform.isDarwin then
      ''
        runHook preInstall
        install -Dm755 "${executable}" "$out/libexec/vela"
        app="$out/Applications/Vela.app"
        mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$out/bin"
        makeWrapper "$out/libexec/vela" "$app/Contents/MacOS/vela" \
          --add-flags '--default-data-dir "''${XDG_DATA_HOME:-$HOME/Library/Application Support}/vela"'
        ln -s "$app/Contents/MacOS/vela" "$out/bin/vela"
        cat > "$app/Contents/Info.plist" <<EOF
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleExecutable</key><string>vela</string>
          <key>CFBundleIdentifier</key><string>io.github.HumXC.vela-launcher</string>
          <key>CFBundleName</key><string>Vela Launcher</string>
          <key>CFBundlePackageType</key><string>APPL</string>
          <key>CFBundleShortVersionString</key><string>${version}</string>
          <key>CFBundleVersion</key><string>${version}</string>
          <key>NSHighResolutionCapable</key><true/>
        </dict></plist>
        EOF
        runHook postInstall
      ''
    else
      ''
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
