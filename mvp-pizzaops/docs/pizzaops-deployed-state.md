# PizzaOps deployed state

Deployment and Teams reply authentication were updated on 2026-11-20.
Tenant-specific IDs are represented by placeholders.

## Azure

| Resource | Deployed value |
|---|---|
| Subscription | `<AZURE_SUBSCRIPTION_ID>` |
| Resource group | `rg-jjazure-ai-mvp-pizzaops` |
| Region | Sweden Central |
| API | `https://ca-pizzaops-api-v2.livelysand-b75eab52.swedencentral.azurecontainerapps.io` |
| API image | `crpizzaopsmvpi2jyp62.azurecr.io/pizzaops-api@sha256:f3463b47531e9a5c26c35a063321dbd3f64e2c82b24136b13eb653e1869225a5` |
| Container App revision | `ca-pizzaops-api-v2--0000005` |
| Container Apps environment | `cae-pizzaops-private-mvp`, VNet-integrated |
| Service Bus queue | `pizzaops-wakeups` |
| Cosmos database | `pizzaops` (`tasks`, `events`) |
| Foundry endpoint | `https://ai-pizzaops-mvp-i2jyp62.services.ai.azure.com/api/projects/pizzaops` |
| Foundry project identity client ID | `<FOUNDRY_PROJECT_CLIENT_ID>` |
| PizzaOps tool API client ID | `<PIZZAOPS_TOOL_API_CLIENT_ID>` |

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
| AI teammate blueprint client ID | `<BLUEPRINT_CLIENT_ID>` |
| Blueprint service principal | `<BLUEPRINT_SERVICE_PRINCIPAL_ID>` |
| Messaging endpoint | `https://ca-pizzaops-api-v2.livelysand-b75eab52.swedencentral.azurecontainerapps.io/api/messages` |
| Bridge UAMI client ID | `<BRIDGE_UAMI_CLIENT_ID>` |
| Bridge UAMI principal ID | `<BRIDGE_UAMI_PRINCIPAL_ID>` |
| Direct Foundry Teams app | `<FOUNDRY_TEAMS_APP_ID>` |
| Direct Foundry publish title | `<FOUNDRY_PUBLISH_TITLE>` |

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
| Agent Identity | `<AGENT_IDENTITY_ID>` |
| Agent Identity display name | PizzaOps Identity |
| Agent User | `<AGENT_USER_ID>` |
| UPN | `pizzaops@jjazdev.org` |
| Usage location | CZ |
| Sponsor | JJ Admin (`<SPONSOR_OBJECT_ID>`) |

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
