#requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for scripts/Common.psm1 shared helpers.
.NOTES
    Written against legacy Pester syntax (`Should Be`, not `Should -Be`) for
    maximum compatibility with the Windows-inbox Pester 3.4 module as well
    as newer Pester installs that retain the legacy assertion shim.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
Import-Module (Join-Path $repoRoot 'scripts\Common.psm1') -Force

Describe 'Common.psm1 - Protect-SynapseSecretText' {
    It 'redacts password= assignments' {
        $result = Protect-SynapseSecretText -Text 'foo password=hunter2 bar'
        $result | Should Not Match 'hunter2'
        $result | Should Match 'REDACTED'
    }

    It 'redacts AccountKey= connection string fragments' {
        $result = Protect-SynapseSecretText -Text 'DefaultEndpointsProtocol=https;AccountKey=abc123XYZ=='
        $result | Should Not Match 'abc123XYZ'
    }

    It 'redacts Bearer tokens' {
        $result = Protect-SynapseSecretText -Text 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.secretpayload'
        $result | Should Not Match 'eyJhbGciOiJIUzI1NiJ9'
    }

    It 'leaves ordinary text untouched' {
        $result = Protect-SynapseSecretText -Text 'Deployment to rg-synapse-dev succeeded'
        $result | Should Be 'Deployment to rg-synapse-dev succeeded'
    }

    It 'handles empty string without error' {
        { Protect-SynapseSecretText -Text '' } | Should Not Throw
    }
}

Describe 'Common.psm1 - Get-SynapseExitCode' {
    It 'returns 0 for Success' {
        Get-SynapseExitCode -Name Success | Should Be 0
    }
    It 'returns distinct non-zero codes for each failure category' {
        $codes = @(
            (Get-SynapseExitCode -Name ValidationFailed),
            (Get-SynapseExitCode -Name MissingDependency),
            (Get-SynapseExitCode -Name ExecutionFailed),
            (Get-SynapseExitCode -Name RollbackFailed),
            (Get-SynapseExitCode -Name InvalidArguments)
        )
        ($codes | Select-Object -Unique).Count | Should Be $codes.Count
        ($codes -contains 0) | Should Be $false
    }
}

Describe 'Common.psm1 - Test-SynapseCommandAvailable / Assert-SynapseDependency' {
    It 'returns true for a command that certainly exists (powershell.exe)' {
        Test-SynapseCommandAvailable -Name 'powershell.exe' | Should Be $true
    }
    It 'returns false for a bogus command name' {
        Test-SynapseCommandAvailable -Name 'this-tool-does-not-exist-xyz' | Should Be $false
    }
    It 'throws when a required dependency is missing and offline-skip was not requested' {
        { Assert-SynapseDependency -Name 'this-tool-does-not-exist-xyz' } | Should Throw
    }
    It 'returns false (not throw) when offline and AllowMissingWhenOffline is set' {
        $result = Assert-SynapseDependency -Name 'this-tool-does-not-exist-xyz' -Offline -AllowMissingWhenOffline
        $result | Should Be $false
    }
    It 'still throws offline when AllowMissingWhenOffline was not requested' {
        { Assert-SynapseDependency -Name 'this-tool-does-not-exist-xyz' -Offline } | Should Throw
    }
}

