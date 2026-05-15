{ config, lib, pkgs, ... }:
let
  cfg = config.services.kace-ampagent;
  inherit (lib)
    mkOption mkEnableOption mkIf types
    mapAttrsToList concatStringsSep optional filterAttrs;

  # Ensure required tools are in PATH for script execution
  kacePath = lib.makeBinPath [
    pkgs.coreutils    # true, false, etc.
    pkgs.bash         # CRITICAL - needed to run any scripts
    pkgs.psmisc       # killall
    pkgs.gnugrep      # grep
    pkgs.gnused       # sed
    pkgs.findutils    # find, xargs
    pkgs.inetutils    # hostname - needed by inventory scripts
  ];

  # Environment: build systemd-friendly env list
  envWithoutPath = filterAttrs (n: _: n != "PATH") cfg.environment;

  finalPath =
    if (cfg.environment ? PATH) && (cfg.environment.PATH != "")
    then "${kacePath}:${cfg.environment.PATH}"
    else kacePath;

  kaceEnv = [ "PATH=${finalPath}" ] ++ mapAttrsToList (n: v: "${n}=${v}") envWithoutPath;

  # Path to kace binaries
  kaceBinDir = "${cfg.package}/opt/quest/kace/bin";

  # Helper: direct foreground execution (preferred on NixOS)
  mkKaceServiceSimple = name: desc: extraOpts:
    let
      bin = "${kaceBinDir}/${name}";
    in
    {
      description = desc;
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = bin;
        KillSignal = "SIGTERM";
        KillMode = "control-group";
        TimeoutStartSec = 120;
        TimeoutStopSec = 30;
        Restart = "on-failure";
        RestartSec = 5;
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        Environment = kaceEnv;
        StandardOutput = "journal";
        StandardError  = "journal";
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

    name = mkOption {
      type = types.str;
      default = config.networking.hostName;
      description = "Machine name reported to KBOX (defaults to networking.hostName).";
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
    # === Users/groups and directories ===
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
        # hostname is not at a standard FHS path on NixOS; inventory scripts
        # that reset PATH to /bin:/usr/bin:/usr/local/bin need it here.
        "L+ /usr/local/bin/hostname - - - - /run/current-system/sw/bin/hostname"
      ] ++ optional cfg.linkOptPath "L+ /opt/quest/kace - - - - ${cfg.package}/opt/quest/kace";

    # === Write NixOS-managed keys into amp.conf ===
    # Merges host= and any ampConf entries into the live amp.conf on every
    # nixos-rebuild switch, preserving all other keys pushed down by KBOX.
    system.activationScripts.kace-ampconf = ''
      mkdir -p "${cfg.dataDir}"
      CONF="${cfg.dataDir}/amp.conf"
      touch "$CONF"
      ${concatStringsSep "\n" (mapAttrsToList (k: v: ''
        if ${pkgs.gnugrep}/bin/grep -q "^${k}=" "$CONF"; then
          ${pkgs.gnused}/bin/sed -i 's|^${k}=.*|${k}=${v}|' "$CONF"
        else
          printf '%s\n' '${k}=${v}' >> "$CONF"
        fi
      '') ({ host = cfg.host; name = cfg.name; } // cfg.ampConf))}
    '';

    # === konea: runs as daemon with -start ===
    systemd.services.konea = {
      description = "KACE konea agent";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.bash}/bin/bash -c 'PATH=${finalPath} exec ${kaceBinDir}/konea'";
        KillSignal = "SIGTERM";
        KillMode = "control-group";
        TimeoutStartSec = 120;
        TimeoutStopSec = 30;
        Restart = "on-failure";
        RestartSec = 5;
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        Environment = kaceEnv;
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # === KSchedulerConsole: start/stop flags
    systemd.services.kschedulerconsole = {
      description = "KACE Scheduler Console";
      after = [ "konea.service" "network-online.target" ];
      requires = [ "konea.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 10";
        ExecStart = "${pkgs.bash}/bin/bash -c 'PATH=${finalPath} exec ${kaceBinDir}/KSchedulerConsole'";
        KillSignal = "SIGTERM";
        KillMode = "control-group";
        TimeoutStartSec = 120;
        TimeoutStopSec = 30;
        Restart = "on-failure";
        RestartSec = 5;
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        Environment = kaceEnv;
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # === Optional AMPWatchDog ===
    systemd.services.ampwatchdog = mkIf cfg.enableWatchdog (mkKaceServiceSimple "AMPWatchDog" "KACE Watchdog Service" {
      after = [ "konea.service" ];
      requires = [ "konea.service" ];
    });

    # === Optional timer ===
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

  };
}
