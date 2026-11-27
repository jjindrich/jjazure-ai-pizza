[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$GatewayEnvironmentName,
    [Parameter(Mandatory)][string]$WorkerIdentityId,
    [Parameter(Mandatory)][string]$Image,
    [Parameter(Mandatory)][string[]]$Settings,
    [string]$GatewayAppName = 'ca-pizzakoordinator',
    [string]$Location = 'swedencentral',
    [string]$SandboxGroupName = 'sbg-pizzakoordinator',
    [string]$SandboxEnvironmentName = 'cae-pizzakoordinator-sandbox',
    [string]$PrivateEndpointSubnetName = 'snet-private-endpoints',
    [switch]$ReplaceWorker
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot 'WorkerSandbox.ps1')
Get-Command aca -ErrorAction Stop | Out-Null
if ($SandboxEnvironmentName -eq $GatewayEnvironmentName) { throw 'Sandbox private ingress must not change the public Gateway environment.' }
if ($Image -notmatch '@sha256:([0-9a-f]{64})$') { throw 'The Worker image must be pinned by digest.' }
$digest = $Matches[1]
$azContext = @('--subscription', $SubscriptionId, '-g', $ResourceGroup)
$acaContext = @('--subscription', $SubscriptionId, '-g', $ResourceGroup, '--region', $Location)
$groupContext = $acaContext + @('--group', $SandboxGroupName)

$gatewayEnvironment = & az containerapp env show @azContext -n $GatewayEnvironmentName -o json | ConvertFrom-Json
$subnetId = $gatewayEnvironment.properties.vnetConfiguration.infrastructureSubnetId
if (-not $subnetId) { throw 'Gateway environment must be VNet-integrated to reach the private Sandbox.' }
$vnetId = $subnetId.Substring(0, $subnetId.LastIndexOf('/subnets/', [StringComparison]::OrdinalIgnoreCase))
$vnet = & az network vnet show --ids $vnetId -o json | ConvertFrom-Json
$subnet = @($vnet.subnets | Where-Object name -eq $PrivateEndpointSubnetName)
if ($subnet.Count -ne 1) { throw "Existing private endpoint subnet $PrivateEndpointSubnetName was not found in the Gateway VNet." }

# A separate, private Express environment; never disable public access on the pizza application's environment.
$environment = Find-Az containerapp env show @azContext -n $SandboxEnvironmentName -o json
if (-not $environment) {
    $help = & az containerapp env create --help
    if (($help -join "`n") -notmatch '--environment-mode') { throw 'Update the Azure CLI containerapp extension with preview support for Express environments before deployment.' }
    & az containerapp env create @azContext -n $SandboxEnvironmentName --location $Location `
        --environment-mode Express --public-network-access Disabled --output none
}
$environment = & az containerapp env show @azContext -n $SandboxEnvironmentName -o json | ConvertFrom-Json
if ($environment.properties.environmentMode -ne 'Express' -or $environment.properties.publicNetworkAccess -ne 'Disabled' -or
    $environment.properties.provisioningState -ne 'Succeeded') { throw 'Sandbox environment must be provisioned, Express and private before creating ingress.' }

$endpointName = "pe-$SandboxGroupName"
$endpoint = Find-Az network private-endpoint show @azContext -n $endpointName -o json
if (-not $endpoint) {
    & az network private-endpoint create @azContext -n $endpointName --location $Location --subnet $subnet[0].id `
        --private-connection-resource-id $environment.id --connection-name $endpointName --group-id managedEnvironments -o none
}
$endpoint = & az network private-endpoint show @azContext -n $endpointName -o json | ConvertFrom-Json
$connections = @($endpoint.privateLinkServiceConnections)
if ($endpoint.subnet.id -ne $subnet[0].id -or $connections.Count -ne 1 -or
    $connections[0].privateLinkServiceId -ne $environment.id -or
    $connections[0].privateLinkServiceConnectionState.status -ne 'Approved') { throw 'Private Endpoint is not approved for the selected environment and subnet.' }

