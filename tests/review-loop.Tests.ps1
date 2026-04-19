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
