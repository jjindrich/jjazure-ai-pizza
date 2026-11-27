[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidatePattern('^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+$')]
    [string]$AgentUpn = 'pizzakoordinator@jjazdev.org',
    [string]$TenantId = $env:AZURE_TENANT_ID,
    [ValidatePattern('^[A-Z]{2}$')]
    [string]$UsageLocation = 'CZ'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$parsedTenant = [guid]::Empty
if (-not [guid]::TryParse($TenantId, [ref]$parsedTenant) -or $parsedTenant -eq [guid]::Empty) {
    throw 'TenantId must be a non-empty GUID; provide -TenantId or AZURE_TENANT_ID.'
}
$TenantId = $parsedTenant.ToString()
Write-Warning 'This script creates Entra directory objects only. Graph user creation does not provision Teams or a mailbox; use the Agent 365 onboarding workflow for a full instance.'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$statePath = Join-Path $root '.local\agent365\instance.pizzakoordinator.json'
$blueprintId = (Get-Content (Join-Path $root 'a365.generated.config.json') -Raw | ConvertFrom-Json).agentBlueprintId
$account = & az account show -o json | ConvertFrom-Json
if ($account.tenantId -ne $TenantId) { throw 'Azure CLI is signed in to a different tenant.' }
if ([string]::IsNullOrWhiteSpace($blueprintId)) { throw 'No PizzaKoordinator blueprint ID was found.' }
$ownerId = & az ad signed-in-user show --query id -o tsv
$binding = @{ tenantId = $TenantId.ToString(); blueprintId = $blueprintId; ownerId = $ownerId; agentUpn = $AgentUpn }
$state = if (Test-Path $statePath) { Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable } else { $binding.Clone() }
foreach ($key in $binding.Keys) {
    if ($state[$key] -ne $binding[$key]) { throw "Saved instance has a different $key; refusing to reuse it." }
}

