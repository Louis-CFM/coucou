{
  description = "Coucou — un petit compagnon en haut de l'écran pour tes agents de code (build Linux, Tauri 2)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      version = (builtins.fromJSON (builtins.readFile ./windows/package.json)).version;

      runtimeLibs = pkgs: with pkgs; [
        webkitgtk_4_1
        gtk3
        gtk-layer-shell
        libayatana-appindicator
        librsvg
        openssl
        dbus
        libsecret
        glib-networking
      ];
    in
    {
      packages = forAllSystems (pkgs: {
        coucou = pkgs.rustPlatform.buildRustPackage (finalAttrs: {
          pname = "coucou";
          inherit version;

          src = ./.;

          cargoLock = {
            lockFile = ./windows/Cargo.lock;
          };

          npmDeps = pkgs.fetchNpmDeps {
            name = "coucou-npm-deps-${finalAttrs.version}";
            src = ./windows;
            hash = "sha256-e5rjMRvBXzBDzpAbskKZ/TTra/zTSbc1kLhfLatTVGI=";
          };

          npmRoot = "windows";
          cargoRoot = "windows";
          buildAndTestSubdir = "windows/src-tauri";

          preBuild = ''
            (cd windows && cargo build --release --frozen -p coucou-hook)
          '';

          nativeBuildInputs = with pkgs; [
            cargo-tauri.hook
            nodejs
            npmHooks.npmConfigHook
            pkg-config
            wrapGAppsHook3
          ];

          buildInputs = runtimeLibs pkgs ++ (with pkgs; [
            gst_all_1.gstreamer
            gst_all_1.gst-plugins-base
            gst_all_1.gst-plugins-good
          ]);

          preFixup = ''
            gappsWrapperArgs+=(
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [
                pkgs.libayatana-appindicator
                pkgs.gtk-layer-shell
              ]}
            )
          '';

          doCheck = false;

          meta = {
            description = "Petit compagnon (Mochi) en haut de l'écran qui surveille tes agents de code";
            homepage = "https://github.com/Louis-CFM/coucou";
            license = pkgs.lib.licenses.mit; 
            platforms = systems;
            mainProgram = "coucou";
          };
        });

        default = self.packages.${pkgs.stdenv.hostPlatform.system}.coucou;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.coucou}/bin/coucou";
          meta = self.packages.${pkgs.stdenv.hostPlatform.system}.coucou.meta;
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            rustc
            cargo
            clippy
            rustfmt
            rust-analyzer
            nodejs_22
            cargo-tauri
            pkg-config
            patchelf
            gst_all_1.gstreamer
            gst_all_1.gst-plugins-base
            gst_all_1.gst-plugins-good
          ] ++ runtimeLibs pkgs;

          shellHook = ''
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (runtimeLibs pkgs)}:$LD_LIBRARY_PATH"
            export XDG_DATA_DIRS="${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:$XDG_DATA_DIRS"
            export GIO_MODULE_DIR="${pkgs.glib-networking}/lib/gio/modules/"
            echo "Coucou dev shell — cd windows && npm install && npm run tauri dev"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
