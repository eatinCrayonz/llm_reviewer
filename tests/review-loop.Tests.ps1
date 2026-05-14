$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "review-loop.ps1"

$previousLibraryMode = $env:REVIEW_LOOP_LIBRARY_MODE
$env:REVIEW_LOOP_LIBRARY_MODE = "1"
. $scriptPath -Task "library-mode"
if ($null -eq $previousLibraryMode) {
    Remove-Item Env:REVIEW_LOOP_LIBRARY_MODE -ErrorAction SilentlyContinue
}
else {
    $env:REVIEW_LOOP_LIBRARY_MODE = $previousLibraryMode
}

function New-ReviewLoopIntegrationFixture {
    param(
        [string]$CodexReport,

        [string]$ClaudeOutput,

        [bool]$CodexEditsFile = $true
    )

    if ([string]::IsNullOrEmpty($CodexReport)) {
        $CodexReport = @'
SUMMARY:
- changed app
CLAIMED_FILES_JSON:
["app.txt"]
'@
    }

    if ([string]::IsNullOrEmpty($ClaudeOutput)) {
        $ClaudeOutput = @'
Looks good.

```json
{"verdict":"pass","issues":[],"scope_creep":false,"blocking_question":null}
```
'@
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    $tempRepo = Join-Path $tempRoot "repo"
    $fakeBin = Join-Path $tempRoot "bin"
    New-Item -ItemType Directory -Path $tempRepo, $fakeBin | Out-Null

    $git = (Get-Command git.exe).Source
    Invoke-ExternalText -FilePath $git -Arguments @("init", "-b", "main") -WorkingDirectory $tempRepo | Out-Null
    "base" | Set-Content -LiteralPath (Join-Path $tempRepo "app.txt") -Encoding ASCII
    Invoke-ExternalText -FilePath $git -Arguments @("add", "app.txt") -WorkingDirectory $tempRepo | Out-Null
    Invoke-ExternalText -FilePath $git -Arguments @("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init") -WorkingDirectory $tempRepo | Out-Null

    $codexReportPath = Join-Path $fakeBin "codex-report.txt"
    Set-Content -LiteralPath $codexReportPath -Value $CodexReport -Encoding ASCII

    $codexEditLine = if ($CodexEditsFile) { "> app.txt echo changed by fake codex" } else { "rem no edit" }
    @"
@echo off
set "out="
:parse
if "%~1"=="" goto done_parse
if "%~1"=="--output-last-message" set "out=%~2"
shift
goto parse
:done_parse
$codexEditLine
if not "%out%"=="" copy /Y "$codexReportPath" "%out%" > nul
type "$codexReportPath"
exit /b 0
"@ | Set-Content -LiteralPath (Join-Path $fakeBin "codex.cmd") -Encoding ASCII

    $claudeOutputPath = Join-Path $fakeBin "claude-output.txt"
    Set-Content -LiteralPath $claudeOutputPath -Value $ClaudeOutput -Encoding ASCII
    @"
@echo off
> claude-called.txt echo called
type "$claudeOutputPath"
exit /b 0
"@ | Set-Content -LiteralPath (Join-Path $fakeBin "claude.cmd") -Encoding ASCII

    return [pscustomobject]@{
        Root = $tempRoot
        Repo = $tempRepo
        Bin = $fakeBin
    }
}

function Invoke-ReviewLoopIntegrationFixture {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Fixture,

        [string]$TestCommand = "if ((Get-Content .\app.txt -Raw) -notmatch 'changed by fake codex') { exit 1 }",

        [string]$CoverageLcovPath
    )

    $previousPath = $env:Path
    try {
        $env:Path = "$($Fixture.Bin);$previousPath"
        $powershell = (Get-Command powershell.exe).Source
        $arguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $scriptPath,
            "Integration smoke phase",
            "-TestCommand", $TestCommand,
            "-MaxRounds", "1"
        )
        if (-not [string]::IsNullOrWhiteSpace($CoverageLcovPath)) {
            $arguments += @("-CoverageLcovPath", $CoverageLcovPath)
        }

        return Invoke-ExternalText `
            -FilePath $powershell `
            -Arguments $arguments `
            -WorkingDirectory $Fixture.Repo `
            -TimeoutSeconds 120 `
            -AllowNonZeroExit
    }
    finally {
        $env:Path = $previousPath
    }
}

Describe "Parse-ImplementerReport" {
    It "parses the canonical format" {
$report = @"
SUMMARY:
- changed parser
CLAIMED_FILES_JSON:
["src/app.js","tests/app.test.js"]
"@

        $result = Parse-ImplementerReport -Output $report

        $result | Should Not BeNullOrEmpty
        $result.Summary | Should Be "- changed parser"
        @($result.ClaimedFiles) | Should Be @("src/app.js", "tests/app.test.js")
    }

    It "tolerates decorated section markers" {
$report = @"
**SUMMARY:**
- changed parser
**CLAIMED_FILES_JSON:**
["./src/app.js"]
"@

        $result = Parse-ImplementerReport -Output $report

        $result | Should Not BeNullOrEmpty
        @($result.ClaimedFiles) | Should Be @("src/app.js")
    }
}

Describe "Resolve-ReviewSchemaPath" {
    It "falls back to the script schema when the target repo has no local schema" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        $repoRoot = Join-Path $tempRoot "repo"
        $scriptRoot = Join-Path $tempRoot "script"
        New-Item -ItemType Directory -Path $repoRoot | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $scriptRoot "schemas") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $scriptRoot "schemas\review-result.schema.json") -Value "{}" -Encoding UTF8

        try {
            $result = Resolve-ReviewSchemaPath -RepoRoot $repoRoot -ScriptRoot $scriptRoot

            $result | Should Be (Join-Path $scriptRoot "schemas\review-result.schema.json")
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "prefers a repo-local schema when one exists" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        $repoRoot = Join-Path $tempRoot "repo"
        $scriptRoot = Join-Path $tempRoot "script"
        New-Item -ItemType Directory -Path (Join-Path $repoRoot "schemas") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $scriptRoot "schemas") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repoRoot "schemas\review-result.schema.json") -Value "{""repo"":true}" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $scriptRoot "schemas\review-result.schema.json") -Value "{""script"":true}" -Encoding UTF8

        try {
            $result = Resolve-ReviewSchemaPath -RepoRoot $repoRoot -ScriptRoot $scriptRoot

            $result | Should Be (Join-Path $repoRoot "schemas\review-result.schema.json")
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "agent command configuration" {
    It "adds a Codex model only when one is configured" {
        $withoutModel = New-CodexImplementerArguments -OutputPath "out.txt" -Model $null
        $withModel = New-CodexImplementerArguments -OutputPath "out.txt" -Model " gpt-test "

        ($withoutModel -contains "--model") | Should Be $false
        $withoutModel[-1] | Should Be "-"
        $withModel | Should Be @("exec", "--model", "gpt-test", "--sandbox", "workspace-write", "--ephemeral", "--output-last-message", "out.txt", "-")
    }

    It "adds a Claude reviewer model only when one is configured" {
        $withoutModel = New-ClaudeReviewerArguments -Model ""
        $withModel = New-ClaudeReviewerArguments -Model " claude-test "

        ($withoutModel -contains "--model") | Should Be $false
        $withModel | Should Be @("-p", "--model", "claude-test", "--input-format", "text", "--output-format", "text", "--no-session-persistence")
    }
}

Describe "Resolve-Setting" {
    It "uses config values when an optional command-line value was not supplied" {
        $config = [pscustomobject]@{
            implementerModel = "codex-config-model"
        }

        $result = Resolve-Setting -ExplicitValue $null -Config $config -ConfigName "implementerModel"

        $result | Should Be "codex-config-model"
    }
}

Describe "Get-ExplicitParameterValue" {
    It "returns the value only when the parameter was supplied" {
        $boundParameters = @{
            MaxRounds = 1
        }

        (Get-ExplicitParameterValue -BoundParameters $boundParameters -Name "MaxRounds" -Value 1) | Should Be 1
        (Get-ExplicitParameterValue -BoundParameters $boundParameters -Name "TestCommand" -Value "") | Should Be $null
    }
}

Describe "Assert-NoApiKeyAuth" {
    It "fails when a guarded API key environment variable is present" {
        $previousValue = [Environment]::GetEnvironmentVariable("REVIEW_LOOP_TEST_API_KEY")
        [Environment]::SetEnvironmentVariable("REVIEW_LOOP_TEST_API_KEY", "secret", "Process")

        try {
            { Assert-NoApiKeyAuth -AgentName "Test agent" -EnvironmentVariableNames @("REVIEW_LOOP_TEST_API_KEY") } | Should Throw "API-key auth appears to be configured"
        }
        finally {
            [Environment]::SetEnvironmentVariable("REVIEW_LOOP_TEST_API_KEY", $previousValue, "Process")
        }
    }

    It "passes when guarded API key environment variables are absent" {
        $previousValue = [Environment]::GetEnvironmentVariable("REVIEW_LOOP_TEST_API_KEY")
        [Environment]::SetEnvironmentVariable("REVIEW_LOOP_TEST_API_KEY", $null, "Process")

        try {
            { Assert-NoApiKeyAuth -AgentName "Test agent" -EnvironmentVariableNames @("REVIEW_LOOP_TEST_API_KEY") } | Should Not Throw
        }
        finally {
            [Environment]::SetEnvironmentVariable("REVIEW_LOOP_TEST_API_KEY", $previousValue, "Process")
        }
    }
}

Describe "Format-GateSummary" {
    It "summarizes an empty additional gate list" {
        $summary = Format-GateSummary -GateResults @() -MaxLines 20

        $summary | Should Match "No additional command gates were configured"
    }
}

Describe "ConvertFrom-ReviewJsonOutput" {
    It "parses raw reviewer JSON" {
        $review = ConvertFrom-ReviewJsonOutput -Output '{"verdict":"pass","issues":[],"scope_creep":false,"blocking_question":null}'

        $review.verdict | Should Be "pass"
    }

    It "extracts reviewer JSON from a fenced block" {
        $output = @'
Looks good.

```json
{
  "verdict": "pass",
  "issues": [],
  "scope_creep": false,
  "blocking_question": null
}
```
'@

        $review = ConvertFrom-ReviewJsonOutput -Output $output

        $review.verdict | Should Be "pass"
    }
}

Describe "review payload attestation formatting" {
    It "handles missing added-test identifier lists" {
        $summary = Format-TestIdentifierAttestation -AddedTestIdentifiers $null -MissingTestIdentifiers $null -VerificationEnabled $true

        $summary | Should Match "No new test identifiers were detected"
    }

    It "handles missing uncovered-line lists when coverage is not configured" {
        $summary = Format-CoverageAttestation -CoverageReportPath $null -UncoveredLines $null

        $summary | Should Match "No LCOV report was configured"
    }
}

Describe "Write-Utf8File" {
    It "writes an empty file when given an empty string" {
        $tempFile = [System.IO.Path]::GetTempFileName()

        try {
            Write-Utf8File -Path $tempFile -Content ""

            (Get-Item $tempFile).Length | Should Be 0
        }
        finally {
            Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
        }
    }
}

Describe "Get-AddedLinesFromDiff" {
    It "captures added lines with file and line numbers" {
        $diff = @"
diff --git a/src/app.js b/src/app.js
index 1111111..2222222 100644
--- a/src/app.js
+++ b/src/app.js
@@ -1,2 +1,4 @@
 const a = 1;
+const b = 2;
 function run() {
+  return a + b;
 }
"@

        $lines = Get-AddedLinesFromDiff -DiffText $diff

        $lines.Count | Should Be 2
        $lines[0].file | Should Be "src/app.js"
        $lines[0].line | Should Be 2
        $lines[0].text | Should Be "const b = 2;"
        $lines[1].line | Should Be 4
    }

    It "returns an empty array when the diff text is empty" {
        $lines = @(Get-AddedLinesFromDiff -DiffText "")

        $lines.Count | Should Be 0
    }
}

Describe "Get-DiffFiles" {
    It "returns an empty array when git diff --name-only is empty" {
        $result = @(Get-DiffFiles -DiffFileNamesOutput "")

        $result.Count | Should Be 0
    }

    It "ignores git warning lines when parsing changed files" {
        $result = @(Get-DiffFiles -DiffFileNamesOutput @"
warning: in the working copy of 'calc.py', LF will be replaced by CRLF the next time Git touches it
calc.py
test_calc.py
"@)

        $result | Should Be @("calc.py", "test_calc.py")
    }
}

Describe "Remove-GitNoiseLines" {
    It "removes git warning and hint lines from command output" {
        $result = Remove-GitNoiseLines -Text @"
warning: unable to access 'C:\Users\eatin/.config/git/ignore': Permission denied
hint: waiting for your editor to close the file...
 M review-loop.ps1
"@

        $result | Should Be " M review-loop.ps1"
    }
}

Describe "Get-AddedTestIdentifiers" {
    It "collects js test names but ignores describe blocks" {
        $items = @(
            [pscustomobject]@{ file = "tests/app.test.js"; line = 1; text = "describe('parser', () => {" },
            [pscustomobject]@{ file = "tests/app.test.js"; line = 2; text = "it('rejects bad flags', () => {" },
            [pscustomobject]@{ file = "tests/app.test.js"; line = 3; text = "test('accepts valid flags', () => {" }
        )

        $identifiers = Get-AddedTestIdentifiers -AddedLines $items

        @($identifiers.name) | Should Be @("rejects bad flags", "accepts valid flags")
    }

    It "does not treat arbitrary CSharp helper methods as tests" {
        $items = @(
            [pscustomobject]@{ file = "tests/ParserTests.cs"; line = 10; text = "public void HelperMethod() {" },
            [pscustomobject]@{ file = "tests/ParserTests.cs"; line = 20; text = "private async Task BuildFixture() {" }
        )

        $identifiers = Get-AddedTestIdentifiers -AddedLines $items

        @($identifiers).Count | Should Be 0
    }

    It "collects Pester It test names" {
        $items = @(
            [pscustomobject]@{ file = "tests/review-loop.Tests.ps1"; line = 10; text = 'Describe "parser" {' },
            [pscustomobject]@{ file = "tests/review-loop.Tests.ps1"; line = 11; text = '    It "detects pester tests" {' },
            [pscustomobject]@{ file = "tests/review-loop.Tests.ps1"; line = 12; text = "    It -Name 'detects named pester tests' {" }
        )

        $identifiers = Get-AddedTestIdentifiers -AddedLines $items

        @($identifiers.name | Sort-Object) | Should Be @("detects named pester tests", "detects pester tests")
    }

    It "returns an empty array when no added lines are present" {
        $identifiers = @(Get-AddedTestIdentifiers -AddedLines $null)

        $identifiers.Count | Should Be 0
    }
}

Describe "Get-MissingTestIdentifiers" {
    It "does not treat substring matches as executed tests" {
        $identifiers = @(
            [pscustomobject]@{ file = "tests/app.test.js"; name = "parse" },
            [pscustomobject]@{ file = "tests/app.test.js"; name = "rejects bad flags" }
        )
        $output = @"
warning: parser module loaded
PASS tests/app.test.js
  rejects bad flags
"@

        $missing = Get-MissingTestIdentifiers -Identifiers $identifiers -Output $output

        @($missing.name) | Should Be @("parse")
    }
}

Describe "Read-LcovCoverageMap and Get-UncoveredAddedProductionLines" {
    It "maps covered lines and reports uncovered production additions" {
        $tempFile = [System.IO.Path]::GetTempFileName()
        try {
            @"
TN:
SF:src/app.js
DA:2,1
DA:3,0
end_of_record
"@ | Set-Content -LiteralPath $tempFile -Encoding UTF8

            $coverageMap = Read-LcovCoverageMap -ReportPath $tempFile -RepoRoot $repoRoot
            $addedLines = @(
                [pscustomobject]@{ file = "src/app.js"; line = 2; text = "const ok = true;" },
                [pscustomobject]@{ file = "src/app.js"; line = 3; text = "const missed = true;" },
                [pscustomobject]@{ file = "tests/app.test.js"; line = 5; text = "it('covers app', () => {})" }
            )

            $uncovered = @(Get-UncoveredAddedProductionLines -AddedLines $addedLines -CoverageMap $coverageMap)

            $coverageMap["src/app.js"].ContainsKey("2") | Should Be $true
            $uncovered.Count | Should Be 1
            $uncovered[0].file | Should Be "src/app.js"
            $uncovered[0].line | Should Be 3
        }
        finally {
            Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
        }
    }
}

Describe "untracked file handling" {
    It "makes new files visible in git diff after intent-to-add refresh" {
        $tempRepo = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tempRepo | Out-Null
        try {
            $git = (Get-Command git.exe).Source
            Invoke-ExternalText -FilePath $git -Arguments @("init", "-b", "main") -WorkingDirectory $tempRepo | Out-Null
            "base" | Set-Content (Join-Path $tempRepo "a.txt")
            Invoke-ExternalText -FilePath $git -Arguments @("add", "a.txt") -WorkingDirectory $tempRepo | Out-Null
            Invoke-ExternalText -FilePath $git -Arguments @("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init") -WorkingDirectory $tempRepo | Out-Null
            "new" | Set-Content (Join-Path $tempRepo "b.txt")

            Ensure-UntrackedFilesVisible -RepoRoot $tempRepo -GitCommand $git
            $diff = (Invoke-ExternalText -FilePath $git -Arguments @("diff", "--name-only", "HEAD") -WorkingDirectory $tempRepo).Output

            $diff | Should Match "b.txt"
        }
        finally {
            Remove-Item -LiteralPath $tempRepo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "applies new-file diffs into the gate worktree" {
        $tempRepo = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tempRepo | Out-Null
        try {
            $git = (Get-Command git.exe).Source
            Invoke-ExternalText -FilePath $git -Arguments @("init", "-b", "main") -WorkingDirectory $tempRepo | Out-Null
            "base" | Set-Content (Join-Path $tempRepo "a.txt")
            Invoke-ExternalText -FilePath $git -Arguments @("add", "a.txt") -WorkingDirectory $tempRepo | Out-Null
            Invoke-ExternalText -FilePath $git -Arguments @("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init") -WorkingDirectory $tempRepo | Out-Null
            "new" | Set-Content (Join-Path $tempRepo "b.txt")

            Ensure-UntrackedFilesVisible -RepoRoot $tempRepo -GitCommand $git
            $patch = (Invoke-ExternalText -FilePath $git -Arguments @("diff", "--binary", "--src-prefix=a/", "--dst-prefix=b/", "HEAD") -WorkingDirectory $tempRepo).Output
            $stateDir = Join-Path $tempRepo ".review-loop"
            New-Item -ItemType Directory -Path $stateDir | Out-Null
            $gateWorktree = New-GateWorktree -RepoRoot $tempRepo -GitCommand $git -StateDirectory $stateDir -Round 1
            try {
                Apply-DiffToGateWorktree -WorktreePath $gateWorktree -GitCommand $git -DiffText $patch
                Test-Path (Join-Path $gateWorktree "b.txt") | Should Be $true
            }
            finally {
                Remove-GateWorktree -WorktreePath $gateWorktree -RepoRoot $tempRepo -GitCommand $git
            }
        }
        finally {
            Remove-Item -LiteralPath $tempRepo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "dirty working tree baseline handling" {
    It "returns only changes made after the baseline diff" {
        $tempRepo = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tempRepo | Out-Null
        try {
            $git = (Get-Command git.exe).Source
            Invoke-ExternalText -FilePath $git -Arguments @("init", "-b", "main") -WorkingDirectory $tempRepo | Out-Null
            "base-a" | Set-Content (Join-Path $tempRepo "a.txt")
            "base-b" | Set-Content (Join-Path $tempRepo "b.txt")
            Invoke-ExternalText -FilePath $git -Arguments @("add", "a.txt", "b.txt") -WorkingDirectory $tempRepo | Out-Null
            Invoke-ExternalText -FilePath $git -Arguments @("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init") -WorkingDirectory $tempRepo | Out-Null

            "dirty-before-run" | Set-Content (Join-Path $tempRepo "a.txt")
            $baselineDiff = (Invoke-ExternalText -FilePath $git -Arguments @("diff", "--binary", "--src-prefix=a/", "--dst-prefix=b/", "HEAD") -WorkingDirectory $tempRepo).Output

            "changed-during-run" | Set-Content (Join-Path $tempRepo "b.txt")
            $currentDiff = (Invoke-ExternalText -FilePath $git -Arguments @("diff", "--binary", "--src-prefix=a/", "--dst-prefix=b/", "HEAD") -WorkingDirectory $tempRepo).Output
            $stateDir = Join-Path $tempRepo ".review-loop"
            New-Item -ItemType Directory -Path $stateDir | Out-Null

            $phaseDiff = Get-DiffFromBaseline -RepoRoot $tempRepo -GitCommand $git -StateDirectory $stateDir -BaselineDiffText $baselineDiff -CurrentDiffText $currentDiff -Round 1
            $files = @(Get-DiffFiles -DiffFileNamesOutput $phaseDiff.DiffFileNamesOutput)

            $files | Should Be @("b.txt")
            $phaseDiff.ReviewDiffText | Should Match "changed-during-run"
            $phaseDiff.ReviewDiffText | Should Not Match "dirty-before-run"
        }
        finally {
            Remove-Item -LiteralPath $tempRepo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "review-loop script integration" {
    It "runs one full passing round with stubbed Codex and Claude commands" {
        $fixture = New-ReviewLoopIntegrationFixture
        try {
            $result = Invoke-ReviewLoopIntegrationFixture -Fixture $fixture

            if ($result.ExitCode -ne 0) {
                throw "review-loop.ps1 exited with $($result.ExitCode):`n$($result.Output)"
            }

            $result.ExitCode | Should Be 0
            $result.Output | Should Match "=== PASSED in round 1 ==="
            (Get-Content -LiteralPath (Join-Path $fixture.Repo "app.txt") -Raw) | Should Match "changed by fake codex"
        }
        finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not call Claude when the test gate fails" {
        $fixture = New-ReviewLoopIntegrationFixture
        try {
            $result = Invoke-ReviewLoopIntegrationFixture -Fixture $fixture -TestCommand "exit 1"

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "The test gate failed"
            Test-Path -LiteralPath (Join-Path $fixture.Repo "claude-called.txt") | Should Be $false
        }
        finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "uses the gate execution root when reading configured LCOV coverage" {
        $fixture = New-ReviewLoopIntegrationFixture
        $coverageCommand = @'
New-Item -ItemType Directory -Force coverage | Out-Null
Set-Content -LiteralPath coverage\lcov.info -Encoding ASCII -Value 'TN:', 'SF:app.txt', 'DA:1,1', 'DA:2,1', 'end_of_record'
'@
        try {
            $result = Invoke-ReviewLoopIntegrationFixture `
                -Fixture $fixture `
                -TestCommand $coverageCommand `
                -CoverageLcovPath "coverage\lcov.info"

            if ($result.ExitCode -ne 0) {
                throw "review-loop.ps1 exited with $($result.ExitCode):`n$($result.Output)"
            }

            $result.ExitCode | Should Be 0
            $result.Output | Should Match "Reviewer verdict: pass"
        }
        finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "exits unsuccessfully when Claude returns a failing review" {
        $claudeOutput = @'
```json
{
  "verdict": "fail",
  "issues": [
    {
      "file": "app.txt",
      "line": null,
      "severity": "major",
      "description": "Review finding from fake Claude.",
      "suggestion": "Fix the fake issue."
    }
  ],
  "scope_creep": false,
  "blocking_question": null
}
```
'@
        $fixture = New-ReviewLoopIntegrationFixture -ClaudeOutput $claudeOutput
        try {
            $result = Invoke-ReviewLoopIntegrationFixture -Fixture $fixture

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "Reviewer verdict: fail"
            $result.Output | Should Match "Review finding from fake Claude"
            Test-Path -LiteralPath (Join-Path $fixture.Repo "claude-called.txt") | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails mechanically when Codex output is malformed" {
        $fixture = New-ReviewLoopIntegrationFixture -CodexReport "not the expected report"
        try {
            $result = Invoke-ReviewLoopIntegrationFixture -Fixture $fixture

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "Implementer output did not follow"
            Test-Path -LiteralPath (Join-Path $fixture.Repo "claude-called.txt") | Should Be $false
        }
        finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
