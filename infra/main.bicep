// main.bicep
// Minimal dev bootstrap for the Azure Synapse Analytics deployment PoC.
// Deploys into an EXISTING resource group (deploy via `az deployment group
// create`). Composed of modular building blocks under ./modules so optional
// pieces (Key Vault, Spark pool, diagnostics) can be toggled independently
// without affecting the core storage + Synapse workspace + RBAC deployment.
//
// Idempotency: all resource names are deterministic given the same inputs
// (environmentName + namePrefix + resourceGroup().id), so re-running this
// deployment performs an incremental (in-place) update rather than creating
// duplicate resources.

targetScope = 'resourceGroup'

@description('Short environment identifier, e.g. dev, test, prod. Used in resource naming and tagging.')
@minLength(2)
@maxLength(10)
param environmentName string = 'dev'

@description('Short prefix applied to all resource names, e.g. a project or team code.')
@minLength(2)
@maxLength(10)
param namePrefix string = 'syn'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Controls public network access for the storage account and Synapse workspace. Set to Disabled for later hardening once private connectivity is in place.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('SQL administrator login name for the Synapse workspace (not a secret).')
param sqlAdministratorLogin string = 'synapseadmin'

@description('SQL administrator login password. Supply at deploy time (e.g. via readEnvironmentVariable in a .bicepparam file or --parameters on the CLI). Never hardcode or commit this value.')
@secure()
param sqlAdministratorLoginPassword string

@description('Deploy an optional Key Vault alongside the core resources.')
param deployKeyVault bool = false

@description('Deploy an optional Spark (big data) pool attached to the Synapse workspace.')
param deploySparkPool bool = false

@description('Node size for the optional Spark pool.')
@allowed([
  'Small'
  'Medium'
  'Large'
])
param sparkPoolNodeSize string = 'Small'

@description('Deploy optional diagnostic settings for the Synapse workspace. Requires logAnalyticsWorkspaceId to be set.')
param deployDiagnostics bool = false

@description('Resource ID of an existing Log Analytics workspace to send Synapse diagnostics to. Required only when deployDiagnostics is true.')
param logAnalyticsWorkspaceId string = ''

@description('Enable the Synapse-managed virtual network. Off by default to keep the PoC fast/cheap to deploy; enable for stronger network isolation.')
param managedVirtualNetworkEnabled bool = false

@description('Common tags applied to all resources.')
param tags object = {
  environment: environmentName
  workload: 'synapse-poc'
  managedBy: 'bicep'
}

// Deterministic, collision-resistant suffix derived from the resource group
// and environment so redeploys are idempotent and names stay stable.
// NOTE: namePrefix/environmentName are assumed lowercase alphanumeric (no
// hyphens/underscores) so the budgets below produce valid names for every
// resource type, including storage accounts and Spark pools which disallow
// hyphens. This is an unvalidated constraint (Bicep params have no regex
// pattern validation) - enforce it operationally via the parameter files.
var uniqueSuffix = uniqueString(resourceGroup().id, environmentName)
var storageAccountName = toLower('${take(namePrefix, 4)}st${take(environmentName, 5)}${uniqueSuffix}')
var filesystemName = toLower('${namePrefix}-${environmentName}-fs')
var workspaceName = toLower(take('${namePrefix}-syn-${environmentName}-${uniqueSuffix}', 50))
var keyVaultName = toLower('${take(namePrefix, 3)}-kv-${take(environmentName, 3)}-${uniqueSuffix}')
var sparkPoolName = toLower('sp${take(environmentName, 2)}${take(uniqueSuffix, 9)}')

module storage 'modules/storage.bicep' = {
  name: 'deploy-storage-${environmentName}'
  params: {
    storageAccountName: storageAccountName
    location: location
    filesystemName: filesystemName
    publicNetworkAccess: publicNetworkAccess
    tags: tags
  }
}

module synapse 'modules/synapse.bicep' = {
  name: 'deploy-synapse-${environmentName}'
  params: {
    workspaceName: workspaceName
    location: location
    storageAccountId: storage.outputs.storageAccountId
    storageAccountDfsEndpoint: storage.outputs.primaryEndpointsDfs
    filesystemName: storage.outputs.filesystemName
    sqlAdministratorLogin: sqlAdministratorLogin
    sqlAdministratorLoginPassword: sqlAdministratorLoginPassword
    publicNetworkAccess: publicNetworkAccess
    allowAllAzureServicesAccess: publicNetworkAccess == 'Enabled'
    managedVirtualNetworkEnabled: managedVirtualNetworkEnabled
    tags: tags
  }
}

