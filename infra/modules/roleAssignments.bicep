// Module: roleAssignments.bicep
// Grants the Synapse workspace's system-assigned managed identity the
// built-in "Storage Blob Data Contributor" role on the default ADLS Gen2
// storage account, which is required for the workspace to read/write its
// default data lake filesystem.

@description('Name of the existing storage account to grant access to.')
param storageAccountName string

@description('Principal ID of the Synapse workspace system-assigned managed identity.')
param principalId string

@description('Deterministic suffix used to keep the role assignment name stable across incremental deployments.')
param roleAssignmentNameSuffix string = 'synapse-workspace-msi'

// Built-in role definition ID for "Storage Blob Data Contributor".
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource storageBlobDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, principalId, storageBlobDataContributorRoleId, roleAssignmentNameSuffix)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Resource ID of the created role assignment.')
output roleAssignmentId string = storageBlobDataContributorAssignment.id
