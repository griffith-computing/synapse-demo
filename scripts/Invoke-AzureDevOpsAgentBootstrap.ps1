#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^https://(dev\.azure\.com/[a-zA-Z0-9_-]+|[a-zA-Z0-9_-]+\.visualstudio\.com)/?$')][string]$OrganizationUrl,
    [Parameter(Mandatory)][string]$PoolName,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [ValidateSet('JobToken', 'PAT')][string]$RegistrationAuth = 'JobToken',
    [string]$Location = 'westus3',
    [string]$VmSize = 'Standard_B2as_v2',
    [string]$AdminUsername = 'runneradmin',
    [string]$VnetAddressPrefix = '10.42.0.0/16',
    [string]$BastionSubnetPrefix = '10.42.0.0/26',
    [string]$RunnerSubnetPrefix = '10.42.1.0/24',
    [string]$EndpointSubnetPrefix = '10.42.2.0/24'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$token = if ($RegistrationAuth -eq 'JobToken') { $env:ADO_JOB_TOKEN } else { $env:ADO_AGENT_PAT }
foreach ($setting in @{ PoolName = $PoolName; ResourceGroupName = $ResourceGroupName; RegistrationCredential = $token; RUNNER_ADMIN_PASSWORD = $env:RUNNER_ADMIN_PASSWORD }.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($setting.Value) -or $setting.Value -match '^\$\(') {
        throw "Missing bootstrap setting '$($setting.Key)'. See docs/deployment-runbook.md."
    }
}
$headers = if ($RegistrationAuth -eq 'JobToken') {
    @{ Authorization = "Bearer $token" }
} else {
    @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$token")) }
}
$baseUrl = $OrganizationUrl.TrimEnd('/')
$pools = Invoke-RestMethod -Uri "$baseUrl/_apis/distributedtask/pools?poolName=$([uri]::EscapeDataString($PoolName))&api-version=7.1" -Headers $headers
$pool = @($pools.value | Where-Object name -EQ $PoolName)
if ($pool.Count -ne 1) { throw "Pool '$PoolName' must exist and be accessible to the selected registration identity." }
$poolId = $pool[0].id
function Wait-IdleAgentPool {
    $idleDeadline = [DateTime]::UtcNow.AddMinutes(15)
    do {
        $poolAgents = Invoke-RestMethod -Uri "$baseUrl/_apis/distributedtask/pools/$poolId/agents?includeAssignedRequest=true&api-version=7.1" -Headers $headers
        if (@($poolAgents.value | Where-Object { $_.PSObject.Properties['assignedRequest'] -and $_.assignedRequest }).Count -eq 0) { return }
        Write-Host "Waiting for assigned work in pool '$PoolName' before bootstrap."
        Start-Sleep -Seconds 10
    } while ([DateTime]::UtcNow -lt $idleDeadline)
    throw "Pool '$PoolName' is still busy. Drain it before bootstrapping."
}
Wait-IdleAgentPool
function Get-LatestOfficialWindowsAgentPackage {
    # The public release page avoids the anonymous GitHub API quota shared by hosted agents.
    $release = Invoke-WebRequest -Uri 'https://github.com/microsoft/azure-pipelines-agent/releases/latest' -TimeoutSec 60
    $windowsRows = @([regex]::Matches($release.Content, '(?s)<tr\b[^>]*>.*?</tr>') |
        ForEach-Object { $_.Value } |
        Where-Object { $_ -match '(?s)^<tr\b[^>]*>\s*<td>\s*Windows x64\s*</td>\s*<td>\s*<a\b[^>]*>\s*vsts-agent-win-x64-' })
    if ($windowsRows.Count -ne 1) {
        throw 'Microsoft agent release metadata did not contain one standard Windows x64 package row.'
    }
    $match = [regex]::Match(
        $windowsRows[0],
        '(?s)^<tr\b[^>]*>\s*<td>\s*Windows x64\s*</td>\s*<td>\s*<a\s+href="https://download\.agent\.dev\.azure\.com/agent/(?<urlVersion>\d+(?:\.\d+)+)/(?<urlFile>vsts-agent-win-x64-[0-9.]+\.zip)"(?:\s+rel="nofollow")?\s*>\s*(?<file>vsts-agent-win-x64-(?<version>\d+(?:\.\d+)+)\.zip)\s*</a>\s*</td>\s*<td>\s*(?<hash>[a-fA-F0-9]{64})\s*</td>\s*</tr>$'
    )
    if (-not $match.Success -or
        $match.Groups['version'].Value -ne $match.Groups['urlVersion'].Value -or
        $match.Groups['file'].Value -ne $match.Groups['urlFile'].Value) {
        throw 'Microsoft agent release metadata did not contain a valid Windows x64 download URL and SHA256.'
    }
    return [pscustomobject]@{
        downloadUrl = "https://download.agent.dev.azure.com/agent/$($match.Groups['urlVersion'].Value)/$($match.Groups['urlFile'].Value)"
        hashValue = $match.Groups['hash'].Value
    }
}

