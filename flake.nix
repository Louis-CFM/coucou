{
  description = "Coucou — Mochi lives at the top of your screen and keeps an eye on your Claude Code sessions";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      # The name, Mochi and the sounds are not free to redistribute
      # (LICENSE-ASSETS.md), so the package is marked unfree; building it for
      # yourself is allowed, and only this package is let through here.
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "coucou";
            }
          )
        );
    in
    {
      packages = forAllSystems (pkgs: rec {
        coucou = pkgs.callPackage ./linux/nix/package.nix { };
        default = coucou;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.coucou}/bin/coucou";
        };
      });

      # nix develop: what `npm run tauri dev` needs (windows/README.md).
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.system}.coucou ];
          packages = [
            pkgs.cargo
            pkgs.rustc
            pkgs.rust-analyzer
            pkgs.clippy
            pkgs.nodejs
          ];
          shellHook = ''
            export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules"
            export LD_LIBRARY_PATH="${
              pkgs.lib.makeLibraryPath [
                pkgs.libayatana-appindicator
                pkgs.gtk-layer-shell
                pkgs.webkitgtk_4_1
                pkgs.gtk3
              ]
            }''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            export XDG_DATA_DIRS="${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
