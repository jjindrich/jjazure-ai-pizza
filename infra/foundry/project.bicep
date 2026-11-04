targetScope = 'resourceGroup'

@description('The existing, approved Foundry account in this resource group.')
param accountName string

@description('The approved Foundry project name.')
param projectName string

@description('The approved Foundry region.')
param location string = resourceGroup().location

@description('Resource tags identifying this isolated scope.')
param tags object = {}

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2026-11-01' existing = {
  name: accountName
}

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2026-11-01' = {
  parent: foundryAccount
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: projectName
    description: 'Isolated Microsoft Foundry project for the pizza ordering agent.'
  }
  tags: tags
}

output projectId string = foundryProject.id
