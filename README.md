# capsule

Run coding agents in a container, on a VM, on a git replica.

`capsule` gives an agent (Claude Code, Cursor CLI) a full Linux machine to work
on without giving it your machine. It works on a *copy* of your repository that
lives in a VM, commits to its own branch, and hands the result back to you over
git. Your working tree is never touched; you review and merge the agent's
commits like you would a pull request.

It doubles as a per-project dev-environment manager: `capsule init/add/rm` set
up and maintain a Nix flake devshell so the same toolchain exists on your host
and inside the capsule.

## How it works

Three layers of isolation, named by the tagline:

- **git replica** — your repo is pushed to a replica in the VM. The agent
  commits there on the `capsule` branch. Nothing flows back until you run
  `capsule fetch` / `review` / `merge`.
- **VM** — the agent runs in a Fedora CoreOS VM (`capsule vm` boots one with
  qemu on Apple Silicon), or on any Linux box you point `CAPSULE_VM_HOST` at.
- **container** — inside the VM, the agent runs in a rootless podman container
  built from a Nix + home-manager image that carries the agent CLIs, direnv,
  ripgrep, git, and friends.

```
your repo ──push──▶ replica in VM ──mount──▶ podman container ──▶ agent
    ▲                    │
    └────── merge ◀── fetch ◀── commits on `capsule` branch
```

`capsule shell` wires this up on first use: it creates a `vm` git remote,
bootstraps the replica (`receive.denyCurrentBranch=updateInstead`, so a push
updates the checked-out tree), pushes your current `HEAD`, then starts the
container mounted on the project. Per-agent state (`~/.claude`, cursor config)
is kept per *profile*, so `capsule shell work` and `capsule shell experiment`
don't share logins or history.

Your git identity comes along for free: `capsule shell` copies your host's
`user.name` / `user.email` to the VM (once — a VM-side identity you set by hand
wins), and the VM's `~/.gitconfig` is mounted read-only into every container. So
the agent's commits are attributed to you without any per-container `git config`.
Only name and email cross over — not the whole host config, whose commit signing
or credential helpers would only break the agent's commits inside the container.

## Requirements

- [Nix](https://nixos.org/download) with flakes, and [direnv](https://direnv.net) — for the devshell commands
- git, ssh
- **`capsule vm` only** (Apple Silicon host): qemu, butane, xz, jq, curl. The
  Nix package wires these into `PATH` for you.

The agent host can be anything reachable over ssh that runs rootless podman.
`capsule vm` is a convenience for people who don't have a spare Linux box.

## Install

With Nix:

```sh
nix run github:stevio89/capsule -- help
# or add to a profile / home-manager via the flake's `packages.default`
```

Or just symlink the script — it resolves through symlinks to find `share/`:

```sh
ln -s "$PWD/bin/capsule" ~/.local/bin/capsule
```

## Quick start

```sh
# 1. boot a VM (Apple Silicon), or skip this and point CAPSULE_VM_HOST at a Linux box
capsule vm

# 2. in a project under $CAPSULE_ROOT (~/code by default), set up a devshell
cd ~/code/myproject
capsule init go            # scaffolds flake.nix, .envrc, .gitignore, justfile

# 3. hand the project to an agent
capsule shell              # replica is bootstrapped and pushed on first run
#   ...agent works, commits on the `capsule` branch...

# 4. bring the work back
capsule review             # every commit + patch waiting in vm/capsule
capsule merge              # diffstat, confirm, merge --no-ff
```

## Commands

**Project** (host and inside the capsule):

| | |
|---|---|
| `init [lang] [name]` | scaffold `flake.nix`, `.envrc`, `.gitignore`, git repo |
| `add <pkg>...` | add packages to the devshell flake |
| `rm <pkg>...` | remove packages |
| `update` | `nix flake update`, then reload |
| `reload` | `direnv reload` |

`lang` seeds language packages and a justfile — `go` and `zig` ship in
`share/templates/`.

**Capsule** (host only):

| | |
|---|---|
| `shell [profile]` | start the agent container for `$PWD` (default profile: `default`) |
| `vm` | boot the qemu VM, downloading the disk if needed |
| `ssh [cmd...]` | ssh into the VM, or run one command there |
| `size` | show the VM disk's actual vs virtual size |
| `pull` | pull the published image, dropping the stale nix volume |
| `image` | build the image locally instead |
| `gc` | prune containers/images, collect Nix garbage |
| `stop` | power off the VM (disk is kept) |
| `destroy` | delete the VM disk (asks first) |

**Handoff** (host only):

| | |
|---|---|
| `push` | `git push vm HEAD:capsule` |
| `fetch` | `git fetch vm` — refs only |
| `review` | show every commit and patch waiting in `vm/capsule` |
| `merge` | diffstat, confirm, `merge --no-ff` |

## Configuration

Copy [`config.example`](config.example) to `~/.config/capsule/config`. It is
sourced as a shell script; anything set there overrides the defaults. Common
knobs:

| variable | default | meaning |
|---|---|---|
| `CAPSULE_ROOT` | `$HOME/code` | projects must live under this dir |
| `CAPSULE_VM_HOST` | `core@localhost` | where the agent runs (must be `user@host`) |
| `CAPSULE_VM_PORT` | `2222` | ssh port |
| `CAPSULE_IMAGE` | `ghcr.io/stevio89/capsule:latest` | container image |
| `CAPSULE_BRANCH` | `capsule` | branch the agent commits on |
| `CAPSULE_VM_CPUS` / `CAPSULE_VM_MEM` | `4` / `6144` | VM resources |
| `CAPSULE_DISK_SIZE` | `80G` | VM disk size |

## The image

The container is a `nixos/nix` base with a [home-manager profile](container/home.nix)
for the `agent` user. It is rebuilt weekly by CI and published as a multi-arch
image to `ghcr.io`. No `flake.lock` is committed for the image, so each build
re-locks nixpkgs and ships current agent CLIs — build it yourself with
`capsule image` if you want to pin.

## Tests

The flake-rewriting logic (inject / strip / dedup) is covered by a
framework-free script — no VM, no network:

```sh
bash test/capsule-test.sh
```

## License

MIT — see [LICENSE](LICENSE).
