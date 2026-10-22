targetScope = 'resourceGroup'

param location string = 'westus3'
@allowed(['dev', 'test', 'prod'])
param environmentName string
param storageAccountId string
param synapseWorkspaceId string
param privateEndpointSubnetId string
param privateDnsZoneIds object

var connections = [
  { name: 'blob', group: 'blob', target: storageAccountId, zone: privateDnsZoneIds.blob }
  { name: 'dfs', group: 'dfs', target: storageAccountId, zone: privateDnsZoneIds.dfs }
  { name: 'dev', group: 'Dev', target: synapseWorkspaceId, zone: privateDnsZoneIds.dev }
  { name: 'sql', group: 'Sql', target: synapseWorkspaceId, zone: privateDnsZoneIds.sql }
  { name: 'sqlondemand', group: 'SqlOnDemand', target: synapseWorkspaceId, zone: privateDnsZoneIds.sql }
]

resource endpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [for connection in connections: {
  name: 'pe-${environmentName}-${connection.name}'
  location: location
  tags: { environment: environmentName, managedBy: 'bicep' }
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${environmentName}-${connection.name}'
        properties: {
          privateLinkServiceId: connection.target
          groupIds: [connection.group]
        }
      }
    ]
  }
}]

resource zoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [for (connection, index) in connections: {
  parent: endpoints[index]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: connection.name
        properties: { privateDnsZoneId: connection.zone }
      }
    ]
  }
}]

output privateEndpointIds array = [for index in range(0, length(connections)): endpoints[index].id]
