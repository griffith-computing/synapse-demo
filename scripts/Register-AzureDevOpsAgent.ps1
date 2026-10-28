#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^https://(dev\.azure\.com/[a-zA-Z0-9_-]+|[a-zA-Z0-9_-]+\.visualstudio\.com)/?$')][string]$OrganizationUrl,
    [Parameter(Mandatory)][string]$PoolName,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PoolId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$AgentName,
    [Parameter(Mandatory)][string]$RegistrationToken,
    [string]$AgentDirectory = 'C:\azagent'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RegistrationToken)) { throw 'Registration credential is empty.' }
$configurationPath = Join-Path $AgentDirectory '.agent'
$servicePath = Join-Path $AgentDirectory '.service'
if (Test-Path -LiteralPath $configurationPath) {
    $configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
    if ($configuration.agentName -ne $AgentName -or $configuration.poolId -ne $PoolId -or
        $configuration.serverUrl.TrimEnd('/') -ne $OrganizationUrl.TrimEnd('/')) {
        throw 'Existing agent belongs to a different organization, pool or name. Remove it explicitly before re-registering.'
    }
    if (-not (Test-Path -LiteralPath $servicePath)) { throw 'Agent has no Windows service. Repair registration before retrying.' }
    $service = Get-Service -Name (Get-Content -LiteralPath $servicePath -Raw).Trim() -ErrorAction Stop
    if ($service.Status -ne 'Running') { Start-Service -Name $service.Name }
    Write-Host "Existing agent '$AgentName' service is running."
    return
}
$config = Join-Path $AgentDirectory 'config.cmd'
if (-not (Test-Path -LiteralPath $config)) { throw 'Azure Pipelines agent installation is missing.' }
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
& icacls.exe $AgentDirectory /grant '*S-1-5-20:(OI)(CI)M' /T /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to grant Network Service access to the agent directory.' }
$savedToken = $env:VSTS_AGENT_INPUT_TOKEN
Push-Location $AgentDirectory
try {
    $env:VSTS_AGENT_INPUT_TOKEN = $RegistrationToken
    $output = & $config --unattended --url $OrganizationUrl --auth pat --pool $PoolName --agent $AgentName `
        --work '_work' --runAsService --windowsLogonAccount 'NT AUTHORITY\NETWORK SERVICE' 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) { Write-Host ([string]$line).Replace($RegistrationToken, '[REDACTED]') }
    if ($exitCode -ne 0) { throw "Agent registration failed with exit code $exitCode." }
} finally {
    Pop-Location
    $env:VSTS_AGENT_INPUT_TOKEN = $savedToken
    $RegistrationToken = $null
}
if (-not (Test-Path -LiteralPath $servicePath)) { throw 'Registration did not create an agent Windows service.' }
$serviceName = (Get-Content -LiteralPath $servicePath -Raw).Trim()
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName" -Name Environment `
    -PropertyType MultiString -Value @(
        "PATH=$([Environment]::GetEnvironmentVariable('Path', 'Machine'))"
        'AZURE_BICEP_USE_BINARY_FROM_PATH=true'
        'SYNAPSE_PRIVATE_AGENT=true'
    ) -Force | Out-Null
Restart-Service -Name $serviceName
$service = Get-Service -Name $serviceName -ErrorAction Stop
$service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
Write-Host "Azure Pipelines agent '$AgentName' service is running."
