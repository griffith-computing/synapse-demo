using '../main.bicep'

// Dev bootstrap parameters for the Synapse deployment PoC.
// The SQL admin password is intentionally NOT stored here. Set it in an
// environment variable before deploying, e.g. (PowerShell):
//   $env:SYNAPSE_SQL_ADMIN_PASSWORD = '<your-password>'
//   az deployment group create -g <rg-name> -f infra/main.bicep -p infra/parameters/dev.bicepparam
param environmentName = 'dev'
param namePrefix = 'syn'
param location = 'eastus2'

// Dev is intentionally left publicly reachable for fast inner-loop access.
// Flip to 'Disabled' once private endpoints/VNet integration are in place.
param publicNetworkAccess = 'Enabled'

param sqlAdministratorLogin = 'synapseadmin'
param sqlAdministratorLoginPassword = readEnvironmentVariable('SYNAPSE_SQL_ADMIN_PASSWORD')

param deployKeyVault = true
param deploySparkPool = false
param deployDiagnostics = false
param logAnalyticsWorkspaceId = ''
param managedVirtualNetworkEnabled = false

param tags = {
  environment: 'dev'
  workload: 'synapse-poc'
  managedBy: 'bicep'
}
