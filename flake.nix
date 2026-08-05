{
  description = "capsule — run coding agents in a container, on a VM, on a git replica";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      # Kept equal to build.zig.zon's by a test, which is the only thing that can: nix
      # cannot read it without a regex over the file, and a wrong regex breaks the build
      # rather than a check.
      version = "0.1.0";
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

          # The binary alone. The container image builds this and nothing else: an agent
          # runs `capsule env` against its own checkout and has no use for a host's ssh,
          # qemu or tuicr, so wrapping it there would only enlarge the image.
          capsule-unwrapped = pkgs.stdenv.mkDerivation {
            pname = "capsule-unwrapped";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ pkgs.zig_0_16 ];
            zigBuildFlags = [ "--system" "${zigDeps}" ];
            zigCheckFlags = [ "--system" "${zigDeps}" ];
            doCheck = true;

            meta = {
              description = "capsule, without the host tool PATH";
              mainProgram = "capsule";
              platforms = systems;
            };
          };

          # One binary. `capsule daemon` is the service; there is no separate `capsuled`
          # and no shell wrapper. Two packages both installing `bin/capsule` is what the
          # rename of the Zig artifact turned into a buildEnv collision.
          capsule = pkgs.stdenvNoCC.mkDerivation {
            pname = "capsule";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              runHook preInstall
              # `capsule image build` ships this tree to the VM as the podman build
              # context, so the repo layout has to survive packaging.
              mkdir -p $out/libexec/capsule
              cp -r container share src config.example \
                build.zig build.zig.zon flake.nix flake.lock \
                $out/libexec/capsule/

              makeWrapper ${self.packages.${system}.capsule-unwrapped}/bin/capsule \
                $out/bin/capsule \
                --set-default CAPSULE_SRC $out/libexec/capsule \
                --prefix PATH : ${
                  pkgs.lib.makeBinPath (
                    with pkgs;
                    # No jq, fzf, awk or sed: the JSON is typed, the picker is native, and
                    # the flake rewriting is Zig. tuicr stays — `run review` spawns it.
                    #
                    # Deliberately no openssh. The user's ssh is the right one: on darwin
                    # `UseKeychain` is an Apple extension that upstream OpenSSH refuses
                    # outright, so shadowing /usr/bin/ssh breaks every command that reaches
                    # the VM for anyone whose ~/.ssh/config uses it. capsule passes its own
                    # options explicitly and needs nothing a system ssh lacks.
                    [ git curl gnutar gzip tuicr ]
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
