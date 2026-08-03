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
    # The VM, not this whitelist, is the security boundary. Both prefixes because the
    # VM's home path differs per host (/home vs /var/home on FCOS).
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

  # tmux is here rather than on the VM because the connection that breaks is host→VM, so
  # the multiplexer has to be on the far side of it. The seeded scripts may depend on
  # tmux, curl, jq and a POSIX shell only: this image re-locks weekly and the rest drifts.
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
