#!/usr/bin/env sh
# capsule: session handoff
#
# The last command in the container's tmux session. When it returns the session ends and
# the container with it, so this is the final chance to make the work reachable.
#
# Reachable, not safe: the project directory is a bind mount of the replica on the VM and
# survives the container either way. What does not survive is visibility — `capsule run
# merge` reads `HEAD..vm/<branch>` and sees commits only, so an uncommitted tree is work
# nobody will ever be offered.
#
# Normally a no-op. commit-gate.sh holds the agent to a clean tree at the end of every
# turn, so what reaches this is what the agent could not commit itself: a crash, an
# interrupted turn, a session killed mid-edit. The message is flat on purpose — there is
# nobody left to say what the change was for, and a generated guess would read like an
# account of work that was never finished.
#
# Depends only on POSIX sh and git.

# Written to the run's agent-state mount, which outlives the container: the tmux session
# ends the moment this returns, taking the terminal and everything printed on it. The
# host reads this back after the session closes.
log="$HOME/.claude/handoff.log"

say() {
  printf '%s\n' "$1"
  printf '%s\n' "$1" >> "$log"
}

: > "$log" 2>/dev/null || log=/dev/null

[ -n "${CAPSULE_PROJECT_DIR:-}" ] || exit 0
cd "$CAPSULE_PROJECT_DIR" 2>/dev/null || {
  say "capsule: $CAPSULE_PROJECT_DIR is gone — nothing to commit"
  exit 0
}
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

if [ -z "$(git status --porcelain)" ]; then
  say "capsule: working tree clean — the agent committed its work"
  exit 0
fi

if ! git config --get user.email >/dev/null 2>&1; then
  say "capsule: uncommitted changes, and no git identity to commit them with."
  say "         they are still in the replica — 'capsule vm ssh' to reach them."
  exit 0
fi

say "capsule: the agent left uncommitted changes:"
git status --short | head -40 | while IFS= read -r line; do say "  $line"; done

# Exit 0 whatever happens: a container that refuses to stop is the failure this replaced.
if git add -A && git commit -q -m "checkpoint: uncommitted work at session end"; then
  say "capsule: committed as $(git rev-parse --short HEAD) — 'capsule run merge' to review it"
else
  say "capsule: the checkpoint commit failed — the work is still in the replica"
fi
exit 0
