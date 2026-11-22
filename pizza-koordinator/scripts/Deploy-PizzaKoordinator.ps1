[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Uri]$OrdersApiUrl,
    [string]$BlueprintId,
    [string]$SubscriptionId = '80214fc0-7aff-43b6-bbff-cf81a36cbb10',
    [string]$TenantId = 'b48accae-439a-467a-9fbf-8ad011508424',
    [string]$ResourceGroup = 'rg-jjazure-ai-pizza-apps',
    [string]$EnvironmentName = 'cae-pizza-22df',
    [string]$Registry = 'crpizza22dfk5ihazv',
    [string]$FoundryAccount = 'ai-pizza-22df-k5ihazv',
    [string]$FoundryProject = 'pizza-ordering-agent',
    [string]$ContainerApp = 'ca-pizzakoordinator',
    [string]$IdentityName = 'id-pizzakoordinator',
    [string]$AdminUpn = 'jjadmin@jjazdev.org',
    [string[]]$Couriers = @('Kuryr1', 'Kuryr2', 'Kuryr3'),
    [string]$Domain = 'jjazdev.org',
    [switch]$PrepareOnly,
    [string]$Image
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$koordinatorRoot = Join-Path $repoRoot 'pizza-koordinator'

# Optional lookups: a missing resource returns nothing instead of failing the script.
function Find-Az {
    $PSNativeCommandUseErrorActionPreference = $false
    $result = & az @args --only-show-errors 2>&1
    if ($LASTEXITCODE -eq 0) { return $result }
    if (($result -join "`n") -match 'ResourceNotFound|Resource .*does not exist|was not found|could not be found') { return }
    throw "Azure lookup failed: $($result -join "`n")"
}

& az account set --subscription $SubscriptionId
& dotnet test (Join-Path $koordinatorRoot 'PizzaKoordinator.slnx') --nologo -v q | Out-Host

# Entra app that the Foundry OpenAPI connection requests tokens for (v2 tokens: aud = appId, azp = Foundry project identity).
$toolAppName = 'PizzaKoordinator Tool API'
$toolAppId = & az ad app list --display-name $toolAppName --query '[0].appId' --output tsv
if ([string]::IsNullOrWhiteSpace($toolAppId)) {
    $toolAppId = & az ad app create --display-name $toolAppName --query appId --output tsv
}
if (-not (& az ad sp list --filter "appId eq '$toolAppId'" --query '[0].id' --output tsv)) {
    & az ad sp create --id $toolAppId | Out-Null
}

$projectId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$FoundryAccount/projects/$FoundryProject"
$foundryPrincipalId = & az resource show --ids $projectId --api-version 2025-06-01 --query identity.principalId --output tsv
$foundryClientId = & az ad sp show --id $foundryPrincipalId --query appId --output tsv
$foundryEndpoint = "https://$FoundryAccount.services.ai.azure.com/api/projects/$FoundryProject"

$toolObjectId = & az ad app show --id $toolAppId --query id -o tsv
$toolPrincipalId = & az ad sp show --id $toolAppId --query id -o tsv
$roleId = '389fa584-a8ec-477d-8217-e203e358de1c'
$patchFile = Join-Path ([IO.Path]::GetTempPath()) "koordinator-role-$([guid]::NewGuid()).json"
try {
    @{ identifierUris = @("api://$toolAppId"); api = @{ requestedAccessTokenVersion = 2 }
       appRoles = @(@{ id = $roleId; allowedMemberTypes = @('Application'); description = 'Call PizzaKoordinator tools'
        displayName = 'PizzaKoordinator Tool Caller'; isEnabled = $true; value = 'PizzaKoordinator.Tool' }) } |
        ConvertTo-Json -Depth 6 | Set-Content $patchFile
    & az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$toolObjectId" --body "@$patchFile" --headers Content-Type=application/json -o none
    $assigned = & az rest --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$toolPrincipalId/appRoleAssignedTo" -o json | ConvertFrom-Json
    if (-not ($assigned.value | Where-Object { $_.principalId -eq $foundryPrincipalId -and $_.appRoleId -eq $roleId })) {
        @{ principalId = $foundryPrincipalId; resourceId = $toolPrincipalId; appRoleId = $roleId } |
            ConvertTo-Json | Set-Content $patchFile
        & az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$toolPrincipalId/appRoleAssignedTo" --body "@$patchFile" --headers Content-Type=application/json -o none
    }
}
finally { Remove-Item -LiteralPath $patchFile -Force }

# Bridge identity: pulls the image, calls Foundry (agent turns, skill versions) and federates with the Agent 365 blueprint.
$identity = Find-Az identity show -g $ResourceGroup -n $IdentityName --output json
if (-not $identity) { $identity = & az identity create -g $ResourceGroup -n $IdentityName --output json }
$identity = ($identity -join "`n") | ConvertFrom-Json
$registryId = & az acr show -n $Registry --query id --output tsv
$registryServer = & az acr show -n $Registry --query loginServer --output tsv
foreach ($assignment in @(@('AcrPull', $registryId), @('53ca6127-db72-4b80-b1b0-d745d6d5456d', $projectId))) {
    & az role assignment create --assignee-object-id $identity.principalId --assignee-principal-type ServicePrincipal `
        --role $assignment[0] --scope $assignment[1] --only-show-errors | Out-Null
}

$defaultDomain = & az containerapp env show -g $ResourceGroup -n $EnvironmentName --query properties.defaultDomain -o tsv
$apiUrl = "https://$ContainerApp.$defaultDomain"
if ($PrepareOnly) {
    return [pscustomobject]@{
        ApiUrl = $apiUrl; MessagingEndpoint = "$apiUrl/api/messages"; ToolAudience = "api://$toolAppId"
        BridgeIdentityClientId = $identity.clientId; BridgeIdentityPrincipalId = $identity.principalId
        FoundryEndpoint = $foundryEndpoint
    }
}
if ([string]::IsNullOrWhiteSpace($BlueprintId)) { throw 'BlueprintId is required. Run PrepareOnly, then Register-PizzaKoordinator first.' }

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

if (-not $Image) {
    $tag = "koordinator-$(Get-Date -Format yyyyMMddHHmmss)"
    & az acr build --registry $Registry --image "pizzakoordinator-api:$tag" `
        --file (Join-Path $koordinatorRoot 'src\PizzaKoordinator.Api\Dockerfile') $repoRoot --only-show-errors | Out-Host
    $digest = & az acr repository show -n $Registry --image "pizzakoordinator-api:$tag" --query digest -o tsv
    $Image = "$registryServer/pizzakoordinator-api@$digest"
}
elseif ($Image.StartsWith("$registryServer/") -and -not $Image.Contains('@sha256:')) {
    $repositoryImage = $Image.Substring($registryServer.Length + 1)
    $digest = & az acr repository show -n $Registry --image $repositoryImage --query digest -o tsv
    $Image = "$registryServer/$($repositoryImage.Split(':')[0])@$digest"
}

# In-memory coordination state requires exactly one replica.
if (Find-Az containerapp show -g $ResourceGroup -n $ContainerApp --query id --output tsv) {
    & az containerapp update -g $ResourceGroup -n $ContainerApp --image $image --min-replicas 1 --max-replicas 1 `
        --replace-env-vars @settings --output none
}
else {
    & az containerapp create -g $ResourceGroup -n $ContainerApp --environment $EnvironmentName --image $image `
        --user-assigned $identity.id --registry-server $registryServer --registry-identity $identity.id `
        --ingress external --target-port 8080 --cpu 0.25 --memory 0.5Gi --min-replicas 1 --max-replicas 1 --env-vars @settings --output none
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
