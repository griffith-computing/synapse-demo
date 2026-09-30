// Module: keyVault.bicep
// Optional Key Vault for the PoC. No secrets are created or referenced by this
// module; it only provisions the vault shell for later use (e.g. linked
// services, credentials) by other workstreams.

@description('Name of the Key Vault. Must be globally unique, 3-24 chars.')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Azure region for the Key Vault.')
param location string

@description('Azure AD tenant ID used by the vault.')
param tenantId string = subscription().tenantId

@description('Allow or disallow public network access to the Key Vault.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('Principal ID (object ID) to grant get/list secret access, e.g. the Synapse workspace managed identity. Leave empty to skip access policy creation.')
param accessPolicyPrincipalId string = ''

@description('Tags applied to the Key Vault.')
param tags object = {}

var basePolicies = []
var identityPolicy = [
  {
    tenantId: tenantId
    objectId: accessPolicyPrincipalId
    permissions: {
      secrets: [
        'get'
        'list'
      ]
      keys: [
        'get'
        'list'
      ]
    }
  }
]

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    enableRbacAuthorization: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      defaultAction: publicNetworkAccess == 'Enabled' ? 'Allow' : 'Deny'
      bypass: 'AzureServices'
    }
    accessPolicies: empty(accessPolicyPrincipalId) ? basePolicies : identityPolicy
  }
}

@description('Resource ID of the Key Vault.')
output keyVaultId string = keyVault.id

@description('Name of the Key Vault.')
output keyVaultName string = keyVault.name

@description('URI of the Key Vault.')
output keyVaultUri string = keyVault.properties.vaultUri
