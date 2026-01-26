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

In your system flake, add this flake as an input and use the exported module and package. Example snippet for `flake.nix` in your system repo:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11"; # Or your desired Nixpkgs channel
  kace-ampagent.url = "github:kd2flz/kace-ampagent/main"; # Or your fork/branch
};

outputs = { self, nixpkgs, kace-ampagent, ... }:
{
  nixosModules = {
    myHost = import ./configuration.nix; # typical usage
  };

  # In your configuration.nix or modules list, import the module:
  # imports = [ kace-ampagent.nixosModules.kace-ampagent ];

  # Then configure options (see Module Options below):
  # services.kace-ampagent.enable = true;
  # services.kace-ampagent.package = kace-ampagent.packages.x86_64-linux.kace-ampagent;
};
```

## Local Build

To build the package or test the flake locally (after providing the tarball as described above):

```bash
nix build .#kace-ampagent
```

## Module Options

-   `services.kace-ampagent.enable`: Enable the KACE AMP Agent service (boolean, default `false`).
-   `services.kace-ampagent.package`: The Nix package providing the KACE agent binaries (package, defaults to `pkgs.kace-ampagent`).
-   `services.kace-ampagent.execPath`: Path to the `ampagent` binary (string, default `${package}/bin/ampagent`).
-   `services.kace-ampagent.extraArgs`: A list of extra arguments passed to the `ampagent` executable (list of strings, default `[]`).
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
  # If the agent expects to run from /opt/quest/kace, and you've linked it:
  # execPath = "/opt/quest/kace/bin/ampagent";
  # Some agent builds might require an explicit "start" argument:
  # extraArgs = [ "start" ];
};
```

## Notes

-   The KACE agent often expects its files under `/opt/quest/kace`. The module creates a symlink to the package content at `/opt/quest/kace` by default (`services.kace-ampagent.linkOptPath = true;`) for compatibility.
-   Depending on your KACE SMA configuration and agent version, you might need to adjust `extraArgs` or perform a manual enrollment step after the service starts to fully configure the agent.