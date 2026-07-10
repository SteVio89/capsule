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
cmd_add ripgrep >/dev/null 2>&1
cmd_add ripgrep >/dev/null 2>&1
check "add is idempotent (no double entry)" "ripgrep" "$(pkg_list)"

seed
cmd_add fd fd >/dev/null 2>&1
check "add dedups a repeated batch arg"     "fd"      "$(pkg_list)"

seed
inject_pkgs go gopls just
cmd_rm gopls >/dev/null 2>&1
check "rm drops only the named package"     "go,just" "$(pkg_list)"

# python3PackagesXfoo must survive `rm python3Packages.foo`: the dot is literal, not regex.
seed
inject_pkgs python3PackagesXfoo
cmd_rm python3Packages.foo >/dev/null 2>&1
check "rm does not regex-over-match a dot"  "python3PackagesXfoo" "$(pkg_list)"

seed
inject_pkgs zig
pkg_present zig;   check "pkg_present true for present"  "0" "$?"
pkg_present cargo; check "pkg_present false for absent"  "1" "$?"

CAPSULE_VM_HOST=localhost bash "$here/../bin/capsule" help >/dev/null 2>&1
check "bare CAPSULE_VM_HOST is rejected"    "1" "$?"

echo
if (( fails == 0 )); then
  echo "all checks passed"
else
  echo "$fails check(s) failed"
  exit 1
fi
