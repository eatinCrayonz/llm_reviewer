# Codex/Claude Review Loop

This repo now contains a Windows-friendly orchestration script that runs:

- Codex as the implementer
- Claude as the reviewer/proofreader
- a strict review loop with a hard round cap
- phase-gated runs where each invocation handles only the task you provide
- an attested test gate before every review
- an implementer-claim check before Claude is asked to review
- optional lint, typecheck, mutation, and coverage gates
- subscription-backed CLI auth by default, with metered API-key auth as an explicit opt-in
- optional per-round snapshot branches without switching your working tree

The key contract is simple:

1. You provide an explicit task.
2. Codex edits the repo to satisfy that task.
3. Codex must explicitly report which files it claims to have changed.
4. The script cross-checks those claims against `git diff --name-only HEAD` in both directions.
5. The script runs configured gates and can mechanically fail the round before Claude is called.
6. Claude reviews the produced diff against the original task, with attested gate results attached as ground truth.
7. The loop stops on `pass` or after `MaxRounds`.
8. You start the next phase yourself with a new task when you are ready.

## Files

- [review-loop.ps1](review-loop.ps1)
- [schemas/review-result.schema.json](schemas/review-result.schema.json)

## Prerequisites

- `git.exe` in `PATH`
- `claude.cmd` in `PATH`
- `codex.cmd` in `PATH`
- Both CLIs already authenticated
- Subscription-backed CLI auth is the default expectation. The script refuses to run agent calls when `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` are present unless you pass `-AllowApiKeyAuth`.
- At least one commit in the repository, so `git diff HEAD` has a baseline
- A repo-level test command supplied either with `-TestCommand` or via `.review-loop.json`
- If you enable changed-line coverage checks, an LCOV report path that exists after your configured commands run

## Usage

Run it from inside the repository:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\review-loop.ps1 "Add input validation to the parseArgs function"
```

Optional:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\review-loop.ps1 "Add input validation to the parseArgs function" -MaxRounds 4
```

If your project needs a specific test command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\review-loop.ps1 "Add input validation to the parseArgs function" -TestCommand "npm test -- --runInBand"
```

Additional gate example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\review-loop.ps1 "Add input validation to the parseArgs function" -TestCommand "npm test -- --runInBand" -LintCommand "npm run lint" -TypecheckCommand "npm run typecheck" -VerifyAddedTestsRan -CoverageLcovPath "coverage/lcov.info"
```

Pick explicit CLI models when you do not want the nested tools to use their defaults:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\review-loop.ps1 "Add input validation to the parseArgs function" -ImplementerModel "your-codex-model" -ReviewerModel "your-claude-model"
```

Ask before each model call:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\review-loop.ps1 "Add input validation to the parseArgs function" -ConfirmAgentCalls
```

Allow metered API-key auth only when you explicitly want it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\review-loop.ps1 "Add input validation to the parseArgs function" -AllowApiKeyAuth
```

You can also set defaults in `.review-loop.json`:

```json
{
  "testCommand": "npm test -- --runInBand",
  "lintCommand": "npm run lint",
  "typecheckCommand": "npm run typecheck",
  "mutationCommand": "",
  "coverageCommand": "",
  "coverageLcovPath": "coverage/lcov.info",
  "implementerModel": "",
  "reviewerModel": "",
  "confirmAgentCalls": false,
  "allowApiKeyAuth": false,
  "verifyAddedTestsRan": true,
  "preserveRounds": true,
  "roundBranchPrefix": "review-loop"
}
```

## Phase-Gated Workflow

Use one invocation for one plan phase. The script will let Codex and Claude iterate only on the task string you provide, then stop on `pass`, `needs_clarification`, or the configured round cap. It will not move on to the next phase of your plan until you run it again with that next phase as the new task.

## What It Enforces

- The implementer and reviewer are separate tools.
- Each run prints the selected agent models, auth policy, and confirmation policy before the first round starts.
- API-key backed agent auth is blocked by default so the CLIs use their subscription-backed sign-in paths when available.
- Codex must emit a structured self-report with claimed changed files.
- The script rejects implementer claims that do not match `git diff --name-only HEAD`.
- The script also rejects diff files that Codex failed to claim.
- Codex runs implementation with `workspace-write` sandbox mode.
- Codex runs with `--ephemeral` so each implementation attempt starts fresh.
- Claude is instructed to review/proofread only and not apply edits.
- The review payload includes attested test results before Claude renders a verdict.
- Optional lint, typecheck, mutation, and coverage commands can mechanically fail the round before review.
- Optional gate commands run in an isolated temporary worktree so their artifacts do not contaminate the main working tree.
- Optional added-test verification checks that newly-added test identifiers appear in test output.
- Optional LCOV checking verifies changed production lines are covered before review.
- The reviewer result must match the JSON schema.
- The reviewer can escalate ambiguity with `needs_clarification`.
- The review contract uses structured issues instead of free-form strings.
- Each model invocation has a timeout.
- Optional `-ConfirmAgentCalls` pauses before each model invocation.
- Gate output passed to the reviewer is capped to the configured tail length.
- Review diffs are capped to avoid silent context-window blowups.
- Oversized diffs are fed back as blocker issues instead of crashing the loop.
- Optional round snapshot branches preserve each attempt without switching your current checkout.
- The loop is capped to avoid infinite back-and-forth.

## Local Artifacts

Each run writes temporary state to `.review-loop/`:

- per-round implementer output
- per-round claimed-file snapshots
- per-round diff snapshots
- per-round gate output when commands run
- the latest reviewer JSON
- optional per-round snapshot branch names

That directory is ignored by git via `.gitignore`.

Current limitations:

- Added-test verification is heuristic and works best when your test command prints test names.
- LCOV checking is opt-in and expects a standard `lcov.info` style report.
- Round preservation uses branch refs, not separate worktrees.
