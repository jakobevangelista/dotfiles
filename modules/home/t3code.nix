{ config, lib, pkgs, ... }:

let
  t3code = pkgs.callPackage ../../pkgs/t3code { };
  homeDir = config.home.homeDirectory;
  servicePath = lib.concatStringsSep ":" (config.home.sessionPath ++ [
    "${config.home.profileDirectory}/bin"
    "${homeDir}/.nix-profile/bin"
    "/run/wrappers/bin"
    "/run/current-system/sw/bin"
  ]);
in
{
  home.packages = [ t3code ];

  # Odin enables users.users.jakob.linger, so this starts at boot without SSH.
  systemd.user.services.t3code = {
    Unit = {
      Description = "T3 Code headless server";
      # Retire the temporary trial when the managed service is first started.
      Conflicts = [ "t3code-trial.service" ];
      After = [ "t3code-trial.service" ];
    };

    Service = {
      ExecStart = "${t3code}/bin/t3 serve --host 127.0.0.1 --port 3773 --base-dir ${homeDir}/.t3 --tailscale-serve";
      WorkingDirectory = "${homeDir}/personal";
      Environment = [ "PATH=${servicePath}" ];
      Restart = "on-failure";
      RestartSec = 5;
      UMask = "0077";
    };

    Install.WantedBy = [ "default.target" ];
  };
}
