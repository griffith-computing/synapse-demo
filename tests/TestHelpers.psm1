#requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers for the tests/ suite (used by both Pester specs and the
    no-dependency runner).

.DESCRIPTION
    The scripts under scripts/ call `exit <code>` on completion, which is
    appropriate for CI steps but would terminate the host process if a
    script were dot-sourced directly inside a test process. All tests
    therefore invoke scripts as child `powershell.exe -File` processes and
    assert on exit code + JSON/output, exactly as GitHub Actions / Azure
    DevOps would.
#>
Set-StrictMode -Version Latest

$Script:RepoRoot = Split-Path -Parent $PSScriptRoot
$Script:ScriptsDir = Join-Path $Script:RepoRoot 'scripts'

function Get-TestScriptsDir {
    return $Script:ScriptsDir
}

function Get-TestRepoRoot {
    return $Script:RepoRoot
}

function Invoke-ScriptUnderTest {
    <#
        .SYNOPSIS
            Runs a scripts/*.ps1 file in a child PowerShell process and
            returns its exit code + captured stdout/stderr text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,

        [Parameter()]
        [hashtable]$Parameters = @{},

        [Parameter()]
        [string]$WorkingDirectory
    )

    $scriptPath = Join-Path $Script:ScriptsDir $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Script under test not found: $scriptPath"
    }

    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [switch] -or $value -is [bool]) {
            if ($value) { $argList += "-$key" }
        } elseif ($value -is [array]) {
            $argList += "-$key"
            # PowerShell's -File invocation (used by both GitHub Actions and
            # Azure DevOps script steps) does not parse space-separated
            # command-line tokens into an array parameter; scripts under
            # test normalize a single comma-separated token via
            # ConvertTo-SynapseStringArray, so tests must send arrays the
            # same way real CI callers would.
            $argList += ($value -join ',')
        } else {
            $argList += "-$key"
            $argList += [string]$value
        }
    }

    $stdOutFile = [System.IO.Path]::GetTempFileName()
    $stdErrFile = [System.IO.Path]::GetTempFileName()
    try {
        $procParams = @{
            FilePath               = 'powershell.exe'
            ArgumentList           = $argList
            NoNewWindow            = $true
            Wait                   = $true
            PassThru               = $true
            RedirectStandardOutput = $stdOutFile
            RedirectStandardError  = $stdErrFile
        }
        if ($WorkingDirectory) { $procParams['WorkingDirectory'] = $WorkingDirectory }

        $process = Start-Process @procParams
        $stdOut = Get-Content -LiteralPath $stdOutFile -Raw -ErrorAction SilentlyContinue
        $stdErr = Get-Content -LiteralPath $stdErrFile -Raw -ErrorAction SilentlyContinue

        return [PSCustomObject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdOut
            StdErr   = $stdErr
        }
    } finally {
        Remove-Item -LiteralPath $stdOutFile, $stdErrFile -ErrorAction SilentlyContinue
    }
}

function New-TestSandbox {
    <#
        .SYNOPSIS
            Creates a unique temp directory for a test to use, returning its
            path. Caller is responsible for removing it (or call
            Remove-TestSandbox).
    #>
    [CmdletBinding()]
    param()
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("synapse-scripts-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-TestSandbox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @(
    'Get-TestScriptsDir'
    'Get-TestRepoRoot'
    'Invoke-ScriptUnderTest'
    'New-TestSandbox'
    'Remove-TestSandbox'
)
