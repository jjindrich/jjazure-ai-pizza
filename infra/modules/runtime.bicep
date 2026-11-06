targetScope = 'resourceGroup'

@description('Approved region.')
param location string
@description('Stable deployment identifier.')
param deploymentId string
@description('Cost and ownership tags.')
param tags object
@description('New VNet-integrated managed environment ID.')
param environmentId string
@description('New environment default domain.')
param environmentDomain string
@description('Private authenticated registry hostname.')
param registryServer string
@description('Catalog managed identity resource ID.')
param catalogIdentityId string
@description('Catalog managed identity client ID.')
param catalogClientId string
@description('Orders managed identity resource ID.')
param ordersIdentityId string
@description('Orders managed identity client ID.')
param ordersClientId string
@description('Temporary initializer identity resource ID.')
param initializerIdentityId string
@description('Temporary initializer client ID.')
param initializerClientId string
@description('Private SQL TLS hostname.')
param sqlHost string
@description('Cosmos account endpoint.')
param cosmosEndpoint string
@description('Blob account endpoint.')
param blobEndpoint string
@description('Temporary initializer lifecycle flag.')
param bootstrapEnabled bool
@description('Catalog immutable ACR image; empty disables app creation.')
param catalogImage string
@description('Orders immutable ACR image; empty disables app creation.')
param ordersImage string
@description('Initializer immutable ACR image; empty disables job creation.')
param initializerImage string

var catalogUrl = 'https://pizza-catalog.${environmentDomain}'
var ordersUrl = 'https://pizza-orders.${environmentDomain}'
var probes = [
  {
    type: 'Startup'
    httpGet: { path: '/health/ready', port: 8080, scheme: 'HTTP' }
    initialDelaySeconds: 5
    periodSeconds: 10
    failureThreshold: 30
  }
  {
    type: 'Readiness'
    httpGet: { path: '/health/ready', port: 8080, scheme: 'HTTP' }
    periodSeconds: 10
    failureThreshold: 3
  }
  {
    type: 'Liveness'
    httpGet: { path: '/health/ready', port: 8080, scheme: 'HTTP' }
    periodSeconds: 30
    failureThreshold: 3
  }
]

resource catalog 'Microsoft.App/containerApps@2025-01-01' = if (!empty(catalogImage)) {
  name: 'pizza-catalog'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${catalogIdentityId}': {} }
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
      registries: [{ server: registryServer, identity: catalogIdentityId }]
    }
    template: {
      containers: [
        {
          name: 'catalog'
          image: catalogImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          probes: probes
          env: [
            { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
            { name: 'AZURE_CLIENT_ID', value: catalogClientId }
            { name: 'PIZZA_STORAGE_MODE', value: 'azure' }
            { name: 'Pizza__Azure__CosmosEndpoint', value: cosmosEndpoint }
            { name: 'Pizza__Azure__CosmosDatabase', value: 'pizza' }
            { name: 'Pizza__Azure__CosmosContainer', value: 'pizzas' }
            { name: 'Pizza__Azure__StorageAccountUrl', value: blobEndpoint }
            { name: 'Pizza__Azure__ImagesContainer', value: 'pizza-images' }
            { name: 'Pizza__OrdersUrl', value: ordersUrl }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
        rules: [{ name: 'http', http: { metadata: { concurrentRequests: '10' } } }]
      }
    }
  }
}

resource orders 'Microsoft.App/containerApps@2025-01-01' = if (!empty(ordersImage)) {
  name: 'pizza-orders'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${ordersIdentityId}': {} }
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
      registries: [{ server: registryServer, identity: ordersIdentityId }]
    }
    template: {
      containers: [
        {
          name: 'orders'
          image: ordersImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          probes: probes
          env: [
            { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
            { name: 'AZURE_CLIENT_ID', value: ordersClientId }
            { name: 'PIZZA_STORAGE_MODE', value: 'azure' }
            { name: 'Pizza__CatalogUrl', value: catalogUrl }
            {
              name: 'Pizza__Azure__SqlConnectionString'
              value: 'Server=tcp:${sqlHost},1433;Database=PizzaOrders;Authentication=Active Directory Managed Identity;User Id=${ordersClientId};Encrypt=True;TrustServerCertificate=False;'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
        rules: [{ name: 'http', http: { metadata: { concurrentRequests: '10' } } }]
      }
    }
  }
}

resource initializer 'Microsoft.App/jobs@2025-01-01' = if (bootstrapEnabled && !empty(initializerImage)) {
  name: 'job-pizza-init-${deploymentId}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${initializerIdentityId}': {} }
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 600
      replicaRetryLimit: 1
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      registries: [{ server: registryServer, identity: initializerIdentityId }]
    }
    template: {
      containers: [
        {
          name: 'initializer'
          image: initializerImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'SQL_HOST', value: sqlHost }
            { name: 'SQL_DATABASE', value: 'PizzaOrders' }
            { name: 'AZURE_CLIENT_ID', value: initializerClientId }
            { name: 'ORDERS_CLIENT_ID', value: ordersClientId }
          ]
        }
      ]
    }
  }
}

output catalogUrl string = catalogUrl
output ordersUrl string = ordersUrl
output initializerJobName string = 'job-pizza-init-${deploymentId}'