$zoneName = "privatelink.$Location.azurecontainerapps.io"
if (-not (Find-Az network private-dns zone show @azContext -n $zoneName -o json)) {
    & az network private-dns zone create @azContext -n $zoneName -o none
}
$link = Find-Az network private-dns link vnet show @azContext -z $zoneName -n $SandboxGroupName -o json
if ($link) {
    if (($link | ConvertFrom-Json).virtualNetwork.id -ne $vnetId) { throw 'Existing Sandbox DNS link points to a different VNet.' }
}
else {
    & az network private-dns link vnet create @azContext -z $zoneName -n $SandboxGroupName --virtual-network $vnetId --registration-enabled false -o none
}
$zoneId = & az network private-dns zone show @azContext -n $zoneName --query id -o tsv
& az network private-endpoint dns-zone-group create @azContext --endpoint-name $endpointName -n sandbox `
    --private-dns-zone $zoneId --zone-name sandbox -o none

# The set-once environment link is created only after private networking is ready.
$groups = @(& aca sandboxgroup list @acaContext -o json | ConvertFrom-Json)
$group = $groups | Where-Object name -eq $SandboxGroupName
if (-not $group) {
    & aca sandboxgroup create @acaContext --name $SandboxGroupName --location $Location --environment-id $environment.id -o json | Out-Null
}
$group = & aca sandboxgroup get @acaContext --name $SandboxGroupName -o json | ConvertFrom-Json
if ($group.properties.environmentId -ne $environment.id) { throw 'SandboxGroup must already be linked to the selected private environment; existing groups are never relinked.' }
$otherIdentities = @($group.identity.userAssignedIdentities.PSObject.Properties.Name | Where-Object { $_ -and $_ -ne $WorkerIdentityId })
if ($otherIdentities.Count -gt 0 -or $group.identity.type -match 'SystemAssigned') { throw 'Use a dedicated SandboxGroup with only the Worker identity.' }
& aca sandboxgroup identity assign @groupContext --user-assigned $WorkerIdentityId -o json | Out-Null

$disks = @(& aca sandboxgroup disk list @groupContext -o json | ConvertFrom-Json | Where-Object { $_.labels.image -eq $digest })
if ($disks.Count -gt 1) { throw 'Multiple Worker disk images match this digest. Inspect them before retrying.' }
$disk = $disks | Select-Object -First 1
if (-not $disk) {
    $disk = & aca sandboxgroup disk create @groupContext --image $Image --identity $WorkerIdentityId `
        --name "worker-$($digest.Substring(0, 12))" --label "image=$digest" --wait-timeout 900 -o json | ConvertFrom-Json
}
if (-not $disk.id) { throw 'Sandbox service returned no disk image ID.' }

