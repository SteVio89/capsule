#!/usr/bin/env bash
# Framework-free checks for capsule's flake-rewriting logic — the only part with real
# parsing (inject/strip/dedup). No VM, no direnv, no network: source bin/capsule with
# the dispatch guarded off, stub direnv, and drive the package helpers on a scratch
# flake.nix. Run: bash test/capsule-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hermetic: a valid host so the source-time guard passes, and an empty XDG_CONFIG_HOME
# so the user's real ~/.config/capsule/config is never sourced.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export CAPSULE_VM_HOST="core@localhost"
export XDG_CONFIG_HOME="$work/xdg"

# shellcheck source=/dev/null
source "$here/../bin/capsule"
set +e                        # the harness probes failure paths; don't abort on them
direnv() { :; }               # stub: cmd_add/cmd_rm call `direnv reload`

fails=0
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

cd "$work" || exit 2

seed() { # fresh devshell flake carrying the injection marker
  cat > flake.nix <<'EOF'
{
  outputs = { self, nixpkgs }: {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        # devhelper:packages
      ];
    };
  };
}
EOF
}

# Comma-joined list of injected packages: indented lines that are a bare token only
# (excludes `packages = with pkgs; [`, the marker, and `];`).
pkg_list() {
  grep -Eo '^[[:space:]]+[A-Za-z0-9._-]+[[:space:]]*$' flake.nix | tr -d ' \t' | paste -sd, -
}

seed
inject_pkgs go gopls
check "inject adds packages in order"      "go,gopls" "$(pkg_list)"
check "inject keeps the marker"            "1"        "$(grep -c '# devhelper:packages' flake.nix)"

seed
cmd_env_add ripgrep >/dev/null 2>&1
cmd_env_add ripgrep >/dev/null 2>&1
check "add is idempotent (no double entry)" "ripgrep" "$(pkg_list)"

seed
cmd_env_add fd fd >/dev/null 2>&1
check "add dedups a repeated batch arg"     "fd"      "$(pkg_list)"

seed
inject_pkgs go gopls just
cmd_env_rm gopls >/dev/null 2>&1
check "rm drops only the named package"     "go,just" "$(pkg_list)"

# python3PackagesXfoo must survive `rm python3Packages.foo`: the dot is literal, not regex.
seed
inject_pkgs python3PackagesXfoo
cmd_env_rm python3Packages.foo >/dev/null 2>&1
check "rm does not regex-over-match a dot"  "python3PackagesXfoo" "$(pkg_list)"

seed
inject_pkgs zig
pkg_present zig;   check "pkg_present true for present"  "0" "$?"
pkg_present cargo; check "pkg_present false for absent"  "1" "$?"

CAPSULE_VM_HOST=localhost bash "$here/../bin/capsule" help >/dev/null 2>&1
check "bare CAPSULE_VM_HOST is rejected"    "1" "$?"

# ---------------------------------------------------------------- the regrammar
#
# The rename was a clean break with no aliases, so these are the checks that catch a
# half-applied one: a verb that lost its function, or an old name that quietly still works.

# A real process, not the sourced copy. Overrides go through `env`, never a `VAR=x capsule`
# prefix: bash leaves an assignment prefixed to a *function* call set after that function
# returns, so one in-capsule check would silently poison every check after it.
cap="$here/../bin/capsule"
capsule() { bash "$cap" "$@"; }

# Every command in the noun-verb table resolves to cmd_<group>_<verb>. One naming law, so
# a missing function here means a command that dispatches into nothing.
missing=""
for pair in \
  env:init env:add env:rm env:update env:reload \
  vm:status vm:start vm:stop vm:ssh vm:disk vm:gc vm:destroy \
  image:pull image:build \
  run:start run:attach run:list run:push run:fetch run:review run:merge \
  project:add project:list project:rm project:profile \
  issue:new issue:list issue:edit issue:rename issue:comment \
  issue:triage issue:archive issue:reopen \
  memory:list memory:review memory:new \
  daemon:start daemon:stop daemon:status
