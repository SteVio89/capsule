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

          # The build.zig.zon dependency tree. The sandbox has no network, so the build
          # runs with `--system` against this; bump the hash when a dependency changes.
          zigDeps = pkgs.stdenvNoCC.mkDerivation {
            name = "capsuled-zig-deps";
            src = ./.;
            dontConfigure = true;
            dontInstall = true;
            buildPhase = ''
              export HOME=$TMPDIR ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              ${pkgs.lib.getExe pkgs.zig_0_16} build --fetch=all
              mv zig-pkg $out
            '';
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = "sha256-OxmNJSwrnzWUF6DcbjUcTSYcmrc5GAVP3PH4+gcdQEc=";
          };
        in
        {
          default = self.packages.${system}.capsule;

          capsuled = pkgs.stdenv.mkDerivation {
            pname = "capsuled";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.zig_0_16 ];
            zigBuildFlags = [ "--system" "${zigDeps}" ];
            zigCheckFlags = [ "--system" "${zigDeps}" ];
            doCheck = true;

            meta = {
              description = "capsule's host daemon, MCP endpoint, and dashboard";
              mainProgram = "capsuled";
              platforms = systems;
            };
          };

          capsule = pkgs.stdenvNoCC.mkDerivation {
            pname = "capsule";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              runHook preInstall
              # `capsule image` ships this tree to the VM as the podman build context,
              # so the repo layout has to survive packaging.
              mkdir -p $out/libexec/capsule
              cp -r bin container share $out/libexec/capsule/
              install -Dm755 bin/capsule $out/bin/capsule
              wrapProgram $out/bin/capsule \
                --set-default CAPSULE_SRC $out/libexec/capsule \
                --set-default CAPSULE_SHARE $out/libexec/capsule/share \
                --prefix PATH : ${
                  pkgs.lib.makeBinPath (
                    with pkgs;
                    # fzf and tuicr are hard dependencies: the id pickers and `run review`.
                    [ git curl jq fzf tuicr coreutils gnused gawk gnutar gzip findutils ]
                    ++ [ self.packages.${system}.capsuled ]
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
        { pkgs, lib, ... }:
        let
          system = pkgs.stdenv.hostPlatform.system;
          capsuled = self.packages.${system}.capsuled;
        in
        {
          home.packages = [ self.packages.${system}.capsule capsuled ];

          # A long-lived user service: the daemon outlives `vm destroy` and holds the ssh
          # master and reverse tunnel. `capsule daemon start` drives whichever is present.
          systemd.user.services.capsuled = lib.mkIf pkgs.stdenv.isLinux {
            Unit.Description = "capsule host daemon";
            Service = {
              ExecStart = lib.getExe capsuled + " daemon";
              Restart = "on-failure";
              RestartSec = 2;
            };
            Install.WantedBy = [ "default.target" ];
          };

          launchd.agents.capsuled = lib.mkIf pkgs.stdenv.isDarwin {
            enable = true;
            config = {
              Label = "dev.capsule.capsuled";
              ProgramArguments = [ (lib.getExe capsuled) "daemon" ];
              KeepAlive = true;
              RunAtLoad = true;
            };
          };
        };

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              shellcheck butane qemu jq fzf tuicr
              zig_0_16 zls
            ];
          };
        }
      );
    };
}
