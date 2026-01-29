
{ stdenv
, lib
, autoPatchelfHook
, requireFile
, makeWrapper
, ...
}:

let
  version = "15.0.54";
  agentFileName = "ampagent-${version}.ubuntu.64.tar.gz";

  agentSrc = requireFile {
    name = agentFileName;
    sha256 = "sha256-HrJp31TNW605PL7hjsCvjJFLG9PP94ARvomcpybOwDQ=";
    message = ''
      The Quest KACE AMP Agent generic Linux tarball is required but not provided.

      1) Download: ${agentFileName}
      2) Place at: ~/.cache/nixpkgs/files/${agentFileName}
         or run:    nix store add-file ${agentFileName}
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

    # Convenience wrappers
    mkdir -p "$out/bin"
    if [ -x "$out/opt/quest/kace/bin/ampagent" ]; then
      ln -s "$out/opt/quest/kace/bin/ampagent" "$out/bin/ampagent"
    else
      echo "WARNING: ampagent not found at $out/opt/quest/kace/bin/ampagent" >&2
    fi
    if [ -x "$out/opt/quest/kace/bin/konea" ]; then
      ln -s "$out/opt/quest/kace/bin/konea" "$out/bin/konea"
    else
      echo "WARNING: konea not found at $out/opt/quest/kace/bin/konea" >&2
    fi

    echo ">>> [kace-ampagent] installed files (depth 3):"
    find "$out" -maxdepth 3 -print

    # IMPORTANT: reset strict modes so strip/fixup hooks don't choke on nounset
    set +u
    set +o pipefail

    runHook postInstall
  '';

  # 👇 Add the C++ runtime & glibc so autoPatchelf can satisfy libstdc++/libgcc
  buildInputs = [
    stdenv.cc.cc.lib   # provides libstdc++.so.6 and libgcc_s.so.1
    stdenv.cc.libc     # provides glibc and the dynamic loader
  ];

  outputs = [ "out" ];

  meta = with lib; {
    description = "Quest KACE SMA AMP Agent packaged from the generic Linux tarball (requireFile)";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    maintainers = [ "David Rhoads" ];
  };
}
