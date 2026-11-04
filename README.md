# Pizza ordering MVP

Blazor Web App and JSON API for a pizza catalog and delivery orders, plus a Microsoft Foundry Managed Harness Agent definition. The catalog is backed by Azure Cosmos DB, uploaded images by a private Azure Blob container, and orders by Azure SQL when running in Azure. Local development uses an in-memory catalog/orders store and seeds ten menu items.

## Run and test locally

Requires the .NET 10 SDK.

```powershell
dotnet run --project src\Pizza.Web
dotnet test PizzaOrdering.slnx
```

The local app serves the menu at `/`, order management at `/orders`, and these APIs:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/catalog/pizzas` | List the catalog |
| `GET` | `/api/catalog/pizzas/{id}` | Read one pizza |
| `POST` | `/api/catalog/pizzas` | Add a pizza |
| `PUT` | `/api/catalog/pizzas/{id}` | Edit a pizza |
| `DELETE` | `/api/catalog/pizzas/{id}` | Delete a pizza |
| `POST` | `/api/catalog/pizzas/{id}/image` | Upload a JPEG, PNG, or WebP image (max 5 MB) |
| `POST` | `/api/orders/` | Place an order with one or more catalog IDs and quantities |
| `GET` | `/api/orders/` | List orders |
| `GET` | `/api/orders/{id}` | Read one order |
| `PUT` | `/api/orders/{id}/status` | Advance one step: New → Preparing → Out for delivery → Completed |

Order prices are read from the live catalog and saved as a snapshot; clients cannot choose a price. The order API rejects unavailable pizzas and quantities outside 1–50. The menu's sample images are illustrative; uploaded photos are stored in Blob Storage and served through the app so the container can remain private.

## Azure and Foundry setup

`azure.yaml`, `infra/main.bicep`, `infra/main.parameters.json`, and the Dockerfile describe Container Apps, Cosmos DB, Blob Storage, Azure SQL, and the Foundry prompt agent. See `.azure/deployment-plan.md` for current validation evidence and recorded Azure deployment state; this README is not a live resource inventory.

Before provisioning:

1. Sign in to Azure CLI and Azure Developer CLI yourself, choose an azd environment and subscription, and set `AZURE_SQL_ADMIN_OBJECT_ID` and `AZURE_SQL_ADMIN_DISPLAY_NAME` in that environment. The parameter file defaults `sqlAdminPrincipalType` to `User`; use `Group` or `Application` when the SQL Entra administrator is not a user.
2. Verify that the selected region supports Container Apps, Cosmos DB serverless, Azure SQL, and the Foundry project/model you intend to use. Regional service availability does not reserve subscription quota or model capacity.
3. Install the modern `sqlcmd` tool before provisioning. The `postprovision` hook creates the idempotent `PizzaOrders` schema and grants the Container App's managed identity only `db_datareader` and `db_datawriter`. The deployment identity must be the configured SQL Entra administrator, and SQL provisioning must run from an authorized VNet-connected environment. SQL public access is disabled; do not enable it as a workaround for missing private connectivity.
4. Create or select a Foundry project with a compatible model deployment and set `model` in `azure.yaml` to its exact name. The Copilot harness requires a model supporting reasoning and tool calling. The manifest selects `gpt-5-mini`; `infra/foundry/reasoning-model.bicep` adds that deployment to an existing account (version `2025-08-07`, `DataZoneStandard` PAYG, capacity 100). Data-zone inference can route within the EU data zone, not strictly Sweden Central. After approval and validation, deploy this additive template with `az deployment group create --resource-group <foundry-resource-group> --template-file .\infra\foundry\reasoning-model.bicep --parameters accountName=<existing-account-name> --mode Incremental`. It preserves the original model and other resources. Do not silently substitute another model or SKU. Verify that the OpenAPI server in `azure.yaml` matches the deployed app's HTTPS FQDN before publishing the agent.
5. Upload and pin the local skill before deploying the agent:

   ```powershell
   azd ai skill create pizza-ordering-guidance --file .\foundry-skills\pizza-ordering-guidance\ --project-endpoint $env:AZURE_AI_PROJECT_ENDPOINT
   ```

   A new skill is published as version 1, which is pinned by `azure.yaml`. If that skill already exists in the project, create/update it deliberately and update the pinned version rather than overwriting it implicitly. Keep these independently published sources under `foundry-skills/`, not the agent project's conventional `skills/` directory: AZD auto-discovers the latter and requires sibling skill lifecycle services even when the agent already pins an existing remote skill.

   Enable the preview in the current shell when deploying or invoking the agent:

   ```powershell
   $env:AZD_ALPHA_ENABLE_AGENTS_MANAGED_HARNESS = 'true'
   $env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
   azd deploy pizza-ordering-agent --no-prompt
   ```

Deployment verification recorded on 2026-11-04: `gpt-5-mini` provisioned successfully with the configuration above, and agent version 2 is active with the Copilot harness, pinned skill version 1, OpenAPI tools, and web search. The original `gpt-4-1-mini` deployment remains intact. **The live agent catalog invocation completed successfully**, returning Capricciosa at 13.80 and Diavola at 13.20; both names, prices, and availability were independently checked against the live API. The app's `/`, `/orders`, `/health/ready`, and live catalog returned HTTP 200; SQL schema and reader/writer grants were applied through the private endpoint, and the synthetic order lifecycle persisted successfully. The read-only agent smoke test did not create an order and does not separately prove wine-search behavior.

The initial capacity 10 (10,000 TPM/10 RPM) hit model rate limits during multi-step skill/tool calls. After explicit user approval, capacity was increased to 100 (100,000 TPM/100 RPM), resolving the invocation failure. This is a PAYG rate-limit allocation, not PTU; it permits higher usage and is not a spending cap. An intermittent HTTP/2 transport failure was avoided with `$env:GODEBUG = 'http2client=0'` in the invoking PowerShell process only. Request-level token controls are not a substitute in the current preview: the service rejects `reasoning` overrides when an agent is specified and rejects `max_output_tokens` for the Copilot harness. Do not silently increase capacity, remove the skill, or substitute a different harness.

For SQL identity verification, resolve the Container App's `identity.principalId` to its Entra service principal and compare the database SID with that principal's **application/client ID**, not its object ID. `CREATE USER ... FROM EXTERNAL PROVIDER WITH OBJECT_ID` uses the object ID to resolve the principal, whereas this managed identity's stored SQL SID represents its client ID. A differing object-ID byte sequence alone does not establish that the database user is stale. Never drop an existing principal based on that comparison.

The issue names WebIQ but supplies no API contract, endpoint, or authentication details. The agent therefore uses Foundry's built-in `web_search` tool for wine-pairing lookups as an explicitly documented interim substitute; no WebIQ integration is claimed. Wire WebIQ only after its supported API and auth contract are provided.

## MVP exposure and safety limits

As requested for the MVP, there is no user authentication or authorization on the catalog or orders APIs. Endpoints are rate-limited, but that is not an access-control boundary. The Container App has external HTTPS ingress so the Foundry agent can reach it. **Do not expose this MVP to the public internet or use it for production orders containing real customer data until authentication/authorization, abuse protection, privacy/retention controls, monitoring, and an approved network boundary are added.** In particular, `/api/orders` returns customer names and delivery addresses.

The deployment uses managed identity for Cosmos DB, Storage, ACR, and SQL (no credentials are committed), plus a NAT Gateway and static egress IP for outbound Container Apps traffic. SQL, Cosmos DB, and Blob Storage public network access is disabled and the app connects through approved private endpoints and private DNS; SQL firewall rules are not used. The Sweden Central retail-price baseline is about USD 46.50/month for the NAT Gateway, one Standard static IP, Basic SQL database, and Basic registry running continuously; private endpoints/DNS, NAT data processing, Container Apps usage beyond subscription free grants, logs, Cosmos DB, Blob Storage, Foundry tokens, taxes, and negotiated discounts are additional or variable. The app scales to zero, and this Consumption plan does not enable Dedicated workload profiles or planned maintenance features. The app has external HTTPS ingress and no authentication/authorization for the MVP; do not use it for production or real customer data until authentication/authorization, abuse protection, privacy/retention controls, monitoring, and an approved network boundary are added. SQL schema and managed-identity provisioning require an authorized VNet-connected execution path. A deployment requires Azure CLI authentication, a valid Foundry project/model deployment, matching agent endpoint URL, SQL admin identity values, and the postprovision SQL hook to succeed.
