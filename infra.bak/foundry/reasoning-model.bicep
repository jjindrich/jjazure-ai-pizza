@description('Existing Foundry account; all other resources are preserved.')
param accountName string

@description('Name of the approved reasoning-model deployment.')
param deploymentName string = 'gpt-5-mini'

@description('Token-rate capacity, not provisioned throughput. Subject to runtime token and request rate limits.')
@minValue(1)
@maxValue(300)
param capacity int = 100

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2026-11-01' existing = {
  name: accountName
}

resource reasoningModel 'Microsoft.CognitiveServices/accounts/deployments@2026-11-01' = {
  parent: foundryAccount
  name: deploymentName
  sku: {
    name: 'DataZoneStandard'
    capacity: capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5-mini'
      version: '2025-08-07'
    }
    raiPolicyName: 'Microsoft.DefaultV2'
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

output modelDeploymentName string = reasoningModel.name
