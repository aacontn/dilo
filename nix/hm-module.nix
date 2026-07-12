# Home-manager module for Dilo speech-to-text
#
# Provides a systemd user service for autostart.
# Usage: imports = [ dilo.homeManagerModules.default ];
#        services.dilo.enable = true;
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.dilo;
in
{
  options.services.dilo = {
    enable = lib.mkEnableOption "Dilo speech-to-text user service";

    package = lib.mkOption {
      type = lib.types.package;
      defaultText = lib.literalExpression "dilo.packages.\${system}.dilo";
      description = "The Dilo package to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.dilo = {
      Unit = {
        Description = "Dilo speech-to-text";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${cfg.package}/bin/dilo";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
