#requires -Version 5.1
<#
.SYNOPSIS
    Orchestrates smoke tests against a deployed Synapse workspace, driven by
    a declarative JSON test-definitions file.

.DESCRIPTION
    Each test definition is a JSON object with:
        Name    : string, required
        Type    : 'AzCommand' | 'HttpCheck'   (required)
        Command : (AzCommand) the az subcommand args as an array, e.g.
                  ["synapse","pipeline","show","--workspace-name","x",
                   "--name","y","--resource-group","rg"]
        Url     : (HttpCheck) URL to GET and expect a 2xx response
        Mutating: bool, default $false. Mutating tests (e.g. triggering a
                  pipeline run) are skipped (not faked) whenever -DryRun or
                  -Offline is set; only read-only checks execute in those
                  modes.

    Aggregates Pass/Fail/Skipped and exits non-zero only if any test
    actually failed. Skips (offline/dry-run/mutating) never count as a
    failure but are reported distinctly so CI cannot mistake "skipped" for
    "passed".

.OUTPUTS
    PSCustomObject summary; also written to -OutputJsonPath if supplied.

.EXAMPLE
    ./Invoke-SynapseSmokeTests.ps1 -TestDefinitionsPath .\tests\fixtures\smoke-tests.sample.json -Offline

.EXAMPLE
    ./Invoke-SynapseSmokeTests.ps1 -TestDefinitionsPath .\smoke-tests.json -TimeoutSeconds 300
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TestDefinitionsPath,

    [Parameter()]
    [int]$TimeoutSeconds = 120,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$Offline,

    [Parameter()]
    [string]$OutputJsonPath,

    [Parameter()]
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

function Invoke-SingleSmokeTest {
    param(
        [Parameter(Mandatory = $true)]$Definition,
        [Parameter(Mandatory = $true)][bool]$IsSimulated,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter()][string]$LogPath
    )

    $name = $Definition.Name
    $type = $Definition.Type
    $isMutating = [bool]($Definition.PSObject.Properties.Match('Mutating').Count -and $Definition.Mutating)

    if ($IsSimulated -and $isMutating) {
        Write-SynapseLog -LogPath $LogPath -Level Warning -Message "Skipping mutating smoke test '$name' (offline/dry-run mode)."
        return [PSCustomObject]@{ Name = $name; Status = 'Skipped'; Reason = 'Mutating test skipped in offline/dry-run mode'; Detail = $null }
    }

    switch ($type) {
        'AzCommand' {
            if ($IsSimulated) {
                $cmdText = "az $($Definition.Command -join ' ')"
                Write-SynapseLog -LogPath $LogPath -Level Info -Message "[Simulated] Would run: $(Protect-SynapseSecretText -Text $cmdText)"
                return [PSCustomObject]@{ Name = $name; Status = 'Skipped'; Reason = 'Offline/DryRun - az command not executed'; Detail = $cmdText }
            }
            try {
                Assert-SynapseDependency -Name 'az' | Out-Null
            } catch {
                return [PSCustomObject]@{ Name = $name; Status = 'Fail'; Reason = $_.Exception.Message; Detail = $null }
            }
            $result = Invoke-SynapseManagedCommand -FilePath 'az' -ArgumentList $Definition.Command -DryRun:$false -Description "Running smoke test '$name'"
            if ($result.ExitCode -eq 0) {
                return [PSCustomObject]@{ Name = $name; Status = 'Pass'; Reason = $null; Detail = $result.Command }
            } else {
                return [PSCustomObject]@{ Name = $name; Status = 'Fail'; Reason = "az exited with code $($result.ExitCode)"; Detail = $result.Command }
            }
        }
        'HttpCheck' {
            if ($IsSimulated) {
                Write-SynapseLog -LogPath $LogPath -Level Info -Message "[Simulated] Would GET: $($Definition.Url)"
                return [PSCustomObject]@{ Name = $name; Status = 'Skipped'; Reason = 'Offline/DryRun - HTTP check not executed'; Detail = $Definition.Url }
            }
            try {
                $response = Invoke-WebRequest -Uri $Definition.Url -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                    return [PSCustomObject]@{ Name = $name; Status = 'Pass'; Reason = $null; Detail = "HTTP $($response.StatusCode)" }
                } else {
                    return [PSCustomObject]@{ Name = $name; Status = 'Fail'; Reason = "Unexpected status code $($response.StatusCode)"; Detail = $Definition.Url }
                }
            } catch {
                return [PSCustomObject]@{ Name = $name; Status = 'Fail'; Reason = $_.Exception.Message; Detail = $Definition.Url }
            }
        }
        default {
            return [PSCustomObject]@{ Name = $name; Status = 'Fail'; Reason = "Unknown test Type '$type'"; Detail = $null }
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath $TestDefinitionsPath)) {
        throw "TestDefinitionsPath not found: $TestDefinitionsPath"
    }
    $rawDefinitions = Get-Content -LiteralPath $TestDefinitionsPath -Raw | ConvertFrom-Json
    # ConvertFrom-Json emits a JSON array as a single pipeline object already
    # typed [object[]]; wrapping it in @() again would nest it. Only a
    # single top-level JSON object needs @() to become an iterable array.
    $definitions = @(if ($rawDefinitions -is [array]) { $rawDefinitions } else { $rawDefinitions })
    if (-not $definitions -or $definitions.Count -eq 0) {
        throw "No smoke test definitions found in '$TestDefinitionsPath'."
    }

    $isSimulated = [bool]($DryRun -or $Offline)
    Write-SynapseLog -LogPath $LogPath -Message "Running $($definitions.Count) smoke test(s) (simulated=$isSimulated)."

    $results = @()
    foreach ($def in $definitions) {
        $results += Invoke-SingleSmokeTest -Definition $def -IsSimulated $isSimulated -TimeoutSeconds $TimeoutSeconds -LogPath $LogPath
    }

    $passCount = @($results | Where-Object { $_.Status -eq 'Pass' }).Count
    $failCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $skipCount = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count

    $summary = [PSCustomObject]@{
        TotalTests   = $results.Count
        Passed       = $passCount
        Failed       = $failCount
        Skipped      = $skipCount
        Simulated    = $isSimulated
        Results      = $results
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        IsSuccess    = ($failCount -eq 0)
    }

    if ($OutputJsonPath) {
        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputJsonPath -Encoding UTF8
    }

    Set-SynapsePipelineOutput -Name 'smokeTestsPassed' -Value ([string]$summary.IsSuccess)
    Set-SynapsePipelineOutput -Name 'smokeTestsFailedCount' -Value ([string]$failCount)
    Set-SynapsePipelineOutput -Name 'smokeTestsSkippedCount' -Value ([string]$skipCount)

    foreach ($r in $results) {
        $level = switch ($r.Status) { 'Pass' { 'Success' }; 'Fail' { 'Error' }; default { 'Warning' } }
        $reasonSuffix = if ($r.Reason) { " - $($r.Reason)" } else { '' }
        Write-SynapseLog -LogPath $LogPath -Level $level -Message "[$($r.Status)] $($r.Name)$reasonSuffix"
    }

    $summary
    if ($summary.IsSuccess) {
        exit (Get-SynapseExitCode -Name Success)
    } else {
        exit (Get-SynapseExitCode -Name ValidationFailed)
    }
} catch {
    Write-SynapseLog -LogPath $LogPath -Level Error -Message "Smoke test orchestration failed: $($_.Exception.Message)"
    exit (Get-SynapseExitCode -Name ExecutionFailed)
}
