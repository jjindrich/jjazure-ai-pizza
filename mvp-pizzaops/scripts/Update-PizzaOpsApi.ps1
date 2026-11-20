[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$SubscriptionId = '80214fc0-7aff-43b6-bbff-cf81a36cbb10',
    [string]$ResourceGroup = 'rg-jjazure-ai-mvp-pizzaops',
    [string]$ContainerApp = 'ca-pizzaops-api-v2',
    [string]$EnvironmentName = 'cae-pizzaops-private-mvp',
    [string]$Registry = 'crpizzaopsmvpi2jyp62'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Invoke-AzChecked {
    param([string[]]$Arguments)

    $result = & az @Arguments --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed (exit $LASTEXITCODE): az $($Arguments -join ' ')"
    }
    return $result
}

$appJson = Invoke-AzChecked @(
    'containerapp', 'show', '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroup, '--name', $ContainerApp, '--output', 'json'
)
$app = ($appJson -join "`n") | ConvertFrom-Json
$environmentId = $app.properties.environmentId
if (-not $environmentId) {
    $environmentId = $app.properties.managedEnvironmentId
}
if (-not $environmentId -or ($environmentId -split '/')[-1] -ine $EnvironmentName) {
    throw "Container App is not in the expected environment '$EnvironmentName'. No image was built or deployed."
}

$registryServer = (Invoke-AzChecked @(
    'acr', 'show', '--subscription', $SubscriptionId,
    '--name', $Registry, '--query', 'loginServer', '--output', 'tsv'
) | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($registryServer)) {
    throw "Registry '$Registry' did not return a login server."
}

if (-not $PSCmdlet.ShouldProcess(
    "$ContainerApp in $ResourceGroup ($SubscriptionId)",
    "Build an image in $Registry and deploy it to the existing Container App"
)) {
    return
}

$tag = "api-$(Get-Date -Format yyyyMMddHHmmss)-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
Push-Location $repoRoot
try {
    Invoke-AzChecked @(
        'acr', 'build', '--subscription', $SubscriptionId, '--registry', $Registry,
        '--image', "pizzaops-api:$tag", '--file', '.\infra\pizzaops\Dockerfile.pizzaops', '.'
    ) | Out-Host
}
finally {
    Pop-Location
}

$digest = (Invoke-AzChecked @(
    'acr', 'repository', 'show', '--subscription', $SubscriptionId, '--name', $Registry,
    '--image', "pizzaops-api:$tag", '--query', 'digest', '--output', 'tsv'
) | Out-String).Trim()
if ($digest -notmatch '^sha256:[a-f0-9]{64}$') {
    throw "Registry did not return a valid digest for pizzaops-api:$tag. No deployment was performed."
}
$image = "$registryServer/pizzaops-api@$digest"

Invoke-AzChecked @(
    'containerapp', 'update', '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroup, '--name', $ContainerApp,
    '--container-name', 'pizzaops-api', '--image', $image, '--output', 'none'
) | Out-Host

$revisionName = $null
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    $stateJson = Invoke-AzChecked @(
        'containerapp', 'show', '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroup, '--name', $ContainerApp,
        '--query', 'properties.{latest:latestRevisionName,ready:latestReadyRevisionName,fqdn:configuration.ingress.fqdn}',
        '--output', 'json'
    )
    $state = ($stateJson -join "`n") | ConvertFrom-Json
    if ($state.latest -and $state.latest -eq $state.ready) {
        $revisionJson = Invoke-AzChecked @(
            'containerapp', 'revision', 'show', '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroup, '--name', $ContainerApp,
            '--revision', $state.ready, '--output', 'json'
        )
        $revision = ($revisionJson -join "`n") | ConvertFrom-Json
        $container = @($revision.properties.template.containers | Where-Object name -eq 'pizzaops-api')
        if ($container.Count -eq 1 -and $container[0].image -eq $image) {
            $revisionName = $state.ready
            break
        }
    }
    Start-Sleep -Seconds 10
}
if (-not $revisionName -or -not $state.fqdn) {
    throw "The deployment was requested, but the new image was not confirmed ready. Inspect $ContainerApp before retrying."
}

$healthUrl = "https://$($state.fqdn)/health"
try {
    $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 15
}
catch {
    throw "Revision '$revisionName' is ready, but the health check at '$healthUrl' failed: $($_.Exception.Message)"
}
if ($health -ne 'Healthy') {
    throw "Revision '$revisionName' returned an unexpected health response from '$healthUrl': $health"
}

[pscustomobject]@{
    ContainerApp = $ContainerApp
    Revision = $revisionName
    Image = $image
    HealthUrl = $healthUrl
    Health = $health
}
