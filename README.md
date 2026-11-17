# local-ci

**GitHub's checks, on your machine, when the minutes run out — and a Vercel
build gate that believes them.**

[![CI](https://github.com/supapow/local-ci/actions/workflows/ci.yml/badge.svg)](https://github.com/supapow/local-ci/actions/workflows/ci.yml)

Two small scripts and a hook. No service, no account, no npm package.

---

## The problem

A free GitHub plan includes a fixed number of Actions minutes per month. When
they are spent, workflows do not queue. GitHub keeps creating the run and fails
it in about two seconds, with **no runner, no steps and no logs**:

```json
{ "status": "completed", "conclusion": "failure",
  "jobs": [{ "steps": [], "runner_name": "" }] }
```

That is indistinguishable from a real red build to everything downstream. Two
things break at once:

1. Nothing is checking your code.
2. If you gate deploys on CI — the common Vercel `ignoreCommand` pattern — **every
   deploy is skipped** for the rest of the month, because the gate reads that
   instant failure as "CI failed".

And it is not obvious: `git log` looks healthy, the PR shows a red check in two
seconds, and production silently stays on the previous deployment.

## What this does

| Situation | Who checks the code | How the deploy is allowed |
| --- | --- | --- |
| Minutes available | GitHub Actions | The gate reads the run |
| Minutes spent | `./scripts/local-ci.sh` | You run `--status --sha <sha>` for the commit Vercel builds; the gate reads the attestation |

`local-ci.sh` runs the steps from `ci-local.conf` — the same ones your workflow
runs, in the same order, stopping at the first failure — with timings and a
summary. `--auto` asks GitHub which side you are on, so a `git push` hook can do
the right thing without you thinking about it.

`vercel-gate.mjs` is a Vercel **Ignored Build Step**. It looks up the CI run for
the exact commit being deployed:

- a run that **executed and passed** → build
- a run that **executed and failed** → skip (a real red is authoritative)
- a run that **never started** → no evidence: read the `ci/local` commit status
  instead (success → build, pending → wait, failure → skip, absent → skip after
  the timeout)
- **no run at all** → build after a short grace (docs-only pushes are often not
  built)

## Install

You need: `bash` (macOS/Linux), `git`, and the [GitHub CLI](https://cli.github.com)
(`gh auth login`) for `--auto` and `--status`. The gate needs Node 18+.

From inside the repository you want to protect:

```sh
git clone https://github.com/supapow/local-ci /tmp/local-ci
/tmp/local-ci/install.sh --hook
```

That copies `scripts/local-ci.sh`, `scripts/vercel-gate.mjs`,
`.githooks/pre-push` and a starter `ci-local.conf`, and points
`core.hooksPath` at `.githooks` (this clone only; `git config --unset
core.hooksPath` undoes it).

Then:

1. Edit `ci-local.conf` until it mirrors your workflow.
2. Run `./scripts/local-ci.sh`. It should pass before anything else changes.
3. Add the gate to `vercel.json` (below).
4. Create the token (below) and set it in Vercel.
5. Redeploy once with **Use project's Ignore Build Step** unticked, so the gate
   you just committed is the one that runs.
6. Put the release rules where your agent reads them: append
   [`prompts/agents-md.md`](prompts/agents-md.md) to `AGENTS.md` / `CLAUDE.md`
   (or run `install.sh --agent-md`, which writes a marked, replaceable section).
   They exist because the obvious readings are wrong — a two-second red is not
   a test failure, a GitHub merge commit is not your `HEAD`, and a cancelled
   deploy reports as a *successful* status.

There is a copy-paste [agent prompt](prompts/agent-setup.md) if you would rather
have an AI do the setup.

## Configure

`ci-local.conf` is sourced by the script, so anything bash can run is a step:

```sh
step "<label>" <kind> "<command>"
```

`kind` only decides what the cheap flags skip:

| kind | `--fast` | `--no-install` | `--no-build` |
| --- | --- | --- | --- |
| `install` | skipped | skipped | runs |
| `build` | skipped | runs | skipped |
| anything else (`check`, `test`, …) | runs | runs | runs |

```sh
step "install"   install "bun install --frozen-lockfile"
step "typecheck" check   "bun run lint"
step "test"      check   "cd apps/web && bun run test"
step "build"     build   "bun run build"
```

Commands run through `bash -c` from the repository root. See
[`ci-local.conf.example`](ci-local.conf.example) for Node, Python and Go.

## Commands

| command | does |
| --- | --- |
| `./scripts/local-ci.sh` | every step |
| `./scripts/local-ci.sh --fast` | steps that are not `install`/`build` |
| `./scripts/local-ci.sh --changed` | exit 0 when every change is markdown |
| `./scripts/local-ci.sh --status` | run every step, then post the `ci/local` status for `HEAD` |
| `./scripts/local-ci.sh --status --sha <sha>` | same, for `<sha>` (any rev, e.g. `origin/main`) when its tree matches `HEAD` |
| `./scripts/local-ci.sh --auto` | exit 0 when GitHub Actions is still running this repo |
| `./scripts/local-ci.sh --mode` | print `actions` or `local` |
| `./scripts/local-ci.sh --list` | print the steps |
| `./scripts/local-ci.sh --secrets` | gitleaks on the commits this push would publish |
| `./scripts/local-ci.sh --install-hook` | make `git push` run `--auto --fast --changed` |

Exit codes: `0` passed (or nothing to do), `1` a step failed, `2` could not run.

`--mode` reads the newest **completed** run on the repository: any step at all
means Actions is executing; zero steps everywhere means the minutes are spent.
It is cached for five minutes in the git dir. Anything unknown — no `gh`, no
auth, an API error — answers `local`, because the safe direction is to do the
checks.

`--status` refuses a dirty working tree: a green run there describes the tree,
not the commit you are attesting. Post it **after** pushing. `--sha` attests a
different commit — the one a UI merge created — but only when its tree is
identical to `HEAD`'s; see [Releasing](#releasing).

`--status` also refuses `--fast`, `--no-install` and `--no-build`. A run that
skipped the install or the build cannot support "this commit passed the suite",
and the gate only sees the state, not the caveat. If you deliberately want the
weaker claim, set `CI_ATTEST_PARTIAL=1`; the status description then records
which kinds were skipped.

## Secrets

The pre-push hook runs [`gitleaks`](https://github.com/gitleaks/gitleaks) over the
commits the push would publish — not the whole history, so a legacy leak does not
block every push — and stops the push if it finds one. It is optional: without
the binary the scan is skipped with a note, because a missing tool must never
become a missing push.

```sh
brew install gitleaks                                                  # macOS
# linux: https://github.com/gitleaks/gitleaks/releases (single binary)

./scripts/local-ci.sh --secrets                                        # by hand
CI_SECRETS_RANGE=origin/main..HEAD ./scripts/local-ci.sh --secrets     # one range
```

Why this is worth the one `brew install`: GitHub's secret scanning and push
protection are **free for public repositories** and part of the paid Secret
Protection SKU for private ones ($19 per active committer per month, sold to
organisations). A private repository on a free plan gets **no server-side scan at
all** — the alerts API answers 404 — and git history is forever. gitleaks is
MIT-licensed, runs offline, and reads that history.

It is also not the same question as the gate. The gate decides *whether a commit
was checked*; this decides *whether the commit is safe to publish*. Nothing
downstream will ever un-publish a key.

## The Vercel half

```json
{
  "ignoreCommand": "node scripts/vercel-gate.mjs"
}
```

Vercel's convention for this command is inverted: **exit 0 skips the build, exit
1 builds**. The script prints its decision (`[ci-gate] BUILD — …` /
`[ci-gate] SKIP — …`) into the deployment log.

**Monorepos:** the ignore command runs inside the project's **Root Directory**,
so the gate has to be reachable from there. Either put it inside that folder
(`apps/web/scripts/vercel-gate.mjs`, referenced as `node
scripts/vercel-gate.mjs`) or leave it at the repo root and point up
(`node ../../scripts/vercel-gate.mjs`). The first is the safer of the two: the
path stays valid if you ever change the Root Directory back to the repo.

### The token

Create a **fine-grained personal access token**, scoped to that one repository,
with exactly two permissions:

| Permission | Access | Why |
| --- | --- | --- |
| Actions | Read-only | to read the run and whether it executed |
| Commit statuses | Read-only | to read the `ci/local` attestation |
| Metadata | Read-only (implied) | GitHub adds it |

Store it in Vercel → Project → Settings → Environment Variables as
`GITHUB_READ_TOKEN` for **Production** (and Preview, if you gate those too).

Both permissions are load-bearing. With Actions alone, `GET
/commits/<sha>/statuses` answers **403**, and a 403 is indistinguishable from
"no attestation" — which is a skip. The gate logs the difference:

```
[ci-gate] cannot read ci/local: GitHub returned 403 Forbidden — GITHUB_READ_TOKEN needs "Commit statuses: read-only" as well as Actions
```

The token is fail-closed on purpose: missing or expired means skip, not build.

## Releasing

The gate decides per commit, so two things matter more than any flag.

### Attest the commit Vercel builds, not the one you have checked out

A pull request merged through the GitHub UI becomes a **new merge commit**. Your
clone does not have it until you fetch, and a green run on the branch head says
nothing about it — that `ci/local` status sits on the branch head, where nothing
deploys.

```sh
git fetch origin main
./scripts/local-ci.sh --status --sha "$(git rev-parse origin/main)"
```

`--sha` runs the suite on the current (clean) tree and posts the statuses to the
named commit, but only when that commit's tree is identical to `HEAD`'s. When it
is not, the script refuses instead of vouching for code it did not run. The
honest ways to get a matching tree are to check the commit out (`git switch
--detach <sha>`) or to merge locally and push, so that `HEAD` *is* the commit
Vercel builds. It takes any rev, so `--sha origin/main` is the shortest correct
form after a UI merge.

`pending` is posted before the first step, so the gate waits for the suite
instead of guessing; `success`/`failure` follows. That only works while the
suite finishes inside `CI_GATE_TIMEOUT_MS` (12 minutes by default). A slower
suite must raise that variable in Vercel, or it cancels its own deploy. A
`ci/local` **error** state means the local run aborted: the gate reads it as no
pass and skips, so rerun it and redeploy.

### If the gate already gave up, redeploy — do not push again

A cancelled deployment does not re-read the attestation when one appears later.
Attest, then redeploy **that same deployment** (Vercel → Deployments → ⋯ →
Redeploy, or `vercel redeploy <url>`). An empty "trigger" commit is not a retry:
it puts a fresh sha in the gate's path with no evidence either.

### Never release with `vercel --prod`

A CLI deploy skips `ignoreCommand` entirely and uploads the working tree,
uncommitted changes included. The deployment carries no commit metadata, so
nothing can tie production to a sha — and `git log` stops describing what is
live. If it is genuinely the only way out, run the full suite on that exact tree
first and say in the release note that the deployment is unattested.

## Verifying a release

**A cancelled gated build is reported by Vercel as a successful commit status.**
So `state: success` is not proof that anything shipped, and a "deploy status"
helper that reads the combined commit status will report a gate cancellation as
a release. The gate cannot change what Vercel writes; the check has to.

Proof is a **READY production deployment whose commit metadata is the sha you
meant to ship**:

```sh
vercel ls --environment production --json \
  | jq -r '(.deployments // .)[] | select(.state == "READY")
           | "\(.meta.githubCommitSha // "-")  \(.url)"' | head
```

A `-` in the first column is a CLI deployment with no commit behind it.
`vercel inspect <url>` shows the same metadata.

If the CLI ever emits a raw control byte — it can pick one up from a commit
message — `jq` rejects the whole payload before printing anything. Strip the
bytes JSON forbids inside strings first:
`... --json | LC_ALL=C tr -d '\000-\010\013\014\016-\037' | jq ...`.

## Limits worth knowing before you rely on this

- **The attestation is self-asserted.** `ci/local` is a commit status your own
  machine posted. GitHub did not verify anything. That is fine for a solo
  repository; on a team it means "a laptop ran the suite", not "CI ran".
- **A partial suite cannot be attested.** `--status` refuses the skip flags: a
  run that never installed or built is not the green the gate reads.
  `CI_ATTEST_PARTIAL=1` is the explicit exception, written into the status.
- **A skipped deployment is not free.** Vercel counts a cancelled deployment
  against the plan's daily deployment quota, and it holds a build slot while the
  gate waits. A month in local mode is cheap, but not free.
- **The gate waits, then gives up.** No attestation means up to
  `CI_GATE_TIMEOUT_MS` (12 minutes) of polling, then skip. Attest first, then
  deploy, and you never see the wait. A late attestation does not revive a
  cancelled deployment: redeploy it.
- **The commit Vercel builds may not be your `HEAD`.** A UI merge is a new merge
  commit. `--sha` attests it when the trees match; otherwise check it out and run
  `--status` there.
- **A slow suite cancels its own deploy.** The gate stops waiting after
  `CI_GATE_TIMEOUT_MS` even when a `pending` attestation is there. If the suite
  is longer than that, raise the variable in Vercel.
- **A cancelled deployment is reported as a successful status.** Vercel writes
  `Vercel: success — Canceled by Ignored Build Step`, so the combined commit
  status cannot distinguish "shipped" from "skipped". Verify from the
  deployment's commit metadata (see [Verifying a release](#verifying-a-release)).
- **A CLI deploy escapes the gate.** `vercel --prod` uploads the working tree and
  produces a deployment with no commit metadata; do not use it as a release
  path.
- **`ignoreCommand` in `vercel.json` beats the project setting.** Setting
  `commandForIgnoringBuildStep` on the project does not override the file; only
  editing the file (or Vercel's per-deploy "Use project's Ignore Build Step"
  checkbox) changes the gate.
- **No CI run at all builds after the grace.** That is deliberate for docs-only
  pushes. It also means that if Actions is disabled outright for the repository,
  the gate becomes a 90-second delay rather than a gate. If you need stronger
  guarantees, keep a workflow that always runs.
- It is not a CI server. Nothing runs it for you, there is no remote runner, no
  artifact upload, and no PR enforcement — it is the same commands, on a machine
  you already have.

## FAQ

**My deploy says "Canceled by Ignored Build Step".**
The gate skipped it: CI concluded a failure, or there was no attestation for that
commit. The deployment log says which (`[ci-gate] SKIP — …`). For the second
case, attest the sha Vercel built (`--status --sha <sha>`), then redeploy that
deployment. Do not read the cancellation as a failure either: Vercel reports it
as a *successful* commit status, so check the deployment's commit metadata before
calling anything shipped.

**Do I have to change anything when the minutes reset?**
No. `--mode` starts answering `actions` again within five minutes, the hook steps
aside, and the gate prefers a run that actually executed.

**Does this work on a paid plan?**
Yes — it is a fallback, not a replacement. The gate still prefers GitHub's verdict
whenever GitHub actually ran the job.

**Why not just make the check required?**
Required status checks are a branch-protection feature on paid plans. On a free
plan this is the same idea pushed into the deploy step.

## License

[MIT](LICENSE). Extracted from the CI setup of [Whoa!](https://whoa.design).