function Invoke-Graph([string]$Method, [string]$Path, $Body) {
    $token = & az account get-access-token --resource-type ms-graph --query accessToken -o tsv
    $headers = @{ Authorization = "Bearer $token"; 'OData-Version' = '4.0' }
    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri "https://graph.microsoft.com/v1.0$Path" -Headers $headers
    }
    return Invoke-RestMethod -Method $Method -Uri "https://graph.microsoft.com/v1.0$Path" -Headers $headers `
        -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 10)
}

function Save-State {
    New-Item -ItemType Directory -Path (Split-Path $statePath -Parent) -Force | Out-Null
    $state | ConvertTo-Json -Depth 5 | Set-Content $statePath
}

$skus = (Invoke-Graph GET '/subscribedSkus' $null).value
$requested = @('AGENT_365', 'Microsoft_365_Copilot', 'Microsoft_365_E5_(no_Teams)', 'Microsoft_Teams_Enterprise_New', 'FLOW_FREE')
$selection = '?$select=id,displayName,userPrincipalName,accountEnabled,usageLocation,assignedLicenses,identityParentId'
$user = if ($state.agentUserId) { Invoke-Graph GET ("/users/$($state.agentUserId)" + $selection) $null }
if ($user -and ($user.userPrincipalName -ne $AgentUpn -or $user.identityParentId -ne $state.agentIdentityId)) {
    throw 'Saved user does not match the requested UPN and Agent Identity.'
}
$assigned = @($user.assignedLicenses.skuId)
$missing = @()
foreach ($name in $requested) {
    $sku = $skus | Where-Object { $_.skuPartNumber -eq $name }
    if (-not $sku) { throw "Tenant has no subscribed SKU '$name'." }
    if ($sku.skuId -in $assigned) { continue }
    if ($sku.prepaidUnits.enabled -le $sku.consumedUnits) { throw "No available license for '$name'." }
    $missing += @{ skuId = $sku.skuId; disabledPlans = @() }
}
if (-not $PSCmdlet.ShouldProcess($AgentUpn, 'Create Agent Identity and Agent User, set usage location and assign available licenses')) { return }

if (-not $state.agentUserId) {
    if ($state.userCreationPending) { throw 'A previous user creation has an unknown outcome. Inspect the directory before retrying.' }
    $existing = & az ad user list --filter "userPrincipalName eq '$AgentUpn'" -o json | ConvertFrom-Json
    if (@($existing).Count -ne 0) { throw 'An unbound user already exists at this UPN. Inspect it rather than creating or adopting another identity.' }
}
Save-State
if (-not $state.agentIdentityId) {
    if ($state.identityCreationPending) { throw 'A previous identity creation has an unknown outcome. Inspect the directory before retrying.' }
    Connect-MgGraph -TenantId $TenantId -Scopes 'AgentIdentity.Create.All' -ContextScope Process -NoWelcome
    $context = Get-MgContext
    if ($context.TenantId -ne $TenantId.ToString() -or $context.Account -ne $account.user.name -or
        $context.ClientId -ne '14d82eec-204b-4c2f-b7e8-296a70dab67e') {
        throw 'Graph PowerShell signed in with an unexpected tenant, account, or application.'
    }
    $state.identityCreationPending = $true
    Save-State
    # Same Agent Identity / Agent User API sequence as the working MVP sample.
    $identityBody = @{
        displayName = 'Pizza Koordinator Identity'
        agentIdentityBlueprintId = $blueprintId
        'sponsors@odata.bind' = @("https://graph.microsoft.com/v1.0/users/$ownerId")
    } | ConvertTo-Json -Depth 5
    $identity = Invoke-MgGraphRequest -Method POST `
        -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals/microsoft.graph.agentIdentity' `
        -Headers @{ 'OData-Version' = '4.0' } -ContentType 'application/json' `
        -Body $identityBody -OutputType PSObject
    if (-not $identity.id) { throw 'Agent Identity creation returned no ID; inspect the directory before retrying.' }
    $state.agentIdentityId = $identity.id
    $state.agentIdentityAppId = $identity.appId
    $state.identityCreationPending = $false
    Save-State
}
else {
    $identity = Invoke-Graph GET "/servicePrincipals/$($state.agentIdentityId)" $null
    if ($identity.agentIdentityBlueprintId -ne $blueprintId) { throw 'Saved identity belongs to a different blueprint.' }
}

if (-not $state.agentUserId) {
    $userBody = @{
        accountEnabled = $true
        displayName = 'Pizza Koordinator'
        mailNickname = 'pizzakoordinator'
        userPrincipalName = $AgentUpn
        identityParentId = $state.agentIdentityId
    }
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        $state.userCreationPending = $true
        Save-State
        try {
            $user = Invoke-Graph POST '/users/microsoft.graph.agentUser' $userBody
            break
        }
        catch {
            if ($_.Exception.Response.StatusCode -ne 400 -or
                $_.ErrorDetails.Message -notmatch 'Agent user IdentityParent does not exist in the directory\.') {
                throw
            }
            $state.userCreationPending = $false
            Save-State
            if ($attempt -eq 5) { throw }
            Write-Warning 'Agent Identity has not replicated to user provisioning yet; retrying the explicitly rejected request.'
            Start-Sleep -Seconds ([math]::Pow(2, $attempt + 1))
        }
    }
    if (-not $user.id) { throw 'Agent User creation returned no ID; inspect the directory before retrying.' }
    $state.agentUserId = $user.id
    $state.userCreationPending = $false
    Save-State
}
$null = Invoke-Graph PATCH "/users/$($state.agentUserId)" @{ usageLocation = $UsageLocation }
if ($missing.Count -gt 0) {
    $null = Invoke-Graph POST "/users/$($state.agentUserId)/assignLicense" @{ addLicenses = $missing; removeLicenses = @() }
}
$verified = Invoke-Graph GET ("/users/$($state.agentUserId)" + $selection) $null
if (-not $verified.accountEnabled -or $verified.usageLocation -ne $UsageLocation -or $verified.identityParentId -ne $state.agentIdentityId) {
    throw 'Agent User account, usage location or parent verification failed.'
}
foreach ($name in $requested) {
    $skuId = ($skus | Where-Object { $_.skuPartNumber -eq $name }).skuId
    if ($skuId -notin @($verified.assignedLicenses.skuId)) { throw "License '$name' was not assigned." }
}
[pscustomobject]@{
    AgentUpn = $verified.userPrincipalName
    AgentUserId = $verified.id
    AgentIdentityId = $state.agentIdentityId
    BlueprintId = $blueprintId
    AccountEnabled = $verified.accountEnabled
    LicenseSkus = $requested
}
