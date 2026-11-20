[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Uri]$OrdersApiUrl,
    [string]$BlueprintId,
    [string]$SubscriptionId = '80214fc0-7aff-43b6-bbff-cf81a36cbb10',
    [string]$TenantId = 'b48accae-439a-467a-9fbf-8ad011508424',
    [string]$ResourceGroup = 'rg-jjazure-ai-mvp-pizzaops',
    [string]$EnvironmentName = 'cae-pizzaops-private-mvp',
    [string]$Registry = 'crpizzaopsmvpi2jyp62',
    [string]$FoundryAccount = 'ai-pizzaops-mvp-i2jyp62',
    [string]$FoundryProject = 'pizzaops',
    [string]$ContainerApp = 'ca-pizzakoordinator',
    [string]$IdentityName = 'id-pizzakoordinator',
    [string]$AdminUpn = 'jjadmin@jjazdev.org',
    [string[]]$Couriers = @('Kuryr1', 'Kuryr2', 'Kuryr3'),
    [string]$Domain = 'jjazdev.org'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$koordinatorRoot = Join-Path $repoRoot 'pizza-koordinator'

# Optional lookups: a missing resource returns nothing instead of failing the script.
function Find-Az { $PSNativeCommandUseErrorActionPreference = $false; & az @args 2>$null }

& az account set --subscription $SubscriptionId
& dotnet test (Join-Path $koordinatorRoot 'PizzaKoordinator.slnx') --nologo -v q

# Entra app that the Foundry OpenAPI connection requests tokens for (v2 tokens: aud = appId, azp = Foundry project identity).
$toolAppName = 'PizzaKoordinator Tool API'
$toolAppId = & az ad app list --display-name $toolAppName --query '[0].appId' --output tsv
if ([string]::IsNullOrWhiteSpace($toolAppId)) {
    $toolAppId = & az ad app create --display-name $toolAppName --query appId --output tsv
}
& az ad app update --id $toolAppId --identifier-uris "api://$toolAppId" --set api.requestedAccessTokenVersion=2 | Out-Null
if (-not (& az ad sp list --filter "appId eq '$toolAppId'" --query '[0].id' --output tsv)) {
    & az ad sp create --id $toolAppId | Out-Null
}

$projectId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$FoundryAccount/projects/$FoundryProject"
$foundryPrincipalId = & az resource show --ids $projectId --query identity.principalId --output tsv
$foundryClientId = & az ad sp show --id $foundryPrincipalId --query appId --output tsv
$foundryEndpoint = "https://$FoundryAccount.services.ai.azure.com/api/projects/$FoundryProject"

# Bridge identity: pulls the image, calls Foundry (agent turns, skill versions) and federates with the Agent 365 blueprint.
$identity = Find-Az identity show -g $ResourceGroup -n $IdentityName --output json
if (-not $identity) { $identity = & az identity create -g $ResourceGroup -n $IdentityName --output json }
$identity = ($identity -join "`n") | ConvertFrom-Json
$registryId = & az acr show -n $Registry --query id --output tsv
$registryServer = & az acr show -n $Registry --query loginServer --output tsv
foreach ($assignment in @(@('AcrPull', $registryId), @('Azure AI User', $projectId))) {
    & az role assignment create --assignee-object-id $identity.principalId --assignee-principal-type ServicePrincipal `
        --role $assignment[0] --scope $assignment[1] --only-show-errors | Out-Null
}

$adminObjectId = & az ad user show --id $AdminUpn --query id --output tsv
$settings = @(
    'ASPNETCORE_ENVIRONMENT=Production',
    "AZURE_CLIENT_ID=$($identity.clientId)",
    "AzureAd__TenantId=$TenantId",
    "AzureAd__ClientId=$BlueprintId",
    'AzureAd__ClientCredentials__0__SourceType=SignedAssertionFromManagedIdentity',
    "AzureAd__ClientCredentials__0__ManagedIdentityClientId=$($identity.clientId)",
    "Koordinator__FoundryEndpoint=$foundryEndpoint",
    "Koordinator__OrdersApiUrl=$($OrdersApiUrl.AbsoluteUri.TrimEnd('/'))",
    "Koordinator__AdminEmail=$AdminUpn",
    "Koordinator__AdminAadObjectId=$adminObjectId",
    "Koordinator__AllowedTenantId=$TenantId",
    "Koordinator__ToolAudience=$toolAppId",
    "Koordinator__ToolClientId=$foundryClientId"
)
for ($i = 0; $i -lt $Couriers.Count; $i++) {
    $upn = "$($Couriers[$i].ToLowerInvariant())@$Domain"
    $objectId = Find-Az ad user show --id $upn --query id --output tsv
    $settings += "Koordinator__Couriers__${i}__Name=$($Couriers[$i])", "Koordinator__Couriers__${i}__Email=$upn", "Koordinator__Couriers__${i}__AadObjectId=$objectId"
}

$tag = "koordinator-$(Get-Date -Format yyyyMMddHHmmss)"
& az acr build --registry $Registry --image "pizzakoordinator-api:$tag" `
    --file (Join-Path $koordinatorRoot 'src\PizzaKoordinator.Api\Dockerfile') $repoRoot --only-show-errors | Out-Host
$image = "$registryServer/pizzakoordinator-api:$tag"

# In-memory coordination state requires exactly one replica.
if (Find-Az containerapp show -g $ResourceGroup -n $ContainerApp --query id --output tsv) {
    & az containerapp update -g $ResourceGroup -n $ContainerApp --image $image --min-replicas 1 --max-replicas 1 `
        --replace-env-vars @settings --output none
}
else {
    & az containerapp create -g $ResourceGroup -n $ContainerApp --environment $EnvironmentName --image $image `
        --user-assigned $identity.id --registry-server $registryServer --registry-identity $identity.id `
        --ingress external --target-port 8080 --min-replicas 1 --max-replicas 1 --env-vars @settings --output none
}

$fqdn = & az containerapp show -g $ResourceGroup -n $ContainerApp --query properties.configuration.ingress.fqdn --output tsv
[pscustomobject]@{
    ApiUrl = "https://$fqdn"
    MessagingEndpoint = "https://$fqdn/api/messages"
    ToolAudience = "api://$toolAppId"
    BridgeIdentityClientId = $identity.clientId
    BridgeIdentityPrincipalId = $identity.principalId
    FoundryEndpoint = $foundryEndpoint
    Image = $image
}
