{
  description = "Vela Launcher — native Linux packages and development shells";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay/f0acd78ef01f2d5e3471cc01b08022ab4e665898";
    zls-overlay.url = "github:zigtools/zls/eab2be0fd74443a27662da809b771c4ad0d2afcf";
    zon2nix.url = "github:nix-community/zon2nix/d1e1762ce1e5d4df3b65a0d45421b6fb7b99cf92";
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-overlay,
      zls-overlay,
      zon2nix,
      ...
    }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "aarch64-linux"
        "x86_64-linux"
      ];
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          zig = zig-overlay.packages.${system}."0.17.0";
          vela = pkgs.callPackage ./nix/package.nix {
            inherit zig;
          };
        in
        {
          inherit vela;
          default = vela;
          dependency-generator = zon2nix.packages.${system}.default.overrideAttrs (old: {
            # Let Nix follow redirects, including when network access needs a proxy.
            postPatch = (old.postPatch or "") + ''
              substituteInPlace src/Dependency.zig \
                --replace-fail 'parseUrl(alloc, io, url, .{})' \
                  'parseUrl(alloc, io, url, .{ .resolveUrl = false })' \
                --replace-fail 'git+{s}?rev={s}' 'git+{s}?rev={s}&shallow=1'
            '';
          });
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          vela-bin = pkgs.callPackage ./nix/binary.nix { };
        }
      );
      apps = forAllSystems (
        system:
        {
          vela = {
            type = "app";
            program = "${self.packages.${system}.vela}/bin/vela";
            meta.description = "Vela Minecraft launcher";
          };
          default = self.apps.${system}.vela;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          vela-bin = {
            type = "app";
            program = "${self.packages.${system}.vela-bin}/bin/vela";
            meta.description = "Vela Minecraft launcher (official binary)";
          };
        }
      );
      checks = forAllSystems (
        system:
        {
          package = self.packages.${system}.vela;
          startup = nixpkgs.legacyPackages.${system}.callPackage ./nix/check.nix {
            vela = self.packages.${system}.vela;
          };
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          binary-package = self.packages.${system}.vela-bin;
          binary-startup = nixpkgs.legacyPackages.${system}.callPackage ./nix/check.nix {
            vela = self.packages.${system}.vela-bin;
          };
        }
      );
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          zig = zig-overlay.packages.${system}."0.17.0";
          zls = zls-overlay.packages.${system}.zls;
        in
        {
          default = pkgs.callPackage ./nix/devshell.nix {
            inherit zig zls;
            dependency-generator = self.packages.${system}.dependency-generator;
          };
        }
      );
    };
}
