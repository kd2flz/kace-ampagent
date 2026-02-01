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

3.  **Make the Tarball Accessible to Nix (Choose ONE method):**

    *   **Method A: Place in Nixpkgs Cache:**
        Place the downloaded tarball in your user's Nixpkgs file cache directory:
        ```bash
        mkdir -p ~/.cache/nixpkgs/files/
        cp ampagent-<version>.ubuntu.64.tar.gz ~/.cache/nixpkgs/files/
        ```

    *   **Method B: Add to Nix Store Directly:**
        Add the file directly to your Nix store using the `nix store add-file` command. This registers the file with Nix, allowing `requireFile` to find it by its content hash:
        ```bash
        nix store add-file ./ampagent-<version>.ubuntu.64.tar.gz
        ```
        (Ensure you are in the directory containing the tarball when running this command.)

Once the tarball is correctly placed or added to the store, Nix will be able to find it during the build process.

## How to Use (NixOS Config with Flakes)

1. **Add this flake as an input** in your system flake (e.g. `flake.nix`):

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11"; # or your channel
  kace-ampagent.url = "github:kd2flz/kace-ampagent/main"; # or your fork/branch
};
```

2. **Import the NixOS module** in your system configuration. The module brings in the service and registers an overlay so `pkgs.kace-ampagent` is built with your system’s nixpkgs (same glibc, no need to pass the flake in `specialArgs`):

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

-   `services.kace-ampagent.enable`: Enable the KACE AMP Agent (boolean, default `false`). When enabled, two systemd services are started: `kace-ampagent-bootup` (AMPAgentBootup) and `kace-ampagent` (AMPctl, which starts konea and AMPWatchDog), matching the generic Linux guidelines.
-   `services.kace-ampagent.package`: The Nix package providing the KACE agent binaries (package, default: `pkgs.kace-ampagent` from the overlay). Leave unset so the module builds the package with your system’s nixpkgs; override only if you need a different source.
-   `services.kace-ampagent.dataDir`: The directory where the agent stores its data (string, default `/var/quest/kace`).
-   `services.kace-ampagent.logDir`: The directory where the agent stores its logs (string, default `/var/log/quest/kace`).
-   `services.kace-ampagent.environment`: An attribute set of extra environment variables for the agent (attrset, default `{}`).
-   `services.kace-ampagent.linkOptPath`: Create a `/opt/quest/kace` symlink pointing to the package content for compatibility (boolean, default `true`).
-   `services.kace-ampagent.host`: The KACE SMA host (string).
-   `services.kace-ampagent.ampConf`: An attribute set of additional key-value pairs for `amp.conf` (attrset, default `{}`).

### Example

```nix
services.kace-ampagent = {
  enable = true;
  host = "kbox.example.com"; # Replace with your KACE SMA host
  ampConf = {
    # Example additional amp.conf settings
    KACE_TOKEN = "your-enroll-token"; # If using token-based enrollment
    # Other settings like CERT_VALIDATION, etc.
  };
};
```

## Notes

-   The KACE agent expects its files under `/opt/quest/kace`. The module creates a symlink to the package content at `/opt/quest/kace` by default (`services.kace-ampagent.linkOptPath = true;`). The services run `/opt/quest/kace/bin/AMPAgentBootup` and `/opt/quest/kace/bin/AMPctl` per the generic Linux guidelines.
-   Depending on your KACE SMA configuration and agent version, you may need to perform a manual enrollment step after the services start to fully configure the agent.