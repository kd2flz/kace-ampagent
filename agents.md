# kace-ampagent - Agent Documentation

Factual documentation for AI agents and developers working on this repository.
Everything here is derived from source code, README.md, git history, or public
NixOS/Quest KACE references. Sections are labeled by verification source.
This file is ASCII-only by design (some model tokenizers choke on Unicode box
drawing characters).

Repository: https://github.com/kd2flz/kace-ampagent (remote `origin`)
License: unfree (Quest proprietary). Platforms: x86_64-linux only.
Maintainer: David Rhoads.

---

## 1. Repository Layout

```
kace-ampagent/
|-- flake.nix                          # Flake: overlay + packages + nixosModule
|-- modules/services/kace-ampagent.nix # NixOS module
|-- pkgs/kace-ampagent/default.nix     # Package derivation
|-- README.md                          # User-facing docs
|-- agents.md                          # This file
`-- .github/workflows/build-kace-ampagent.yml  # CI
```

Branches: `main`, `dev`, `call-konea-directly`. Development happens on `dev`
and is merged to `main` via PRs (merge commits reference PRs from forks such
as kd2hbv/dev).

---

## 2. Flake Interface [code: flake.nix]

- Input: `nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11"`.
- Systems: `[ "x86_64-linux" ]`.
- `overlays.default`: adds `pkgs.kace-ampagent` via `final.callPackage ./pkgs/kace-ampagent { }`.
- `packages.<system>.default` / `.kace-ampagent`.
- `packages.<system>.kace-ampagent-env`: env-aware variant. Reads
  KACE_TARBALL_URL via builtins.getEnv wrapped in tryEval; when the variable
  is set AND evaluation is impure (`--impure`), it builds with
  `url = $KACE_TARBALL_URL` (fetchurl path). Otherwise it is identical to
  kace-ampagent (requireFile). Intended for CI.
- `nixosModules.kace-ampagent`: imports the module file and injects
  `nixpkgs.overlays = [ self.overlays.default ]`, so `pkgs.kace-ampagent`
  resolves inside consumer configs without extra wiring.
- The flake's own pkgs import sets `config.allowUnfree = true`.

---

## 3. Package [code: pkgs/kace-ampagent/default.nix]

Current version: **15.1.45** (bumped from 15.0.54 on 2026-08-23).
Tarball name pattern: `ampagent-<version>.ubuntu.64.tar.gz`.

### Source acquisition (two mutually exclusive paths)

The derivation accepts an optional `url ? null` parameter:

- `url != null`: source = `fetchurl { inherit url; sha256 = ...; }`.
  Enables pure builds; no manual store step.
- `url == null` (default): source = `requireFile { name; sha256; message; }`.
  User must download the tarball and run
  `nix store add-file ./ampagent-<version>.ubuntu.64.tar.gz`.

SHA256 (both paths): `sha256-nkCcTIKybOJCytZzYXrrkjW6KK3pPa02z/oBLEW0hB0=`

Note: the tarball URL is treated as semi-sensitive; it is supplied per-deployment
via `packageUrl` or the KACE_TARBALL_URL CI secret and is deliberately not
recorded in this repository (including git history - see scrub commit).

Official agent download procedure (Quest KB):
https://support.quest.com/kb/4272341/how-to-find-and-install-the-generic-linux-agent-for-sma

### Build steps (installPhase)

- `dontUnpack = true`; manual tar extraction into a temp dir.
- Requires `opt/` at archive top level; copies it to `$out/opt/`. Errors out
  with an archive listing if missing.
