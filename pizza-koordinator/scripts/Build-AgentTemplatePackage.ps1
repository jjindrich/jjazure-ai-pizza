param(
    [Parameter(Mandatory = $true)]
    [string]$BlueprintId
)

$ErrorActionPreference = 'Stop'
$koordinatorRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = Split-Path $koordinatorRoot -Parent
$templateRoot = Join-Path $koordinatorRoot 'teams'
$staging = Join-Path $koordinatorRoot '.local\agent-template'
$package = Join-Path $koordinatorRoot '.local\pizzakoordinator-agent-template-1.0.0.zip'

# Icons come from the MVP generator (its outputs are git-ignored there).
$mvpTemplate = Join-Path $repoRoot 'mvp-pizzaops\teams\pizzaops-agent-factory'
& python (Join-Path $mvpTemplate 'generate_icons.py')

Remove-Item $staging, $package -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $staging -Force | Out-Null
Copy-Item (Join-Path $templateRoot 'manifest.preview.json') (Join-Path $staging 'manifest.json')
Copy-Item (Join-Path $mvpTemplate 'color.png'), (Join-Path $mvpTemplate 'outline.png') $staging

$agentic = Get-Content (Join-Path $templateRoot 'agentic-user.template.json') -Raw | ConvertFrom-Json
$agentic.agentIdentityBlueprintId = $BlueprintId
$agentic | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $staging 'agentic-user.template.json')

Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $package
Write-Host "Agent template package: $package"
