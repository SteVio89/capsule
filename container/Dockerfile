# Build context is the repo root: podman build -f container/Dockerfile -t capsule-dev .
# Fully qualified: podman on Fedora CoreOS enforces short-name resolution and cannot
# prompt over a non-interactive ssh session.
FROM docker.io/nixos/nix:latest

RUN printf 'experimental-features = nix-command flakes\n' >> /etc/nix/nix.conf

ENV USER=agent \
    HOME=/home/agent \
    PATH=/nix/var/nix/profiles/default/bin:/home/agent/.nix-profile/bin:/usr/local/bin:/bin:/usr/bin \
    CLAUDE_CONFIG_DIR=/home/agent/.claude \
    CAPSULE_SHARE=/usr/local/share/capsule

RUN mkdir -p /home/agent/.local/state/nix/profiles /usr/local/bin /usr/local/share
WORKDIR /home/agent

COPY container /etc/capsule
RUN sys="$(uname -m)-linux" && \
    nix run github:nix-community/home-manager -- switch --flake "/etc/capsule#$sys" -b backup

COPY bin/capsule /usr/local/bin/capsule
COPY share /usr/local/share/capsule
RUN chmod +x /usr/local/bin/capsule

ENTRYPOINT ["bash", "-l"]
