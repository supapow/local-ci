#!/usr/bin/env bash
# local-ci — the checks GitHub runs, on the machine that has the code.
#
# Why: a free GitHub plan includes a fixed number of Actions minutes a month.
# When they run out, workflows do not queue — GitHub keeps creating the run and
# fails it in about two seconds with no runner, no steps and no logs. That looks
# exactly like a red build to every tool around it, including Vercel's build
# gate, so checks and deploys both stop. This runs the same steps locally, in the
# same order, and `--status` attests the commit so the gate can tell "the checks
# never ran" from "the checks failed".
#
# It is not a CI server. Nothing runs it for you: run it before a push,
# `--install-hook` to let `git push` decide, `--status` after a push while
# Actions is out.
#
# Exit codes: 0 pass (or nothing to do), 1 a step failed, 2 could not run.
#
# Usage:
#   ./scripts/local-ci.sh                # every step in ci-local.conf
#   ./scripts/local-ci.sh --fast         # skip `install` and `build` steps
#   ./scripts/local-ci.sh --no-build     # skip `build` steps
#   ./scripts/local-ci.sh --no-install   # skip `install` steps
#   ./scripts/local-ci.sh --changed      # exit 0 when every change is markdown
#   ./scripts/local-ci.sh --status       # post the `ci/local` commit status
#   ./scripts/local-ci.sh --auto         # exit 0 when GitHub Actions is running
#   ./scripts/local-ci.sh --mode         # print "actions" or "local"
#   ./scripts/local-ci.sh --list         # print the steps and exit
#   ./scripts/local-ci.sh --install-hook # make `git push` run --auto --fast
#
# The Vercel half is vercel-gate.mjs; see README.md.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

# ---------------------------------------------------------------- presentation

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  bold=$'\033[1m'; dim=$'\033[2m'
  red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
else
  bold=''; dim=''; red=''; green=''; yellow=''; reset=''
fi

say()  { printf '%s\n' "$*"; }
note() { printf '%s\n' "${dim}$*${reset}"; }
warn() { printf '%s\n' "${yellow}$*${reset}" >&2; }
die()  { printf '%s\n' "${red}$*${reset}" >&2; exit 2; }

# ------------------------------------------------------------------- git + gh

github_slug() {
  local url
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    url=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) && [ -n "$url" ] \
      && { printf '%s' "$url"; return 0; }
  fi
  url=$(git remote get-url origin 2>/dev/null) || return 1
  printf '%s' "$url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' | grep -E '^[^/]+/[^/]+$'
}

# -------------------------------------------------------- who is checking this
#
# Spend GitHub's included minutes and nothing more: while Actions is actually
# running the repo it is the check, and the laptop should not duplicate it. When
# the minutes are spent, the newest completed run executed zero steps — that is
# the signal. Anything unknown (no gh, no auth, an API error) answers "local",
# because the safe direction is to do the checks.
#
# Cached for five minutes in the git dir so a hook is not an API client; short
# enough that the switch flips on the first push after the minutes reset.
CI_MODE_TTL=${CI_MODE_TTL:-300}

ci_mode() { # prints "actions" or "local"
  local dir cache cached_at cached_mode now mode slug run steps
  dir=$(git rev-parse --git-dir 2>/dev/null) || dir=.git
  cache="$dir/local-ci-mode"

  if [ -f "$cache" ]; then
    cached_at=$(sed -n '1p' "$cache" 2>/dev/null)
    cached_mode=$(sed -n '2p' "$cache" 2>/dev/null)
    now=$(date +%s)
    case "$cached_at" in
      ''|*[!0-9]*) : ;;
      *) if [ "$((now - cached_at))" -lt "$CI_MODE_TTL" ] && [ -n "$cached_mode" ]; then
           printf '%s' "$cached_mode"; return 0
         fi ;;
    esac
  fi

  mode=local
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 \
     && slug=$(github_slug) \
     && run=$(gh api "repos/$slug/actions/runs?status=completed&per_page=1" \
                --jq '.workflow_runs[0].id' 2>/dev/null) \
     && [ -n "$run" ] && [ "$run" != "null" ]; then
    steps=$(gh api "repos/$slug/actions/runs/$run/jobs?per_page=100" \
              --jq '[.jobs[].steps|length] | add // 0' 2>/dev/null)
    case "$steps" in
      ''|*[!0-9]*) : ;;
      *) [ "$steps" -gt 0 ] && mode=actions ;;
    esac
  fi

  printf '%s\n%s\n' "$(date +%s)" "$mode" > "$cache" 2>/dev/null || true
  printf '%s' "$mode"
}

