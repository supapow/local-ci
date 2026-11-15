#!/usr/bin/env node
/**
 * Vercel "Ignored Build Step": hold a production build until the commit's CI
 * run has finished successfully — and, when GitHub never actually ran it,
 * accept the `ci/local` status that local-ci.sh posts instead.
 *
 * The hole this closes: Vercel builds every push to a connected branch itself,
 * in parallel with CI. A merge made while CI was still running went live first.
 * On a free plan there is a second hole: when the month's minutes are spent,
 * GitHub keeps creating the run and fails it in ~2s with no runner and no
 * steps. That is not a failed test, it is no evidence at all — and reading it
 * as "CI failed" stops every deploy for the rest of the month.
 *
 * Vercel's convention for this command is inverted from most scripts:
 *   exit 0 → skip the build (the deployment is cancelled)
 *   exit 1 → build
 *
 * Behaviour by deployment:
 *   - preview / non-production → build immediately; only releases are gated.
 *   - no GITHUB_READ_TOKEN      → skip. No CI evidence, no release. Fail-closed
 *     on purpose: the site keeps the last good deployment instead of shipping
 *     unchecked work.
 *   - CI pending                → wait (up to CI_GATE_TIMEOUT_MS).
 *   - CI success                → build.
 *   - CI failed / cancelled     → skip, if a runner ever executed it.
 *   - a run that never executed → no evidence: fall back to the attestation.
 *   - no CI run for this sha    → build after CI_GATE_GRACE_MS (markdown-only
 *     pushes are deliberately not built by most workflows).
 *
 * The attestation is a commit status posted by local-ci.sh --status:
 *   - success → build      - pending → wait      - failure → skip
 *   - absent  → skip after the timeout, and say how to produce one
 * A PR merged in the GitHub UI becomes a NEW merge commit: attest that sha, not
 * the branch head, with `local-ci.sh --status --sha <merge-sha>`.
 * A run that DID execute stays authoritative: a real red CI is never
 * overridden by a green laptop.
 *
 * `GITHUB_READ_TOKEN` is a fine-grained PAT with exactly two repository
 * permissions, both read-only: **Actions** (to read the run) and **Commit
 * statuses** (to read the attestation; Actions alone answers that endpoint with
 * 403, which reads as "no attestation" and skips every release).
 *
 * Env:
 *   CI_WORKFLOW_NAME         default "CI"
 *   CI_ATTESTATION_CONTEXT   default "ci/local"
 *   CI_GATE_GRACE_MS         default 90_000
 *   CI_GATE_TIMEOUT_MS       default 720_000
 *   CI_GATE_POLL_MS          default 10_000
 *   CI_GATE_API              testing only; points the gate at a stub API
 *
 * Two things learned the hard way, worth knowing before you change this:
 *   - `commandForIgnoringBuildStep` in the project settings does NOT beat
 *     `ignoreCommand` in vercel.json. The file is the gate; toggling the
 *     project field changes nothing.
 *   - A cancelled deployment still counts against the plan's daily deployment
 *     quota and holds a build slot while this script waits. A month of
 *     un-attested pushes is cheap, but not free.
 */

const OWNER = process.env.VERCEL_GIT_REPO_OWNER
const REPO = process.env.VERCEL_GIT_REPO_SLUG
const SHA = process.env.VERCEL_GIT_COMMIT_SHA
const ENVIRONMENT = process.env.VERCEL_ENV
const TOKEN = process.env.GITHUB_READ_TOKEN

const API = process.env.CI_GATE_API ?? 'https://api.github.com'
const WORKFLOW_NAME = process.env.CI_WORKFLOW_NAME ?? 'CI'
const CONTEXT = process.env.CI_ATTESTATION_CONTEXT ?? 'ci/local'
const GRACE_MS = Number(process.env.CI_GATE_GRACE_MS ?? 90_000)
const TIMEOUT_MS = Number(process.env.CI_GATE_TIMEOUT_MS ?? 12 * 60_000)
const POLL_MS = Number(process.env.CI_GATE_POLL_MS ?? 10_000)

const log = (...args) => console.log('[ci-gate]', ...args)
const build = (why) => {
  log(`BUILD — ${why}`)
  process.exit(1)
}
const skip = (why) => {
  log(`SKIP — ${why}`)
  process.exit(0)
}

// Preview deployments answer to their branch, not to production.
if (ENVIRONMENT !== 'production') build(`VERCEL_ENV=${ENVIRONMENT ?? 'unset'} is not "production"`)
// A CLI deploy or a redeploy without git metadata has no commit to check.
if (!OWNER || !REPO || !SHA) build('no git commit metadata (VERCEL_GIT_* is unset)')
if (!TOKEN) skip('GITHUB_READ_TOKEN is not configured, so CI cannot be verified')

const headers = {
  Accept: 'application/vnd.github+json',
  Authorization: `Bearer ${TOKEN}`,
  'X-GitHub-Api-Version': '2022-11-28',
}

/** The push-triggered run for this exact commit, or null while none exists. */
async function findCiRun() {
  const url = `${API}/repos/${OWNER}/${REPO}/actions/runs?head_sha=${SHA}&event=push&per_page=100`
  const response = await fetch(url, { headers, signal: AbortSignal.timeout(20_000) })
  if (!response.ok) throw new Error(`GitHub returned ${response.status} ${response.statusText}`)
  const body = await response.json()
  const runs = Array.isArray(body?.workflow_runs) ? body.workflow_runs : []
  return runs.find((run) => run.name === WORKFLOW_NAME) ?? null
}

