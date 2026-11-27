$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..\scripts\Update-PizzaOpsApi.ps1'
$testSubscription = [guid]::NewGuid().ToString()
$global:pizzaOpsTestDigest = 'sha256:' + ('a' * 64)
$global:pizzaOpsTestImage = "example.azurecr.io/pizzaops-api@$global:pizzaOpsTestDigest"
$global:pizzaOpsTestScenario = 'success'
$global:pizzaOpsTestCommands = [System.Collections.Generic.List[string]]::new()

function global:az {
    $command = $args -join ' '
    $global:pizzaOpsTestCommands.Add($command)
    $global:LASTEXITCODE = 0
    if ($command -like 'containerapp show*' -and $command -like '*--query*') {
        return '{"latest":"rev-1","ready":"rev-1","fqdn":"api.example"}'
    }
    if ($command -like 'containerapp show*') {
        $environment = if ($global:pizzaOpsTestScenario -eq 'wrong-environment') { 'wrong-env' } else { 'cae-pizzaops-private-mvp' }
        return "{`"properties`":{`"environmentId`":`"/environments/$environment`"}}"
    }
    if ($command -like 'acr show*') { return 'example.azurecr.io' }
    if ($command -like 'acr build*') {
        if ($global:pizzaOpsTestScenario -eq 'build-failed') {
            $global:LASTEXITCODE = 1
            return
        }
        return 'build completed'
    }
    if ($command -like 'acr repository show*') {
        if ($global:pizzaOpsTestScenario -eq 'missing-digest') { return '' }
        return $global:pizzaOpsTestDigest
    }
    if ($command -like 'containerapp update*') { return }
    if ($command -like 'containerapp revision show*') {
        return "{`"properties`":{`"template`":{`"containers`":[{`"name`":`"pizzaops-api`",`"image`":`"$global:pizzaOpsTestImage`"}]}}}"
    }
    throw "Unexpected Azure CLI call: $command"
}

function global:Invoke-RestMethod {
    param([string]$Uri, [int]$TimeoutSec)
    if ($Uri -ne 'https://api.example/health') { throw "Unexpected health URL: $Uri" }
    return 'Healthy'
}

try {
    & $script -SubscriptionId $testSubscription -WhatIf
    if ($global:pizzaOpsTestCommands -match '^acr build|^containerapp update') {
        throw 'WhatIf must not build or update.'
    }

    $global:pizzaOpsTestCommands.Clear()
    $result = & $script -SubscriptionId $testSubscription -Confirm:$false
    if ($result.Image -ne $global:pizzaOpsTestImage -or $result.Revision -ne 'rev-1' -or $result.Health -ne 'Healthy') {
        throw 'Successful deployment did not return the verified revision and digest.'
    }
    $lookup = @($global:pizzaOpsTestCommands | Where-Object { $_ -like 'acr repository show*' })
    $build = @($global:pizzaOpsTestCommands | Where-Object { $_ -like 'acr build*' })
    if ($lookup.Count -ne 1 -or $build.Count -ne 1 -or
        $build[0] -notmatch '--image (pizzaops-api:\S+)' -or
        $lookup[0] -notlike "*--image $($Matches[1])*") {
        throw 'Digest lookup must use the exact tag just built.'
    }
    if (-not ($global:pizzaOpsTestCommands | Where-Object { $_ -like "containerapp update*--image $global:pizzaOpsTestImage*" })) {
        throw 'The Container App must be updated with the immutable digest.'
    }

    foreach ($failure in @('wrong-environment', 'build-failed', 'missing-digest')) {
        $global:pizzaOpsTestScenario = $failure
        $global:pizzaOpsTestCommands.Clear()
        $failed = $false
        try { & $script -SubscriptionId $testSubscription -Confirm:$false } catch { $failed = $true }
        if (-not $failed -or ($global:pizzaOpsTestCommands | Where-Object { $_ -like 'containerapp update*' })) {
            throw "$failure must fail without updating the app."
        }
        $global:pizzaOpsTestCommands.Clear()
        $failed = $false
        try { & $script -SubscriptionId 'invalid' -Confirm:$false } catch { $failed = $true }
        if (-not $failed -or $global:pizzaOpsTestCommands.Count -ne 0) {
            throw 'An invalid subscription must fail before invoking Azure CLI.'
        }
    }
    Write-Host 'Update-PizzaOpsApi script tests passed.'
}
finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Variable pizzaOpsTestDigest, pizzaOpsTestImage, pizzaOpsTestScenario, pizzaOpsTestCommands -Scope Global -ErrorAction SilentlyContinue
}
