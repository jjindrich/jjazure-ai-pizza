@description('Deterministic globally unique name for the new Foundry account.')
param accountName string

@description('The fixed deployment name for the approved model.')
param deploymentName string

@description('The approved Azure region.')
param location string

@description('The approved Foundry project name.')
param projectName string

@description('Resource tags identifying this isolated scope.')
param tags object

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2026-11-01' = {
  name: accountName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    a365LoggingEnabled: true
    a365Status: 'Enabled'
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
  tags: tags
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

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2026-11-01' = {
  parent: foundryAccount
  name: deploymentName
  sku: {
    name: 'Standard'
    capacity: 1
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4.1-mini'
      version: '2025-04-14'
    }
    raiPolicyName: 'Microsoft.DefaultV2'
    versionUpgradeOption: 'NoAutoUpgrade'
  }
  dependsOn: [
    foundryProject
  ]
  tags: tags
}

output accountId string = foundryAccount.id
output projectId string = foundryProject.id
output modelDeploymentName string = modelDeployment.name
