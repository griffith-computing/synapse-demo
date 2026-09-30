#requires -Version 5.1
<#
.SYNOPSIS
    Zero-dependency validation entry point for tests/. Works whether or not
    Pester is installed.

.DESCRIPTION
    - If Pester (any version) is available, runs the full tests/*.Tests.ps1
      Pester suite via Invoke-Pester and surfaces its pass/fail count.
    - Always additionally runs (or, with -PesterOnly, skips) a compact,
      dependency-free smoke suite implemented in plain PowerShell (no
      Pester DSL) that exercises the same key behaviors for each script:
      dry-run/offline support, explicit failure on bad input, and no
      invented success when a dependency/artifact is missing. This gives a
      reliable validation path even on a machine with no Pester module at
      all.

    Exit code is 0 only if every executed check (Pester and/or built-in)
    passed.

.PARAMETER PesterOnly
    Skip the built-in no-dependency suite and only run Pester (fails if
    Pester is unavailable).

.PARAMETER SkipPester
    Skip Pester entirely (even if installed) and only run the built-in
    no-dependency suite. Useful to prove the workspace is validatable with
    zero external dependencies.

.EXAMPLE
    ./Run-Tests.ps1

.EXAMPLE
    ./Run-Tests.ps1 -SkipPester
#>
[CmdletBinding()]
param(
    [switch]$PesterOnly,
    [switch]$SkipPester
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
Import-Module (Join-Path $here 'TestHelpers.psm1') -Force

$overallSuccess = $true

# ---------------------------------------------------------------------------
# 1. Pester suite (only if Pester is actually installed and not skipped)
# ---------------------------------------------------------------------------
$pesterAvailable = [bool](Get-Module -ListAvailable -Name Pester -ErrorAction SilentlyContinue)

if (-not $SkipPester) {
    if ($pesterAvailable) {
        Write-Host "==> Pester detected. Running tests/*.Tests.ps1 ..." -ForegroundColor Cyan
        Import-Module Pester -Force
        $pesterResult = Invoke-Pester -Script (Join-Path $here '*.Tests.ps1') -PassThru -ErrorAction SilentlyContinue
        if (-not $pesterResult) {
            # Older Pester (3.x) -PassThru still returns an object; if this
            # somehow returned nothing, treat it as a hard failure rather
            # than silently skipping.
            Write-Host "Pester did not return a result object; treating as failure." -ForegroundColor Red
            $overallSuccess = $false
        } else {
            $failed = $pesterResult.FailedCount
            $passed = $pesterResult.PassedCount
            Write-Host "Pester: $passed passed, $failed failed." -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
            if ($failed -gt 0) { $overallSuccess = $false }
        }
    } else {
        Write-Host "==> Pester is not installed on this machine. Skipping Pester suite (this is expected/OK; the no-dependency suite below still validates the scripts)." -ForegroundColor Yellow
        if ($PesterOnly) {
            Write-Host "-PesterOnly was specified but Pester is unavailable." -ForegroundColor Red
            exit 2
        }
    }
}

if ($PesterOnly) {
    exit ([int](-not $overallSuccess))
}

# ---------------------------------------------------------------------------
# 2. Built-in, zero-dependency smoke suite
# ---------------------------------------------------------------------------
$script:CheckResults = New-Object System.Collections.Generic.List[object]

function Test-Case {
    <#
        .SYNOPSIS
            Runs a single named check. $Body should throw (or call
            Assert-True/Assert-Equal) to indicate failure.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    try {
        & $Body
        $script:CheckResults.Add([PSCustomObject]@{ Name = $Name; Passed = $true; Error = $null })
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } catch {
        $script:CheckResults.Add([PSCustomObject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message })
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "Assertion failed: $Message (expected '$Expected', got '$Actual')" }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) { throw "Assertion failed: $Message (pattern '$Pattern' not found)" }
}

Write-Host ""
Write-Host "==> Running built-in no-dependency smoke suite ..." -ForegroundColor Cyan

$sandbox = New-TestSandbox
try {
    # --- Common.psm1 ---------------------------------------------------
    Import-Module (Join-Path (Get-TestScriptsDir) 'Common.psm1') -Force

    Test-Case 'Common: secret redaction hides password values' {
        $r = Protect-SynapseSecretText -Text 'password=hunter2'
        Assert-True ($r -notmatch 'hunter2') 'password value should be redacted'
    }

    Test-Case 'Common: Get-SynapseExitCode returns 0 for Success' {
        Assert-Equal 0 (Get-SynapseExitCode -Name Success) 'Success exit code should be 0'
    }

    Test-Case 'Common: Assert-SynapseDependency throws for a missing command by default' {
        $threw = $false
        try { Assert-SynapseDependency -Name 'this-tool-does-not-exist-xyz' } catch { $threw = $true }
        Assert-True $threw 'Assert-SynapseDependency should throw when a required dependency is missing'
    }

    Test-Case 'Common: ConvertTo-SynapseStringArray splits a single comma-separated token' {
        $result = ConvertTo-SynapseStringArray -Value @('a,b,c')
        Assert-Equal 3 $result.Count 'expected 3 elements after split'
    }

    # --- Test-SynapseRepository.ps1 -------------------------------------
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'present') -Force | Out-Null

    Test-Case 'Test-SynapseRepository: passes for an existing required path (offline)' {
        $r = Invoke-ScriptUnderTest -ScriptName 'Test-SynapseRepository.ps1' -Parameters @{ RepositoryRoot = $sandbox; RequiredPaths = @('present'); Offline = $true }
        Assert-Equal 0 $r.ExitCode 'validation should pass'
    }

    Test-Case 'Test-SynapseRepository: fails explicitly for a missing required path' {
        $r = Invoke-ScriptUnderTest -ScriptName 'Test-SynapseRepository.ps1' -Parameters @{ RepositoryRoot = $sandbox; RequiredPaths = @('missing-xyz'); Offline = $true }
        Assert-Equal 1 $r.ExitCode 'validation should fail explicitly, not silently pass'
    }

    # --- New-SynapseReleasePackage.ps1 -----------------------------------
    $srcDir = Join-Path $sandbox 'src'
    New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
    'print(1)' | Set-Content -LiteralPath (Join-Path $srcDir 'a.py')
    $releaseDir = Join-Path $sandbox 'release'

    Test-Case 'New-SynapseReleasePackage: dry-run does not write any files' {
        $r = Invoke-ScriptUnderTest -ScriptName 'New-SynapseReleasePackage.ps1' -Parameters @{ SourcePaths = @($srcDir); OutputDirectory = $releaseDir; Version = '9.9.9'; DryRun = $true }
        Assert-Equal 0 $r.ExitCode 'dry-run should succeed'
        Assert-True (-not (Test-Path -LiteralPath $releaseDir)) 'dry-run must not create the output directory'
    }

    Test-Case 'New-SynapseReleasePackage: real run produces manifest + checksums + zip' {
        $r = Invoke-ScriptUnderTest -ScriptName 'New-SynapseReleasePackage.ps1' -Parameters @{ SourcePaths = @($srcDir); OutputDirectory = $releaseDir; Version = '9.9.9' }
        Assert-Equal 0 $r.ExitCode 'packaging should succeed'
        Assert-True (Test-Path -LiteralPath (Join-Path $releaseDir 'synapse-release-9.9.9.manifest.json')) 'manifest should exist'
        Assert-True (Test-Path -LiteralPath (Join-Path $releaseDir 'synapse-release-9.9.9.zip')) 'zip should exist'
    }

    Test-Case 'New-SynapseReleasePackage: fails explicitly for a missing source path' {
        $r = Invoke-ScriptUnderTest -ScriptName 'New-SynapseReleasePackage.ps1' -Parameters @{ SourcePaths = @((Join-Path $sandbox 'nope')); OutputDirectory = (Join-Path $sandbox 'release-2'); Version = '1.0.0' }
        Assert-True ($r.ExitCode -ne 0) 'packaging must fail, not invent success, for a missing source path'
    }

    # --- Deploy-SynapseWorkspace.ps1 -------------------------------------
    $templateFile = Join-Path $sandbox 'template.json'
    $paramsFile = Join-Path $sandbox 'params.json'
    '{}' | Set-Content -LiteralPath $templateFile
    '{}' | Set-Content -LiteralPath $paramsFile

    Test-Case 'Deploy-SynapseWorkspace: offline mode builds the command without calling az' {
        $r = Invoke-ScriptUnderTest -ScriptName 'Deploy-SynapseWorkspace.ps1' -Parameters @{ ResourceGroupName = 'rg-x'; WorkspaceName = 'ws-x'; TemplateFile = $templateFile; TemplateParametersFile = $paramsFile; Offline = $true }
        Assert-Equal 0 $r.ExitCode 'offline deploy should succeed'
        Assert-Match $r.StdOut 'deployment group create' 'should log the constructed az command'
    }

    Test-Case 'Deploy-SynapseWorkspace: fails explicitly when the template file is missing' {
        $r = Invoke-ScriptUnderTest -ScriptName 'Deploy-SynapseWorkspace.ps1' -Parameters @{ ResourceGroupName = 'rg-x'; WorkspaceName = 'ws-x'; TemplateFile = (Join-Path $sandbox 'missing.json'); TemplateParametersFile = $paramsFile; Offline = $true }
        Assert-True ($r.ExitCode -ne 0) 'deploy must fail, not invent success, for a missing template'
    }

    # --- Invoke-SynapseSmokeTests.ps1 ------------------------------------
    $smokeDefs = Join-Path $sandbox 'smoke.json'
    '[{"Name":"X","Type":"AzCommand","Command":["synapse","workspace","show"],"Mutating":false}]' | Set-Content -LiteralPath $smokeDefs

    Test-Case 'Invoke-SynapseSmokeTests: offline mode skips (never fakes pass/fail)' {
        $r = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseSmokeTests.ps1' -Parameters @{ TestDefinitionsPath = $smokeDefs; Offline = $true }
        Assert-Equal 0 $r.ExitCode 'offline smoke test run should succeed overall'
        Assert-Match $r.StdOut 'Skipped\s*:\s*1' 'the single test should be reported as Skipped, not Passed'
    }

    Test-Case 'Invoke-SynapseSmokeTests: fails explicitly when definitions file is missing' {
        $r = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseSmokeTests.ps1' -Parameters @{ TestDefinitionsPath = (Join-Path $sandbox 'no-file.json'); Offline = $true }
        Assert-True ($r.ExitCode -ne 0) 'must fail, not invent success, for a missing definitions file'
    }

    # --- Invoke-SynapseRollback.ps1 ---------------------------------------
    $pkgDir = Join-Path $sandbox 'packages'
    New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
    'content' | Set-Content -LiteralPath (Join-Path $pkgDir 'asset-1.0.0.txt') -NoNewline
    $hash = (Get-FileHash -LiteralPath (Join-Path $pkgDir 'asset-1.0.0.txt') -Algorithm SHA256).Hash
    $manifestObj = [PSCustomObject]@{
        PackageName = 'synapse-release'; Version = '1.0.0'; CreatedUtc = [DateTime]::UtcNow.ToString('o')
        GitCommit = $null; FileCount = 1; TotalBytes = 7
        Files = @([PSCustomObject]@{ RelativePath = 'asset-1.0.0.txt'; Sha256 = $hash; SizeBytes = 7 })
    }
    $manifestObj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $pkgDir 'synapse-release-1.0.0.manifest.json')

    Test-Case 'Invoke-SynapseRollback: selects a valid candidate and verifies checksums' {
        $r = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseRollback.ps1' -Parameters @{ PackageDirectory = $pkgDir; DryRun = $true }
        Assert-Equal 0 $r.ExitCode 'rollback selection should succeed for a valid package'
        Assert-Match $r.StdOut 'ChecksumsVerified\s*:\s*True' 'checksum verification should have run and passed'
    }

    Test-Case 'Invoke-SynapseRollback: fails explicitly when no manifests exist' {
        $emptyDir = Join-Path $sandbox 'no-packages'
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        $r = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseRollback.ps1' -Parameters @{ PackageDirectory = $emptyDir; DryRun = $true }
        Assert-True ($r.ExitCode -ne 0) 'must fail, not invent a rollback candidate, when none exist'
    }
} finally {
    Remove-TestSandbox -Path $sandbox
}

$builtInFailed = @($script:CheckResults | Where-Object { -not $_.Passed }).Count
$builtInPassed = @($script:CheckResults | Where-Object { $_.Passed }).Count

Write-Host ""
Write-Host "Built-in suite: $builtInPassed passed, $builtInFailed failed." -ForegroundColor $(if ($builtInFailed -eq 0) { 'Green' } else { 'Red' })

if ($builtInFailed -gt 0) { $overallSuccess = $false }

if ($overallSuccess) {
    Write-Host ""
    Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Host "ONE OR MORE CHECKS FAILED" -ForegroundColor Red
    exit 1
}
