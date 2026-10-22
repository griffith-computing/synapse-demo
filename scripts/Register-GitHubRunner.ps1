#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$')][string]$Repository,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$RunnerName,
    [Parameter(Mandatory)][string]$RegistrationToken,
    [string]$RunnerDirectory = 'C:\actions-runner'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$configurationPath = Join-Path $RunnerDirectory '.runner'
$servicePath = Join-Path $RunnerDirectory '.service'
if (Test-Path -LiteralPath $configurationPath) {
    $configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
    if ($configuration.agentName -ne $RunnerName -or $configuration.gitHubUrl.TrimEnd('/') -ne "https://github.com/$Repository") {
        throw 'Existing runner registration belongs to a different runner/repository. Remove it explicitly before re-registering.'
    }
    if (-not (Test-Path -LiteralPath $servicePath)) { throw 'Runner is registered without a Windows service. Repair or remove the registration before retrying.' }
    $serviceName = (Get-Content -LiteralPath $servicePath -Raw).Trim()
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName" -Name Environment `
        -PropertyType MultiString -Value @(
            "PATH=$([Environment]::GetEnvironmentVariable('Path', 'Machine'))"
            'AZURE_BICEP_USE_BINARY_FROM_PATH=true'
        ) -Force | Out-Null
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    if ($service.Status -ne 'Running') { Start-Service -Name $serviceName }
    Write-Host "Existing runner '$RunnerName' service is running."
    return
}

$config = Join-Path $RunnerDirectory 'config.cmd'
if (-not (Test-Path -LiteralPath $config)) { throw 'Runner prerequisites are missing. Run Initialize-GitHubRunner.ps1 first.' }
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
# The service account must be able to update the runner and write job workspaces.
& icacls.exe $RunnerDirectory /grant '*S-1-5-20:(OI)(CI)M' /T /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to grant Network Service access to the runner directory.' }
Push-Location $RunnerDirectory
try {
    $output = & $config --unattended --url "https://github.com/$Repository" --token $RegistrationToken `
        --name $RunnerName --work '_work' --labels 'synapse-private' `
        --runasservice --windowslogonaccount 'NT AUTHORITY\NETWORK SERVICE' 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) { Write-Host ([string]$line).Replace($RegistrationToken, '[REDACTED]') }
    if ($exitCode -ne 0) { throw "Runner registration failed with exit code $exitCode." }
} finally {
    Pop-Location
    $RegistrationToken = $null
}
if (-not (Test-Path -LiteralPath $servicePath)) { throw 'Registration did not create the runner Windows service.' }
$serviceName = (Get-Content -LiteralPath $servicePath -Raw).Trim()
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName" -Name Environment `
    -PropertyType MultiString -Value @(
        "PATH=$([Environment]::GetEnvironmentVariable('Path', 'Machine'))"
        'AZURE_BICEP_USE_BINARY_FROM_PATH=true'
    ) -Force | Out-Null
Restart-Service -Name $serviceName
$service = Get-Service -Name $serviceName
$service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
Write-Host "Runner '$RunnerName' Windows service is running."
