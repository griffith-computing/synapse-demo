#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunnerResourceGroup,
    [Parameter(Mandatory)][string]$EnvironmentResourceGroup,
    [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$WorkspaceName,
    [string]$SharedDeploymentName = 'shared-runner',
    [string]$TemplateFile = (Join-Path $PSScriptRoot '..\infra\runner\connectivity.bicep')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RunnerResourceGroup)) { throw 'RUNNER_RESOURCE_GROUP must reference the bootstrapped shared resource group.' }

$json = az deployment group show --resource-group $RunnerResourceGroup --name $SharedDeploymentName --query properties.outputs --output json
if ($LASTEXITCODE -ne 0) { throw "Shared deployment '$SharedDeploymentName' is unavailable. Run Deploy shared runner first." }
$shared = $json | ConvertFrom-Json
$json = az synapse workspace show --resource-group $EnvironmentResourceGroup --name $WorkspaceName --output json
if ($LASTEXITCODE -ne 0) { throw "Cannot resolve workspace '$WorkspaceName' for private connectivity." }
$workspace = $json | ConvertFrom-Json
if (-not $workspace.defaultDataLakeStorage.resourceId) { throw 'Workspace default data lake resource ID is missing.' }

$parameters = @{
    environmentName = @{ value = $EnvironmentName }
    storageAccountId = @{ value = $workspace.defaultDataLakeStorage.resourceId }
    synapseWorkspaceId = @{ value = $workspace.id }
    privateEndpointSubnetId = @{ value = $shared.privateEndpointSubnetId.value }
    privateDnsZoneIds = @{ value = $shared.privateDnsZoneIds.value }
}
$parameterFile = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid()).parameters.json"
try {
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $parameterFile -Encoding utf8
    az deployment group create --resource-group $RunnerResourceGroup --name "connectivity-$EnvironmentName" `
        --template-file $TemplateFile --parameters "@$parameterFile" --output none
    if ($LASTEXITCODE -ne 0) { throw "Private connectivity deployment failed for '$EnvironmentName'." }
} finally {
    if (Test-Path -LiteralPath $parameterFile) { Remove-Item -LiteralPath $parameterFile -Force }
}
