function Assert-FoundryDeliveryCall {
    param([Parameter(Mandatory = $true)]$Response)

    $calls = @($Response.output | Where-Object type -eq 'openapi_call')
    if ($Response.status -ne 'completed' -or $calls.Count -ne 1 -or
        $calls[0].name -ne 'pizzakoordinator_operations___listDeliveries' -or $calls[0].status -ne 'completed' -or
        [string]::IsNullOrWhiteSpace($calls[0].call_id)) {
        throw 'Foundry did not complete the expected read-only listDeliveries call.'
    }

    $results = @($Response.output | Where-Object {
        $_.type -eq 'openapi_call_output' -and $_.call_id -eq $calls[0].call_id
    })
    if ($results.Count -ne 1 -or $results[0].name -ne $calls[0].name -or
        $results[0].status -ne 'completed' -or $null -eq $results[0].output -or
        $null -eq $results[0].output.PSObject.Properties['array_response_data'] -or
        $results[0].output.array_response_data -isnot [array]) {
        throw 'Foundry did not return a completed listDeliveries array response.'
    }
}
