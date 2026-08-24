# KACE AMP Agent - Nix Package and NixOS Module

This project provides a Nix package and NixOS module for the Quest KACE AMP Agent, specifically designed for the generic Linux tarball distribution.

## Module Structure
- Module: `modules/services/kace-ampagent.nix`
- Package: `pkgs/kace-ampagent/default.nix`

## Providing the Agent Tarball

The `kace-ampagent` Nix package requires the official Quest KACE SMA generic Linux agent tarball (currently `ampagent-15.1.45.ubuntu.64.tar.gz`; see `version` in `pkgs/kace-ampagent/default.nix`). This file is not included in the repository due to licensing and distribution restrictions. There are two ways to provide it.

### Option A - Fetch by URL (pure build, recommended)

Set `services.kace-ampagent.packageUrl` (or pass `url` directly to the package via `pkgs.kace-ampagent.override { url = "..."; }`). Nix downloads the tarball with `fetchurl` and verifies it against the SHA256 pinned in `pkgs/kace-ampagent/default.nix`:

```nix
services.kace-ampagent = {
  enable = true;
  host = "kbox.example.com";
  packageUrl = "https://your-server.example.com/ampagent-15.1.45.ubuntu.64.tar.gz";
};
```

- Any publicly reachable HTTP(S) location works (web server, GitHub release, internal mirror); the downloaded bytes must match the pinned hash or the build fails.
- Do **not** put credentials or tokens in the URL (including query strings): URLs can surface in store paths and logs.
- This repository's GitHub Actions workflow fetches the tarball using the `KACE_TARBALL_URL` repository secret (Settings -> Secrets and variables -> Actions).

### Option B - Manual store import (`requireFile`)

1.  **Download the Agent Tarball:**
    Obtain the `ampagent-<version>.ubuntu.64.tar.gz` file from your KACE SMA portal. The exact filename and version are specified within `pkgs/kace-ampagent/default.nix`. See also the Quest KB: https://support.quest.com/kb/4272341/how-to-find-and-install-the-generic-linux-agent-for-sma

2.  **Verify SHA256 Hash (Recommended):**
    The `default.nix` file contains a specific SHA256 hash for the expected tarball. If your downloaded file has a different hash, the build will fail. You can compute the hash of your file using:
    ```bash
    nix hash-file --type sha256 ampagent-<version>.ubuntu.64.tar.gz
    ```
    If the computed hash differs from the one in `pkgs/kace-ampagent/default.nix`, you will need to update the `sha256` attribute in that file to match your downloaded tarball.

3.  **Make the Tarball Accessible to Nix:**
      Add the file directly to your Nix store using the `nix store add-file` command. This registers the file with Nix, allowing `requireFile` to find it by its content hash:
      ```bash
    nix store add-file ./ampagent-<version>.ubuntu.64.tar.gz
    ```
      (Ensure you are in the directory containing the tarball when running this command.)

Once the tarball is correctly added to the store, Nix will be able to find it during the build process.

## How to Use (NixOS Config with Flakes)

1. **Add this flake as an input** in your system flake (e.g. `flake.nix`):

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11"; # or your channel
  kace-ampagent.url = "github:kd2flz/kace-ampagent/main"; # or your fork/branch
};
```

2. **Import the NixOS module** in your system configuration. The module brings in the service and registers an overlay so `pkgs.kace-ampagent` is built with your system's nixpkgs:

```nix
# In configuration.nix or wherever you list modules:
imports = [ kace-ampagent.nixosModules.kace-ampagent ];
```

3. **Allow unfree packages.** The agent is proprietary (`licenses.unfree`), so your host configuration must set:

```nix
nixpkgs.config.allowUnfree = true;
```

4. **Enable and configure the agent** (see Module Options below). Do **not** set `services.kace-ampagent.package` unless you have a specific reason: the default package comes from the overlay and is built with the same nixpkgs as the rest of your system, which avoids glibc mismatches and keeps your config independent of `inputs.kace-ampagent` in scope.

```nix
services.kace-ampagent = {
  enable = true;
  host = "kbox.example.com";
  # Pure build: fetch the tarball from a URL instead of `nix store add-file`.
  # The URL can also come from a sops-decoded file or any other source at eval time.
  packageUrl = "https://github.com/your-org/resources/releases/download/15.1.45/ampagent-15.1.45.ubuntu.64.tar.gz";
};
```

If you omit `packageUrl`, provide the tarball manually via Option B above.

You do not need to reference `kace-ampagent` in your flake `outputs` or `specialArgs`; the module is self-contained once imported.

### Optional extras

```nix
services.kace-ampagent = {
  enable = true;
  host = "kbox.example.com";
  name = "web01";               # defaults to networking.hostName
  ampConf = { org = "Default"; };
  environment = { KACE_HTTPS = "true"; };
  enableWatchdog = true;        # 6h watchdog + 10min konea/scheduler checker timers
  linkOptPath = true;           # /opt/quest/kace symlink (default)
};
```

## Local Build

To build the package or test the flake locally:

```bash
# Manual tarball mode (requires Option B store import first)
nix build .#kace-ampagent

