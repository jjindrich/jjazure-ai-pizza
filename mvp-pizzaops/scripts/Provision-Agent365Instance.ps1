[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$SourceCheckout = (Join-Path (Join-Path $PSScriptRoot '..') '.local\agent-demos'),
    [string]$OwnerId = '63963f49-be4b-46ca-8d95-fa33e9777a22',
    [string]$BlueprintId = 'd935a216-c452-4e0b-93e9-96ef4141d64e',
    [string]$TenantId = 'b48accae-439a-467a-9fbf-8ad011508424',
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
    [string]$InstanceName = 'pizzaops',
    [string]$AgentUpn = 'pizzaops@jjazdev.org',
    [string]$DisplayName = 'PizzaOps',
    [string]$MailNickname = 'pizzaops',
    [string]$IdentityDisplayName = 'PizzaOps Identity',
    [ValidatePattern('^[A-Z]{2}$')]
    [string]$UsageLocation = 'CZ',
    [string[]]$LicenseSkus = @(
        'AGENT_365', 'Microsoft_365_Copilot', 'Microsoft_365_E5_(no_Teams)',
        'Microsoft_Teams_Enterprise_New', 'FLOW_FREE'
    ),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
foreach ($name in @('OwnerId', 'BlueprintId', 'TenantId')) {
    $value = Get-Variable $name -ValueOnly
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$name must be a non-empty object or application GUID."
    }
}
foreach ($name in @('AgentUpn', 'DisplayName', 'MailNickname', 'IdentityDisplayName')) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable $name -ValueOnly))) {
        throw "$name must not be empty."
    }
}
if ($AgentUpn -notmatch '^[^@\s]+@[^@\s]+$') {
    throw 'AgentUpn must be a user principal name with a domain.'
}
if ($InstanceName -ne 'pizzaops' -and (
    -not $PSBoundParameters.ContainsKey('AgentUpn') -or
    -not $PSBoundParameters.ContainsKey('MailNickname') -or
    -not $PSBoundParameters.ContainsKey('DisplayName')
)) {
    throw 'For a new InstanceName, specify AgentUpn, MailNickname and DisplayName explicitly.'
}
if (-not $PSBoundParameters.ContainsKey('IdentityDisplayName') -and $InstanceName -ne 'pizzaops') {
    $IdentityDisplayName = "$DisplayName Identity"
}
if (@($LicenseSkus).Count -eq 0 -or @($LicenseSkus | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_.Contains(',') }).Count -gt 0) {
    throw 'Each LicenseSkus entry must be non-empty and contain no comma.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sampleRoot = Join-Path $SourceCheckout 'autopilots-on-azure'
$script = Join-Path $sampleRoot 'scripts\provision_agent365_instance.py'
$stateDirectory = Join-Path $repoRoot '.local\agent365'
$state = Join-Path $stateDirectory "instance.$InstanceName.json"
$bindingPath = Join-Path $stateDirectory "instance.$InstanceName.binding.json"

if (-not (Test-Path $script)) {
    throw "Provisioning script was not found at '$script'. Clone https://github.com/tkubica12/agent-demos under .local first."
}

$tenant = & az account show --query tenantId --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tenant)) {
    throw 'Could not determine the signed-in Azure CLI tenant.'
}
if ($tenant.Trim() -ine $TenantId) {
    throw "Azure CLI is signed in to tenant '$($tenant.Trim())', not the requested tenant '$TenantId'."
}

$binding = [ordered]@{
    tenantId = $TenantId.ToLowerInvariant()
    blueprintId = $BlueprintId.ToLowerInvariant()
    ownerId = $OwnerId.ToLowerInvariant()
    agentUpn = $AgentUpn.ToLowerInvariant()
}
if (Test-Path -LiteralPath $bindingPath) {
    $savedBinding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json
    foreach ($key in $binding.Keys) {
        if ($savedBinding.$key -ine $binding[$key]) {
            throw "Instance '$InstanceName' is bound to a different $key. Use a different InstanceName or restore its original settings."
        }
    }
}
elseif (Test-Path -LiteralPath $state) {
    $savedState = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
    if ($InstanceName -ne 'pizzaops' -or
        $AgentUpn -ine 'pizzaops@jjazdev.org' -or
        $TenantId -ine 'b48accae-439a-467a-9fbf-8ad011508424' -or
        $BlueprintId -ine 'd935a216-c452-4e0b-93e9-96ef4141d64e' -or
        $OwnerId -ine '63963f49-be4b-46ca-8d95-fa33e9777a22' -or
        $savedState.agentUserPrincipalName -ine $AgentUpn) {
        throw "Unbound existing state '$state' cannot be safely matched to this request. Preserve it and investigate before continuing."
    }
}

if (($WhatIfPreference -or -not $DryRun) -and -not $PSCmdlet.ShouldProcess(
    "$AgentUpn in tenant $TenantId",
    "Create or reuse an Agent Identity and Agent User, set usage location, and assign licenses"
)) {
    return
}

if (-not $DryRun -and -not (Test-Path -LiteralPath $bindingPath)) {
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    $bindingJson = $binding | ConvertTo-Json
    $stream = [System.IO.File]::Open($bindingPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
        try { $writer.Write($bindingJson) } finally { $writer.Dispose() }
    }
    finally { $stream.Dispose() }
}

Push-Location $sampleRoot
try {
    $arguments = @(
        '-m', 'scripts.provision_agent365_instance'
    )
    if ($DryRun) {
        $arguments += '--dry-run'
    }
    $arguments += @(
        'provision',
        '--state-name', $InstanceName,
        '--owner-id', $OwnerId,
        '--agent-blueprint-id', $BlueprintId,
        '--agent-upn', $AgentUpn,
        '--display-name', $DisplayName,
        '--mail-nickname', $MailNickname,
        '--identity-display-name', $IdentityDisplayName,
        '--usage-location', $UsageLocation,
        '--license-skus', ($LicenseSkus -join ','),
        '--state-file', $state
    )
    & python @arguments
    if ($LASTEXITCODE -ne 0) {
        throw 'PizzaOps Agent 365 instance provisioning failed.'
    }
}
finally {
    Pop-Location
}
