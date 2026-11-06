targetScope = 'subscription'

@description('The approved Sweden Central region for the isolated Foundry deployment.')
param location string = 'swedencentral'

@description('Dedicated resource group for this Foundry deployment only.')
param resourceGroupName string = 'rg-jjazure-ai-pizza-foundry'

@description('Approved Foundry project name.')
param projectName string = 'pizza-ordering-agent'

var accountName = 'pizzaai${uniqueString(subscription().id, resourceGroupName, projectName, location)}'
var deploymentName = 'gpt-4-1-mini'
var tags = {
  application: 'jjazure-ai-pizza'
  scope: 'foundry'
}

resource foundryResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module foundry './resources.bicep' = {
  name: 'foundry-${uniqueString(subscription().id, resourceGroupName, projectName)}'
  scope: foundryResourceGroup
  params: {
    accountName: accountName
    deploymentName: deploymentName
    location: location
    projectName: projectName
    tags: tags
  }
}

output resourceGroupName string = foundryResourceGroup.name
output accountName string = accountName
output projectName string = projectName
output modelDeploymentName string = deploymentName
