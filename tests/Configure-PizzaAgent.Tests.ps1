$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "pizza-agent-config-test-$([guid]::NewGuid().ToString('N'))"
$global:ConfigureTest = @{
    Subscription = [guid]::NewGuid().ToString()
    AccountSubscription = $null
    Calls = [System.Collections.Generic.List[string]]::new()
    Definition = $null
}
$global:ConfigureTest.AccountSubscription = $global:ConfigureTest.Subscription

function global:az {
    $global:LASTEXITCODE = 0
    $global:ConfigureTest.Calls.Add(($args -join ' '))
    if ($args[0] -eq 'account' -and $args[1] -eq 'show') { return $global:ConfigureTest.AccountSubscription }
    if ($args[0] -eq 'rest') {
        $bodyIndex = [array]::IndexOf($args, '--body')
        $global:ConfigureTest.Definition = Get-Content ($args[$bodyIndex + 1].Substring(1)) -Raw | ConvertFrom-Json
        return '{"name":"pizza-ordering-agent-copilot"}'
    }
    throw "Unexpected Azure CLI call: $args"
}

try {
    New-Item -ItemType Directory -Path (Join-Path $testRoot 'tools'), (Join-Path $testRoot 'agent') -Force | Out-Null
    Copy-Item (Join-Path $repoRoot 'tools\Configure-PizzaAgent.ps1') (Join-Path $testRoot 'tools')
    Copy-Item (Join-Path $repoRoot 'agent\pizza-agent.template.json') (Join-Path $testRoot 'agent')
    $script = Join-Path $testRoot 'tools\Configure-PizzaAgent.ps1'
    $parameters = @{
        SubscriptionId = $global:ConfigureTest.Subscription
        ProjectResourceId = "/subscriptions/$($global:ConfigureTest.Subscription)/resourceGroups/rg-jjazure-ai-pizza-apps/providers/Microsoft.CognitiveServices/accounts/example/projects/pizza-ordering-agent"
        ProjectEndpoint = 'https://example.services.ai.azure.com/api/projects/pizza-ordering-agent'
        CatalogOrigin = 'https://catalog.example.test'
        OrdersOrigin = 'https://orders.example.test'
    }

    $wrongProject = $parameters.Clone()
    $wrongProject.ProjectResourceId = $wrongProject.ProjectResourceId.Replace($parameters.SubscriptionId, [guid]::NewGuid().ToString())
    $failed = $false
    try { & $script @wrongProject } catch { $failed = $true }
    if (-not $failed -or $global:ConfigureTest.Calls.Count -ne 0) {
        throw 'A project in another subscription must be rejected before invoking Azure CLI.'
    }

    $global:ConfigureTest.AccountSubscription = [guid]::NewGuid().ToString()
    $failed = $false
    try { & $script @parameters } catch { $failed = $true }
    if (-not $failed -or $global:ConfigureTest.Definition -or (Test-Path (Join-Path $testRoot '.azure\rendered-agent.json'))) {
        throw 'A different selected subscription must be rejected before rendering or posting.'
    }

    $global:ConfigureTest.AccountSubscription = $parameters.SubscriptionId
    & $script @parameters | Out-Null
    $definition = $global:ConfigureTest.Definition
    if (-not $definition -or
        $definition.definition.tools[1].openapi.auth.security_scheme.project_connection_id -ne "$($parameters.ProjectResourceId)/connections/pizza-catalog" -or
        $definition.definition.tools[2].openapi.auth.security_scheme.project_connection_id -ne "$($parameters.ProjectResourceId)/connections/pizza-orders") {
        throw 'The verified project ID must be used for both generated connections.'
    }
    'Pizza agent subscription guard checks passed.'
}
finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Variable ConfigureTest -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
