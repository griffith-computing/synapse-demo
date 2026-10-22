#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VmResourceId,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$Name,
    [Parameter(Mandatory)][string]$ScriptPath,
    [hashtable]$Parameters = @{},
    [hashtable]$ProtectedParameters = @{},
    [ValidateRange(60, 7200)][int]$TimeoutSeconds = 3600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$body = @{
    location = $Location
    properties = @{
        source = @{ script = Get-Content -LiteralPath $ScriptPath -Raw }
        parameters = @($Parameters.GetEnumerator() | ForEach-Object {
            @{ name = $_.Key; value = [string]$_.Value }
        })
        protectedParameters = @($ProtectedParameters.GetEnumerator() | ForEach-Object {
            @{ name = $_.Key; value = [string]$_.Value }
        })
        asyncExecution = $false
        timeoutInSeconds = $TimeoutSeconds
        treatFailureAsDeploymentFailure = $true
    }
}
$uri = "https://management.azure.com$VmResourceId/runCommands/${Name}?api-version=2024-11-01"
$payload = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid()).json"
try {
    [IO.File]::WriteAllText($payload, '', [Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode($payload, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
    [IO.File]::WriteAllText($payload, ($body | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    az rest --method put --url $uri --body "@$payload" --output none
    if ($LASTEXITCODE -ne 0) { throw "Unable to start managed Run Command '$Name'." }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds + 300)
    do {
        $json = az rest --method get --url "$uri&`$expand=instanceView" --output json
        if ($LASTEXITCODE -ne 0) { throw "Unable to inspect managed Run Command '$Name'." }
        $command = $json | ConvertFrom-Json
        $view = $command.properties.PSObject.Properties['instanceView']
        $executionState = if ($view -and $view.Value -and $view.Value.PSObject.Properties['executionState']) {
            $view.Value.executionState
        } else { $null }
        if ($executionState -eq 'Succeeded') {
            if ($view.Value.exitCode -ne 0) { throw "Managed Run Command '$Name' returned exit code $($view.Value.exitCode)." }
            az rest --method delete --url $uri --output none
            if ($LASTEXITCODE -ne 0) { throw "Managed Run Command '$Name' succeeded but its resource could not be removed." }
            Write-Host "Managed Run Command '$Name' succeeded."
            return
        }
        if ($command.properties.provisioningState -eq 'Failed' -or
            $executionState -in @('Failed', 'TimedOut', 'Canceled')) {
            throw "Managed Run Command '$Name' failed. Inspect its instance view in Azure; do not print protected registration parameters."
        }
        Start-Sleep -Seconds 10
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for managed Run Command '$Name'."
} finally {
    if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload -Force }
}
