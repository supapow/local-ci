# local-ci

**GitHub's checks, on your machine, when the minutes run out — and a Vercel
build gate that believes them.**

[![CI](https://github.com/supapow/local-ci/actions/workflows/ci.yml/badge.svg)](https://github.com/supapow/local-ci/actions/workflows/ci.yml)

Two small files and a hook. No service, no account, no npm package.

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
| Minutes spent | `./scripts/local-ci.sh` | You run `--status`, the gate reads the attestation |

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

There is a copy-paste [agent prompt](prompts/agent-setup.md) if you would rather
have an AI do 1–5.

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
| `./scripts/local-ci.sh --status` | run, then post the `ci/local` commit status |
| `./scripts/local-ci.sh --auto` | exit 0 when GitHub Actions is still running this repo |
| `./scripts/local-ci.sh --mode` | print `actions` or `local` |
| `./scripts/local-ci.sh --list` | print the steps |
| `./scripts/local-ci.sh --install-hook` | make `git push` run `--auto --fast --changed` |

Exit codes: `0` passed (or nothing to do), `1` a step failed, `2` could not run.

`--mode` reads the newest **completed** run on the repository: any step at all
means Actions is executing; zero steps everywhere means the minutes are spent.
It is cached for five minutes in the git dir. Anything unknown — no `gh`, no
auth, an API error — answers `local`, because the safe direction is to do the
checks.

`--status` refuses a dirty working tree: a green run there describes the tree,
not the commit you are attesting. Post it **after** pushing.

## The Vercel half

```json
{
  "ignoreCommand": "node scripts/vercel-gate.mjs"
}
```

Vercel's convention for this command is inverted: **exit 0 skips the build, exit
1 builds**. The script prints its decision (`[ci-gate] BUILD — …` /
`[ci-gate] SKIP — …`) into the deployment log.

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

## Limits worth knowing before you rely on this

- **The attestation is self-asserted.** `ci/local` is a commit status your own
  machine posted. GitHub did not verify anything. That is fine for a solo
  repository; on a team it means "a laptop ran the suite", not "CI ran".
- **A skipped deployment is not free.** Vercel counts a cancelled deployment
  against the plan's daily deployment quota, and it holds a build slot while the
  gate waits. A month in local mode is cheap, but not free.
- **The gate waits, then gives up.** No attestation means up to
  `CI_GATE_TIMEOUT_MS` (12 minutes) of polling, then skip. Attest first, then
  deploy, and you never see the wait.
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
commit. The deployment log says which (`[ci-gate] SKIP — …`).

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