$manifest = New-WorkerSandboxManifest -DiskId $disk.id -Settings $Settings
$local = Join-Path $PSScriptRoot '..\.local'
New-Item -ItemType Directory -Path $local -Force | Out-Null
$manifestFile = Join-Path $local 'worker-sandbox.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestFile
& aca sandbox validate --file $manifestFile | Out-Host
$workers = @(& aca sandbox list @groupContext -l app=pizzakoordinator-worker -o json | ConvertFrom-Json)
$selection = Select-WorkerSandbox -Sandboxes $workers -Configuration $manifest.labels.configuration -ReplaceWorker:$ReplaceWorker
$gatewayRevision = $null
try {
    $gatewayText = Find-Az containerapp show @azContext -n $GatewayAppName -o json
    if ($gatewayText) {
        $gateway = ($gatewayText -join "`n") | ConvertFrom-Json
        $gatewayImage = $gateway.properties.template.containers[0].image
        $revisions = @()
        if ($gatewayImage -match '/pizzakoordinator-api(@|:)') {
            $revisions = @(& az containerapp revision list @azContext -n $GatewayAppName -o json | ConvertFrom-Json)
        }
        $runningWorkerCount = @($workers | Where-Object state -eq 'Running').Count
        $cutover = Get-LegacyGatewayCutover -Image $gatewayImage -Revisions $revisions `
            -LatestReadyRevision $gateway.properties.latestReadyRevisionName `
            -RunningWorkerCount $runningWorkerCount
        $gatewayRevision = $cutover.Revision
        if ($cutover.Deactivate) {
            & az containerapp revision deactivate @azContext -n $GatewayAppName --revision $gatewayRevision -o none
            $paused = $false
            for ($attempt = 0; $attempt -lt 12; $attempt++) {
                $active = & az containerapp revision show @azContext -n $GatewayAppName --revision $gatewayRevision `
                    --query properties.active -o tsv
                if ($active -eq 'false') { $paused = $true; break }
                Start-Sleep -Seconds 5
            }
            if (-not $paused) { throw 'The legacy order poller did not stop; refusing to start a second poller.' }
        }
    }

    foreach ($old in $selection.Stop) {
        & aca sandbox stop @groupContext --id $old.id --wait-timeout 300 -o json | Out-Null
        $stopped = & aca sandbox get @groupContext --id $old.id -o json | ConvertFrom-Json
        if ($stopped.state -ne 'Stopped') { throw "Old Worker $($old.id) did not stop; refusing a second active Worker." }
    }
    $worker = $selection.Existing
    if (-not $worker) {
        # Never retry uncertain creates: the manifest's configuration label locates an allocation after interruption.
        & aca sandbox apply @groupContext --file $manifestFile --wait-timeout 600 -o json | Out-Null
        $created = @(& aca sandbox list @groupContext -l app=pizzakoordinator-worker -o json |
            ConvertFrom-Json | Where-Object { $_.labels.configuration -eq $manifest.labels.configuration })
        if ($created.Count -ne 1) { throw "Expected one Worker allocation for configuration $($manifest.labels.configuration); inspect the group before retrying." }
        $worker = $created[0]
    }
    elseif ($worker.state -eq 'Stopped') {
        & aca sandbox resume @groupContext --id $worker.id --wait-timeout 300 -o json | Out-Null
    }
    if (-not $worker.id) { throw 'No Worker sandbox ID returned. Inspect the group before retrying; no allocation was retried.' }
    $worker = & aca sandbox get @groupContext --id $worker.id -o json | ConvertFrom-Json
    $workerUrl = Assert-WorkerSandbox -Sandbox $worker
    if ($worker.sourcesRef.diskImage.id -ne $disk.id) { throw 'Worker booted from a different disk image.' }
    [pscustomobject]@{
        WorkerUrl = $workerUrl
        WorkerSandboxId = $worker.id
        WorkerSandboxGroup = $SandboxGroupName
        SandboxEnvironmentId = $environment.id
        WorkerImage = $Image
        PreviousGatewayRevision = $gatewayRevision
    }
}
catch {
    $deploymentError = $_
    if ($gatewayRevision) {
        $running = @(& aca sandbox list @groupContext -l app=pizzakoordinator-worker -o json |
            ConvertFrom-Json | Where-Object { $_.state -eq 'Running' -and $_.labels.configuration -eq $manifest.labels.configuration })
        foreach ($activeWorker in $running) {
            & aca sandbox stop @groupContext --id $activeWorker.id --wait-timeout 300 -o json | Out-Null
            $stopped = & aca sandbox get @groupContext --id $activeWorker.id -o json | ConvertFrom-Json
            if ($stopped.state -ne 'Stopped') {
                throw "Worker $($activeWorker.id) could not be stopped after a failed cutover; the legacy poller remains paused to prevent duplicate order handling."
            }
        }
        $gatewayActive = & az containerapp revision show @azContext -n $GatewayAppName --revision $gatewayRevision `
            --query properties.active -o tsv
        if ($gatewayActive -eq 'false') {
            & az containerapp revision activate @azContext -n $GatewayAppName --revision $gatewayRevision -o none
            $gatewayActive = & az containerapp revision show @azContext -n $GatewayAppName --revision $gatewayRevision `
                --query properties.active -o tsv
            if ($gatewayActive -ne 'true') {
                throw "Sandbox deployment failed and the prior Gateway revision could not be restored. Original error: $deploymentError"
            }
        }
    }
    throw $deploymentError
}
