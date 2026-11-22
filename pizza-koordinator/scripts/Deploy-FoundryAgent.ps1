[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Uri]$ProjectEndpoint,
    [Parameter(Mandatory = $true)]
    [Uri]$ApiUrl,
    [Parameter(Mandatory = $true)]
    [string]$ApiAudience,
    [string]$ModelDeployment = 'gpt-5-mini',
    [string]$EnvironmentName = 'pizzakoordinator',
    [Parameter(Mandatory = $true)]
    [string]$ProjectId,
    [string]$SubscriptionId = '80214fc0-7aff-43b6-bbff-cf81a36cbb10',
    [string]$ResourceGroup = 'rg-jjazure-ai-pizza-apps',
    [string]$Location = 'swedencentral',
    [string]$TenantId = 'b48accae-439a-467a-9fbf-8ad011508424'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$koordinatorRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourceManifest = Join-Path $koordinatorRoot 'foundry\pizzakoordinator\azure.yaml'
$foundryRoot = Join-Path $koordinatorRoot '.local\foundry-deploy'
New-Item -ItemType Directory -Path $foundryRoot -Force | Out-Null
Copy-Item $sourceManifest (Join-Path $foundryRoot 'azure.yaml')
$skillRoot = Join-Path $koordinatorRoot 'foundry-skills'
$endpoint = $ProjectEndpoint.AbsoluteUri.TrimEnd('/')

$env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS = 'true'
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
Push-Location $foundryRoot
try {
    if (-not (Test-Path '.azure\config.json')) { & azd env new $EnvironmentName --no-prompt }
    & azd env set AZURE_SUBSCRIPTION_ID $SubscriptionId
    & azd env set AZURE_RESOURCE_GROUP $ResourceGroup
    & azd env set AZURE_LOCATION $Location
    & azd env set AZURE_TENANT_ID $TenantId
    & azd env set AZURE_AI_PROJECT_ID $ProjectId

    $PSNativeCommandUseErrorActionPreference = $false
    $connection = & azd ai connection show pizzakoordinator-openapi --project-endpoint $endpoint --output json 2>$null
    $PSNativeCommandUseErrorActionPreference = $true
    if ($LASTEXITCODE -ne 0) {
        $connection = & azd ai connection create pizzakoordinator-openapi --kind openapi --target $ApiUrl.AbsoluteUri.TrimEnd('/') `
            --auth-type project-managed-identity --audience $ApiAudience --project-endpoint $endpoint --output json
        $connection = & azd ai connection show pizzakoordinator-openapi --project-endpoint $endpoint --output json
    }
    $connectionId = (($connection -join "`n") | ConvertFrom-Json).id
    if ([string]::IsNullOrWhiteSpace($connectionId)) { throw 'The OpenAPI connection returned no resource ID.' }

    # Skills are created only when missing; the agent uses each skill's default version
    # (courier-preferences keeps whatever version the admin approved last).
    $versions = @{}
    foreach ($skill in 'courier-preferences', 'delivery-coordination', 'preference-change-approval') {
        $PSNativeCommandUseErrorActionPreference = $false
        $existing = & azd ai skill show $skill --project-endpoint $endpoint --output json 2>$null
        $PSNativeCommandUseErrorActionPreference = $true
        if ($LASTEXITCODE -ne 0) {
            & azd ai skill create $skill --file (Join-Path $skillRoot $skill) --project-endpoint $endpoint --output json | Out-Null
            $existing = & azd ai skill show $skill --project-endpoint $endpoint --output json
        }
        $info = ($existing -join "`n") | ConvertFrom-Json
        $versions[$skill] = ($info.default_version ?? $info.latest_version).ToString()
    }
    # azd does not expand environment references in skill versions.
    (Get-Content $sourceManifest -Raw).
        Replace('${COURIER_PREFERENCES_SKILL_VERSION}', $versions['courier-preferences']).
        Replace('${DELIVERY_COORDINATION_SKILL_VERSION}', $versions['delivery-coordination']).
        Replace('${PREFERENCE_CHANGE_APPROVAL_SKILL_VERSION}', $versions['preference-change-approval']) |
        Set-Content (Join-Path $foundryRoot 'azure.yaml')

    & azd env set AZURE_AI_PROJECT_ENDPOINT $endpoint
    & azd env set FOUNDRY_PROJECT_ENDPOINT $endpoint
    & azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $ModelDeployment
    & azd env set KOORDINATOR_MODEL_DEPLOYMENT $ModelDeployment
    & azd env set KOORDINATOR_API_URL $ApiUrl.AbsoluteUri.TrimEnd('/')
    & azd env set KOORDINATOR_OPENAPI_CONNECTION_ID $connectionId
    & azd env set COURIER_PREFERENCES_SKILL_VERSION $versions['courier-preferences']
    & azd env set DELIVERY_COORDINATION_SKILL_VERSION $versions['delivery-coordination']
    & azd env set PREFERENCE_CHANGE_APPROVAL_SKILL_VERSION $versions['preference-change-approval']

    & azd deploy pizza-koordinator-agent --no-prompt
    & azd ai agent show --output json
}
finally {
    Pop-Location
    Remove-Item Env:\AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS, Env:\AZURE_DEV_USER_AGENT -ErrorAction SilentlyContinue
}
