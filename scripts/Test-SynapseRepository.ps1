#requires -Version 5.1
<#
.SYNOPSIS
    Validates repository layout, configuration files, and release artifacts
    before a Synapse deployment is allowed to proceed.

.DESCRIPTION
    Read-only, side-effect-free check used as a gate by CI (GitHub Actions
    or Azure DevOps) and locally. It never mutates the repository.

    Three independent checks are performed, each optional so this single
    script can validate whatever the caller supplies without assuming a
    fixed folder layout owned by other teams (infra/synapse/config/pipelines
    are intentionally NOT hard-coded here):

      1. RequiredPaths       - files/folders that must exist (relative to
                                -RepositoryRoot).
      2. ConfigFiles         - JSON/YAML files that must parse and must not
                                contain obviously hard-coded plaintext
                                secrets.
      3. ArtifactManifestPath - a manifest.json (as produced by
                                New-SynapseReleasePackage.ps1) whose
                                recorded checksums must match the files on
                                disk under -ArtifactBasePath.

.PARAMETER DryRun
    Alias for -Offline for this script: validation is always read-only, so
    DryRun/Offline only affect whether the optional Azure resource check is
    attempted.

.PARAMETER VerifyAzureResourceGroup
    Optional resource group name. When supplied (and not offline/dry-run),
    validates the resource group exists via az CLI. This is a genuine
    network call and is skipped (not faked) when offline.

.OUTPUTS
    PSCustomObject summary written to -ResultJsonPath (if supplied) and
    returned on the pipeline. Exit code 0 = pass, 1 = validation failed,
    2 = missing dependency for a requested (non-skippable) check.

.EXAMPLE
    ./Test-SynapseRepository.ps1 -RepositoryRoot . -RequiredPaths 'synapse/workspace' -ConfigFiles 'config/dev.json' -DryRun

.EXAMPLE
    ./Test-SynapseRepository.ps1 -RepositoryRoot . -ArtifactManifestPath ./release/manifest.json -ArtifactBasePath ./release -Offline
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepositoryRoot,

    [Parameter()]
    [string[]]$RequiredPaths = @(),

    [Parameter()]
    [string[]]$ConfigFiles = @(),

    [Parameter()]
    [string]$ArtifactManifestPath,

    [Parameter()]
    [string]$ArtifactBasePath,

    [Parameter()]
    [string]$VerifyAzureResourceGroup,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$Offline,

    [Parameter()]
    [switch]$FailOnConfigWarning,

    [Parameter()]
    [string]$ResultJsonPath,

    [Parameter()]
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

# DryRun and Offline are treated identically by this read-only script.
$isOffline = [bool]($DryRun -or $Offline)

$failures = @()
$warnings = @()
$skipped = @()
$passed = @()

