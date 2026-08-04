#!/usr/bin/env sh
# capsule hook: commit-gate
#
#   event:  Stop
#   stdin:  the hook's JSON payload
#   exit 0: let the turn end
#   exit 2: block, and feed stderr back to the agent as the reason
#
# Depends only on POSIX sh, jq and git.
#
# The agent writes the message because only the agent knows what it just did. This runs
# while it is still alive to do that; handoff.sh is the net for the turns that end
# without one.

payload=$(cat)

# Gate on the project directory capsule injected: without it the hook fails open.
[ -n "${CAPSULE_PROJECT_DIR:-}" ] || exit 0
cd "$CAPSULE_PROJECT_DIR" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

session=$(printf '%s' "$payload" | jq -r '.session_id // "unknown"')
attempts_file="${TMPDIR:-/tmp}/capsule-commit-$session"

if [ -z "$(git status --porcelain)" ]; then
  # Cleared here, not only on the give-up path: a session that is let through once and
  # dirties the tree again later has to be blocked again.
  rm -f "$attempts_file"
  exit 0
fi

# Every commit fails without an identity, so blocking on one would never terminate. The
# identity is the VM's ~/.gitconfig, mounted read-only, and absent when the VM has none.
git config --get user.email >/dev/null 2>&1 || exit 0

# quality-gate owns the turn while the build is failing — its attempt counter exists for
# exactly as long as it is still asking for a fix. Prompting for a commit on top of that
# asks the agent to record the breakage.
[ -f "${TMPDIR:-/tmp}/capsule-gate-$session" ] && exit 0

# Re-entry guard: block twice, then let the turn through. An agent that cannot commit
# would otherwise be held here forever, and the work is no safer for it — handoff.sh
# still catches the tree on the way out.
attempts=$(cat "$attempts_file" 2>/dev/null || echo 0)
if [ "$attempts" -ge 2 ]; then
  rm -f "$attempts_file"
  exit 0
fi
echo $((attempts + 1)) > "$attempts_file"

{
  printf 'Uncommitted changes are still in the working tree:\n\n'
  git status --short | head -40
  printf '\nCommit them before ending the turn. The branch is yours and nothing leaves\n'
  printf 'this machine until a human merges it.\n\n'
  printf 'Write the message yourself: one short subject line saying what changed, then\n'
  printf 'a blank line and why, when the why is not obvious from the diff. No trailers,\n'
  printf 'no co-authors, and no mention of what wrote it.\n'
} >&2
exit 2
