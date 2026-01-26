
{ config, lib, pkgs, ... }:
let
  cfg = config.services.kace-ampagent;
  inherit (lib) mkOption mkEnableOption mkIf types optional mapAttrsToList concatStringsSep;
in
{
  options.services.kace-ampagent = {
    enable = mkEnableOption "Quest KACE AMP Agent";

    package = mkOption {
      type = types.package;
      default = pkgs.kace-ampagent;
      description = "Package providing the KACE agent tree (generic tarball version).";
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = "User account to run the KACE agent.";
    };

    group = mkOption {
      type = types.str;
      default = "root";
      description = "Group to run the KACE agent.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/quest/kace";
      description = "Data directory used by the KACE agent (contains amp.conf).";
    };

    logDir = mkOption {
      type = types.path;
      default = "/var/log/quest/kace";
      description = "Log directory used by the KACE agent.";
    };

    host = mkOption {
      type = types.str;
      example = "kbox.example.com";
      description = "KACE SMA host (amp.conf: host=<value>).";
    };

    ampConf = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { org = "Default"; /* token = "enrollment-token"; */ };
      description = "Extra amp.conf entries to write as key=value lines.";
    };

    execPath = mkOption {
      type = types.str;
      default = "${cfg.package}/bin/ampagent";
      description = "Path to the ampagent executable.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra arguments passed to ampagent at start.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Environment variables for the agent (e.g., KACE_HOST, KACE_TOKEN).";
    };

    linkOptPath = mkOption {
      type = types.bool;
      default = true;
      description = "Create /opt/quest/kace symlink to the package content (useful for scripts expecting FHS paths).";
    };
  };

  config = mkIf cfg.enable {
    users.groups = mkIf (cfg.group != "root") {
      "${cfg.group}" = { };
    };

    users.users = mkIf (cfg.user != "root") {
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
      ++ optional cfg.linkOptPath "L+ /opt/quest/kace - - - - ${cfg.package}/opt/quest/kace";

    systemd.services.kace-ampagent-setup = {
      description = "Prepare KACE AMP Agent configuration";
      wantedBy = [ "multi-user.target" ];
      before = [ "kace-ampagent.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = let
          confBody =
            "host=${cfg.host}\n" +
            (if cfg.ampConf == { } then "" else
              (concatStringsSep "\n" (mapAttrsToList (n: v: "${n}=${v}") cfg.ampConf)) + "\n");
          setupScript = pkgs.writeShellScript "kace-setup" ''
            set -euo pipefail
            install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}
            install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.logDir}
            tmpfile="$(mktemp)"
            cat > "$tmpfile" <<'EOF'
${confBody}EOF
            install -m 0640 -o ${cfg.user} -g ${cfg.group} "$tmpfile" ${cfg.dataDir}/amp.conf
            rm -f "$tmpfile"
          '';
        in setupScript;
      };
    };

    systemd.services.kace-ampagent = {
      description = "Quest KACE AMP Agent";
      after = [ "network-online.target" "kace-ampagent-setup.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        Restart = "on-failure";
        RestartSec = "30s";
        Environment = mapAttrsToList (n: v: "${n}=${v}") cfg.environment;
        ExecStart = lib.escapeShellArgs ([ cfg.execPath ] ++ cfg.extraArgs);
      };
    };
  };
}
