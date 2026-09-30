#requires -Version 5.1
<#
.SYNOPSIS
    Selects and verifies a rollback candidate package from a directory of
    release packages produced by New-SynapseReleasePackage.ps1.

.DESCRIPTION
    Scans -PackageDirectory for *.manifest.json files, applies optional
    -ExcludeVersions / -TargetVersion filters, and selects the newest
    remaining candidate by CreatedUtc (or an exact -TargetVersion match).

    By default the selected package's checksums are re-verified against the
    files on disk (-VerifyChecksums, default on) so a corrupted or
    tampered package can never be silently used for rollback. This check is
    always performed - even offline/dry-run - because it is purely local
    file I/O with no external dependency.

    This script only SELECTS and VERIFIES a candidate; it does not deploy
    it. Chain its output (SelectedPackagePath / template locations inside
    the package) into Deploy-SynapseWorkspace.ps1 to actually perform the
    rollback deployment.

.OUTPUTS
    PSCustomObject: SelectedVersion, SelectedManifestPath, SelectedPackagePath,
    ChecksumsVerified, Candidates, IsValid

.EXAMPLE
    ./Invoke-SynapseRollback.ps1 -PackageDirectory .\release -ExcludeVersions '1.4.0' -DryRun

.EXAMPLE
    ./Invoke-SynapseRollback.ps1 -PackageDirectory .\release -TargetVersion '1.3.2'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageDirectory,

    [Parameter()]
    [string]$TargetVersion,

    [Parameter()]
    [string[]]$ExcludeVersions = @(),

    [Parameter()]
    [switch]$VerifyChecksums = $true,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$Offline,

    [Parameter()]
    [string]$ResultJsonPath,

    [Parameter()]
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

try {
    $ExcludeVersions = ConvertTo-SynapseStringArray -Value $ExcludeVersions

    if (-not (Test-Path -LiteralPath $PackageDirectory)) {
        throw "PackageDirectory not found: $PackageDirectory"
    }
    $PackageDirectory = (Resolve-Path -LiteralPath $PackageDirectory).Path

    $manifestFiles = @(Get-ChildItem -LiteralPath $PackageDirectory -Filter '*.manifest.json' -File -ErrorAction SilentlyContinue)
    if (-not $manifestFiles -or $manifestFiles.Count -eq 0) {
        throw "No release manifests (*.manifest.json) found in '$PackageDirectory'. Cannot select a rollback candidate."
    }

    $candidates = @()
    foreach ($mf in $manifestFiles) {
        try {
            $manifest = Get-Content -LiteralPath $mf.FullName -Raw | ConvertFrom-Json
            $candidates += [PSCustomObject]@{
                Version      = $manifest.Version
                CreatedUtc   = [DateTime]::Parse($manifest.CreatedUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                ManifestPath = $mf.FullName
                PackageName  = $manifest.PackageName
            }
        } catch {
            Write-SynapseLog -LogPath $LogPath -Level Warning -Message "Skipping unreadable manifest '$($mf.FullName)': $($_.Exception.Message)"
        }
    }

    if ($candidates.Count -eq 0) {
        throw "Found manifest files in '$PackageDirectory' but none could be parsed. Cannot select a rollback candidate."
    }

    $eligible = $candidates | Where-Object { $ExcludeVersions -notcontains $_.Version }

    $selected = $null
    if ($TargetVersion) {
        $selected = $eligible | Where-Object { $_.Version -eq $TargetVersion } | Select-Object -First 1
        if (-not $selected) {
            throw "Requested TargetVersion '$TargetVersion' was not found among eligible candidates in '$PackageDirectory'."
        }
    } else {
        $selected = $eligible | Sort-Object CreatedUtc -Descending | Select-Object -First 1
        if (-not $selected) {
            throw "No eligible rollback candidate remains after applying ExcludeVersions filter. Refusing to guess."
        }
    }

    Write-SynapseLog -LogPath $LogPath -Message "Selected rollback candidate: version=$($selected.Version) manifest=$($selected.ManifestPath)"

    $checksumsVerified = $null
    $verificationDetail = $null
    if ($VerifyChecksums) {
        $verificationDetail = Test-SynapseFileManifest -ManifestPath $selected.ManifestPath -BasePath $PackageDirectory
        $checksumsVerified = $verificationDetail.IsValid
        if ($checksumsVerified) {
            Write-SynapseLog -LogPath $LogPath -Level Success -Message "Checksum verification passed for rollback candidate '$($selected.Version)'."
        } else {
            Write-SynapseLog -LogPath $LogPath -Level Error -Message "Checksum verification FAILED for rollback candidate '$($selected.Version)'. Refusing to select a corrupted/tampered package."
        }
    } else {
        Write-SynapseLog -LogPath $LogPath -Level Warning -Message "VerifyChecksums disabled by caller; selected package integrity was NOT confirmed."
    }

    $packagePath = Join-Path $PackageDirectory "$($selected.PackageName)-$($selected.Version).zip"
    $isValid = if ($VerifyChecksums) { [bool]$checksumsVerified } else { $true }

    $summary = [PSCustomObject]@{
        SelectedVersion      = $selected.Version
        SelectedManifestPath = $selected.ManifestPath
        SelectedPackagePath  = if (Test-Path -LiteralPath $packagePath) { $packagePath } else { $null }
        ChecksumsVerified    = $checksumsVerified
        VerificationDetail   = $verificationDetail
        Candidates           = @($candidates | Select-Object Version, CreatedUtc, ManifestPath)
        Offline              = [bool]($DryRun -or $Offline)
        IsValid              = $isValid
        TimestampUtc         = [DateTime]::UtcNow.ToString('o')
    }

    if ($ResultJsonPath) {
        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
    }

    Set-SynapsePipelineOutput -Name 'rollbackSelectedVersion' -Value ([string]$selected.Version)
    Set-SynapsePipelineOutput -Name 'rollbackIsValid' -Value ([string]$isValid)

    $summary
    if ($isValid) {
        exit (Get-SynapseExitCode -Name Success)
    } else {
        exit (Get-SynapseExitCode -Name RollbackFailed)
    }
} catch {
    Write-SynapseLog -LogPath $LogPath -Level Error -Message "Rollback selection/verification failed: $($_.Exception.Message)"
    exit (Get-SynapseExitCode -Name ExecutionFailed)
}
