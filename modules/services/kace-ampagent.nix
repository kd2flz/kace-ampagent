{ config, lib, pkgs, ... }:
let
  cfg = config.services.kace-ampagent;
  inherit (lib)
    mkOption mkEnableOption mkIf types
    mapAttrsToList concatStringsSep optional filterAttrs;

  # Ensure required tools are in PATH (coreutils at least)
  kacePath = lib.makeBinPath [ pkgs.coreutils ];

  # Environment: build systemd-friendly env list
  envWithoutPath = filterAttrs (n: _: n != "PATH") cfg.environment;

  finalPath =
    if (cfg.environment ? PATH) && (cfg.environment.PATH != "")
    then "${kacePath}:${cfg.environment.PATH}"
    else kacePath;

  kaceEnv = [ "PATH=${finalPath}" ] ++ mapAttrsToList (n: v: "${n}=${v}") envWithoutPath;

  # Helper: create a systemd-safe service for a KACE binary
  mkKaceService = name: desc: extraOpts:
    {
      description = desc;

      # Unit-level fields
      wantedBy = [ "multi-user.target" ];
      after = [ "kace-ampagent-setup.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "kace-ampagent-setup.service" ]; # ensure config exists

      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 30;
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        Environment = kaceEnv;

        # Use native KACE stop/start flags instead of killall
        ExecStart = "${cfg.package}/opt/quest/kace/bin/${name} -start";
        ExecStop = "${cfg.package}/opt/quest/kace/bin/${name} -stop";

        StandardOutput = "journal";
        StandardError = "journal";
      };
    } // extraOpts;
in
{
  options.services.kace-ampagent = {
    enable = mkEnableOption "Quest KACE AMP Agent (systemd)";

    package = mkOption {
      type = types.package;
      default = pkgs.kace-ampagent;
      description = "Package containing KACE agent tree (e.g., tarball install under /opt/quest/kace).";
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = "User to run KACE services.";
    };

    group = mkOption {
      type = types.str;
      default = "root";
      description = "Group for KACE services.";
    };

    # runtime filesystem paths -> prefer str over path
    dataDir = mkOption {
      type = types.str;
      default = "/var/quest/kace";
      description = "Working/data directory (amp.conf lives here).";
    };

    logDir = mkOption {
      type = types.str;
      default = "/var/log/quest/kace";
      description = "Log directory.";
    };

    host = mkOption {
      type = types.str;
      example = "kbox.example.com";
      description = "KACE SMA host (written to amp.conf).";
    };

    ampConf = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { org = "Default"; };
      description = "Additional key=value entries for amp.conf.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional environment variables (e.g., KACE_TOKEN, KACE_HTTPS).";
    };

    linkOptPath = mkOption {
      type = types.bool;
      default = true;
      description = "Create /opt/quest/kace → package symlink.";
    };

    enableWatchdog = mkOption {
      type = types.bool;
      default = false;
      description = "Enable standalone AMPWatchDog as systemd service (replaces cron).";
    };
  };

  config = mkIf cfg.enable {
    # === Setup users/groups and directories ===
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
      ] ++ optional cfg.linkOptPath "L+ /opt/quest/kace - - - - ${cfg.package}/opt/quest/kace";

    # === Configuration setup (amp.conf) ===
    systemd.services.kace-ampagent-setup = {
      description = "Setup KACE AMP configuration";
      wantedBy = [ "multi-user.target" ];
      before = [ "konea.service" "kschedulerconsole.service" ];

      # Run as root so we can chown/chmod deterministically
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        WorkingDirectory = cfg.dataDir;
        ExecStart = let
          confBody =
            "host=${cfg.host}\n" +
            (if cfg.ampConf == { } then "" else
              concatStringsSep "\n" (mapAttrsToList (n: v: "${n}=${v}") cfg.ampConf) + "\n");
          setupScript = pkgs.writeShellScript "kace-setup" ''
            set -euo pipefail

            # Create directories with owner/group/mode
            install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}
            install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.logDir}

            tmpfile="$(mktemp)"
            # Use single-quoted heredoc delimiter to avoid runtime expansions
            cat > "$tmpfile" <<'AMP_CONF_EOF'
${confBody}
AMP_CONF_EOF
            chmod 640 "$tmpfile"
            chown ${cfg.user}:${cfg.group} "$tmpfile"
            mv -f "$tmpfile" ${cfg.dataDir}/amp.conf
          '';
        in
          setupScript;
      };
    };

    # === Service: konea (main agent) ===
    systemd.services.konea = mkKaceService "konea" "KACE konea agent" { };

    # === Service: KSchedulerConsole ===
    systemd.services.kschedulerconsole = mkKaceService "KSchedulerConsole" "KACE Scheduler Console" {
      after = [ "konea.service" ];
      requires = [ "konea.service" ];
      wantedBy = [ "multi-user.target" ];
    };

    # === Optional: AMPWatchDog as native systemd service (no cron) ===
    systemd.services.ampwatchdog = mkIf cfg.enableWatchdog (mkKaceService "AMPWatchDog" "KACE Watchdog Service" {
      after = [ "konea.service" ];
      requires = [ "konea.service" ];
      # If AMPWatchDog really wants to daemonize, you could:
      # serviceConfig = {
      #   ExecStart = "${cfg.package}/opt/quest/kace/bin/AMPWatchDog --daemon";
      #   # and drop ExecStop to let systemd handle TERM/KILL
      # };
    });

    # === Optional: Timer for health checks / cron replacement ===
    systemd.timers.konea-checker = mkIf cfg.enableWatchdog {
      description = "Periodic KACE health check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "5min";
        AccuracySec = "1m";
        Persistent = true;
      };
    };

    systemd.services.konea-checker = mkIf cfg.enableWatchdog {
      description = "KACE Konea health check (once per timer tick)";
      after = [ "konea.service" ];
      requires = [ "konea.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${cfg.package}/opt/quest/kace/bin/AMPHealthCheck";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # === Optional: Legacy AMPctl compatibility (systemd-backed) ===
    systemd.services.ampctl = {
      description = "Legacy KACE AMPctl compatibility wrapper (systemd-backed)";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.writeShellScript "ampctl-wrapper" ''
          set -euo pipefail
          case "$1" in
            start)
              systemctl start konea
              systemctl start kschedulerconsole
              ;;
            stop)
              systemctl stop kschedulerconsole || true
              systemctl stop konea || true
              ;;
            restart)
              systemctl restart kschedulerconsole
              systemctl restart konea
              ;;
            status)
              if systemctl is-active --quiet konea; then
                exit 0
              else
                exit 1
              fi
              ;;
            *)
              echo "Usage: $0 {start|stop|restart|status}" >&2
              exit 1
              ;;
          esac
        ''}/bin/ampctl-wrapper";
      };
    };
  };
}