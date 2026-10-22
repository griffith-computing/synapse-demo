#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$CompiledRunnerTemplate,
    [string]$CompiledConnectivityTemplate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $root 'scripts'
$count = 0
function Assert-RunnerTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:count++
}
function Assert-RunnerFailure {
    param([scriptblock]$Action, [string]$MessagePattern)
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    Assert-RunnerTest ($null -ne $failure -and $failure.ToString() -match $MessagePattern) "Expected failure matching '$MessagePattern', received '$failure'."
}

$global:RunnerTestCalls = [Collections.Generic.List[object]]::new()
$global:RunnerTestMode = 'success'
function global:az {
    $global:LASTEXITCODE = 0
    $arguments = @($args)
    $body = $null
    foreach ($argument in $arguments) {
        if ($argument -is [string] -and $argument.StartsWith('@')) {
            $body = Get-Content -LiteralPath $argument.Substring(1) -Raw | ConvertFrom-Json
        }
    }
    $global:RunnerTestCalls.Add(@{ Arguments = $arguments; Body = $body })
    $text = $arguments -join ' '
    if ($text -match '^vm list-skus') {
        if ($global:RunnerTestMode -eq 'restricted-sku') {
            return '[{"name":"Standard_B2as_v2","family":"standardBasv2Family","restrictions":[{"reasonCode":"NotAvailableForSubscription"}],"capabilities":[{"name":"vCPUs","value":"2"}]}]'
        }
        return '[{"name":"Standard_B2as_v2","family":"standardBasv2Family","restrictions":[],"capabilities":[{"name":"vCPUs","value":"2"}]}]'
    }
    if ($text -match '^vm list-usage') {
        return '[{"name":{"value":"cores"},"limit":100,"currentValue":100},{"name":{"value":"standardBasv2Family"},"limit":100,"currentValue":100}]'
    }
    if ($text -match '^vm list ') {
        if ($global:RunnerTestMode -eq 'existing-vm') {
            return '[{"tags":{"workload":"synapse-shared-runner"},"hardwareProfile":{"vmSize":"Standard_B2as_v2"}}]'
        }
        return '[]'
    }
    if ($global:RunnerTestMode -eq 'start-failure' -and 'put' -in $arguments) {
        $global:LASTEXITCODE = 1
        return
    }
    if ('get' -in $arguments) {
        if ($global:RunnerTestMode -eq 'execution-failure') {
            return '{"properties":{"provisioningState":"Succeeded","instanceView":{"executionState":"Failed","exitCode":1}}}'
        }
        return '{"properties":{"provisioningState":"Succeeded","instanceView":{"executionState":"Succeeded","exitCode":0}}}'
    }
    if (($arguments -join ' ') -match '^deployment group show') {
        return '{"privateEndpointSubnetId":{"value":"/subnets/private"},"privateDnsZoneIds":{"value":{"blob":"/zones/blob","dfs":"/zones/dfs","dev":"/zones/dev","sql":"/zones/sql"}}}'
    }
    if (($arguments -join ' ') -match '^synapse workspace show') {
        return '{"id":"/workspaces/dev","defaultDataLakeStorage":{"resourceId":"/storage/dev"}}'
    }
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "runner-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $sandbox | Out-Null
$savedPassword = $env:RUNNER_ADMIN_PASSWORD
try {
    $commandScript = Join-Path $scripts 'Invoke-RunnerManagedCommand.ps1'
    $parameters = @{
        VmResourceId = '/subscriptions/test/resourceGroups/shared/providers/Microsoft.Compute/virtualMachines/runner'
        Location = 'westus3'
        Name = 'registration-test'
        ScriptPath = (Join-Path $scripts 'Register-GitHubRunner.ps1')
        Parameters = @{ Repository = 'example/repository'; RunnerName = 'runner' }
        ProtectedParameters = @{ RegistrationToken = 'unit-test-secret' }
    }
    & $commandScript @parameters
    $put = @($global:RunnerTestCalls | Where-Object { 'put' -in $_.Arguments })[0]
    Assert-RunnerTest ($put.Body.properties.protectedParameters[0].value -eq 'unit-test-secret') 'Token was not placed in protected parameters.'
    Assert-RunnerTest ('RegistrationToken' -notin $put.Body.properties.parameters.name) 'Registration token leaked into ordinary parameters.'
    Assert-RunnerTest ($put.Body.properties.source.script -notmatch 'unit-test-secret') 'Token leaked into script source.'
    Assert-RunnerTest ($put.Body.properties.treatFailureAsDeploymentFailure -eq $true) 'Guest failures are not surfaced as deployment failures.'
    $payloadPath = @($put.Arguments | Where-Object { $_ -like '@*' })[0].Substring(1)
    Assert-RunnerTest (-not (Test-Path -LiteralPath $payloadPath)) 'Sensitive payload was not cleaned up.'
    Assert-RunnerTest (@($global:RunnerTestCalls | Where-Object { 'delete' -in $_.Arguments }).Count -eq 1) 'Completed Run Command resource was not deleted.'
    $global:RunnerTestMode = 'start-failure'
    Assert-RunnerFailure { & $commandScript @parameters } 'Unable to start'
    $global:RunnerTestMode = 'execution-failure'
    Assert-RunnerFailure { & $commandScript @parameters } 'failed'
    $global:RunnerTestMode = 'success'

    & (Join-Path $scripts 'Set-SynapsePrivateConnectivity.ps1') -RunnerResourceGroup shared `
        -EnvironmentResourceGroup dev -EnvironmentName dev -WorkspaceName workspace
    $deploy = @($global:RunnerTestCalls | Where-Object { ($_.Arguments -join ' ') -match '^deployment group create' })[0]
    Assert-RunnerTest ($deploy.Body.parameters.storageAccountId.value -eq '/storage/dev') 'Storage ID was not resolved from the workspace.'
    Assert-RunnerTest ($deploy.Body.parameters.synapseWorkspaceId.value -eq '/workspaces/dev') 'Workspace ID was not preserved.'
    Assert-RunnerTest ($deploy.Body.parameters.privateEndpointSubnetId.value -eq '/subnets/private') 'Shared endpoint subnet was not used.'
    Assert-RunnerTest ($deploy.Body.parameters.privateDnsZoneIds.value.sql -eq '/zones/sql') 'Shared SQL private DNS zone was not passed.'
    $parametersPath = @($deploy.Arguments | Where-Object { $_ -like '@*' })[0].Substring(1)
    Assert-RunnerTest (-not (Test-Path -LiteralPath $parametersPath)) 'Connectivity parameter file was not cleaned up.'

    $env:RUNNER_ADMIN_PASSWORD = 'unit-test-password'
    $deploymentScript = Join-Path $scripts 'Deploy-SharedRunner.ps1'
    $global:RunnerTestMode = 'restricted-sku'
    Assert-RunnerFailure { & $deploymentScript -ResourceGroupName shared } 'unavailable or restricted'
    $global:RunnerTestMode = 'success'
    Assert-RunnerFailure { & $deploymentScript -ResourceGroupName shared } 'Insufficient or unknown quota'
    $global:RunnerTestMode = 'existing-vm'
    & $deploymentScript -ResourceGroupName shared
    $sharedDeploy = @($global:RunnerTestCalls | Where-Object {
        ($_.Arguments -join ' ') -match '^deployment group create' -and 'shared-runner' -in $_.Arguments
    })[0]
    Assert-RunnerTest ($sharedDeploy.Body.parameters.vmSize.value -eq 'Standard_B2as_v2') 'Shared deployment did not use the selected SKU.'
    $secretPath = @($sharedDeploy.Arguments | Where-Object { $_ -like '@*' })[0].Substring(1)
    Assert-RunnerTest (-not (Test-Path -LiteralPath $secretPath)) 'VM password parameter file was not cleaned up.'
    $env:RUNNER_ADMIN_PASSWORD = ''
    Assert-RunnerFailure { & $deploymentScript -ResourceGroupName shared } 'RUNNER_ADMIN_PASSWORD'

    $global:RunnerTestServiceWrites = 0
    function global:New-ItemProperty { $global:RunnerTestServiceWrites++ }
    function global:Get-Service { [pscustomobject]@{ Status = 'Running' } }
    '{"agentName":"unit-runner","gitHubUrl":"https://github.com/example/repository"}' |
        Set-Content -LiteralPath (Join-Path $sandbox '.runner')
    'unit-service' | Set-Content -LiteralPath (Join-Path $sandbox '.service')
    $registrationScript = Join-Path $scripts 'Register-GitHubRunner.ps1'
    & $registrationScript -Repository example/repository -RunnerName unit-runner -RegistrationToken unit-token -RunnerDirectory $sandbox
    & $registrationScript -Repository example/repository -RunnerName unit-runner -RegistrationToken unit-token -RunnerDirectory $sandbox
    Assert-RunnerTest ($global:RunnerTestServiceWrites -eq 2) 'Repeated registration did not reuse the existing service.'
    Assert-RunnerFailure {
        & $registrationScript -Repository other/repository -RunnerName unit-runner -RegistrationToken unit-token -RunnerDirectory $sandbox
    } 'different runner/repository'
    Remove-Item -LiteralPath (Join-Path $sandbox '.service')
    Assert-RunnerFailure {
        & $registrationScript -Repository example/repository -RunnerName unit-runner -RegistrationToken unit-token -RunnerDirectory $sandbox
    } 'without a Windows service'

    function global:Resolve-DnsName { [pscustomobject]@{ Type = 'A'; IPAddress = '20.1.2.3' } }
    Assert-RunnerFailure {
        & (Join-Path $scripts 'Test-RunnerPrivateConnectivity.ps1') -StorageAccountName accounttest -WorkspaceName workspace
    } 'non-private address'
    function global:Resolve-DnsName { @() }
    Assert-RunnerFailure {
        & (Join-Path $scripts 'Test-RunnerPrivateConnectivity.ps1') -StorageAccountName accounttest -WorkspaceName workspace
    } 'No DNS addresses'

    foreach ($name in @('deploy-environment.yml', 'publish-artifacts-environment.yml')) {
        $workflow = Get-Content (Join-Path $root ".github\workflows\$name") -Raw
        Assert-RunnerTest ($workflow -match 'runs-on: \[self-hosted, Windows, X64, synapse-private\]') "$name does not route to the Windows runner."
        Assert-RunnerTest ($workflow -match "github.ref == 'refs/heads/main'") "$name is not restricted to main."
        Assert-RunnerTest ($workflow -match 'Test-RunnerPrivateConnectivity.ps1') "$name has no private-path preflight."
    }
    $bootstrap = Get-Content (Join-Path $root '.github\workflows\deploy-runner.yml') -Raw
    Assert-RunnerTest ($bootstrap -match 'runs-on: ubuntu-latest') 'Bootstrap depends on its own runner.'
    Assert-RunnerTest ($bootstrap.IndexOf('Install Windows runner prerequisites') -lt $bootstrap.IndexOf('Create repository administration token')) 'Registration token is minted before prerequisite installation.'
    $resolution = 'RUNNER_RESOURCE_GROUP: ${{ vars.RUNNER_RESOURCE_GROUP }}'
    Assert-RunnerTest ($bootstrap.Contains($resolution)) 'Bootstrap does not read the runner resource group directly from GitHub variables.'
    Assert-RunnerTest ($bootstrap -notmatch 'runner-resource-group') 'Bootstrap still exposes runner resource group input/output plumbing.'
    $promotion = Get-Content (Join-Path $root '.github\workflows\deploy.yml') -Raw
    Assert-RunnerTest ($promotion -notmatch 'runner-resource-group') 'Deploy still exposes or forwards a runner resource group input.'
    $environmentWorkflow = Get-Content (Join-Path $root '.github\workflows\deploy-environment.yml') -Raw
    Assert-RunnerTest ($environmentWorkflow -notmatch 'runner-resource-group') 'Environment deployment still accepts a runner resource group input.'
    Assert-RunnerTest ($environmentWorkflow.Contains($resolution)) 'Private connectivity does not read the runner resource group directly from GitHub variables.'
    $validation = Get-Content (Join-Path $root '.github\workflows\validate.yml') -Raw
    Assert-RunnerTest ($validation -match 'runs-on: ubuntu-latest' -and $validation -notmatch 'runs-on: \[self-hosted') 'PR validation moved onto the trusted runner.'

    if ($CompiledRunnerTemplate) {
        $template = Get-Content -LiteralPath $CompiledRunnerTemplate -Raw | ConvertFrom-Json
        $vm = @($template.resources | Where-Object type -EQ 'Microsoft.Compute/virtualMachines')
        $bastion = @($template.resources | Where-Object type -EQ 'Microsoft.Network/bastionHosts')
        $nic = @($template.resources | Where-Object type -EQ 'Microsoft.Network/networkInterfaces')
        $vnet = @($template.resources | Where-Object type -EQ 'Microsoft.Network/virtualNetworks')[0]
        Assert-RunnerTest ($vm.Count -eq 1 -and $bastion.Count -eq 1 -and $nic.Count -eq 1) 'Expected exactly one shared VM, Bastion and NIC.'
        Assert-RunnerTest ($template.parameters.vmSize.defaultValue -eq 'Standard_B2as_v2') 'Unexpected default VM size.'
        Assert-RunnerTest ($vm[0].properties.storageProfile.imageReference.sku -eq '2022-datacenter-azure-edition') 'Unexpected Windows image.'
        Assert-RunnerTest ($bastion[0].sku.name -eq 'Basic') 'Bastion is not Basic.'
        Assert-RunnerTest (-not $nic[0].properties.ipConfigurations[0].properties.PSObject.Properties['publicIPAddress']) 'VM NIC has a public IP.'
        $runnerSubnet = @($vnet.properties.subnets | Where-Object name -EQ 'runner')[0]
        Assert-RunnerTest ($runnerSubnet.properties.defaultOutboundAccess -eq $false -and $null -ne $runnerSubnet.properties.natGateway.id) 'Runner subnet lacks explicit NAT egress.'
        Assert-RunnerTest ($template.variables.zones.Count -eq 4) 'Expected four shared private DNS zones.'
    }
    if ($CompiledConnectivityTemplate) {
        $template = Get-Content -LiteralPath $CompiledConnectivityTemplate -Raw | ConvertFrom-Json
        Assert-RunnerTest ($template.variables.connections.Count -eq 5) 'Expected five private endpoints per environment.'
        Assert-RunnerTest (($template.variables.connections.group -join ',') -eq 'blob,dfs,Dev,Sql,SqlOnDemand') 'Incorrect private endpoint group IDs.'
    }

    foreach ($path in Get-ChildItem -LiteralPath $scripts -Filter '*Runner*.ps1') {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($path.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-RunnerTest ($errors.Count -eq 0) "PowerShell parsing failed for '$($path.Name)'."
    }
    Write-Host "$count runner infrastructure checks passed."
} finally {
    $env:RUNNER_ADMIN_PASSWORD = $savedPassword
    Remove-Item -LiteralPath $sandbox -Recurse -Force
    Remove-Item Function:\global:az
    Remove-Item Function:\global:New-ItemProperty, Function:\global:Get-Service -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Resolve-DnsName -ErrorAction SilentlyContinue
    Remove-Variable RunnerTestCalls, RunnerTestMode -Scope Global
    Remove-Variable RunnerTestServiceWrites -Scope Global -ErrorAction SilentlyContinue
}
