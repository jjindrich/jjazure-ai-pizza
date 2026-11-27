[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Uri]$OrdersApiUrl,
    [string]$BlueprintId,
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$TenantId = $env:AZURE_TENANT_ID,
    [string]$ResourceGroup = 'rg-jjazure-ai-pizza-apps',
    [string]$EnvironmentName = 'cae-pizza-22df',
    [string]$Registry = 'crpizza22dfk5ihazv',
    [string]$FoundryAccount = 'ai-pizza-22df-k5ihazv',
    [string]$FoundryProject = 'pizza-ordering-agent',
    # Public DMZ Gateway keeps the original app name, so the messaging endpoint and tool URL do not change.
    [string]$GatewayApp = 'ca-pizzakoordinator',
    [string]$GatewayIdentityName = 'id-pizzakoordinator-gateway',
    [string]$SandboxGroupName = 'sbg-pizzakoordinator',
    [string]$SandboxEnvironmentName = 'cae-pizzakoordinator-sandbox',
    [string]$Location = 'swedencentral',
    [string]$IdentityName = 'id-pizzakoordinator',
    [string]$AdminUpn = 'jjadmin@jjazdev.org',
    [string[]]$Couriers = @('Kuryr1', 'Kuryr2', 'Kuryr3'),
    [string]$Domain = 'jjazdev.org',
    [switch]$PrepareOnly,
    [string]$GatewayImage,
    [string]$WorkerImage,
    [switch]$ReplaceWorker
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
foreach ($name in @('SubscriptionId', 'TenantId')) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse((Get-Variable $name -ValueOnly), [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$name must be a non-empty GUID; provide it as a parameter or AZURE_* environment variable."
    }
}
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$koordinatorRoot = Join-Path $repoRoot 'pizza-koordinator'
. (Join-Path $PSScriptRoot 'WorkerSandbox.ps1')
Assert-SandboxTools
if ($SandboxEnvironmentName -eq $EnvironmentName) { throw 'Sandbox ingress requires a separate private Express environment.' }

& az account set --subscription $SubscriptionId
$accountTenantId = & az account show --query tenantId -o tsv
if ($accountTenantId -ine $TenantId) { throw 'The selected subscription belongs to a different tenant.' }
& dotnet test (Join-Path $koordinatorRoot 'PizzaKoordinator.slnx') --nologo -v q | Out-Host
if (Find-Az containerapp show -g $ResourceGroup -n ca-pizzakoordinator-worker --query id -o tsv) {
    throw 'A legacy Worker Container App exists. Retire it explicitly before deploying the Sandbox Worker; this script never deletes it.'
}

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

