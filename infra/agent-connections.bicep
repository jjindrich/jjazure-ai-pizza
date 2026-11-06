targetScope = 'resourceGroup'

@description('Name of the new Foundry account in this resource group.')
param accountName string
@description('Name of the new Foundry project.')
param projectName string = 'pizza-ordering-agent'
@description('Verified live Catalog HTTPS origin.')
param catalogUrl string
@description('Verified live Orders HTTPS origin.')
param ordersUrl string

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: accountName
}
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: account
  name: projectName
}

resource catalog 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: 'pizza-catalog'
  properties: {
    category: 'OpenAPI'
    authType: 'None'
    target: catalogUrl
    metadata: { type: 'openapi' }
  }
}
resource orders 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: 'pizza-orders'
  properties: {
    category: 'OpenAPI'
    authType: 'None'
    target: ordersUrl
    metadata: { type: 'openapi' }
  }
}

output catalogConnectionId string = catalog.id
output ordersConnectionId string = orders.id
