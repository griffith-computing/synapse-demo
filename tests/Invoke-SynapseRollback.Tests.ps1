#requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for scripts/Invoke-SynapseRollback.ps1.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'TestHelpers.psm1') -Force

function New-FakeReleasePackage {
    param(
        [string]$Directory,
        [string]$Version,
        [string]$CreatedUtc,
        [switch]$Tamper,
        [switch]$OmitFile
    )
    $fileName = "asset-$Version.txt"
    $filePath = Join-Path $Directory $fileName
    "content-$Version" | Set-Content -LiteralPath $filePath -NoNewline
    $hash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
    if ($Tamper) {
        "tampered-$Version" | Set-Content -LiteralPath $filePath -NoNewline
    }
    if ($OmitFile) {
        Remove-Item -LiteralPath $filePath -Force
    }
    $manifest = [PSCustomObject]@{
        PackageName = 'synapse-release'
        Version     = $Version
        CreatedUtc  = $CreatedUtc
        GitCommit   = $null
        FileCount   = 1
        TotalBytes  = 10
        Files       = @([PSCustomObject]@{ RelativePath = $fileName; Sha256 = $hash; SizeBytes = 10 })
    }
    $manifestPath = Join-Path $Directory "synapse-release-$Version.manifest.json"
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath
}

Describe 'Invoke-SynapseRollback.ps1' {
    $sandbox = New-TestSandbox
    New-FakeReleasePackage -Directory $sandbox -Version '1.0.0' -CreatedUtc '2024-01-01T00:00:00.0000000Z'
    New-FakeReleasePackage -Directory $sandbox -Version '1.1.0' -CreatedUtc '2024-02-01T00:00:00.0000000Z'
    New-FakeReleasePackage -Directory $sandbox -Version '1.2.0-broken' -CreatedUtc '2024-03-01T00:00:00.0000000Z' -Tamper

    It 'selects the newest candidate by CreatedUtc when no filters are given' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseRollback.ps1' -Parameters @{
            PackageDirectory = $sandbox
            ExcludeVersions  = @('1.2.0-broken')
            DryRun           = $true
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match "SelectedVersion\s*:\s*1\.1\.0"
    }

    It 'selects an exact -TargetVersion match when requested' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseRollback.ps1' -Parameters @{
            PackageDirectory = $sandbox
            TargetVersion    = '1.0.0'
            DryRun           = $true
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match "SelectedVersion\s*:\s*1\.0\.0"
    }

    It 'verifies a package manifest against a separate extraction root' {
        $packageDir = Join-Path $sandbox 'separate-package'
        $extractedDir = Join-Path $sandbox 'separate-extracted'
        New-Item -ItemType Directory -Path $packageDir, $extractedDir -Force | Out-Null
        New-FakeReleasePackage -Directory $packageDir -Version '2.0.0' -CreatedUtc '2024-04-01T00:00:00.0000000Z'
        Move-Item -LiteralPath (Join-Path $packageDir 'asset-2.0.0.txt') -Destination $extractedDir

        $result = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseRollback.ps1' -Parameters @{
            PackageDirectory = $packageDir
            ArtifactBasePath = $extractedDir
            TargetVersion    = '2.0.0'
            DryRun           = $true
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match "ChecksumsVerified\s*:\s*True"
    }

    It 'fails explicitly (RollbackFailed) when the newest candidate has a checksum mismatch' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseRollback.ps1' -Parameters @{
            PackageDirectory = $sandbox
            TargetVersion    = '1.2.0-broken'
            DryRun           = $true
        }
        $result.ExitCode | Should Be 4
        $result.StdOut | Should Match "ChecksumsVerified\s*:\s*False"
    }

    It 'fails explicitly when the requested TargetVersion does not exist' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseRollback.ps1' -Parameters @{
            PackageDirectory = $sandbox
            TargetVersion    = '9.9.9-does-not-exist'
            DryRun           = $true
        }
        $result.ExitCode | Should Be 3
        $result.StdOut | Should Match 'was not found among eligible candidates'
    }

    It 'fails explicitly when PackageDirectory has no manifests' {
        $emptyDir = Join-Path $sandbox 'empty-package-dir'
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        $result = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseRollback.ps1' -Parameters @{
            PackageDirectory = $emptyDir
            DryRun           = $true
        }
        $result.ExitCode | Should Be 3
        $result.StdOut | Should Match 'No release manifests'
    }

    It 'fails explicitly when every eligible candidate is excluded' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseRollback.ps1' -Parameters @{
            PackageDirectory = $sandbox
            ExcludeVersions  = @('1.0.0', '1.1.0', '1.2.0-broken')
            DryRun           = $true
        }
        $result.ExitCode | Should Be 3
        $result.StdOut | Should Match 'No eligible rollback candidate remains'
    }

    Remove-TestSandbox -Path $sandbox
}
