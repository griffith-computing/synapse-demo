#requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for scripts/Test-SynapseRepository.ps1.
.NOTES
    Invokes the script as a child process (it calls `exit`), matching how
    GitHub Actions / Azure DevOps would run it.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'TestHelpers.psm1') -Force

Describe 'Test-SynapseRepository.ps1' {
    $sandbox = New-TestSandbox
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'present') -Force | Out-Null
    '{"key":"value"}' | Set-Content -LiteralPath (Join-Path $sandbox 'valid.json')
    'not json {' | Set-Content -LiteralPath (Join-Path $sandbox 'invalid.json')
    "key: value`npassword: hunter2`n" | Set-Content -LiteralPath (Join-Path $sandbox 'secretish.yml')

    It 'passes when required paths and config files are valid (offline)' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Test-SynapseRepository.ps1' -Parameters @{
            RepositoryRoot = $sandbox
            RequiredPaths  = @('present')
            ConfigFiles    = @('valid.json')
            Offline        = $true
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match 'Validation PASSED'
    }

    It 'fails explicitly when a required path is missing' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Test-SynapseRepository.ps1' -Parameters @{
            RepositoryRoot = $sandbox
            RequiredPaths  = @('does-not-exist')
            Offline        = $true
        }
        $result.ExitCode | Should Be 1
        $result.StdOut | Should Match 'Required path missing'
    }

    It 'fails when a config file is not valid JSON' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Test-SynapseRepository.ps1' -Parameters @{
            RepositoryRoot = $sandbox
            ConfigFiles    = @('invalid.json')
            Offline        = $true
        }
        $result.ExitCode | Should Be 1
        $result.StdOut | Should Match 'not valid JSON'
    }

    It 'warns (but does not fail by default) on a plaintext-looking secret in config' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Test-SynapseRepository.ps1' -Parameters @{
            RepositoryRoot = $sandbox
            ConfigFiles    = @('secretish.yml')
            Offline        = $true
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match 'Possible hard-coded secret'
        $result.StdOut | Should Not Match 'hunter2'
    }

    It 'fails on the same plaintext secret when -FailOnConfigWarning is set' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Test-SynapseRepository.ps1' -Parameters @{
            RepositoryRoot      = $sandbox
            ConfigFiles         = @('secretish.yml')
            Offline             = $true
            FailOnConfigWarning = $true
        }
        $result.ExitCode | Should Be 1
    }

    It 'skips (does not fake-pass) an optional Azure resource group check when offline' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Test-SynapseRepository.ps1' -Parameters @{
            RepositoryRoot          = $sandbox
            Offline                 = $true
            VerifyAzureResourceGroup = 'rg-does-not-matter'
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match 'Skipping live Azure resource group check'
    }

    It 'fails explicitly when RepositoryRoot does not exist' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Test-SynapseRepository.ps1' -Parameters @{
            RepositoryRoot = (Join-Path $sandbox 'nope-not-real')
            Offline        = $true
        }
        $result.ExitCode | Should Be 3
    }

    Remove-TestSandbox -Path $sandbox
}
