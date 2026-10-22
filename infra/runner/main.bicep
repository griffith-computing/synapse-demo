targetScope = 'resourceGroup'

param location string = 'westus3'
@minLength(2)
@maxLength(10)
param namePrefix string = 'synrunner'
param vmSize string = 'Standard_B2as_v2'
param adminUsername string = 'runneradmin'
@secure()
@minLength(12)
param adminPassword string
param vnetAddressPrefix string = '10.42.0.0/16'
param bastionSubnetPrefix string = '10.42.0.0/26'
param runnerSubnetPrefix string = '10.42.1.0/24'
param endpointSubnetPrefix string = '10.42.2.0/24'
@minValue(127)
param osDiskSizeGB int = 128
param tags object = {
  workload: 'synapse-shared-runner'
  managedBy: 'bicep'
}

var suffix = uniqueString(resourceGroup().id)
var vmName = '${namePrefix}-${take(suffix, 4)}'
var zones = [
  { key: 'blob', name: 'privatelink.blob.${environment().suffixes.storage}' }
  { key: 'dfs', name: 'privatelink.dfs.${environment().suffixes.storage}' }
  { key: 'dev', name: 'privatelink.dev.azuresynapse.net' }
  { key: 'sql', name: 'privatelink.sql.azuresynapse.net' }
]

resource natIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${namePrefix}-nat-ip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nat 'Microsoft.Network/natGateways@2024-05-01' = {
  name: '${namePrefix}-nat'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIpAddresses: [{ id: natIp.id }]
    idleTimeoutInMinutes: 10
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${namePrefix}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowBastionRdp'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: bastionSubnetPrefix
          destinationAddressPrefix: runnerSubnetPrefix
        }
      }
      {
        name: 'DenyOtherVnetInbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${namePrefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [vnetAddressPrefix] }
    subnets: [
      {
        name: 'AzureBastionSubnet'
        properties: { addressPrefix: bastionSubnetPrefix }
      }
      {
        name: 'runner'
        properties: {
          addressPrefix: runnerSubnetPrefix
          networkSecurityGroup: { id: nsg.id }
          natGateway: { id: nat.id }
          defaultOutboundAccess: false
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: endpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

resource bastionIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${namePrefix}-bastion-ip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: '${namePrefix}-bastion'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion'
        properties: {
          subnet: { id: '${vnet.id}/subnets/AzureBastionSubnet' }
          publicIPAddress: { id: bastionIp.id }
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'private'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${vnet.id}/subnets/runner' }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
    osProfile: {
      computerName: take(vmName, 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGB
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        deleteOption: 'Delete'
      }
    }
    networkProfile: { networkInterfaces: [{ id: nic.id }] }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}

resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zone in zones: {
  name: zone.name
  location: 'global'
  tags: tags
}]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zone, index) in zones: {
  parent: dnsZones[index]
  name: '${namePrefix}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

output vmName string = vm.name
output vmResourceId string = vm.id
output location string = location
output vnetId string = vnet.id
output privateEndpointSubnetId string = '${vnet.id}/subnets/private-endpoints'
output privateDnsZoneIds object = {
  blob: dnsZones[0].id
  dfs: dnsZones[1].id
  dev: dnsZones[2].id
  sql: dnsZones[3].id
}
