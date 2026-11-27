[CmdletBinding()]
param(
    [string]$DisplayName = 'Pizza Orders Agent MCP API'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$apps = @(& az ad app list --all --filter "displayName eq '$DisplayName'" -o json | ConvertFrom-Json)
if ($apps.Count -gt 1) { throw "More than one Entra application is named '$DisplayName'." }

$app = $apps | Select-Object -First 1
if (-not $app) {
    $app = & az ad app create --display-name $DisplayName -o json | ConvertFrom-Json
}
if (-not $app.appId -or -not $app.id) {
    $app = & az ad app show --id $app.appId -o json | ConvertFrom-Json
}
if (-not $app.appId -or -not $app.id) { throw 'Orders MCP application registration returned no IDs.' }

$audience = "api://$($app.appId)"
$identifierUris = @($app.identifierUris | Where-Object { $_ })
if ($identifierUris.Count -gt 0 -and ($identifierUris.Count -ne 1 -or $identifierUris[0] -ne $audience)) {
    throw "Existing '$DisplayName' application has an unexpected identifier URI; refusing to replace it."
}
if ($identifierUris.Count -eq 0 -or $app.api.requestedAccessTokenVersion -ne 2) {
    $patchFile = Join-Path ([IO.Path]::GetTempPath()) "orders-mcp-api-$([guid]::NewGuid()).json"
    try {
        @{ identifierUris = @($audience); api = @{ requestedAccessTokenVersion = 2 } } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $patchFile
        & az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" `
            --body "@$patchFile" --headers Content-Type=application/json -o none
    }
    finally {
        Remove-Item -LiteralPath $patchFile -Force -ErrorAction SilentlyContinue
    }
}

$servicePrincipals = @(& az ad sp list --all --filter "appId eq '$($app.appId)'" -o json | ConvertFrom-Json)
if ($servicePrincipals.Count -gt 1) { throw 'Multiple service principals exist for the Orders MCP application.' }
if ($servicePrincipals.Count -eq 0) {
    & az ad sp create --id $app.appId -o none
}

[pscustomobject]@{
    Audience = $audience
    ApplicationClientId = $app.appId
}
