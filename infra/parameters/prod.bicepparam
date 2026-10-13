using '../main.bicep'

// Production-shaped defaults contain no secrets or customer identifiers.
// Supply the SQL administrator password through SYNAPSE_SQL_ADMIN_PASSWORD.
param environmentName = 'prod'
param namePrefix = 'syn'
param location = 'eastus2'
// The PoC uses hosted CI agents. Disable public access only after private
// endpoints and a network-connected self-hosted agent are configured.
param publicNetworkAccess = 'Enabled'

param sqlAdministratorLogin = 'synapseadmin'
param sqlAdministratorLoginPassword = readEnvironmentVariable('SYNAPSE_SQL_ADMIN_PASSWORD', 'validation-only-not-for-deployment')

param deployKeyVault = true
param deploySparkPool = true
param sparkPoolNodeSize = 'Medium'
param deployDiagnostics = false
param logAnalyticsWorkspaceId = ''
param managedVirtualNetworkEnabled = true

param tags = {
  environment: 'prod'
  workload: 'synapse-poc'
  managedBy: 'bicep'
}
