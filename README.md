# capsule

> [!IMPORTANT]
> **This is a prototype, and it is 100% AI-generated.**
>
> I know that. It is deliberate. Right now I am proving out whether all my ideas
> actually work and — most importantly — whether this supports the way I like to
> work with AI agents. Polish and refactoring come *after* that, not before.

Run coding agents in a container, on a VM, on a git replica.

`capsule` gives an agent (Claude Code, Cursor CLI) a full Linux machine to work
on without giving it your machine. It works on a *copy* of your repository that
lives in a VM, commits to its own branch, and hands the result back to you over
git. Your working tree is never touched; you review and merge the agent's
commits like you would a pull request.

It doubles as a per-project dev-environment manager: `capsule env init/add/rm`
set up and maintain a Nix flake devshell so the same toolchain exists on your
host and inside the capsule.

Commands are noun-verb — `capsule <group> <verb>`. Run `capsule` for the groups,
`capsule <group>` for that group's commands.

## How it works

Three layers of isolation, named by the tagline:

- **git replica** — your repo is pushed to a replica in the VM. The agent
  commits there on a per-issue branch, `capsule/<issue-id>`. Nothing flows back
  until you run `capsule run fetch` / `review` / `merge`. The replica is kept
  with no git remotes at all (checked on every `run start`), which is what keeps
  agent commits from reaching a shared remote — there is nothing configured to
  push to.
- **VM** — the agent runs in a Fedora CoreOS VM (`capsule vm start` boots one
  with qemu on Apple Silicon), or on any Linux box you point `CAPSULE_VM_HOST`
  at.
- **container** — inside the VM, the agent runs in a rootless podman container
  built from a Nix + home-manager image that carries the agent CLIs, direnv,
  ripgrep, git, and friends.

```
your repo ──push──▶ replica in VM ──mount──▶ podman container ──▶ agent
    ▲                    │
    └────── merge ◀── fetch ◀── commits on `capsule/<issue-id>`
```

`capsule run start` wires this up on first use: it creates a `vm` git remote,
bootstraps the replica (`receive.denyCurrentBranch=updateInstead`, so a push
updates the checked-out tree), pushes your current `HEAD` onto the issue's
branch and checks it out there, then starts the container mounted on the
project. Each run is bound to one issue, and its agent state lives in a per-run
copy of the *profile's* state, so two profiles don't share logins or history.

Your git identity comes along for free: `capsule run start` copies your host's
`user.name` / `user.email` to the VM (once — a VM-side identity you set by hand
wins), and the VM's `~/.gitconfig` is mounted read-only into every container. So
the agent's commits are attributed to you without any per-container `git config`.
Only name and email cross over — not the whole host config, whose commit signing
or credential helpers would only break the agent's commits inside the container.

## Requirements

