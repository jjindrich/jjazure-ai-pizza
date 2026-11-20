targetScope = 'subscription'

@description('Resource group created for the PizzaOps bridge resources.')
param resourceGroupName string = 'rg-pizzaops'
@description('Azure region for all PizzaOps resources.')
param location string = 'swedencentral'
@description('Object ID of the deploying user who will administer the new Foundry project.')
param callerObjectId string
@description('Stable deployment identifier used in resource names.')
@minLength(2)
@maxLength(10)
param deploymentId string = 'demo'
@description('PizzaOps container image. Leave empty for the infrastructure bootstrap pass.')
param containerImage string = ''
@description('Client ID of the existing Foundry project managed identity allowed to call the PizzaOps tool API.')
param foundryProjectClientId string = ''
@description('Teams blueprint application client ID. This is configuration only, not an Entra app registration.')
param teamsBlueprintClientId string
@description('Tenant ID for the tenant-preview Teams blueprint.')
param teamsTenantId string
@description('Audience accepted by the PizzaOps OpenAPI and webhook endpoints.')
param apiAudience string
@description('Tenant-held random value used to verify Graph webhook notifications.')
@secure()
param graphWebhookClientState string

var tags = {
  application: 'PizzaOps'
  component: 'teams-agentic-bridge'
  environment: 'preview'
}

resource pizzaOpsGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module core 'modules/core.bicep' = {
  name: 'pizzaops-core'
  scope: pizzaOpsGroup
  params: {
    location: location
    deploymentId: deploymentId
    tags: tags
    graphWebhookClientState: graphWebhookClientState
  }
}

module foundry 'modules/foundry.bicep' = {
  name: 'pizzaops-foundry'
  scope: pizzaOpsGroup
  params: {
    location: location
    deploymentId: deploymentId
    tags: tags
    callerObjectId: callerObjectId
    bridgeIdentityPrincipalId: core.outputs.bridgeIdentityPrincipalId
  }
}

module authorization 'modules/authorization.bicep' = {
  name: 'pizzaops-authorization'
  scope: pizzaOpsGroup
  params: {
    registryName: core.outputs.registryName
    serviceBusNamespaceName: core.outputs.serviceBusNamespaceName
    serviceBusQueueName: core.outputs.serviceBusQueueName
    cosmosAccountName: core.outputs.cosmosAccountName
    cosmosDatabaseName: core.outputs.cosmosDatabaseName
    keyVaultName: core.outputs.keyVaultName
    bridgeIdentityId: core.outputs.bridgeIdentityId
    bridgeIdentityPrincipalId: core.outputs.bridgeIdentityPrincipalId
  }
}

module app 'modules/app.bicep' = {
  name: 'pizzaops-app'
  scope: pizzaOpsGroup
  dependsOn: [
    authorization
  ]
  params: {
    location: location
    tags: tags
    containerEnvironmentId: core.outputs.containerEnvironmentId
    containerImage: containerImage
    registryServer: core.outputs.registryServer
    bridgeIdentityId: core.outputs.bridgeIdentityId
    bridgeIdentityClientId: core.outputs.bridgeIdentityClientId
    serviceBusFullyQualifiedNamespace: core.outputs.serviceBusFullyQualifiedNamespace
    serviceBusQueueName: core.outputs.serviceBusQueueName
    cosmosEndpoint: core.outputs.cosmosEndpoint
    cosmosDatabaseName: core.outputs.cosmosDatabaseName
    graphClientState: graphWebhookClientState
    applicationInsightsConnectionString: core.outputs.applicationInsightsConnectionString
    foundryEndpoint: foundry.outputs.projectEndpoint
    foundryProjectId: foundry.outputs.projectId
    foundryAgentName: 'pizzaops-agent'
    foundryProjectClientId: foundryProjectClientId
    teamsBlueprintClientId: teamsBlueprintClientId
    teamsTenantId: teamsTenantId
    apiAudience: apiAudience
  }
}

output resourceGroupName string = pizzaOpsGroup.name
output resourceGroupId string = pizzaOpsGroup.id
output registryName string = core.outputs.registryName
output registryServer string = core.outputs.registryServer
output containerEnvironmentId string = core.outputs.containerEnvironmentId
output bridgeIdentityResourceId string = core.outputs.bridgeIdentityId
output bridgeIdentityClientId string = core.outputs.bridgeIdentityClientId
output bridgeIdentityPrincipalId string = core.outputs.bridgeIdentityPrincipalId
output serviceBusFullyQualifiedNamespace string = core.outputs.serviceBusFullyQualifiedNamespace
output serviceBusQueueName string = core.outputs.serviceBusQueueName
output cosmosEndpoint string = core.outputs.cosmosEndpoint
output cosmosDatabaseName string = core.outputs.cosmosDatabaseName
output keyVaultName string = core.outputs.keyVaultName
output graphClientStateSecretUri string = core.outputs.graphClientStateSecretUri
output containerAppDeployed bool = app.outputs.deployed
output containerAppUrl string = app.outputs.containerAppUrl
output foundryAccountName string = foundry.outputs.accountName
output foundryProjectId string = foundry.outputs.projectId
output foundryProjectEndpoint string = foundry.outputs.projectEndpoint
output foundryProjectPrincipalId string = foundry.outputs.projectPrincipalId
output foundryAgentName string = 'pizzaops-agent'
