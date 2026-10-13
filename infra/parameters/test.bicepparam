using '../main.bicep'

// Test defaults contain no secrets or customer identifiers. Supply the SQL
// administrator password through SYNAPSE_SQL_ADMIN_PASSWORD at deployment.
param environmentName = 'test'
param namePrefix = 'syn'
param location = 'eastus2'
param publicNetworkAccess = 'Enabled'

param sqlAdministratorLogin = 'synapseadmin'
param sqlAdministratorLoginPassword = readEnvironmentVariable('SYNAPSE_SQL_ADMIN_PASSWORD', 'validation-only-not-for-deployment')

param deployKeyVault = true
param deploySparkPool = true
param sparkPoolNodeSize = 'Small'
param deployDiagnostics = false
param logAnalyticsWorkspaceId = ''
param managedVirtualNetworkEnabled = false

param tags = {
  environment: 'test'
  workload: 'synapse-poc'
  managedBy: 'bicep'
}
