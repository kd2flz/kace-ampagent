{ stdenvNoCC, lib, dpkg, autoPatchelfHook, makeWrapper, openssl, zlib, curl, util-linux, systemd, gcc, python3, src }:

stdenvNoCC.mkDerivation {
  pname = "kace-ampagent";
  version = "14.1.19";
  inherit src;
  dontUnpack = true;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    openssl      # libcrypto, libssl
    zlib         # libz
    curl         # libcurl
    util-linux   # libuuid, etc.
    systemd      # libsystemd (if the agent links to it)
    gcc.cc.lib   # libstdc++ and libgcc_s
    python3      # ensure `python`/`python3` is in the runtime closure
  ];

  installPhase = ''
    mkdir -p $out
    # Extract the Debian package into $out
    dpkg-deb -x "$src" "$out"

    # Many .deb files put stuff under usr/; flatten that into $out.
    if [ -d "$out/usr" ]; then
      # Move everything from $out/usr/* to $out/
      shopt -s dotglob
      mv $out/usr/* $out/
      rmdir $out/usr || true
      shopt -u dotglob
    fi

    # Some agents install binaries under sbin; ensure they are in bin/
    if [ -d "$out/sbin" ]; then
      mkdir -p $out/bin
      shopt -s nullglob
      mv $out/sbin/* $out/bin/ || true
      shopt -u nullglob
      rmdir $out/sbin || true
    fi

    # Ensure the agent binary is available as $out/bin/ampagent
    if [ ! -x "$out/bin/ampagent" ]; then
      BIN_PATH=$(find "$out" -type f -name ampagent -perm -111 | head -n1 || true)
      if [ -n "$BIN_PATH" ]; then
        mkdir -p $out/bin
        ln -s "$BIN_PATH" $out/bin/ampagent
      fi
    fi

    # Provide a `python` executable for scripts that expect `python`.
    if command -v python3 >/dev/null 2>&1; then
      mkdir -p $out/bin
      ln -sf "$(command -v python3)" "$out/bin/python"
    fi
  '';

  meta = with lib; {
    description = "Quest KACE SMA AMP Agent repackaged from a Debian .deb for Nix/NixOS";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "ampagent";
    maintainers = [ "David Rhoads" ];
  };
}
