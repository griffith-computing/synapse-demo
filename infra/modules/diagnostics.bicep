// Module: diagnostics.bicep
// Optional diagnostic settings sending Synapse workspace logs/metrics to an
// existing Log Analytics workspace. Does not create the Log Analytics
// workspace itself (kept out of scope for this minimal PoC bootstrap).

@description('Name of the Synapse workspace (used to scope the extension resource).')
param synapseWorkspaceName string

@description('Resource ID of an existing Log Analytics workspace to send diagnostics to.')
param logAnalyticsWorkspaceId string

@description('Name of the diagnostic setting.')
param diagnosticSettingName string = 'synapse-workspace-diagnostics'

resource workspace 'Microsoft.Synapse/workspaces@2021-06-01' existing = {
  name: synapseWorkspaceName
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: diagnosticSettingName
  scope: workspace
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

@description('Resource ID of the diagnostic setting.')
output diagnosticSettingId string = diagnosticSettings.id
