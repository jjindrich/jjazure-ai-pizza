targetScope = 'subscription'

@description('Exact user-approved new resource group.')
param resourceGroupName string = 'rg-jjazure-ai-pizza-apps'

@description('Approved deployment region.')
param location string = 'swedencentral'

@description('Short stable deployment identifier.')
param deploymentId string = '22df'

@description('Existing Entra administrator object ID for final SQL handover.')
param sqlAdminObjectId string

@description('Existing Entra administrator display name.')
param sqlAdminDisplayName string

@description('Existing deployment caller object ID for new Foundry project access.')
param callerObjectId string = sqlAdminObjectId

@description('Provision the temporary initializer identity/job. Set false after verified handover; incremental mode does not delete resources.')
param bootstrapEnabled bool = false

@description('ACR Catalog image digest; empty means do not create the app.')
param catalogImage string = ''

@description('ACR Orders image digest; empty means do not create the app.')
param ordersImage string = ''

@description('ACR initializer image digest; empty means do not create the Job.')
param initializerImage string = ''

var tags = {
  application: 'jjazure-ai-pizza'
  environment: 'demo'
  deployment: 'pizza-private-${deploymentId}'
}

resource appGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module foundation './modules/foundation.bicep' = {
  name: 'pizza-foundation'
  scope: appGroup
  params: {
    location: location
    deploymentId: deploymentId
    tags: tags
    bootstrapEnabled: bootstrapEnabled
    sqlAdminObjectId: sqlAdminObjectId
    sqlAdminDisplayName: sqlAdminDisplayName
  }
}

module foundry './modules/foundry.bicep' = {
  name: 'pizza-foundry'
  scope: appGroup
  params: {
    location: location
    deploymentId: deploymentId
    tags: tags
    callerObjectId: callerObjectId
  }
}

module dataPrivateEndpoints './data-private-endpoints.bicep' = {
  name: 'pizza-data-private-endpoints'
  scope: appGroup
  params: {
    location: location
    deploymentId: deploymentId
    cosmosAccountName: foundation.outputs.cosmosAccountName
    storageAccountName: foundation.outputs.storageAccountName
  }
}

module runtime './modules/runtime.bicep' = {
  dependsOn: [dataPrivateEndpoints]
  name: 'pizza-runtime'
  scope: appGroup
  params: {
    location: location
    deploymentId: deploymentId
    tags: tags
    environmentId: foundation.outputs.environmentId
    environmentDomain: foundation.outputs.environmentDomain
    registryServer: foundation.outputs.registryServer
    catalogIdentityId: foundation.outputs.catalogIdentityId
    catalogClientId: foundation.outputs.catalogClientId
    ordersIdentityId: foundation.outputs.ordersIdentityId
    ordersClientId: foundation.outputs.ordersClientId
    initializerIdentityId: foundation.outputs.initializerIdentityId
    initializerClientId: foundation.outputs.initializerClientId
    sqlHost: foundation.outputs.sqlHost
    cosmosEndpoint: foundation.outputs.cosmosEndpoint
    blobEndpoint: foundation.outputs.blobEndpoint
    bootstrapEnabled: bootstrapEnabled
    catalogImage: catalogImage
    ordersImage: ordersImage
    initializerImage: initializerImage
  }
}

output resourceGroupId string = appGroup.id
output registryName string = foundation.outputs.registryName
output registryServer string = foundation.outputs.registryServer
output sqlServerName string = foundation.outputs.sqlServerName
output sqlHost string = foundation.outputs.sqlHost
output ordersClientId string = foundation.outputs.ordersClientId
output initializerIdentityId string = foundation.outputs.initializerIdentityId
output initializerPullRoleId string = foundation.outputs.initializerPullRoleId
output environmentId string = foundation.outputs.environmentId
output managedResourceGroup string = '${resourceGroupName}-managed'
output catalogUrl string = runtime.outputs.catalogUrl
output ordersUrl string = runtime.outputs.ordersUrl
output initializerJobName string = runtime.outputs.initializerJobName
output foundryAccountName string = foundry.outputs.accountName
output projectEndpoint string = foundry.outputs.projectEndpoint
output projectId string = foundry.outputs.projectId