do
  declare -F "cmd_${pair%%:*}_${pair##*:}" >/dev/null || missing="$missing $pair"
done
check "every table entry has a cmd_ function" "" "$missing"

# Old flat verbs are gone, not aliased. `vm` and `image` survive as group names and print
# that group's help, which is why they aren't in this list.
survivors=""
for v in init add rm update reload shell ssh size pull gc stop destroy push fetch review merge; do
  capsule "$v" >/dev/null 2>&1
  [[ $? -eq 2 ]] || survivors="$survivors $v"
done
check "old flat verbs are all rejected"     "" "$survivors"

check "CAPSULE_BRANCH is gone from the tree" "" \
  "$(grep -rl CAPSULE_BRANCH "$here/../bin" "$here/../config.example" "$here/../README.md" 2>/dev/null | paste -sd, -)"

# Host-only gating moved off CAPSULE_PROFILE, which now says nothing about where we are.
env CAPSULE_IN_CAPSULE=1 bash "$cap" vm start >/dev/null 2>&1
check "in-capsule: vm start refused"        "1" "$?"
env CAPSULE_IN_CAPSULE=1 bash "$cap" env init >/dev/null 2>&1
check "in-capsule: env init refused"        "1" "$?"
env CAPSULE_PROFILE=default bash "$cap" env init >/dev/null 2>&1
check "a stale CAPSULE_PROFILE no longer gates" "1" "$?"   # fails on flake.nix, not on gating

# env add must stay usable inside a capsule. In an empty dir it fails for the *flake*
# reason, never the host-only one — that difference is the whole assertion.
mkdir -p "$work/nof" && cd "$work/nof" || exit 2
check "in-capsule: env add reaches the flake check" "no flake.nix" \
  "$(env CAPSULE_IN_CAPSULE=1 bash "$cap" env add foo 2>&1 | grep -o 'no flake.nix\|not inside the capsule')"
cd "$work" || exit 2

# start/stop/destroy/disk answer for a disk image capsule owns; a real machine has none.
# Capture and match rather than piping to grep: pipefail is on, so a pipeline ending in a
# successful grep still reports capsule's own non-zero exit and the && would never fire.
refused=0
for v in start stop destroy disk; do
  out=$(env CAPSULE_VM_HOST=user@buildbox bash "$cap" vm "$v" 2>&1 >/dev/null)
  case "$out" in *"drives the local qemu VM"*) refused=$((refused + 1)) ;; esac
done
check "vm start/stop/destroy/disk are qemu-only" "4" "$refused"
env CAPSULE_VM_HOST=user@buildbox bash "$cap" vm status >/dev/null 2>&1
check "vm status works against a remote host"    "0" "$?"

# Daemon-backed commands must name the remedy rather than failing obscurely. Stub
# capsuled to a failure so `need_daemon` fires without a real socket anywhere.
mkdir -p "$work/stub" && printf '#!/bin/sh\nexit 1\n' > "$work/stub/capsuled"
chmod +x "$work/stub/capsuled"
check "daemon status names the remedy when nothing is running" "capsule daemon start" \
  "$(PATH="$work/stub:$PATH" bash "$cap" daemon status 2>&1 | grep -o "capsule daemon start")"
check "board refuses without a daemon rather than opening an empty screen" "capsule daemon start" \
  "$(PATH="$work/stub:$PATH" bash "$cap" board 2>&1 | grep -o "capsule daemon start")"
check "need_daemon names the remedy"       "capsule daemon start" \
  "$(PATH="$work/stub:$PATH" bash -c "set -e; . '$cap'; need_daemon" 2>&1 | grep -o "capsule daemon start")"

# `shell` and `size` were renamed out of existence rather than moved, so no help text
# anywhere should still offer them.
check "help never mentions a renamed-away verb" "" \
  "$({ capsule help; capsule env; capsule vm; capsule image; capsule run; } 2>&1 \
     | grep -Eo '^  (shell|size)\b' | paste -sd, -)"

echo
if (( fails == 0 )); then
  echo "all checks passed"
else
  echo "$fails check(s) failed"
  exit 1
fi
