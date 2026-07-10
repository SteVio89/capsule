{
  description = "capsule — run coding agents in a container, on a VM, on a git replica";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = self.packages.${system}.capsule;

          capsule = pkgs.stdenvNoCC.mkDerivation {
            pname = "capsule";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              runHook preInstall
              # `capsule image` sends this tree to the VM as the podman build context,
              # so it has to keep the repo layout: bin/ container/ share/.
              mkdir -p $out/libexec/capsule
              cp -r bin container share $out/libexec/capsule/
              install -Dm755 bin/capsule $out/bin/capsule
              wrapProgram $out/bin/capsule \
                --set-default CAPSULE_SRC $out/libexec/capsule \
                --set-default CAPSULE_SHARE $out/libexec/capsule/share \
                --prefix PATH : ${
                  pkgs.lib.makeBinPath (
                    with pkgs;
                    [ git curl jq coreutils gnused gawk gnutar gzip findutils ]
                    ++ lib.optionals stdenv.isDarwin [ qemu butane xz ]
                  )
                }
              runHook postInstall
            '';

            meta = {
              description = "Run coding agents in a container, on a VM, on a git replica";
              mainProgram = "capsule";
              platforms = systems;
            };
          };
        }
      );

      homeModules.default =
        { pkgs, ... }:
        {
          home.packages = [ self.packages.${pkgs.stdenv.hostPlatform.system}.capsule ];
        };

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [ shellcheck butane qemu jq ];
          };
        }
      );
    };
}
