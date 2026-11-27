function Resolve-Agent365GrantResources {
    param([Parameter(Mandatory = $true)][hashtable]$ScopesByAppId)

    $byAppId = @{}
    $byPrincipalId = @{}
    foreach ($appId in $ScopesByAppId.Keys) {
        $principalId = & az ad sp show --id $appId --query id --output tsv
        $parsed = [guid]::Empty
        if ($LASTEXITCODE -ne 0 -or -not [guid]::TryParse($principalId, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
            throw "Could not resolve the tenant service principal for resource application '$appId'."
        }
        $principalId = $parsed.ToString()
        if ($byPrincipalId.ContainsKey($principalId)) {
            throw "Multiple resource applications resolved to service principal '$principalId'."
        }
        $byAppId[$appId] = $principalId
        $byPrincipalId[$principalId] = $ScopesByAppId[$appId]
    }
    return @{ ByAppId = $byAppId; ByPrincipalId = $byPrincipalId }
}

function Add-Agent365GrantScope {
    param([string]$ExistingScopes, [Parameter(Mandatory = $true)][string]$RequiredScope)

    $scopes = @($ExistingScopes -split '\s+' | Where-Object { $_ } | Select-Object -Unique)
    foreach ($scope in ($RequiredScope -split '\s+' | Where-Object { $_ })) {
        if ($scope -notin $scopes) { $scopes += $scope }
    }
    return ($scopes -join ' ')
}

function Test-Agent365GrantScope {
    param([string]$ExistingScopes, [Parameter(Mandatory = $true)][string]$RequiredScope)

    $existing = @($ExistingScopes -split '\s+')
    return -not ($RequiredScope -split '\s+' | Where-Object { $_ -and $_ -notin $existing })
}

function Assert-Agent365MessagingGrant {
    param(
        [Parameter(Mandatory = $true)]$Grants,
        [Parameter(Mandatory = $true)]$Inheritance,
        [Parameter(Mandatory = $true)][string]$MessagingResourceId
    )

    if ($Grants.'@odata.nextLink' -or $Inheritance.'@odata.nextLink') {
        throw 'Agent 365 permission results are paginated; inspect all pages before verifying.'
    }

    $grant = @($Grants.value | Where-Object {
        $_.resourceId -eq $MessagingResourceId -and
        $_.consentType -eq 'AllPrincipals' -and
        'AgentData.ReadWrite' -in ($_.scope -split '\s+')
    })
    $inheritable = @($Inheritance.value | Where-Object {
        $_.resourceAppId -eq '5a807f24-c9de-44ee-a3a7-329e88a00ffc' -and
        ($_.inheritableScopes.kind -eq 'allAllowed' -or
            ($_.inheritableScopes.kind -eq 'enumerated' -and 'AgentData.ReadWrite' -in $_.inheritableScopes.scopes))
    })
    if ($grant.Count -ne 1 -or $inheritable.Count -ne 1) {
        throw 'Agent 365 messaging requires an inheritable AllPrincipals AgentData.ReadWrite grant on the blueprint.'
    }
}
