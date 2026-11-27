[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-jjazure-ai-pizza-apps',
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$SandboxGroupName = 'sbg-pizzakoordinator',
    [string]$SandboxEnvironmentName = 'cae-pizzakoordinator-sandbox',
    [string]$Location = 'swedencentral'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$parsedSubscription = [guid]::Empty
if (-not [guid]::TryParse($SubscriptionId, [ref]$parsedSubscription) -or $parsedSubscription -eq [guid]::Empty) {
    throw 'SubscriptionId must be a non-empty GUID; provide -SubscriptionId or AZURE_SUBSCRIPTION_ID.'
}
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'WorkerSandbox.ps1')
. (Join-Path $PSScriptRoot 'Agent365Grants.ps1')
. (Join-Path $PSScriptRoot 'FoundryToolVerification.ps1')
& az account set --subscription $SubscriptionId
$gatewayApp = & az containerapp show -g $ResourceGroup -n ca-pizzakoordinator -o json | ConvertFrom-Json
$groupContext = @('--subscription', $SubscriptionId, '-g', $ResourceGroup, '--region', $Location, '--group', $SandboxGroupName)
$group = & aca sandboxgroup get --subscription $SubscriptionId -g $ResourceGroup --name $SandboxGroupName -o json | ConvertFrom-Json
$environment = & az containerapp env show -g $ResourceGroup -n $SandboxEnvironmentName -o json | ConvertFrom-Json
if ($group.properties.environmentId -ne $environment.id -or $environment.properties.environmentMode -ne 'Express' -or
    $environment.properties.publicNetworkAccess -ne 'Disabled' -or $environment.properties.provisioningState -ne 'Succeeded') {
    throw 'Worker SandboxGroup must be linked to its own private Express environment.'
}
$endpoint = & az network private-endpoint show -g $ResourceGroup -n "pe-$SandboxGroupName" -o json | ConvertFrom-Json
if (-not ($endpoint.privateLinkServiceConnections | Where-Object {
    $_.privateLinkServiceId -eq $environment.id -and $_.privateLinkServiceConnectionState.status -eq 'Approved'
})) { throw 'Sandbox Private Endpoint is not approved.' }
$gatewayEnvironment = & az containerapp env show --ids $gatewayApp.properties.environmentId -o json | ConvertFrom-Json
$gatewaySubnet = $gatewayEnvironment.properties.vnetConfiguration.infrastructureSubnetId
if (-not $gatewaySubnet) { throw 'Gateway environment has no VNet integration.' }
$gatewayVnetId = $gatewaySubnet.Substring(0, $gatewaySubnet.LastIndexOf('/subnets/', [StringComparison]::OrdinalIgnoreCase))
$dnsLink = & az network private-dns link vnet show -g $ResourceGroup -z "privatelink.$Location.azurecontainerapps.io" -n $SandboxGroupName -o json | ConvertFrom-Json
if ($dnsLink.virtualNetwork.id -ne $gatewayVnetId) { throw 'Sandbox DNS zone is not linked to the Gateway VNet.' }
$workers = @(& aca sandbox list @groupContext -l app=pizzakoordinator-worker -o json | ConvertFrom-Json | Where-Object state -eq 'Running')
if ($workers.Count -ne 1) { throw 'Expected exactly one running Worker Sandbox.' }
$worker = & aca sandbox get @groupContext --id $workers[0].id -o json | ConvertFrom-Json
$workerUrl = Assert-WorkerSandbox -Sandbox $worker
$configuredUrl = ($gatewayApp.properties.template.containers[0].env | Where-Object name -eq 'Gateway__WorkerUrl').value
if ($configuredUrl -ne $workerUrl) { throw 'Gateway does not target the running Worker Sandbox port URL.' }
$url = "https://$($gatewayApp.properties.configuration.ingress.fqdn)"
if ((Invoke-RestMethod "$url/health" -TimeoutSec 30) -ne 'Healthy') { throw 'Gateway health check failed.' }
if ((Invoke-RestMethod "$url/health/ready" -TimeoutSec 30) -ne 'Healthy') { throw 'Gateway cannot reach the Worker over Private Link with its managed identity.' }
$unauthorized = Invoke-WebRequest "$url/v1/deliveries" -SkipHttpErrorCheck -TimeoutSec 30
if ([int]$unauthorized.StatusCode -ne 401) { throw "Unauthenticated tools returned $($unauthorized.StatusCode), expected 401." }

