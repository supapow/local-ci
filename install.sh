#!/usr/bin/env bash
# Copy local-ci into this repository.
#
#   ./install.sh                 # into the repo you are standing in
#   ./install.sh --dir ../other  # into another repo
#   ./install.sh --hook          # also make `git push` decide (writes core.hooksPath)
#   ./install.sh --force         # overwrite files that already exist
#
# It copies:  scripts/local-ci.sh, scripts/vercel-gate.mjs, .githooks/pre-push,
# and (if missing) ci-local.conf from ci-local.conf.example.
#
# It does NOT touch vercel.json. Add the line by hand — a bad merge there takes
# production down:
#
#   { "ignoreCommand": "node scripts/vercel-gate.mjs" }

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
target=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "not a git repository — run this from the repo you want to set up" >&2
  exit 2
}
hook=0
force=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   shift; target=$(cd "${1:-}" 2>/dev/null && pwd) || { echo "no such directory: ${1:-}" >&2; exit 2; } ;;
    --hook)  hook=1 ;;
    --force) force=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

copy() { # source, destination
  local src="$1" dst="$2"
  if [ -e "$dst" ] && [ "$force" = 0 ]; then
    echo "  · $dst exists — left alone (use --force to replace)"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "  → $dst"
}

echo "local-ci → $target"
copy "$here/local-ci.sh" "$target/scripts/local-ci.sh"
copy "$here/vercel-gate.mjs" "$target/scripts/vercel-gate.mjs"
copy "$here/.githooks/pre-push" "$target/.githooks/pre-push"
copy "$here/ci-local.conf.example" "$target/ci-local.conf"

chmod +x "$target/scripts/local-ci.sh" "$target/.githooks/pre-push" 2>/dev/null || true

if [ "$hook" = 1 ]; then
  ( cd "$target" && git config core.hooksPath .githooks ) \
    && echo "  ✓ core.hooksPath → .githooks (this clone only)"
fi

cat <<'NEXT'

Next:
  1. Edit ci-local.conf so it mirrors your workflow's steps.
  2. Run ./scripts/local-ci.sh — it should pass before anything else changes.
  3. Add to vercel.json:  "ignoreCommand": "node scripts/vercel-gate.mjs"
  4. Create a fine-grained PAT with Actions: read-only AND Commit statuses:
     read-only for this repository, then set it in Vercel (Production) as
     GITHUB_READ_TOKEN. Both permissions are required — see README.md.
  5. One-off: redeploy with Vercel's "Use project's Ignore Build Step" unticked,
     so the gate that just got committed is the one that runs next time.
  6. After a pull request is merged in the UI, attest the commit Vercel builds —
     not your branch head, and not your local HEAD:
       git fetch origin main
       ./scripts/local-ci.sh --status --sha "$(git rev-parse origin/main)"
     If that deployment was already cancelled by the gate, redeploy it. Never
     release with `vercel --prod`: it bypasses the gate and leaves no commit.

Agent instructions for the repository (append, do not overwrite):
NEXT

echo "  $here/prompts/agents-md.md"
echo "  → AGENTS.md / CLAUDE.md — copy it before this clone is removed."
