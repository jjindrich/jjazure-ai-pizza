[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Image,
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$ResourceGroup = 'rg-jjazure-ai-pizza-apps',
    # Gateway only. Sandbox Worker image changes go through Deploy-PizzaKoordinator.ps1 -ReplaceWorker.
    [string]$ContainerApp = 'ca-pizzakoordinator'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$parsedSubscription = [guid]::Empty
if (-not [guid]::TryParse($SubscriptionId, [ref]$parsedSubscription) -or $parsedSubscription -eq [guid]::Empty) {
    throw 'SubscriptionId must be a non-empty GUID; provide -SubscriptionId or AZURE_SUBSCRIPTION_ID.'
}

$query = '{image:properties.template.containers[0].image,revision:properties.latestRevisionName,fqdn:properties.configuration.ingress.fqdn}'
$before = & az containerapp show --subscription $SubscriptionId -g $ResourceGroup -n $ContainerApp --query $query -o json |
    ConvertFrom-Json
$repository = ($before.image -split '@', 2)[0]
if ($Image -notmatch "^$([regex]::Escape($repository))@sha256:[0-9a-f]{64}$") {
    throw "Image must be a digest from the existing repository $repository."
}
if ($Image -eq $before.image) {
    return [pscustomobject]@{ PreviousImage = $before.image; Image = $before.image; Revision = $before.revision }
}

if ($PSCmdlet.ShouldProcess($ContainerApp, "Update only its container image to $Image")) {
    & az containerapp update --subscription $SubscriptionId -g $ResourceGroup -n $ContainerApp `
        --image $Image --only-show-errors -o none
    $after = & az containerapp show --subscription $SubscriptionId -g $ResourceGroup -n $ContainerApp --query $query -o json |
        ConvertFrom-Json
    if ($after.image -ne $Image) { throw "Container App did not retain the requested image." }
    [pscustomobject]@{
        PreviousImage = $before.image
        Image = $after.image
        Revision = $after.revision
        HealthUrl = "https://$($after.fqdn)/health"
    }
}
