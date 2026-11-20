param(
    [Parameter(Mandatory = $true)]
    [string]$Prompt
)

$ErrorActionPreference = 'Stop'
$foundryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\foundry\pizzaops')).Path
$previousAlpha = $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS
$previousUserAgent = $env:AZURE_DEV_USER_AGENT
try {
    $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS = 'true'
    $env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
    Push-Location $foundryRoot
    try {
        & azd ai agent invoke pizzaops-agent $Prompt
        if ($LASTEXITCODE -ne 0) {
            throw 'PizzaOps smoke invocation failed.'
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($null -eq $previousAlpha) {
        Remove-Item Env:\AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS -ErrorAction SilentlyContinue
    }
    else {
        $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS = $previousAlpha
    }

    if ($null -eq $previousUserAgent) {
        Remove-Item Env:\AZURE_DEV_USER_AGENT -ErrorAction SilentlyContinue
    }
    else {
        $env:AZURE_DEV_USER_AGENT = $previousUserAgent
    }
}
