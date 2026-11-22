$ErrorActionPreference = 'Stop'
$source = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Provision-Agent365Instance.ps1')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "PizzaKoordinatorProvisioning-$([guid]::NewGuid())"
$statePath = Join-Path $testRoot '.local\agent365\instance.pizzakoordinator.json'
$scriptPath = Join-Path $testRoot 'scripts\Provision-Agent365Instance.ps1'
$tenant = 'b48accae-439a-467a-9fbf-8ad011508424'
$owner = '63963f49-be4b-46ca-8d95-fa33e9777a22'
$blueprint = '2001462b-309f-4b8e-ba8d-85c3b2dd8943'
$identity = '9fac1cc6-de81-4bc2-b577-5219a157e89e'
$global:ProvisionCase = @{
    Scenario = 'replication'; Posts = 0; User = $null
    Skus = @('AGENT_365', 'Microsoft_365_Copilot', 'Microsoft_365_E5_(no_Teams)', 'Microsoft_Teams_Enterprise_New', 'FLOW_FREE') |
        ForEach-Object { @{ skuPartNumber = $_; skuId = [guid]::NewGuid().ToString(); prepaidUnits = @{ enabled = 1 }; consumedUnits = 0 } }
}
function az {
    if ($args[0] -eq 'account' -and $args[1] -eq 'show') {
        return (@{ tenantId = $tenant; user = @{ name = 'jjadmin@jjazdev.org' } } | ConvertTo-Json)
    }
    if ($args[0] -eq 'ad' -and $args[1] -eq 'signed-in-user') { return $owner }
    if ($args[0] -eq 'ad' -and $args[1] -eq 'user') { return '[]' }
    if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') { return 'fake-token' }
    throw "Unexpected az call: $args"
}
function Start-Sleep { param($Seconds) }
function Invoke-RestMethod {
    [CmdletBinding()]
    param($Method, $Uri, $Headers, $ContentType, $Body)
    if ($Uri -like '*/subscribedSkus') { return [pscustomobject]@{ value = $global:ProvisionCase.Skus } }
    if ($Uri -like '*/servicePrincipals/*') {
        return [pscustomobject]@{ id = $identity; agentIdentityBlueprintId = $blueprint }
    }
    if ($Method -eq 'POST' -and $Uri -like '*/users/microsoft.graph.agentUser') {
        $global:ProvisionCase.Posts++
        if ($global:ProvisionCase.Scenario -eq 'unknown' -or $global:ProvisionCase.Posts -eq 1) {
            $status = if ($global:ProvisionCase.Scenario -eq 'unknown') { 503 } else { 400 }
            $response = [System.Net.Http.HttpResponseMessage]::new($status)
            $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Provisioning failed', $response)
            $record = [Management.Automation.ErrorRecord]::new($exception, 'GraphError', 'InvalidOperation', $null)
            $message = if ($status -eq 400) { 'Agent user IdentityParent does not exist in the directory.' } else { 'Service unavailable' }
            $record.ErrorDetails = [Management.Automation.ErrorDetails]::new($message)
            $PSCmdlet.ThrowTerminatingError($record)
        }
        $payload = $Body | ConvertFrom-Json
        $global:ProvisionCase.User = [pscustomobject]@{
            id = 'new-user'; userPrincipalName = $payload.userPrincipalName; identityParentId = $payload.identityParentId
            accountEnabled = $true; usageLocation = $null; assignedLicenses = @()
        }
        return $global:ProvisionCase.User
    }
    if ($Method -eq 'PATCH') {
        $global:ProvisionCase.User.usageLocation = ($Body | ConvertFrom-Json).usageLocation
        return
    }
    if ($Method -eq 'POST' -and $Uri -like '*/assignLicense') {
        $global:ProvisionCase.User.assignedLicenses = @(
            ($Body | ConvertFrom-Json).addLicenses | ForEach-Object { [pscustomobject]@{ skuId = $_.skuId } }
        )
        return
    }
    if ($Method -eq 'GET' -and $Uri -like '*/users/new-user*') { return $global:ProvisionCase.User }
    throw "Unexpected directory call: $Method $Uri"
}
function Write-InitialState {
    @{
        tenantId = $tenant; ownerId = $owner; blueprintId = $blueprint
        agentUpn = 'pizzakoordinator@jjazdev.org'; agentIdentityId = $identity; identityCreationPending = $false
    } | ConvertTo-Json | Set-Content $statePath
}
try {
    New-Item -ItemType Directory -Path (Split-Path $statePath), (Join-Path $testRoot 'scripts') | Out-Null
    Copy-Item -LiteralPath $source -Destination $scriptPath
    @{ agentBlueprintId = $blueprint } | ConvertTo-Json | Set-Content (Join-Path $testRoot 'a365.generated.config.json')
    Write-InitialState
    $result = & $scriptPath -Confirm:$false
    if ($global:ProvisionCase.Posts -ne 2 -or $result.AgentUserId -ne 'new-user') {
        throw 'An explicitly rejected replication request should retry and create one user.'
    }
    $global:ProvisionCase.Scenario = 'unknown'
    $global:ProvisionCase.Posts = 0
    $global:ProvisionCase.User = $null
    Write-InitialState
    $failed = $false
    try { & $scriptPath -Confirm:$false }
    catch { $failed = $true }
    $saved = Get-Content $statePath -Raw | ConvertFrom-Json
    if (-not $failed -or $global:ProvisionCase.Posts -ne 1 -or -not $saved.userCreationPending) {
        throw 'Unknown creation outcomes must remain pending without a retry.'
    }
    try { & $scriptPath -Confirm:$false }
    catch {
        if ($_.Exception.Message -notlike '*unknown outcome*') { throw }
    }
    if ($global:ProvisionCase.Posts -ne 1) { throw 'A pending user creation must not be submitted again.' }
    'Agent 365 provisioning retry checks passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    Remove-Variable ProvisionCase -Scope Global
}
