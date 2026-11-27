$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "koordinator-deploy-test-$([guid]::NewGuid().ToString('N'))"
$scripts = Join-Path $testRoot 'scripts'
$global:DeploymentTest = @{
    Subscription = [guid]::NewGuid().ToString()
    Tenant = [guid]::NewGuid().ToString()
    AccountTenant = $null
    TeamsApp = [guid]::NewGuid().ToString()
    Blueprint = [guid]::NewGuid().ToString()
    AgentClient = [guid]::NewGuid().ToString()
    Calls = [System.Collections.Generic.List[object]]::new()
    AzCalls = 0
}
$global:DeploymentTest.AccountTenant = $global:DeploymentTest.Tenant

function global:az {
    $global:DeploymentTest.AzCalls++
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'account' -and $args[1] -eq 'set') { return }
    if ($args[0] -eq 'account' -and $args[1] -eq 'show') { return $global:DeploymentTest.AccountTenant }
    if ($args[0] -eq 'containerapp' -and $args[1] -eq 'show') { return 'orders.example.test' }
    if ($args[0] -eq 'resource' -and $args[1] -eq 'show') {
        return "/subscriptions/$($global:DeploymentTest.Subscription)/resourceGroups/rg-jjazure-ai-pizza-apps/providers/Microsoft.CognitiveServices/accounts/example/projects/example"
    }
    throw "Unexpected Azure CLI call: $args"
}
function global:azd {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'ai' -and $args[1] -eq 'agent' -and $args[2] -eq 'show') {
        return (@{ versions = @{ latest = @{ status = 'active'; instance_identity = @{ client_id = $global:DeploymentTest.AgentClient } } } } | ConvertTo-Json -Depth 5)
    }
    throw "Unexpected azd call: $args"
}
function global:Invoke-WebRequest { param($Uri, [switch]$SkipHttpErrorCheck, $TimeoutSec) return [pscustomobject]@{ StatusCode = 400 } }
function global:Invoke-RestMethod { param($Uri, $TimeoutSec) return 'Healthy' }
function global:Start-Transcript { param($Path) }
function global:Stop-Transcript {}

try {
    New-Item -ItemType Directory -Path $scripts, (Join-Path $testRoot '.local\foundry-deploy') -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot '..\scripts\Deploy-ExistingEnvironment.ps1') $scripts
    $stubs = @{
        'WorkerSandbox.ps1' = @'
function Assert-SandboxTools {}
function Restore-LegacyPoller { throw 'Unexpected rollback.' }
'@
        'Register-OrdersMcpApi.ps1' = @'
[pscustomobject]@{ Audience = 'api://orders-test' }
'@
        'Update-OrdersApi.ps1' = @'
param($ResourceGroup, $McpTenantId, $McpAudience, $McpAllowedClientId)
$global:DeploymentTest.Calls.Add(@{ Kind = 'Orders'; Tenant = $McpTenantId })
'@
        'Deploy-PizzaKoordinator.ps1' = @'
param($OrdersApiUrl, $ResourceGroup, $SubscriptionId, $TenantId, $EnvironmentName, $Registry, $FoundryAccount, $FoundryProject, [switch]$PrepareOnly, $BlueprintId, $GatewayImage, $WorkerImage, [switch]$ReplaceWorker)
$kind = if ($PrepareOnly) { 'Prepare' } else { 'Deploy' }
$global:DeploymentTest.Calls.Add(@{ Kind = $kind; Tenant = $TenantId; Subscription = $SubscriptionId })
[pscustomobject]@{ MessagingEndpoint = 'https://gateway.example.test/api/messages'; WorkerIdentityPrincipalId = 'worker'; FoundryEndpoint = 'https://foundry.example.test'; ApiUrl = 'https://gateway.example.test'; ToolAudience = 'api://tool-test' }
'@
        'Register-PizzaKoordinator.ps1' = @'
param($MessagingEndpoint, $WorkerIdentityPrincipalId, $TenantId, $TeamsAppId)
$global:DeploymentTest.Calls.Add(@{ Kind = 'Register'; Tenant = $TenantId; TeamsApp = $TeamsAppId })
@{ agentBlueprintId = $global:DeploymentTest.Blueprint } | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot '..\a365.generated.config.json')
'@
        'Deploy-FoundryAgent.ps1' = @'
param($ProjectEndpoint, $ApiUrl, $OrdersMcpUrl, $ApiAudience, $OrdersMcpAudience, $ProjectId, $SubscriptionId, $ResourceGroup, $TenantId)
$global:DeploymentTest.Calls.Add(@{ Kind = 'Foundry'; Tenant = $TenantId; Subscription = $SubscriptionId })
'@
        'Verify-Deployment.ps1' = @'
param($ResourceGroup, $SubscriptionId)
$global:DeploymentTest.Calls.Add(@{ Kind = 'Verify'; Subscription = $SubscriptionId })
'@
    }
    foreach ($name in $stubs.Keys) { Set-Content -LiteralPath (Join-Path $scripts $name) -Value $stubs[$name] }
    $script = Join-Path $scripts 'Deploy-ExistingEnvironment.ps1'
    $parameters = @{
        SubscriptionId = $global:DeploymentTest.Subscription
        TenantId = $global:DeploymentTest.Tenant
        TeamsAppId = $global:DeploymentTest.TeamsApp
    }

    & $script @parameters
    $calls = $global:DeploymentTest.Calls
    foreach ($kind in @('Orders', 'Prepare', 'Deploy', 'Register', 'Foundry')) {
        $matching = @($calls | Where-Object { $_.Kind -eq $kind })
        if ($matching.Count -ne 1 -or $matching[0].Tenant -ne $parameters.TenantId) {
            throw "$kind did not receive the selected tenant."
        }
    }
    foreach ($kind in @('Prepare', 'Deploy', 'Foundry', 'Verify')) {
        $matching = @($calls | Where-Object { $_.Kind -eq $kind })
        if ($matching.Count -ne 1 -or $matching[0].Subscription -ne $parameters.SubscriptionId) {
            throw "$kind did not receive the selected subscription."
        }
    }
    if (($calls | Where-Object { $_.Kind -eq 'Register' }).TeamsApp -ne $parameters.TeamsAppId) {
        throw 'Registration did not receive the selected Teams app ID.'
    }

    $calls.Clear()
    $global:DeploymentTest.AccountTenant = [guid]::NewGuid().ToString()
    $failed = $false
    try { & $script @parameters } catch { $failed = $_.Exception.Message -like '*different tenant*' }
    if (-not $failed -or $calls.Count -ne 0) { throw 'A mismatched tenant must stop before deployment steps.' }

    $global:DeploymentTest.AzCalls = 0
    $failed = $false
    try { & $script -SubscriptionId $parameters.SubscriptionId -TenantId $parameters.TenantId -TeamsAppId 'invalid' }
    catch { $failed = $true }
    if (-not $failed -or $global:DeploymentTest.AzCalls -ne 0) {
        throw 'An invalid Teams app ID must stop before invoking Azure CLI.'
    }
    'Deployment context forwarding checks passed.'
}
finally {
    foreach ($name in @('az', 'azd', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-Transcript', 'Stop-Transcript')) {
        Remove-Item "Function:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable DeploymentTest -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
