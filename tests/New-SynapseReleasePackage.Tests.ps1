#requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for scripts/New-SynapseReleasePackage.ps1.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'TestHelpers.psm1') -Force

Describe 'New-SynapseReleasePackage.ps1' {
    $sandbox = New-TestSandbox
    $srcDir = Join-Path $sandbox 'src'
    New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
    'print("hi")' | Set-Content -LiteralPath (Join-Path $srcDir 'notebook.py')
    $outDir = Join-Path $sandbox 'release'

    It 'dry-run reports planned package without writing any files' {
        $result = Invoke-ScriptUnderTest -ScriptName 'New-SynapseReleasePackage.ps1' -Parameters @{
            SourcePaths     = @($srcDir)
            OutputDirectory = $outDir
            Version         = '1.0.0'
            DryRun          = $true
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match 'Simulated\s*:\s*True'
        (Test-Path -LiteralPath $outDir) | Should Be $false
    }

    It 'creates manifest, checksums, and a zip archive for real' {
        $result = Invoke-ScriptUnderTest -ScriptName 'New-SynapseReleasePackage.ps1' -Parameters @{
            SourcePaths     = @($srcDir)
            OutputDirectory = $outDir
            Version         = '1.0.0'
        }
        $result.ExitCode | Should Be 0
        (Join-Path $outDir 'synapse-release-1.0.0.manifest.json') | Should Exist
        (Join-Path $outDir 'synapse-release-1.0.0.checksums.sha256') | Should Exist
        (Join-Path $outDir 'synapse-release-1.0.0.zip') | Should Exist
    }

    It 'the manifest checksum verifies successfully against the produced zip contents directory' {
        $manifestPath = Join-Path $outDir 'synapse-release-1.0.0.manifest.json'
        $validationResult = Invoke-ScriptUnderTest -ScriptName 'Test-SynapseRepository.ps1' -Parameters @{
            ArtifactManifestPath = $manifestPath
            ArtifactBasePath     = $srcDir
            Offline              = $true
        }
        $validationResult.ExitCode | Should Be 0
    }

    It 'fails explicitly when a source path does not exist' {
        $result = Invoke-ScriptUnderTest -ScriptName 'New-SynapseReleasePackage.ps1' -Parameters @{
            SourcePaths     = @((Join-Path $sandbox 'no-such-dir'))
            OutputDirectory = (Join-Path $sandbox 'release2')
            Version         = '1.0.0'
        }
        $result.ExitCode | Should Be 3
        (Test-Path -LiteralPath (Join-Path $sandbox 'release2')) | Should Be $false
    }

    Remove-TestSandbox -Path $sandbox
}
