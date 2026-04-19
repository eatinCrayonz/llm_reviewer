# Codex/Claude Review Loop

This repo now contains a Windows-friendly orchestration script that runs:

- Claude as the implementer
- Codex as the reviewer
- a strict review loop with a hard round cap
- an attested test gate before every review
- an implementer-claim check before Codex is asked to review
- optional lint, typecheck, mutation, and coverage gates
- optional per-round snapshot branches without switching your working tree

The key contract is simple:

1. You provide an explicit task.
2. Claude edits the repo to satisfy that task.
3. Claude must explicitly report which files it claims to have changed.
4. The script cross-checks those claims against `git diff --name-only HEAD` in both directions.
5. The script runs configured gates and can mechanically fail the round before Codex is called.
6. Codex reviews the produced diff against the original task, with attested gate results attached as ground truth.
7. The loop stops on `pass` or after `MaxRounds`.

## Files

- [review-loop.ps1](C:/Users/eatin/Documents/GitHub/codex_claude_control_script/review-loop.ps1)
- [schemas/review-result.schema.json](C:/Users/eatin/Documents/GitHub/codex_claude_control_script/schemas/review-result.schema.json)

## Prerequisites

- `git.exe` in `PATH`
- `claude.cmd` in `PATH`
- `codex.cmd` in `PATH`
- Both CLIs already authenticated
- A clean git working tree before you start
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

You can also set a default in [.review-loop.json.example](C:/Users/eatin/Documents/GitHub/codex_claude_control_script/.review-loop.json.example) by copying it to `.review-loop.json`:

```json
{
  "testCommand": "npm test -- --runInBand",
  "lintCommand": "npm run lint",
  "typecheckCommand": "npm run typecheck",
  "mutationCommand": "",
  "coverageCommand": "",
  "coverageLcovPath": "coverage/lcov.info",
  "verifyAddedTestsRan": true,
  "preserveRounds": true,
  "roundBranchPrefix": "review-loop"
}
```

## What It Enforces

- The implementer and reviewer are separate tools.
- Claude must emit a structured self-report with claimed changed files.
- The script rejects implementer claims that do not match `git diff --name-only HEAD`.
- The script also rejects diff files that Claude failed to claim.
- Codex runs the review in `read-only` sandbox mode.
- Codex runs with `--ephemeral` so each review starts fresh.
- Codex can inspect the repo read-only for surrounding context.
- The review payload includes attested test results before Codex renders a verdict.
- Optional lint, typecheck, mutation, and coverage commands can mechanically fail the round before review.
- Optional gate commands run in an isolated temporary worktree so their artifacts do not contaminate the main working tree.
- Optional added-test verification checks that newly-added test identifiers appear in test output.
- Optional LCOV checking verifies changed production lines are covered before review.
- The reviewer result must match the JSON schema.
- The reviewer can escalate ambiguity with `needs_clarification`.
- The review contract uses structured issues instead of free-form strings.
- Each model invocation has a timeout.
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

## Important Limitation

This script intentionally refuses to run if the working tree is already dirty. That keeps the reviewer focused on changes caused by the current task instead of unrelated local edits.

Current limitations:

- Added-test verification is heuristic and works best when your test command prints test names.
- LCOV checking is opt-in and expects a standard `lcov.info` style report.
- Round preservation uses branch refs, not separate worktrees.