MODE_BLURB_ACTIONS="GitHub Actions is running this repo — it will check this push"
MODE_BLURB_LOCAL="GitHub Actions is not running this repo right now (runs fail with no steps) — the local suite is the check"

# ---------------------------------------------------------------------- flags

CONFIG=${CI_LOCAL_CONFIG:-ci-local.conf}
SKIP_INSTALL=0
SKIP_BUILD=0
DOCS_ONLY=0
ATTEST=0
INSTALL_HOOK=0
AUTO=0
LIST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --fast)         SKIP_INSTALL=1; SKIP_BUILD=1 ;;
    --no-install)   SKIP_INSTALL=1 ;;
    --no-build)     SKIP_BUILD=1 ;;
    --changed)      DOCS_ONLY=1 ;;
    --status)       ATTEST=1 ;;
    --auto)         AUTO=1 ;;
    --list)         LIST=1 ;;
    --install-hook) INSTALL_HOOK=1 ;;
    --mode)         if [ "$(ci_mode)" = actions ]; then say "actions  $MODE_BLURB_ACTIONS"
                    else say "local    $MODE_BLURB_LOCAL"; fi; exit 0 ;;
    --config)       shift; CONFIG=${1:-$CONFIG} ;;
    -h|--help)      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown flag: $1 (try --help)" ;;
  esac
  shift
done

# -------------------------------------------------------------------- the hook

if [ "$INSTALL_HOOK" = 1 ]; then
  current=$(git config --get core.hooksPath 2>/dev/null || true)
  if [ "$current" != ".githooks" ]; then
    git config core.hooksPath .githooks || die "could not set core.hooksPath"
    say "${green}✓${reset} core.hooksPath → .githooks (this clone only)"
    [ -n "$current" ] && note "  was: $current"
  else
    say "${green}✓${reset} core.hooksPath is already .githooks"
  fi
  chmod +x .githooks/pre-push 2>/dev/null || true
  say ""
  note "  git push now runs: ./scripts/local-ci.sh --auto --fast --changed"
  note "  skip once with CI_SKIP=1 git push, or git push --no-verify"
  note "  undo with: git config --unset core.hooksPath"
  exit 0
fi

# ---------------------------------------------------------------------- steps

STEP_LABELS=()
STEP_KINDS=()
STEP_CMDS=()

# Called by ci-local.conf: step <label> <kind> <command>
#   kind install  skipped by --fast and --no-install
#   kind build    skipped by --fast and --no-build
#   anything else always runs
step() {
  [ -n "${3:-}" ] || die "a step needs three arguments: label kind command"
  STEP_LABELS+=("$1")
  STEP_KINDS+=("${2:-run}")
  STEP_CMDS+=("$3")
}

if [ ! -f "$CONFIG" ]; then
  die "no $CONFIG — copy ci-local.conf.example, or write your own (see README.md)."
fi

