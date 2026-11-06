using './modules/runtime.bicep'

var foundation = json(readEnvironmentVariable('PIZZA_FOUNDATION_OUTPUTS'))

param location = 'swedencentral'
param deploymentId = '22df'
param tags = {
  application: 'jjazure-ai-pizza'
  environment: 'demo'
  deployment: 'pizza-private-22df'
}
param environmentId = foundation.environmentId.value
param environmentDomain = foundation.environmentDomain.value
param registryServer = foundation.registryServer.value
param catalogIdentityId = foundation.catalogIdentityId.value
param catalogClientId = foundation.catalogClientId.value
param ordersIdentityId = foundation.ordersIdentityId.value
param ordersClientId = foundation.ordersClientId.value
param initializerIdentityId = foundation.initializerIdentityId.value
param initializerClientId = foundation.initializerClientId.value
param sqlHost = foundation.sqlHost.value
param cosmosEndpoint = foundation.cosmosEndpoint.value
param blobEndpoint = foundation.blobEndpoint.value
param bootstrapEnabled = false
param catalogImage = ''
param ordersImage = ''
param initializerImage = ''
