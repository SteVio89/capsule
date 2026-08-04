#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
capsuled="${CAPSULE_BIN:-$here/../zig-out/bin/capsule}"

if [[ ! -x $capsuled ]]; then
  echo "capsuled not found at $capsuled — run 'zig build' first, or set CAPSULED" >&2
  exit 2
fi

work="$(mktemp -d)"
export CAPSULE_SOCKET="$work/d.sock"
export CAPSULE_DB="$work/state.db"
export CAPSULE_CTL_DIR="$work/ctl"
export CAPSULE_MCP_PORT="${CAPSULE_MCP_PORT:-18799}"
export CAPSULE_VM_HOST=core@127.0.0.1
export CAPSULE_VM_PORT=9

daemon_pid=""
cleanup() {
  [[ -n $daemon_pid ]] && kill "$daemon_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

fails=0
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

out=$("$capsuled" ping 2>&1); rc=$?
check "a client with no daemon fails"        "1" "$rc"
check "...and names the remedy"              "capsule daemon start" \
  "$(grep -o 'capsule daemon start' <<<"$out")"

"$capsuled" daemon & daemon_pid=$!
for _ in $(seq 1 50); do [[ -S $CAPSULE_SOCKET ]] && break; sleep 0.1; done
check "the socket appears where it was asked to" "yes" \
  "$([[ -S $CAPSULE_SOCKET ]] && echo yes || echo no)"

check "the store file is created"            "yes" \
  "$([[ -f $CAPSULE_DB ]] && echo yes || echo no)"

check "ping answers"                         '{"pong":true}' "$("$capsuled" ping)"
check "status reports an empty store"        "0" \
  "$("$capsuled" daemon.status | jq -r '.projects')"
check "status reports the endpoint state"    "up" \
  "$("$capsuled" daemon.status | jq -r '.endpoint')"

"$capsuled" nope.method >/dev/null 2>&1
check "an unknown method exits nonzero"      "1" "$?"
check "...and says which method"             "nope.method" \
  "$("$capsuled" nope.method 2>&1 | grep -o 'nope.method')"

check "world.get answers even with the VM down" "false" \
  "$("$capsuled" world.get | sed 's/.*"reachable"://; s/,.*//')"

repo="$work/repo"
git init -q "$repo"
gcd=$(git -C "$repo" rev-parse --git-common-dir)
params=$(jq -cn --arg g "$gcd" --arg c "$repo" '{git_common_dir: $g, cwd: $c}')

check "a scratch project registers" "0" \
  "$("$capsuled" project.add "$(jq -c '. + {profile: "default"}' <<<"$params")" >/dev/null 2>&1; echo $?)"

body=$'first line\nsecond "quoted" line\n\ttabbed, and a back\\slash'
new_params=$(jq -cn --argjson p "$params" --arg t "multi-line body" --arg b "$body" \
  '$p + {title: $t, body: $b}')
created=$("$capsuled" issue.new "$new_params")
check "an issue with a multi-line body is accepted" "0" "$?"

short=$(jq -r '.short' <<<"$created")
got=$("$capsuled" issue.get "$(jq -c --arg id "$short" '. + {id: $id}' <<<"$params")" | jq -r '.body')
check "the body round-trips byte for byte" "$body" "$got"

http_get() { # http_get <path>
  exec 3<>"/dev/tcp/127.0.0.1/$CAPSULE_MCP_PORT" || return 1
  printf 'GET %s HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n' "$1" >&3
  timeout 5 cat <&3
  exec 3<&-
}

check "GET /ping answers"                    '{"ok":true}' "$(http_get /ping | tail -1)"
check "...as json"                           "application/json" \
  "$(http_get /ping | grep -io 'application/json' | head -1)"
check "an unknown path is 404, not a hang"   "404" \
  "$(http_get /nope | head -1 | grep -o '404')"
if command -v ss >/dev/null 2>&1; then
  check "the endpoint is bound to loopback only" "" \
    "$(ss -ltnH "sport = :$CAPSULE_MCP_PORT" | awk '{print $4}' | grep -v '^127\.0\.0\.1:')"
fi

out=$("$capsuled" daemon 2>&1); rc=$?
check "a second daemon refuses"              "1" "$rc"
check "...saying it is already running"      "already running" \
  "$(grep -o 'already running' <<<"$out")"
check "the first daemon still answers"       '{"pong":true}' "$("$capsuled" ping)"

"$capsuled" daemon.stop >/dev/null 2>&1
wait "$daemon_pid" 2>/dev/null; daemon_pid=""
check "the socket is removed on a clean exit" "gone" \
  "$([[ -S $CAPSULE_SOCKET ]] && echo present || echo gone)"

: > "$CAPSULE_SOCKET"
"$capsuled" daemon & daemon_pid=$!
for _ in $(seq 1 50); do "$capsuled" ping >/dev/null 2>&1 && break; sleep 0.1; done
check "a stale socket file is reclaimed"     '{"pong":true}' "$("$capsuled" ping)"
"$capsuled" daemon.stop >/dev/null 2>&1
wait "$daemon_pid" 2>/dev/null; daemon_pid=""

echo
if (( fails == 0 )); then
  echo "all checks passed"
else
  echo "$fails check(s) failed"
  exit 1
fi
