[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Task,

    [ValidateRange(1, 10)]
    [int]$MaxRounds = 3,

    [string]$TestCommand,
    [string]$LintCommand,
    [string]$TypecheckCommand,
    [string]$MutationCommand,
    [string]$CoverageCommand,
    [string]$CoverageLcovPath,

    [switch]$VerifyAddedTestsRan,
    [switch]$PreserveRounds,
    [switch]$ConfirmAgentCalls,
    [switch]$AllowApiKeyAuth,

    [string]$RoundBranchPrefix = "review-loop",
    [string]$ImplementerModel,
    [string]$ReviewerModel,

    [ValidateRange(30, 7200)]
    [int]$ImplementerTimeoutSeconds = 900,

    [ValidateRange(30, 7200)]
    [int]$ReviewerTimeoutSeconds = 600,

    [ValidateRange(30, 7200)]
    [int]$TestTimeoutSeconds = 900,

    [ValidateRange(30, 7200)]
    [int]$GateTimeoutSeconds = 900,

    [ValidateRange(50, 5000)]
    [int]$MaxGateOutputLines = 200,

    [ValidateRange(100, 20000)]
    [int]$MaxReviewDiffLines = 2000
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-RequiredCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command '$Name' was not found in PATH."
    }

    return $command.Source
}

function Invoke-ExternalText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [string]$InputText,

        [string]$WorkingDirectory = (Get-Location).Path,

        [ValidateRange(1, 7200)]
        [int]$TimeoutSeconds = 600,

        [switch]$AllowNonZeroExit
    )

    $job = Start-Job -ScriptBlock {
        param($InnerFilePath, $InnerArguments, $InnerInputText, $InnerWorkingDirectory)

        $ErrorActionPreference = "Continue"
        Set-Location -LiteralPath $InnerWorkingDirectory

        if ($null -ne $InnerInputText) {
            $commandOutput = $InnerInputText | & $InnerFilePath @InnerArguments 2>&1
        }
        else {
            $commandOutput = & $InnerFilePath @InnerArguments 2>&1
        }

        if ($null -eq $commandOutput) {
            $commandOutput = @()
        }

        [pscustomobject]@{
            Output = ($commandOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
            ExitCode = $LASTEXITCODE
        }
    } -ArgumentList $FilePath, $Arguments, $InputText, $WorkingDirectory

    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $completed) {
        Stop-Job -Job $job -Force | Out-Null
        Remove-Job -Job $job -Force | Out-Null
        throw "Command timed out after ${TimeoutSeconds}s: $FilePath $($Arguments -join ' ')"
    }

    $result = Receive-Job -Job $job
    Remove-Job -Job $job -Force | Out-Null

    $output = ""
    $exitCode = 0

    if ($null -ne $result) {
        $output = $result.Output
        $exitCode = [int]$result.ExitCode
    }

    if (-not $AllowNonZeroExit -and $exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $FilePath $($Arguments -join ' ')`n$output"
    }

    return [pscustomobject]@{
        Output = $output
        ExitCode = $exitCode
    }
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-OutputTailText {
    param(
        [AllowNull()]
        [string]$Output,

        [ValidateRange(1, 5000)]
        [int]$MaxLines
    )

    $lines = @()
    if ($Output) {
        $lines = $Output -split "`r?`n"
    }

    if (@($lines).Count -eq 0) {
        return "(no output)"
    }

    return (@($lines | Select-Object -Last $MaxLines)) -join [Environment]::NewLine
}

function Read-LoopConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $configPath = Join-Path $RepoRoot ".review-loop.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json)
    }
    catch {
        throw "Could not parse $configPath as JSON. $($_.Exception.Message)"
    }
}

function Get-ConfigValue {
    param(
        [AllowNull()]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (
        $null -ne $Config -and
        $Config.PSObject.Properties.Name -contains $Name -and
        $null -ne $Config.$Name
    ) {
        return $Config.$Name
    }

    return $null
}

function Resolve-Setting {
    param(
        [AllowNull()]
        [object]$ExplicitValue,

        [AllowNull()]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$ConfigName,

        [AllowNull()]
        [object]$DefaultValue = $null
    )

    if ($PSBoundParameters.ContainsKey("ExplicitValue") -and $null -ne $ExplicitValue) {
        if ($ExplicitValue -is [string] -and [string]::IsNullOrWhiteSpace($ExplicitValue)) {
            return $DefaultValue
        }

        return $ExplicitValue
    }

    $configValue = Get-ConfigValue -Config $Config -Name $ConfigName
    if ($null -ne $configValue) {
        if ($configValue -is [string]) {
            return $configValue.Trim()
        }

        return $configValue
    }

    return $DefaultValue
}

function Resolve-ReviewSchemaPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    $candidatePaths = @(
        (Join-Path $RepoRoot "schemas\review-result.schema.json"),
        (Join-Path $ScriptRoot "schemas\review-result.schema.json")
    )

    foreach ($candidatePath in $candidatePaths | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidatePath) {
            return [System.IO.Path]::GetFullPath($candidatePath)
        }
    }

    return $null
}

function Assert-NoApiKeyAuth {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AgentName,

        [Parameter(Mandatory = $true)]
        [string[]]$EnvironmentVariableNames
    )

    $presentNames = @()
    foreach ($name in $EnvironmentVariableNames) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $presentNames += $name
        }
    }

    if (@($presentNames).Count -gt 0) {
        throw "$AgentName would run while API-key auth appears to be configured ($($presentNames -join ', ')). This loop defaults to subscription-backed CLI auth. Remove those environment variables or pass -AllowApiKeyAuth to opt into metered API-key auth."
    }
}

function Format-AgentModel {
    param(
        [AllowNull()]
        [string]$Model
    )

    if ([string]::IsNullOrWhiteSpace($Model)) {
        return "(CLI default)"
    }

    return $Model.Trim()
}

function Confirm-AgentCall {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Enabled,

        [Parameter(Mandatory = $true)]
        [string]$AgentName,

        [AllowNull()]
        [string]$Model
    )

    if (-not $Enabled) {
        return
    }

    Write-Host ""
    Write-Host ("About to start {0} model call." -f $AgentName)
    Write-Host ("Model: {0}" -f (Format-AgentModel -Model $Model))
    $answer = Read-Host "Type YES to continue"
    if ($answer -ne "YES") {
        throw "$AgentName model call was not confirmed."
    }
}

function New-CodexImplementerArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [AllowNull()]
        [string]$Model
    )

    $arguments = @("exec")
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $arguments += @("--model", $Model.Trim())
    }

    $arguments += @(
        "--sandbox", "workspace-write",
        "--ephemeral",
        "--output-last-message", $OutputPath,
        $Prompt
    )

    return $arguments
}

function New-ClaudeReviewerArguments {
    param(
        [AllowNull()]
        [string]$Model
    )

    $arguments = @("-p")
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $arguments += @("--model", $Model.Trim())
    }

    $arguments += @(
        "--input-format", "text",
        "--output-format", "text",
        "--no-session-persistence"
    )

    return $arguments
}

function Write-RunSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Task,

        [Parameter(Mandatory = $true)]
        [int]$MaxRounds,

        [AllowNull()]
        [string]$ImplementerModel,

        [AllowNull()]
        [string]$ReviewerModel,

        [Parameter(Mandatory = $true)]
        [bool]$ApiKeyAuthAllowed,

        [Parameter(Mandatory = $true)]
        [bool]$ConfirmAgentCalls
    )

    $authText = if ($ApiKeyAuthAllowed) { "API-key auth allowed" } else { "subscription-backed CLI auth required" }
    $confirmText = if ($ConfirmAgentCalls) { "enabled" } else { "disabled" }

    Write-Host ""
    Write-Host "=== Review loop phase ==="
    Write-Host ("Task: {0}" -f $Task)
    Write-Host ("Max rounds: {0}" -f $MaxRounds)
    Write-Host ("Implementer: Codex, model {0}" -f (Format-AgentModel -Model $ImplementerModel))
    Write-Host ("Reviewer: Claude, model {0}" -f (Format-AgentModel -Model $ReviewerModel))
    Write-Host ("Agent auth policy: {0}" -f $authText)
    Write-Host ("Confirm agent calls: {0}" -f $confirmText)
}

function Invoke-CommandText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandText,

        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [ValidateRange(1, 7200)]
        [int]$TimeoutSeconds
    )

    $powershellCommand = Resolve-RequiredCommand -Name "powershell.exe"
    return Invoke-ExternalText `
        -FilePath $powershellCommand `
        -Arguments @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-Command", $CommandText
        ) `
        -WorkingDirectory $RepoRoot `
        -TimeoutSeconds $TimeoutSeconds `
        -AllowNonZeroExit
}

