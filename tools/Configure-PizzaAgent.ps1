param(
    [Parameter(Mandatory)][string]$ProjectEndpoint,
    [Parameter(Mandatory)][string]$ProjectResourceId,
    [Parameter(Mandatory)][string]$CatalogOrigin,
    [Parameter(Mandatory)][string]$OrdersOrigin,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,62}$')]
    [string]$AgentName = 'pizza-ordering-agent-copilot'
)

$ErrorActionPreference = 'Stop'
foreach ($origin in @($CatalogOrigin, $OrdersOrigin)) {
    $uri = [uri]$origin
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or
        $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
        throw 'Catalog and Orders must be verified HTTPS origins.'
    }
}
if ($ProjectResourceId -notmatch '^/subscriptions/80214fc0-7aff-43b6-bbff-cf81a36cbb10/resourceGroups/rg-jjazure-ai-pizza-apps/providers/Microsoft.CognitiveServices/accounts/([^/]+)/projects/pizza-ordering-agent$') {
    throw 'Project must belong to the explicitly approved new subscription/resource group.'
}
$accountName = $Matches[1]
$expectedEndpoint = "https://$accountName.services.ai.azure.com/api/projects/pizza-ordering-agent"
if ($ProjectEndpoint.TrimEnd('/') -ne $expectedEndpoint) {
    throw 'Project endpoint does not match its approved ARM resource.'
}
$root = Split-Path $PSScriptRoot -Parent
$json = Get-Content (Join-Path $root 'agent\pizza-agent.template.json') -Raw
$json = $json.Replace('__AGENT_NAME__', $AgentName).
    Replace('__CATALOG_URL__', $CatalogOrigin.TrimEnd('/')).
    Replace('__ORDERS_URL__', $OrdersOrigin.TrimEnd('/')).
    Replace('__PROJECT_ID__', $ProjectResourceId)
$definition = $json | ConvertFrom-Json
if ($definition.definition.kind -ne 'prompt' -or
    $definition.definition.harness.type -ne 'microsoft_copilot_preview' -or
    $definition.definition.tools.Count -ne 3 -or
    $definition.definition.tools[0].type -ne 'microsoft_copilot_toolset_preview' -or
    $definition.definition.tools[0].default_config.enabled -ne $false -or
    $definition.definition.skills.Count -ne 1 -or
    $definition.definition.skills[0].name -ne 'pizza-ordering-guidance' -or
    $definition.definition.skills[0].version -ne '1' -or
    $json -match '__[A-Z_]+__') {
    throw 'Agent rendering failed or left unresolved template tokens.'
}
$output = Join-Path $root '.azure\rendered-agent.json'
New-Item -ItemType Directory -Path (Split-Path $output -Parent) -Force | Out-Null
[System.IO.File]::WriteAllText($output, $json)
az rest --method post --url "$expectedEndpoint/agents?api-version=v1" `
    --resource https://ai.azure.com --body "@$output" `
    --headers 'Foundry-Features=MicrosoftCopilot=V1Preview' `
    --query '{id:id,name:name,version:version,versions:versions}' -o json
if ($LASTEXITCODE -ne 0) {
    throw 'Foundry did not confirm agent creation; do not assume the agent is ready.'
}
