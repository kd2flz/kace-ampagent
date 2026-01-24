{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.kace-ampagent;
in
{
  options.services.kace-ampagent = {
    enable = lib.mkEnableOption "Quest KACE AMP Agent";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.kace-ampagent;
      description = "Package providing the KACE ampagent binary.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "User account to run the KACE agent.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "Group to run the KACE agent.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/quest/kace";
      description = "Data directory used by the KACE agent.";
    };

    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/log/quest/kace";
      description = "Log directory used by the KACE agent.";
    };

    execPath = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.package}/bin/ampagent";
      description = "Path to the ampagent executable.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments passed to ampagent at start.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the agent (e.g., KACE_HOST, KACE_TOKEN).";
      example = {
        KACE_HOST = "kbox.example.com";
        KACE_TOKEN = "your-enroll-token";
      };
    };

    linkOptPath = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create /opt/quest/kace symlink to the package content.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups = lib.mkIf (cfg.group != "root") {
      "${cfg.group}" = { };
    };

    users.users = lib.mkIf (cfg.user != "root") {
      "${cfg.user}" = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
        description = "KACE AMP Agent";
      };
    };

    systemd.tmpfiles.rules =
      [
        "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
        "d ${cfg.logDir} 0750 ${cfg.user} ${cfg.group} - -"
      ]
      ++ lib.optional cfg.linkOptPath "L+ /opt/quest/kace - - - - ${cfg.package}/opt/quest/kace";

    systemd.services.kace-ampagent = {
      description = "Quest KACE AMP Agent";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        Restart = "on-failure";
        RestartSec = "30s";
        Environment = lib.mapAttrsToList (n: v: "${n}=${v}") cfg.environment;
        ExecStart = lib.escapeShellArgs ([ cfg.execPath ] ++ cfg.extraArgs);
      };
    };
  };
}
