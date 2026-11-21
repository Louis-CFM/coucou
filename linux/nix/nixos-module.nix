# Maintainer: Dorian Luyet (@DurianTheWAV)
#
# NixOS module, exposed by the flake as nixosModules.default:
#
#   programs.coucou.enable = true;            # installs Coucou
#   programs.coucou.desktopShortcut = true;   # and puts its launcher on the desktop
#
# The package comes from the flake itself, so no unfree setting is needed on your side.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.coucou;
in
{
  options.programs.coucou = {
    enable = lib.mkEnableOption "Coucou, Mochi at the top of your screen watching your AI coding agents";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "coucou.packages.\${pkgs.stdenv.hostPlatform.system}.default";
      description = ''
        The Coucou package. The default is built by Coucou's flake, which allows its
        unfree artwork for this package only.
      '';
    };

    desktopShortcut = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Put a Coucou launcher on each user's desktop (the folder `xdg-user-dir DESKTOP`
        names, such as ~/Desktop or ~/Bureau) at every graphical login. While this is on,
        a launcher you delete comes back at the next login; turning it off leaves the
        last copy in place.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # The launcher holds no store path (Exec=coucou, Icon=coucou), so a copy keeps
    # working across updates. Executable, so Plasma and Xfce trust it.
    systemd.user.services.coucou-desktop-shortcut = lib.mkIf cfg.desktopShortcut {
      description = "Coucou launcher on the desktop";
      wantedBy = [ "graphical-session.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        desktop=$(${pkgs.xdg-user-dirs}/bin/xdg-user-dir DESKTOP)
        # xdg-user-dir answers $HOME when no desktop folder is set: leave home alone.
        if [ -n "$desktop" ] && [ "$desktop" != "$HOME" ]; then
          install -Dm755 ${cfg.package}/share/applications/Coucou.desktop "$desktop/Coucou.desktop"
        fi
      '';
    };
  };
}
