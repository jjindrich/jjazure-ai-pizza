param(
    [string]$BlueprintId = $env:PIZZAOPS_BLUEPRINT_ID,
    [string]$TeamsAppId = $env:PIZZAOPS_TEAMS_APP_ID
)

$ErrorActionPreference = 'Stop'
foreach ($name in @('BlueprintId', 'TeamsAppId')) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse((Get-Variable $name -ValueOnly), [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$name must be a non-empty GUID; provide it as a parameter or PIZZAOPS_* environment variable."
    }
}
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$templateRoot = Join-Path $repoRoot 'teams\pizzaops-agent-factory'
$staging = Join-Path $repoRoot '.local\pizzaops-agent-template'
$package = Join-Path $repoRoot '.local\pizzaops-agent-template-1.0.0.zip'

& python (Join-Path $templateRoot 'generate_icons.py')
if ($LASTEXITCODE -ne 0) { throw 'Could not generate the PizzaOps package icons.' }
if (Test-Path $staging) {
    Remove-Item $staging -Recurse -Force
}
New-Item -ItemType Directory -Path $staging -Force | Out-Null

Copy-Item (Join-Path $templateRoot 'manifest.preview.json') (Join-Path $staging 'manifest.json')
Copy-Item (Join-Path $templateRoot 'agentic-user.template.json') (Join-Path $staging 'pizzaops-agentic-user.json')
Copy-Item (Join-Path $templateRoot 'color.png') (Join-Path $staging 'color.png')
Copy-Item (Join-Path $templateRoot 'outline.png') (Join-Path $staging 'outline.png')

$manifest = Get-Content (Join-Path $staging 'manifest.json') -Raw | ConvertFrom-Json
$manifest.id = $TeamsAppId
$manifest.agenticUserTemplates[0].file = 'pizzaops-agentic-user.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $staging 'manifest.json')
$agentic = Get-Content (Join-Path $staging 'pizzaops-agentic-user.json') -Raw | ConvertFrom-Json
$agentic.agentIdentityBlueprintId = $BlueprintId
$agentic | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $staging 'pizzaops-agentic-user.json')

if (Test-Path $package) {
    Remove-Item $package -Force
}
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $package
Write-Host "Agent template package: $package"
