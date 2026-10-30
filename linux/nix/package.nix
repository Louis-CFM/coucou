# Maintainer: Dorian Luyet (@DurianTheWAV)
#
# Coucou for Linux: the Tauri 2 app in windows/ (Rust + TypeScript), built from source.
# Exposed by the flake at the root of the repo (flake.nix); see "NixOS" in README.md.
#
# Nothing here needs touching for a release: the version is read from windows/Cargo.toml,
# the crates from windows/Cargo.lock and the npm packages from windows/package-lock.json.
# The only hashes are sherpa-onnx's below, which change when Cargo.lock moves to a new
# sherpa-onnx-sys version.
{
  lib,
  stdenv,
  fetchzip,
  rustPlatform,
  cargo,
  rustc,
  cargo-tauri,
  importNpmLock,
  nodejs,
  pkg-config,
  wrapGAppsHook3,
  alsa-lib,
  bzip2,
  dbus,
  glib,
  glib-networking,
  gst_all_1,
  gtk3,
  gtk-layer-shell,
  libayatana-appindicator,
  librsvg,
  webkitgtk_4_1,
  xdg-utils,
  xz,
  zstd,
}:

let
  sherpaOnnxSys =
    lib.findFirst (p: p.name == "sherpa-onnx-sys")
      (throw "coucou: sherpa-onnx-sys is missing from windows/Cargo.lock")
      (lib.importTOML ../../windows/Cargo.lock).package;
  sherpaOnnxVersion = sherpaOnnxSys.version;

  # sherpa-onnx-sys downloads its static libraries (sherpa-onnx + onnxruntime) from
  # GitHub at build time, which the Nix sandbox forbids. Fetch the same archive here
  # and hand it over with SHERPA_ONNX_LIB_DIR. After a sherpa-onnx-sys bump the URL
  # follows Cargo.lock and the build stops on a hash mismatch: copy the new hashes in.
  sherpaOnnxArchives = {
    x86_64-linux = {
      arch = "x64";
      hash = "sha256-WLP1eIW3GIIVSDK4g4xi7AfF0Spg9z92cVLmLU6SXw4=";
    };
    aarch64-linux = {
      arch = "aarch64";
      hash = "sha256-Yez0bmpbNktkMqJpMInFOoHX1kAuwCY8cFl3JcKo4xE=";
    };
  };

  sherpaOnnxArchive =
    sherpaOnnxArchives.${stdenv.hostPlatform.system}
      or (throw "coucou: no sherpa-onnx build for ${stdenv.hostPlatform.system}");

  sherpaOnnxStatic = fetchzip {
    url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${sherpaOnnxVersion}/sherpa-onnx-v${sherpaOnnxVersion}-linux-${sherpaOnnxArchive.arch}-static-lib.tar.bz2";
    inherit (sherpaOnnxArchive) hash;
  };

  # The Tauri app without local build output, plus the sounds its Vite build copies
  # from the Mac app. The rest of the repo (the Mac app, Android, docs…) does not
  # trigger rebuilds.
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      (lib.fileset.difference ../../windows (
        lib.fileset.unions (
          map lib.fileset.maybeMissing [
            ../../windows/dist
            ../../windows/node_modules
            ../../windows/release
            ../../windows/src-tauri/gen
            ../../windows/target
          ]
        )
      ))
      ../../NotchBuddy/Resources/sounds
    ];
  };
