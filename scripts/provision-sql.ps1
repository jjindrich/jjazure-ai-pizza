$ErrorActionPreference = 'Stop'

$environmentValues = azd env get-values
if ($LASTEXITCODE -ne 0) {
    throw "azd env get-values failed with exit code $LASTEXITCODE."
}

foreach ($line in $environmentValues) {
    if ($line -match '^([^=]+)=(.*)$') {
        Set-Item "env:$($Matches[1])" $Matches[2].Trim('"')
    }
}

if (-not $env:SQL_SERVER -or -not $env:SQL_DATABASE) {
    throw 'SQL_SERVER and SQL_DATABASE must be set in the azd environment.'
}

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw "'sqlcmd' is not installed or not on PATH. Install the modern go-sqlcmd tool."
}

sqlcmd `
    -S "$($env:SQL_SERVER).database.windows.net" `
    -d $env:SQL_DATABASE `
    --authentication-method ActiveDirectoryDefault `
    -i .\infra\sql\schema.sql

if ($LASTEXITCODE -ne 0) {
    throw "sqlcmd failed with exit code $LASTEXITCODE while creating the SQL schema."
}

& .\scripts\grant-sql-access.ps1
