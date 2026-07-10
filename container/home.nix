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

  home.packages = with pkgs; [
    claude-code
    cursor-cli
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
