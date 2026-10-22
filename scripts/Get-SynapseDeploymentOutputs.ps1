#requires -Version 5.1
<#
.SYNOPSIS
    Resolves workspace and storage details from a successful infrastructure
    deployment and exports them as GitHub Actions or Azure DevOps outputs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$DeploymentName,

    [Parameter()]
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

Assert-SynapseDependency -Name 'az' | Out-Null
$arguments = @(
    'deployment', 'group', 'show',
    '--resource-group', $ResourceGroupName,
    '--name', $DeploymentName,
    '--query', 'properties',
    '--output', 'json'
)
if ($SubscriptionId) { $arguments += @('--subscription', $SubscriptionId) }
$json = az @arguments
if ($LASTEXITCODE -ne 0 -or -not $json) {
    throw "Cannot read infrastructure deployment '$DeploymentName' in '$ResourceGroupName'. Deploy infrastructure before resolving workspace details."
}
$deployment = $json | ConvertFrom-Json
if ($deployment.provisioningState -ne 'Succeeded') {
    throw "Infrastructure deployment '$DeploymentName' has not succeeded (state: $($deployment.provisioningState))."
}

$outputs = @{}
foreach ($name in @('synapseWorkspaceName', 'storageAccountName', 'storageAccountDfsEndpoint', 'synapseWebEndpoint')) {
    $output = $deployment.outputs.PSObject.Properties[$name]
    if (-not $output -or [string]::IsNullOrWhiteSpace([string]$output.Value.value)) {
        throw "Infrastructure deployment '$DeploymentName' is missing required output '$name'. Redeploy infra/main.bicep."
    }
    $outputs[$name] = [string]$output.Value.value
}
foreach ($name in $outputs.Keys) {
    Set-SynapsePipelineOutput -Name $name -Value $outputs[$name]
}
[PSCustomObject]$outputs
