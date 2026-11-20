# PizzaOps deployed state

Deployment and Teams reply authentication were updated on 2026-11-20 in tenant
`b48accae-439a-467a-9fbf-8ad011508424`.

## Azure

| Resource | Deployed value |
|---|---|
| Subscription | `80214fc0-7aff-43b6-bbff-cf81a36cbb10` |
| Resource group | `rg-jjazure-ai-mvp-pizzaops` |
| Region | Sweden Central |
| API | `https://ca-pizzaops-api-v2.livelysand-b75eab52.swedencentral.azurecontainerapps.io` |
| API image | `crpizzaopsmvpi2jyp62.azurecr.io/pizzaops-api@sha256:f3463b47531e9a5c26c35a063321dbd3f64e2c82b24136b13eb653e1869225a5` |
| Container App revision | `ca-pizzaops-api-v2--0000005` |
| Container Apps environment | `cae-pizzaops-private-mvp`, VNet-integrated |
| Service Bus queue | `pizzaops-wakeups` |
| Cosmos database | `pizzaops` (`tasks`, `events`) |
| Foundry endpoint | `https://ai-pizzaops-mvp-i2jyp62.services.ai.azure.com/api/projects/pizzaops` |
| Foundry project identity client ID | `de6a798d-6fa8-4114-a89d-882d10029a62` |
| PizzaOps tool API client ID | `fc0eb307-a003-4545-bf6c-2d1d79fafd78` |

The API health endpoint returned `Healthy`. The earlier main app environment
was not VNet-integrated and could not reach Cosmos DB with public access
disabled; use the private-network app above without opening the Cosmos firewall.

The Teams bridge now creates Foundry conversations through the managed-harness
agent endpoint (`/agents/pizzaops-agent/endpoint/protocols/openai/conversations`)
rather than the project-level conversation route. A stale conversation ID is
replaced automatically on a 404 and the new ID is written back to the durable
task.
Responses use structured `CreateResponseOptions` and the agent endpoint's
`POST /responses` route, rather than treating the prompt as a response ID.

## Foundry

The deployed `pizzaops-agent` is version 2:

- `kind: prompt`;
- `harness.type: microsoft_copilot_preview`;
- model `gpt-5-mini`;
- four version-pinned Skills;
- OpenAPI connection `pizzaops-openapi` using Project Managed Identity.

Fresh-conversation greeting:

> Jsem PizzaOps — asistent pro plánování workshopů, kalendáře a rozvoz pizzy.

Authenticated OpenAPI test returned target arrival `12:25` and order deadline
`11:45` for lunch `12:30` with a 40-minute delivery duration and five-minute
serving buffer.

## Microsoft 365 / Agent 365

| Resource | Value |
|---|---|
| AI teammate blueprint client ID | `d935a216-c452-4e0b-93e9-96ef4141d64e` |
| Blueprint service principal | `6dadbaf5-f5bb-4486-aed7-b99bcb698408` |
| Messaging endpoint | `https://ca-pizzaops-api-v2.livelysand-b75eab52.swedencentral.azurecontainerapps.io/api/messages` |
| Bridge UAMI client ID | `c3f39f3f-613f-4fb7-9219-85716161cedf` |
| Bridge UAMI principal ID | `6d82b2a5-c94d-4136-a757-ec71692723ea` |
| Direct Foundry Teams app | `27cbaae1-2490-4724-9f4f-d65118d7a054` |
| Direct Foundry publish title | `T_b102dbd8-a11f-d462-1fc4-370ba663c08a` |

The A365 CLI reported setup completed successfully, the blueprint was reused on
the reconciliation run, tenant-wide permissions were granted, and the
messaging endpoint was registered. The blueprint's federated credential uses
the bridge UAMI's principal ID as its subject, the tenant v2 issuer, and
`api://AzureADTokenExchange` as its audience. Graph calendar/online-meeting
delegated scopes are consented.

### Agent 365 instance

The instance was provisioned with the referenced
`tkubica12/agent-demos/autopilots-on-azure/scripts/provision_agent365_instance.py`.

| Property | Value |
|---|---|
| Agent Identity | `3cfe8c77-57f8-46bb-9565-bbb551dd5237` |
| Agent Identity display name | PizzaOps Identity |
| Agent User | `b075d28f-6246-4630-aa69-7ef99f2b837f` |
| UPN | `pizzaops@jjazdev.org` |
| Usage location | CZ |
| Sponsor | JJ Admin (`63963f49-be4b-46ca-8d95-fa33e9777a22`) |

The Agent User is enabled as a Member and has `AGENT_365`,
`Microsoft_365_Copilot`, `Microsoft_365_E5_(no_Teams)`,
`Microsoft_Teams_Enterprise_New`, and `FLOW_FREE`.

The idempotent provisioning state is stored locally under
`.local/agent365/instance.pizzaops.json` and is ignored by Git. Re-running the
same command reuses these recorded object IDs.

The final agent-template ZIP is generated locally at:

`mvp-pizzaops/.local/pizzaops-agent-template-1.0.0.zip`

The ZIP was prepared for the tenant's ALM/admin upload; the desktop file-picker
flow did not complete in this session. A later Teams greeting received a
Czech capabilities response without a technical exception. Its message IDs
encode timestamps approximately 48 seconds apart; the 10-second response
requirement has not been demonstrated.