# URL mode (pure): reads KACE_TARBALL_URL from the environment
KACE_TARBALL_URL="https://your-server.example.com/ampagent-15.1.45.ubuntu.64.tar.gz" \
  nix build --impure .#kace-ampagent-env
```

The `kace-ampagent-env` output falls back to `requireFile` behavior when the variable is unset or when built without `--impure`.

## Module Options

-   `services.kace-ampagent.enable`: Enable the KACE AMP Agent (boolean, default `false`). When enabled, the module creates `konea.service` (main daemon), `kschedulerconsole.service`, and - with `enableWatchdog = true` - the watchdog timers described below. `amp.conf` is managed by an activation script plus a post-start patch script, not by separate oneshot services.
-   `services.kace-ampagent.package`: The Nix package providing the KACE agent binaries (package, default: `pkgs.kace-ampagent` from the overlay). Leave unset so the module builds the package with your system's nixpkgs; override only if you need a different source.
-   `services.kace-ampagent.packageUrl`: Optional URL to fetch the agent tarball for pure builds (string or null, default `null`). When set, the module builds the package from that URL (`fetchurl`, verified against the pinned SHA256); when null, the package uses `requireFile` and expects the tarball in your store.
-   `services.kace-ampagent.user`: User to run KACE services (string, default `"root"`).
-   `services.kace-ampagent.group`: Group to run KACE services (string, default `"root"`).
-   `services.kace-ampagent.dataDir`: The directory where the agent stores its data (string, default `/var/quest/kace`).
-   `services.kace-ampagent.logDir`: The directory where the agent stores its logs (string, default `/var/log/quest/kace`).
-   `services.kace-ampagent.environment`: An attribute set of extra environment variables for the agent (attrset, default `{}`).
-   `services.kace-ampagent.linkOptPath`: Create a `/opt/quest/kace` symlink pointing to the package content for compatibility (boolean, default `true`).
-   `services.kace-ampagent.host`: The KACE SMA host (string, required). Written to `amp.conf` as `host=`.
-   `services.kace-ampagent.name`: Machine name reported to KBOX (string, default: `networking.hostName`). Written to `amp.conf` as `name=` and re-applied after each konea start (see Service Behavior).
-   `services.kace-ampagent.ampConf`: An attribute set of additional key-value pairs for `amp.conf` (attrset, default `{}`).
-   `services.kace-ampagent.enableWatchdog`: Enable `AMPWatchDog` via systemd timers (boolean, default `false`). Creates `ampwatchdog.timer` (every 6 h, matching `AMPWatchDogCrontab`) and `konea-checker.timer` (every 10 min, matching `KoneaCheckerCrontab`). The watchdog one-shots intentionally do NOT depend on `konea.service`, so they still run and restart konea after an SMA agent-reset. The 10 min `konea-checker` additionally restarts `KSchedulerConsole` if it is not running, because `AMPWatchDog -k` only revives konea - leaving the scheduler (which drives scheduled inventory/scripts) dead after a reset.

### Example

```nix
services.kace-ampagent = {
  enable = true;
  host = "kbox.example.com"; # Replace with your KACE SMA host
  ampConf = {
    # Example additional amp.conf settings
    org = "Default";
    # Other settings like CERT_VALIDATION, etc.
  };
  enableWatchdog = true; # Optional: watchdog + konea-checker timers
};
```

## Service Behavior

When the module is enabled:

1. **Activation (`system.activationScripts.kace-ampconf`)**: At system activation, the module ensures `/var/quest/kace/amp.conf` exists and upserts `host=`, `name=`, and every `ampConf` key (sed replace-in-place if the key exists, append otherwise).

2. **`konea.service`** (simple daemon): Runs konea from the package with the module's PATH (coreutils, bash, psmisc, grep, sed, awk, find, hostname, ps/free, lscpu, ip, systemctl, lspci, nmcli - konea's spawn chain inherits this PATH, and inventory tools missing from it cause silently discarded inventory documents). After start, an `ExecStartPost` script waits 30 seconds and re-applies `name=` and all `ampConf` keys: KBOX pushes a fresh `amp.conf` down shortly after konea connects, which would otherwise clobber locally-set keys. Uses `Restart = always` - the SMA's agent-reset makes konea exit cleanly (exit 0), which `Restart = on-failure` would ignore, leaving the agent dead until reboot.

3. **`kschedulerconsole.service`** (simple): Starts 10 s after konea (`requires konea.service`). Also uses `Restart = always` for the same clean-exit-on-reset reason.

4. **Optional watchdog** (`enableWatchdog = true`) - two systemd timers modeled after the cron one-shots shipped in the package. They deliberately do **not** depend on `konea.service`, so they still run after an SMA agent-reset stops konea:
   - **`ampwatchdog.timer` / `ampwatchdog.service`**: runs `AMPWatchDog` every 6 h (`*-*-* 03,09,15,21:05:00`, matching `AMPWatchDogCrontab`)
   - **`konea-checker.timer` / `konea-checker.service`**: runs every 10 min (`*:00,10,20,30,40,50:00`, matching `KoneaCheckerCrontab`) a wrapper that invokes `AMPWatchDog -k` (revives konea) and starts `kschedulerconsole.service` if it is down - `AMPWatchDog -k` only revives konea, but RESETAGENT stops both processes, so without this scheduled inventory/scripts would silently stop after a reset.

### FHS compatibility layer

The module creates tmpfiles symlinks so the prebuilt Ubuntu binaries find their tools on NixOS: `hostname` at `/usr/local/bin`, `/usr/bin` and `/bin` (from inetutils; konea hardcodes `PATH=/usr/bin:/bin`), `/usr/sbin/dmidecode`, `/usr/bin/{lspci,systemctl,nmcli,lscpu,ip,lsblk}`, `/bin/bash`, plus dmidecode added to `environment.systemPackages`.

Known limitation: KACE `INSTALLED_SOFTWARE` inventory stays empty because `rpm`/`dpkg-query` do not exist on NixOS ("Only RPM and Debian package systems currently supported!"). Addressing it requires a server-side KACE Custom Inventory Rule.

## Using the Agent Manually

When running `konea` commands manually (outside of systemd):

1. Ensure the package is built and available:
   ```bash
   nix build .#kace-ampagent
   ```

2. Run the binaries from the package:
   ```bash
   ./result/opt/quest/kace/bin/konea -help
   ```

3. Available `konea` commands:
   - `konea -start` - Start the konea daemon
   - `konea -stop` - Stop the konea daemon
   - `konea -url <host>` - Set the server URL
   - `konea -enable` - Enable connection to the server (enrollment)
   - `konea -disable` - Disable connection to server (daemon still runs)
   - `konea -version` - Output version information

4. Running kbot scripts manually:
   ```bash
   ./result/opt/quest/kace/bin/runkbot <kbot-id> <version>
   ```

## Notes

-   The KACE agent expects its files under `/opt/quest/kace`. The module creates a symlink to the package content at `/opt/quest/kace` by default (`services.kace-ampagent.linkOptPath = true;`).

-   **Enrollment happens through normal konea operation**: once `host` is set in `amp.conf` (activation script) and konea can reach the SMA, the agent enrolls itself. If it does not connect, check `journalctl -u konea.service` for reachability or certificate errors.

-   When running `konea` or `runkbot` manually, ensure PATH includes `killall` (psmisc) and `true` (coreutils). The systemd services automatically add these to PATH; for manual runs, use `sudo systemctl start konea` or add them manually.

-   The agent logs to `/var/log/quest/kace/`. You can view logs with `journalctl -u konea.service`.

-   The `amp.conf` file lives at `/var/quest/kace/amp.conf`. It is written at system activation (`host`, `name`, `ampConf` keys) and re-patched 30 s after each konea start (`name`, `ampConf` keys), because KBOX pushes its own copy of `amp.conf` when konea connects.