- Installs a minimal LSB `init-functions` stub at
  `$out/opt/quest/kace/lib/lsb/init-functions` (NixOS has no /lib/lsb) and
  rewrites `/lib/lsb/init-functions` references in bin/* scripts to point at it.
- Injects psmisc/coreutils into PATH of `AMPctl` and `AMPAgentBootup`.
- Rewrites hardcoded `/bin/true` to `true` (PATH lookup) across bin/*.
- Removes `2> /dev/null` stderr suppression in `AMPctl`/`AMPAgentBootup` so
  startup errors reach journalctl.
- Creates `$out/bin` symlinks: AMPctl, AMPAgentBootup, konea.

### Dependencies

nativeBuildInputs: autoPatchelfHook, makeWrapper.
buildInputs: stdenv.cc.cc.lib, stdenv.cc.libc (glibc), psmisc, coreutils.

Output layout:

```
$out/bin/{AMPctl,AMPAgentBootup,konea} -> ../opt/quest/kace/bin/*
$out/opt/quest/kace/bin/               # konea, KSchedulerConsole, AMPWatchDog,
                                       # AMPHealthCheck, runkbot, AMPctl, ...
$out/opt/quest/kace/lib/lsb/init-functions
```

---

## 4. NixOS Module [code: modules/services/kace-ampagent.nix]

Namespace: `services.kace-ampagent.*`. Everything below only applies when
`enable = true` (config block wrapped in `mkIf cfg.enable`).

### Options

| Option | Type | Default | Notes |
|---|---|---|---|
| enable | bool | false | mkEnableOption |
| package | package | pkgs.kace-ampagent | From overlay |
| packageUrl | nullOr str | null | NEW 2026-08-23: when non-null, module uses pkgs.kace-ampagent.override { url = cfg.packageUrl; } instead of cfg.package |
| user | str | "root" | Service user |
| group | str | "root" | Service group |
| dataDir | str | "/var/quest/kace" | amp.conf lives here |
| logDir | str | "/var/log/quest/kace" | Log directory |
| host | str | (no default) | Written to amp.conf as host= |
| name | str | config.networking.hostName | Machine name reported to KBOX (name= key) |
| ampConf | attrsOf str | {} | Extra key=value lines for amp.conf |
| environment | attrsOf str | {} | Extra env vars; PATH gets special handling below |
| linkOptPath | bool | true | tmpfiles symlink /opt/quest/kace -> package |
| enableWatchdog | bool | false | Enables the two timers described below |

Effective package binding:

```
kacePackage = if cfg.packageUrl != null
              then pkgs.kace-ampagent.override { url = cfg.packageUrl; }
              else cfg.package;
```

All binary paths use `${kacePackage}/opt/quest/kace/bin`.

### PATH construction (critical; rationale from code comments)

`kacePath = lib.makeBinPath [...]` over 15 packages: coreutils, bash, psmisc,
gnugrep, gnused, gawk, findutils, inetutils, procps, util-linux, iproute2,
systemd, pciutils, networkmanager.

Why so many: konea does not sanitise PATH; its spawn chain (konea -> KPlugins
-> runkbot -> KBoxClient -> KInventory) inherits it. Missing lscpu produced
~4.5KB inventory documents reporting 0 CPUs which the SMA silently discards
(HTTP 200 with empty body; only symptom: Last Inventory never advances). With
the tools present, inventories are ~33.8KB. Verified in-repo 2026-08-14. Tools
must be on THIS PATH; /usr/bin FHS symlinks alone do not work because the
spawn PATH has no /usr/bin.

If the user sets `environment.PATH`, it is appended after kacePath. All other
environment attrs become Environment= entries on every service.

### amp.conf management (two mechanisms)

1. Activation script `system.activationScripts.kace-ampconf` (runs at system
   activation): ensures dataDir exists and amp.conf exists, then upserts keys:
   `host = cfg.host`, `name = cfg.name`, plus every cfg.ampConf pair.
   Upsert = sed replace-in-place if key exists, else append line.
2. ExecStartPost on konea.service runs `ampConfPatchScript`: sleeps 30s, then
   re-applies `name = cfg.name` plus all cfg.ampConf keys with the same upsert
   logic. Reason: KBOX pushes a fresh amp.conf down shortly after konea
   connects, clobbering locally-set keys; 30s lets that push settle first.
   Note asymmetry: host= is written at activation only; name=/ampConf are
   re-applied post-start.

### FHS compatibility layer (tmpfiles.rules)

Directories: dataDir and logDir, mode 0750 owner cfg.user:cfg.group.

Symlinks (L+ rules):
- /usr/local/bin/hostname, /usr/bin/hostname, /bin/hostname ->
  ${pkgs.inetutils}/bin/hostname (konea hardcodes PATH=/usr/bin:/bin)
- /usr/sbin/dmidecode -> ${pkgs.dmidecode}/bin/dmidecode (hardcoded path in
  KInventory)
- /usr/bin/lspci -> pciutils; /usr/bin/systemctl -> systemd;
  /usr/bin/nmcli -> networkmanager; /usr/bin/lscpu -> util-linux;
  /usr/bin/ip -> iproute2; /usr/bin/lsblk -> util-linux;
  /bin/bash -> bash
- Optional: /opt/quest/kace -> ${kacePackage}/opt/quest/kace when
  linkOptPath = true.

Additionally: `environment.systemPackages = [ pkgs.dmidecode ]`.

Known limitation (code comment): rpm and dpkg-query do not exist on NixOS, so
KACE INSTALLED_SOFTWARE inventory stays empty ("Only RPM and Debian package
systems currently supported!"). Fixing this requires a KACE Custom Inventory
Rule server-side, not a client-side change.

### Services

konea.service (Type=simple daemon):
- ExecStart: bash -c 'PATH=<finalPath> exec <kaceBinDir>/konea'
- after/wants network-online.target; wantedBy multi-user.target
- ExecStartPost: ampConfPatchScript (see above)
- KillSignal SIGTERM; KillMode control-group; RestartSec 5
- Restart = always. Rationale (code comment, observed 2026-08-07): an SMA
  agent-reset tells konea to exit cleanly (exit 0); with on-failure systemd
  ignores clean exits, leaving the agent dead silently until reboot.
- User/Group from cfg; WorkingDirectory dataDir; Environment kaceEnv;
  output to journal.

kschedulerconsole.service (Type=simple):
- ExecStartPre: sleep 10; ExecStart: bash exec KSchedulerConsole
- after + requires konea.service; wants network-online.target
- Restart = always (same clean-exit-on-reset rationale).

### Watchdog (enableWatchdog = true): two timers, NOT long-running services

Design (from code comments): KACE ships AMPWatchDog as periodic cron one-shots
(AMPWatchDogCrontab, KoneaCheckerCrontab inside the package); the module models
this as systemd timers. A watchdog must NOT depend on konea.service - if it
did, it would be stopped whenever konea stops (e.g., agent-reset), which is
exactly the failure it exists to recover from.

ampwatchdog.timer + ampwatchdog.service:
- Timer OnCalendar "*-*-* 03,09,15,21:05:00" (every 6h, matches KACE crontab),
  AccuracySec 1m, Persistent true.
- Service Type=oneshot; ExecStart <kaceBinDir>/AMPWatchDog.

konea-checker.timer + konea-checker.service:
- Timer OnCalendar "*-*-* *:00,10,20,30,40,50:00" (every 10 min, matches
  KoneaCheckerCrontab), AccuracySec 1m, Persistent true.
- Service Type=oneshot; ExecStart = koneaCheckerScript (writeShellScript):
  1. Run <kaceBinDir>/AMPWatchDog -k. AMPWatchDog detects systemd and revives
     konea via systemctl start konea.
  2. If kschedulerconsole.service is not active, systemctl start it.
  Rationale: AMPWatchDog -k does NOT restart KSchedulerConsole, but RESETAGENT
  stops both; konea contains no scheduler logic, so scheduled inventory would
  silently stop. Mirrors KACE's own AMPctl, which starts both together.

Historical note (git history): earlier iterations ran AMPHealthCheck from the
timer and ran ampwatchdog as a long-running service requiring konea; replaced
by the current timer design (commits 6d6443c, cbd1d1c, b41d056).

---

## 5. Usage Examples [derived from option definitions above]

Basic (manual tarball):

```nix
inputs.kace-ampagent.url = "github:kd2flz/kace-ampagent/main";
imports = [ kace-ampagent.nixosModules.kace-ampagent ];
services.kace-ampagent = {
  enable = true;
  host = "kbox.example.com";
};
# plus: nix store add-file ./ampagent-15.1.45.ubuntu.64.tar.gz
```

Pure build via URL:

```nix
services.kace-ampagent = {
  enable = true;
  host = "kbox.example.com";
  packageUrl = "https://your-server.example.com/ampagent-15.1.45.ubuntu.64.tar.gz";
};
```

Fuller example (name override, ampConf, watchdog):

```nix
services.kace-ampagent = {
  enable = true;
  host = "kbox.example.com";
  name = "web01";
  ampConf = { org = "Default"; };
  environment = { KACE_HTTPS = "true"; };
  enableWatchdog = true;
};
```

---

## 6. Development Workflow [README + CI workflow verified]

Build locally (manual tarball path):

```bash
nix store add-file ./ampagent-15.1.45.ubuntu.64.tar.gz
nix build .#kace-ampagent
```

Run binaries manually:

```bash
./result/opt/quest/kace/bin/konea -help
./result/opt/quest/kace/bin/runkbot <kbot-id> <version>
```

Manual runs need psmisc/coreutils reachable; systemd services add them via
Environment PATH automatically.

CI (.github/workflows/build-kace-ampagent.yml): on push/PR to main,
installs Nix (cachix/install-nix-action@v27, channel nixos-unstable for the
installer's nix_path), then:

1. Warns via ::warning:: if KACE_TARBALL_URL is empty.
2. `nix build --impure .#kace-ampagent-env` - fetches the tarball from
   KACE_TARBALL_URL (repository secret) when set; otherwise falls back to
   requireFile, which fails with an instructive message.
3. Builds a temporary consumer flake that enables services.kace-ampagent and
   builds the full nixosConfiguration toplevel. The temp flake sets
   services.kace-ampagent.host = "kbox.invalid" (host is a required option;
   omitting it broke evaluation) and packageUrl read from KACE_TARBALL_URL.
   Built with `--impure` so getEnv resolves.

Secret setup: repository Settings -> Secrets and variables -> Actions ->
New repository secret, name KACE_TARBALL_URL, value = publicly reachable
tarball URL. Caveat: GitHub does not pass secrets to pull requests opened
from forks; same-repo branches and pushes get them.

---

## 7. Troubleshooting [each item traced to code]

| Symptom | Cause (verified where) | Resolution |
|---|---|---|
| Build error: expected opt/ inside archive | installPhase check in default.nix | Verify tarball layout/version |
| requireFile error at eval time | Tarball not in store | nix store add-file, or set packageUrl |
| Hash mismatch on fetchurl | URL serves different bytes | Re-hash and update sha256 in default.nix |
| konea reports hostname as error string | dangling hostname symlink (git 939c04f/7d1b259) | Fixed by direct store-path symlinks; verify tmpfiles rules applied |
| Last Inventory never advances, no visible errors | 0-CPU inventory discarded by SMA (module comment) | Ensure kacePath tools present; check journal for konea-checker activity |
| Agent dies hours after SMA agent-reset | clean exit + Restart=on-failure (old behavior) | Fixed: Restart=always; ensure you are on current module |
| name= keeps reverting | KBOX config push clobbers amp.conf | Handled by ampConfPatchScript; check konea.service ExecStartPost logs |
| INSTALLED_SOFTWARE empty | no rpm/dpkg-query on NixOS (module comment) | Server-side Custom Inventory Rule required |

---

## 8. Version History [git history]

- 15.0.54: initial packaged version (requireFile only).
- 2026-08-23 (uncommitted work on dev): version bump to 15.1.45, optional
  `url` parameter added to package (fetchurl path), new module option
  `services.kace-ampagent.packageUrl`, agents.md created.

---

## 9. External References [public URLs]

- Quest KB: generic Linux agent download
  https://support.quest.com/kb/4272341/how-to-find-and-install-the-generic-linux-agent-for-sma
- NixOS modules: https://nixos.org/manual/nixos/stable/index.html#ch-modules
- Nix fetchurl: https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-fetchurl.html
- Nixpkgs requireFile: https://nixos.org/manual/nixpkgs/stable/#sec-file-requirements
- systemd.service: https://www.freedesktop.org/software/systemd/man/systemd.service.html

---

## 10. Known Documentation Drift (README vs code)

The README describes two one-shot services that do NOT exist in any version
of modules/services/kace-ampagent.nix checked into git:

- kace-ampagent-setup.service
- kace-ampagent-initial-config.service (and its .initial-config-done marker)

Actual behavior: amp.conf is managed by the activation script + ExecStartPost
patch script (section 4); enrollment happens through normal konea operation.
Do not rely on those service names when debugging. Consider updating README.
