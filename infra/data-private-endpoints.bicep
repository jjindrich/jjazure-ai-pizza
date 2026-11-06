targetScope = 'resourceGroup'

param location string = 'swedencentral'
param deploymentId string = '22df'
param cosmosAccountName string
param storageAccountName string

var tags = {
  application: 'jjazure-ai-pizza'
  environment: 'demo'
  deployment: 'pizza-private-${deploymentId}'
}
var services = [
  {
    name: 'cosmos'
    zone: 'privatelink.documents.azure.com'
    groupId: 'Sql'
    resourceId: resourceId('Microsoft.DocumentDB/databaseAccounts', cosmosAccountName)
  }
  {
    name: 'blob'
    zone: 'privatelink.blob.${environment().suffixes.storage}'
    groupId: 'blob'
    resourceId: resourceId('Microsoft.Storage/storageAccounts', storageAccountName)
  }
]

resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' existing = {
  name: 'vnet-pizza-${deploymentId}'
}
resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = {
  parent: vnet
  name: 'snet-private-endpoints'
}
resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for service in services: {
  name: service.zone
  location: 'global'
  tags: tags
}]
resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (service, index) in services: {
  parent: zones[index]
  name: 'link-pizza-${service.name}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]
resource endpoints 'Microsoft.Network/privateEndpoints@2024-07-01' = [for service in services: {
  name: 'pep-pizza-${service.name}-${deploymentId}'
  location: location
  tags: tags
  properties: {
    subnet: { id: subnet.id }
    privateLinkServiceConnections: [
      {
        name: 'connection-pizza-${service.name}'
        properties: {
          privateLinkServiceId: service.resourceId
          groupIds: [service.groupId]
        }
      }
    ]
  }
}]
resource groups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = [for (service, index) in services: {
  parent: endpoints[index]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: service.name, properties: { privateDnsZoneId: zones[index].id } }
    ]
  }
}]

output privateEndpointIds array = [for (service, index) in services: endpoints[index].id]
