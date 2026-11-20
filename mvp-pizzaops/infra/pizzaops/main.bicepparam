using './main.bicep'

param resourceGroupName = 'rg-pizzaops-preview'
param location = 'swedencentral'
param deploymentId = 'preview'
param containerImage = ''
param callerObjectId = 'REPLACE_DEPLOYER_OBJECT_ID'

// Reuse an existing main deployment. These values are intentionally non-secret placeholders.
param foundryProjectClientId = '00000000-0000-0000-0000-000000000000'

// Tenant-preview Teams and API values. Replace through the deployment pipeline.
param teamsBlueprintClientId = 'd935a216-c452-4e0b-93e9-96ef4141d64e'
param teamsTenantId = '00000000-0000-0000-0000-000000000000'
param apiAudience = 'api://REPLACE_TEAMS_BLUEPRINT_CLIENT_ID'

// Never commit a real client-state value. The workflow overrides this secure parameter.
param graphWebhookClientState = 'REPLACE_FROM_PIZZAOPS_GRAPH_WEBHOOK_CLIENT_STATE'
