{
  lib,
  stdenv,
  fetchurl,
  callPackage,
}:
let
  runtime = callPackage ./runtime.nix { };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "vela-bin";
  version = "0.1.0";

  src = fetchurl {
    url = "https://github.com/HumXC/vela-launcher/releases/download/v${finalAttrs.version}/vela-v${finalAttrs.version}-linux-x86_64.tar.gz";
    hash = "sha256-k8D/ey1aY0uNiWhlAXuv+wEWnr8WT3yBjXkoHkG7FDs=";
  };

  nativeBuildInputs = runtime.nativeBuildInputs;
  buildInputs = runtime.libraries;
  strictDeps = true;
  dontConfigure = true;
  dontBuild = true;
  installPhase = runtime.install "vela";

  # Keep the published ELF intact; the wrapper supplies its loader and libraries.
  dontPatchELF = true;
  dontStrip = true;

  meta = {
    description = "Minecraft launcher built with Zig and DVUI (official binary)";
    homepage = "https://github.com/HumXC/vela-launcher";
    mainProgram = "vela";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