- [Nix](https://nixos.org/download) with flakes, and [direnv](https://direnv.net) — for the devshell commands
- git, ssh, [fzf](https://github.com/junegunn/fzf), [jq](https://jqlang.github.io/jq/),
  [tuicr](https://tuicr.dev) — the Nix package wires fzf, jq and tuicr in for you.
  tuicr is what `run review` opens; without it the command falls back to `git log -p`
- **`capsule vm start` only** (Apple Silicon host): qemu, butane, xz, jq, curl.
  The Nix package wires these into `PATH` for you.

The agent host can be anything reachable over ssh that runs rootless podman.
`capsule vm start` is a convenience for people who don't have a spare Linux box;
point `CAPSULE_VM_HOST` at a real machine and the qemu-only commands (`vm start`,
`stop`, `disk`, `destroy`) refuse rather than pretending to manage it.

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
capsule vm start

# 2. register a project and set up a devshell (registration is explicit — capsule
#    never adopts a directory just because it is a git repo)
cd ~/code/myproject
capsule project add
capsule env init go        # scaffolds flake.nix, .envrc, .gitignore, justfile

# 3. file work and hand it to an agent
capsule issue new "the thing to do"
capsule run start          # pick the issue; replica is bootstrapped on first run
#   ...agent works, commits on `capsule/<issue-id>`...

# 4. bring the work back
capsule run review         # the issue's branch, PR-style in tuicr
capsule run merge          # diffstat, confirm, squash-merge as one commit
```

## Commands

**`capsule env`** — the project's Nix devshell:

| | |
|---|---|
| `env init [lang] [name]` | scaffold `flake.nix`, `.envrc`, `.gitignore`, git repo |
| `env add <pkg>...` | add packages to the devshell flake |
| `env rm <pkg>...` | remove packages |
| `env update` | `nix flake update`, then reload |
| `env reload` | `direnv reload` |

`lang` seeds language packages and a justfile — `go` and `zig` ship in
`share/templates/`.

This is the only group that works inside the capsule as well as on the host —
with the exception of `env init`, which is host-only because scaffolding a
project also registers it with capsule, and a container has no route to that.

**`capsule vm`** — the machine the agent runs on (host only):

| | |
|---|---|
| `vm status` | where the agent host is, and whether it's up |
| `vm ssh [cmd...]` | ssh into it, or run one command there |
| `vm gc` | prune containers/images, collect Nix garbage |
| `vm start` | boot the qemu VM, downloading the disk if needed |
| `vm stop` | power it off (disk is kept) |
| `vm disk` | actual vs virtual size of the VM disk |
| `vm destroy` | delete the VM disk (asks first) |

The last four drive the local qemu VM specifically. When `CAPSULE_VM_HOST` names
a real machine they refuse — that box is not capsule's to boot or erase.
`status`, `ssh` and `gc` work either way.

**`capsule image`** — the container image the agent runs in (host only):

| | |
|---|---|
| `image pull` | pull the published image, dropping the stale nix volume |
| `image build` | build it locally instead, from this checkout |

**`capsule issue`** — the backlog for this project (host only):

| | |
|---|---|
| `issue new <title>` | create one; the body opens in `$EDITOR` |
| `issue list [state]` | every issue, or only those in one state |
| `issue edit [id]` | edit the body in `$EDITOR` |
| `issue rename [id] <title>` | change the title |
| `issue comment [id]` | add a note to the event log |
| `issue state [id] <state>` | set it by hand: `open`, `in_progress`, `blocked`, `ready_for_review` |
| `issue triage` | review everything an agent filed, in one buffer |
| `issue archive [id] -m <reason>` | set it aside, with a reason (reversible) |
| `issue reopen [id]` | bring an archived issue back onto its existing branch |

Omit the id and an fzf picker opens, with the issue body in the preview pane. Ids resolve
by unique prefix, as git resolves a short SHA, so the eight-character form shown by
`issue list` is almost always enough.

Those eight characters come from the *end* of the id, not the start. A UUIDv7 begins with
a millisecond timestamp, so a leading prefix barely changes between issues filed minutes
apart — every issue in a project would have shared a "short id".

`events` is the source of truth and is append-only; the state you see is a cached
replay of it. That is what keeps the record honest: an agent can *claim* completion, but
it cannot erase what happened or rewrite an issue to match what it built. Opening an
issue in the editor and closing it unchanged writes nothing at all.

Titles do not go through the editor — a title is one line, and a malformed edit silently
renaming an issue is a risk that buys nothing.

Triage opens every `proposed` issue in one buffer, `rebase -i` style. Two rules diverge
from `rebase -i` deliberately: the default verb is `keep`, so saving an unread buffer does
nothing; and **a deleted line means keep, not delete** — accidentally removing a line must
never destroy data. A malformed buffer re-opens with the error at the top and your text
intact, rather than half-applying.

**`capsule memory`** — what a fresh agent could not work out for itself (host only):

| | |
|---|---|
| `memory list` | every memory and its state |
| `memory review` | review proposals and prune the active set |
| `memory new` | write one by hand |

Agents propose memories during a run; you review them at merge, or after archiving an
issue — archived issues and abandoned runs are where failed approaches come from, and
they never reach a merge. The cap is **40 active and enforced**: accepting at the cap
requires deactivating one in the same pass. That refusal is the entire reason curation
happens, and a soft cap would make the set a junk drawer.

**`capsule board`** — the dashboard (host only):

VM state, uptime, disk, running containers, and `capsule/*` branches with commits waiting.
`q` quits, `r` refreshes now. It reads everything from the daemon's world model rather
than shelling out to `capsule vm status` on a timer — each of those would be a fresh ssh
handshake, and several per refresh would be slow and flaky.

**It is read-only and stays that way.** Every mutation goes through a CLI command: a
keystroke cannot be piped, scripted, called from CI, invoked from a direnv hook, or
written down in an issue thread.

**`capsule daemon`** — the host service everything else reads from:

| | |
|---|---|
| `daemon start` | start it, via the user service if one is installed |
| `daemon stop` | stop it |
| `daemon status` | whether it is up, and what it is holding |

`capsuled` owns the SQLite store, a polled model of the VM, and the loopback endpoint the
agent talks to. It is a long-lived user service — a systemd user unit on Linux, a launchd
agent on macOS, both installed by the flake's home-manager module — and `daemon start`
falls back to a plain background process when neither is present, so `nix run` still
works. It starts before the VM exists and survives `capsule vm destroy`; a VM-down world
model is a normal state, not an error.

The `env` verbs other than `init` deliberately do not need it, so they keep working inside
a container where there is no socket to talk to.

**`capsule run`** — hand work to an agent and take it back (host only):

| | |
|---|---|
| `run start [issue]` | pick (or name) an issue, start the agent container for it |
| `run attach` | reattach to the live run's tmux session |
| `run end` | end the live run and remove its container |
| `run list` | the project's runs and their states |
| `run push [issue]` | `git push vm HEAD:capsule/<issue-id>` |
| `run fetch` | `git fetch vm` — refs only |
| `run review [issue]` | review the issue's branch in [tuicr](https://tuicr.dev), PR-style |
| `run merge [issue]` | diffstat, confirm, **squash-merge** as one commit, mark the issue done |

When a run dies with its container, the daemon sees the container gone and marks the run
`abandoned` on its next poll — but only while the VM answers. If it does not, the run
stays `active` and refuses the next `run start`; `run end` clears it, and needs no VM for
that. The issue is left in `in_progress` either way, and `run start` offers it again — it
resumes on the branch it already has. Use `issue state <id> open` when you are putting
the work down rather than picking it back up, so the backlog reads honestly.

`run review` opens the branch in [tuicr](https://tuicr.dev) — the whole diff as one
PR-style buffer, with inline comments. Reviewing a revision range needs no GitHub
and no shared remote, so it works on the replica's branches as-is. When the work
isn't ready to merge, leave comments and press `y`: on exit, capsule shows what
you exported and offers to attach it to the issue, where the agent sees it on its
next run. Attaching is a confirmed step, never implicit — quitting without
exporting changes nothing. Without tuicr on `PATH` (or with stdout redirected)
the command falls back to `git log -p`.

The merge is a squash, not `--no-ff`: one commit with a message you author lands
on your branch, and the agent's granular commits stay out of your history.
After a `run merge` into your default branch, `capsule` pushes the result back to
the replica and checks the default branch out there, so the agent's next run is
based on the merge, not the stale tip it committed on. It's best-effort: if the
replica's tree is dirty mid-task the checkout is skipped with a note. Merges into
any other branch leave the replica untouched. Override which branch counts as
"default" with `CAPSULE_MAIN_BRANCH` (otherwise it's auto-detected from
`origin/HEAD`, then `main`/`master`).

**`capsule project`** — registration, which is the explicit barrier (host only):

| | |
|---|---|
| `project add [--profile <name>]` | register `$PWD`'s repository with capsule |
| `project list` | every registered project |
| `project profile <name>` | switch which profile this project's runs use |
| `project rm [--force]` | retire it (`--force` also removes its issues and memories) |

**`capsule login [profile]`** — a container with a terminal to authenticate the agent
CLI in; the stored token is injected into that profile's future runs (host only).

## Configuration

Copy [`config.example`](config.example) to `~/.config/capsule/config`. It is
sourced as a shell script; anything set there overrides the defaults. Common
knobs:

| variable | default | meaning |
|---|---|---|
| `CAPSULE_VM_HOST` | `core@localhost` | where the agent runs (must be `user@host`) |
| `CAPSULE_VM_PORT` | `2222` | ssh port |
| `CAPSULE_IMAGE` | `ghcr.io/stevio89/capsule:latest` | container image |
| `CAPSULE_MAIN_BRANCH` | auto-detected | branch whose merge re-syncs the replica |
| `CAPSULE_MCP_PORT` | `8765` | loopback port the agent reaches `capsuled` on |
| `CAPSULE_POLL_INTERVAL` | `3` | seconds between world-model refreshes |
| `CAPSULE_VM_CPUS` / `CAPSULE_VM_MEM` | `4` / `6144` | VM resources |
| `CAPSULE_DISK_SIZE` | `80G` | VM disk size |

## The image

The container is a `nixos/nix` base with a [home-manager profile](container/home.nix)
for the `agent` user. It is rebuilt weekly by CI and published as a multi-arch
image to `ghcr.io`. No `flake.lock` is committed for the image, so each build
re-locks nixpkgs and ships current agent CLIs — build it yourself with
`capsule image build` if you want to pin.

## Tests

Framework-free bash for the shell side, and Zig's own runner for `capsuled` — no VM, no
network, nothing to install beyond the devshell:

```sh
bash test/capsule-test.sh     # flake rewriting, the command taxonomy, the gating rules
nix develop --command zig build test
nix develop --command sh -c 'zig build && bash test/capsuled-test.sh'   # socket + HTTP
```

The daemon's interesting logic is kept in pure functions so it can be tested without a
socket, a database, or a terminal: event replay, the triage/memory buffer parser, prefix
resolution, the world-model probe parser, and the HTTP head parser. The ssh tunnel is not
covered and is deliberately not mocked — a mocked ssh would only prove the mock.

## License

MIT — see [LICENSE](LICENSE).