$package = $null
try {
    $packages = Invoke-RestMethod -Uri "$baseUrl/_apis/distributedtask/packages/agent?platform=win-x64&`$top=1&api-version=7.1-preview.1" -Headers $headers
    $package = @($packages.value)
} catch {
    $lookupError = $_.Exception.Message
    if ($_.ErrorDetails) { $lookupError += " $($_.ErrorDetails.Message)" }
    if ($lookupError -notmatch 'PackageNotFoundException|A package with the type agent could not be found') { throw }
    Write-Warning 'Azure DevOps did not return agent package metadata; using the official Microsoft agent release metadata.'
    try {
        $package = @(Get-LatestOfficialWindowsAgentPackage)
    } catch {
        throw "Azure DevOps agent package lookup failed, and the official Microsoft release fallback failed: $($_.Exception.Message)"
    }
}
if ($package.Count -ne 1) { throw 'Azure DevOps returned no unique Windows x64 agent package.' }
$packageHash = $package[0].hashValue -replace '-', ''
if ($packageHash -notmatch '^[a-fA-F0-9]{64}$') {
    throw 'Azure DevOps returned no unique Windows x64 agent package with a SHA256 hash.'
}

& (Join-Path $PSScriptRoot 'Deploy-SharedRunner.ps1') -ResourceGroupName $ResourceGroupName -Location $Location `
    -VmSize $VmSize -AdminUsername $AdminUsername -VnetAddressPrefix $VnetAddressPrefix `
    -BastionSubnetPrefix $BastionSubnetPrefix -RunnerSubnetPrefix $RunnerSubnetPrefix -EndpointSubnetPrefix $EndpointSubnetPrefix
$json = az deployment group show -g $ResourceGroupName -n shared-runner --query properties.outputs -o json
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve shared agent deployment.' }
$outputs = $json | ConvertFrom-Json
$agentName = $outputs.vmName.value
$agentUri = "$baseUrl/_apis/distributedtask/pools/$poolId/agents?agentName=$([uri]::EscapeDataString($agentName))&includeCapabilities=true&includeAssignedRequest=true&api-version=7.1"
Wait-IdleAgentPool
$command = @{
    VmResourceId = $outputs.vmResourceId.value
    Location = $outputs.location.value
}
$run = "$env:BUILD_BUILDID-$env:SYSTEM_JOBATTEMPT"
& (Join-Path $PSScriptRoot 'Invoke-RunnerManagedCommand.ps1') @command -Name "prerequisites-$run" `
    -ScriptPath (Join-Path $PSScriptRoot 'Initialize-GitHubRunner.ps1') -Parameters @{ RunnerInstall = 'None' }
& (Join-Path $PSScriptRoot 'Invoke-RunnerManagedCommand.ps1') @command -Name "agent-install-$run" `
    -ScriptPath (Join-Path $PSScriptRoot 'Initialize-AzureDevOpsAgent.ps1') `
    -Parameters @{ DownloadUrl = $package[0].downloadUrl; Sha256 = $packageHash }
& (Join-Path $PSScriptRoot 'Invoke-RunnerManagedCommand.ps1') @command -Name "agent-register-$run" `
    -ScriptPath (Join-Path $PSScriptRoot 'Register-AzureDevOpsAgent.ps1') `
    -Parameters @{ OrganizationUrl = $OrganizationUrl; PoolName = $PoolName; PoolId = $poolId; AgentName = $agentName } `
    -ProtectedParameters @{ RegistrationToken = $token } -TimeoutSeconds 600
$deadline = [DateTime]::UtcNow.AddMinutes(3)
do {
    $agents = Invoke-RestMethod -Uri $agentUri -Headers $headers
    $agent = @($agents.value | Where-Object name -EQ $agentName)
    if ($agent.Count -eq 1 -and $agent[0].enabled -and $agent[0].status -eq 'online') {
        $capabilities = $agent[0].systemCapabilities
        $ready = $null -ne $capabilities
        foreach ($required in @{ 'Agent.OS' = 'Windows_NT'; 'Agent.OSArchitecture' = 'X64'; SYNAPSE_PRIVATE_AGENT = 'true' }.GetEnumerator()) {
            if (-not $ready) { break }
            $property = $capabilities.PSObject.Properties[$required.Key]
            if (-not $property -or $property.Value -ne $required.Value) { $ready = $false }
        }
        if ($ready) {
            Write-Host "Agent '$agentName' is online with the required private Windows capabilities."
            return
        }
    }
    Start-Sleep -Seconds 10
} while ([DateTime]::UtcNow -lt $deadline)
throw "Agent '$agentName' did not become available with the required capabilities."
