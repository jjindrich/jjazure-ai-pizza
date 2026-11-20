param(
    [Parameter(Mandatory = $true)]
    [Uri]$ProjectEndpoint,

    [Parameter(Mandatory = $true)]
    [Uri]$ApiUrl,

    [Parameter(Mandatory = $true)]
    [string]$ApiAudience,

    [string]$ModelDeployment = 'gpt-5-mini',

    [string]$EnvironmentName = 'pizzaops',
    [string]$ProjectId,
    [string]$SubscriptionId,
    [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$foundryRoot = Join-Path $repoRoot 'foundry\pizzaops'
$skillRoot = Join-Path $repoRoot 'foundry-skills'

$skills = @(
    'pizza-delivery-planning',
    'meeting-calendar-coordination',
    'autonomous-task-continuation',
    'human-approval-and-policy'
)

$previousAlpha = $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS
$previousUserAgent = $env:AZURE_DEV_USER_AGENT
try {
    $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS = 'true'
    $env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'

    Push-Location $foundryRoot
    try {
        if (-not (Test-Path (Join-Path $foundryRoot '.azure\config.json'))) {
            & azd env new $EnvironmentName --no-prompt
            if ($LASTEXITCODE -ne 0) {
                throw "Could not create azd environment '$EnvironmentName'."
            }
        }
    }
    finally {
        Pop-Location
    }

    Push-Location $foundryRoot
    try {
        $connectionJson = & azd ai connection show pizzaops-openapi `
            --project-endpoint $ProjectEndpoint.AbsoluteUri `
            --output json 2>$null
    }
    finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        Push-Location $foundryRoot
        try {
            & azd ai connection create pizzaops-openapi `
                --kind openapi `
                --target $ApiUrl.AbsoluteUri.TrimEnd('/') `
                --auth-type project-managed-identity `
                --audience $ApiAudience `
                --project-endpoint $ProjectEndpoint.AbsoluteUri `
                --output json
            if ($LASTEXITCODE -ne 0) {
                throw 'Could not create the Foundry OpenAPI project-managed-identity connection.'
            }
        }
        finally {
            Pop-Location
        }
    }
    Push-Location $foundryRoot
    try {
        $connectionJson = & azd ai connection show pizzaops-openapi `
            --project-endpoint $ProjectEndpoint.AbsoluteUri `
            --output json
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not read the Foundry OpenAPI connection.'
        }
    }
    finally {
        Pop-Location
    }
    $connectionId = (($connectionJson -join "`n") | ConvertFrom-Json).id

    foreach ($skill in $skills) {
        Push-Location $foundryRoot
        try {
            $existingSkill = & azd ai skill show $skill `
                --project-endpoint $ProjectEndpoint.AbsoluteUri `
                --output json 2>$null
        }
        finally {
            Pop-Location
        }
        if ($LASTEXITCODE -eq 0) {
            $existing = ($existingSkill -join "`n") | ConvertFrom-Json
            $existingVersion = ($existing.default_version ?? $existing.latest_version).ToString()
            if ($existingVersion -ne '1') {
                throw "Foundry Skill '$skill' exists at version '$existingVersion', but this source manifest pins version 1. Update the pin deliberately before deployment."
            }
            Write-Host "Reusing Foundry Skill '$skill' version 1."
            continue
        }

        Push-Location $foundryRoot
        try {
            & azd ai skill create $skill `
                --file (Join-Path $skillRoot $skill) `
                --project-endpoint $ProjectEndpoint.AbsoluteUri `
                --output json
            if ($LASTEXITCODE -ne 0) {
                throw "Could not create Foundry Skill '$skill'."
            }
        }
        finally {
            Pop-Location
        }
    }

    Push-Location $foundryRoot
    try {
        & azd env set AZURE_AI_PROJECT_ENDPOINT $ProjectEndpoint.AbsoluteUri
        & azd env set FOUNDRY_PROJECT_ENDPOINT $ProjectEndpoint.AbsoluteUri
        if ($ProjectId) {
            & azd env set AZURE_AI_PROJECT_ID $ProjectId
        }
        if ($SubscriptionId) {
            & azd env set AZURE_SUBSCRIPTION_ID $SubscriptionId
        }
        if ($ResourceGroup) {
            & azd env set AZURE_RESOURCE_GROUP $ResourceGroup
        }
        & azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME $ModelDeployment
        & azd env set PIZZAOPS_API_URL $ApiUrl.AbsoluteUri.TrimEnd('/')
        & azd env set PIZZAOPS_API_AUDIENCE $ApiAudience
        & azd env set PIZZAOPS_OPENAPI_CONNECTION_ID $connectionId
        & azd env set PIZZAOPS_MODEL_DEPLOYMENT $ModelDeployment

        & azd deploy pizzaops-agent --no-prompt
        if ($LASTEXITCODE -ne 0) {
            throw 'PizzaOps agent deployment failed.'
        }

        & azd ai agent show --output json
        if ($LASTEXITCODE -ne 0) {
            throw 'The deployed PizzaOps agent could not be read back.'
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($null -eq $previousAlpha) {
        Remove-Item Env:\AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS -ErrorAction SilentlyContinue
    }
    else {
        $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS = $previousAlpha
    }

    if ($null -eq $previousUserAgent) {
        Remove-Item Env:\AZURE_DEV_USER_AGENT -ErrorAction SilentlyContinue
    }
    else {
        $env:AZURE_DEV_USER_AGENT = $previousUserAgent
    }
}
