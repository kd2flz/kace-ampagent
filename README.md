# KACE AMP Agent - Nix Package and NixOS Module

## Module Structure
- Module: `modules/services/kace-ampagent.nix`
- Package: `pkgs/kace-ampagent/default.nix`

## Local .deb file
Place your vendor-provided `.deb` in the repo root and keep the filename in `flake.nix` in sync:
- `ampagent-14.1.19.ubuntu.64_kbox.ccistack.com+ouFKd-xkTi_AYkT-YyLvu1G5MJr2lAxJG6MqxDGLPvQp-vVWBOGcUQ.deb`

If you rename the file, update the `src = ./<file>.deb;` line in `flake.nix`.

## How to Use (NixOS Config with Flakes)
In your system flake, add this flake as an input and use the exported module and package. Example snippet for `flake.nix` in your system repo:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  kaceAgent.url = "github:your-org/kace-ampagent/main";
};

outputs = { self, nixpkgs, kaceAgent, ... }:
{
  nixosModules = {
    myHost = import ./configuration.nix; # typical usage
  };

  # In your configuration.nix or modules list:
  # imports = [ kaceAgent.nixosModules.kace-ampagent ];

  # Then configure options:
  # services.kace-ampagent.enable = true;
  # services.kace-ampagent.package = kaceAgent.packages.x86_64-linux.kace-ampagent;
}
```

## Local Build
- Build the package or test the flake locally:
  `nix build .#packages.x86_64-linux.kace-ampagent`

## Module Options
- `services.kace-ampagent.enable` : enable service
- `services.kace-ampagent.package` : package providing the binary (defaults to `pkgs.kace-ampagent`)
- `services.kace-ampagent.execPath` : path to the ampagent binary (default `${package}/bin/ampagent`)
- `services.kace-ampagent.extraArgs` : extra args passed to ampagent
- `services.kace-ampagent.dataDir` : data dir (default `/var/quest/kace`)
- `services.kace-ampagent.logDir` : log dir (default `/var/log/quest/kace`)
- `services.kace-ampagent.environment` : extra environment variables (e.g., `KACE_HOST`, `KACE_TOKEN`)
- `services.kace-ampagent.linkOptPath` : create `/opt/quest/kace` symlink to the package content (default `true`)

### Example
```nix
services.kace-ampagent = {
  enable = true;
  environment = {
    KACE_HOST = "kbox.example.com";
    KACE_TOKEN = "your-enroll-token";
  };
  # If the agent expects to run from /opt/quest/kace, use:
  # execPath = "/opt/quest/kace/bin/ampagent";
  # Some agent builds require an explicit "start" argument:
  # extraArgs = [ "start" ];
};
```

## Notes
- The KACE agent commonly expects files under `/opt/quest/kace`. The module creates a symlink to the package content by default for compatibility.
- Because vendor `.deb` installers often perform post-install steps, you may need to adjust `extraArgs` or run a manual enrollment command if your environment requires it.
