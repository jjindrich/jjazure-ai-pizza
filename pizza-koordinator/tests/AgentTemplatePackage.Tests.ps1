$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "pizza-template-test-$([guid]::NewGuid().ToString('N'))"
$blueprintId = [guid]::NewGuid().ToString()
$teamsAppId = [guid]::NewGuid().ToString()
$paths = @(
    'mvp-pizzaops\scripts\Build-AgentTemplatePackage.ps1',
    'mvp-pizzaops\teams\pizzaops-agent-factory\generate_icons.py',
    'mvp-pizzaops\teams\pizzaops-agent-factory\manifest.preview.json',
    'mvp-pizzaops\teams\pizzaops-agent-factory\agentic-user.template.json',
    'pizza-koordinator\scripts\Build-AgentTemplatePackage.ps1',
    'pizza-koordinator\teams\manifest.preview.json',
    'pizza-koordinator\teams\agentic-user.template.json'
)

try {
    foreach ($path in $paths) {
        $target = Join-Path $testRoot $path
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot $path) -Destination $target
    }

    foreach ($project in @('mvp-pizzaops', 'pizza-koordinator')) {
        $script = Join-Path $testRoot "$project\scripts\Build-AgentTemplatePackage.ps1"
        $failed = $false
        try { & $script -BlueprintId $blueprintId -TeamsAppId 'invalid' }
        catch { $failed = $true }
        if (-not $failed -or (Test-Path (Join-Path $testRoot "$project\.local"))) {
            throw "$project must reject an invalid Teams app ID before creating a package."
        }

        & $script -BlueprintId $blueprintId -TeamsAppId $teamsAppId
        $packageName = if ($project -eq 'mvp-pizzaops') { 'pizzaops-agent-template-1.0.0.zip' } else { 'pizzakoordinator-agent-template-1.0.0.zip' }
        $package = Join-Path $testRoot "$project\.local\$packageName"
        $unpacked = Join-Path $testRoot "$project\unpacked"
        Expand-Archive -LiteralPath $package -DestinationPath $unpacked
        $manifest = Get-Content (Join-Path $unpacked 'manifest.json') -Raw | ConvertFrom-Json
        $agentic = Get-Content (Join-Path $unpacked $manifest.agenticUserTemplates[0].file) -Raw | ConvertFrom-Json
        if ($manifest.id -ne $teamsAppId -or $agentic.agentIdentityBlueprintId -ne $blueprintId) {
            throw "$project package must contain the supplied Teams app ID and blueprint ID."
        }
        if (-not (Test-Path (Join-Path $unpacked 'color.png')) -or -not (Test-Path (Join-Path $unpacked 'outline.png'))) {
            throw "$project package must contain both Teams icons."
        }
    }
    'Agent template package checks passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
