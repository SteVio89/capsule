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
              # zig 0.16 does not create tmp/ before writing a zip dependency there.
              mkdir -p $ZIG_GLOBAL_CACHE_DIR/tmp
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

          # One binary. `capsule daemon` is the service; there is no separate `capsuled`
          # and no shell wrapper. Two packages both installing `bin/capsule` is what the
          # rename of the Zig artifact turned into a buildEnv collision.
          capsule = pkgs.stdenv.mkDerivation {
            pname = "capsule";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.zig_0_16 pkgs.makeWrapper ];
            zigBuildFlags = [ "--system" "${zigDeps}" ];
            zigCheckFlags = [ "--system" "${zigDeps}" ];
            doCheck = true;

            postInstall = ''
              # `capsule image build` ships this tree to the VM as the podman build
              # context, so the repo layout has to survive packaging.
              mkdir -p $out/libexec/capsule
              cp -r bin container share $out/libexec/capsule/
              wrapProgram $out/bin/capsule \
                --set-default CAPSULE_SRC $out/libexec/capsule \
                --prefix PATH : ${
                  pkgs.lib.makeBinPath (
                    with pkgs;
                    # No jq, fzf, awk or sed: the JSON is typed, the picker is native, and
                    # the flake rewriting is Zig. tuicr stays — `run review` spawns it.
                    [ git openssh curl gnutar gzip tuicr ]
                    ++ lib.optionals stdenv.isDarwin [ qemu butane xz ]
                  )
                }
            '';

            meta = {
              description = "Run coding agents in a container, on a VM, on a git replica";
              mainProgram = "capsule";
              platforms = systems;
            };
          };

          # Kept so a configuration that still names `capsuled` evaluates. It is the same
          # derivation, so buildEnv sees one store path rather than a conflict.
          capsuled = self.packages.${system}.capsule;
        }
      );

      homeModules.default =
        { pkgs, lib, ... }:
        let
          system = pkgs.stdenv.hostPlatform.system;
          capsule = self.packages.${system}.capsule;
        in
        {
          home.packages = [ capsule ];

          # A long-lived user service: the daemon outlives `vm destroy` and holds the ssh
          # master and reverse tunnel. `capsule daemon start` drives whichever is present.
          systemd.user.services.capsuled = lib.mkIf pkgs.stdenv.isLinux {
            Unit.Description = "capsule host daemon";
            Service = {
              ExecStart = lib.getExe capsule + " daemon";
              Restart = "on-failure";
              RestartSec = 2;
            };
            Install.WantedBy = [ "default.target" ];
          };

          launchd.agents.capsuled = lib.mkIf pkgs.stdenv.isDarwin {
            enable = true;
            config = {
              Label = "dev.capsule.capsuled";
              ProgramArguments = [ (lib.getExe capsule) "daemon" ];
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
