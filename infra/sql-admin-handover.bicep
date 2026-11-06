targetScope = 'resourceGroup'

param sqlServerName string
param adminObjectId string
param adminDisplayName string

resource sql 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: sqlServerName
}
resource admin 'Microsoft.Sql/servers/administrators@2023-08-01' = {
  parent: sql
  name: 'ActiveDirectory'
  properties: {
    administratorType: 'ActiveDirectory'
    login: adminDisplayName
    sid: adminObjectId
    tenantId: tenant().tenantId
  }
}
