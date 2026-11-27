$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\FoundryToolVerification.ps1')

function New-Response {
    [pscustomobject]@{
        status = 'completed'
        output = @(
            [pscustomobject]@{
                type = 'openapi_call'
                name = 'pizzakoordinator_operations___listDeliveries'
                call_id = 'call-1'
                status = 'completed'
            },
            [pscustomobject]@{
                type = 'openapi_call_output'
                name = 'pizzakoordinator_operations___listDeliveries'
                call_id = 'call-1'
                status = 'completed'
                output = [pscustomobject]@{ array_response_data = @() }
            }
        )
    }
}

Assert-FoundryDeliveryCall -Response (New-Response)
foreach ($scenario in 'no-call', 'failed-call', 'failed-result', 'wrong-call', 'missing-call-id', 'missing-array', 'invalid-array') {
    $response = New-Response
    switch ($scenario) {
        'no-call' { $response.output = @() }
        'failed-call' { $response.output[0].status = 'failed' }
        'failed-result' { $response.output[1].status = 'failed' }
        'wrong-call' { $response.output[1].call_id = 'different' }
        'missing-call-id' { $response.output[0].call_id = $null; $response.output[1].call_id = $null }
        'missing-array' { $response.output[1].output = [pscustomobject]@{} }
        'invalid-array' { $response.output[1].output.array_response_data = 'not-an-array' }
    }
    $failed = $false
    try { Assert-FoundryDeliveryCall -Response $response }
    catch { $failed = $true }
    if (-not $failed) { throw "Expected $scenario verification to fail." }
}
'Foundry read-only tool response checks passed.'
