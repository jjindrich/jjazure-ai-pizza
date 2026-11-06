targetScope = 'resourceGroup'

@description('Approved region.')
param location string
@description('Stable deployment identifier.')
param deploymentId string
@description('Cost and ownership tags.')
param tags object
@description('Existing deployment caller object ID; project administration only.')
param callerObjectId string

var suffix = take(uniqueString(subscription().id, resourceGroup().id), 7)
var name = 'ai-pizza-${deploymentId}-${suffix}'

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: name
    allowProjectManagement: true
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  dependsOn: [model]
  parent: account
  name: 'pizza-ordering-agent'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Pizza ordering demo'
    description: 'Synthetic pizza orders through separate Catalog and Orders APIs.'
  }
}
resource model 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: 'gpt-5-mini'
  sku: {
    name: 'GlobalStandard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5-mini'
      version: '2025-08-07'
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}
resource callerProjectManager 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(project.id, callerObjectId, 'project-manager')
  scope: project
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'eadc314b-1a2d-4efa-be10-5d325db5065e')
    principalId: callerObjectId
    principalType: 'User'
  }
}
resource callerModelUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, callerObjectId, 'model-user')
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: callerObjectId
    principalType: 'User'
  }
}
resource projectModelUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, project.id, 'model-user')
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output accountName string = account.name
output projectId string = project.id
output projectEndpoint string = 'https://${name}.services.ai.azure.com/api/projects/${project.name}'
