[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MessagingEndpoint,
    [Parameter(Mandatory = $true)]
    [string]$BridgeIdentityPrincipalId,
    [string]$TenantId = 'b48accae-439a-467a-9fbf-8ad011508424'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$koordinatorRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $koordinatorRoot
try {
    & a365 setup requirements
    & a365 setup all --aiteammate --m365 --agent-name PizzaKoordinator --tenant-id $TenantId --messaging-endpoint $MessagingEndpoint
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

    & (Join-Path $PSScriptRoot 'Build-AgentTemplatePackage.ps1') -BlueprintId $blueprintId
    [ordered]@{ blueprintId = $blueprintId; messagingEndpoint = $MessagingEndpoint } | ConvertTo-Json
}
finally {
    Pop-Location
}
