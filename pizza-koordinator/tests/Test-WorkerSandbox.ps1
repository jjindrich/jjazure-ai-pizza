# Offline contract tests. No Azure login or resources required.
[CmdletBinding()]
param([string]$AcaCommand = 'aca')

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot '..\scripts\WorkerSandbox.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null }
    catch { $threw = $true }
    Assert-True $threw $Message
}

$settings = @(
    'ASPNETCORE_ENVIRONMENT=Production',
    'Koordinator__OrdersApiUrl=https://orders.example.test',
    'Koordinator__FoundryEndpoint=https://foundry.example.test/api/projects/pizza',
    'AZURE_CLIENT_ID=11111111-1111-1111-1111-111111111111'
)
$diskId = '22222222-2222-2222-2222-222222222222'
$manifest = New-WorkerSandboxManifest -DiskId $diskId -Settings $settings
$reordered = New-WorkerSandboxManifest -DiskId $diskId -Settings $settings[3, 1, 0, 2]
Assert-True ($manifest.labels.configuration -eq $reordered.labels.configuration) 'Equivalent settings must reuse the same sandbox.'
Assert-True ($manifest.labels.configuration.Length -le 63) 'Sandbox configuration labels must meet ACA label length limits.'
$changed = New-WorkerSandboxManifest -DiskId $diskId -Settings ($settings + 'Koordinator__UrgeAfterMinutes=4')
Assert-True ($manifest.labels.configuration -ne $changed.labels.configuration) 'Changing Worker settings must produce a different deployment fingerprint.'
Assert-True (-not $manifest.lifecycle.autoSuspendPolicy.enabled -and -not $manifest.lifecycle.autoDeletePolicy.enabled) 'Background polling must not be suspended or deleted.'
Assert-True ($manifest.environment.ASPNETCORE_CONTENTROOT -eq '/app') 'Worker must load appsettings independently of the sandbox working directory.'
$hosts = @($manifest.egressPolicy.rules | ForEach-Object { $_.match.host })
Assert-True ($manifest.egressPolicy.defaultAction -eq 'Deny' -and $hosts -contains 'orders.example.test' -and $hosts -contains 'foundry.example.test' -and $hosts -notcontains '*') 'Egress must be deny-by-default with workload-specific hosts.'
Assert-Throws { New-WorkerSandboxManifest -DiskId $diskId -Settings ($settings + 'AZURE_CLIENT_ID=other') } 'Duplicate settings must not silently override the identity.'
Assert-Throws { New-WorkerSandboxManifest -DiskId $diskId -Settings ($settings -replace 'https://orders', 'http://orders') } 'Insecure Orders endpoints must be rejected.'

$old = [pscustomobject]@{ id = 'old'; state = 'Running'; labels = @{ configuration = 'old' } }
$same = [pscustomobject]@{ id = 'same'; state = 'Running'; labels = @{ configuration = $manifest.labels.configuration } }
Assert-Throws { Select-WorkerSandbox @($old) $manifest.labels.configuration } 'A changed Worker requires explicit replacement.'
$replace = Select-WorkerSandbox @($old) $manifest.labels.configuration -ReplaceWorker
Assert-True ($replace.Stop.Count -eq 1 -and $replace.Stop[0].id -eq 'old' -and -not $replace.Existing) 'Replace must stop the old Worker before creating another.'
Assert-Throws { Select-WorkerSandbox @($old, $same) $manifest.labels.configuration -ReplaceWorker } 'Duplicate running Workers must not be silently accepted.'
$old.state = 'Stopped'
$reuse = Select-WorkerSandbox @($old, $same) $manifest.labels.configuration
Assert-True ($reuse.Existing.id -eq 'same' -and $reuse.Stop.Count -eq 0) 'Retained stopped snapshots must not prevent idempotent reuse.'
Assert-Throws { Select-WorkerSandbox @($same, $same) $manifest.labels.configuration } 'Ambiguous allocations must be resolved before retrying.'

$legacyImage = 'registry.example.test/pizzakoordinator-api@sha256:abc'
$activeLegacy = @([pscustomobject]@{ name = 'legacy--0000005'; properties = @{ active = $true } })
$cutover = Get-LegacyGatewayCutover -Image $legacyImage -Revisions $activeLegacy -LatestReadyRevision 'legacy--0000005'
Assert-True ($cutover.Revision -eq 'legacy--0000005' -and $cutover.Deactivate) 'Cutover must pause the active legacy poller and retain its revision for rollback.'
$paused = Get-LegacyGatewayCutover -Image $legacyImage -LatestReadyRevision 'legacy--0000005'
Assert-True ($paused.Revision -eq 'legacy--0000005' -and -not $paused.Deactivate) 'A previously paused legacy revision must remain available for rollback.'
$currentGateway = Get-LegacyGatewayCutover -Image 'registry.example.test/pizzakoordinator-gateway@sha256:def'
Assert-True (-not $currentGateway.Revision -and -not $currentGateway.Deactivate) 'A split Gateway must not trigger legacy poller cutover.'
Assert-Throws { Get-LegacyGatewayCutover -Image $legacyImage -Revisions $activeLegacy -RunningWorkerCount 1 } 'Cutover must refuse simultaneous legacy and Sandbox pollers.'
Assert-Throws {
    Get-LegacyGatewayCutover -Image $legacyImage -Revisions @($activeLegacy + $activeLegacy) -LatestReadyRevision 'legacy--0000005'
} 'Cutover must refuse multiple active legacy revisions.'

$worker = @{
    id = 'worker'
    state = 'Running'
    lifecycle = $manifest.lifecycle
    egressPolicy = $manifest.egressPolicy
    ports = @(@{ port = 8080; auth = @{ anonymous = $true }; url = 'https://worker.example.test' })
}
Assert-True ((Assert-WorkerSandbox $worker) -eq 'https://worker.example.test') 'Use the service-returned HTTPS URL.'
$worker.lifecycle = @{ autoSuspendPolicy = @{ enabled = $true }; autoDeletePolicy = @{ enabled = $false } }
Assert-Throws { Assert-WorkerSandbox $worker } 'Auto-suspend must fail deployment verification.'
$worker.lifecycle = @{}
Assert-Throws { Assert-WorkerSandbox $worker } 'Missing lifecycle fields must not look like a safe disabled policy.'
$worker.lifecycle = $manifest.lifecycle
$worker.ports += @{ port = 22; url = 'https://unexpected.example.test' }
Assert-Throws { Assert-WorkerSandbox $worker } 'Unexpected ingress ports must fail verification.'

$file = Join-Path ([IO.Path]::GetTempPath()) "worker-sandbox-test-$([guid]::NewGuid()).json"
try {
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file
    & $AcaCommand sandbox validate --file $file
}
finally { Remove-Item -LiteralPath $file -Force }
Write-Host 'Worker Sandbox contracts passed (manifest, lifecycle, egress, identity settings, singleton replacement and ingress).'
