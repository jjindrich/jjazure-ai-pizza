[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Image,
    [string]$SubscriptionId = '80214fc0-7aff-43b6-bbff-cf81a36cbb10',
    [string]$ResourceGroup = 'rg-jjazure-ai-pizza-apps',
    [string]$ContainerApp = 'ca-pizzakoordinator'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

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
