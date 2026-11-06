using './modules/foundry.bicep'

param location = 'swedencentral'
param deploymentId = '22df'
param callerObjectId = readEnvironmentVariable('PIZZA_SQL_ADMIN_OBJECT_ID')
param tags = {
  application: 'jjazure-ai-pizza'
  environment: 'demo'
  deployment: 'pizza-private-22df'
}