function Invoke-GateCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$CommandText,

        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [ValidateRange(1, 7200)]
        [int]$TimeoutSeconds
    )

    $result = Invoke-CommandText -CommandText $CommandText -RepoRoot $RepoRoot -TimeoutSeconds $TimeoutSeconds
    return [pscustomobject]@{
        Name = $Name
        Command = $CommandText
        Output = $result.Output
        ExitCode = $result.ExitCode
    }
}

function New-ReviewIssue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$File,

        [AllowNull()]
        [Nullable[int]]$Line,

        [Parameter(Mandatory = $true)]
        [ValidateSet("blocker", "major", "minor")]
        [string]$Severity,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [AllowNull()]
        [string]$Suggestion
    )

    return [pscustomobject]@{
        file = $File
        line = $Line
        severity = $Severity
        description = $Description
        suggestion = $Suggestion
    }
}

function New-ReviewResult {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("pass", "fail", "needs_clarification")]
        [string]$Verdict,

        [Parameter(Mandatory = $true)]
        [object[]]$Issues,

        [bool]$ScopeCreep = $false,

        [AllowNull()]
        [string]$BlockingQuestion = $null
    )

    return [pscustomobject]@{
        verdict = $Verdict
        issues = @($Issues)
        scope_creep = $ScopeCreep
        blocking_question = $BlockingQuestion
    }
}

function Save-ReviewResult {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Review,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Write-Utf8File -Path $Path -Content ($Review | ConvertTo-Json -Depth 6)
}

function Normalize-RepoPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = $Path.Trim()
    $normalized = $normalized -replace '^[.][/\\]', ''
    $normalized = $normalized -replace '\\', '/'
    return $normalized
}

function Parse-ImplementerReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Output
    )

    $lines = @($Output -split "`r?`n")
    $summaryIndex = -1
    $filesIndex = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($summaryIndex -lt 0 -and $lines[$i] -match '^\s*[*#>\-`"]*\s*SUMMARY\s*:?\s*[*`"]*\s*$') {
            $summaryIndex = $i
            continue
        }

        if ($filesIndex -lt 0 -and $lines[$i] -match '^\s*[*#>\-`"]*\s*CLAIMED_FILES_JSON\s*:?\s*[*`"]*\s*$') {
            $filesIndex = $i
        }
    }

    if ($summaryIndex -lt 0 -or $filesIndex -lt 0 -or $filesIndex -le $summaryIndex) {
        return $null
    }

    $summaryLines = @($lines[($summaryIndex + 1)..($filesIndex - 1)])
    $claimedJson = @($lines[($filesIndex + 1)..($lines.Count - 1)]) -join [Environment]::NewLine

    try {
        $rawFiles = $claimedJson | ConvertFrom-Json
    }
    catch {
        return $null
    }

    $claimedFiles = @()
    if ($null -ne $rawFiles) {
        foreach ($rawFile in @($rawFiles)) {
            if ($null -eq $rawFile) {
                continue
            }

            $normalizedFile = Normalize-RepoPath -Path ([string]$rawFile)
            if ($normalizedFile) {
                $claimedFiles += $normalizedFile
            }
        }
    }

    return [pscustomobject]@{
        Summary = ($summaryLines -join [Environment]::NewLine).Trim()
        ClaimedFiles = @($claimedFiles | Select-Object -Unique)
    }
}

