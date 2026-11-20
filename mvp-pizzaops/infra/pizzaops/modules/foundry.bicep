targetScope = 'resourceGroup'

@description('Deployment region.')
param location string
@description('Stable deployment identifier.')
param deploymentId string
@description('Resource tags.')
param tags object
@description('Object ID of the deployer receiving Foundry project management access.')
param callerObjectId string
@description('Principal ID of the PizzaOps bridge UAMI that invokes and continues Foundry responses.')
param bridgeIdentityPrincipalId string

var suffix = take(uniqueString(subscription().id, resourceGroup().id, deploymentId), 7)
var accountName = 'ai-pizzaops-${deploymentId}-${suffix}'

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: accountName
    allowProjectManagement: true
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
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

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  dependsOn: [model]
  name: 'pizzaops'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'PizzaOps MVP'
    description: 'Managed Harness Prompt Agent for workshop and pizza delivery planning.'
  }
}

resource callerProjectManager 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(project.id, callerObjectId, 'foundry-project-manager')
  scope: project
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'eadc314b-1a2d-4efa-be10-5d325db5065e')
    principalId: callerObjectId
    principalType: 'User'
  }
}

resource callerModelUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, callerObjectId, 'cognitive-services-user')
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: callerObjectId
    principalType: 'User'
  }
}

resource projectModelUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, project.id, 'cognitive-services-user')
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource bridgeProjectUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(project.id, bridgeIdentityPrincipalId, 'foundry-user')
  scope: project
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')
    principalId: bridgeIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output accountName string = account.name
output projectId string = project.id
output projectEndpoint string = 'https://${accountName}.services.ai.azure.com/api/projects/${project.name}'
output projectPrincipalId string = project.identity.principalId
