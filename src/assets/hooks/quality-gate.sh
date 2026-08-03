#!/usr/bin/env sh
# capsule hook: quality-gate
#
#   event:  Stop
#   stdin:  the hook's JSON payload
#   exit 0: let the turn end
#   exit 2: block, and feed stderr back to the agent as the reason
#
# Depends only on POSIX sh, jq and `just`.

payload=$(cat)

# Gate on the project directory capsule injected: without it the hook fails open.
[ -n "${CAPSULE_PROJECT_DIR:-}" ] || exit 0
cd "$CAPSULE_PROJECT_DIR" 2>/dev/null || exit 0

# Re-entry guard: block twice, then let the turn through. A plain stop_hook_active
# boolean prevents the loop but never re-runs the gate, so the fix is never verified.
session=$(printf '%s' "$payload" | jq -r '.session_id // "unknown"')
attempts_file="${TMPDIR:-/tmp}/capsule-gate-$session"
attempts=$(cat "$attempts_file" 2>/dev/null || echo 0)
if [ "$attempts" -ge 2 ]; then
  rm -f "$attempts_file"
  exit 0
fi

command -v just >/dev/null 2>&1 || exit 0
recipes=$(just --summary 2>/dev/null) || exit 0

run_recipe() { # run_recipe <name>
  case " $recipes " in *" $1 "*) ;; *) return 0 ;; esac
  # Bounded: the whole block reason enters the agent's context.
  output=$(just "$1" 2>&1) && return 0
  printf '%s\n' "$output" | tail -100 > "${TMPDIR:-/tmp}/capsule-gate-out"
  lines=$(printf '%s\n' "$output" | wc -l)
  {
    # shellcheck disable=SC2016  # backticks are markdown for the agent, not a subshell
    printf '`just %s` failed. Fix it before ending the turn.\n\n' "$1"
    [ "$lines" -gt 100 ] && printf '(last 100 of %s lines)\n\n' "$lines"
    cat "${TMPDIR:-/tmp}/capsule-gate-out"
  } >&2
  return 1
}

if run_recipe build && run_recipe test; then
  rm -f "$attempts_file"
  exit 0
fi

echo $((attempts + 1)) > "$attempts_file"
exit 2
