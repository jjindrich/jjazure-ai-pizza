# Test PizzaOps

## Fast local validation

No local command can validate tenant licensing, an Agentic User, Teams
installation, or Graph consent. Local checks are therefore split from tenant
acceptance tests.

```powershell
dotnet restore PizzaOps.slnx
dotnet build PizzaOps.slnx --configuration Release --no-restore
dotnet test tests\PizzaOps.Tests --configuration Release --no-build
python tests\pizzaops_validate.py
pwsh -NoProfile -File tests\Update-PizzaOpsApi.Tests.ps1
pwsh -NoProfile -File tests\Provision-Agent365Instance.Tests.ps1
az bicep build --file infra\pizzaops\main.bicep --stdout > $null
```

The PizzaOps tests cover:

- arrival and order-deadline arithmetic across a time zone;
- missing or invalid delivery input;
- policy classification for autonomous, approval, and denied operations;
- approval input binding;
- optimistic concurrency/version conflicts;
- idempotent duplicate event handling;
- exact wakeup eligibility and classification.
- the Foundry response request's HTTP method, agent endpoint, input, and
  conversation ID.

The tests inject in-memory stores and clients. They do not make live Foundry,
Graph, Teams, Cosmos, Service Bus, or payment calls.

## Contract validation

`foundry/pizzaops/azure.yaml` and the running PizzaOps.Api `/openapi/v1.json`
must expose the same 12 operation IDs. Run the declarative check locally.
A deployment with a mismatched tool contract is not accepted even if the
agent prompt appears plausible.

## Remote Foundry smoke

After agent deployment:

```powershell
.\scripts\pizzaops\Invoke-PizzaOps.ps1 `
  -Prompt 'Plan tomorrow workshop 10:00-16:00 for 12 people. Read state and calculate the lunch plan, but do not create a meeting.'
```

Validate actual tool trace evidence. A normal model reply is not a successful
state or calendar test.

## Tenant acceptance

Run the complete [PizzaOps demonstration](pizzaops-demo.md):

1. interactive Teams activity;
2. calendar read and delivery timing;
3. exact headcount reminder with no new user prompt;
4. Graph change notification and recomputation;
5. approval-gated meeting create/update;
6. denied payment;
7. replay of the same event with no duplicate outbound message.

Acceptance evidence is the set of durable IDs and operation IDs listed in the
demonstration guide. Do not retain personal message bodies in the evidence.
For the greeting, separately record whether a Czech capabilities response
without a technical exception arrived within 10 seconds. A later response is
not a pass for that timing requirement. The 2026-11-20 response was observed
but its message IDs encode timestamps approximately 48 seconds apart; the
10-second requirement remains unverified.

## Failure injection

For a production-like pilot, exercise:

- stale task version (`412`);
- duplicate Teams inbound event;
- duplicate Graph callback;
- duplicate Service Bus delivery;
- dead-lettered message;
- expired approval;
- changed canonical input after approval;
- unavailable Graph;
- blocked/uninstalled Teams app (`403 MessageWritesBlocked`);
- Foundry unavailable or rate limited;
- expired Graph subscription.

The safe outcome is a surfaced failure or bounded retry with unchanged business
state, never an extra meeting or payment-like action.
