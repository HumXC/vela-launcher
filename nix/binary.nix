{
  lib,
  stdenv,
  fetchurl,
  callPackage,
}:
let
  runtime = callPackage ./runtime.nix { };
  version = "0.1.1";
  releases = {
    x86_64-linux = {
      platform = "linux";
      arch = "x86_64";
      hash = "sha256-vJ7aGum+6JVYkHr1HOy+CSviTw1ThU7fuVW8fd8qg2o=";
    };
    aarch64-linux = {
      platform = "linux";
      arch = "aarch64";
      hash = "sha256-xYRZWY4g4s4vEL7muL4IfyX48d8LK5dbUVoKKQRr7A4=";
    };
    x86_64-darwin = {
      platform = "macos";
      arch = "x86_64";
      hash = "sha256-z9g1JLwE1sKFaX7Xk1zD6zes3tgENnMYKIB9620wW5k=";
    };
    aarch64-darwin = {
      platform = "macos";
      arch = "aarch64";
      hash = "sha256-P/4PFryLMOmVAZo8djL4m+YDsaONzBdJ+RP90scx24M=";
    };
  };
  release = releases.${stdenv.hostPlatform.system};
in
stdenv.mkDerivation {
  pname = "vela-bin";
  inherit version;
  src = fetchurl {
    url = "https://github.com/HumXC/vela-launcher/releases/download/v${version}/vela-v${version}-${release.platform}-${release.arch}.tar.gz";
    inherit (release) hash;
  };
  nativeBuildInputs = runtime.nativeBuildInputs;
  buildInputs = runtime.libraries;
  strictDeps = true;
  dontConfigure = true;
  dontBuild = true;
  installPhase = runtime.install (
    if stdenv.hostPlatform.isDarwin then "Vela.app/Contents/MacOS/vela" else "vela"
  ) version;
  # Preserve the published executable, including its native Mach-O signature.
  dontPatchELF = true;
  dontStrip = true;
  meta = {
    description = "Minecraft launcher built with Zig and DVUI (official binary)";
    homepage = "https://github.com/HumXC/vela-launcher";
    mainProgram = "vela";
    platforms = builtins.attrNames releases;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
