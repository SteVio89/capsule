#!/usr/bin/env sh
# capsule hook: comment-guard
#
#   event:  PostToolUse, matching Write | Edit | MultiEdit
#   stdin:  the hook's JSON payload
#   exit 0: say nothing
#   exit 2: advisory — whatever this prints on stderr is fed back to the agent
#
# Depends only on POSIX sh, jq and curl.
#
# ─────────────────────────────────────────────────────────────────────────────
#  FILL THIS IN — your comment rules go between the EOF markers, one per line.
#  They are printed to the agent verbatim when it adds a comment line.
#
#  Inline them here rather than pointing at a CLAUDE.md: capsule never writes one
#  into your project, so the agent would go looking for a file that is not there.
# ─────────────────────────────────────────────────────────────────────────────
RULES=$(cat <<'EOF'
# your comment rules here, e.g.:
#   - say why, not what; the code already says what
#   - no comment that restates the line below it
EOF
)
# ───────────────────────────────────────────────────────────── END FILL-IN ───

payload=$(cat)

# Gate on the project directory capsule injected: without it the guard fails open.
[ -n "${CAPSULE_PROJECT_DIR:-}" ] || exit 0

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty')
file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')
[ -n "$file" ] || exit 0

case "$tool" in
  Write | Edit | MultiEdit) ;;
  *) exit 0 ;;
esac

# bash and Nix use # for comments, so these fire constantly and never usefully.
case "$file" in
  *.envrc | *.gitignore | *.lock | *.json | *.md) exit 0 ;;
esac

# All three payload shapes: Write, Edit, and MultiEdit's nested edits.
added=$(printf '%s' "$payload" |
  jq -r '[(.tool_input.content // empty),
          (.tool_input.new_string // empty),
          (.tool_input.edits[]?.new_string // empty)] | join("\n")' |
  grep -cE '^[[:space:]]*(#|//|--)' || true)

[ "${added:-0}" -gt 0 ] || exit 0

printf 'comment-guard: %s comment line(s) added to %s\n\n%s\n' "$added" "$file" "$RULES" >&2
exit 2
