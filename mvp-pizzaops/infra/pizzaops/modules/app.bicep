targetScope = 'resourceGroup'

@description('Azure region for the Container App.')
param location string
@description('Tags applied to the Container App.')
param tags object
@description('Container Apps environment resource ID.')
param containerEnvironmentId string
@description('Image reference. Empty omits the Container App for first-stage infrastructure bootstrap.')
param containerImage string
@description('ACR login server.')
param registryServer string
@description('PizzaOps bridge identity resource ID.')
param bridgeIdentityId string
@description('PizzaOps bridge identity client ID.')
param bridgeIdentityClientId string
@description('Service Bus fully qualified namespace.')
param serviceBusFullyQualifiedNamespace string
@description('Service Bus wakeup queue name.')
param serviceBusQueueName string
@description('Cosmos DB endpoint.')
param cosmosEndpoint string
@description('Cosmos DB database name.')
param cosmosDatabaseName string
@description('Graph webhook client-state value injected through a deployment-secure parameter.')
@secure()
param graphClientState string
@description('Application Insights connection string.')
param applicationInsightsConnectionString string
@description('Existing Foundry project endpoint.')
param foundryEndpoint string
@description('Existing Foundry project resource ID.')
param foundryProjectId string
@description('Existing Foundry prompt agent name.')
param foundryAgentName string
@description('Client ID allowed to authenticate as the Foundry tool caller.')
param foundryProjectClientId string
@description('Teams blueprint application client ID.')
param teamsBlueprintClientId string
@description('Tenant ID used by the Teams blueprint.')
param teamsTenantId string
@description('Audience accepted by the PizzaOps API.')
param apiAudience string

resource app 'Microsoft.App/containerApps@2025-01-01' = if (!empty(containerImage)) {
  name: 'ca-pizzaops-api-v2'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${bridgeIdentityId}': {}
    }
  }
  properties: {
    environmentId: containerEnvironmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: registryServer
          identity: bridgeIdentityId
        }
      ]
      secrets: [
        {
          name: 'graph-webhook-client-state'
          value: graphClientState
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'pizzaops-api'
          image: containerImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'ASPNETCORE_ENVIRONMENT'
              value: 'Production'
            }
            {
              name: 'ASPNETCORE_URLS'
              value: 'http://+:8080'
            }
            {
              name: 'Azure__ClientId'
              value: bridgeIdentityClientId
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: bridgeIdentityClientId
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: applicationInsightsConnectionString
            }
            {
              name: 'PizzaOps__FoundryEndpoint'
              value: foundryEndpoint
            }
            {
              name: 'PizzaOps__FoundryProjectId'
              value: foundryProjectId
            }
            {
              name: 'PizzaOps__FoundryAgentName'
              value: foundryAgentName
            }
            {
              name: 'AzureAd__ClientId'
              value: teamsBlueprintClientId
            }
            {
              name: 'AzureAd__TenantId'
              value: teamsTenantId
            }
            {
              name: 'AzureAd__ClientCredentials__0__SourceType'
              value: 'SignedAssertionFromManagedIdentity'
            }
            {
              name: 'AzureAd__ClientCredentials__0__ManagedIdentityClientId'
              value: bridgeIdentityClientId
            }
            {
              name: 'Api__Audience'
              value: replace(apiAudience, 'api://', '')
            }
            {
              name: 'Api__AllowedClientId'
              value: foundryProjectClientId
            }
            {
              name: 'PizzaOps__GraphWebhookClientState'
              secretRef: 'graph-webhook-client-state'
            }
            {
              name: 'PizzaOps__ServiceBusNamespace'
              value: serviceBusFullyQualifiedNamespace
            }
            {
              name: 'PizzaOps__ServiceBusQueue'
              value: serviceBusQueueName
            }
            {
              name: 'PizzaOps__CosmosEndpoint'
              value: cosmosEndpoint
            }
            {
              name: 'PizzaOps__CosmosDatabase'
              value: cosmosDatabaseName
            }
            {
              name: 'PizzaOps__CosmosTasksContainer'
              value: 'tasks'
            }
            {
              name: 'PizzaOps__CosmosEventsContainer'
              value: 'events'
            }
            {
              name: 'PizzaOps__AllowedTenantId'
              value: teamsTenantId
            }
            {
              name: 'PizzaOps__AllowedIssuers'
              value: 'https://login.microsoftonline.com/${teamsTenantId}/v2.0;https://sts.windows.net/${teamsTenantId}/'
            }
            {
              name: 'PizzaOps__RequiredToolRole'
              value: 'PizzaOps.Tool'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 10
        rules: [
          {
            name: 'http'
            http: {
              metadata: {
                concurrentRequests: '20'
              }
            }
          }
          {
            name: 'service-bus-wakeups'
            custom: {
              type: 'azure-servicebus'
              metadata: {
                namespace: serviceBusFullyQualifiedNamespace
                queueName: serviceBusQueueName
                messageCount: '5'
                activationMessageCount: '1'
              }
              identity: bridgeIdentityId
            }
          }
        ]
      }
    }
  }
}

output deployed bool = !empty(containerImage)
output containerAppName string = empty(containerImage) ? '' : app!.name
output containerAppFqdn string = empty(containerImage) ? '' : app!.properties.configuration.ingress.fqdn
output containerAppUrl string = empty(containerImage) ? '' : 'https://${app!.properties.configuration.ingress.fqdn}'
