#requires -Version 5.1
<#
.SYNOPSIS
    Assembles a release package (zip) from one or more source paths,
    producing a checksum manifest and a plain sha256 checksums file.

.DESCRIPTION
    Deterministic, offline-capable packaging step:
      - Computes SHA256 + size for every file under -SourcePaths.
      - Writes manifest.json (structured, consumed by Test-SynapseRepository.ps1
        and Invoke-SynapseRollback.ps1) and checksums.sha256 (plain
        `sha256  path` lines, compatible with `sha256sum -c`).
      - Optionally compresses everything into a single .zip using the
        built-in Compress-Archive cmdlet (no third-party dependency).

    In -DryRun mode, nothing is written to disk. The script instead reports
    exactly what it would produce (file count, total size, computed
    manifest) so CI can preview a release without creating artifacts.

.PARAMETER Offline
    Accepted for interface symmetry with the other scripts. Packaging never
    performs network calls, so Offline only suppresses optional git remote
    metadata lookups (local `git rev-parse` calls, which do not touch the
    network, are still attempted unless git itself is unavailable).

.OUTPUTS
    PSCustomObject: PackagePath, ManifestPath, ChecksumsPath, PackageSha256,
    FileCount, TotalSizeBytes, Simulated

.EXAMPLE
    ./New-SynapseReleasePackage.ps1 -SourcePaths .\synapse\workspace -OutputDirectory .\release -Version 1.2.3 -DryRun

.EXAMPLE
    ./New-SynapseReleasePackage.ps1 -SourcePaths .\synapse\workspace, .\config\prod.json -OutputDirectory .\release -Version 1.2.3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$SourcePaths,

    [Parameter()]
    [string]$OutputDirectory = '.\release',

    [Parameter()]
    [string]$PackageName = 'synapse-release',

    [Parameter()]
    [string]$Version,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$Offline,

    [Parameter()]
    [switch]$SkipArchive,

    [Parameter()]
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

try {
    $SourcePaths = ConvertTo-SynapseStringArray -Value $SourcePaths
    if ($SourcePaths.Count -eq 0) {
        throw "SourcePaths must contain at least one path."
    }
    foreach ($p in $SourcePaths) {
        if (-not (Test-Path -LiteralPath $p)) {
            throw "Source path not found: $p"
        }
    }

    if (-not $Version) {
        $Version = [DateTime]::UtcNow.ToString('yyyyMMdd.HHmmss')
        Write-SynapseLog -LogPath $LogPath -Level Warning -Message "No -Version supplied; generated timestamp-based version '$Version'."
    }

    $gitCommit = $null
    if (-not $Offline -and (Test-SynapseCommandAvailable -Name 'git')) {
        $gitCommit = git rev-parse HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { $gitCommit = $null }
    }

    # Compress-Archive preserves each supplied source root. Build manifest
    # paths from their containing directories so verification uses the same
    # layout after extraction, including when only one directory is packaged.
    $resolvedSources = @($SourcePaths | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
    $sourceContainers = @($resolvedSources | ForEach-Object { Split-Path -Parent $_ })
    $basePath = Get-SynapseCommonAncestorPath -ResolvedPath $sourceContainers

    Write-SynapseLog -LogPath $LogPath -Message "Computing manifest for $($SourcePaths.Count) source path(s) relative to '$basePath'..."
    $entries = @(Get-SynapseFileManifestEntries -Path $resolvedSources -BasePath $basePath)

    if ($entries.Count -eq 0) {
        throw "No files found under the supplied SourcePaths; refusing to create an empty package."
    }

    $totalSize = ($entries | Measure-Object -Property SizeBytes -Sum).Sum
    $packageFileName = "$PackageName-$Version.zip"
    $manifestFileName = "$PackageName-$Version.manifest.json"
    $checksumsFileName = "$PackageName-$Version.checksums.sha256"

    $manifestObject = [PSCustomObject]@{
        PackageName  = $PackageName
        Version      = $Version
        CreatedUtc   = [DateTime]::UtcNow.ToString('o')
        GitCommit    = $gitCommit
        FileCount    = $entries.Count
        TotalBytes   = $totalSize
        Files        = $entries
    }

    Write-SynapseLog -LogPath $LogPath -Message "Manifest computed: $($entries.Count) file(s), $totalSize byte(s) total."

    if ($DryRun) {
        Write-SynapseLog -LogPath $LogPath -Level Info -Message "[DryRun] Would write manifest '$manifestFileName', checksums '$checksumsFileName', and archive '$packageFileName' to '$OutputDirectory'. No files were written."
        $result = [PSCustomObject]@{
            PackagePath     = (Join-Path $OutputDirectory $packageFileName)
            ManifestPath    = (Join-Path $OutputDirectory $manifestFileName)
            ChecksumsPath   = (Join-Path $OutputDirectory $checksumsFileName)
            PackageSha256   = $null
            FileCount       = $entries.Count
            TotalSizeBytes  = $totalSize
            Version         = $Version
            Simulated       = $true
        }
        Set-SynapsePipelineOutput -Name 'packageVersion' -Value $Version
        Set-SynapsePipelineOutput -Name 'packageSimulated' -Value 'true'
        $result
        exit (Get-SynapseExitCode -Name Success)
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

    $manifestPath = Join-Path $OutputDirectory $manifestFileName
    $manifestObject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-SynapseLog -LogPath $LogPath -Level Info -Message "Wrote manifest: $manifestPath"

    $checksumsPath = Join-Path $OutputDirectory $checksumsFileName
    $checksumLines = $entries | ForEach-Object { "$($_.Sha256)  $($_.RelativePath)" }
    Set-Content -LiteralPath $checksumsPath -Value $checksumLines -Encoding UTF8
    Write-SynapseLog -LogPath $LogPath -Level Info -Message "Wrote checksums: $checksumsPath"

    $packageSha256 = $null
    $packagePath = Join-Path $OutputDirectory $packageFileName
    if (-not $SkipArchive) {
        if (Test-Path -LiteralPath $packagePath) {
            Remove-Item -LiteralPath $packagePath -Force
        }
        # Compress-Archive is built into PowerShell 5.1 - no extra module needed.
        Compress-Archive -Path $resolvedSources -DestinationPath $packagePath -CompressionLevel Optimal
        $packageSha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
        Write-SynapseLog -LogPath $LogPath -Level Success -Message "Created package: $packagePath (SHA256: $packageSha256)"
    } else {
        Write-SynapseLog -LogPath $LogPath -Level Info -Message "SkipArchive specified; manifest and checksums written without a zip archive."
    }

    Set-SynapsePipelineOutput -Name 'packageVersion' -Value $Version
    Set-SynapsePipelineOutput -Name 'packagePath' -Value $packagePath
    Set-SynapsePipelineOutput -Name 'packageSha256' -Value ([string]$packageSha256)

    $result = [PSCustomObject]@{
        PackagePath     = $packagePath
        ManifestPath    = $manifestPath
        ChecksumsPath   = $checksumsPath
        PackageSha256   = $packageSha256
        FileCount       = $entries.Count
        TotalSizeBytes  = $totalSize
        Version         = $Version
        Simulated       = $false
    }
    $result
    exit (Get-SynapseExitCode -Name Success)
} catch {
    Write-SynapseLog -LogPath $LogPath -Level Error -Message "Release packaging failed: $($_.Exception.Message)"
    exit (Get-SynapseExitCode -Name ExecutionFailed)
}
