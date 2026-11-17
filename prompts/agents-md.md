# Copy-paste block for the repository's agent instructions

`install.sh` and the setup prompt leave this file untouched: `AGENTS.md`,
`CLAUDE.md`, `CONTRIBUTING.md` and friends belong to the repository, and an
installer that edits them is an installer people stop running.

Append the block below once, after `ci-local.conf` mirrors the workflow and the
Vercel gate is in place. It is the part an agent cannot infer from the code: why
a two-second red is not its bug, which commit to attest, and why a Vercel
"success" does not mean a deploy happened. Everything here is true for any
repository using local-ci — adjust only paths and the default branch if yours
differ.

---

```md
## CI and production deploys (local-ci)

This repository uses local-ci: the same checks as its GitHub workflow, runnable
on this machine, plus a Vercel build gate that accepts them when GitHub Actions
has no minutes left. The mirror lives in `ci-local.conf`; the gate is
`vercel-gate.mjs` (referenced from `vercel.json` as `ignoreCommand`).

### Checking a change

- `./scripts/local-ci.sh` runs every step in `ci-local.conf`, in the workflow's
  order, and stops at the first failure.
- `git push` runs the fast subset (secrets scan, then everything except
  `install`/`build` steps) when the push hook is installed:
  `./scripts/local-ci.sh --install-hook`.
- A GitHub check that fails in ~2 seconds with **no steps, no runner and no log**
  is the free-plan billing block, not a test failure. Do not start debugging the
  code. Run the local suite instead.

### Releasing

Production is gated per commit. The gate builds when the `CI` run for that exact
commit executed and passed; when the run never started, it falls back to the
`ci/local` commit status; with no evidence at all it waits, then cancels the
deployment.

- Attest the **commit Vercel builds**, not the commit you have checked out. A PR
  merged in the GitHub UI becomes a new merge commit that your clone does not
  have until you fetch it:
  ```sh
  git fetch origin main
  ./scripts/local-ci.sh --status --sha "$(git rev-parse origin/main)"
  ```
  `--sha` refuses unless that commit's tree is identical to `HEAD`'s, so keep
  the working tree clean. To avoid the two-step entirely, merge locally and
  push: then `HEAD` is the commit Vercel builds and plain `--status` covers it.
- `--status` posts `pending` before the first step, so the gate waits for the
  suite instead of guessing, then posts `success` or `failure` for that sha.
- If the gated deployment already gave up (it is cancelled after about 12
  minutes), a late status does not revive it: attest, then **redeploy that same
  deployment** (Vercel → Deployments → ⋯ → Redeploy, or
  `vercel redeploy <url>`). Do not push an empty commit to "retry" — the new sha
  starts with no evidence again.
- If the suite takes longer than the gate's window, raise `CI_GATE_TIMEOUT_MS`
  in the Vercel project's production environment (milliseconds). Otherwise a
  slow machine cancels its own deploy.

### Never deploy from the CLI

Do not use `vercel --prod` to release. It bypasses the gate and uploads the
working tree, uncommitted changes included, and the deployment carries no commit
metadata — nothing can tie production to a sha. If it is genuinely the only way
out, run the full local suite on that exact tree first, and say in the release
note that the deployment is unattested.

### Verifying a release

A cancelled gated build is reported by Vercel as a **successful** commit status,
so `state: success` is not proof that anything shipped. Proof is a READY
production deployment whose commit metadata is the sha you meant to ship:

```sh
vercel ls --environment production --json \
  | jq -r '(.deployments // .)[] | select(.state == "READY")
           | "\(.meta.githubCommitSha // "-")  \(.url)"' | head
```

A `-` in the first column is a CLI deployment with no commit behind it.

### Keep it honest

- `ci/local` is self-asserted: it means a machine ran the suite on that tree, not
  that GitHub verified anything.
- Never weaken the gate or delete a step to make a run green.
- Do not edit the vendored `scripts/local-ci.sh` or `scripts/vercel-gate.mjs`;
  sync from upstream instead, or the next update overwrites the change.
```
