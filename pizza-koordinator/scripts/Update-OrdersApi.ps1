[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-jjazure-ai-pizza-apps',
    [string]$Registry = 'crpizza22dfk5ihazv',
    [string]$McpTenantId = $env:KOORDINATOR_ORDERS_MCP_TENANT_ID,
    [string]$McpAudience = $env:KOORDINATOR_ORDERS_MCP_AUDIENCE,
    [string]$McpAllowedClientId = $env:KOORDINATOR_ORDERS_AGENT_CLIENT_ID,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $VerifyOnly) {
    & dotnet test (Join-Path $repoRoot 'PizzaOrdering.slnx') --nologo -v q | Out-Host
    $previous = & az containerapp show -g $ResourceGroup -n pizza-orders --query properties.template.containers[0].image -o tsv
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'pizza-koordinator\.local') -Force | Out-Null
    $previous | Set-Content (Join-Path $repoRoot 'pizza-koordinator\.local\orders-previous-image.txt')
    $tag = "koordinator-filter-$(Get-Date -Format yyyyMMddHHmmss)"
    & az acr build --registry $Registry --image "pizza-orders:$tag" --file (Join-Path $repoRoot 'src\Pizza.Orders\Dockerfile') $repoRoot --no-logs --only-show-errors | Out-Host
    $digest = & az acr repository show -n $Registry --image "pizza-orders:$tag" --query digest -o tsv
    $server = & az acr show -n $Registry --query loginServer -o tsv
    $updateArgs = @('-g', $ResourceGroup, '-n', 'pizza-orders', '--image', "$server/pizza-orders@$digest")
    $mcpValues = @($McpTenantId, $McpAudience, $McpAllowedClientId)
    if (@($mcpValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        if (@($mcpValues | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw 'MCP configuration requires tenant ID, audience and allowed agent client ID together.'
        }
        $updateArgs += @('--set-env-vars',
            "Pizza__AgentMcp__TenantId=$McpTenantId",
            "Pizza__AgentMcp__Audience=$McpAudience",
            "Pizza__AgentMcp__AllowedClientId=$McpAllowedClientId")
    }
    # Preserve the application's existing environment, identity, network and SQL settings.
    & az containerapp update @updateArgs -o none
}
$hostName = & az containerapp show -g $ResourceGroup -n pizza-orders --query properties.configuration.ingress.fqdn -o tsv
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $invalid = Invoke-WebRequest "https://$hostName/api/orders/?status=Invalid" -SkipHttpErrorCheck -TimeoutSec 30
    if ([int]$invalid.StatusCode -eq 400) { break }
    Write-Host "Waiting for Orders revision traffic to propagate (HTTP $($invalid.StatusCode))."
    Start-Sleep -Seconds 5
}
if ([int]$invalid.StatusCode -ne 400) { throw 'Deployed Orders API is not binding the status filter.' }
$orders = Invoke-RestMethod "https://$hostName/api/orders/?status=New" -TimeoutSec 30
if (@($orders | Where-Object { $_.status -ne 'New' }).Count -ne 0) { throw 'Status filter returned non-New orders.' }
Write-Host 'Orders API status filter verified.'
if (-not [string]::IsNullOrWhiteSpace($McpAllowedClientId)) {
    $probeBody = @{
        jsonrpc = '2.0'
        id = 1
        method = 'initialize'
        params = @{
            protocolVersion = '2025-03-26'
            capabilities = @{}
            clientInfo = @{ name = 'deployment-auth-probe'; version = '1.0' }
        }
    } | ConvertTo-Json -Depth 6 -Compress
    $mcpProbe = Invoke-WebRequest "https://$hostName/mcp" -Method Post -ContentType 'application/json' `
        -Headers @{ Accept = 'application/json, text/event-stream' } -Body $probeBody `
        -SkipHttpErrorCheck -TimeoutSec 30
    if ([int]$mcpProbe.StatusCode -ne 401) {
        throw "Orders MCP must reject unauthenticated requests with HTTP 401; received $($mcpProbe.StatusCode)."
    }
    Write-Host 'Orders MCP unauthenticated access denied as expected.'
}
