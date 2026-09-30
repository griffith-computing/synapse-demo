// Module: synapse.bicep
// Deploys a minimal Azure Synapse Analytics workspace with a system-assigned
// managed identity, backed by an existing ADLS Gen2 storage account/filesystem.

@description('Name of the Synapse workspace. 1-50 chars, lowercase letters/numbers/hyphens.')
@minLength(1)
@maxLength(50)
param workspaceName string

@description('Azure region for the Synapse workspace.')
param location string

@description('Resource ID of the ADLS Gen2 storage account used as the default data lake.')
param storageAccountId string

@description('DFS endpoint (e.g. https://<account>.dfs.core.windows.net) of the default storage account.')
param storageAccountDfsEndpoint string

@description('Name of the ADLS Gen2 filesystem used as the default data lake.')
param filesystemName string

@description('SQL administrator login name for the workspace (not a secret).')
param sqlAdministratorLogin string

@description('SQL administrator login password for the workspace. Must be supplied at deploy time, never stored in source.')
@secure()
param sqlAdministratorLoginPassword string

@description('Allow or disallow public network access to the workspace.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('When true, adds a firewall rule allowing all Azure service traffic. Only meaningful when publicNetworkAccess is Enabled.')
param allowAllAzureServicesAccess bool = true

@description('When true, enables the Synapse-managed virtual network (recommended for production; adds deployment time).')
param managedVirtualNetworkEnabled bool = false

@description('Tags applied to the workspace.')
param tags object = {}

resource workspace 'Microsoft.Synapse/workspaces@2021-06-01' = {
  name: workspaceName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    defaultDataLakeStorage: {
      accountUrl: storageAccountDfsEndpoint
      filesystem: filesystemName
      resourceId: storageAccountId
      createManagedPrivateEndpoint: false
    }
    sqlAdministratorLogin: sqlAdministratorLogin
    sqlAdministratorLoginPassword: sqlAdministratorLoginPassword
    publicNetworkAccess: publicNetworkAccess
    managedVirtualNetwork: managedVirtualNetworkEnabled ? 'default' : null
    managedVirtualNetworkSettings: managedVirtualNetworkEnabled ? {
      preventDataExfiltration: false
    } : null
  }
}

// Firewall rule permitting Azure-internal service traffic (e.g. Azure Data
// Factory, Power BI) to reach the workspace endpoints. Only created when the
// workspace is publicly reachable and the caller opts in.
resource allowAzureServicesFirewallRule 'Microsoft.Synapse/workspaces/firewallRules@2021-06-01' = if (publicNetworkAccess == 'Enabled' && allowAllAzureServicesAccess) {
  parent: workspace
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

@description('Resource ID of the Synapse workspace.')
output workspaceId string = workspace.id

@description('Name of the Synapse workspace.')
output workspaceName string = workspace.name

@description('Principal ID of the workspace system-assigned managed identity.')
output principalId string = workspace.identity.principalId

@description('Tenant ID of the workspace system-assigned managed identity.')
output tenantId string = workspace.identity.tenantId

@description('SQL endpoint (dedicated SQL pool connectivity) of the workspace.')
output sqlEndpoint string = workspace.properties.connectivityEndpoints.sql

@description('Serverless SQL on-demand endpoint of the workspace.')
output sqlOnDemandEndpoint string = workspace.properties.connectivityEndpoints.sqlOnDemand

@description('Web/development endpoint (Synapse Studio) of the workspace.')
output webEndpoint string = workspace.properties.connectivityEndpoints.web