# Worker identity (internal): pulls its image, calls Foundry and federates with the Agent 365 blueprint.
# Gateway identity (DMZ): pulls its image and calls only the internal Worker; no Foundry, Graph or blueprint access.
$registryId = & az acr show -n $Registry --query id --output tsv
$registryServer = & az acr show -n $Registry --query loginServer --output tsv
$identities = @{}
foreach ($name in @($IdentityName, $GatewayIdentityName)) {
    $identity = Find-Az identity show -g $ResourceGroup -n $name --output json
    if (-not $identity) { $identity = & az identity create -g $ResourceGroup -n $name --output json }
    $identities[$name] = ($identity -join "`n") | ConvertFrom-Json
}
$workerIdentity = $identities[$IdentityName]
$gatewayIdentity = $identities[$GatewayIdentityName]
foreach ($assignment in @(
        @($workerIdentity, 'AcrPull', $registryId),
        @($workerIdentity, '53ca6127-db72-4b80-b1b0-d745d6d5456d', $projectId), # Foundry User
        @($gatewayIdentity, 'AcrPull', $registryId))) {
    & az role assignment create --assignee-object-id $assignment[0].principalId --assignee-principal-type ServicePrincipal `
        --role $assignment[1] --scope $assignment[2] --only-show-errors | Out-Null
}

# Tool API callers: the Foundry project identity calls the Gateway, the Gateway identity calls the Worker.
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
    foreach ($principalId in @($foundryPrincipalId, $gatewayIdentity.principalId)) {
        if ($assigned.value | Where-Object { $_.principalId -eq $principalId -and $_.appRoleId -eq $roleId }) { continue }
        @{ principalId = $principalId; resourceId = $toolPrincipalId; appRoleId = $roleId } |
            ConvertTo-Json | Set-Content $patchFile
        # A just-created managed identity can take a moment to replicate to Microsoft Graph.
        for ($attempt = 1; ; $attempt++) {
            try { & az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$toolPrincipalId/appRoleAssignedTo" --body "@$patchFile" --headers Content-Type=application/json -o none; break }
            catch { if ($attempt -ge 5) { throw }; Start-Sleep -Seconds 15 }
        }
    }
}
finally { Remove-Item -LiteralPath $patchFile -Force }

$defaultDomain = & az containerapp env show -g $ResourceGroup -n $EnvironmentName --query properties.defaultDomain -o tsv
$apiUrl = "https://$GatewayApp.$defaultDomain"
if ($PrepareOnly) {
    return [pscustomobject]@{
        ApiUrl = $apiUrl; MessagingEndpoint = "$apiUrl/api/messages"; ToolAudience = "api://$toolAppId"
        WorkerIdentityClientId = $workerIdentity.clientId; WorkerIdentityPrincipalId = $workerIdentity.principalId
        GatewayIdentityClientId = $gatewayIdentity.clientId; FoundryEndpoint = $foundryEndpoint
    }
}
if ([string]::IsNullOrWhiteSpace($BlueprintId)) { throw 'BlueprintId is required. Run PrepareOnly, then Register-PizzaKoordinator first.' }

$adminObjectId = & az ad user show --id $AdminUpn --query id --output tsv
$workerSettings = @(
    'ASPNETCORE_ENVIRONMENT=Production',
    "AZURE_CLIENT_ID=$($workerIdentity.clientId)",
    "AzureAd__TenantId=$TenantId",
    "AzureAd__ClientId=$BlueprintId",
    'AzureAd__ClientCredentials__0__SourceType=SignedAssertionFromManagedIdentity',
    "AzureAd__ClientCredentials__0__ManagedIdentityClientId=$($workerIdentity.clientId)",
    "Koordinator__FoundryEndpoint=$foundryEndpoint",
    "Koordinator__OrdersApiUrl=$($OrdersApiUrl.AbsoluteUri.TrimEnd('/'))",
    "Koordinator__AdminEmail=$AdminUpn",
    "Koordinator__AdminAadObjectId=$adminObjectId",
    "Koordinator__AllowedTenantId=$TenantId",
    "Koordinator__ToolAudience=$toolAppId",
    "Koordinator__GatewayClientId=$($gatewayIdentity.clientId)"
)
for ($i = 0; $i -lt $Couriers.Count; $i++) {
    $upn = "$($Couriers[$i].ToLowerInvariant())@$Domain"
    $objectId = Find-Az ad user show --id $upn --query id --output tsv
    $workerSettings += "Koordinator__Couriers__${i}__Name=$($Couriers[$i])", "Koordinator__Couriers__${i}__Email=$upn", "Koordinator__Couriers__${i}__AadObjectId=$objectId"
}

# Builds the project image when none is given and pins every registry image to its digest.
function Resolve-Image([string]$Image, [string]$Repository, [string]$Project) {
    if (-not $Image) {
        $Image = "$registryServer/${Repository}:koordinator-$(Get-Date -Format yyyyMMddHHmmss)"
        & az acr build --registry $Registry --image $Image.Substring($registryServer.Length + 1) `
            --file (Join-Path $koordinatorRoot "src\$Project\Dockerfile") $repoRoot --only-show-errors | Out-Host
    }
    if ($Image.StartsWith("$registryServer/") -and -not $Image.Contains('@sha256:')) {
        $repositoryImage = $Image.Substring($registryServer.Length + 1)
        $digest = & az acr repository show -n $Registry --image $repositoryImage --query digest -o tsv
        $Image = "$registryServer/$($repositoryImage.Split(':')[0])@$digest"
    }
    $Image
}
$WorkerImage = Resolve-Image $WorkerImage 'pizzakoordinator-worker' 'PizzaKoordinator.Worker'
$GatewayImage = Resolve-Image $GatewayImage 'pizzakoordinator-gateway' 'PizzaKoordinator.Gateway'
if (-not $WorkerImage.StartsWith("$registryServer/")) { throw 'Worker sandbox image must come from the existing ACR.' }
$worker = & (Join-Path $PSScriptRoot 'Deploy-WorkerSandbox.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
    -GatewayEnvironmentName $EnvironmentName -WorkerIdentityId $workerIdentity.id -Image $WorkerImage -Settings $workerSettings `
    -Location $Location -SandboxGroupName $SandboxGroupName -SandboxEnvironmentName $SandboxEnvironmentName -ReplaceWorker:$ReplaceWorker

# Gateway (DMZ): validates Teams and Foundry callers, holds no blueprint credentials and forwards to the Worker.
$gatewaySettings = @(
    'ASPNETCORE_ENVIRONMENT=Production',
    "AZURE_CLIENT_ID=$($gatewayIdentity.clientId)",
    "AzureAd__TenantId=$TenantId",
    "AzureAd__ClientId=$BlueprintId",
    "Gateway__WorkerUrl=$($worker.WorkerUrl)",
    "Gateway__AllowedTenantId=$TenantId",
    "Gateway__ToolAudience=$toolAppId",
    "Gateway__FoundryClientId=$foundryClientId"
)
try {
    if (Find-Az containerapp show -g $ResourceGroup -n $GatewayApp --query id --output tsv) {
        # The app previously ran the whole bridge: switch it to the Gateway identity, then drop the Worker identity.
        & az containerapp identity assign -g $ResourceGroup -n $GatewayApp --user-assigned $gatewayIdentity.id --output none
        & az containerapp registry set -g $ResourceGroup -n $GatewayApp --server $registryServer --identity $gatewayIdentity.id --output none
        & az containerapp update -g $ResourceGroup -n $GatewayApp --image $GatewayImage --min-replicas 1 --max-replicas 3 `
            --replace-env-vars @gatewaySettings --output none
        $gatewayIdentities = (& az containerapp show -g $ResourceGroup -n $GatewayApp --query identity.userAssignedIdentities -o json |
            ConvertFrom-Json).PSObject.Properties.Name
        if ($gatewayIdentities -contains $workerIdentity.id) {
            & az containerapp identity remove -g $ResourceGroup -n $GatewayApp --user-assigned $workerIdentity.id --output none
        }
    }
    else {
        & az containerapp create -g $ResourceGroup -n $GatewayApp --environment $EnvironmentName --image $GatewayImage `
            --user-assigned $gatewayIdentity.id --registry-server $registryServer --registry-identity $gatewayIdentity.id `
            --ingress external --target-port 8080 --cpu 0.25 --memory 0.5Gi --min-replicas 1 --max-replicas 3 --env-vars @gatewaySettings --output none
    }
}
catch {
    $gatewayError = $_
    if ($worker.PreviousGatewayRevision) {
        try {
            Restore-LegacyPoller -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -GatewayAppName $GatewayApp `
                -GatewayRevision $worker.PreviousGatewayRevision -SandboxGroupName $SandboxGroupName `
                -WorkerSandboxId $worker.WorkerSandboxId -WorkerIdentityName $IdentityName `
                -GatewayIdentityName $GatewayIdentityName -Registry $Registry -Location $Location
        }
        catch {
            throw "Gateway deployment failed ($gatewayError), and restoring the prior poller also failed: $_"
        }
    }
    throw $gatewayError
}

$fqdn = & az containerapp show -g $ResourceGroup -n $GatewayApp --query properties.configuration.ingress.fqdn --output tsv
[pscustomobject]@{
    ApiUrl = "https://$fqdn"
    MessagingEndpoint = "https://$fqdn/api/messages"
    ToolAudience = "api://$toolAppId"
    WorkerUrl = $worker.WorkerUrl
    WorkerSandboxId = $worker.WorkerSandboxId
    WorkerSandboxGroup = $worker.WorkerSandboxGroup
    SandboxEnvironmentId = $worker.SandboxEnvironmentId
    WorkerIdentityClientId = $workerIdentity.clientId
    WorkerIdentityPrincipalId = $workerIdentity.principalId
    GatewayIdentityClientId = $gatewayIdentity.clientId
    GatewayIdentityPrincipalId = $gatewayIdentity.principalId
    PreviousGatewayRevision = $worker.PreviousGatewayRevision
    FoundryEndpoint = $foundryEndpoint
    GatewayImage = $GatewayImage
    WorkerImage = $WorkerImage
}
