# Agent setup prompt

Paste everything in the block below into your coding agent (Claude Code, Codex,
OpenCode, Cursor, …) while it is working inside the repository you want to
protect. It is written to be safe: the agent reads your existing workflow instead
of inventing steps, asks before it changes git config, and never writes a
credential anywhere.

---

```text
Set up local-ci in this repository. It lets the checks keep running when the
GitHub Actions minutes for the month are spent, and lets a Vercel build gate
accept that instead of skipping deploys. Work through the steps in order and
stop to ask me if reality does not match an assumption.

1. Learn what CI already does here.
   - Read .github/workflows/*.yml (or .yaml). List the commands that actually
     check the code: install, typecheck/lint, test, build. Note the working
     directories and the package manager (lockfile in the repo root wins).
   - Do not invent steps that the workflow does not run. This tool mirrors CI;
     it must not quietly become a different, weaker or stronger gate.

2. Fetch and install the two files.
     git clone https://github.com/supapow/local-ci /tmp/local-ci
     /tmp/local-ci/install.sh
   If scripts/local-ci.sh or scripts/vercel-gate.mjs already exist, stop and show
   me the diff instead of overwriting.

3. Write ci-local.conf from what you found in step 1, one line per step:
     step "<label>" <kind> "<command>"
   kind is install | build | check. Use install for dependency installation and
   build for the production build, so --fast can skip them. Keep the workflow's
   order. Example shape:
     step "install"   install "bun install --frozen-lockfile"
     step "typecheck" check   "bun run lint"
     step "test"      check   "cd apps/web && bun run test"
     step "build"     build   "bun run build"

4. Run ./scripts/local-ci.sh --list, then ./scripts/local-ci.sh.
   - If a step fails, report the failure to me with the command and the output.
     Do not change application code, tests or config to make it pass.
   - If a step hangs or needs a service, remove it from the config and tell me
     which one and why.

5. Add the Vercel gate. If vercel.json exists, merge into it and keep every
   existing key:
     "ignoreCommand": "node scripts/vercel-gate.mjs"
   If it does not exist, create it with just that key. If the project is not on
   Vercel, skip this step and say so.

6. The credential is mine to create. Give me exactly these instructions and then
   wait:
   - github.com/settings/personal-access-tokens -> fine-grained token
   - Repository access: only this repository
   - Repository permissions: Actions = Read-only AND Commit statuses = Read-only
   - Store it in Vercel -> Project -> Settings -> Environment Variables as
     GITHUB_READ_TOKEN for Production (and Preview if we gate previews).
   Do not ask me to paste the token into the chat, and never write it to a file.

7. Install the push hook only after asking me: ./scripts/local-ci.sh --install-hook
   (it writes core.hooksPath for this clone; other worktrees of the same clone
   inherit it).

8. Verify and report:
   - ./scripts/local-ci.sh --mode prints "actions" or "local" and why.
   - On a clean tree, ./scripts/local-ci.sh --status runs the suite and posts a
     ci/local commit status. Confirm it with:
       gh api repos/{owner}/{repo}/commits/HEAD/statuses --jq '.[] | select(.context=="ci/local")'
   - ./scripts/local-ci.sh --status must refuse a dirty tree; try it and confirm.

Rules for this whole task:
- Never weaken the gate: do not edit vercel-gate.mjs to always build, do not
  remove steps from ci-local.conf to make a run green, and do not post a
  ci/local success you did not earn.
- Never commit a token, a .env file, or anything from ~/.config/gh.
- statuses and hooks are opt-in. Ask before either.
- If the repo's CI is already red for a real reason, say so and stop; that is not
  this tool's job.

When done, give me: the ci-local.conf you wrote, the vercel.json line, the two
dashboard actions I still have to take (token, and one redeploy with "Use
project's Ignore Build Step" unticked), and the output of --mode.
```

---

## What good looks like

- `./scripts/local-ci.sh` takes roughly as long as the workflow does, and fails
  on the same things.
- `--mode` says `actions` while the account has minutes, `local` when it does
  not, and flips back on its own after the monthly reset.
- A deploy never says *"Canceled by Ignored Build Step"* without a line above it
  in the build log explaining which check was missing.
- The agent never asked for the token, and the token never appears in a diff.