// Grants the Synapse workspace managed identity data-plane access to its
// default ADLS Gen2 storage account. Deployed after both storage and synapse
// so the workspace's system-assigned principal ID is available.
module storageRoleAssignment 'modules/roleAssignments.bicep' = {
  name: 'deploy-role-assignment-${environmentName}'
  params: {
    storageAccountName: storage.outputs.storageAccountName
    principalId: synapse.outputs.principalId
    roleAssignmentNameSuffix: '${namePrefix}-${environmentName}-synapse-msi'
  }
}

module keyVault 'modules/keyVault.bicep' = if (deployKeyVault) {
  name: 'deploy-keyvault-${environmentName}'
  params: {
    keyVaultName: keyVaultName
    location: location
    publicNetworkAccess: publicNetworkAccess
    accessPolicyPrincipalId: synapse.outputs.principalId
    tags: tags
  }
}

module sparkPool 'modules/sparkPool.bicep' = if (deploySparkPool) {
  name: 'deploy-sparkpool-${environmentName}'
  params: {
    workspaceName: synapse.outputs.workspaceName
    sparkPoolName: sparkPoolName
    location: location
    nodeSize: sparkPoolNodeSize
    tags: tags
  }
}

module diagnostics 'modules/diagnostics.bicep' = if (deployDiagnostics) {
  name: 'deploy-diagnostics-${environmentName}'
  params: {
    synapseWorkspaceName: synapse.outputs.workspaceName
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    diagnosticSettingName: '${namePrefix}-${environmentName}-synapse-diagnostics'
  }
}

@description('Name of the resource group targeted by this deployment.')
output resourceGroupName string = resourceGroup().name

@description('Name of the ADLS Gen2 storage account backing the Synapse workspace.')
output storageAccountName string = storage.outputs.storageAccountName

@description('Resource ID of the ADLS Gen2 storage account.')
output storageAccountId string = storage.outputs.storageAccountId

@description('Name of the default ADLS Gen2 filesystem used by Synapse.')
output dataLakeFilesystemName string = storage.outputs.filesystemName

@description('Primary DFS endpoint of the ADLS Gen2 storage account. Consumed by the deploy pipeline to resolve synapse/ artifact placeholders (e.g. linked service typeProperties.url) before publishing workspace artifacts.')
output storageAccountDfsEndpoint string = storage.outputs.primaryEndpointsDfs

@description('Name of the Synapse workspace.')
output synapseWorkspaceName string = synapse.outputs.workspaceName

@description('Resource ID of the Synapse workspace.')
output synapseWorkspaceId string = synapse.outputs.workspaceId

@description('Principal ID of the Synapse workspace system-assigned managed identity.')
output synapseWorkspacePrincipalId string = synapse.outputs.principalId

@description('SQL (dedicated pool) connectivity endpoint of the Synapse workspace.')
output synapseSqlEndpoint string = synapse.outputs.sqlEndpoint

@description('Serverless SQL on-demand connectivity endpoint of the Synapse workspace.')
output synapseSqlOnDemandEndpoint string = synapse.outputs.sqlOnDemandEndpoint

@description('Synapse Studio web endpoint of the workspace.')
output synapseWebEndpoint string = synapse.outputs.webEndpoint

@description('Effective public network access setting applied to the storage account and workspace.')
output publicNetworkAccess string = publicNetworkAccess

@description('Name of the Key Vault, if deployed; empty string otherwise.')
output keyVaultName string = deployKeyVault ? keyVault!.outputs.keyVaultName : ''

@description('URI of the Key Vault, if deployed; empty string otherwise.')
output keyVaultUri string = deployKeyVault ? keyVault!.outputs.keyVaultUri : ''

@description('Name of the Spark pool, if deployed; empty string otherwise.')
output sparkPoolName string = deploySparkPool ? sparkPool!.outputs.sparkPoolName : ''
