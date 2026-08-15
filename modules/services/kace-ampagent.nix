{ config, lib, pkgs, ... }:
let
  cfg = config.services.kace-ampagent;
  inherit (lib)
    mkOption mkEnableOption mkIf types
    mapAttrsToList concatStringsSep optional filterAttrs;

  # Use custom package with URL if provided
  kacePackage = if cfg.packageUrl != null then pkgs.kace-ampagent.override { url = cfg.packageUrl; } else cfg.package;

  # Ensure required tools are in PATH for script execution.
  # This PATH is inherited by konea's /exec spawn chain (konea -> KPlugins ->
  # runkbot -> KBoxClient -> KInventory): konea does NOT sanitise it. Verified
  # 2026-08-14 by re-running KInventory with this exact PATH and reproducing the
  # broken ~4.5KB inventory (0 CPUs) that the SMA silently discards; with lscpu
  # on PATH the same run yields the ~33.8KB inventory the SMA accepts. Tools
  # KInventory needs must therefore be listed HERE, not as /usr/bin FHS symlinks
  # (the spawn PATH has no /usr/bin, so the symlinks never resolve).
  kacePath = lib.makeBinPath [
    pkgs.coreutils    # true, false, etc.
    pkgs.bash         # CRITICAL - needed to run any scripts
    pkgs.psmisc       # killall
    pkgs.gnugrep      # grep
    pkgs.gnused       # sed
    pkgs.gawk         # awk - used by inventory shell pipelines
    pkgs.findutils    # find, xargs
    pkgs.inetutils    # hostname - needed by inventory scripts
    pkgs.procps       # ps, free - processes and memory inventory
    pkgs.util-linux   # lscpu - CPU inventory (0 CPUs => SMA discards the doc)
    pkgs.iproute2     # ip - network interface inventory
    pkgs.systemd      # systemctl - needed for startup programs inventory
    pkgs.pciutils     # lspci - needed for audio/video hardware inventory
    pkgs.networkmanager # nmcli - needed for DHCP/network inventory
  ];

  # Environment: build systemd-friendly env list
  envWithoutPath = filterAttrs (n: _: n != "PATH") cfg.environment;

  finalPath =
    if (cfg.environment ? PATH) && (cfg.environment.PATH != "")
    then "${kacePath}:${cfg.environment.PATH}"
    else kacePath;

  kaceEnv = [ "PATH=${finalPath}" ] ++ mapAttrsToList (n: v: "${n}=${v}") envWithoutPath;

  # Path to kace binaries
  kaceBinDir = "${kacePackage}/opt/quest/kace/bin";

  # Wrapper for the 10-min konea checker. AMPWatchDog -k revives konea (it
  # detects systemd and does `systemctl start konea`), but it does NOT restart
  # KSchedulerConsole, which also dies on an SMA agent-reset (RESETAGENT stops
  # both, so Restart=always never fires). konea has no scheduler code of its
  # own, so without KSchedulerConsole scheduled inventory/scripts silently stop.
  # KACE's own AMPctl starts both konea and KSchedulerConsole together, so we
  # mirror that here.
  koneaCheckerScript = pkgs.writeShellScript "kace-konea-checker" ''
    set +e
    ${kaceBinDir}/AMPWatchDog -k
    if ! ${pkgs.systemd}/bin/systemctl is-active --quiet kschedulerconsole.service; then
      echo "konea-checker: KSchedulerConsole not running, starting it"
      ${pkgs.systemd}/bin/systemctl start kschedulerconsole.service
    fi
  '';

  # Wrapper for the 10-min konea checker. AMPWatchDog -k revives konea (it
  # detects systemd and does `systemctl start konea`), but it does NOT restart
  # KSchedulerConsole, which also dies on an SMA agent-reset (RESETAGENT stops
  # both, so Restart=always never fires). konea has no scheduler code of its
  # own, so without KSchedulerConsole scheduled inventory/scripts silently stop.
  # KACE's own AMPctl starts both konea and KSchedulerConsole together, so we
  # mirror that here.
  koneaCheckerScript = pkgs.writeShellScript "kace-konea-checker" ''
    set +e
    ${kaceBinDir}/AMPWatchDog -k
    if ! ${pkgs.systemd}/bin/systemctl is-active --quiet kschedulerconsole.service; then
      echo "konea-checker: KSchedulerConsole not running, starting it"
      ${pkgs.systemd}/bin/systemctl start kschedulerconsole.service
    fi
  '';

  # Script that re-applies NixOS-managed keys to amp.conf.
  # Runs after a delay so it fires after KBOX pushes its config on connect,
  # which would otherwise clobber keys we set at activation time.
  ampConfPatchScript = pkgs.writeShellScript "kace-ampconf-patch" ''
    sleep 30
    CONF="${cfg.dataDir}/amp.conf"
    ${concatStringsSep "\n" (mapAttrsToList (k: v: ''
      if ${pkgs.gnugrep}/bin/grep -q "^${k}=" "$CONF"; then
        ${pkgs.gnused}/bin/sed -i 's|^${k}=.*|${k}=${v}|' "$CONF"
      else
        printf '%s\n' '${k}=${v}' >> "$CONF"
      fi
    '') ({ name = cfg.name; } // cfg.ampConf))}
  '';
in
{
  options.services.kace-ampagent = {
    enable = mkEnableOption "Quest KACE AMP Agent (systemd)";

    package = mkOption {
      type = types.package;
      default = pkgs.kace-ampagent;
      description = "Package containing KACE agent tree (e.g., tarball install under /opt/quest/kace).";
    };

    packageUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://your-server.example.com/ampagent-15.1.45.ubuntu.64.tar.gz";
      description = "Optional URL to fetch the agent tarball for pure builds. If set, overrides the package source via pkgs.kace-ampagent.override { url = ... }.";
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
      type = types.nullOr types.str;
      default = null;
      example = "kbox.example.com";
      description = ''
        KACE SMA host (written to amp.conf), given directly as a plain string.
        Mutually exclusive with `hostFile`. Exactly one of `host` or `hostFile`
        must be set.
      '';
    };

    hostFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/kace-host";
      description = ''
        Path to a file containing the KACE SMA host, read at activation
        *runtime* (e.g. via `cat`) rather than interpolated into the Nix
        string / activation script at eval time. Use this instead of `host`
        when the hostname must not appear in the Nix store or in any `.drv`
        (e.g. a sops-nix secret path). Mutually exclusive with `host`.
        Exactly one of `host` or `hostFile` must be set.
      '';
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
      description = "Enable AMPWatchDog via systemd timers (replaces the cron one-shots KACE ships: every 6h watchdog + every 10 min konea checker). The 10 min checker also restarts KSchedulerConsole, which AMPWatchDog -k does not cover.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.host != null) != (cfg.hostFile != null);
        message = "services.kace-ampagent: exactly one of `host` or `hostFile` must be set.";
      }
    ];

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

    # dmidecode is hardcoded to /usr/sbin/dmidecode by KInventory; ensure it is installed.
    environment.systemPackages = [ pkgs.dmidecode ];

    systemd.tmpfiles.rules =
      [
        "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
        "d ${cfg.logDir} 0750 ${cfg.user} ${cfg.group} - -"
        # hostname is not at a standard FHS path on NixOS. konea (precompiled Ubuntu
        # binary) calls hostname via a hardcoded PATH=/usr/bin:/bin, so we need
        # symlinks in all three locations. Point directly to the nix store path
        # so they are never dangling regardless of environment.systemPackages.
        "L+ /usr/local/bin/hostname - - - - ${pkgs.inetutils}/bin/hostname"
        "L+ /usr/bin/hostname - - - - ${pkgs.inetutils}/bin/hostname"
        "L+ /bin/hostname - - - - ${pkgs.inetutils}/bin/hostname"
        # dmidecode is hardcoded to /usr/sbin/dmidecode in KInventory (not on PATH).
        "L+ /usr/sbin/dmidecode - - - - ${pkgs.dmidecode}/bin/dmidecode"
        # KInventory resolves these with find_cmd_in_path against konea's spawn
        # PATH (= kacePath above). /usr/bin symlinks alone are NOT sufficient -
        # the spawn PATH has no /usr/bin - but keep them for tools invoked via a
        # hardcoded /usr/bin|/usr/sbin|/bin path (dmidecode, lsblk, bash,
        # hostname). Without lscpu on PATH, KInventory emits a ~4.5KB document
        # reporting 0 CPUs, which the SMA silently discards: the upload still
        # returns 200 with an empty body, so the only symptom is Last Inventory
        # never advancing. Note: the 2026-08-06 "symlink fix" (4.5KB -> 33.8KB)
        # was a false positive from a manually-run KInventory (user shell PATH);
        # konea-spawned runs stayed broken until kacePath gained the tools.
        "L+ /usr/bin/lspci - - - - ${pkgs.pciutils}/bin/lspci"
        "L+ /usr/bin/systemctl - - - - ${pkgs.systemd}/bin/systemctl"
        "L+ /usr/bin/nmcli - - - - ${pkgs.networkmanager}/bin/nmcli"
        "L+ /usr/bin/lscpu - - - - ${pkgs.util-linux}/bin/lscpu"
        "L+ /usr/bin/ip - - - - ${pkgs.iproute2}/bin/ip"
        "L+ /usr/bin/lsblk - - - - ${pkgs.util-linux}/bin/lsblk"
        "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
        # Not fixable this way: rpm / dpkg-query do not exist on NixOS, so
        # INSTALLED_SOFTWARE stays empty ("Only RPM and Debian package systems
        # currently supported!"). Needs a KACE Custom Inventory Rule instead.
      ] ++ optional cfg.linkOptPath "L+ /opt/quest/kace - - - - ${kacePackage}/opt/quest/kace";

    # === Write NixOS-managed keys into amp.conf at activation time ===
    # Handles initial setup and ensures host= is always correct.
    # Note: KBOX pushes a fresh amp.conf on every konea connection, which
    # clobbers keys like name=. The ExecStartPost on konea re-applies them
    # 30 s after start (after the KBOX push settles).
    #
    # host= is upserted separately from the name=/ampConf map below so that
    # `hostFile` (e.g. a sops-nix secret path) can be `cat`-ed at shell
    # *runtime* instead of being interpolated into this script as a Nix
    # string at *eval* time. Interpolating a value here bakes it in plain
    # text into the activation script derivation in /nix/store (world
    # readable, cached, copied on `nix copy`) -- fine for non-secret values
    # like `host`, but defeats the point of a secret if `hostFile` is used.
    #
    # When hostFile is used, this script must run AFTER sops-nix has
    # decrypted secrets to /run/secrets/, not before. NixOS activation
    # scripts have no default ordering guarantee -- observed in production
    # (2026-08-25): kace-ampconf ran before setupSecrets, so
    # `cat "${cfg.hostFile}"` hit "No such file or directory" and failed the
    # whole activation.
    #
    # `setupSecrets` only exists when sops-nix is imported AND declares at
    # least one regular secret AND is not using `useSystemdActivation`
    # (see sops-nix modules/sops/default.nix). Referencing a nonexistent
    # activation-script name in `deps` is a hard eval error ("attribute
    # 'setupSecrets' missing"), so the dependency must be conditional on it
    # actually existing -- this module has no hard dependency on sops-nix
    # (host= works with a plain string with no secrets involved at all).
    system.activationScripts.kace-ampconf =
      let
        kaceAmpconfScript = ''
          mkdir -p "${cfg.dataDir}"
          CONF="${cfg.dataDir}/amp.conf"
          touch "$CONF"

          ${
            if cfg.hostFile != null then ''
              HOST_VALUE="$(cat "${cfg.hostFile}")"
              if ${pkgs.gnugrep}/bin/grep -q "^host=" "$CONF"; then
                ${pkgs.gnused}/bin/sed -i "s|^host=.*|host=$HOST_VALUE|" "$CONF"
              else
                printf 'host=%s\n' "$HOST_VALUE" >> "$CONF"
              fi
            '' else ''
              if ${pkgs.gnugrep}/bin/grep -q "^host=" "$CONF"; then
                ${pkgs.gnused}/bin/sed -i 's|^host=.*|host=${cfg.host}|' "$CONF"
              else
                printf 'host=%s\n' '${cfg.host}' >> "$CONF"
              fi
            ''
          }

          ${concatStringsSep "\n" (mapAttrsToList (k: v: ''
            if ${pkgs.gnugrep}/bin/grep -q "^${k}=" "$CONF"; then
              ${pkgs.gnused}/bin/sed -i 's|^${k}=.*|${k}=${v}|' "$CONF"
            else
              printf '%s\n' '${k}=${v}' >> "$CONF"
            fi
          '') ({ name = cfg.name; } // cfg.ampConf))}
        '';
        # Only depend on setupSecrets if it actually exists: sops-nix
        # imported, has >=1 regular (non-neededForUsers) secret, and is not
        # using useSystemdActivation (mirrors sops-nix's own condition for
        # defining system.activationScripts.setupSecrets -- see sops-nix
        # modules/sops/default.nix). Referencing a nonexistent
        # activation-script name in `deps` is a hard eval error, and this
        # module has no hard dependency on sops-nix (host= needs no secrets
        # at all).
        #
        # Deliberately checks config.sops.* (a disjoint part of the config
        # tree) rather than `config.system.activationScripts ? setupSecrets`:
        # the latter forces evaluating the merged activationScripts attrset,
        # which includes kace-ampconf's own value -- infinite recursion.
        hasSetupSecrets =
          (config ? sops)
          && (lib.filterAttrs (_: v: !(v.neededForUsers or false)) (config.sops.secrets or { }) != { })
          && !(config.sops.useSystemdActivation or false);
      in
        if cfg.hostFile != null && hasSetupSecrets
        then lib.stringAfter [ "setupSecrets" ] kaceAmpconfScript
        else kaceAmpconfScript;

    # === konea: runs as daemon with -start ===
    systemd.services.konea = {
      description = "KACE konea agent";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.bash}/bin/bash -c 'PATH=${finalPath} exec ${kaceBinDir}/konea'";
        # Re-apply name= (and any ampConf keys) after KBOX pushes its config.
        # KBOX overwrites amp.conf shortly after konea connects; 30 s is enough
        # for that push to complete before we write our keys back.
        ExecStartPost = ampConfPatchScript;
        KillSignal = "SIGTERM";
        KillMode = "control-group";
        TimeoutStartSec = 120;
        TimeoutStopSec = 30;
        # "always", not "on-failure": the SMA's agent-reset tells konea to shut
        # down, and konea exits 0. on-failure ignores a clean exit, so the agent
        # stays dead until the next reboot with nothing appearing to be wrong.
        # Observed 2026-08-07: a reset at 08:50:35 took konea and
        # KSchedulerConsole down and neither returned for hours -- no scheduled
        # or forced inventory can run in that state.
        Restart = "always";
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
        # Same clean-exit-on-reset problem as konea above. Without this the
        # scheduler stays dead after a reset, so even the periodic inventory
        # stops -- the failure is silent because nothing ever reports failed.
        Restart = "always";
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
    # KACE ships AMPWatchDog as periodic cron one-shots (see AMPWatchDogCrontab
    # and KoneaCheckerCrontab in the package), so we model it as systemd timers,
    # NOT a long-running service. A watchdog must not depend on konea.service --
    # if it did, it would be stopped whenever konea is stopped (e.g. by an SMA
    # agent-reset), which is exactly the failure it exists to recover from.
    systemd.timers.ampwatchdog = mkIf cfg.enableWatchdog {
      description = "AMPWatchDog periodic health check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 03,09,15,21:05:00"; # matches AMPWatchDogCrontab (every 6h)
        AccuracySec = "1m";
        Persistent = true;
      };
    };

    systemd.services.ampwatchdog = mkIf cfg.enableWatchdog {
      description = "AMPWatchDog KACE watchdog (one-shot per timer tick)";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        Environment = kaceEnv;
        ExecStart = "${kaceBinDir}/AMPWatchDog";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    systemd.timers.konea-checker = mkIf cfg.enableWatchdog {
      description = "Periodic KACE konea health check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* *:00,10,20,30,40,50:00"; # matches KoneaCheckerCrontab (every 10 min)
        AccuracySec = "1m";
        Persistent = true;
      };
    };

    systemd.services.konea-checker = mkIf cfg.enableWatchdog {
      description = "KACE konea health check (one-shot per timer tick)";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        Environment = kaceEnv;
        ExecStart = koneaCheckerScript;
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

  };
}