function Get-ReviewIssues {
    param(
        [AllowNull()]
        [object]$Review
    )

    if ($null -eq $Review -or $null -eq $Review.issues) {
        return @()
    }

    return @($Review.issues)
}

function Is-TestFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = Normalize-RepoPath -Path $Path
    if (
        $normalized -match '(^|/)(test|tests|__tests__|spec|specs)(/|$)' -or
        $normalized -match '(\.|_)(test|tests|spec)(\.[^./]+)+$' -or
        $normalized -match '/conftest\.py$' -or
        $normalized -match '/test_[^/]+\.py$'
    ) {
        return $true
    }

    return $false
}

function Remove-GitNoiseLines {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    if (-not $Text) {
        return ""
    }

    return @(
        $Text -split "`r?`n" |
        Where-Object {
            $_ -notmatch '^(warning|hint):'
        }
    ) -join [Environment]::NewLine
}

function Get-DiffFiles {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$DiffFileNamesOutput
    )

    if (-not $DiffFileNamesOutput) {
        return @()
    }

    return @(
        $DiffFileNamesOutput -split "`r?`n" |
        Where-Object { $_.Trim() -and $_ -notmatch '^(warning|hint):' } |
        ForEach-Object { Normalize-RepoPath -Path $_ } |
        Select-Object -Unique
    )
}

function Get-AddedLinesFromDiff {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$DiffText
    )

    if (-not $DiffText) {
        return @()
    }

    $items = @()
    $currentFile = $null
    $currentNewLine = 0

    foreach ($line in @($DiffText -split "`r?`n")) {
        if ($line -match '^\+\+\+ b/(.+)$') {
            $currentFile = Normalize-RepoPath -Path $Matches[1]
            continue
        }

        if ($line -eq '+++ /dev/null') {
            $currentFile = $null
            continue
        }

        if ($line -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@') {
            $currentNewLine = [int]$Matches[1]
            continue
        }

        if (-not $currentFile) {
            continue
        }

        if ($line.StartsWith("+") -and -not $line.StartsWith("+++")) {
            $items += [pscustomobject]@{
                file = $currentFile
                line = $currentNewLine
                text = $line.Substring(1)
            }
            $currentNewLine++
            continue
        }

        if ($line.StartsWith(" ")) {
            $currentNewLine++
        }
    }

    return @($items)
}

function Get-AddedTestIdentifiers {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object[]]$AddedLines
    )

    $identifiers = @()
    foreach ($item in @($AddedLines)) {
        if (-not (Is-TestFile -Path $item.file)) {
            continue
        }

        $text = [string]$item.text
        $name = $null

        if ($text -match '^\s*(?:it|test)(?:\.(?:only|skip|todo|concurrent|each))*\s*\(\s*["'']([^"'']+)["'']') {
            $name = $Matches[1]
        }
        elseif ($text -match '^\s*(?:Deno\.)?test\s*\(\s*["'']([^"'']+)["'']') {
            $name = $Matches[1]
        }
        elseif ($text -match '^\s*def\s+(test_[A-Za-z0-9_]+)\s*\(') {
            $name = $Matches[1]
        }
        elseif ($text -match '^\s*func\s+(Test[A-Za-z0-9_]+)\s*\(') {
            $name = $Matches[1]
        }
        elseif ($text -match '^\s*fn\s+(test_[A-Za-z0-9_]+)\s*\(') {
            $name = $Matches[1]
        }
        if ($name) {
            $identifiers += [pscustomobject]@{
                file = $item.file
                name = $name
            }
        }
    }

    $grouped = @{}
    foreach ($identifier in $identifiers) {
        $key = "{0}|{1}" -f $identifier.file, $identifier.name
        if (-not $grouped.ContainsKey($key)) {
            $grouped[$key] = $identifier
        }
    }

    return @($grouped.Values)
}

function Get-MissingTestIdentifiers {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object[]]$Identifiers,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Output
    )

    $missing = @()
    foreach ($identifier in @($Identifiers)) {
        $escapedName = [regex]::Escape($identifier.name)
        $pattern = "(?im)(^|[^A-Za-z0-9_])$escapedName([^A-Za-z0-9_]|$)"
        if (-not [regex]::IsMatch($Output, $pattern)) {
            $missing += $identifier
        }
    }

    return @($missing)
}

function Format-TestSummary {
    param(
        [AllowNull()]
        [object]$TestGate,
        [ValidateRange(1, 5000)]
        [int]$MaxLines
    )

    if ($null -eq $TestGate) {
        return @"
Tests:
- No test command was configured.
- Treat missing tests as a review concern when the change clearly requires coverage.
"@
    }

    $status = if ($TestGate.ExitCode -eq 0) { "PASS" } else { "FAIL" }
    $outputLines = @()
    if ($TestGate.Output) {
        $outputLines = $TestGate.Output -split "`r?`n"
    }

    $tailText = Get-OutputTailText -Output $TestGate.Output -MaxLines $MaxLines

    return @"
Tests:
- Command: $($TestGate.Command)
- Status: $status
- Exit code: $($TestGate.ExitCode)
- Output tail:
$tailText
"@
}

function Format-GateSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$GateResults,

        [ValidateRange(1, 5000)]
        [int]$MaxLines
    )

    if (@($GateResults).Count -eq 0) {
        return @"
Gate attestation:
- No additional command gates were configured.
"@
    }

    $sections = @("Gate attestation:")
    foreach ($gateResult in $GateResults) {
        $status = if ($gateResult.ExitCode -eq 0) { "PASS" } else { "FAIL" }
        $tailText = Get-OutputTailText -Output $gateResult.Output -MaxLines $MaxLines

        $sections += "- {0}: {1} (exit {2})" -f $gateResult.Name, $status, $gateResult.ExitCode
        $sections += "  Command: $($gateResult.Command)"
        $sections += "  Output tail:"
        $sections += $tailText
    }

    return ($sections -join [Environment]::NewLine)
}

