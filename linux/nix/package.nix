# Coucou for NixOS and Nix — built from the Tauri app in windows/, which runs on
# Windows and Linux alike. Use it through the flake at the root of the repo:
#   nix run github:Louis-CFM/coucou
{
  lib,
  stdenv,
  rustPlatform,
  fetchNpmDeps,
  npmHooks,
  nodejs,
  cargo-tauri,
  pkg-config,
  wrapGAppsHook3,
  openssl,
  dbus,
  glib-networking,
  webkitgtk_4_1,
  gtk3,
  gtk-layer-shell,
  libayatana-appindicator,
  librsvg,
  gst_all_1,
  xdg-utils,
}:

let
  root = ../..;
  triple = stdenv.hostPlatform.rust.rustcTargetSpec;
  cargoToml = lib.importTOML (root + "/windows/Cargo.toml");
in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "coucou";
  version = cargoToml.workspace.package.version;

  # The sounds live in the macOS tree (windows/vite.config.ts), so the source is
  # the repo, cut down to what this build reads.
  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/windows")
      (root + "/NotchBuddy/Resources/sounds")
      (root + "/linux/arch/coucou.desktop")
      (root + "/LICENSE")
      (root + "/LICENSE-ASSETS.md")
    ];
  };

  cargoRoot = "windows";
  buildAndTestSubdir = finalAttrs.cargoRoot;
  cargoLock.lockFile = root + "/windows/Cargo.lock";

  npmRoot = "windows";
  # Update the hash when windows/package-lock.json changes (Nix prints the new one).
  npmDeps = fetchNpmDeps {
    name = "${finalAttrs.pname}-${finalAttrs.version}-npm-deps";
    src = "${finalAttrs.src}/windows";
    hash = "sha256-V1XF0g+jjNWX/iqkCSaieVHDk5jcntIut0jqBBRWMDk=";
  };

  nativeBuildInputs = [
    cargo-tauri.hook
    nodejs
    npmHooks.npmConfigHook
    pkg-config
    wrapGAppsHook3
  ];

  buildInputs = [
    openssl
    dbus
    glib-networking # TLS for WebKit
    webkitgtk_4_1
    gtk3
    gtk-layer-shell # the island sits on the top edge on Hyprland, Sway, KDE, COSMIC
    libayatana-appindicator
    librsvg
    # Mochi's sounds are WAV files: wavparse is in -good.
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
  ];

  # The packages are not wanted here, only the binary.
  tauriBuildFlags = [ "--no-bundle" ];

  # npm's prebuild script builds coucou-hook for the target triple, but
  # tauri.conf.json looks for it in windows/target/release.
  postPatch = ''
    mkdir -p target/${triple}/release windows/target
    ln -s "$PWD/target/${triple}/release" windows/target/release
  '';

  # The tests of the whole workspace run in the Linux workflow.
  doCheck = false;

  # The app copies coucou-hook from next to its own executable into
  # ~/.local/share/coucou/bin, where the agents' configs point.
  installPhase = ''
    runHook preInstall
    install -Dm755 target/${triple}/release/coucou $out/bin/coucou
    install -Dm755 target/${triple}/release/coucou-hook $out/bin/coucou-hook
    install -Dm644 linux/arch/coucou.desktop $out/share/applications/coucou.desktop
    install -Dm644 windows/src-tauri/icons/32x32.png $out/share/icons/hicolor/32x32/apps/coucou.png
    install -Dm644 windows/src-tauri/icons/128x128.png $out/share/icons/hicolor/128x128/apps/coucou.png
    install -Dm644 windows/src-tauri/icons/128x128@2x.png $out/share/icons/hicolor/256x256/apps/coucou.png
    runHook postInstall
  '';

  # The tray icon library opens libayatana-appindicator at run time; xdg-open
  # opens links and folders.
  preFixup = ''
    gappsWrapperArgs+=(
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ libayatana-appindicator ]}
      --prefix PATH : ${lib.makeBinPath [ xdg-utils ]}
    )
  '';

  meta = {
    description = "Mochi lives at the top of your screen and keeps an eye on your Claude Code sessions";
    homepage = "https://github.com/Louis-CFM/coucou";
    license = [
      lib.licenses.mit
      {
        shortName = "coucou-assets";
        fullName = "Coucou assets license (LICENSE-ASSETS.md)";
        free = false;
      }
    ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "coucou";
  };
})
