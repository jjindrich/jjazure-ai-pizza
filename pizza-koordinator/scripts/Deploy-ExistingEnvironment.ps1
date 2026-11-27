[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-jjazure-ai-pizza-apps',
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$GatewayImage,
    [string]$WorkerImage,
    [switch]$ReplaceWorker,
    [string]$TenantId = $env:AZURE_TENANT_ID,
    [string]$TeamsAppId = $env:PIZZAKOORDINATOR_TEAMS_APP_ID
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
foreach ($name in @('SubscriptionId', 'TenantId', 'TeamsAppId')) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse((Get-Variable $name -ValueOnly), [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$name must be a non-empty GUID; provide it as a parameter or environment variable."
    }
}
. (Join-Path $PSScriptRoot 'WorkerSandbox.ps1')
Assert-SandboxTools
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$local = Join-Path $root '.local'
New-Item -ItemType Directory -Path $local -Force | Out-Null
Start-Transcript -Path (Join-Path $local "deployment-$(Get-Date -Format yyyyMMddHHmmss).log")
$deployed = $null
try {
    & az account set --subscription $SubscriptionId
    $accountTenantId = & az account show --query tenantId -o tsv
    if ($accountTenantId -ine $TenantId) { throw 'The selected subscription belongs to a different tenant.' }
    $ordersHost = & az containerapp show -g $ResourceGroup -n pizza-orders --query properties.configuration.ingress.fqdn -o tsv
    $filterCheck = Invoke-WebRequest "https://$ordersHost/api/orders/?status=Invalid" -SkipHttpErrorCheck -TimeoutSec 30
    if ([int]$filterCheck.StatusCode -notin @(200, 400)) { throw "Orders API preflight failed: $($filterCheck.StatusCode)." }

    $foundryRoot = Join-Path $root '.local\foundry-deploy'
    $previousUserAgent = $env:AZURE_DEV_USER_AGENT
    $previousAlpha = $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS
    $locationPushed = $false
    try {
        $env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
        $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS = 'true'
        Push-Location $foundryRoot
        $locationPushed = $true
        $agent = & azd ai agent show --output json | ConvertFrom-Json
    }
    finally {
        if ($locationPushed) { Pop-Location }
        $env:AZURE_DEV_USER_AGENT = $previousUserAgent
        $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS = $previousAlpha
    }
    $OrdersAgentClientId = $agent.versions.latest.instance_identity.client_id
    if ($agent.versions.latest.status -ne 'active' -or [string]::IsNullOrWhiteSpace($OrdersAgentClientId)) {
        throw 'The active Foundry agent identity could not be resolved; refusing to configure Orders API access.'
    }
    $ordersMcp = & (Join-Path $PSScriptRoot 'Register-OrdersMcpApi.ps1')
    $OrdersMcpAudience = $ordersMcp.Audience

    & (Join-Path $PSScriptRoot 'Update-OrdersApi.ps1') -ResourceGroup $ResourceGroup `
        -McpTenantId $TenantId -McpAudience $OrdersMcpAudience -McpAllowedClientId $OrdersAgentClientId
    $parameters = @{
        OrdersApiUrl = "https://$ordersHost"; ResourceGroup = $ResourceGroup; SubscriptionId = $SubscriptionId; TenantId = $TenantId
        EnvironmentName = 'cae-pizza-22df'; Registry = 'crpizza22dfk5ihazv'
        FoundryAccount = 'ai-pizza-22df-k5ihazv'; FoundryProject = 'pizza-ordering-agent'
    }
    $prepared = & (Join-Path $PSScriptRoot 'Deploy-PizzaKoordinator.ps1') @parameters -PrepareOnly
    $prepared | ConvertTo-Json | Set-Content (Join-Path $local 'prepared.json')
    & (Join-Path $PSScriptRoot 'Register-PizzaKoordinator.ps1') `
        -MessagingEndpoint $prepared.MessagingEndpoint -WorkerIdentityPrincipalId $prepared.WorkerIdentityPrincipalId `
        -TenantId $TenantId -TeamsAppId $TeamsAppId
    $blueprint = (Get-Content (Join-Path $root 'a365.generated.config.json') -Raw | ConvertFrom-Json).agentBlueprintId
    $deployed = & (Join-Path $PSScriptRoot 'Deploy-PizzaKoordinator.ps1') @parameters -BlueprintId $blueprint `
        -GatewayImage $GatewayImage -WorkerImage $WorkerImage -ReplaceWorker:$ReplaceWorker
    $deployed | ConvertTo-Json | Set-Content (Join-Path $local 'deployment-output.json')
    $projectId = & az resource show --ids "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/ai-pizza-22df-k5ihazv/projects/pizza-ordering-agent" `
        --api-version 2025-06-01 --query id -o tsv
    & (Join-Path $PSScriptRoot 'Deploy-FoundryAgent.ps1') -ProjectEndpoint $deployed.FoundryEndpoint `
        -ApiUrl $deployed.ApiUrl -OrdersMcpUrl "https://$ordersHost/mcp" -ApiAudience $deployed.ToolAudience `
        -OrdersMcpAudience $OrdersMcpAudience -ProjectId $projectId `
        -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -TenantId $TenantId
    $health = Invoke-RestMethod "$($deployed.ApiUrl)/health" -TimeoutSec 30
    if ($health -ne 'Healthy') { throw "Gateway is not healthy: $health" }
    & (Join-Path $PSScriptRoot 'Verify-Deployment.ps1') -ResourceGroup $ResourceGroup -SubscriptionId $SubscriptionId
}
catch {
    $deploymentError = $_
    if ($deployed -and $deployed.PreviousGatewayRevision) {
        try {
            Restore-LegacyPoller -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -GatewayAppName 'ca-pizzakoordinator' `
                -GatewayRevision $deployed.PreviousGatewayRevision -SandboxGroupName 'sbg-pizzakoordinator' `
                -WorkerSandboxId $deployed.WorkerSandboxId -WorkerIdentityName 'id-pizzakoordinator' `
                -GatewayIdentityName 'id-pizzakoordinator-gateway' -Registry 'crpizza22dfk5ihazv'
        }
        catch {
            throw "Post-deployment validation failed ($deploymentError), and restoring the prior poller also failed: $_"
        }
    }
    throw $deploymentError
}
finally { Stop-Transcript }
