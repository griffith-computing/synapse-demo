// Module: storage.bicep
// Deploys an ADLS Gen2 capable storage account (hierarchical namespace enabled)
// plus a single filesystem (container) used as the Synapse default data lake.

@description('Name of the storage account. Must be globally unique, lowercase, 3-24 chars.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Azure region for the storage account.')
param location string

@description('Name of the ADLS Gen2 filesystem (container) to create for Synapse.')
param filesystemName string

@description('Storage account SKU name.')
param skuName string = 'Standard_LRS'

@description('Allow or disallow public network access to the storage account.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('Tags applied to the storage account.')
param tags object = {}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  kind: 'StorageV2'
  properties: {
    isHnsEnabled: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      defaultAction: publicNetworkAccess == 'Enabled' ? 'Allow' : 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource filesystem 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobServices
  name: filesystemName
  properties: {
    publicAccess: 'None'
  }
}

resource sampleFilesystems 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = [for sampleFilesystemName in [
  'raw'
  'curated'
]: {
  parent: blobServices
  name: sampleFilesystemName
  properties: {
    publicAccess: 'None'
  }
}]

@description('Resource ID of the storage account.')
output storageAccountId string = storageAccount.id

@description('Name of the storage account.')
output storageAccountName string = storageAccount.name

@description('Primary Blob (DFS-capable) endpoint of the storage account.')
output primaryEndpointsBlob string = storageAccount.properties.primaryEndpoints.blob

@description('Primary DFS endpoint of the storage account (ADLS Gen2).')
output primaryEndpointsDfs string = storageAccount.properties.primaryEndpoints.dfs

@description('Name of the ADLS Gen2 filesystem created for Synapse.')
output filesystemName string = filesystem.name
