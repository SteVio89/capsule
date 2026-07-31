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

          # The daemon, the MCP endpoint and the TUI, in one binary. Host-only: the
          # container reaches it over the tunnel and never runs it, so it is deliberately
          # absent from the image's build context (bin container share, below).
          #
          # Pinned to zig_0_16 rather than `zig`, which is an alias that will roll to 0.17
          # the week it lands. The opposite of the image's weekly re-lock, on purpose.
          capsuled = pkgs.stdenv.mkDerivation {
            pname = "capsuled";
            version = "0.1.0";
            src = ./.;

            # zig's setup hook supplies configure/build/check/install phases. doCheck is
            # what actually runs zigCheckPhase (`zig build test`) inside the sandbox —
            # mkDerivation defaults it off, and without it the "works in the devshell,
            # breaks in the derivation" class goes uncaught despite the CI comment
            # promising otherwise.
            nativeBuildInputs = [ pkgs.zig_0_16 pkgs.pkg-config ];
            buildInputs = [ pkgs.sqlite ];
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
                    # fzf is a hard dependency: every command that takes an id also accepts
                    # none and opens a picker instead.
                    [ git curl jq fzf coreutils gnused gawk gnutar gzip findutils ]
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

          # A long-lived user service, not something a command starts on demand. The
          # daemon has to be up before the VM exists and has to survive `vm destroy`, and
          # it holds the ssh master and the reverse tunnel for the VM's whole lifetime.
          #
          # `capsule daemon start` drives whichever of these is installed, and falls back
          # to a plain background process when neither is — so `nix run` still works.
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
              shellcheck butane qemu jq fzf
              zig_0_16 zls pkg-config
            ];
            buildInputs = [ pkgs.sqlite ];
          };
        }
      );
    };
}