Describe 'Common.psm1 - manifest / checksum helpers' {
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("common-tests-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    'hello world' | Set-Content -LiteralPath (Join-Path $sandbox 'a.txt') -NoNewline

    It 'computes manifest entries with correct sha256' {
        $entries = @(Get-SynapseFileManifestEntries -Path $sandbox -BasePath $sandbox)
        $entries.Count | Should Be 1
        $entries[0].RelativePath | Should Be 'a.txt'
        $expectedHash = (Get-FileHash -LiteralPath (Join-Path $sandbox 'a.txt') -Algorithm SHA256).Hash
        $entries[0].Sha256 | Should Be $expectedHash
    }

    It 'Test-SynapseFileManifest reports valid when files match' {
        $entries = @(Get-SynapseFileManifestEntries -Path $sandbox -BasePath $sandbox)
        $manifest = [PSCustomObject]@{ Files = $entries }
        $manifestPath = Join-Path $sandbox 'manifest.json'
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath
        $result = Test-SynapseFileManifest -ManifestPath $manifestPath -BasePath $sandbox
        $result.IsValid | Should Be $true
    }

    It 'verifies slash-delimited nested paths on the current platform' {
        $nestedDir = Join-Path $sandbox 'nested'
        New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
        $nestedFile = Join-Path $nestedDir 'item.txt'
        'nested content' | Set-Content -LiteralPath $nestedFile -NoNewline
        $manifest = [PSCustomObject]@{
            Files = @([PSCustomObject]@{
                RelativePath = 'nested/item.txt'
                Sha256       = (Get-FileHash -LiteralPath $nestedFile -Algorithm SHA256).Hash
            })
        }
        $manifestPath = Join-Path $sandbox 'nested-manifest.json'
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath

        $result = Test-SynapseFileManifest -ManifestPath $manifestPath -BasePath $sandbox
        $result.IsValid | Should Be $true
    }

    It 'Test-SynapseFileManifest detects tampering' {
        $entries = @(Get-SynapseFileManifestEntries -Path $sandbox -BasePath $sandbox)
        $manifest = [PSCustomObject]@{ Files = $entries }
        $manifestPath = Join-Path $sandbox 'manifest2.json'
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath
        'tampered content' | Set-Content -LiteralPath (Join-Path $sandbox 'a.txt') -NoNewline
        $result = Test-SynapseFileManifest -ManifestPath $manifestPath -BasePath $sandbox
        $result.IsValid | Should Be $false
        $result.Mismatches.Count | Should Be 1
    }

    It 'Test-SynapseFileManifest detects missing files' {
        $missingDir = Join-Path $sandbox 'empty'
        New-Item -ItemType Directory -Path $missingDir -Force | Out-Null
        $entries = @(@(Get-SynapseFileManifestEntries -Path $sandbox -BasePath $sandbox) | Where-Object { $_.RelativePath -eq 'a.txt' })
        $manifest = [PSCustomObject]@{ Files = $entries }
        $manifestPath = Join-Path $sandbox 'manifest3.json'
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath
        $result = Test-SynapseFileManifest -ManifestPath $manifestPath -BasePath $missingDir
        $result.IsValid | Should Be $false
        $result.Missing.Count | Should Be 1
    }

    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Common.psm1 - Get-SynapsePipelineProvider' {
    It 'detects GitHub Actions via GITHUB_ACTIONS env var' {
        $old = $env:GITHUB_ACTIONS
        try {
            $env:GITHUB_ACTIONS = 'true'
            Get-SynapsePipelineProvider | Should Be 'GitHubActions'
        } finally {
            $env:GITHUB_ACTIONS = $old
        }
    }
    It 'detects Azure DevOps via TF_BUILD env var' {
        $oldGh = $env:GITHUB_ACTIONS
        $oldTf = $env:TF_BUILD
        try {
            $env:GITHUB_ACTIONS = $null
            $env:TF_BUILD = 'True'
            Get-SynapsePipelineProvider | Should Be 'AzureDevOps'
        } finally {
            $env:GITHUB_ACTIONS = $oldGh
            $env:TF_BUILD = $oldTf
        }
    }
    It 'falls back to Local when neither is set' {
        $oldGh = $env:GITHUB_ACTIONS
        $oldTf = $env:TF_BUILD
        try {
            $env:GITHUB_ACTIONS = $null
            $env:TF_BUILD = $null
            Get-SynapsePipelineProvider | Should Be 'Local'
        } finally {
            $env:GITHUB_ACTIONS = $oldGh
            $env:TF_BUILD = $oldTf
        }
    }
}
