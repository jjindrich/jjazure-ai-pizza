targetScope = 'resourceGroup'

@minLength(1)
@maxLength(16)
param environmentName string

param location string = resourceGroup().location
param tags object = {}

@description('Reuses the existing Container Apps delegated subnet when recovering a partially provisioned environment.')
param useExistingContainerAppsSubnet bool = false

@description('Reuses the existing VNet instead of redeploying its parent resource during recovery.')
param useExistingVirtualNetwork bool = false

@description('Reuses the existing NAT Gateway instead of redeploying it during recovery.')
param useExistingNatGateway bool = false

@description('Object ID of the Entra user or service principal that administers Azure SQL.')
param sqlAdminObjectId string

@description('Display name of the signed-in Entra administrator.')
param sqlAdminDisplayName string

@allowed([
  'User'
  'Group'
  'Application'
])
param sqlAdminPrincipalType string = 'User'

param sqlAdminTenantId string = tenant().tenantId

var suffix = take(uniqueString(subscription().id, resourceGroup().id, environmentName), 8)
var appName = 'pizza-${environmentName}-${suffix}'
var storageName = take('pizzast${suffix}', 24)
var cosmosName = take('pizza-cosmos-${suffix}', 44)
var registryName = take('pizzareg${suffix}', 50)
var sqlServerName = 'pizza-sql-${suffix}'
var workspaceName = 'pizza-logs-${suffix}'
var containerAppEnvironmentName = 'pizza-env-${suffix}'
var networkName = 'pizza-vnet-${suffix}'
var natName = 'pizza-nat-${suffix}'
var natPublicIpName = 'pizza-egress-${suffix}'

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: natPublicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    ddosSettings: {
      protectionMode: 'VirtualNetworkInherited'
    }
    ipTags: [
      {
        ipTagType: 'FirstPartyUsage'
        tag: '/Unprivileged'
      }
    ]
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-11-01' existing = {
  name: natName
}

resource newNatGateway 'Microsoft.Network/natGateways@2023-11-01' = if (!useExistingNatGateway) {
  name: natName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

var natGatewayId = useExistingNatGateway ? natGateway.id : newNatGateway!.id

resource network 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: networkName
}

resource newNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' = if (!useExistingVirtualNetwork) {
  name: networkName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
  }
}

resource containerAppsSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = if (!useExistingContainerAppsSubnet) {
  parent: network
  name: 'container-apps'
  properties: {
    addressPrefix: '10.20.0.0/23'
    privateEndpointNetworkPolicies: 'Disabled'
    delegations: [
      {
        name: 'container-apps'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
    natGateway: {
      id: natGatewayId
    }
  }
  dependsOn: [
    newNetwork
  ]
}

resource existingContainerAppsSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: network
  name: 'container-apps'
}

var containerAppsSubnetId = useExistingContainerAppsSubnet
  ? existingContainerAppsSubnet.id
  : containerAppsSubnet!.id

resource privateEndpointsSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: network
  name: 'private-endpoints'
  properties: {
    addressPrefix: '10.20.2.0/24'
    privateEndpointNetworkPolicies: 'Disabled'
  }
  dependsOn: [
    newNetwork
  ]
}

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource containerAppEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppEnvironmentName
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: containerAppsSubnetId
      internal: false
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logWorkspace.properties.customerId
        sharedKey: logWorkspace.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    peerAuthentication: {
      mtls: {
        enabled: false
      }
    }
    peerTrafficConfiguration: {
      encryption: {
        enabled: false
      }
    }
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    dataEndpointEnabled: false
    encryption: {
      status: 'disabled'
    }
    policies: {
      azureADAuthenticationAsArmPolicy: {
        status: 'enabled'
      }
    }
    publicNetworkAccess: 'Enabled'
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
  }
}

resource imageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${storage.name}/default/pizza-images'
  properties: {
    publicAccess: 'None'
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
  }
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: cosmosName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    enableAutomaticFailover: true
    analyticalStorageConfiguration: {
      schemaType: 'WellDefined'
    }
    defaultIdentity: 'FirstPartyIdentity'
    minimalTlsVersion: 'Tls12'
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
  }
}

resource catalogDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmos
  name: 'PizzaCatalog'
  properties: {
    resource: {
      id: 'PizzaCatalog'
    }
  }
}

resource catalogContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: catalogDatabase
  name: 'Pizzas'
  properties: {
    resource: {
      id: 'Pizzas'
      partitionKey: {
        paths: [
          '/id'
        ]
        kind: 'Hash'
        version: 2
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [
          {
            path: '/*'
          }
        ]
        excludedPaths: [
          {
            path: '/"_etag"/?'
          }
        ]
      }
      conflictResolutionPolicy: {
        mode: 'LastWriterWins'
        conflictResolutionPath: '/_ts'
      }
    }
  }
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  tags: tags
  properties: {
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      principalType: sqlAdminPrincipalType
      login: sqlAdminDisplayName
      sid: sqlAdminObjectId
      tenantId: sqlAdminTenantId
    }
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
  }
}

