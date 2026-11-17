#!/usr/bin/env bash
# Copy local-ci into this repository.
#
#   ./install.sh                 # into the repo you are standing in
#   ./install.sh --dir ../other  # into another repo
#   ./install.sh --hook          # also make `git push` decide (writes core.hooksPath)
#   ./install.sh --force         # overwrite files that already exist
#   ./install.sh --agent-md      # append the release rules to AGENTS.md/CLAUDE.md
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
target=""
hook=0
force=0
agent_md=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   shift; target=$(cd "${1:-}" 2>/dev/null && pwd) || { echo "no such directory: ${1:-}" >&2; exit 2; } ;;
    --hook)  hook=1 ;;
    --force) force=1 ;;
    --agent-md) agent_md=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$target" ]; then
  target=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "not a git repository — run this from the repo you want to set up, or pass --dir" >&2
    exit 2
  }
fi
git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "not a git repository: $target" >&2
  exit 2
}

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

# Opt-in: put the release rules where the next agent reads them. The section is
# marked so a re-run replaces it instead of appending a second copy.
if [ "$agent_md" = 1 ]; then
  section="$here/prompts/agents-md.md"
  if [ ! -f "$section" ]; then
    echo "  · prompts/agents-md.md is missing — agent instructions skipped" >&2
  else
    if [ -f "$target/AGENTS.md" ]; then doc="$target/AGENTS.md"
    elif [ -f "$target/CLAUDE.md" ]; then doc="$target/CLAUDE.md"
    else doc="$target/AGENTS.md"; fi
    if [ -f "$doc" ] && grep -q '<!-- local-ci:begin -->' "$doc"; then
      tmp="$doc.local-ci.$$"
      awk '
        /<!-- local-ci:begin -->/ { inside = 1; next }
        /<!-- local-ci:end -->/   { inside = 0; next }
        !inside { print }
      ' "$doc" > "$tmp" && mv "$tmp" "$doc"
    fi
    {
      printf '\n<!-- local-ci:begin -->\n'
      cat "$section"
      printf '<!-- local-ci:end -->\n'
    } >> "$doc"
    echo "  → $doc (release rules, marked section)"
  fi
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

Agent instructions for the repository:
   install.sh --agent-md appends them to AGENTS.md (or CLAUDE.md) as a marked
   section. To do it by hand, append:
NEXT

echo "  $here/prompts/agents-md.md"
echo "  → AGENTS.md / CLAUDE.md — copy the text before this clone is removed."
