# Shared deployment contracts; dot-sourcing this file does not contact Azure.
function Assert-SandboxTools {
    $userInstall = Join-Path $HOME '.aca\bin'
    if (-not (Get-Command aca -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $userInstall 'aca.exe'))) {
        $env:PATH = "$env:PATH;$userInstall"
    }
    Get-Command aca -ErrorAction Stop | Out-Null
    & aca sandbox validate --help | Out-Null
    & aca sandboxgroup environment link --help | Out-Null
    $help = & az containerapp env create --help
    if (($help -join "`n") -notmatch '--environment-mode') {
        throw 'Install a current Azure CLI containerapp extension with preview support for Express environments.'
    }
}

function Find-Az {
    $PSNativeCommandUseErrorActionPreference = $false
    $result = & az @args --only-show-errors 2>&1
    if ($LASTEXITCODE -eq 0) { return $result }
    if (($result -join "`n") -match 'ResourceNotFound|Resource .*does not exist|was not found|could not be found') { return }
    throw "Azure lookup failed: $($result -join "`n")"
}

function New-WorkerSandboxManifest {
    param(
        [Parameter(Mandatory)][guid]$DiskId,
        [Parameter(Mandatory)][string[]]$Settings
    )
    $environment = [ordered]@{}
    foreach ($setting in ($Settings | Sort-Object)) {
        $pair = $setting.Split('=', 2)
        if ($pair.Count -ne 2 -or $environment.Contains($pair[0])) { throw "Invalid or duplicate Worker setting: $($pair[0])." }
        $environment[$pair[0]] = $pair[1]
    }
    if ($environment['ASPNETCORE_ENVIRONMENT'] -ne 'Production') { throw 'Sandbox Worker must run in Production.' }
    $environment['ASPNETCORE_CONTENTROOT'] = '/app'
    $environment['ASPNETCORE_URLS'] = 'http://+:8080'
    $hosts = @('login.microsoftonline.com', 'graph.microsoft.com', '*.botframework.com', 'smba.trafficmanager.net')
    foreach ($name in @('Koordinator__OrdersApiUrl', 'Koordinator__FoundryEndpoint')) {
        $uri = $null
        if (-not [Uri]::TryCreate($environment[$name], [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or $uri.UserInfo) { throw "$name must be an absolute HTTPS URL without credentials." }
        $hosts += $uri.DnsSafeHost
    }
    $manifest = [ordered]@{
        diskId = $DiskId.ToString()
        entrypoint = @('/usr/share/dotnet/dotnet', '/app/PizzaKoordinator.Worker.dll')
        environment = $environment
        resources = [ordered]@{ cpu = '250m'; memory = '512Mi'; disk = '5Gi' }
        lifecycle = [ordered]@{
            # Outbound polling does not prevent sandbox idleness. Never suspend this autonomous Worker.
            autoSuspendPolicy = [ordered]@{ enabled = $false; interval = 300; mode = 'Memory' }
            autoDeletePolicy = [ordered]@{ enabled = $false }
        }
        # The group must already be Private-Link-only. The Worker, not the ingress proxy, validates the Gateway JWT.
        ports = @([ordered]@{ name = 'worker'; port = 8080; auth = [ordered]@{ anonymous = $true } })
        egressPolicy = [ordered]@{
            defaultAction = 'Deny'
            trafficInspection = 'Full'
            rules = @($hosts | Sort-Object -Unique | ForEach-Object {
                [ordered]@{ match = [ordered]@{ host = $_ }; action = [ordered]@{ type = 'Allow' } }
            })
        }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 20 -Compress))
    $configuration = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant().Substring(0, 63)
    $manifest.labels = @{
        app = 'pizzakoordinator-worker'
        configuration = $configuration
    }
    return $manifest
}

function Select-WorkerSandbox {
    param([object[]]$Sandboxes, [string]$Configuration, [switch]$ReplaceWorker)
    if (@($Sandboxes | Where-Object state -eq 'Running').Count -gt 1) {
        throw 'More than one Worker is running. Resolve duplicate workers before deployment.'
    }
    $matching = @($Sandboxes | Where-Object { $_.labels.configuration -eq $Configuration })
    if ($matching.Count -gt 1) { throw 'Multiple sandboxes match this configuration. Inspect them before retrying.' }
    $other = @($Sandboxes | Where-Object { $_.labels.configuration -ne $Configuration })
    if (($matching.Count -eq 0 -and $other.Count -gt 0 -or @($other | Where-Object state -ne 'Stopped').Count -gt 0) -and -not $ReplaceWorker) {
        throw 'Worker replacement requires -ReplaceWorker. Its in-memory coordination state is not migrated; old sandboxes are stopped, not deleted.'
    }
    return @{
        Existing = $matching | Select-Object -First 1
        Stop = @($other | Where-Object { $_.state -ne 'Stopped' })
    }
}

function Get-LegacyGatewayCutover {
    param(
        [Parameter(Mandatory)][string]$Image,
        [object[]]$Revisions = @(),
        [string]$LatestReadyRevision,
        [int]$RunningWorkerCount = 0
    )
    if ($Image -match '/pizzakoordinator-gateway(@|:)') {
        return [pscustomobject]@{ Revision = $null; Deactivate = $false }
    }
    if ($Image -notmatch '/pizzakoordinator-api(@|:)') {
        throw "Unexpected image on Gateway app; refusing to alter its revision."
    }
    if ($RunningWorkerCount -gt 0) {
        throw 'Both the legacy poller and a Sandbox Worker are running; resolve the duplicate before cutover.'
    }
    $active = @($Revisions | Where-Object { $_.properties.active -eq $true })
    if ($active.Count -gt 1) { throw 'Multiple Gateway revisions are active; refusing an ambiguous poller cutover.' }
    $revision = if ($active.Count -eq 1) { $active[0].name } else { $LatestReadyRevision }
    if (-not $revision) { throw 'The legacy Gateway revision could not be identified for a safe cutover.' }
    return [pscustomobject]@{ Revision = $revision; Deactivate = ($active.Count -eq 1) }
}

function Assert-WorkerSandbox {
    param([Parameter(Mandatory)]$Sandbox)
    if (-not $Sandbox.id -or $Sandbox.state -ne 'Running') {
        throw 'Expected a running Worker in the selected sandbox group.'
    }
    if ($Sandbox.lifecycle.autoSuspendPolicy.enabled -ne $false -or $Sandbox.lifecycle.autoDeletePolicy.enabled -ne $false) {
        throw 'Worker auto-suspend and auto-delete must both be explicitly disabled.'
    }
    if ($Sandbox.egressPolicy.defaultAction -ne 'Deny' -or $Sandbox.egressPolicy.trafficInspection -ne 'Full') {
        throw 'Worker must enforce the configured outbound host allowlist.'
    }
    $ports = @($Sandbox.ports)
    if ($ports.Count -ne 1 -or $ports[0].port -ne 8080 -or $ports[0].auth.anonymous -ne $true) {
        throw 'Expected only Worker port 8080 with application-level JWT authentication behind Private Link.'
    }
    $url = $null
    if (-not [Uri]::TryCreate($ports[0].url, [UriKind]::Absolute, [ref]$url) -or $url.Scheme -ne 'https') {
        throw 'Sandbox service returned no HTTPS Worker port URL.'
    }
    return $url.AbsoluteUri.TrimEnd('/')
}

function Restore-LegacyPoller {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$GatewayAppName,
        [Parameter(Mandatory)][string]$GatewayRevision,
        [Parameter(Mandatory)][string]$SandboxGroupName,
        [Parameter(Mandatory)][string]$WorkerSandboxId,
        [string]$WorkerIdentityName = 'id-pizzakoordinator',
        [string]$GatewayIdentityName = 'id-pizzakoordinator-gateway',
        [string]$Registry = 'crpizza22dfk5ihazv',
        [string]$Location = 'swedencentral'
    )
    $context = @('--subscription', $SubscriptionId, '-g', $ResourceGroup)
    $groupContext = $context + @('--region', $Location, '--group', $SandboxGroupName)
    $worker = & aca sandbox get @groupContext --id $WorkerSandboxId -o json | ConvertFrom-Json
    if ($worker.state -eq 'Running') {
        & aca sandbox stop @groupContext --id $WorkerSandboxId --wait-timeout 300 -o json | Out-Null
        $worker = & aca sandbox get @groupContext --id $WorkerSandboxId -o json | ConvertFrom-Json
    }
    if ($worker.state -ne 'Stopped') { throw "Worker $WorkerSandboxId is not stopped; refusing to reactivate the legacy poller." }

    $workerIdentity = & az identity show @context -n $WorkerIdentityName -o json | ConvertFrom-Json
    $gatewayIdentity = & az identity show @context -n $GatewayIdentityName -o json | ConvertFrom-Json
    $registryServer = & az acr show --subscription $SubscriptionId -n $Registry --query loginServer -o tsv
    & az containerapp identity assign @context -n $GatewayAppName --user-assigned $workerIdentity.id -o none
    & az containerapp registry set @context -n $GatewayAppName --server $registryServer --identity $workerIdentity.id -o none
    $app = & az containerapp show @context -n $GatewayAppName -o json | ConvertFrom-Json
    if ($app.identity.userAssignedIdentities.PSObject.Properties.Name -contains $gatewayIdentity.id) {
        & az containerapp identity remove @context -n $GatewayAppName --user-assigned $gatewayIdentity.id -o none
    }
    & az containerapp revision activate @context -n $GatewayAppName --revision $GatewayRevision -o none
    $active = & az containerapp revision show @context -n $GatewayAppName --revision $GatewayRevision --query properties.active -o tsv
    if ($active -ne 'true') { throw "Legacy Gateway revision $GatewayRevision did not become active." }
}
