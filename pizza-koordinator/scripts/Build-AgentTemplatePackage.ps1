param(
    [Parameter(Mandatory = $true)]
    [string]$BlueprintId,
    [string]$TeamsAppId = $env:PIZZAKOORDINATOR_TEAMS_APP_ID
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
foreach ($name in @('BlueprintId', 'TeamsAppId')) {
    $value = Get-Variable $name -ValueOnly
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$name must be a non-empty GUID. Specify TeamsAppId or PIZZAKOORDINATOR_TEAMS_APP_ID."
    }
}
$koordinatorRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = Split-Path $koordinatorRoot -Parent
$templateRoot = Join-Path $koordinatorRoot 'teams'
$staging = Join-Path $koordinatorRoot '.local\agent-template'
$package = Join-Path $koordinatorRoot '.local\pizzakoordinator-agent-template-1.0.0.zip'

# Run a copy of the MVP generator, leaving the MVP directory untouched.
$mvpTemplate = Join-Path $repoRoot 'mvp-pizzaops\teams\pizzaops-agent-factory'
Remove-Item $staging, $package -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $staging -Force | Out-Null
Copy-Item (Join-Path $mvpTemplate 'generate_icons.py') $staging
try { & python (Join-Path $staging 'generate_icons.py') }
finally { Remove-Item -LiteralPath (Join-Path $staging 'generate_icons.py') -Force }
$manifest = Get-Content (Join-Path $templateRoot 'manifest.preview.json') -Raw | ConvertFrom-Json
$manifest.id = $TeamsAppId
$manifest | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $staging 'manifest.json')

$agentic = Get-Content (Join-Path $templateRoot 'agentic-user.template.json') -Raw | ConvertFrom-Json
$agentic.agentIdentityBlueprintId = $BlueprintId
$agentic | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $staging 'agentic-user.template.json')

Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $package
Write-Host "Agent template package: $package"
