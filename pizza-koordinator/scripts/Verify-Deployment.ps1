[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-jjazure-ai-pizza-apps'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$hostName = & az containerapp show -g $ResourceGroup -n ca-pizzakoordinator --query properties.configuration.ingress.fqdn -o tsv
$url = "https://$hostName"
if ((Invoke-RestMethod "$url/health" -TimeoutSec 30) -ne 'Healthy') { throw 'Bridge health check failed.' }
$unauthorized = Invoke-WebRequest "$url/v1/deliveries" -SkipHttpErrorCheck -TimeoutSec 30
if ([int]$unauthorized.StatusCode -ne 401) { throw "Unauthenticated tools returned $($unauthorized.StatusCode), expected 401." }

$identity = & az identity show -g $ResourceGroup -n id-pizzakoordinator -o json | ConvertFrom-Json
$projectId = "/subscriptions/80214fc0-7aff-43b6-bbff-cf81a36cbb10/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/ai-pizza-22df-k5ihazv/projects/pizza-ordering-agent"
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
    $agent | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $root '.local\deployed-agent.json')
    & azd ai agent invoke 'Proved pouze read-only overeni: pouzij nastroj listDeliveries a strucne vypis pocet sledovanych objednavek. Nic neprideluj, nedokonci, neposilej zpravy ani nemen preference.' |
        Tee-Object -FilePath (Join-Path $root '.local\smoke-response.txt')
    $smoke = Get-Content (Join-Path $root '.local\smoke-response.txt') -Raw
    if ($smoke -match '403|401|Forbidden|Unauthorized|selhal|nem.m p.stup') {
        throw 'Agent response reports a tool access failure; deployment verification is incomplete.'
    }
}
finally {
    $env:AZURE_DEV_USER_AGENT = $previousUserAgent
    $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS = $previousAlpha
    Pop-Location
}
Write-Host "Verified bridge: $url; unauthenticated tools: 401; scoped RBAC; active agent with three skills."