/**
 * Did this run ever have a runner?
 *
 * A billing-blocked run still exists and is `completed/failure`, but its job has
 * `steps: []` and an empty `runner_name` — it never started. A run that executed
 * always has at least one step, so zero steps everywhere means "no evidence",
 * not "red". Any lookup failure answers `true`: the conservative reading, which
 * leaves a genuine failure authoritative.
 */
const executedRuns = new Map()
async function runExecuted(run) {
  if (executedRuns.has(run.id)) return executedRuns.get(run.id)
  let executed = true
  try {
    const url = `${API}/repos/${OWNER}/${REPO}/actions/runs/${run.id}/jobs?per_page=100`
    const response = await fetch(url, { headers, signal: AbortSignal.timeout(20_000) })
    if (response.ok) {
      const body = await response.json()
      const jobs = Array.isArray(body?.jobs) ? body.jobs : []
      executed = jobs.some((job) => (job.steps?.length ?? 0) > 0 || job.runner_name)
    }
  } catch {
    // keep the conservative default
  }
  if (run.status === 'completed') executedRuns.set(run.id, executed)
  return executed
}

/** The newest attestation for this sha, posted by `local-ci.sh --status`. */
async function localAttestation() {
  const url = `${API}/repos/${OWNER}/${REPO}/commits/${SHA}/statuses?per_page=100`
  const response = await fetch(url, { headers, signal: AbortSignal.timeout(20_000) })
  if (!response.ok) throw new Error(`GitHub returned ${response.status} ${response.statusText}`)
  const body = await response.json()
  const statuses = Array.isArray(body) ? body : []
  const mine = statuses.find((status) => status.context === CONTEXT)
  return mine ? { state: mine.state, description: mine.description ?? '' } : null
}

const short = SHA.slice(0, 8)
const startedAt = Date.now()
let lastState = ''

/** What the attestation says, once Actions is out of the picture. */
async function settleOnAttestation(why, otherwise) {
  let attestation = null
  let unreadable = false
  try {
    attestation = await localAttestation()
  } catch (error) {
    // A 403 here is a token-scope problem, not a missing attestation.
    unreadable = true
    const message = error?.message ?? String(error)
    if (/\b(403|401)\b/.test(message)) {
      log(`cannot read ${CONTEXT}: ${message} — GITHUB_READ_TOKEN needs "Commit statuses: read-only" as well as Actions`)
    } else {
      log(`${CONTEXT} lookup failed: ${message}`)
    }
  }
  if (attestation?.state === 'success') {
    build(`${why}; ${CONTEXT} attested this commit — ${attestation.description}`)
  }
  if (attestation?.state === 'failure') {
    skip(`${why}; local CI attested a failure — ${attestation.description}`)
  }
  if (attestation?.state === 'pending') {
    if (lastState !== 'local/pending') {
      log(`waiting for local CI to finish — ${attestation.description}`)
      lastState = 'local/pending'
    }
    return false
  }
  if (!unreadable && lastState !== 'local/missing') {
    log(`no ${CONTEXT} attestation for this commit — post one with: ./scripts/local-ci.sh --status --sha ${SHA}`)
    lastState = 'local/missing'
  }
  return otherwise()
}

for (;;) {
  let run = null
  try {
    run = await findCiRun()
  } catch (error) {
    // A transient API failure is not a reason to publish unchecked work; keep
    // polling until the overall timeout decides.
    log(`CI lookup failed: ${error?.message ?? error}`)
  }

  if (run) {
    const state = `${run.status}/${run.conclusion ?? 'pending'}`
    if (state !== lastState) {
      log(`CI ${state} — ${run.html_url ?? ''}`.trim())
      lastState = state
    }
    if (run.status === 'completed') {
      if (run.conclusion === 'success') build('CI passed')
      // A completed run is authoritative only if a runner ever picked it up.
      if (await runExecuted(run)) skip(`CI concluded "${run.conclusion}"`)
      if (lastState !== 'no-runner') {
        log(`CI ${short} never ran (no steps, no runner) — billing block? waiting for an attestation`)
        lastState = 'no-runner'
      }
      await settleOnAttestation(`CI never ran for ${short}`, () => false)
    }
  } else {
    await settleOnAttestation(`no CI run for ${short} yet`, () => {
      if (lastState !== 'none') {
        log('no CI run for this commit (markdown-only pushes are often not built)')
        lastState = 'none'
      }
      if (Date.now() - startedAt >= GRACE_MS) build('no CI run for this commit')
      return false
    })
  }

  if (Date.now() - startedAt >= TIMEOUT_MS) {
    skip(
      `CI did not finish within ${Math.round(TIMEOUT_MS / 60_000)} minutes — ` +
      (lastState === 'local/missing' || lastState === 'no-runner'
        ? `nothing attested ${short}: run ./scripts/local-ci.sh --status --sha ${SHA}, then redeploy this deployment`
        : `if the suite is simply slower than this window, raise CI_GATE_TIMEOUT_MS`),
    )
  }

  await new Promise((resolve) => setTimeout(resolve, POLL_MS))
}
