
{ stdenv
, lib
, autoPatchelfHook
, requireFile
, makeWrapper
, psmisc
, coreutils
, ...
}:

let
  version = "15.0.54";
  agentFileName = "ampagent-${version}.ubuntu.64.tar.gz";

  # Minimal LSB init-functions for NixOS (scripts expect /lib/lsb/init-functions)
  lsbInitFunctions = builtins.toFile "lsb-init-functions" ''
    # Minimal stub for LSB init-functions (NixOS has no /lib/lsb/)
    log_success_msg() { echo "$*"; }
    log_failure_msg() { echo "$*" >&2; }
    log_warning_msg() { echo "$*" >&2; }
    log_begin_msg() { echo "$*"; }
    log_end_msg() { echo "$*"; }
    log_action_begin_msg() { echo "$*"; }
    log_action_cont_msg() { echo "$*"; }
    log_action_end_msg() { echo "$*"; }
    log_daemon_msg() { echo "$*"; }
    log_progress_msg() { echo "$*"; }

    pidofproc() {
      local base="$1"
      local pidfile="''${2:-/var/run/$base.pid}"
      [ -f "$pidfile" ] && cat "$pidfile" || true
    }

    killproc() {
      local pathname="$1"
      local sig="''${2:-TERM}"
      local pidfile=""
      [ "x$1" = "x-p" ] && { pidfile="$2"; shift 2; }
      local base="$(basename "$pathname")"
      local pidf="''${pidfile:-/var/run/$base.pid}"
      [ -f "$pidf" ] && kill -"$sig" "$(cat "$pidf")" 2>/dev/null || true
    }

    start_daemon() {
      local force="" nice="" pidfile="" pathname=""
      while [ "x$1" != "x" ]; do
        case "$1" in
          -f) force=1 ;;
          -n) shift; nice="-n $1" ;;
          -p) shift; pidfile="$1" ;;
          *) pathname="$1"; break ;;
        esac
        shift
      done
      shift
      local base="$(basename "$pathname")"
      local pidf="''${pidfile:-/var/run/$base.pid}"
      if [ -z "$force" ] && [ -f "$pidf" ]; then
        local pid="$(cat "$pidf")"
        [ -d "/proc/$pid" ] 2>/dev/null && return 0
      fi
      nohup "$pathname" "$@" </dev/null >/dev/null 2>&1 &
      echo $! > "$pidf"
    }
  '';

  agentSrc = requireFile {
    name = agentFileName;
    sha256 = "sha256-HrJp31TNW605PL7hjsCvjJFLG9PP94ARvomcpybOwDQ=";
    message = ''
      The Quest KACE AMP Agent generic Linux tarball is required but not provided.

      1) Download: ${agentFileName} - see https://support.quest.com/kb/4272341/how-to-find-and-install-the-generic-linux-agent-for-sma
      2) nix store add-file ${agentFileName}
      3) Re-run:    nix build .#kace-ampagent
    '';
  };
in
stdenv.mkDerivation {
  pname = "kace-ampagent";
  inherit version;

  src = agentSrc;

  nativeBuildInputs = [ autoPatchelfHook makeWrapper ];

  # The archive has multiple top-level entries; skip default unpacker.
  dontUnpack = true;

  installPhase = ''
    set -euo pipefail
    runHook preInstall

    echo ">>> [kace-ampagent] installPhase: extracting from $src"

    mkdir -p "$out"
    workdir="$(mktemp -d)"

    case "$src" in
      *.tar.gz|*.tgz) tar -xzvf "$src" -C "$workdir" ;;
      *.tar)          tar -xvf  "$src" -C "$workdir" ;;
      *) echo "ERROR: Unknown archive format: $src" >&2; exit 1 ;;
    esac

    # Expect 'opt/' at the top level after extraction
    if [ -d "$workdir/opt" ]; then
      mkdir -p "$out/opt"
      cp -r "$workdir/opt/"* "$out/opt/"
    else
      echo "ERROR: expected 'opt/' inside the archive but did not find it." >&2
      echo "Archive top-level contents:" >&2
      ls -la "$workdir" >&2
      exit 1
    fi

    # Provide LSB init-functions (scripts expect /lib/lsb/init-functions on Debian/Ubuntu)
    mkdir -p "$out/opt/quest/kace/lib/lsb"
    cp ${lsbInitFunctions} "$out/opt/quest/kace/lib/lsb/init-functions"

    # Patch scripts to source init-functions from package instead of /lib/lsb
    for f in "$out/opt/quest/kace/bin"/*; do
      if [ -f "$f" ] && grep -q '/lib/lsb/init-functions' "$f" 2>/dev/null; then
        substituteInPlace "$f" --replace-warn '/lib/lsb/init-functions' '"$(dirname "$0")/../lib/lsb/init-functions"'
      fi
    done
    # Ensure killall (psmisc) and true (coreutils) are on PATH when scripts run (manual or systemd)
    for f in "$out/opt/quest/kace/bin/AMPctl" "$out/opt/quest/kace/bin/AMPAgentBootup"; do
      [ -f "$f" ] || continue
      sed -i '1a export PATH="'${psmisc}'/bin:'${coreutils}'/bin:$PATH"' "$f"
    done
    # NixOS has no /bin/true; use true from PATH (coreutils in service Environment)
    for f in "$out/opt/quest/kace/bin"/*; do
      if [ -f "$f" ] && grep -q '/bin/true' "$f" 2>/dev/null; then
        substituteInPlace "$f" --replace-warn '/bin/true' 'true'
      fi
    done
    # Stop hiding konea/KSchedulerConsole stderr so startup errors show in journalctl (use sed to avoid shell parsing "2>")
    for f in "$out/opt/quest/kace/bin/AMPctl" "$out/opt/quest/kace/bin/AMPAgentBootup"; do
      [ -f "$f" ] || continue
      sed -i 's#2> /dev/null || true#|| true#g' "$f"
    done

    # Convenience wrappers (generic Linux tarball uses AMPctl/AMPAgentBootup, not ampagent)
    mkdir -p "$out/bin"
    if [ -x "$out/opt/quest/kace/bin/AMPctl" ]; then
      ln -s "$out/opt/quest/kace/bin/AMPctl" "$out/bin/AMPctl"
    fi
    if [ -x "$out/opt/quest/kace/bin/AMPAgentBootup" ]; then
      ln -s "$out/opt/quest/kace/bin/AMPAgentBootup" "$out/bin/AMPAgentBootup"
    fi
    if [ -x "$out/opt/quest/kace/bin/konea" ]; then
      ln -s "$out/opt/quest/kace/bin/konea" "$out/bin/konea"
    fi

    echo ">>> [kace-ampagent] installed files (depth 3):"
    find "$out" -maxdepth 3 -print

    # IMPORTANT: reset strict modes so strip/fixup hooks don't choke on nounset
    set +u
    set +o pipefail

    runHook postInstall
  '';

  # Runtime: killall (psmisc), true (coreutils); build: C++ runtime & glibc for autoPatchelf
  buildInputs = [
    stdenv.cc.cc.lib
    stdenv.cc.libc
    psmisc      # killall - used by AMPctl/AMPAgentBootup
    coreutils   # true - used by AMPctl/AMPAgentBootup
  ];

  outputs = [ "out" ];

  meta = with lib; {
    description = "Quest KACE SMA AMP Agent packaged from the generic Linux tarball (requireFile)";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    maintainers = [ "David Rhoads" ];
  };
}
