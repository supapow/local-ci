#!/usr/bin/env bash
# The installer's behaviour: a copy into a throwaway repository, --agent-md
# idempotence, and working from outside a repository with --dir.
#
#   bash test/install-test.sh
#
# Exit 0 = every case behaved; 1 = something regressed.

set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d 2>/dev/null || mktemp -d -t local-ci-install)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok()    { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad()   { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $2, got $3)"; fi
}

new_repo() { # directory
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
}

cd "$work" || exit 2

run_install() { bash "$here/install.sh" "$@" >"$work/out" 2>&1; echo $?; }

echo "install.sh self-test"

# 1. copies its files, and --agent-md preserves the repository's own text
A="$work/a"
new_repo "$A"
printf '# Rules\n\nKeep me.\n' > "$A/AGENTS.md"
git -C "$A" add -A && git -C "$A" commit -qm init

check "install --dir --agent-md exits 0" 0 "$(run_install --dir "$A" --agent-md)"
for f in scripts/local-ci.sh scripts/vercel-gate.mjs .githooks/pre-push ci-local.conf; do
  if [ -e "$A/$f" ]; then ok "copied $f"; else bad "copied $f"; fi
done
grep -q 'Keep me\.' "$A/AGENTS.md" && ok "kept the existing instructions" || bad "kept the existing instructions"
check "added one marked section" 1 "$(grep -c '<!-- local-ci:begin -->' "$A/AGENTS.md")"
grep -q '## CI and production deploys' "$A/AGENTS.md" && ok "added the release rules" || bad "added the release rules"

# 2. a second run replaces the marked section instead of appending another
check "a second run exits 0" 0 "$(run_install --dir "$A" --agent-md)"
check "still one marker" 1 "$(grep -c '<!-- local-ci:begin -->' "$A/AGENTS.md")"
check "still one section" 1 "$(grep -c '## CI and production deploys' "$A/AGENTS.md")"
check "the existing text is not duplicated" 1 "$(grep -c 'Keep me\.' "$A/AGENTS.md")"

# 3. a CLAUDE.md-only repository gets the section there
B="$work/b"
new_repo "$B"
printf '# Claude rules\n' > "$B/CLAUDE.md"
check "CLAUDE.md-only repository exits 0" 0 "$(run_install --dir "$B" --agent-md)"
grep -q '<!-- local-ci:begin -->' "$B/CLAUDE.md" && ok "appended to CLAUDE.md" || bad "appended to CLAUDE.md"
[ ! -f "$B/AGENTS.md" ] && ok "did not create a second instruction file" || bad "did not create a second instruction file"

# 4. --dir outside a repository is still validated
mkdir -p "$work/notrepo"
check "--dir on a non-repository exits 2" 2 "$(run_install --dir "$work/notrepo")"
grep -q 'not a git repository' "$work/out" && ok "and says why" || bad "and says why"

# 5. --help
check "--help exits 0" 0 "$(run_install --help)"
grep -q -- '--agent-md' "$work/out" && ok "--help mentions --agent-md" || bad "--help mentions --agent-md"

echo
if [ "$fail" -eq 0 ]; then
  echo "all $pass checks passed"
  exit 0
fi
echo "$fail of $((pass + fail)) checks failed"
exit 1