in
stdenv.mkDerivation {
  pname = "coucou";
  version = (lib.importTOML ../../windows/Cargo.toml).workspace.package.version;

  inherit src;
  sourceRoot = "${src.name}/windows";

  # Both read straight from the lock files: no hash to update on each release.
  cargoDeps = rustPlatform.importCargoLock { lockFile = ../../windows/Cargo.lock; };
  npmDeps = importNpmLock {
    package = lib.importJSON ../../windows/package.json;
    packageLock = lib.importJSON ../../windows/package-lock.json;
  };

  # cargo-tauri.hook runs `cargo tauri build --bundles deb` from here, and the deb's
  # contents become $out. `npm run build` (Tauri's beforeBuildCommand) builds the
  # front end and coucou-hook, which the bundle picks up from target/release.
  buildAndTestSubdir = "src-tauri";

  env.SHERPA_ONNX_LIB_DIR = "${sherpaOnnxStatic}/lib";

  # nixpkgs builds with CARGO_BUILD_TARGET set, so npm's prebuild puts coucou-hook in
  # target/<triple>/release, while tauri.linux.conf.json expects target/release.
  preBuild = ''
    mkdir -p target/release
    ln -s ../${stdenv.hostPlatform.rust.cargoShortTarget}/release/coucou-hook target/release/coucou-hook
  '';

  postPatch = ''
    # The tray icon loads libayatana-appindicator with dlopen: give it the full path.
    substituteInPlace "$cargoDepsCopy"/libappindicator-sys-*/src/lib.rs \
      --replace-fail "libayatana-appindicator3.so.1" \
        "${libayatana-appindicator}/lib/libayatana-appindicator3.so.1"

    # "Start at login" (~/.config/autostart/Coucou.desktop) and the command Settings
    # shows for desktop shortcuts would record this build's own executable,
    # /nix/store/…/bin/.coucou-wrapped: it skips the wrapper (GTK, GStreamer and TLS
    # modules) and is gone after the next garbage collection. Use `coucou` from PATH.
    substituteInPlace "$cargoDepsCopy"/tauri-plugin-autostart-*/src/lib.rs \
      --replace-fail "let current_exe = current_exe()?;" \
        'let current_exe = std::path::PathBuf::from("coucou");'
    substituteInPlace src-tauri/src/shortcuts.rs \
      --replace-fail ".or_else(|| std::env::current_exe().ok())" ""
  '';

  nativeBuildInputs = [
    cargo
    cargo-tauri.hook
    importNpmLock.npmConfigHook
    nodejs
    pkg-config
    rustc
    rustPlatform.cargoSetupHook
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    bzip2
    dbus
    glib-networking
    gst_all_1.gst-plugins-base # Mochi's sounds, played by WebKit
    gst_all_1.gst-plugins-good
    gtk-layer-shell
    gtk3
    libayatana-appindicator
    librsvg
    webkitgtk_4_1
    xz
    zstd
  ];

  postInstall = ''
    # Tauri files its 128x128@2x icon (256 px) under 256x256@2, which means 512 px.
    if [ -d $out/share/icons/hicolor/256x256@2 ]; then
      mv $out/share/icons/hicolor/256x256@2 $out/share/icons/hicolor/256x256
    fi
  '';

  preFixup = ''
    gappsWrapperArgs+=(
      # xdg-open (links, files), gsettings (theme), gtk-launch (« OK Coucou » opens apps).
      --suffix PATH : ${
        lib.makeBinPath [
          glib
          gtk3
          xdg-utils
        ]
      }
    )
  '';

  # For the flake's dev shell.
  passthru = { inherit sherpaOnnxStatic; };

  # Coucou copies the relay from $out/lib/Coucou/coucou-hook to
  # ~/.local/share/coucou/bin/ at each launch, so Claude Code's hooks keep a stable
  # path across updates rather than pointing into the Nix store.

  meta = {
    description = "Mochi lives at the top of your screen and keeps an eye on your AI coding agents";
    longDescription = ''
      Coucou shows your Claude Code, Codex, Cursor, Gemini CLI and other agent sessions
      at the top of the screen, and lets you approve, answer, chat and drop files without
      leaving what you are doing. Also: Flow dictation with Parakeet offline, and a
      notetaker for your calls.
    '';
    homepage = "https://github.com/Louis-CFM/coucou";
    changelog = "https://github.com/Louis-CFM/coucou/blob/main/CHANGELOG.md";
    # The code is MIT. The name, Mochi, the icon and the sounds are © Louis Raillé
    # (LICENSE-ASSETS.md): building and running it for yourself is allowed,
    # redistributing binaries is not without written permission. Hence `unfree`,
    # which also keeps it out of public binary caches.
    license = with lib.licenses; [
      mit
      unfree
    ];
    # Same fields as nixpkgs' maintainers/maintainer-list.nix.
    maintainers = [
      {
        name = "Dorian Luyet";
        github = "DurianTheWAV";
        githubId = 151391647;
      }
    ];
    mainProgram = "coucou";
    platforms = lib.attrNames sherpaOnnxArchives;
  };
}
