#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [Parameter(Mandatory)][string]$DestinationDirectory,
    [Parameter(Mandatory)][string]$ExpectedVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ExpectedVersion) -or $ExpectedVersion -match '^\$\[') {
    throw 'An explicit resolved package version is required.'
}
$zip = @(Get-ChildItem -LiteralPath $PackageDirectory -Filter '*.zip' -File)
$manifest = @(Get-ChildItem -LiteralPath $PackageDirectory -Filter '*.manifest.json' -File)
if ($zip.Count -ne 1 -or $manifest.Count -ne 1) { throw 'Expected exactly one zip and one manifest in the downloaded package.' }
$actualVersion = (Get-Content -LiteralPath $manifest[0].FullName -Raw | ConvertFrom-Json).Version
if ($actualVersion -ne $ExpectedVersion) { throw "Package version '$actualVersion' does not match expected version '$ExpectedVersion'." }
if (Test-Path -LiteralPath $DestinationDirectory) { throw 'Package extraction directory already exists; refusing to mix releases.' }
Expand-Archive -LiteralPath $zip[0].FullName -DestinationPath $DestinationDirectory
Set-SynapsePipelineOutput -Name manifestPath -Value $manifest[0].FullName
