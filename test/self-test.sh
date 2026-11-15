#!/usr/bin/env bash
# The self-test: run local-ci.sh against a throwaway repo and check its
# behaviour, not its output. No network, no gh, no package manager.
#
#   bash test/self-test.sh
#
# Exit 0 = every case behaved; 1 = something regressed.

set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d 2>/dev/null || mktemp -d -t local-ci)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }
check(){ # description, expected, actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $2, got $3)"; fi
}

git config --global user.email >/dev/null 2>&1 || {
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
}
export GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-test} GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-test@example.com}
export GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-test} GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-test@example.com}

# ---------------------------------------------------------------- fixtures

git init -q --bare "$work/remote.git"
git init -q "$work/repo"
cd "$work/repo" || exit 2
git remote add origin "$work/remote.git"
mkdir -p scripts
cp "$here/local-ci.sh" scripts/local-ci.sh
chmod +x scripts/local-ci.sh

cat > ci-local.conf <<'CONF'
step "install" install "echo installing"
step "check"   check   "echo checking"
step "build"   build   "echo building"
CONF

printf '# demo\n' > README.md
printf 'x\n' > thing.txt
git add -A && git commit -qm "first"
git push -q -u origin HEAD:main
git checkout -q -b work
git branch --set-upstream-to=origin/main work >/dev/null 2>&1

run() { bash scripts/local-ci.sh "$@" > "$work/out" 2>&1; echo $?; }
steps_run() { grep -c '▶' "$work/out" 2>/dev/null || true; }

echo "local-ci self-test"

# 1. everything runs by default
check "default run exits 0" 0 "$(run)"
check "default run runs all three steps" 3 "$(steps_run)"

# 2. --fast keeps only the check kind
check "--fast exits 0" 0 "$(run --fast)"
check "--fast runs one step" 1 "$(steps_run)"

# 3. --no-build drops only the build
check "--no-build exits 0" 0 "$(run --no-build)"
check "--no-build runs two steps" 2 "$(steps_run)"

# 4. a failing step is exit 1 and stops the run
cat > ci-local.conf <<'CONF'
step "ok"   check "true"
step "boom" check "false"
step "late" check "echo never"
CONF
check "failing step exits 1" 1 "$(run)"
check "failure stops the run" 2 "$(steps_run)"
grep -q 'never' "$work/out" && bad "steps after a failure were skipped" || ok "steps after a failure are skipped"

# 5. markdown-only change is free
cat > ci-local.conf <<'CONF'
step "check" check "echo checking"
CONF
git commit -qam "config"
git push -q origin HEAD:main && git fetch -q origin
printf 'more docs\n' >> README.md
git commit -qam "docs only"
check "--changed exits 0 for markdown" 0 "$(run --changed)"
check "--changed skipped the steps" 0 "$(steps_run)"

# 6. a code change is not free
printf 'y\n' >> thing.txt
git commit -qam "code"
check "--changed runs on code" 0 "$(run --changed)"
check "--changed ran the step" 1 "$(steps_run)"

# 7. --list prints the steps
check "--list exits 0" 0 "$(run --list)"
grep -q 'checking' "$work/out" && ok "--list shows the command" || bad "--list shows the command"

# 8. --status refuses a dirty tree
printf 'dirty\n' >> thing.txt
check "--status with a dirty tree exits 2" 2 "$(run --status)"
grep -q 'uncommitted changes' "$work/out" && ok "and says why" || bad "and says why"
git checkout -q -- thing.txt

# 8b. --sha names the commit to attest, so it only makes sense with --status
check "--sha without --status exits 2" 2 "$(run --sha HEAD)"
grep -q 'only works with --status' "$work/out" && ok "and explains why" || bad "and explains why"

# 8c. a commit whose tree differs from HEAD is refused before any network call
git commit -q --allow-empty -m "same tree a"
same_a=$(git rev-parse HEAD)
git commit -q --allow-empty -m "same tree b"
same_b=$(git rev-parse HEAD)
older=$(git rev-parse HEAD~3)
check "--sha with a different tree exits 2" 2 "$(run --status --sha "$older")"
grep -q 'different tree' "$work/out" && ok "and says the tree differs" || bad "and says the tree differs"

# 8d. a same-tree commit gets the statuses, not HEAD (gh is a stub: no network)
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'GH'
#!/bin/sh
case "$*" in
  "auth status") exit 0 ;;
  "repo view"*) printf 'test/repo\n' ;;
  "api -X POST"*) printf '%s\n' "$*" >> "$GH_LOG" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$work/bin/gh"
post_with_fake_gh() {
  GH_LOG="$work/gh.log" PATH="$work/bin:$PATH" bash scripts/local-ci.sh "$@" >"$work/out" 2>&1
  echo $?
}

rm -f "$work/gh.log"
check "--status --sha accepts a same-tree commit" 0 "$(post_with_fake_gh --status --sha "$same_a")"
check "it posts twice, to that sha" 2 "$(grep -c "statuses/$same_a" "$work/gh.log")"
check "pending first" pending "$(head -1 "$work/gh.log" | grep -o 'state=[a-z]*' | cut -d= -f2)"
check "success last" success "$(tail -1 "$work/gh.log" | grep -o 'state=[a-z]*' | cut -d= -f2)"
check "and never to HEAD" 0 "$(grep -c "statuses/$same_b" "$work/gh.log")"

rm -f "$work/gh.log"
check "--status without --sha still attests HEAD" 0 "$(post_with_fake_gh --status)"
check "…at HEAD's sha" 2 "$(grep -c "statuses/$same_b" "$work/gh.log")"

# 9. --mode answers without exploding
check "--mode exits 0" 0 "$(run --mode)"
grep -qE '^(actions|local)' "$work/out" && ok "--mode prints a verdict" || bad "--mode prints a verdict"

# 10. a missing config is exit 2, not a silent pass
mv ci-local.conf ci-local.conf.bak
check "missing config exits 2" 2 "$(run)"
mv ci-local.conf.bak ci-local.conf

# 11. --secrets is optional, and its verdict is gitleaks' exit code
mkdir -p "$work/bin"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/gitleaks"; chmod +x "$work/bin/gitleaks"
check "secrets scan passes when gitleaks is happy" 0 \
  "$(PATH="$work/bin:$PATH" bash scripts/local-ci.sh --secrets >/dev/null 2>&1; echo $?)"
printf '#!/bin/sh\necho "Finding: REDACTED"\nexit 1\n' > "$work/bin/gitleaks"; chmod +x "$work/bin/gitleaks"
check "secrets scan fails on a finding" 1 \
  "$(PATH="$work/bin:$PATH" bash scripts/local-ci.sh --secrets >/dev/null 2>&1; echo $?)"
rm -f "$work/bin/gitleaks"
check "secrets scan is skipped without gitleaks" 0 \
  "$(PATH="$work/bin:/usr/bin:/bin" bash scripts/local-ci.sh --secrets >/dev/null 2>&1; echo $?)"

echo
if [ "$fail" -eq 0 ]; then
  echo "all $pass checks passed"
  exit 0
fi
echo "$fail of $((pass + fail)) checks failed"
exit 1
