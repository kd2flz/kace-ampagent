# KACE AMP Agent - Nix Package and NixOS Module

This project provides a Nix package and NixOS module for the Quest KACE AMP Agent, specifically designed for the generic Linux tarball distribution.

## Module Structure
- Module: `modules/services/kace-ampagent.nix`
- Package: `pkgs/kace-ampagent/default.nix`

## Providing the Agent Tarball

The `kace-ampagent` Nix package requires the official generic Linux agent tarball (e.g., `ampagent-15.0.54.ubuntu.64.tar.gz`). This file is not included in the repository due to licensing and distribution restrictions.

You must provide this file yourself. The `pkgs/kace-ampagent/default.nix` uses `requireFile` to locate it based on its filename and SHA256 hash.

Follow these steps to make the tarball available to Nix:

1.  **Download the Agent Tarball:**
    Obtain the `ampagent-<version>.ubuntu.64.tar.gz` file from your KACE SMA portal. The exact filename and version are specified within `pkgs/kace-ampagent/default.nix`.

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

3. **Enable and configure the agent** (see Module Options below). Do **not** set `services.kace-ampagent.package` unless you have a specific reason: the default package comes from the overlay and is built with the same nixpkgs as the rest of your system, which avoids glibc mismatches and keeps your config independent of `inputs.kace-ampagent` in scope.

```nix
services.kace-ampagent = {
  enable = true;
  host = "kbox.example.com";
  # ampConf = { ... };  # optional
};
```

You do not need to reference `kace-ampagent` in your flake `outputs` or `specialArgs`; the module is self-contained once imported.

## Local Build

To build the package or test the flake locally (after providing the tarball as described above):

```bash
nix build .#kace-ampagent
```

## Module Options

-   `services.kace-ampagent.enable`: Enable the KACE AMP Agent (boolean, default `false`). When enabled, the following systemd services are started:
    -   `kace-ampagent-initial-config`: One-time service that runs `konea -url` and `konea -enable` to enroll the agent with the server
    -   `kace-ampagent-setup`: Creates the `amp.conf` configuration file with the host and optional settings
    -   `konea`: Main KACE agent service that runs `konea -start` as a daemon
    -   `kschedulerconsole`: Scheduler console service that starts after konea
    -   `ampwatchdog` (optional): Standalone watchdog service when `enableWatchdog = true`
-   `services.kace-ampagent.package`: The Nix package providing the KACE agent binaries (package, default: `pkgs.kace-ampagent` from the overlay). Leave unset so the module builds the package with your system's nixpkgs; override only if you need a different source.
-   `services.kace-ampagent.dataDir`: The directory where the agent stores its data (string, default `/var/quest/kace`).
-   `services.kace-ampagent.logDir`: The directory where the agent stores its logs (string, default `/var/log/quest/kace`).
-   `services.kace-ampagent.environment`: An attribute set of extra environment variables for the agent (attrset, default `{}`).
-   `services.kace-ampagent.linkOptPath`: Create a `/opt/quest/kace` symlink pointing to the package content for compatibility (boolean, default `true`).
-   `services.kace-ampagent.host`: The KACE SMA host (string, required). Written to `amp.conf` as `host=`.
-   `services.kace-ampagent.ampConf`: An attribute set of additional key-value pairs for `amp.conf` (attrset, default `{}`).
-   `services.kace-ampagent.enableWatchdog`: Enable the standalone `AMPWatchDog` service (boolean, default `false`).

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
  enableWatchdog = true; # Optional: enables AMPWatchDog service
};
```

## Service Behavior and Order

When the module is enabled, the following systemd services are created and run in order:

1. **`kace-ampagent-setup.service`** (oneshot): Creates `/var/quest/kace/amp.conf` with `host=` and any `ampConf` entries

2. **`kace-ampagent-initial-config.service`** (oneshot): Runs once to enroll the agent:
   - Runs `konea -url <host>` to configure the server URL
   - Runs `konea -enable` to enroll the agent and download kbot scripts
   - Creates `/var/quest/kace/.initial-config-done` marker file to prevent re-running

3. **`konea.service`** (simple): Runs `konea -start` as a daemon to connect to the KACE SMA

4. **`kschedulerconsole.service`** (simple): Runs `KSchedulerConsole` (depends on konea)

5. **`ampwatchdog.service`** (simple, optional): Runs `AMPWatchDog` when `enableWatchdog = true`

6. **`konea-checker.timer`** and **`konea-checker.service`** (optional): Periodic health checks when `enableWatchdog = true`

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

-   **Initial enrollment is automatic**: When you first enable the module, `konea -enable` runs automatically during the initial configuration. This enrollment connects the agent to your KACE SMA and downloads kbot scripts. You do not need to run this manually.

-   When running `konea` or `runkbot` manually, ensure PATH includes `killall` (psmisc) and `true` (coreutils). The systemd services automatically add these to PATH; for manual runs, use `sudo systemctl start konea` or add them manually.

-   The agent logs to `/var/log/quest/kace/`. You can view logs with `journalctl -u konea.service`.

-   The `amp.conf` file is created at `/var/quest/kace/amp.conf` with the host and any additional `ampConf` settings.

-   Depending on your KACE SMA configuration and agent version, you may need to perform a manual enrollment step after the services start to fully configure the agent. The initial configuration service handles this automatically via `konea -enable`.