# shellcheck disable=SC1090
case "$CONFIG" in
  /*) . "$CONFIG" || die "could not read $CONFIG" ;;
  *)  . "./$CONFIG" || die "could not read $CONFIG" ;;
esac

if [ "${#STEP_CMDS[@]}" -eq 0 ]; then
  die "$CONFIG defines no steps. Each line looks like:"
  note '  step "typecheck" check "npm run typecheck"'
fi

if [ "$LIST" = 1 ]; then
  i=0
  while [ "$i" -lt "${#STEP_CMDS[@]}" ]; do
    printf '  %-10s %-22s %s\n' "${STEP_KINDS[$i]}" "${STEP_LABELS[$i]}" "${STEP_CMDS[$i]}"
    i=$((i + 1))
  done
  exit 0
fi

if [ "$AUTO" = 1 ]; then
  if [ "$(ci_mode)" = actions ]; then
    say "${green}✓${reset} $MODE_BLURB_ACTIONS — the local suite would be a duplicate"
    note "  see it yourself: --mode · run it anyway: --no-install"
    exit 0
  fi
  note "$MODE_BLURB_LOCAL"
fi

# -------------------------------------------------------------- markdown only
#
# A docs push cannot break a typecheck, a test or a build, and every workflow
# worth copying already ignores it. Keep the local run just as cheap.
docs_only_change() {
  local base upstream changed
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || upstream=""
  if [ -z "$upstream" ]; then
    upstream=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || upstream=""
  fi
  [ -n "$upstream" ] || return 1
  base=$(git merge-base HEAD "$upstream" 2>/dev/null) || return 1
  [ -n "$base" ] || return 1
  changed=$(
    {
      git diff --name-only "$base" HEAD 2>/dev/null
      git diff --name-only HEAD 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null
    } | sed '/^$/d' | sort -u
  )
  [ -n "$changed" ] || return 1
  ! printf '%s\n' "$changed" | grep -qvE '\.md$'
}

if [ "$DOCS_ONLY" = 1 ] && docs_only_change; then
  say "${green}✓${reset} markdown only — nothing here can fail a build"
  exit 0
fi

# ------------------------------------------------------------------ attestation

SLUG=""
SHA=""
ATTEST_READY=0
CONTEXT=${CI_ATTESTATION_CONTEXT:-ci/local}

attest_setup() {
  # Cheapest and most certain refusal first: a green run on a dirty tree would
  # describe the tree, not the commit, and that needs no network to establish.
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    die "--status refused: the working tree has uncommitted changes, so a green run would describe the tree, not the commit. Commit first (or run without --status)."
  fi
  command -v gh >/dev/null 2>&1 \
    || die "--status needs the GitHub CLI (https://cli.github.com), and an authenticated session."
  gh auth status >/dev/null 2>&1 || die "--status needs an authenticated gh session (gh auth status)."
  SLUG=$(github_slug) || die "could not work out the GitHub repo slug (no gh remote, no origin URL)."
  SHA=$(git rev-parse HEAD) || die "could not read HEAD."
  ATTEST_READY=1
}

post_status() { # state, description
  gh api -X POST "repos/$SLUG/statuses/$SHA" \
    -f state="$1" -f context="$CONTEXT" -f description="$2" \
    --jq '.context' >/dev/null 2>&1
}

if [ "$ATTEST" = 1 ]; then
  attest_setup
  if post_status pending "local CI running on $(hostname -s 2>/dev/null || echo this machine)"; then
    note "attestation: $CONTEXT → pending for ${SHA:0:8}"
  else
    warn "could not post the pending $CONTEXT status — the result will still be reported at the end"
  fi
fi

# ------------------------------------------------------------------------ run

STEP_NAMES=()
STEP_TIMES=()
STEP_STATES=()
FAILED=""

run_step() { # index
  local label="${STEP_LABELS[$1]}" cmd="${STEP_CMDS[$1]}"
  local start=$SECONDS
  printf '\n%s▶ %s%s\n' "$bold" "$label" "$reset"
  if bash -c "$cmd"; then
    STEP_STATES+=("pass")
  else
    STEP_STATES+=("fail")
    FAILED="$label"
  fi
  STEP_NAMES+=("$label")
  STEP_TIMES+=($((SECONDS - start)))
}

TOTAL_START=$SECONDS
i=0
while [ "$i" -lt "${#STEP_CMDS[@]}" ]; do
  case "${STEP_KINDS[$i]}" in
    install) if [ "$SKIP_INSTALL" = 1 ]; then i=$((i + 1)); continue; fi ;;
    build)   if [ "$SKIP_BUILD" = 1 ];   then i=$((i + 1)); continue; fi ;;
  esac
  run_step "$i"
  [ -n "$FAILED" ] && break
  i=$((i + 1))
done
TOTAL=$((SECONDS - TOTAL_START))

# -------------------------------------------------------------------- summary

printf '\n%s%s%s\n' "$bold" "local-ci" "$reset"
i=0
while [ "$i" -lt "${#STEP_NAMES[@]}" ]; do
  if [ "${STEP_STATES[$i]}" = pass ]; then
    printf '  %s✓%s %-38s %3ss\n' "$green" "$reset" "${STEP_NAMES[$i]}" "${STEP_TIMES[$i]}"
  else
    printf '  %s✗%s %-38s %3ss\n' "$red" "$reset" "${STEP_NAMES[$i]}" "${STEP_TIMES[$i]}"
  fi
  i=$((i + 1))
done

if [ -n "$FAILED" ]; then
  printf '\n  %sFAILED%s in %ss at "%s".\n' "$red" "$reset" "$TOTAL" "$FAILED"
  ATTEST_DESC="local CI failed at $FAILED"
else
  printf '\n  %spassed%s in %ss.\n' "$green" "$reset" "$TOTAL"
  ATTEST_DESC="local CI passed in ${TOTAL}s"
fi

if [ "$ATTEST_READY" = 1 ]; then
  if [ -n "$FAILED" ]; then
    post_status failure "$ATTEST_DESC" \
      && note "  attested: $CONTEXT → failure for ${SHA:0:8}"
  else
    if post_status success "$ATTEST_DESC"; then
      note "  attested: $CONTEXT → success for ${SHA:0:8}"
    else
      warn "  could not post the $CONTEXT status — check gh auth and the token's permissions"
      exit 2
    fi
  fi
fi

[ -n "$FAILED" ] && exit 1
exit 0
