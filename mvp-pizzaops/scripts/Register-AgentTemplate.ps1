param(
    [string]$TenantId = 'b48accae-439a-467a-9fbf-8ad011508424',
    [string]$MessagingEndpoint = 'https://ca-pizzaops-api-v2.livelysand-b75eab52.swedencentral.azurecontainerapps.io/api/messages',
    [string]$BridgeManagedIdentityClientId = 'c3f39f3f-613f-4fb7-9219-85716161cedf'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $repoRoot
try {
    & a365 setup requirements
    if ($LASTEXITCODE -ne 0) {
        throw 'Agent 365 prerequisites are not satisfied.'
    }

    & a365 setup all `
        --aiteammate `
        --m365 `
        --agent-name PizzaOps `
        --tenant-id $TenantId `
        --messaging-endpoint $MessagingEndpoint
    if ($LASTEXITCODE -ne 0) {
        throw 'Agent 365 blueprint setup failed.'
    }

    $state = Get-Content .\a365.generated.config.json -Raw | ConvertFrom-Json
    $blueprintId = $state.agentBlueprintId
    if ([string]::IsNullOrWhiteSpace($blueprintId)) {
        throw 'A365 setup did not return an Agent Identity Blueprint ID.'
    }

    $bridgeManagedIdentityPrincipalId = & az identity list `
        --query "[?clientId=='$BridgeManagedIdentityClientId'].principalId | [0]" `
        --output tsv
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not resolve the Container App managed identity principal ID.'
    }
    if ([string]::IsNullOrWhiteSpace($bridgeManagedIdentityPrincipalId)) {
        throw "No managed identity was found for client ID '$BridgeManagedIdentityClientId'."
    }

    $principalId = [guid]::Empty
    if (-not [guid]::TryParse($bridgeManagedIdentityPrincipalId, [ref]$principalId)) {
        throw 'The Container App managed identity returned an invalid principal ID.'
    }

    $expectedIssuer = "https://login.microsoftonline.com/$TenantId/v2.0"
    $expectedAudience = 'api://AzureADTokenExchange'
    $federatedCredentials = & az ad app federated-credential list --id $blueprintId --output json |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not list federated credentials on the Agent Identity Blueprint.'
    }

    $matchingCredential = $federatedCredentials | Where-Object {
        $_.issuer -CEQ $expectedIssuer -and
        $_.subject -CEQ $principalId.ToString() -and
        @($_.audiences) -CContains $expectedAudience
    }
    if (-not $matchingCredential) {
        $fic = @{
            name = "pizzaops-container-app-uami-$($principalId.ToString('N').Substring(0, 8))"
            issuer = $expectedIssuer
            subject = $principalId.ToString()
            audiences = @($expectedAudience)
            description = 'PizzaOps Container App managed identity federation'
        } | ConvertTo-Json -Compress
        $ficPath = Join-Path ([IO.Path]::GetTempPath()) "pizzaops-fic-$([guid]::NewGuid()).json"
        [IO.File]::WriteAllText($ficPath, $fic)
        try {
            & az ad app federated-credential create --id $blueprintId --parameters "@$ficPath" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw 'Could not federate the PizzaOps blueprint with the Container App identity.'
            }
        }
        finally {
            Remove-Item $ficPath -Force -ErrorAction SilentlyContinue
        }
    }

    & az ad app permission add `
        --id $blueprintId `
        --api '00000003-0000-0000-c000-000000000000' `
        --api-permissions `
            '1ec239c2-d7c9-4623-a91a-a9775856bb36=Scope' `
            'a65f2972-a4f8-4f5e-afd7-69ccb046d5dc=Scope' | Out-Null
    & az ad app permission admin-consent --id $blueprintId
    if ($LASTEXITCODE -ne 0) {
        throw 'Calendar admin consent was not granted for the PizzaOps blueprint.'
    }

    & .\scripts\Build-AgentTemplatePackage.ps1

    [ordered]@{
        blueprintId = $blueprintId
        blueprintServicePrincipalId = $state.agentBlueprintServicePrincipalObjectId
        messagingEndpoint = $MessagingEndpoint
        package = (Join-Path $repoRoot '.local\pizzaops-agent-template-1.0.0.zip')
        nextStep = 'Submit the ZIP through the approved Agent 365/ALM process for this tenant.'
    } | ConvertTo-Json -Depth 5
}
finally {
    Pop-Location
}
