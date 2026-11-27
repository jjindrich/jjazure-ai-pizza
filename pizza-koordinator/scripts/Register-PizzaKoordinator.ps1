[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MessagingEndpoint,
    [Parameter(Mandatory = $true)]
    # Internal Worker identity; the DMZ Gateway never federates with the blueprint.
    [string]$WorkerIdentityPrincipalId,
    [string]$TenantId = $env:AZURE_TENANT_ID,
    [string]$TeamsAppId = $env:PIZZAKOORDINATOR_TEAMS_APP_ID,
    # Derives "<AgentName> Blueprint" / "<AgentName> Identity" display names.
    [string]$AgentName = 'Pizza Koordinator'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
foreach ($name in @('TenantId', 'TeamsAppId')) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse((Get-Variable $name -ValueOnly), [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$name must be a non-empty GUID; provide it as a parameter or environment variable."
    }
}
$accountTenant = & az account show --query tenantId --output tsv
if ([string]::IsNullOrWhiteSpace($accountTenant) -or $accountTenant.Trim() -ine $TenantId) {
    throw 'Azure CLI must be signed in to the requested tenant before registration.'
}
. (Join-Path $PSScriptRoot 'Agent365Grants.ps1')
$koordinatorRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $koordinatorRoot
try {
    & a365 setup requirements
    & a365 setup all --aiteammate --m365 --agent-name $AgentName --tenant-id $TenantId --messaging-endpoint $MessagingEndpoint |
        ForEach-Object { if ($_ -match 'Blueprint client secret:') { 'Blueprint client secret: [REDACTED]' } else { $_ } } | Out-Host
    $blueprintId = (Get-Content .\a365.generated.config.json -Raw | ConvertFrom-Json).agentBlueprintId
    if ([string]::IsNullOrWhiteSpace($blueprintId)) { throw 'A365 setup did not return an Agent Identity Blueprint ID.' }

    # Let only the internal Worker managed identity act for the blueprint.
    $issuer = "https://login.microsoftonline.com/$TenantId/v2.0"
    $existing = (& az ad app federated-credential list --id $blueprintId --output json | ConvertFrom-Json) |
        Where-Object { $_.issuer -eq $issuer -and $_.subject -eq $WorkerIdentityPrincipalId }
    if (-not $existing) {
        $fic = Join-Path ([IO.Path]::GetTempPath()) "pizzakoordinator-fic-$([guid]::NewGuid()).json"
        @{ name = 'pizzakoordinator-container-app'; issuer = $issuer; subject = $WorkerIdentityPrincipalId; audiences = @('api://AzureADTokenExchange') } |
            ConvertTo-Json -Compress | Set-Content $fic
        try { & az ad app federated-credential create --id $blueprintId --parameters "@$fic" | Out-Null }
        finally { Remove-Item $fic -Force -ErrorAction SilentlyContinue }
    }

    # Delegated Graph scopes for the agentic user: Calendars.ReadWrite, Mail.Send,
    # Chat.ReadWrite + ChatMessage.Send + ChannelMessage.Send (👀 reaction on received Teams messages).
    & az ad app permission add --id $blueprintId --api '00000003-0000-0000-c000-000000000000' `
        --api-permissions '1ec239c2-d7c9-4623-a91a-a9775856bb36=Scope' 'e383f46e-2787-4529-855e-0e479a3ffac0=Scope' `
        '9ff7295e-131b-4d94-90e1-69fde507ac11=Scope' '116b7235-7cc6-461e-b163-8e55691d839e=Scope' `
        'ebf0f66e-9fb1-49e4-a278-222f76911cf4=Scope' | Out-Null

    # Tenant-wide grants are written directly: legacy `az ad app permission admin-consent`
    # resets grants to requiredResourceAccess and dropped the Messaging Bot API grant (AADSTS65001).
    $blueprintSp = & az ad sp show --id $blueprintId --query id --output tsv
    if ([string]::IsNullOrWhiteSpace($blueprintSp)) {
        throw 'Blueprint service principal was not found.'
    }
    $resolvedResources = Resolve-Agent365GrantResources -ScopesByAppId @{
        '00000003-0000-0000-c000-000000000000' = 'Calendars.ReadWrite Mail.Send Chat.ReadWrite ChatMessage.Send ChannelMessage.Send'
        '5a807f24-c9de-44ee-a3a7-329e88a00ffc' = 'AgentData.ReadWrite'
        'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1' = 'McpServersMetadata.Read.All'
        '8578e004-a5c6-46e7-913e-12f58912df43' = 'Connectivity.Connections.Read'
    }
    $messagingResource = $resolvedResources.ByAppId['5a807f24-c9de-44ee-a3a7-329e88a00ffc']
    $bridgeGrants = $resolvedResources.ByPrincipalId
    $grantPage = & az rest --method GET --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$blueprintSp'" | ConvertFrom-Json
    if ($grantPage.'@odata.nextLink') { throw 'Blueprint permission grants are paginated; inspect all pages before changing them.' }
    foreach ($resource in $bridgeGrants.Keys) {
        $existingGrant = @($grantPage.value | Where-Object { $_.resourceId -eq $resource -and $_.consentType -eq 'AllPrincipals' })
        if ($existingGrant.Count -gt 1) { throw "Multiple AllPrincipals grants exist for resource $resource." }
        if ($existingGrant.Count -eq 1 -and (Test-Agent365GrantScope -ExistingScopes $existingGrant[0].scope -RequiredScope $bridgeGrants[$resource])) { continue }
        $body = Join-Path ([IO.Path]::GetTempPath()) "pizzakoordinator-grant-$([guid]::NewGuid()).json"
        if ($existingGrant.Count -eq 1) {
            $scopes = Add-Agent365GrantScope -ExistingScopes $existingGrant[0].scope -RequiredScope $bridgeGrants[$resource]
            @{ scope = $scopes } | ConvertTo-Json -Compress | Set-Content $body
            $method = 'PATCH'
            $grantUrl = "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($existingGrant[0].id)"
        }
        else {
            @{ clientId = $blueprintSp; consentType = 'AllPrincipals'; resourceId = $resource; scope = $bridgeGrants[$resource] } |
                ConvertTo-Json -Compress | Set-Content $body
            $method = 'POST'
            $grantUrl = 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants'
        }
        try { & az rest --method $method --url $grantUrl --body "@$body" --headers 'Content-Type=application/json' | Out-Null }
        finally { Remove-Item $body -Force -ErrorAction SilentlyContinue }
    }
    $grantPage = & az rest --method GET --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$blueprintSp'" | ConvertFrom-Json
    $inheritance = & az rest --method GET --url "https://graph.microsoft.com/beta/applications/$blueprintId/microsoft.graph.agentIdentityBlueprint/inheritablePermissions" | ConvertFrom-Json
    Assert-Agent365MessagingGrant -Grants $grantPage -Inheritance $inheritance -MessagingResourceId $messagingResource

    & (Join-Path $PSScriptRoot 'Build-AgentTemplatePackage.ps1') -BlueprintId $blueprintId -TeamsAppId $TeamsAppId
    [ordered]@{ blueprintId = $blueprintId; messagingEndpoint = $MessagingEndpoint } | ConvertTo-Json
}
finally {
    Pop-Location
}
