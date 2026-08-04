# Build context is the repo root: podman build -f container/Dockerfile -t capsule-dev .
# Fully qualified because podman on Fedora CoreOS cannot prompt for short-name
# resolution over a non-interactive ssh session.
FROM docker.io/nixos/nix:latest

RUN printf 'experimental-features = nix-command flakes\n' >> /etc/nix/nix.conf

ENV USER=agent \
    HOME=/home/agent \
    PATH=/nix/var/nix/profiles/default/bin:/home/agent/.nix-profile/bin:/usr/local/bin:/bin:/usr/bin \
    CLAUDE_CONFIG_DIR=/home/agent/.claude

RUN mkdir -p /home/agent/.local/state/nix/profiles /usr/local/bin /usr/local/share
WORKDIR /home/agent

COPY container /etc/capsule
RUN sys="$(uname -m)-linux" && \
    nix run github:nix-community/home-manager -- switch --flake "/etc/capsule#$sys" -b backup

# capsule itself, built here rather than copied in. It is a compiled binary now, so a
# `COPY` would need one cross-compiled per architecture on whatever machine ran the build —
# and `capsule image build` runs on a user's machine, which has no zig. The base image
# already has nix, and the source is in the build context, so it can just build it.
#
# `capsule-unwrapped`, not `capsule`: an agent uses the `env` group against its own
# checkout and never the host's ssh, qemu or tuicr, so the wrapper's PATH would add a large
# closure this image has no use for.
COPY build.zig build.zig.zon flake.nix flake.lock config.example /usr/src/capsule/
COPY src /usr/src/capsule/src
# build.zig embeds the devshell templates and the butane config from here, so the build
# needs them even though nothing in the image reads share/ at run time.
COPY share /usr/src/capsule/share
RUN out="$(nix build --no-link --print-out-paths 'path:/usr/src/capsule#capsule-unwrapped')" && \
    install -Dm755 "$out/bin/capsule" /usr/local/bin/capsule && \
    rm -rf /usr/src/capsule && \
    nix-collect-garbage -d >/dev/null 2>&1 || true

ENTRYPOINT ["bash", "-l"]
