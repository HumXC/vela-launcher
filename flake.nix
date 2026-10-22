{
  description = "Vela Launcher — Zig and DVUI SDL3 development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay/f0acd78ef01f2d5e3471cc01b08022ab4e665898";
    zls-overlay.url = "github:zigtools/zls/eab2be0fd74443a27662da809b771c4ad0d2afcf";
  };

  outputs = {
    self,
    nixpkgs,
    zig-overlay,
    zls-overlay,
    ...
  }: let
    forAllSystems = nixpkgs.lib.genAttrs [
      "aarch64-linux"
      "x86_64-linux"
    ];
  in {
    devShells = forAllSystems (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.17.0";
        zls = zls-overlay.packages.${system}.zls;
      in {
        default = pkgs.callPackage ./nix/devshell.nix {inherit zig zls;};
      }
    );
  };
}
