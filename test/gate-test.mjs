/**
 * The gate's contract, against a stub GitHub API.
 *
 *   node test/gate-test.mjs
 *
 * Cheap because it is the one piece that can silently stop a release: every
 * case here is a decision `vercel-gate.mjs` makes about a production deploy.
 */
import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const gate = join(root, 'vercel-gate.mjs')

const scenario = {
  run: null, // { status, conclusion, steps: n, runner: bool }
  attestation: null, // 'success' | 'failure' | 'pending' | null
}

const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost')
  const send = (body) => {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify(body))
  }

  if (url.pathname.endsWith('/actions/runs')) {
    return send({ workflow_runs: scenario.run ? [{ id: 7, name: 'CI', ...scenario.run }] : [] })
  }
  if (url.pathname.endsWith('/actions/runs/7/jobs')) {
    const steps = scenario.run?.steps ?? 0
    return send({ jobs: [{ steps: Array.from({ length: steps }, (_, i) => ({ name: `s${i}` })), runner_name: scenario.run?.runner ? 'GitHub Actions 3' : '' }] })
  }
  if (url.pathname.endsWith('/statuses')) {
    return send(scenario.attestation ? [{ context: 'ci/local', state: scenario.attestation, description: 'stub' }] : [])
  }
  res.writeHead(404)
  res.end('{}')
})

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
const base = `http://127.0.0.1:${server.address().port}`

function runGate(env) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [gate], {
      cwd: root,
      env: {
        ...process.env,
        VERCEL_GIT_REPO_OWNER: 'o',
        VERCEL_GIT_REPO_SLUG: 'r',
        VERCEL_GIT_COMMIT_SHA: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
        CI_GATE_API: base,
        CI_GATE_POLL_MS: '40',
        CI_GATE_GRACE_MS: '150',
        CI_GATE_TIMEOUT_MS: '2500',
        ...env,
      },
    })
    let out = ''
    child.stdout.on('data', (d) => { out += d })
    child.stderr.on('data', (d) => { out += d })
    child.on('close', (code) => resolve({ code, out }))
  })
}

let pass = 0
let fail = 0
const check = (name, expected, actual) => {
  if (expected === actual) { pass++; console.log(`  ✓ ${name}`) }
  else { fail++; console.log(`  ✗ ${name} (expected ${expected}, got ${actual})`) }
}

console.log('vercel-gate contract')

// 1. previews are never gated
scenario.run = { status: 'completed', conclusion: 'failure', steps: 1, runner: true }
check('preview builds', 1, (await runGate({ VERCEL_ENV: 'preview', GITHUB_READ_TOKEN: 'x' })).code)

// 2. no token is fail-closed
check('no token skips', 0, (await runGate({ VERCEL_ENV: 'production' })).code)

// 3. a real red CI is authoritative
scenario.run = { status: 'completed', conclusion: 'failure', steps: 4, runner: true }
scenario.attestation = 'success'
check('a run that executed and failed still skips', 0, (await runGate({ VERCEL_ENV: 'production', GITHUB_READ_TOKEN: 'x' })).code)

// 4. a real green CI builds
scenario.run = { status: 'completed', conclusion: 'success', steps: 4, runner: true }
scenario.attestation = null
check('a run that executed and passed builds', 1, (await runGate({ VERCEL_ENV: 'production', GITHUB_READ_TOKEN: 'x' })).code)

// 5. a run that never started is no evidence: attestation decides
scenario.run = { status: 'completed', conclusion: 'failure', steps: 0, runner: false }
scenario.attestation = 'success'
check('a never-run job + attestation builds', 1, (await runGate({ VERCEL_ENV: 'production', GITHUB_READ_TOKEN: 'x' })).code)

// 6. same, but the local suite said no
scenario.attestation = 'failure'
check('a never-run job + local failure skips', 0, (await runGate({ VERCEL_ENV: 'production', GITHUB_READ_TOKEN: 'x' })).code)

// 7. same, but nobody attested: wait out the window, then skip
scenario.attestation = null
check('a never-run job with no attestation skips', 0, (await runGate({ VERCEL_ENV: 'production', GITHUB_READ_TOKEN: 'x' })).code)

// 7b. a local run that errored is not evidence of a pass
scenario.attestation = 'error'
check('a never-run job + local error skips', 0, (await runGate({ VERCEL_ENV: 'production', GITHUB_READ_TOKEN: 'x' })).code)

// 8. no run at all (markdown-only push) builds after the grace
scenario.run = null
scenario.attestation = null
check('no run at all builds after the grace', 1, (await runGate({ VERCEL_ENV: 'production', GITHUB_READ_TOKEN: 'x' })).code)

server.close()
console.log()
if (fail === 0) {
  console.log(`all ${pass} checks passed`)
  process.exit(0)
}
console.log(`${fail} of ${pass + fail} checks failed`)
process.exit(1)
