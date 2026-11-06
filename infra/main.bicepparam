using './main.bicep'

param resourceGroupName = 'rg-jjazure-ai-pizza-apps'
param location = 'swedencentral'
param deploymentId = '22df'
param sqlAdminObjectId = readEnvironmentVariable('PIZZA_SQL_ADMIN_OBJECT_ID')
param sqlAdminDisplayName = readEnvironmentVariable('PIZZA_SQL_ADMIN_DISPLAY_NAME')
