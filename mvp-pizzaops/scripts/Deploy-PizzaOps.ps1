param(
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$ResourceGroup = 'rg-jjazure-ai-mvp-pizzaops',
    [string]$Location = 'swedencentral',
    [string]$DeploymentId = 'mvp',
    [string]$TenantId = $env:AZURE_TENANT_ID,
    [string]$TeamsBlueprintClientId = $env:PIZZAOPS_BLUEPRINT_ID,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GraphWebhookClientState
)

$ErrorActionPreference = 'Stop'
foreach ($name in @('SubscriptionId', 'TenantId', 'TeamsBlueprintClientId')) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse((Get-Variable $name -ValueOnly), [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$name must be a non-empty GUID; provide it as a parameter or environment variable."
    }
}
if ($PSVersionTable.PSVersion -lt [version]'7.3') {
    throw 'PowerShell 7.3 or later is required to stop on native command failures.'
}
$PSNativeCommandUseErrorActionPreference = $true
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $repoRoot
try {
    & az account set --subscription $SubscriptionId
    $accountTenant = & az account show --query tenantId --output tsv
    if ($accountTenant -ine $TenantId) { throw 'The selected subscription belongs to a different tenant.' }
    $callerObjectId = & az ad signed-in-user show --query id --output tsv
    if ([string]::IsNullOrWhiteSpace($callerObjectId)) {
        throw 'No signed-in Azure user was found.'
    }

    & dotnet restore .\PizzaOps.slnx
    & dotnet build .\PizzaOps.slnx --configuration Release --no-restore
    & dotnet test .\PizzaOps.slnx --configuration Release --no-build
    & python .\tests\pizzaops_validate.py
    & az bicep build --file .\infra\pizzaops\main.bicep --stdout | Out-Null

    & az group create --name $ResourceGroup --location $Location --tags application=PizzaOps environment=mvp | Out-Null

    $toolAppName = 'PizzaOps MVP Tool API'
    $toolAppId = & az ad app list --display-name $toolAppName --query '[0].appId' --output tsv
    if ([string]::IsNullOrWhiteSpace($toolAppId)) {
        $toolAppId = & az ad app create --display-name $toolAppName --query appId --output tsv
    }
    $toolAppObjectId = & az ad app show --id $toolAppId --query id --output tsv
    $toolRoleId = '14c7f4f6-3e1a-4bc4-9e7d-5d9dfb1f8a21'
    $apiAudience = "api://$toolAppId"
    $graphPatch = @{
        identifierUris = @($apiAudience)
        api = @{
            requestedAccessTokenVersion = 2
        }
        appRoles = @(
            @{
                id = $toolRoleId
                allowedMemberTypes = @('Application')
                description = 'Allows a trusted Foundry project identity to call PizzaOps tools.'
                displayName = 'PizzaOps Tool Caller'
                isEnabled = $true
                value = 'PizzaOps.Tool'
            }
        )
    } | ConvertTo-Json -Depth 8 -Compress
    $graphPatchPath = Join-Path ([IO.Path]::GetTempPath()) "pizzaops-app-$([guid]::NewGuid()).json"
    [IO.File]::WriteAllText($graphPatchPath, $graphPatch)
    try {
        & az rest --method PATCH `
            --uri "https://graph.microsoft.com/v1.0/applications/$toolAppObjectId" `
            --headers 'Content-Type=application/json' `
            --body "@$graphPatchPath" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not configure the PizzaOps tool API Entra application.'
        }
    }
    finally {
        Remove-Item $graphPatchPath -Force -ErrorAction SilentlyContinue
    }
    $toolServicePrincipalId = & az ad sp list --filter "appId eq '$toolAppId'" --query '[0].id' --output tsv
    if ([string]::IsNullOrWhiteSpace($toolServicePrincipalId)) {
        & az ad sp create --id $toolAppId | Out-Null
        $toolServicePrincipalId = & az ad sp list --filter "appId eq '$toolAppId'" --query '[0].id' --output tsv
    }

    $deploymentName = "pizzaops-bootstrap-$(Get-Date -Format yyyyMMddHHmmss)"
    & az deployment sub create `
        --name $deploymentName `
        --location $Location `
        --template-file .\infra\pizzaops\main.bicep `
        --parameters `
            resourceGroupName=$ResourceGroup `
            location=$Location `
            deploymentId=$DeploymentId `
            callerObjectId=$callerObjectId `
            teamsBlueprintClientId=$TeamsBlueprintClientId `
            teamsTenantId=$TenantId `
            apiAudience=$apiAudience `
            graphWebhookClientState=$GraphWebhookClientState | Out-Null

    $foundryEndpoint = & az deployment sub show --name $deploymentName --query 'properties.outputs.foundryProjectEndpoint.value' --output tsv
    $foundryProjectId = & az deployment sub show --name $deploymentName --query 'properties.outputs.foundryProjectId.value' --output tsv
    $foundryPrincipalId = & az deployment sub show --name $deploymentName --query 'properties.outputs.foundryProjectPrincipalId.value' --output tsv
    $registryName = & az deployment sub show --name $deploymentName --query 'properties.outputs.registryName.value' --output tsv
    $registryServer = & az deployment sub show --name $deploymentName --query 'properties.outputs.registryServer.value' --output tsv
    $foundryClientId = & az ad sp show --id $foundryPrincipalId --query appId --output tsv
    if ([string]::IsNullOrWhiteSpace($foundryClientId)) {
        throw 'The deployed Foundry project managed identity did not resolve to a client ID.'
    }

    $existingAssignment = & az rest --method GET `
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$toolServicePrincipalId/appRoleAssignedTo" `
        --query "value[?principalId=='$foundryPrincipalId' && appRoleId=='$toolRoleId'].id | [0]" `
        --output tsv
    if ([string]::IsNullOrWhiteSpace($existingAssignment)) {
        $assignment = @{
            principalId = $foundryPrincipalId
            resourceId = $toolServicePrincipalId
            appRoleId = $toolRoleId
        } | ConvertTo-Json -Compress
        $assignmentPath = Join-Path ([IO.Path]::GetTempPath()) "pizzaops-role-$([guid]::NewGuid()).json"
        [IO.File]::WriteAllText($assignmentPath, $assignment)
        try {
            & az rest --method POST `
                --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$toolServicePrincipalId/appRoleAssignedTo" `
                --headers 'Content-Type=application/json' `
                --body "@$assignmentPath" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw 'Could not grant the Foundry project identity the PizzaOps tool app role.'
            }
        }
        finally {
            Remove-Item $assignmentPath -Force -ErrorAction SilentlyContinue
        }
    }

    $imageTag = "mvp-$(Get-Date -Format yyyyMMddHHmmss)-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    & az acr build `
        --registry $registryName `
        --image "pizzaops-api:$imageTag" `
        --file .\infra\pizzaops\Dockerfile.pizzaops `
        . | Out-Null
    $digest = & az acr repository show `
        --name $registryName `
        --image "pizzaops-api:$imageTag" `
        --query 'digest' `
        --output tsv
    if ($digest -notmatch '^sha256:[a-f0-9]{64}$') {
        throw "The registry did not return a valid digest for pizzaops-api:$imageTag."
    }
    $containerImage = "$registryServer/pizzaops-api@$digest"

    $runtimeDeployment = "pizzaops-runtime-$(Get-Date -Format yyyyMMddHHmmss)"
    & az deployment sub create `
        --name $runtimeDeployment `
        --location $Location `
        --template-file .\infra\pizzaops\main.bicep `
        --parameters `
            resourceGroupName=$ResourceGroup `
            location=$Location `
            deploymentId=$DeploymentId `
            callerObjectId=$callerObjectId `
            containerImage=$containerImage `
            foundryProjectClientId=$foundryClientId `
            teamsBlueprintClientId=$TeamsBlueprintClientId `
            teamsTenantId=$TenantId `
            apiAudience=$apiAudience `
            graphWebhookClientState=$GraphWebhookClientState | Out-Null

    $apiUrl = & az deployment sub show --name $runtimeDeployment --query 'properties.outputs.containerAppUrl.value' --output tsv
    if ([string]::IsNullOrWhiteSpace($apiUrl)) {
        throw 'The Container App URL was not produced by deployment.'
    }
    $lastHealthError = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $health = Invoke-RestMethod "$apiUrl/health" -TimeoutSec 10
            if ($health -eq 'Healthy') { break }
        }
        catch { $lastHealthError = $_.Exception.Message }
        Start-Sleep -Seconds 10
    }
    if ($health -ne 'Healthy') {
        throw "PizzaOps.Api did not become healthy at $apiUrl. Last error: $lastHealthError"
    }
    $operations = (Invoke-RestMethod "$apiUrl/openapi/v1.json").paths
    $operationCount = @(
        $operations.PSObject.Properties.Value.PSObject.Properties |
            Where-Object { $_.Value.operationId }
    ).Count
    if ($operationCount -ne 12) {
        throw "Expected 12 deployed OpenAPI operations, found $operationCount."
    }

    & .\scripts\pizzaops\Deploy-FoundryAgent.ps1 `
        -ProjectEndpoint $foundryEndpoint `
        -ApiUrl $apiUrl `
        -ApiAudience $apiAudience `
        -ModelDeployment 'gpt-5-mini' `
        -EnvironmentName 'pizzaops-mvp' `
        -ProjectId $foundryProjectId `
        -SubscriptionId $SubscriptionId `
        -ResourceGroup $ResourceGroup

    $result = [ordered]@{
        resourceGroup = $ResourceGroup
        subscriptionId = $SubscriptionId
        region = $Location
        apiUrl = $apiUrl
        foundryProjectId = $foundryProjectId
        foundryProjectEndpoint = $foundryEndpoint
        foundryAgentName = 'pizzaops-agent'
        foundryProjectClientId = $foundryClientId
        toolApiClientId = $toolAppId
        teamsBlueprintClientId = $TeamsBlueprintClientId
        graphNotificationUrl = "$apiUrl/api/graph/notifications"
        graphWebhookClientState = $GraphWebhookClientState
    }
    $result | ConvertTo-Json -Depth 4 | Set-Content .\deployment-output.json
    $result.GetEnumerator() | Where-Object Key -NE 'graphWebhookClientState'
}
finally {
    Pop-Location
}
