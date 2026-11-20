[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Uri]$ProjectEndpoint,
    [Parameter(Mandatory = $true)]
    [Uri]$ApiUrl,
    [Parameter(Mandatory = $true)]
    [string]$ApiAudience,
    [string]$ModelDeployment = 'gpt-5-mini',
    [string]$EnvironmentName = 'pizzakoordinator'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$koordinatorRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$foundryRoot = Join-Path $koordinatorRoot 'foundry\pizzakoordinator'
$skillRoot = Join-Path $koordinatorRoot 'foundry-skills'
$endpoint = $ProjectEndpoint.AbsoluteUri.TrimEnd('/')

$env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS = 'true'
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
Push-Location $foundryRoot
try {
    if (-not (Test-Path '.azure\config.json')) { & azd env new $EnvironmentName --no-prompt }

    $PSNativeCommandUseErrorActionPreference = $false
    $connection = & azd ai connection show pizzakoordinator-openapi --project-endpoint $endpoint --output json 2>$null
    $PSNativeCommandUseErrorActionPreference = $true
    if ($LASTEXITCODE -ne 0) {
        $connection = & azd ai connection create pizzakoordinator-openapi --kind openapi --target $ApiUrl.AbsoluteUri.TrimEnd('/') `
            --auth-type project-managed-identity --audience $ApiAudience --project-endpoint $endpoint --output json
    }
    $connectionId = (($connection -join "`n") | ConvertFrom-Json).id

    # Skills are created only when missing; courier-preferences keeps whatever version the admin approved last.
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
    foreach ($skill in 'delivery-coordination', 'preference-change-approval') {
        if ($versions[$skill] -ne '1') { throw "Skill '$skill' is at version $($versions[$skill]); azure.yaml pins version 1." }
    }

    & azd env set AZURE_AI_PROJECT_ENDPOINT $endpoint
    & azd env set FOUNDRY_PROJECT_ENDPOINT $endpoint
    & azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $ModelDeployment
    & azd env set KOORDINATOR_MODEL_DEPLOYMENT $ModelDeployment
    & azd env set KOORDINATOR_API_URL $ApiUrl.AbsoluteUri.TrimEnd('/')
    & azd env set KOORDINATOR_OPENAPI_CONNECTION_ID $connectionId
    & azd env set COURIER_PREFERENCES_SKILL_VERSION $versions['courier-preferences']

    & azd deploy pizza-koordinator-agent --no-prompt
    & azd ai agent show --output json
}
finally {
    Pop-Location
    Remove-Item Env:\AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS, Env:\AZURE_DEV_USER_AGENT -ErrorAction SilentlyContinue
}
