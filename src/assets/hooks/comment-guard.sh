#!/usr/bin/env sh
# capsule hook: comment-guard
#
#   event:  PostToolUse, matching Write | Edit | MultiEdit
#   stdin:  the hook's JSON payload
#   exit 0: say nothing
#   exit 2: advisory — whatever this prints on stderr is fed back to the agent
#
# Advisory pressure rather than a block, which is the right severity for a style rule:
# a comment the agent disagrees with should cost it one turn, not trap the session.
#
# Depends only on POSIX sh, jq and curl. Nothing else is in the container image, and the
# image re-locks nixpkgs weekly, so anything more will eventually break.
#
# ─────────────────────────────────────────────────────────────────────────────
#  FILL THIS IN — your comment rules go between the EOF markers, one per line.
#  They are printed to the agent verbatim when it adds a comment line.
#
#  Deliberately not "check these against CLAUDE.md": capsule never writes a
#  CLAUDE.md into your project, so pointing at one would send the agent looking
#  for a file that is not there — or give it a reason to discount the feedback.
#  Inline the rules here instead.
# ─────────────────────────────────────────────────────────────────────────────
RULES=$(cat <<'EOF'
# your comment rules here, e.g.:
#   - say why, not what; the code already says what
#   - no comment that restates the line below it
EOF
)
# ───────────────────────────────────────────────────────────── END FILL-IN ───

payload=$(cat)

# Gate on the project directory capsule injected, not on a hardcoded path. The host
# version of this hook checked for ~/code, which never matches inside a container and so
# failed *open* — the guard silently never fired.
[ -n "${CAPSULE_PROJECT_DIR:-}" ] || exit 0

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty')
file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')
[ -n "$file" ] || exit 0

# MultiEdit is in this list deliberately: the host version omitted it, so every
# multi-edit slipped past the guard entirely.
case "$tool" in
  Write | Edit | MultiEdit) ;;
  *) exit 0 ;;
esac

# capsule is bash and Nix, where # is the comment marker, so these fire constantly and
# never usefully. Skipping them is what keeps the signal worth reading.
case "$file" in
  *.envrc | *.gitignore | *.lock | *.json | *.md) exit 0 ;;
esac

# All three payload shapes: Write carries .content, Edit carries .new_string, and
# MultiEdit nests its strings as .edits[].new_string — with only the first two keys,
# every MultiEdit read as zero added lines and the guard failed open for exactly the
# tool that edits the most at once.
added=$(printf '%s' "$payload" |
  jq -r '[(.tool_input.content // empty),
          (.tool_input.new_string // empty),
          (.tool_input.edits[]?.new_string // empty)] | join("\n")' |
  grep -cE '^[[:space:]]*(#|//|--)' || true)

[ "${added:-0}" -gt 0 ] || exit 0

printf 'comment-guard: %s comment line(s) added to %s\n\n%s\n' "$added" "$file" "$RULES" >&2
exit 2