try {
    $RequiredPaths = ConvertTo-SynapseStringArray -Value $RequiredPaths
    $ConfigFiles = ConvertTo-SynapseStringArray -Value $ConfigFiles

    if (-not $RepositoryRoot) {
        $RepositoryRoot = Get-SynapseRepositoryRoot -StartPath $PSScriptRoot
    }
    if (-not (Test-Path -LiteralPath $RepositoryRoot)) {
        throw "RepositoryRoot does not exist: $RepositoryRoot"
    }
    $RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
    Write-SynapseLog -LogPath $LogPath -Message "Validating repository at '$RepositoryRoot' (Offline/DryRun=$isOffline)"

    # --- 1. Required paths -------------------------------------------------
    foreach ($relativePath in $RequiredPaths) {
        $fullPath = Join-Path $RepositoryRoot $relativePath
        if (Test-Path -LiteralPath $fullPath) {
            $passed += "RequiredPath:$relativePath"
            Write-SynapseLog -LogPath $LogPath -Level Info -Message "Required path present: $relativePath"
        } else {
            $failures += "Required path missing: $relativePath"
            Write-SynapseLog -LogPath $LogPath -Level Error -Message "Required path missing: $relativePath"
        }
    }

    # --- 2. Config file parse + plaintext secret scan ----------------------
    foreach ($relativePath in $ConfigFiles) {
        $fullPath = Join-Path $RepositoryRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath)) {
            $failures += "Config file missing: $relativePath"
            Write-SynapseLog -LogPath $LogPath -Level Error -Message "Config file missing: $relativePath"
            continue
        }

        $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
        $content = Get-Content -LiteralPath $fullPath -Raw

        if ($extension -eq '.json') {
            try {
                $null = $content | ConvertFrom-Json
                $passed += "ConfigParsed:$relativePath"
                Write-SynapseLog -LogPath $LogPath -Level Info -Message "Config file parsed as valid JSON: $relativePath"
            } catch {
                $failures += "Config file is not valid JSON: $relativePath ($($_.Exception.Message))"
                Write-SynapseLog -LogPath $LogPath -Level Error -Message "Config file failed JSON parse: $relativePath"
            }
        } elseif ($extension -in @('.yml', '.yaml')) {
            # No YAML parser ships with PowerShell 5.1 by default; do a
            # best-effort structural sanity check instead of a full parse.
            if ([string]::IsNullOrWhiteSpace($content)) {
                $failures += "Config file is empty: $relativePath"
            } else {
                $passed += "ConfigPresent:$relativePath"
                Write-SynapseLog -LogPath $LogPath -Level Info -Message "YAML config present (structural check only, no parser available): $relativePath"
            }
        } else {
            if ([string]::IsNullOrWhiteSpace($content)) {
                $failures += "Config file is empty: $relativePath"
            } else {
                $passed += "ConfigPresent:$relativePath"
            }
        }

        # Plaintext secret heuristic: flag assignments like password=xxxx,
        # secret: xxxx, AccountKey=xxxx that are NOT obviously a placeholder
        # (placeholders contain $, {, }, <, > or the words like
        # 'REPLACE'/'CHANGEME'/'REDACTED'/env-var syntax).
        $secretLikeMatches = [regex]::Matches($content, '(?im)^(?<key>[^=:\r\n]*(password|secret|apikey|accountkey|token)[^=:\r\n]*)\s*[:=]\s*(?<value>[^\r\n]+)$')
        foreach ($m in $secretLikeMatches) {
            $value = $m.Groups['value'].Value.Trim().Trim('"', "'")
            $looksLikePlaceholder = $value -match '[\$\{\}\<\>]' -or $value -match '(?i)replace|changeme|redacted|example|xxxx|placeholder|^$'
            if (-not $looksLikePlaceholder -and $value.Length -gt 0) {
                $msg = "Possible hard-coded secret in ${relativePath}: key '$($m.Groups['key'].Value.Trim())'"
                $warnings += $msg
                Write-SynapseLog -LogPath $LogPath -Level Warning -Message $msg
            }
        }
    }

    # --- 3. Artifact manifest / checksum verification -----------------------
    if ($ArtifactManifestPath) {
        if (-not $ArtifactBasePath) {
            $ArtifactBasePath = Split-Path -Parent (Resolve-Path -LiteralPath $ArtifactManifestPath -ErrorAction Stop)
        }
        try {
            $manifestResult = Test-SynapseFileManifest -ManifestPath $ArtifactManifestPath -BasePath $ArtifactBasePath
            if ($manifestResult.IsValid) {
                $passed += 'ArtifactManifestVerified'
                Write-SynapseLog -LogPath $LogPath -Level Success -Message "Artifact manifest checksum verification passed."
            } else {
                foreach ($miss in $manifestResult.Missing) {
                    $failures += "Artifact missing referenced by manifest: $miss"
                }
                foreach ($mismatch in $manifestResult.Mismatches) {
                    $failures += "Artifact checksum mismatch: $($mismatch.RelativePath) expected=$($mismatch.Expected) actual=$($mismatch.Actual)"
                }
                Write-SynapseLog -LogPath $LogPath -Level Error -Message "Artifact manifest checksum verification FAILED."
            }
        } catch {
            $failures += "Failed to verify artifact manifest: $($_.Exception.Message)"
        }
    }

    # --- Optional live Azure check ------------------------------------------
    if ($VerifyAzureResourceGroup) {
        if ($isOffline) {
            $skipped += "AzureResourceGroupCheck:$VerifyAzureResourceGroup (offline/dry-run - not executed, not assumed to pass)"
            Write-SynapseLog -LogPath $LogPath -Level Warning -Message "Skipping live Azure resource group check for '$VerifyAzureResourceGroup' because Offline/DryRun was specified."
        } else {
            Assert-SynapseDependency -Name 'az' | Out-Null
            $result = Invoke-SynapseManagedCommand -FilePath 'az' -ArgumentList @('group', 'show', '--name', $VerifyAzureResourceGroup, '-o', 'none') -DryRun:$false -Description "Checking resource group '$VerifyAzureResourceGroup' exists"
            if ($result.ExitCode -eq 0) {
                $passed += "AzureResourceGroupCheck:$VerifyAzureResourceGroup"
            } else {
                $failures += "Resource group '$VerifyAzureResourceGroup' not found or inaccessible (az exit code $($result.ExitCode))"
            }
        }
    }

    if ($FailOnConfigWarning -and $warnings.Count -gt 0) {
        $failures += $warnings
    }

    $summary = [PSCustomObject]@{
        RepositoryRoot = $RepositoryRoot
        Offline        = $isOffline
        Passed         = $passed
        Warnings       = $warnings
        Skipped        = $skipped
        Failures       = $failures
        IsValid        = ($failures.Count -eq 0)
        TimestampUtc   = [DateTime]::UtcNow.ToString('o')
    }

    if ($ResultJsonPath) {
        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
    }

    Set-SynapsePipelineOutput -Name 'validationPassed' -Value ([string]$summary.IsValid)
    Set-SynapsePipelineOutput -Name 'validationFailureCount' -Value ([string]$failures.Count)

    if ($summary.IsValid) {
        Write-SynapseLog -LogPath $LogPath -Level Success -Message "Validation PASSED ($($passed.Count) checks, $($warnings.Count) warnings, $($skipped.Count) skipped)."
        $summary
        exit (Get-SynapseExitCode -Name Success)
    } else {
        Write-SynapseLog -LogPath $LogPath -Level Error -Message "Validation FAILED with $($failures.Count) failure(s):"
        foreach ($f in $failures) { Write-SynapseLog -LogPath $LogPath -Level Error -Message " - $f" }
        $summary
        exit (Get-SynapseExitCode -Name ValidationFailed)
    }
} catch {
    Write-SynapseLog -LogPath $LogPath -Level Error -Message "Validation script failed unexpectedly: $($_.Exception.Message)"
    exit (Get-SynapseExitCode -Name ExecutionFailed)
}
