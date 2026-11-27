$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "pizzaops-provision-test-$([guid]::NewGuid().ToString('N'))"
$testTenant = [guid]::NewGuid().ToString()
$testBlueprint = [guid]::NewGuid().ToString()
$testOwner = [guid]::NewGuid().ToString()
$global:pizzaOpsProvisionTenant = $testTenant
$global:pizzaOpsProvisionCalls = [System.Collections.Generic.List[object]]::new()
$global:pizzaOpsProvisionExitCode = 0

function global:az {
    $global:LASTEXITCODE = 0
    return $global:pizzaOpsProvisionTenant
}

function global:python {
    $global:pizzaOpsProvisionCalls.Add(@($args))
    $global:LASTEXITCODE = $global:pizzaOpsProvisionExitCode
}

try {
    $scripts = Join-Path $testRoot 'scripts'
    $sample = Join-Path $testRoot 'sample\autopilots-on-azure\scripts'
    New-Item -ItemType Directory -Path $scripts, $sample -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Provision-Agent365Instance.ps1') -Destination $scripts
    Set-Content -LiteralPath (Join-Path $sample 'provision_agent365_instance.py') -Value '# test fixture'
    $scriptPath = Join-Path $scripts 'Provision-Agent365Instance.ps1'
    $sourceCheckout = Join-Path $testRoot 'sample'
    $parameters = @{
        SourceCheckout = $sourceCheckout
        TenantId = $testTenant
        BlueprintId = $testBlueprint
        OwnerId = $testOwner
        InstanceName = 'pizzaops-workshop'
        AgentUpn = 'pizzaops-workshop@example.org'
        DisplayName = 'PizzaOps Workshop'
        MailNickname = 'pizzaops-workshop'
    }
    $binding = Join-Path $testRoot '.local\agent365\instance.pizzaops-workshop.binding.json'

    & $scriptPath @parameters -WhatIf
    if ($global:pizzaOpsProvisionCalls.Count -ne 0 -or (Test-Path -LiteralPath $binding)) {
        throw 'WhatIf must not call provisioning or write binding state.'
    }
    & $scriptPath @parameters -DryRun -WhatIf
    if ($global:pizzaOpsProvisionCalls.Count -ne 0 -or (Test-Path -LiteralPath $binding)) {
        throw 'WhatIf combined with DryRun must not call provisioning or write binding state.'
    }
    & $scriptPath @parameters -DryRun
    if ($global:pizzaOpsProvisionCalls.Count -ne 1 -or
        $global:pizzaOpsProvisionCalls[0] -notcontains '--dry-run' -or
        $global:pizzaOpsProvisionCalls[0] -notcontains 'pizzaops-workshop@example.org' -or
        (Test-Path -LiteralPath $binding)) {
        throw 'DryRun must forward the instance and avoid writing binding state.'
    }

    & $scriptPath @parameters -Confirm:$false
    $saved = Get-Content -LiteralPath $binding -Raw | ConvertFrom-Json
    if ($saved.agentUpn -ne 'pizzaops-workshop@example.org' -or
        $global:pizzaOpsProvisionCalls[1] -contains '--dry-run') {
        throw 'Provisioning must bind the UPN and invoke the non-dry-run module.'
    }

    $callsBefore = $global:pizzaOpsProvisionCalls.Count
    $parameters.AgentUpn = 'different@example.org'
    $failed = $false
    try { & $scriptPath @parameters -Confirm:$false } catch { $failed = $true }
    if (-not $failed -or $global:pizzaOpsProvisionCalls.Count -ne $callsBefore) {
        throw 'A mismatched UPN must not invoke the provisioning module.'
    }

    $parameters.AgentUpn = 'pizzaops-workshop@example.org'
    $global:pizzaOpsProvisionTenant = '00000000-0000-0000-0000-000000000001'
    $failed = $false
    try { & $scriptPath @parameters -DryRun } catch { $failed = $true }
    if (-not $failed -or $global:pizzaOpsProvisionCalls.Count -ne $callsBefore) {
        throw 'A mismatched tenant must not invoke the provisioning module.'
    }

    $global:pizzaOpsProvisionTenant = $testTenant
    $global:pizzaOpsProvisionExitCode = 1
    $failed = $false
    try { & $scriptPath @parameters -Confirm:$false } catch { $failed = $true }
    if (-not $failed -or -not (Test-Path -LiteralPath $binding)) {
        throw 'A module failure must be surfaced and leave the binding intact for recovery.'
    }

    $legacyState = Join-Path $testRoot '.local\agent365\instance.pizzaops.json'
    '{"agentUserPrincipalName":"pizzaops@jjazdev.org"}' | Set-Content -LiteralPath $legacyState
    $callsBefore = $global:pizzaOpsProvisionCalls.Count
    $failed = $false
    try {
        & $scriptPath -SourceCheckout $sourceCheckout -TenantId $testTenant `
            -BlueprintId $testBlueprint -OwnerId $testOwner -DryRun
    }
    catch { $failed = $_.Exception.Message -like '*Unbound existing state*' }
    if (-not $failed -or $global:pizzaOpsProvisionCalls.Count -ne $callsBefore) {
        throw 'An unbound existing instance must not be trusted or provisioned automatically.'
    }
    Write-Host 'Provision-Agent365Instance script tests passed.'
}
finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Item Function:\python -ErrorAction SilentlyContinue
    Remove-Variable pizzaOpsProvisionTenant, pizzaOpsProvisionCalls, pizzaOpsProvisionExitCode -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
