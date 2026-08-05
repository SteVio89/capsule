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
project. Each run is bound to one issue, and its agent state is built from
scratch every time — the *profile* supplies the login token and the interface
preferences, and nothing else survives from one run to the next.

Your git identity comes along for free: `capsule run start` copies your host's
`user.name` / `user.email` to the VM (once — a VM-side identity you set by hand
wins), and the VM's `~/.gitconfig` is mounted read-only into every container. So
the agent's commits are attributed to you without any per-container `git config`.
Only name and email cross over — not the whole host config, whose commit signing
or credential helpers would only break the agent's commits inside the container.

## Requirements

- [Nix](https://nixos.org/download) with flakes, and [direnv](https://direnv.net) — for the devshell commands
- git, ssh, curl, tar, and [tuicr](https://tuicr.dev) — the Nix package wires them in for
  you. tuicr is what `run review` opens; without it the command falls back to `git log -p`
- **`capsule vm start` only** (Apple Silicon host): qemu, butane, xz.
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

capsule is one binary. `capsule daemon` is the service the rest of it reads from; there is
no separate `capsuled` and no wrapper script. Building it yourself needs only the devshell:

```sh
nix develop --command zig build
ln -s "$PWD/zig-out/bin/capsule" ~/.local/bin/capsule
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

`capsule` on its own opens the board, which is where the loop above is meant to live day
to day. `capsule help` lists every command; down a pipe, a bare `capsule` prints that list
instead, since a dashboard is no use to a script.

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

Omit the id and a picker opens, matching on subsequences so `bord` finds "make the board
useful" without the letters being adjacent. Ids resolve
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

**`capsule board`** — the dashboard (host only), and what a bare `capsule` opens:

Three views. **Overview** is the VM, the issue counts that actually need you (never done
or archived), the running issues by name, memory pressure, containers, and `capsule/*`
branches with commits waiting. **Issues** is the full list, filterable by state with `f`;
`↵` opens an issue's event log — what changed, when, and whether it was you or the agent.
**Runs** is the session history, which draws `ended` and `abandoned` differently on
purpose: the model separates "you quit" from "something broke", and rendering both as
"finished" would discard the only distinction that matters.

`↑↓`/`jk`/`gG`/page keys move, `esc` unwinds one step, `q` quits.

The menu line is the command table, two levels deep — a key per group, then a key per
verb: `i` then `l` for the issue list, `r` then `l` for runs. **The keys are derived from
`cli.zig` rather than hand-maintained**, so a command reaches the board by being added
there, and each key is shown beside its label because `vm` alone has `status`, `ssh`,
`start` and `stop` all wanting `s`.

**Every mutation is a named command.** A verb the board can answer itself switches view;
every other one suspends the board, runs *the same command you could have typed*, and
waits for a keypress before repainting — because a keystroke cannot be piped, scripted,
called from CI, invoked from a direnv hook, or written down in an issue thread, and the
command can.

It reads everything from the daemon in one `board.get` per tick rather than shelling out
on a timer — each of those would be a fresh ssh handshake, and two separate calls would
let the VM panel show a container the issue panel had no run for.

**`capsule doctor`** — check the backlog against its own event log (host only):

`events` is the source of truth; `issues.state` is a cache of replaying it, written by the
event applier and never invalidated. Nothing else checks the two still agree. `doctor`
replays each issue's log and reports only the issues it has something to say about — a
clean row printed beside a corrupt one just buries it.

It exits non-zero for a verdict meaning something is wrong — including `unreadable`, a
column this build cannot decode, which is either corruption or a store written by a newer
capsule. The one exception is `unverifiable`: an issue whose log predates the recorded
target state cannot be replayed either way, which is a fact about history rather than a
fault, and failing on it would make the command useless on any store with a past.

**`capsule daemon`** — the host service everything else reads from:

| | |
|---|---|
| `daemon start` | start it, via the user service if one is installed |
| `daemon stop` | stop it |
| `daemon status` | whether it is up, and what it is holding |

The daemon owns the SQLite store, a polled model of the VM, and the loopback endpoint the
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
| `run end` | end the live run and remove its container, from the host |
| `run reset [--force]` | remove this project from the VM entirely, and the `vm` remote with it |
| `run list` | the project's runs and their states |
| `run push [issue]` | `git push vm HEAD:capsule/<issue-id>` |
| `run fetch` | `git fetch vm` — refs only |
| `run review [issue]` | review the issue's branch in [tuicr](https://tuicr.dev), PR-style |
| `run merge [issue]` | diffstat, confirm, **squash-merge** as one commit, mark the issue done |

Quitting the agent ends the run. The container commits anything still uncommitted, stops
itself, and `run attach` returns to your own shell with a report of what was committed.
Detaching does not do this: `ctrl-b d`, a dropped ssh connection and a closed laptop all
leave the session running, which is what the tmux-inside-the-container arrangement is for.
`run end` is the same thing driven from the host, for a run you do not want to attach to
first.

Nothing is lost by stopping a container — the project directory is a bind mount of the
replica on the VM and outlives it. What a container stop can cost you is *visibility*:
`run merge` reads `HEAD..vm/<branch>` and sees commits only, so an uncommitted tree is
work nobody will be offered. Two things prevent that, and both live in the run's
agent-state directory — see [`src/assets`](src/assets/README.md): a `Stop` hook that will
not let a turn end on a dirty tree, and a handoff script that commits whatever the agent
could not.

When a run dies with its container some other way — a crash, a killed VM — the daemon sees
the container gone and marks the run `abandoned` on its next poll, but only while the VM
answers. If it does not, the run stays `active` and refuses the next `run start`; `run
end` clears it, and needs no VM for that. The issue is left in `in_progress` either way,
and `run start` offers it again — it resumes on the branch it already has. Use `issue
state <id> open` when you are putting the work down rather than picking it back up, so the
backlog reads honestly.

`run reset` is the undo for everything `run start` built outside your working tree: the
replica in the VM, every per-run seed directory, the containers, and the `vm` remote —
which takes `refs/remotes/vm/*` with it. It refuses while the replica still holds a branch
whose issue is not `done`, because a squash merge leaves those commits out of your history
and the replica is the only copy; `run fetch` brings them here first, or `--force` drops
them. The project stays registered with its issues and memories intact, so the next
`run start` simply bootstraps a fresh replica. Agent logins live in the profile, not the
project, and survive. Use it when a replica's tree is wedged, or to take a project off a
shared VM without touching anyone else's — `vm destroy` is the blunt alternative and takes
every project with it.

`run review` opens the branch in [tuicr](https://tuicr.dev) — the whole diff as one
PR-style buffer, with inline comments. Reviewing a revision range needs no GitHub
and no shared remote, so it works on the replica's branches as-is. When the work
isn't ready to merge, leave comments and quit — there is nothing to export. tuicr
persists every review under a session name, so capsule reads the comments back from
there, prints them under that name, and offers to attach them to the issue, where the
agent sees them on its next run. Attaching is a confirmed step, never implicit, and
declining leaves the comments in the session rather than dropping them. Without tuicr
on `PATH` (or with stdout redirected) the command falls back to `git log -p`.

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
| `project rm [--force]` | retire it, and `run reset` with it (`--force` also removes its issues and memories) |

**`capsule login [profile]`** — a container with a terminal to authenticate the agent
CLI in; the stored token is injected into that profile's future runs (host only).

A profile is a directory of one-value files under
`~/.config/capsule/profiles/<name>/`, written by `login` and safe to edit by hand:

| file | default | meaning |
|---|---|---|
| `token` | — | the `claude setup-token` token, injected as `CLAUDE_CODE_OAUTH_TOKEN` |
| `theme` | `dark` | the agent's colour theme |
| `editor-mode` | `vim` | `vim` or `normal` input mode |

`theme` and `editor-mode` are seeded into each run's `.claude.json` along with the
onboarding and trust flags. A run's agent state is built from scratch every time, so
without them the agent would meet the first-run wizard — theme picker, login method,
"do you trust the files in this folder?" — on every single run, with nobody there to
answer it. `login` writes both files once and never overwrites them, so an edit sticks.

## Configuration

Copy [`config.example`](config.example) to `~/.config/capsule/config`. It is `KEY=value`,
with `#` comments and `$VAR` / `${VAR:-default}` expansion — the subset of shell the file
was always written in, now parsed rather than sourced. **The daemon reads it too**, which
it could not when the file was sourced by a shell the daemon never ran. A line the parser
cannot use is reported on stderr rather than dropped. Common knobs:

| variable | default | meaning |
|---|---|---|
| `CAPSULE_VM_HOST` | `core@localhost` | where the agent runs (must be `user@host`) |
| `CAPSULE_VM_PORT` | `2222` | ssh port |
| `CAPSULE_IMAGE` | `ghcr.io/stevio89/capsule:latest` | container image |
| `CAPSULE_MAIN_BRANCH` | auto-detected | branch whose merge re-syncs the replica |
| `CAPSULE_MCP_PORT` | `8765` | loopback port the agent reaches the daemon on |
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

Zig's own runner, plus one bash suite for the daemon's socket and HTTP surface — no VM, no
network, nothing to install beyond the devshell:

```sh
nix develop --command zig build test
nix develop --command sh -c 'zig build && bash test/capsuled-test.sh'   # socket + HTTP
```

The interesting logic is kept in pure functions so it can be tested without a socket, a
database, or a terminal: event replay, the triage/memory buffer parser, prefix resolution,
the world-model probe parser, the HTTP head parser, and the flake rewriting.

Three things are checked by handing them to a real shell, because nothing else can answer
them. The container command is run past a fake `podman` that echoes its argv, proving it
survives exactly one shell parse — split it a second time and the agent gets an unnamed
tmux session with its instructions scattered across arguments. The generated remote scripts
are put through `sh -n`, and their paths through actual expansion, because
`"$HOME/capsule/'name'"` parses perfectly and resolves to the wrong directory.

The ssh tunnel is not covered and is deliberately not mocked — a mocked ssh would only
prove the mock. Tests that need a git repository skip where there is none, so the flake's
`checkPhase` passes in a sandbox that unpacks the source without one.

## License

MIT — see [LICENSE](LICENSE).
