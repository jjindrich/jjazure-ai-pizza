targetScope = 'resourceGroup'

@description('Private registry name.')
param registryName string
@description('Service Bus namespace name.')
param serviceBusNamespaceName string
@description('Service Bus queue used for wakeups.')
param serviceBusQueueName string
@description('Cosmos DB account name.')
param cosmosAccountName string
@description('Cosmos DB SQL database name.')
param cosmosDatabaseName string
@description('Key Vault name containing the Graph webhook client state.')
param keyVaultName string
@description('PizzaOps bridge user-assigned identity resource ID.')
param bridgeIdentityId string
@description('PizzaOps bridge user-assigned identity principal ID.')
param bridgeIdentityPrincipalId string

var acrPullRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var serviceBusReceiverRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0')
var serviceBusSenderRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39')
var keyVaultSecretsUserRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var cosmosDataContributorRoleId = '00000000-0000-0000-0000-000000000002'

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: registryName
}
resource serviceBus 'Microsoft.ServiceBus/namespaces@2024-01-01' existing = {
  name: serviceBusNamespaceName
}
resource wakeupQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' existing = {
  parent: serviceBus
  name: serviceBusQueueName
}
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2025-04-15' existing = {
  name: cosmosAccountName
}
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}
resource bridgePull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, bridgeIdentityId, acrPullRole)
  properties: {
    roleDefinitionId: acrPullRole
    principalId: bridgeIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource bridgeReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: wakeupQueue
  name: guid(wakeupQueue.id, bridgeIdentityId, serviceBusReceiverRole)
  properties: {
    roleDefinitionId: serviceBusReceiverRole
    principalId: bridgeIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource bridgeSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: wakeupQueue
  name: guid(wakeupQueue.id, bridgeIdentityId, serviceBusSenderRole)
  properties: {
    roleDefinitionId: serviceBusSenderRole
    principalId: bridgeIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource bridgeCosmosDataContributor 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-04-15' = {
  parent: cosmos
  name: guid(cosmos.id, bridgeIdentityPrincipalId, cosmosDataContributorRoleId)
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${cosmosDataContributorRoleId}'
    principalId: bridgeIdentityPrincipalId
    scope: '${cosmos.id}/dbs/${cosmosDatabaseName}'
  }
}

resource bridgeGraphSecretReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, bridgeIdentityId, keyVaultSecretsUserRole)
  properties: {
    roleDefinitionId: keyVaultSecretsUserRole
    principalId: bridgeIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}
