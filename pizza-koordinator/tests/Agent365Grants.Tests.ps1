$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\Agent365Grants.ps1')

if ((Add-Agent365GrantScope -ExistingScopes 'Other.Scope' -RequiredScope 'AgentData.ReadWrite') -ne 'Other.Scope AgentData.ReadWrite') {
    throw 'Adding a scope must preserve existing permissions.'
}
if ((Add-Agent365GrantScope -ExistingScopes 'Other.Scope AgentData.ReadWrite' -RequiredScope 'AgentData.ReadWrite') -ne 'Other.Scope AgentData.ReadWrite') {
    throw 'Adding an existing scope must not duplicate it.'
}
if ((Add-Agent365GrantScope -ExistingScopes 'Mail.Send Mail.Send Calendars.ReadWrite' -RequiredScope 'Mail.Send ChatMessage.Send') -ne 'Mail.Send Calendars.ReadWrite ChatMessage.Send') {
    throw 'Adding several scopes must deduplicate and preserve existing permissions.'
}
if (-not (Test-Agent365GrantScope -ExistingScopes 'A B C' -RequiredScope 'C A') -or (Test-Agent365GrantScope -ExistingScopes 'A B' -RequiredScope 'A D')) {
    throw 'Scope check must require every requested scope.'
}

$resource = [guid]::NewGuid().ToString()
$otherResource = [guid]::NewGuid().ToString()
$appIds = @('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')
function az {
    $global:LASTEXITCODE = 0
    if ($args[4] -eq $appIds[0]) { return $resource }
    if ($args[4] -eq $appIds[1]) { return $otherResource }
    if ($args[4] -eq '33333333-3333-3333-3333-333333333333') { return '' }
    throw 'Unexpected resource application.'
}
$resolved = Resolve-Agent365GrantResources -ScopesByAppId @{
    $appIds[0] = 'First.Scope'
    $appIds[1] = 'Second.Scope'
}
if ($resolved.ByAppId[$appIds[0]] -ne $resource -or $resolved.ByPrincipalId[$otherResource] -ne 'Second.Scope') {
    throw 'Grant resources must be resolved from application IDs to the current tenant principal IDs.'
}
$failed = $false
try { Resolve-Agent365GrantResources -ScopesByAppId @{ '33333333-3333-3333-3333-333333333333' = 'Missing.Scope' } }
catch { $failed = $true }
if (-not $failed) { throw 'A missing resource principal must stop grant configuration.' }
$grant = [pscustomobject]@{
    resourceId = $resource
    consentType = 'AllPrincipals'
    scope = 'AgentData.ReadWrite'
}
$inheritable = [pscustomobject]@{
    resourceAppId = '5a807f24-c9de-44ee-a3a7-329e88a00ffc'
    inheritableScopes = [pscustomobject]@{ kind = 'allAllowed' }
}
$grants = [pscustomobject]@{ value = @($grant) }
$inheritance = [pscustomobject]@{ value = @($inheritable) }
Assert-Agent365MessagingGrant -Grants $grants -Inheritance $inheritance -MessagingResourceId $resource
$enumerated = [pscustomobject]@{
    value = @([pscustomobject]@{
        resourceAppId = $inheritable.resourceAppId
        inheritableScopes = [pscustomobject]@{ kind = 'enumerated'; scopes = @('AgentData.ReadWrite') }
    })
}
Assert-Agent365MessagingGrant -Grants $grants -Inheritance $enumerated -MessagingResourceId $resource

foreach ($scenario in @('missing', 'wrong-scope', 'wrong-consent', 'noninheritable', 'paginated')) {
    $testGrant = $grant.PSObject.Copy()
    $testInheritance = $inheritable.PSObject.Copy()
    $testGrants = [pscustomobject]@{ value = @($testGrant); '@odata.nextLink' = $null }
    $testInheritances = [pscustomobject]@{ value = @($testInheritance) }
    switch ($scenario) {
        'missing' { $testGrants.value = @() }
        'wrong-scope' { $testGrant.scope = 'AgentData.ReadWrite.Other' }
        'wrong-consent' { $testGrant.consentType = 'Principal' }
        'noninheritable' { $testInheritance.inheritableScopes = [pscustomobject]@{ kind = 'noScopes' } }
        'paginated' { $testGrants.'@odata.nextLink' = 'next' }
    }
    $failed = $false
    try { Assert-Agent365MessagingGrant -Grants $testGrants -Inheritance $testInheritances -MessagingResourceId $resource }
    catch { $failed = $true }
    if (-not $failed) { throw "Expected $scenario grant validation to fail." }
}
'Agent 365 messaging grant checks passed.'
