#requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for scripts/Invoke-SynapseSmokeTests.ps1.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'TestHelpers.psm1') -Force

Describe 'Invoke-SynapseSmokeTests.ps1' {
    $sandbox = New-TestSandbox
    $defsFile = Join-Path $sandbox 'smoke-tests.json'
    @'
[
  { "Name": "ReadOnlyCheck", "Type": "AzCommand", "Command": ["synapse","pipeline","show"], "Mutating": false },
  { "Name": "MutatingCheck", "Type": "AzCommand", "Command": ["synapse","pipeline","create-run"], "Mutating": true },
  { "Name": "HttpCheck", "Type": "HttpCheck", "Url": "https://example.invalid/health", "Mutating": false }
]
'@ | Set-Content -LiteralPath $defsFile

    It 'offline mode skips all tests (mutating and non-mutating) without faking pass/fail' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseSmokeTests.ps1' -Parameters @{
            TestDefinitionsPath = $defsFile
            Offline             = $true
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match 'Skipped\s*:\s*3'
        $result.StdOut | Should Match 'Passed\s*:\s*0'
        $result.StdOut | Should Match 'Failed\s*:\s*0'
    }

    It 'fails explicitly when the test definitions file does not exist' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseSmokeTests.ps1' -Parameters @{
            TestDefinitionsPath = (Join-Path $sandbox 'no-such-file.json')
            Offline             = $true
        }
        $result.ExitCode | Should Be 3
        $result.StdOut | Should Match 'TestDefinitionsPath not found'
    }

    It 'fails explicitly when the test definitions file is empty array' {
        $emptyFile = Join-Path $sandbox 'empty.json'
        '[]' | Set-Content -LiteralPath $emptyFile
        $result = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseSmokeTests.ps1' -Parameters @{
            TestDefinitionsPath = $emptyFile
            Offline             = $true
        }
        $result.ExitCode | Should Be 3
        $result.StdOut | Should Match 'No smoke test definitions found'
    }

    It 'writes a JSON results summary when -OutputJsonPath is supplied' {
        $outJson = Join-Path $sandbox 'results.json'
        $result = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseSmokeTests.ps1' -Parameters @{
            TestDefinitionsPath = $defsFile
            Offline             = $true
            OutputJsonPath      = $outJson
        }
        $result.ExitCode | Should Be 0
        $outJson | Should Exist
        $parsed = Get-Content -LiteralPath $outJson -Raw | ConvertFrom-Json
        $parsed.TotalTests | Should Be 3
        $parsed.IsSuccess | Should Be $true
    }

    It 'a single JSON test object (not wrapped in an array) is still accepted' {
        $singleFile = Join-Path $sandbox 'single.json'
        '{ "Name": "Solo", "Type": "AzCommand", "Command": ["synapse","workspace","show"] }' | Set-Content -LiteralPath $singleFile
        $result = Invoke-ScriptUnderTest -ScriptName 'Invoke-SynapseSmokeTests.ps1' -Parameters @{
            TestDefinitionsPath = $singleFile
            Offline             = $true
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match 'TotalTests\s*:\s*1'
    }

    Remove-TestSandbox -Path $sandbox
}
