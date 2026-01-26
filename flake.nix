
{
  description = "Quest KACE AMP Agent (generic Linux tarball) packaged for NixOS with a module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs, ... }:
  let
    systems = [ "x86_64-linux" ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ self.overlays.default ];
        };
      in f pkgs
    );
  in
  {
    overlays.default = (final: prev: {
      kace-ampagent = final.callPackage ./pkgs/kace-ampagent { };
    });

    packages = forAllSystems (pkgs: {
      default = pkgs.kace-ampagent;
      kace-ampagent = pkgs.kace-ampagent;
    });

    nixosModules.kace-ampagent = { ... }: {
      imports = [ ./modules/services/kace-ampagent.nix ];
      nixpkgs.overlays = [ self.overlays.default ];
    };
  };
}
