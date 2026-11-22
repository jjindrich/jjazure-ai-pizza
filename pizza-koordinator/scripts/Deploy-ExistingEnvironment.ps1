[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-jjazure-ai-pizza-apps',
    [string]$SubscriptionId = '80214fc0-7aff-43b6-bbff-cf81a36cbb10',
    [string]$Image
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$local = Join-Path $root '.local'
New-Item -ItemType Directory -Path $local -Force | Out-Null
Start-Transcript -Path (Join-Path $local "deployment-$(Get-Date -Format yyyyMMddHHmmss).log")
try {
    & az account set --subscription $SubscriptionId
    $ordersHost = & az containerapp show -g $ResourceGroup -n pizza-orders --query properties.configuration.ingress.fqdn -o tsv
    $filterCheck = Invoke-WebRequest "https://$ordersHost/api/orders/?status=Invalid" -SkipHttpErrorCheck -TimeoutSec 30
    if ([int]$filterCheck.StatusCode -eq 200) {
        & (Join-Path $PSScriptRoot 'Update-OrdersApi.ps1') -ResourceGroup $ResourceGroup
    }
    elseif ([int]$filterCheck.StatusCode -ne 400) { throw "Orders API preflight failed: $($filterCheck.StatusCode)." }
    $parameters = @{
        OrdersApiUrl = "https://$ordersHost"; ResourceGroup = $ResourceGroup; SubscriptionId = $SubscriptionId
        EnvironmentName = 'cae-pizza-22df'; Registry = 'crpizza22dfk5ihazv'
        FoundryAccount = 'ai-pizza-22df-k5ihazv'; FoundryProject = 'pizza-ordering-agent'
    }
    $prepared = & (Join-Path $PSScriptRoot 'Deploy-PizzaKoordinator.ps1') @parameters -PrepareOnly
    $prepared | ConvertTo-Json | Set-Content (Join-Path $local 'prepared.json')
    & (Join-Path $PSScriptRoot 'Register-PizzaKoordinator.ps1') `
        -MessagingEndpoint $prepared.MessagingEndpoint -BridgeIdentityPrincipalId $prepared.BridgeIdentityPrincipalId
    $blueprint = (Get-Content (Join-Path $root 'a365.generated.config.json') -Raw | ConvertFrom-Json).agentBlueprintId
    $deployed = & (Join-Path $PSScriptRoot 'Deploy-PizzaKoordinator.ps1') @parameters -BlueprintId $blueprint -Image $Image
    $deployed | ConvertTo-Json | Set-Content (Join-Path $local 'deployment-output.json')
    $projectId = & az resource show --ids "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/ai-pizza-22df-k5ihazv/projects/pizza-ordering-agent" `
        --api-version 2025-06-01 --query id -o tsv
    & (Join-Path $PSScriptRoot 'Deploy-FoundryAgent.ps1') -ProjectEndpoint $deployed.FoundryEndpoint `
        -ApiUrl $deployed.ApiUrl -ApiAudience $deployed.ToolAudience -ProjectId $projectId `
        -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup
    $health = Invoke-RestMethod "$($deployed.ApiUrl)/health" -TimeoutSec 30
    if ($health -ne 'Healthy') { throw "Bridge is not healthy: $health" }
    & (Join-Path $PSScriptRoot 'Verify-Deployment.ps1') -ResourceGroup $ResourceGroup
}
finally { Stop-Transcript }
