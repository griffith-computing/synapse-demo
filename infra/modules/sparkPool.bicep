// Module: sparkPool.bicep
// Optional Apache Spark (big data) pool attached to an existing Synapse
// workspace. Sized small by default to keep PoC cost low; auto-pause enabled.

@description('Name of the parent Synapse workspace.')
param workspaceName string

@description('Name of the Spark pool. 1-15 chars, lowercase letters/numbers.')
@minLength(1)
@maxLength(15)
param sparkPoolName string

@description('Azure region for the Spark pool (should match the workspace region).')
param location string

@description('Node size family for the Spark pool.')
param nodeSizeFamily string = 'MemoryOptimized'

@description('Node size for the Spark pool.')
@allowed([
  'Small'
  'Medium'
  'Large'
])
param nodeSize string = 'Small'

@description('Minimum number of nodes.')
param nodeCountMin int = 3

@description('Maximum number of nodes for autoscale.')
param nodeCountMax int = 3

@description('Spark version.')
param sparkVersion string = '3.3'

@description('Idle minutes before the Spark pool auto-pauses.')
param autoPauseDelayInMinutes int = 15

@description('Tags applied to the Spark pool.')
param tags object = {}

resource workspace 'Microsoft.Synapse/workspaces@2021-06-01' existing = {
  name: workspaceName
}

resource sparkPool 'Microsoft.Synapse/workspaces/bigDataPools@2021-06-01' = {
  parent: workspace
  name: sparkPoolName
  location: location
  tags: tags
  properties: {
    nodeSizeFamily: nodeSizeFamily
    nodeSize: nodeSize
    autoScale: {
      enabled: true
      minNodeCount: nodeCountMin
      maxNodeCount: nodeCountMax
    }
    autoPause: {
      enabled: true
      delayInMinutes: autoPauseDelayInMinutes
    }
    sparkVersion: sparkVersion
    isComputeIsolationEnabled: false
  }
}

@description('Resource ID of the Spark pool.')
output sparkPoolId string = sparkPool.id

@description('Name of the Spark pool.')
output sparkPoolName string = sparkPool.name
