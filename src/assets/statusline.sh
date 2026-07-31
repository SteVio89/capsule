#!/usr/bin/env sh
# capsule status line — a template. Edit it; capsule will not overwrite your version.
#
# The format is a preference, not policy. capsule's job is to make the data trivially
# available, not to dictate how it looks.
#
# `GET /status` rather than MCP: MCP is JSON-RPC with an initialisation handshake, which
# is far too much machinery to run on every status-line render. Same server, same token,
# read-only.
#
# Depends only on POSIX sh, curl and jq.

status=$(curl -s --max-time 1 \
  -H "authorization: Bearer ${CAPSULE_RUN_TOKEN:-}" \
  "http://localhost:${CAPSULE_MCP_PORT:-8765}/status" 2>/dev/null)

[ -n "$status" ] || exit 0

# ─────────────────────────────────────────────────────────────────────────────
#  FILL THIS IN — the fields available are:
#     .issue    short id, e.g. 018f2a1c
#     .state    open | in_progress | blocked | ready_for_review
#     .title    the issue title
#     .branch   capsule/<full issue id>
# ─────────────────────────────────────────────────────────────────────────────
printf '%s' "$status" | jq -r '"\(.issue) \(.state) — \(.title)"'
# ───────────────────────────────────────────────────────────── END FILL-IN ───
