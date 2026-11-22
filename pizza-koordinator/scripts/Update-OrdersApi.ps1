[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-jjazure-ai-pizza-apps',
    [string]$Registry = 'crpizza22dfk5ihazv',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $VerifyOnly) {
    & dotnet test (Join-Path $repoRoot 'PizzaOrdering.slnx') --nologo -v q | Out-Host
    $previous = & az containerapp show -g $ResourceGroup -n pizza-orders --query properties.template.containers[0].image -o tsv
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'pizza-koordinator\.local') -Force | Out-Null
    $previous | Set-Content (Join-Path $repoRoot 'pizza-koordinator\.local\orders-previous-image.txt')
    $tag = "koordinator-filter-$(Get-Date -Format yyyyMMddHHmmss)"
    & az acr build --registry $Registry --image "pizza-orders:$tag" --file (Join-Path $repoRoot 'src\Pizza.Orders\Dockerfile') $repoRoot --no-logs --only-show-errors | Out-Host
    $digest = & az acr repository show -n $Registry --image "pizza-orders:$tag" --query digest -o tsv
    $server = & az acr show -n $Registry --query loginServer -o tsv
    # Change only the image; retain the application's networking, identity and SQL configuration.
    & az containerapp update -g $ResourceGroup -n pizza-orders --image "$server/pizza-orders@$digest" -o none
}
$hostName = & az containerapp show -g $ResourceGroup -n pizza-orders --query properties.configuration.ingress.fqdn -o tsv
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $invalid = Invoke-WebRequest "https://$hostName/api/orders/?status=Invalid" -SkipHttpErrorCheck -TimeoutSec 30
    if ([int]$invalid.StatusCode -eq 400) { break }
    Write-Host "Waiting for Orders revision traffic to propagate (HTTP $($invalid.StatusCode))."
    Start-Sleep -Seconds 5
}
if ([int]$invalid.StatusCode -ne 400) { throw 'Deployed Orders API is not binding the status filter.' }
$orders = Invoke-RestMethod "https://$hostName/api/orders/?status=New" -TimeoutSec 30
if (@($orders | Where-Object { $_.status -ne 'New' }).Count -ne 0) { throw 'Status filter returned non-New orders.' }
Write-Host 'Orders API status filter verified.'