resource sqlAadOnly 'Microsoft.Sql/servers/azureADOnlyAuthentications@2023-08-01-preview' = {
  parent: sqlServer
  name: 'Default'
  properties: {
    azureADOnlyAuthentication: true
  }
}

resource sqlPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  // Azure Public Cloud's fixed SQL Private Link DNS zone.
  #disable-next-line no-hardcoded-env-urls
  name: 'privatelink.database.windows.net'
  location: 'global'
  tags: tags
}

resource sqlPrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: sqlPrivateDnsZone
  name: '${network.name}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: network.id
    }
  }
  dependsOn: [
    newNetwork
  ]
}

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${sqlServerName}-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointsSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: '${sqlServerName}-connection'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
}

resource sqlPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: sqlPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sql'
        properties: {
          privateDnsZoneId: sqlPrivateDnsZone.id
        }
      }
    ]
  }
}

resource storagePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource storagePrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: storagePrivateDnsZone
  name: '${network.name}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: network.id
    }
  }
  dependsOn: [
    newNetwork
  ]
}

resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${storage.name}-blob-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointsSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: '${storage.name}-blob-connection'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource storagePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: storagePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: storagePrivateDnsZone.id
        }
      }
    ]
  }
}

resource cosmosPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.documents.azure.com'
  location: 'global'
  tags: tags
}

resource cosmosPrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: cosmosPrivateDnsZone
  name: '${network.name}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: network.id
    }
  }
  dependsOn: [
    newNetwork
  ]
}

resource cosmosPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${cosmos.name}-sql-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointsSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: '${cosmos.name}-sql-connection'
        properties: {
          privateLinkServiceId: cosmos.id
          groupIds: [
            'Sql'
          ]
        }
      }
    ]
  }
}

resource cosmosPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: cosmosPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sql'
        properties: {
          privateDnsZoneId: cosmosPrivateDnsZone.id
        }
      }
    ]
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: 'PizzaOrders'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648
    zoneRedundant: false
  }
}

resource pizzaApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: union(tags, {
    'azd-service-name': 'pizza-web'
  })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerAppEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'pizza-web'
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'ASPNETCORE_URLS'
              value: 'http://+:8080'
            }
            {
              name: 'PIZZA_STORAGE_MODE'
              value: 'azure'
            }
            {
              name: 'Pizza__Azure__CosmosEndpoint'
              value: cosmos.properties.documentEndpoint
            }
            {
              name: 'Pizza__Azure__CosmosDatabase'
              value: catalogDatabase.name
            }
            {
              name: 'Pizza__Azure__CosmosContainer'
              value: catalogContainer.name
            }
            {
              name: 'Pizza__Azure__StorageAccountUrl'
              value: 'https://${storage.name}.blob.${environment().suffixes.storage}'
            }
            {
              name: 'Pizza__Azure__SqlConnectionString'
              value: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=${sqlDatabase.name};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;Authentication=Active Directory Default;'
            }
          ]
          probes: [
            {
              type: 'Readiness'
              httpGet: {
                path: '/'
                port: 8080
                scheme: 'HTTP'
              }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
      }
    }
  }
  dependsOn: [
    imageContainer
    sqlAadOnly
    sqlPrivateDnsLink
    sqlPrivateDnsZoneGroup
    storagePrivateDnsLink
    storagePrivateDnsZoneGroup
    cosmosPrivateDnsLink
    cosmosPrivateDnsZoneGroup
  ]
}

module registryPullRole './modules/acr-pull-role.bicep' = {
  name: 'acrPullRole'
  params: {
    acrName: registry.name
    principalId: pizzaApp.identity.principalId
  }
}

resource blobDataRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, pizzaApp.id, 'StorageBlobDataContributor')
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
    principalId: pizzaApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource cosmosDataRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmos
  name: guid(cosmos.id, pizzaApp.id, 'CosmosDataContributor')
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    principalId: pizzaApp.identity.principalId
    scope: cosmos.id
  }
}

output AZURE_CONTAINER_APP_NAME string = pizzaApp.name
output AZURE_CONTAINER_APP_RESOURCE_ID string = pizzaApp.id
output AZURE_CONTAINER_APP_FQDN string = pizzaApp.properties.configuration.ingress.fqdn
output AZURE_CONTAINER_APP_ENVIRONMENT_NAME string = containerAppEnvironment.name
output cosmosEndpoint string = cosmos.properties.documentEndpoint
output cosmosDatabaseName string = catalogDatabase.name
output cosmosContainerName string = catalogContainer.name
output storageAccountUrl string = 'https://${storage.name}.blob.${environment().suffixes.storage}'
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlPrivateEndpointName string = sqlPrivateEndpoint.name
output sqlDatabaseName string = sqlDatabase.name
output SQL_SERVER string = sqlServer.name
output SQL_DATABASE string = sqlDatabase.name
output SERVICE_WEB_NAME string = pizzaApp.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = registry.properties.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = registry.name
output containerAppManagedIdentityPrincipalId string = pizzaApp.identity.principalId
