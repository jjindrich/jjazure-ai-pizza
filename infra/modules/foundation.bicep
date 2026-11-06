targetScope = 'resourceGroup'

@description('Approved region.')
param location string
@description('Stable deployment identifier.')
param deploymentId string
@description('Cost and ownership tags.')
param tags object
@description('Temporary SQL bootstrap identity lifecycle.')
param bootstrapEnabled bool
@description('Final existing SQL administrator object ID.')
param sqlAdminObjectId string
@description('Final existing SQL administrator display name.')
param sqlAdminDisplayName string

var suffix = take(uniqueString(subscription().id, resourceGroup().id), 7)
var registryName = 'crpizza${deploymentId}${suffix}'
var sqlName = 'sql-pizza-${deploymentId}-${suffix}'
var cosmosName = 'cosmos-pizza-${deploymentId}-${suffix}'
var storageName = 'stpizza${deploymentId}${suffix}'
var acrPullRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource catalogIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-pizza-catalog-${deploymentId}'
  location: location
  tags: tags
}
resource ordersIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-pizza-orders-${deploymentId}'
  location: location
  tags: tags
}
resource initializerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (bootstrapEnabled) {
  name: 'id-pizza-init-${deploymentId}'
  location: location
  tags: tags
}

resource network 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: 'vnet-pizza-${deploymentId}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.44.0.0/16']
    }
    subnets: [
      {
        name: 'snet-container-apps'
        properties: {
          addressPrefix: '10.44.0.0/23'
          delegations: [
            {
              name: 'container-apps'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: '10.44.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource logs 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: 'log-pizza-${deploymentId}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: 1 }
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource environment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: 'cae-pizza-${deploymentId}'
  location: location
  tags: tags
  properties: {
    infrastructureResourceGroup: '${resourceGroup().name}-managed'
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    vnetConfiguration: {
      infrastructureSubnetId: '${network.id}/subnets/snet-container-apps'
      internal: false
    }
    zoneRedundant: false
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: registryName
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}
resource catalogPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, catalogIdentity.id, acrPullRole)
  scope: registry
  properties: {
    roleDefinitionId: acrPullRole
    principalId: catalogIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
resource ordersPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, ordersIdentity.id, acrPullRole)
  scope: registry
  properties: {
    roleDefinitionId: acrPullRole
    principalId: ordersIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
resource initializerPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (bootstrapEnabled) {
  name: guid(registry.id, initializerIdentity!.id, acrPullRole)
  scope: registry
  properties: {
    roleDefinitionId: acrPullRole
    principalId: initializerIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2025-04-15' = {
  name: cosmosName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    capabilities: [{ name: 'EnableServerless' }]
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
  }
}
resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2025-04-15' = {
  parent: cosmos
  name: 'pizza'
  properties: { resource: { id: 'pizza' } }
}
resource pizzas 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2025-04-15' = {
  parent: database
  name: 'pizzas'
  properties: {
    resource: {
      id: 'pizzas'
      partitionKey: {
        paths: ['/id']
        kind: 'Hash'
        version: 2
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [{ path: '/*' }]
        excludedPaths: [{ path: '/"_etag"/?' }]
      }
    }
  }
}
resource catalogDataRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-04-15' = {
  parent: cosmos
  name: guid(cosmos.id, catalogIdentity.id, 'catalog-data')
  properties: {
    principalId: catalogIdentity.properties.principalId
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: '${cosmos.id}/dbs/pizza/colls/pizzas'
  }
  dependsOn: [pizzas]
}

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
  }
}
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storage
  name: 'default'
}
resource images 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: blobs
  name: 'pizza-images'
  properties: { publicAccess: 'None' }
}
resource imageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: images
  name: guid(images.id, catalogIdentity.id, 'images-contributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: catalogIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource sql 'Microsoft.Sql/servers@2023-08-01' = {
  name: sqlName
  location: location
  tags: tags
  properties: {
    version: '12.0'
    publicNetworkAccess: 'Disabled'
    minimalTlsVersion: '1.2'
    // This property is create-time only; the child below owns subsequent handover.
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      principalType: bootstrapEnabled ? 'Application' : 'User'
      login: bootstrapEnabled ? initializerIdentity!.name : sqlAdminDisplayName
      sid: bootstrapEnabled ? initializerIdentity!.properties.principalId : sqlAdminObjectId
      tenantId: tenant().tenantId
    }
  }
}
resource sqlAdmin 'Microsoft.Sql/servers/administrators@2023-08-01' = {
  parent: sql
  name: 'ActiveDirectory'
  properties: {
    administratorType: 'ActiveDirectory'
    login: bootstrapEnabled ? initializerIdentity!.name : sqlAdminDisplayName
    sid: bootstrapEnabled ? initializerIdentity!.properties.principalId : sqlAdminObjectId
    tenantId: tenant().tenantId
  }
}
resource sqlEntraOnly 'Microsoft.Sql/servers/azureADOnlyAuthentications@2023-08-01' = {
  parent: sql
  name: 'Default'
  properties: { azureADOnlyAuthentication: true }
  dependsOn: [sqlAdmin]
}
resource orders 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: sql
  name: 'PizzaOrders'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  properties: {
    maxSizeBytes: 2147483648
    zoneRedundant: false
    requestedBackupStorageRedundancy: 'Local'
  }
}
resource sqlDns 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink${az.environment().suffixes.sqlServerHostname}'
  location: 'global'
  tags: tags
}
resource sqlDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: sqlDns
  name: 'link-pizza-sql'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: network.id }
  }
}
resource sqlEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: 'pep-pizza-sql-${deploymentId}'
  location: location
  tags: tags
  properties: {
    subnet: { id: '${network.id}/subnets/snet-private-endpoints' }
    privateLinkServiceConnections: [
      {
        name: 'sql'
        properties: {
          privateLinkServiceId: sql.id
          groupIds: ['sqlServer']
        }
      }
    ]
  }
}
resource sqlDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: sqlEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sql'
        properties: { privateDnsZoneId: sqlDns.id }
      }
    ]
  }
}

output registryName string = registry.name
output registryServer string = registry.properties.loginServer
output environmentId string = environment.id
output environmentDomain string = environment.properties.defaultDomain
output sqlServerName string = sql.name
output sqlHost string = sql.properties.fullyQualifiedDomainName
output catalogIdentityId string = catalogIdentity.id
output catalogClientId string = catalogIdentity.properties.clientId
output ordersIdentityId string = ordersIdentity.id
output ordersClientId string = ordersIdentity.properties.clientId
output initializerIdentityId string = bootstrapEnabled ? initializerIdentity!.id : ''
output initializerClientId string = bootstrapEnabled ? initializerIdentity!.properties.clientId : ''
output initializerPullRoleId string = bootstrapEnabled ? initializerPull!.id : ''
output cosmosEndpoint string = cosmos.properties.documentEndpoint
output blobEndpoint string = storage.properties.primaryEndpoints.blob
output cosmosAccountName string = cosmos.name
output storageAccountName string = storage.name
