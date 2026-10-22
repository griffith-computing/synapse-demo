#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$Location = 'westus3',
    [string]$VmSize = 'Standard_B2as_v2',
    [string]$AdminUsername = 'runneradmin',
    [string]$TemplateFile = (Join-Path $PSScriptRoot '..\infra\runner\main.bicep'),
    [string]$VnetAddressPrefix = '10.42.0.0/16',
    [string]$BastionSubnetPrefix = '10.42.0.0/26',
    [string]$RunnerSubnetPrefix = '10.42.1.0/24',
    [string]$EndpointSubnetPrefix = '10.42.2.0/24'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($env:RUNNER_ADMIN_PASSWORD)) { throw 'RUNNER_ADMIN_PASSWORD must be supplied through the process environment.' }
az group show --name $ResourceGroupName --output none
if ($LASTEXITCODE -ne 0) { throw "Shared resource group '$ResourceGroupName' must already exist." }
$json = az vm list-skus --location $Location --resource-type virtualMachines --all --output json
if ($LASTEXITCODE -ne 0) { throw 'Unable to check VM SKU availability.' }
$skus = @($json | ConvertFrom-Json | Where-Object name -EQ $VmSize)
if ($skus.Count -ne 1 -or @($skus[0].restrictions).Count -ne 0) { throw "VM SKU '$VmSize' is unavailable or restricted in '$Location'." }
$sku = $skus[0]
$cores = [int]($sku.capabilities | Where-Object name -EQ 'vCPUs').value
$json = az vm list --resource-group $ResourceGroupName --output json
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect existing shared VMs.' }
$existing = @($json | ConvertFrom-Json | Where-Object {
    $_.tags -and $_.tags.PSObject.Properties['workload'] -and
    $_.tags.workload -eq 'synapse-shared-runner' -and $_.hardwareProfile.vmSize -eq $VmSize
})
$additionalCores = if ($existing.Count -eq 1) { 0 } else { $cores }
$json = az vm list-usage --location $Location --output json
if ($LASTEXITCODE -ne 0) { throw 'Unable to check VM quota.' }
$usage = @($json | ConvertFrom-Json)
foreach ($quotaName in @('cores', $sku.family)) {
    $quota = @($usage | Where-Object { $_.name.value -eq $quotaName })
    if ($quota.Count -ne 1 -or ([int]$quota[0].limit - [int]$quota[0].currentValue) -lt $additionalCores) {
        throw "Insufficient or unknown quota for '$quotaName' in '$Location'."
    }
}
$parameters = @{
    location = @{ value = $Location }
    vmSize = @{ value = $VmSize }
    adminUsername = @{ value = $AdminUsername }
    adminPassword = @{ value = $env:RUNNER_ADMIN_PASSWORD }
    vnetAddressPrefix = @{ value = $VnetAddressPrefix }
    bastionSubnetPrefix = @{ value = $BastionSubnetPrefix }
    runnerSubnetPrefix = @{ value = $RunnerSubnetPrefix }
    endpointSubnetPrefix = @{ value = $EndpointSubnetPrefix }
}
$file = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid()).parameters.json"
try {
    [IO.File]::WriteAllText($file, '')
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode($file, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file -Encoding utf8
    az deployment group what-if --resource-group $ResourceGroupName --name shared-runner --template-file $TemplateFile --parameters "@$file"
    if ($LASTEXITCODE -ne 0) { throw 'Shared infrastructure what-if failed.' }
    az deployment group create --resource-group $ResourceGroupName --name shared-runner --template-file $TemplateFile --parameters "@$file" --output none
    if ($LASTEXITCODE -ne 0) { throw 'Shared infrastructure deployment failed.' }
} finally {
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}