function Format-TestIdentifierAttestation {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$AddedTestIdentifiers,

        [Parameter(Mandatory = $true)]
        [object[]]$MissingTestIdentifiers,

        [bool]$VerificationEnabled
    )

    if (-not $VerificationEnabled) {
        return @"
Added test execution attestation:
- Verification disabled.
"@
    }

    if (@($AddedTestIdentifiers).Count -eq 0) {
        return @"
Added test execution attestation:
- No new test identifiers were detected in the diff.
"@
    }

    $expectedText = (@($AddedTestIdentifiers | ForEach-Object { "{0}: {1}" -f $_.file, $_.name })) -join [Environment]::NewLine
    $missingText = if (@($MissingTestIdentifiers).Count -gt 0) {
        (@($MissingTestIdentifiers | ForEach-Object { "{0}: {1}" -f $_.file, $_.name })) -join [Environment]::NewLine
    }
    else {
        "(none)"
    }

    return @"
Added test execution attestation:
- Expected identifiers:
$expectedText
- Missing from test output:
$missingText
"@
}

function Read-LcovCoverageMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportPath,

        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $coverageMap = @{}
    $currentFile = $null

    foreach ($line in Get-Content -LiteralPath $ReportPath -Encoding UTF8) {
        if ($line.StartsWith("SF:")) {
            $rawFile = $line.Substring(3).Trim()
            $candidate = $rawFile
            if ([System.IO.Path]::IsPathRooted($candidate)) {
                $repoRootFull = [System.IO.Path]::GetFullPath($RepoRoot)
                $candidateFull = [System.IO.Path]::GetFullPath($candidate)
                if ($candidateFull.StartsWith($repoRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $candidate = $candidateFull.Substring($repoRootFull.Length).TrimStart('\', '/')
                }
            }

            $currentFile = Normalize-RepoPath -Path $candidate
            if (-not $coverageMap.ContainsKey($currentFile)) {
                $coverageMap[$currentFile] = @{}
            }
            continue
        }

        if ($line.StartsWith("DA:") -and $currentFile) {
            $parts = $line.Substring(3).Split(",")
            if ($parts.Count -ge 2) {
                $lineNumber = [int]$parts[0]
                $hits = [int]$parts[1]
                if ($hits -gt 0) {
                    $coverageMap[$currentFile]["$lineNumber"] = $true
                }
            }
            continue
        }

        if ($line -eq "end_of_record") {
            $currentFile = $null
        }
    }

    return $coverageMap
}

function Get-UncoveredAddedProductionLines {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object[]]$AddedLines,

        [Parameter(Mandatory = $true)]
        [hashtable]$CoverageMap
    )

    $uncovered = @()
    foreach ($item in @($AddedLines)) {
        if (Is-TestFile -Path $item.file) {
            continue
        }

        $fileCoverage = $CoverageMap[$item.file]
        if ($null -eq $fileCoverage -or -not $fileCoverage.ContainsKey("$($item.line)")) {
            $uncovered += $item
        }
    }

    return @($uncovered)
}

function Format-CoverageAttestation {
    param(
        [AllowNull()]
        [string]$CoverageReportPath,

        [Parameter(Mandatory = $true)]
        [object[]]$UncoveredLines
    )

    if (-not $CoverageReportPath) {
        return @"
Coverage attestation:
- No LCOV report was configured.
"@
    }

    if (@($UncoveredLines).Count -eq 0) {
        return @"
Coverage attestation:
- Report: $CoverageReportPath
- Added production lines: fully covered.
"@
    }

    $grouped = $UncoveredLines | Group-Object -Property file
    $lines = @()
    foreach ($group in $grouped) {
        $lineNumbers = @($group.Group | ForEach-Object { $_.line } | Sort-Object -Unique)
        $lines += ("- {0}: {1}" -f $group.Name, ($lineNumbers -join ", "))
    }

    return @"
Coverage attestation:
- Report: $CoverageReportPath
- Uncovered added production lines:
$($lines -join [Environment]::NewLine)
"@
}

function Format-IssueLine {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Issue
    )

    $location = $Issue.file
    if ($Issue.line) {
        $location = "${location}:$($Issue.line)"
    }

    $text = "[{0}] {1} - {2}" -f $Issue.severity.ToUpperInvariant(), $location, $Issue.description
    if ($Issue.suggestion) {
        $text += " Suggestion: $($Issue.suggestion)"
    }

    return $text
}

function Write-ReviewSummary {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Review
    )

    Write-Host ""
    Write-Host ("Reviewer verdict: {0}" -f $Review.verdict)

    if ($Review.verdict -eq "needs_clarification" -and $Review.blocking_question) {
        Write-Host ("Blocking question: {0}" -f $Review.blocking_question)
    }

    if ($Review.scope_creep) {
        Write-Host "Scope creep detected."
    }

    foreach ($issue in (Get-ReviewIssues -Review $Review)) {
        Write-Host ("- {0}" -f (Format-IssueLine -Issue $issue))
    }
}

