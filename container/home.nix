{ pkgs, ... }:

{
  home.username = "agent";
  home.homeDirectory = "/home/agent";
  home.stateVersion = "26.05";

  programs.bash = {
    enable = true;
    shellAliases.agent = "cursor-agent";
  };

  programs.git = {
    enable = true;
    extraConfig.safe.directory = "*";
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    # direnv runs untrusted project code, but the VM — not this whitelist — is the
    # security boundary, so there's no point locking it down. Projects are bind-mounted
    # at the VM's own path, which differs per host user (/home vs /var/home on FCOS).
    config.whitelist.prefix = [ "/home" "/var/home" ];
    stdlib = ''
      declare -A direnv_layout_dirs
      direnv_layout_dir() {
        echo "''${direnv_layout_dirs[$PWD]:=$(
          echo -n "$HOME/.cache/direnv/layouts/"
          echo -n "$PWD" | sha1sum | cut -d ' ' -f 1
        )}"
      }
    '';
  };

  # The whole container-side addition for issue tracking, and deliberately no more:
  #   tmux  holds the agent session so a dropped ssh connection cannot kill it
  #   curl  the status line reaches the host's endpoint through the reverse tunnel
  #   jq    the seeded hooks parse their stdin payload with it
  #
  # tmux lives here rather than on the VM because the connection that breaks is host→VM,
  # so the multiplexer has to be on the far side of it — and the VM is immutable Fedora
  # CoreOS, where layering a package is far more awkward than one line of Nix.
  #
  # Nothing is mounted for issues at all: the agent reaches the store over the tunnel.
  #
  # No flake.lock is committed for this image and CI re-locks weekly, so everything added
  # here drifts. Keep the seeded scripts dependent on these three and a POSIX shell only.
  home.packages = with pkgs; [
    claude-code
    cursor-cli
    tmux
    curl
    jq
    docker-client
    coreutils
    ripgrep
    fd
    gnugrep
    gnused
    gawk
    findutils
    ncurses
    less
    util-linux
    just
  ];
}
