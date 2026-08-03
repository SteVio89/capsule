# Agent-state assets

Everything here is written into the **run's** agent-state directory when a run starts.
That directory is a copy of the profile's, made at start and discarded at end — so
editing a file *inside a container* changes nothing for the next run. Edit the copies
here, or your own template at `~/.config/capsule/agent-settings.json`.

Nothing here is ever written into your project. That is hard constraint 1: capsule leaves
no trace in the repository or its history.

## What lands where

| written to | from | yours to edit? |
| --- | --- | --- |
| `~/.claude/settings.json` | your template merged with capsule policy | the template, yes |
| `~/.claude/.claude.json` | generated — the MCP server entry | no |

`CLAUDE_CONFIG_DIR=~/.claude` is set in the run container, which is what makes Claude
Code read `.claude.json` from this directory instead of the home root the mount never
touches.
| `~/.claude/hooks/*.sh` | this directory | **yes — see below** |
| `~/.claude/statusline.sh` | this directory | **yes** |
| `~/.claude/INSTRUCTIONS.md` | generated per run | no |

## The fill-in scripts

`hooks/comment-guard.sh` and `statusline.sh` ship as working skeletons with a marked
section:

```sh
# ───────────────────────────────────────────────
#  FILL THIS IN — ...
# ───────────────────────────────────────────────
...your content...
# ─────────────────────────────── END FILL-IN ───
```

Put your own rules and format between the markers. Everything outside them is plumbing —
the stdin contract, the exit codes, the scope check — and is easy to get subtly wrong, so
it is written for you.

`hooks/quality-gate.sh` needs no filling in: it runs `just build` and `just test` when
they exist and no-ops when they do not.

## The contract, if you are changing the plumbing

- **stdin** is the hook's JSON payload. `jq` is available; nothing else is.
- **exit 0** says nothing. **exit 2** feeds stderr back to the agent.
- Hooks gate on `CAPSULE_PROJECT_DIR`, which capsule injects into a *run* container and
  deliberately not into a `capsule login` one. A hook that gates on a hardcoded host path
  fails **open** inside a container — it silently never fires, which is the worst way for
  a guard to be wrong.
- Only POSIX `sh`, `curl`, `jq` and `just` are in the image, and the image re-locks
  nixpkgs weekly. Anything else will eventually stop being there.

## Blocking on `Stop`

Blocking is fine when the condition is something the agent can fix — a failing build, a
failing test — because then it terminates. It is not fine for bookkeeping: an unset issue
status is not something the agent can resolve, so blocking on it loops forever.

Any blocking `Stop` hook needs a re-entry guard. `quality-gate.sh` uses an attempt
counter keyed by session id rather than the usual `stop_hook_active` boolean: the boolean
prevents the loop but never re-runs the check, so the fix is never verified.
