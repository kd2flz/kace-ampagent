{
  description = "Quest KACE AMP Agent package and NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
      ];
      kaceOverlay = final: prev: {
        kace-ampagent = final.callPackage ./pkgs/kace-ampagent {
          src = ./ampagent-14.1.19.ubuntu.64_kbox.ccistack.com+ouFKd-xkTi_AYkT-YyLvu1G5MJr2lAxJG6MqxDGLPvQp-vVWBOGcUQ.deb;
        };
      };
    in
    {
      overlays.default = kaceOverlay;

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
            };
            overlays = [ kaceOverlay ];
          };
        in
        {
          kace-ampagent = pkgs.kace-ampagent;
        }
      );

      nixosModules.kace-ampagent = {
        imports = [ ./modules/services/kace-ampagent.nix ];
        nixpkgs.overlays = [ kaceOverlay ];
      };

    };
}