function Save-RoundSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$GitCommand,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [string]$BranchPrefix,

        [Parameter(Mandatory = $true)]
        [int]$Round,

        [Parameter(Mandatory = $true)]
        [string]$Outcome
    )

    $snapshotResult = Invoke-ExternalText `
        -FilePath $GitCommand `
        -Arguments @("stash", "create", "review-loop round $Round $Outcome") `
        -WorkingDirectory $RepoRoot `
        -AllowNonZeroExit

    $snapshotSha = $snapshotResult.Output.Trim()
    if (-not $snapshotSha) {
        return $null
    }

    $safePrefix = ($BranchPrefix.Trim("/")) -replace '[^A-Za-z0-9._/\-]', '-'
    $safeOutcome = ($Outcome -replace '[^A-Za-z0-9._\-]', '-').Trim('-')
    $branchName = "{0}/{1}/round-{2:00}-{3}" -f $safePrefix, $RunId, $Round, $safeOutcome

    [void](Invoke-ExternalText `
        -FilePath $GitCommand `
        -Arguments @("branch", $branchName, $snapshotSha) `
        -WorkingDirectory $RepoRoot)

    Write-Utf8File `
        -Path (Join-Path $StateDirectory ("round-{0:00}-snapshot-branch.txt" -f $Round)) `
        -Content $branchName

    return $branchName
}

function Ensure-UntrackedFilesVisible {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$GitCommand
    )

    [void](Invoke-ExternalText `
        -FilePath $GitCommand `
        -Arguments @("add", "-N", "--all") `
        -WorkingDirectory $RepoRoot `
        -AllowNonZeroExit)
}

function New-GateWorktree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$GitCommand,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [int]$Round
    )

    $headSha = (Invoke-ExternalText `
        -FilePath $GitCommand `
        -Arguments @("rev-parse", "--verify", "HEAD") `
        -WorkingDirectory $RepoRoot).Output.Trim()

    if (-not $headSha) {
        return $null
    }

    $worktreePath = Join-Path $StateDirectory ("gate-worktree-round-{0:00}" -f $Round)
    if (Test-Path -LiteralPath $worktreePath) {
        [void](Invoke-ExternalText `
            -FilePath $GitCommand `
            -Arguments @("worktree", "remove", "--force", $worktreePath) `
            -WorkingDirectory $RepoRoot `
            -AllowNonZeroExit)
    }

    [void](Invoke-ExternalText `
        -FilePath $GitCommand `
        -Arguments @("worktree", "add", "--detach", $worktreePath, $headSha) `
        -WorkingDirectory $RepoRoot)

    return $worktreePath
}

function Apply-DiffToGateWorktree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorktreePath,

        [Parameter(Mandatory = $true)]
        [string]$GitCommand,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$DiffText
    )

    if (-not $DiffText.Trim()) {
        return
    }

    [void](Invoke-ExternalText `
        -FilePath $GitCommand `
        -Arguments @("apply", "--binary") `
        -WorkingDirectory $WorktreePath `
        -InputText $DiffText)
}

function Remove-GateWorktree {
    param(
        [AllowNull()]
        [string]$WorktreePath,

        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$GitCommand
    )

    if (-not $WorktreePath) {
        return
    }

    [void](Invoke-ExternalText `
        -FilePath $GitCommand `
        -Arguments @("worktree", "remove", "--force", $WorktreePath) `
        -WorkingDirectory $RepoRoot `
        -AllowNonZeroExit)
}

if ($env:REVIEW_LOOP_LIBRARY_MODE -eq "1") {
    return
}

$gitCommand = Resolve-RequiredCommand -Name "git.exe"
$claudeCommand = Resolve-RequiredCommand -Name "claude.cmd"
$codexCommand = Resolve-RequiredCommand -Name "codex.cmd"

$repoRoot = (Invoke-ExternalText -FilePath $gitCommand -Arguments @("rev-parse", "--show-toplevel")).Output.Trim()
if (-not $repoRoot) {
    throw "This script must be run inside a git repository."
}

Set-Location $repoRoot

$hasHead = $true
try {
    [void](Invoke-ExternalText -FilePath $gitCommand -Arguments @("rev-parse", "--verify", "HEAD") -WorkingDirectory $repoRoot)
}
catch {
    $hasHead = $false
}

if (-not $hasHead) {
    throw "The repository has no commits yet. Create an initial commit before running the review loop."
}

$schemaPath = Resolve-ReviewSchemaPath -RepoRoot $repoRoot -ScriptRoot $PSScriptRoot
if (-not $schemaPath) {
    throw "Review schema file not found in either '$repoRoot\schemas\review-result.schema.json' or '$PSScriptRoot\schemas\review-result.schema.json'."
}

$config = Read-LoopConfig -RepoRoot $repoRoot
$explicitVerifyAddedTests = if ($PSBoundParameters.ContainsKey("VerifyAddedTestsRan")) { $VerifyAddedTestsRan.IsPresent } else { $null }
$explicitPreserveRounds = if ($PSBoundParameters.ContainsKey("PreserveRounds")) { $PreserveRounds.IsPresent } else { $null }
$explicitConfirmAgentCalls = if ($PSBoundParameters.ContainsKey("ConfirmAgentCalls")) { $ConfirmAgentCalls.IsPresent } else { $null }
$explicitAllowApiKeyAuth = if ($PSBoundParameters.ContainsKey("AllowApiKeyAuth")) { $AllowApiKeyAuth.IsPresent } else { $null }
$explicitRoundBranchPrefix = if ($PSBoundParameters.ContainsKey("RoundBranchPrefix")) { $RoundBranchPrefix } else { $null }

$effectiveTestCommand = Resolve-Setting -ExplicitValue $TestCommand -Config $config -ConfigName "testCommand"
$effectiveLintCommand = Resolve-Setting -ExplicitValue $LintCommand -Config $config -ConfigName "lintCommand"
$effectiveTypecheckCommand = Resolve-Setting -ExplicitValue $TypecheckCommand -Config $config -ConfigName "typecheckCommand"
$effectiveMutationCommand = Resolve-Setting -ExplicitValue $MutationCommand -Config $config -ConfigName "mutationCommand"
$effectiveCoverageCommand = Resolve-Setting -ExplicitValue $CoverageCommand -Config $config -ConfigName "coverageCommand"
$effectiveCoverageLcovPath = Resolve-Setting -ExplicitValue $CoverageLcovPath -Config $config -ConfigName "coverageLcovPath"
$effectiveImplementerModel = Resolve-Setting -ExplicitValue $ImplementerModel -Config $config -ConfigName "implementerModel"
$effectiveReviewerModel = Resolve-Setting -ExplicitValue $ReviewerModel -Config $config -ConfigName "reviewerModel"
$verifyAddedTests = [bool](Resolve-Setting -ExplicitValue $explicitVerifyAddedTests -Config $config -ConfigName "verifyAddedTestsRan" -DefaultValue $false)
$preserveRoundSnapshots = [bool](Resolve-Setting -ExplicitValue $explicitPreserveRounds -Config $config -ConfigName "preserveRounds" -DefaultValue $false)
$confirmAgentCalls = [bool](Resolve-Setting -ExplicitValue $explicitConfirmAgentCalls -Config $config -ConfigName "confirmAgentCalls" -DefaultValue $false)
$allowApiKeyAuth = [bool](Resolve-Setting -ExplicitValue $explicitAllowApiKeyAuth -Config $config -ConfigName "allowApiKeyAuth" -DefaultValue $false)
$effectiveRoundBranchPrefix = [string](Resolve-Setting -ExplicitValue $explicitRoundBranchPrefix -Config $config -ConfigName "roundBranchPrefix" -DefaultValue "review-loop")

if (-not $allowApiKeyAuth) {
    Assert-NoApiKeyAuth -AgentName "Codex implementer" -EnvironmentVariableNames @("OPENAI_API_KEY")
    Assert-NoApiKeyAuth -AgentName "Claude reviewer" -EnvironmentVariableNames @("ANTHROPIC_API_KEY")
}

Write-RunSummary `
    -Task $Task `
    -MaxRounds $MaxRounds `
    -ImplementerModel $effectiveImplementerModel `
    -ReviewerModel $effectiveReviewerModel `
    -ApiKeyAuthAllowed $allowApiKeyAuth `
    -ConfirmAgentCalls $confirmAgentCalls

$stateDirectory = Join-Path $repoRoot ".review-loop"
New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null

$reviewPath = Join-Path $stateDirectory "review.json"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"

for ($round = 1; $round -le $MaxRounds; $round++) {
    Write-Host ""
    Write-Host "=== Round $round / ${MaxRounds}: implementer (Codex) ==="

    $implementerPrompt = @"
You are the implementer in a two-agent review loop.
Modify the current repository to complete the task below.

Task:
$Task

Rules:
- Keep changes tightly scoped to the task.
- Do not make unrelated refactors.
- Add or update tests when they are clearly relevant.
- Apply code changes directly in the repository.
- When you finish, print exactly this shape and nothing else:
SUMMARY:
- short bullet
- short bullet
CLAIMED_FILES_JSON:
["relative/path/one","relative/path/two"]
- Only list files that actually appear in git diff --name-only HEAD.
"@

    if ($round -gt 1) {
        $previousReview = Get-Content -LiteralPath $reviewPath -Raw
        $implementerPrompt += @"

Reviewer feedback from the last round:
$previousReview

Address the reviewer findings. Do not expand scope.
"@
    }

    $implementerPath = Join-Path $stateDirectory ("round-{0:00}-implementer.txt" -f $round)
    Confirm-AgentCall -Enabled $confirmAgentCalls -AgentName "Codex implementer" -Model $effectiveImplementerModel
    $implementerResult = Invoke-ExternalText `
        -FilePath $codexCommand `
        -Arguments (New-CodexImplementerArguments -OutputPath $implementerPath -Prompt $implementerPrompt -Model $effectiveImplementerModel) `
        -WorkingDirectory $repoRoot `
        -TimeoutSeconds $ImplementerTimeoutSeconds

    if (Test-Path -LiteralPath $implementerPath) {
        $implementerOutput = Get-Content -LiteralPath $implementerPath -Raw
    }
    else {
        $implementerOutput = $implementerResult.Output
        Write-Utf8File -Path $implementerPath -Content $implementerOutput
    }

    Ensure-UntrackedFilesVisible -RepoRoot $repoRoot -GitCommand $gitCommand

    $reviewDiffText = Remove-GitNoiseLines -Text ((Invoke-ExternalText -FilePath $gitCommand -Arguments @("diff", "--no-ext-diff", "HEAD") -WorkingDirectory $repoRoot).Output)
    $fullDiffText = Remove-GitNoiseLines -Text ((Invoke-ExternalText -FilePath $gitCommand -Arguments @("diff", "--no-ext-diff", "--binary", "HEAD") -WorkingDirectory $repoRoot).Output)
    $diffFileNamesOutput = Remove-GitNoiseLines -Text ((Invoke-ExternalText -FilePath $gitCommand -Arguments @("diff", "--name-only", "HEAD") -WorkingDirectory $repoRoot).Output)
    $diffFiles = Get-DiffFiles -DiffFileNamesOutput $diffFileNamesOutput
    $addedLines = Get-AddedLinesFromDiff -DiffText $reviewDiffText
    $addedTestIdentifiers = Get-AddedTestIdentifiers -AddedLines $addedLines

    Write-Utf8File -Path (Join-Path $stateDirectory ("round-{0:00}-diff.patch" -f $round)) -Content $fullDiffText
    Write-Utf8File -Path (Join-Path $stateDirectory ("round-{0:00}-diff.txt" -f $round)) -Content $reviewDiffText

    $implementerReport = Parse-ImplementerReport -Output $implementerOutput
    $mechanicalIssues = @()
    $scopeCreep = $false

    if (-not $implementerReport) {
        $mechanicalIssues += New-ReviewIssue `
            -File "repo" `
            -Line $null `
            -Severity "major" `
            -Description "Implementer output did not follow the required SUMMARY/CLAIMED_FILES_JSON format." `
            -Suggestion "Return the exact two-section report with a valid JSON array of touched files."
    }
    else {
        Write-Utf8File `
            -Path (Join-Path $stateDirectory ("round-{0:00}-claimed-files.json" -f $round)) `
            -Content (($implementerReport.ClaimedFiles | ConvertTo-Json -Depth 6))

        $invalidClaims = @(
            $implementerReport.ClaimedFiles |
            Where-Object { $_ -notin $diffFiles } |
            Select-Object -Unique
        )

        foreach ($invalidClaim in $invalidClaims) {
            $mechanicalIssues += New-ReviewIssue `
                -File "repo" `
                -Line $null `
                -Severity "major" `
                -Description "Implementer claimed a change in '$invalidClaim', but that file is not present in git diff --name-only HEAD." `
                -Suggestion "Only report files that actually changed in this round."
        }

        $unclaimedDiffFiles = @(
            $diffFiles |
            Where-Object { $_ -notin $implementerReport.ClaimedFiles } |
            Select-Object -Unique
        )

        foreach ($unclaimedDiffFile in $unclaimedDiffFiles) {
            $mechanicalIssues += New-ReviewIssue `
                -File $unclaimedDiffFile `
                -Line $null `
                -Severity "major" `
                -Description "The diff changed '$unclaimedDiffFile', but the implementer did not include it in CLAIMED_FILES_JSON." `
                -Suggestion "Either remove the unrelated change or claim it explicitly."
        }

    }

    $reviewDiffLines = @()
    if ($reviewDiffText) {
        $reviewDiffLines = $reviewDiffText -split "`r?`n"
    }

    if ($reviewDiffLines.Count -gt $MaxReviewDiffLines) {
        $mechanicalIssues += New-ReviewIssue `
            -File "repo" `
            -Line $null `
            -Severity "blocker" `
            -Description "The diff exceeded the configured review limit." `
            -Suggestion "Reduce the scope of the round or raise MaxReviewDiffLines."
    }

    $gateResults = @()
    $testGate = $null
    $gateWorktreePath = $null
    $uncoveredAddedLines = @()
    $gateDefinitions = @(
        @{ Name = "test"; Command = $effectiveTestCommand; Timeout = $TestTimeoutSeconds },
        @{ Name = "lint"; Command = $effectiveLintCommand; Timeout = $GateTimeoutSeconds },
        @{ Name = "typecheck"; Command = $effectiveTypecheckCommand; Timeout = $GateTimeoutSeconds },
        @{ Name = "mutation"; Command = $effectiveMutationCommand; Timeout = $GateTimeoutSeconds },
        @{ Name = "coverage"; Command = $effectiveCoverageCommand; Timeout = $GateTimeoutSeconds }
    )

    try {
        if (@($gateDefinitions | Where-Object { $_.Command }).Count -gt 0) {
            $gateWorktreePath = New-GateWorktree -RepoRoot $repoRoot -GitCommand $gitCommand -StateDirectory $stateDirectory -Round $round
            Apply-DiffToGateWorktree -WorktreePath $gateWorktreePath -GitCommand $gitCommand -DiffText $fullDiffText
        }

        foreach ($gateDefinition in $gateDefinitions) {
            if (-not $gateDefinition.Command) {
                continue
            }

            Write-Host ""
            Write-Host ("=== Round {0} / {1}: {2} gate ===" -f $round, $MaxRounds, $gateDefinition.Name)

            $gateRepoRoot = if ($gateWorktreePath) { $gateWorktreePath } else { $repoRoot }
            $gateResult = Invoke-GateCommand `
                -Name $gateDefinition.Name `
                -CommandText $gateDefinition.Command `
                -RepoRoot $gateRepoRoot `
                -TimeoutSeconds $gateDefinition.Timeout

            $gateResults += $gateResult
            Write-Utf8File `
                -Path (Join-Path $stateDirectory ("round-{0:00}-{1}.txt" -f $round, $gateDefinition.Name)) `
                -Content $gateResult.Output

            if ($gateDefinition.Name -eq "test") {
                $testGate = $gateResult
            }
        }

        if ($effectiveCoverageLcovPath) {
            $coverageExecutionRoot = if ($gateWorktreePath) { $gateWorktreePath } else { $repoRoot }
            $coverageReportPath = Join-Path $coverageExecutionRoot $effectiveCoverageLcovPath
            if (-not (Test-Path -LiteralPath $coverageReportPath)) {
                $mechanicalIssues += New-ReviewIssue `
                    -File "repo" `
                    -Line $null `
                    -Severity "blocker" `
                    -Description "The configured LCOV report '$effectiveCoverageLcovPath' was not found." `
                    -Suggestion "Generate the coverage report before the reviewer step or correct the configured path."
            }
            else {
                $coverageMap = Read-LcovCoverageMap -ReportPath $coverageReportPath -RepoRoot $coverageExecutionRoot
                $uncoveredAddedLines = Get-UncoveredAddedProductionLines -AddedLines $addedLines -CoverageMap $coverageMap
            }
        }
    }
    finally {
        Remove-GateWorktree -WorktreePath $gateWorktreePath -RepoRoot $repoRoot -GitCommand $gitCommand
    }

    foreach ($gateResult in $gateResults) {
        if ($gateResult.ExitCode -ne 0) {
            $gateTail = Get-OutputTailText -Output $gateResult.Output -MaxLines 20
            $mechanicalIssues += New-ReviewIssue `
                -File "repo" `
                -Line $null `
                -Severity "blocker" `
                -Description ("The {0} gate failed with exit code {1}. Output tail:`n{2}" -f $gateResult.Name, $gateResult.ExitCode, $gateTail) `
                -Suggestion ("Fix the {0} failures shown above before asking the reviewer to pass the diff." -f $gateResult.Name)
        }
    }

    $missingTestIdentifiers = @()
    if ($verifyAddedTests -and $null -ne $testGate) {
        $missingTestIdentifiers = Get-MissingTestIdentifiers -Identifiers $addedTestIdentifiers -Output $testGate.Output
        foreach ($missingIdentifier in $missingTestIdentifiers) {
            $mechanicalIssues += New-ReviewIssue `
                -File $missingIdentifier.file `
                -Line $null `
                -Severity "blocker" `
                -Description "Added test '$($missingIdentifier.name)' was not found in the test command output." `
                -Suggestion "Run tests in a mode that prints executed test names, or ensure the new test actually ran."
        }
    }

    foreach ($uncoveredLine in $uncoveredAddedLines) {
        $mechanicalIssues += New-ReviewIssue `
            -File $uncoveredLine.file `
            -Line $uncoveredLine.line `
            -Severity "blocker" `
            -Description "Added production line is not covered in the configured LCOV report." `
            -Suggestion "Add or fix tests so the changed line is executed by the coverage run."
    }

    if ($mechanicalIssues.Count -gt 0) {
        $mechanicalReview = New-ReviewResult -Verdict "fail" -Issues $mechanicalIssues -ScopeCreep $scopeCreep
        Save-ReviewResult -Review $mechanicalReview -Path $reviewPath
        Write-ReviewSummary -Review $mechanicalReview

        if ($preserveRoundSnapshots) {
            [void](Save-RoundSnapshot -RepoRoot $repoRoot -GitCommand $gitCommand -StateDirectory $stateDirectory -RunId $runId -BranchPrefix $effectiveRoundBranchPrefix -Round $round -Outcome "mechanical-fail")
        }

        Write-Host ""
        Write-Host "Implementer summary:"
        if ($implementerReport -and $implementerReport.Summary) {
            Write-Host $implementerReport.Summary
        }
        elseif ($implementerOutput.Trim()) {
            Write-Host (Get-OutputTailText -Output $implementerOutput -MaxLines 60)
        }
        else {
            Write-Host "(no implementer summary)"
        }

        continue
    }

    Write-Host ""
    Write-Host "=== Round $round / ${MaxRounds}: reviewer (Claude) ==="

    $testSummary = Format-TestSummary -TestGate $testGate -MaxLines $MaxGateOutputLines
    $gateSummary = Format-GateSummary -GateResults @($gateResults | Where-Object { $_.Name -ne "test" }) -MaxLines $MaxGateOutputLines
    $testIdentifierSummary = Format-TestIdentifierAttestation -AddedTestIdentifiers $addedTestIdentifiers -MissingTestIdentifiers $missingTestIdentifiers -VerificationEnabled $verifyAddedTests
    $coverageSummary = Format-CoverageAttestation -CoverageReportPath $effectiveCoverageLcovPath -UncoveredLines $uncoveredAddedLines
    $claimedFilesJson = $implementerReport.ClaimedFiles | ConvertTo-Json -Depth 6
    $diffFilesText = if ($diffFiles.Count -gt 0) {
        $diffFiles -join [Environment]::NewLine
    }
    else {
        "(no changed files)"
    }

    $reviewPayload = @"
Claim attestation:
- Implementer claimed files:
$claimedFilesJson
- Actual changed files:
$diffFilesText
- Claim validation status: PASS

$testSummary

$gateSummary

$testIdentifierSummary

$coverageSummary

Diff under review:
$reviewDiffText
"@

    $reviewPrompt = @"
Original task:
$Task

You are the reviewer in a two-agent loop.
Codex produced the implementation. You are proofreading/reviewing Codex's diff, not applying changes.
You are running at the repository root. Treat your role as read-only: inspect files when needed, but do not edit them.
The diff on stdin is the primary artifact under review. Inspect source files and test files in the repo when needed to verify that the diff and tests target real behavior.

Code review focus:
- Check whether the implementation actually satisfies the original task.
- Look for correctness bugs, broken edge cases, regressions, missing error handling, and unsafe assumptions.
- Check whether tests were added or updated when the task changes behavior that should be covered.
- Verify that tests assert meaningful behavior instead of only exercising implementation details.
- Watch for unrelated refactors, formatting churn, dependency changes, generated files, or scope expansion.
- Prefer concrete, actionable findings over broad advice.
- Do not report style preferences, naming preferences, or speculative improvements unless they affect correctness, maintainability, testability, or task scope.
- Do not ask Codex to implement features beyond the original task. If a finding would expand scope, set scope_creep = true or use needs_clarification.

Output only a JSON object that matches the provided schema.

Verdict rules:
- Return "pass" only if the diff satisfies the task, stays in scope, and the attested gate results are acceptable.
- Return "fail" if the diff misses the task, introduces unrelated changes, fabricates behavior, or any attested gate failed.
- A nonzero test exit code must result in verdict = "fail".
- A nonzero lint, typecheck, mutation, or coverage command exit code must result in verdict = "fail".
- If added test execution attestation reports missing identifiers, verdict must be "fail".
- If coverage attestation reports uncovered added production lines, verdict must be "fail".
- Return "needs_clarification" only when the original task is too ambiguous to judge correctly from the artifact.

Issue rules:
- Populate issues with concrete findings.
- Anchor each issue to the best file path you can identify. Use a repository-relative path or "repo" when it is cross-cutting.
- Use severity "blocker" for correctness or test-gate failures, "major" for substantial review issues, and "minor" for smaller concerns.
- Include a short suggestion when you can describe the next fix clearly.

Set scope_creep = true when unrelated work is present.
Set blocking_question to a short human-facing clarification question only when verdict = "needs_clarification"; otherwise use null.

Schema:
$(Get-Content -LiteralPath $schemaPath -Raw)
"@

    Confirm-AgentCall -Enabled $confirmAgentCalls -AgentName "Claude reviewer" -Model $effectiveReviewerModel
    $reviewOutput = (Invoke-ExternalText `
        -FilePath $claudeCommand `
        -Arguments (New-ClaudeReviewerArguments -Model $effectiveReviewerModel) `
        -WorkingDirectory $repoRoot `
        -InputText "$reviewPrompt`n`n$reviewPayload" `
        -TimeoutSeconds $ReviewerTimeoutSeconds).Output
    Write-Utf8File -Path $reviewPath -Content $reviewOutput

    $review = Get-Content -LiteralPath $reviewPath -Raw | ConvertFrom-Json
    Write-ReviewSummary -Review $review

    if ($preserveRoundSnapshots) {
        [void](Save-RoundSnapshot -RepoRoot $repoRoot -GitCommand $gitCommand -StateDirectory $stateDirectory -RunId $runId -BranchPrefix $effectiveRoundBranchPrefix -Round $round -Outcome $review.verdict)
    }

    Write-Host ""
    Write-Host "Implementer summary:"
    if ($implementerReport.Summary) {
        Write-Host $implementerReport.Summary
    }
    else {
        Write-Host "(no implementer summary)"
    }

    if ($review.verdict -eq "pass") {
        Write-Host ""
        Write-Host "=== PASSED in round $round ==="
        exit 0
    }

    if ($review.verdict -eq "needs_clarification") {
        Write-Host ""
        Write-Host "=== Reviewer needs clarification ==="
        exit 2
    }
}

Write-Host ""
Write-Host "=== Hit max rounds. Escalating to human. ==="
exit 1