# DMZ boundary: the Gateway carries neither blueprint credentials nor the Worker identity, and its identity only pulls images.
$identity = & az identity show -g $ResourceGroup -n id-pizzakoordinator -o json | ConvertFrom-Json
$gatewayIdentity = & az identity show -g $ResourceGroup -n id-pizzakoordinator-gateway -o json | ConvertFrom-Json
$workerIdentities = @($group.identity.userAssignedIdentities.PSObject.Properties.Name)
if ($workerIdentities.Count -ne 1 -or $workerIdentities[0] -ne $identity.id -or $group.identity.type -ne 'UserAssigned') {
    throw 'SandboxGroup must carry only the Worker user-assigned identity.'
}
if ($gatewayApp.identity.userAssignedIdentities.PSObject.Properties.Name -contains $identity.id) { throw 'Gateway must not carry the Worker identity.' }
if ($gatewayApp.properties.template.containers[0].env.name -match '^AzureAd__ClientCredentials') { throw 'Gateway must not hold blueprint credentials.' }
$blueprintId = ($gatewayApp.properties.template.containers[0].env | Where-Object name -eq 'AzureAd__ClientId').value
if ([string]::IsNullOrWhiteSpace($blueprintId)) { throw 'Gateway has no Agent 365 blueprint client ID.' }
$blueprintSp = & az ad sp show --id $blueprintId --query id -o tsv
$messagingResource = & az ad sp show --id '5a807f24-c9de-44ee-a3a7-329e88a00ffc' --query id -o tsv
if ([string]::IsNullOrWhiteSpace($blueprintSp) -or [string]::IsNullOrWhiteSpace($messagingResource)) {
    throw 'Blueprint or Messaging Bot API service principal was not found.'
}
$grantPage = & az rest --method GET --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$blueprintSp'" | ConvertFrom-Json
$inheritance = & az rest --method GET --url "https://graph.microsoft.com/beta/applications/$blueprintId/microsoft.graph.agentIdentityBlueprint/inheritablePermissions" | ConvertFrom-Json
Assert-Agent365MessagingGrant -Grants $grantPage -Inheritance $inheritance -MessagingResourceId $messagingResource
$gatewayRoles = & az role assignment list --assignee $gatewayIdentity.principalId --all --query '[].roleDefinitionName' -o json | ConvertFrom-Json
if (@($gatewayRoles | Where-Object { $_ -ne 'AcrPull' }).Count -gt 0) { throw "Gateway identity has unexpected roles: $($gatewayRoles -join ', ')." }

$projectId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/ai-pizza-22df-k5ihazv/projects/pizza-ordering-agent"
$registryId = & az acr show -n crpizza22dfk5ihazv --query id -o tsv
foreach ($required in @(@($projectId, 'Foundry User'), @($registryId, 'AcrPull'))) {
    $roles = & az role assignment list --scope $required[0] -o json | ConvertFrom-Json
    if (-not ($roles | Where-Object { $_.principalId -eq $identity.principalId -and $_.roleDefinitionName -eq $required[1] })) {
        throw "Missing role $($required[1]) at $($required[0])."
    }
}

Push-Location (Join-Path $root '.local\foundry-deploy')
$previousUserAgent = $env:AZURE_DEV_USER_AGENT
$previousAlpha = $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS
try {
    $env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
    $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS = 'true'
    $agent = & azd ai agent show --output json | ConvertFrom-Json
    if ($agent.versions.latest.status -ne 'active' -or @($agent.versions.latest.definition.skills).Count -ne 3) {
        throw 'Expected an active agent with three skills.'
    }
    $openApi = @($agent.versions.latest.definition.tools | Where-Object type -eq 'openapi')
    if ($openApi.Count -ne 1 -or
        $openApi[0].openapi.spec.paths.PSObject.Properties['/v1/meetings'].Value.post.operationId -ne 'scheduleMeeting') {
        throw 'The active agent does not expose the scheduleMeeting operation.'
    }
    $agent | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $root '.local\deployed-agent.json')
    & azd ai agent invoke 'Proved pouze read-only overeni: pouzij nastroj listDeliveries a strucne vypis pocet sledovanych objednavek. Nic neprideluj, nedokonci, neposilej zpravy ani nemen preference.' |
        Tee-Object -FilePath (Join-Path $root '.local\smoke-response.txt')
    $smoke = Get-Content (Join-Path $root '.local\smoke-response.txt') -Raw
    if ($smoke -match '403|401|Forbidden|Unauthorized|selhal|nem.m p.stup|chyba|nelze potvrdit') {
        throw 'Agent response reports a tool access failure; deployment verification is incomplete.'
    }

    $project = & azd ai project show --output json | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($project.endpoint)) { throw 'Foundry project endpoint is missing.' }
    $token = & az account get-access-token --resource 'https://ai.azure.com' --query accessToken -o tsv
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Failed to obtain a Foundry token for tool verification.' }
    $headers = @{ Authorization = "Bearer $token"; 'Foundry-Features' = 'MicrosoftCopilot=V1Preview' }
    try {
        $base = "$($project.endpoint.TrimEnd('/'))/agents/$([Uri]::EscapeDataString($agent.name))/endpoint/protocols/openai"
        $conversation = Invoke-RestMethod "$base/conversations?api-version=v1" -Method Post `
            -Headers $headers -Body '{}' -ContentType 'application/json' -TimeoutSec 60
        if ([string]::IsNullOrWhiteSpace($conversation.id)) { throw 'Foundry did not create a verification conversation.' }
        $body = @{
            conversation = $conversation.id
            input = @(@{ role = 'user'; content = @(@{
                type = 'input_text'
                text = 'Pouzij pouze read-only listDeliveries. Nic neprideluj, nedokonci, neposilej zpravy ani nemen preference.'
            }) })
        } | ConvertTo-Json -Depth 8
        $response = Invoke-RestMethod "$base/responses?api-version=v1" -Method Post `
            -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 120
        Assert-FoundryDeliveryCall -Response $response
    }
    finally {
        Remove-Variable token, headers -ErrorAction SilentlyContinue
    }
}
finally {
    $env:AZURE_DEV_USER_AGENT = $previousUserAgent
    $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS = $previousAlpha
    Pop-Location
}
Write-Host "Verified Gateway: $url; private Sandbox Worker: $($worker.id); auto-suspend/delete disabled; authenticated readiness; Gateway without agent credentials or Sandbox management roles; active agent with three skills and a completed read-only OpenAPI call."
