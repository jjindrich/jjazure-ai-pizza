[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MessagingEndpoint,
    [Parameter(Mandatory = $true)]
    [string]$BridgeIdentityPrincipalId,
    [string]$TenantId = 'b48accae-439a-467a-9fbf-8ad011508424',
    # Derives "<AgentName> Blueprint" / "<AgentName> Identity" display names.
    [string]$AgentName = 'Pizza Koordinator'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$koordinatorRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $koordinatorRoot
try {
    & a365 setup requirements
    & a365 setup all --aiteammate --m365 --agent-name $AgentName --tenant-id $TenantId --messaging-endpoint $MessagingEndpoint |
        ForEach-Object { if ($_ -match 'Blueprint client secret:') { 'Blueprint client secret: [REDACTED]' } else { $_ } } | Out-Host
    $blueprintId = (Get-Content .\a365.generated.config.json -Raw | ConvertFrom-Json).agentBlueprintId
    if ([string]::IsNullOrWhiteSpace($blueprintId)) { throw 'A365 setup did not return an Agent Identity Blueprint ID.' }

    # Let the Container App managed identity act for the blueprint.
    $issuer = "https://login.microsoftonline.com/$TenantId/v2.0"
    $existing = (& az ad app federated-credential list --id $blueprintId --output json | ConvertFrom-Json) |
        Where-Object { $_.issuer -eq $issuer -and $_.subject -eq $BridgeIdentityPrincipalId }
    if (-not $existing) {
        $fic = Join-Path ([IO.Path]::GetTempPath()) "pizzakoordinator-fic-$([guid]::NewGuid()).json"
        @{ name = 'pizzakoordinator-container-app'; issuer = $issuer; subject = $BridgeIdentityPrincipalId; audiences = @('api://AzureADTokenExchange') } |
            ConvertTo-Json -Compress | Set-Content $fic
        try { & az ad app federated-credential create --id $blueprintId --parameters "@$fic" | Out-Null }
        finally { Remove-Item $fic -Force -ErrorAction SilentlyContinue }
    }

    # Delegated Graph scopes for the agentic user: Calendars.ReadWrite and Mail.Send.
    & az ad app permission add --id $blueprintId --api '00000003-0000-0000-c000-000000000000' `
        --api-permissions '1ec239c2-d7c9-4623-a91a-a9775856bb36=Scope' 'e383f46e-2787-4529-855e-0e479a3ffac0=Scope' | Out-Null
    & az ad app permission admin-consent --id $blueprintId

    # Bridge token exchange needs these tenant-wide grants (as in MVP), otherwise AADSTS65001.
    $blueprintSp = & az ad sp show --id $blueprintId --query id --output tsv
    $bridgeGrants = @{
        '3710a0fe-0154-4e9c-8456-52b7016e9150' = 'AgentData.ReadWrite'           # Messaging Bot API
        'd77f2f69-bbb8-48f4-b5da-c258cdd85a9c' = 'McpServersMetadata.Read.All'   # Agent 365 Tools
        'dc81a085-289b-4484-9a42-43933c28b798' = 'Connectivity.Connections.Read' # Power Platform API
    }
    $grants = (& az rest --method GET --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$blueprintSp'" | ConvertFrom-Json).value
    foreach ($resource in $bridgeGrants.Keys) {
        if ($grants | Where-Object { $_.resourceId -eq $resource -and $_.consentType -eq 'AllPrincipals' }) { continue }
        $body = Join-Path ([IO.Path]::GetTempPath()) "pizzakoordinator-grant-$([guid]::NewGuid()).json"
        @{ clientId = $blueprintSp; consentType = 'AllPrincipals'; resourceId = $resource; scope = $bridgeGrants[$resource] } |
            ConvertTo-Json -Compress | Set-Content $body
        try { & az rest --method POST --url 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' --body "@$body" --headers 'Content-Type=application/json' | Out-Null }
        finally { Remove-Item $body -Force -ErrorAction SilentlyContinue }
    }

    & (Join-Path $PSScriptRoot 'Build-AgentTemplatePackage.ps1') -BlueprintId $blueprintId
    [ordered]@{ blueprintId = $blueprintId; messagingEndpoint = $MessagingEndpoint } | ConvertTo-Json
}
finally {
    Pop-Location
}
