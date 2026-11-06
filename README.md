# Pizza ordering MVP

Blazor Web App and JSON API for a pizza catalog and delivery orders, plus a Microsoft Foundry Managed Harness Agent definition. The catalog is backed by Azure Cosmos DB, uploaded images by a private Azure Blob container, and orders by Azure SQL when running in Azure. Local development uses an in-memory catalog/orders store and seeds ten menu items.

## Run and test locally

Requires the .NET 10 SDK.

```powershell
# Terminal 1: Catalog
$env:Pizza__StorageMode = 'memory'
$env:ASPNETCORE_ENVIRONMENT = 'Development'
dotnet run --project src\Pizza.Catalog --no-launch-profile --urls http://localhost:5080
# Terminal 2: Orders
$env:Pizza__StorageMode = 'memory'
$env:Pizza__CatalogUrl = 'http://localhost:5080'
$env:ASPNETCORE_ENVIRONMENT = 'Development'
dotnet run --project src\Pizza.Orders --no-launch-profile --urls http://localhost:5081
dotnet test PizzaOrdering.slnx
```

Catalog serves the menu at `/` on port 5080. Orders serves order management at `/orders` (also `/`)
on port 5081. Both applications include **API documentation** in navigation at `/api-docs`, with
request/response schemas, validation limits, status codes, image uploads and curl examples.
Catalog and Orders APIs must be called on their respective service origins:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/catalog/pizzas` | List the catalog |
| `GET` | `/api/catalog/pizzas/{id}` | Read one pizza |
| `POST` | `/api/catalog/pizzas` | Add a pizza |
| `PUT` | `/api/catalog/pizzas/{id}` | Edit a pizza |
| `DELETE` | `/api/catalog/pizzas/{id}` | Delete a pizza |
| `POST` | `/api/catalog/pizzas/{id}/image` | Upload a JPEG, PNG, or WebP image (max 5 MB) |
| `GET` | `/api/catalog/images/{key}` | Read an uploaded image |
| `POST` | `/api/orders/` | Place an order with one or more catalog IDs and quantities |
| `GET` | `/api/orders/` | List orders |
| `GET` | `/api/orders/{id}` | Read one order |
| `PUT` | `/api/orders/{id}/status` | Advance one step: New → Preparing → Out for delivery → Completed |

Order prices are read from the live catalog and saved as a snapshot; clients cannot choose a price. The order API rejects unavailable pizzas and quantities outside 1–50. The menu's sample images are illustrative; uploaded photos are stored in Blob Storage and served through the app so the container can remain private.

### Managing pizzas and currency

Use **Add pizza** above the menu to open and focus the management form. Enter a name, description,
price and availability, then submit. **Edit** opens the same form with the selected pizza's values
and scrolls it into view on desktop and mobile. **Cancel** clears the draft; adding or cancelling
never changes an existing pizza. After creation, use **Change photo** on its card to upload an image.
The form uses the same validation rules as the Catalog service and API.

The original source defines no business currency. Both UIs now format decimal amounts consistently,
independently of the host OS culture, without the invariant-culture `¤` symbol or an inferred local
currency. Until the business currency is confirmed, amounts have two decimal places and no currency
symbol, with an explicit unconfigured notice. Set `Pizza:CurrencyCode` (environment variable
`Pizza__CurrencyCode`) to the confirmed three-letter uppercase ISO currency code **on both services**
to display that code next to prices and totals. No currency is selected by default, stored prices
are not converted, and JSON API contracts are unchanged.

Cross-service navigation uses `Pizza:OrdersUrl` on Catalog and the existing `Pizza:CatalogUrl` on
Orders. Values must be HTTPS origins (loopback HTTP is allowed in Development). Without an Orders
origin, Catalog retains its previous relative link. Configure the real verified endpoint only after
the replacement is healthy; no source code embeds the future Orders hostname.

### Fresh private Azure stack

The current approved design is `.azure/infrastructure-plan.json`. `infra/main.bicep` is
subscription-scoped and creates `rg-jjazure-ai-pizza-apps` in Sweden Central, plus the explicitly
named Container Apps managed networking group `rg-jjazure-ai-pizza-apps-managed`.
The stopped additive migration in `.azure/deployment-plan.md`, `infra.bak/`, and `azure.yaml`
is historical, not the current deployment entry point. Do not run its old hooks or reuse its URLs.
The new SQL database starts empty; the Catalog seeds its sample menu. No old backup is assumed.

The foundation module creates a VNet-integrated Consumption Container Apps environment, private
SQL endpoint/DNS with public SQL access disabled and Entra-only authentication, serverless Cosmos DB,
private Blob container, ACR Basic and managed identities. Catalog/Orders HTTPS web APIs are public,
unauthenticated demo endpoints: use synthetic data only. This is not a production security boundary.
Cosmos and Blob also use private endpoints and private DNS in the existing endpoint subnet. This
approved extension accommodates organization policies that enforce disabled public data access.
Registry and Foundry endpoints remain authenticated public endpoints.
Storage/registry/Cosmos endpoints require identity authentication; Blob anonymous access and account
keys, Cosmos local authentication and the ACR admin account are disabled.

Set `PIZZA_SQL_ADMIN_OBJECT_ID` and `PIZZA_SQL_ADMIN_DISPLAY_NAME` to the verified final Entra user,
then run read-only preflight from the repository root:

```powershell
az bicep build --file infra\main.bicep --stdout > $null
az deployment sub validate --location swedencentral --template-file infra\main.bicep --parameters infra\main.bicepparam
az deployment sub what-if --location swedencentral --template-file infra\main.bicep --parameters infra\main.bicepparam
```

Provisioning and remote image builds require the separate validated-plan deployment approval.
After that approval, execute the subscription deployment with the same template/parameters.
Foundation and Foundry are independent deployment branches. Build Catalog, Orders and SQL
initializer images from current source in parallel through the new ACR (or an available Linux
Docker engine), using their respective Dockerfiles. The root `.dockerignore` allowlists source
and excludes credentials, local data, stale publish output, infrastructure and binaries.
All runtime images must be supplied as actual immutable registry digests; never deploy validation
placeholder images. Empty image parameters intentionally omit the associated app/job.

Bootstrap and verify SQL before enabling Orders:

1. For a new empty deployment, explicitly set `bootstrapEnabled=true`; supply the initializer image
   and start the no-ingress job. Defaults are false to prevent recreating a cleaned-up administrator.
2. Require job success and logs proving private DNS/TCP, schema, correct Orders application SID,
   no database roles and exactly CONNECT plus SELECT/INSERT/UPDATE on `dbo.PizzaOrders`.
3. Set `bootstrapEnabled=false` to hand the SQL administrator child resource to the approved final
   Entra user. Keep app images empty until schema/grants are verified.
4. Run the existing job once with command `dotnet Pizza.SqlInitializer.dll --verify-revoked`
   and require the specific SQL login-denied result, not a DNS/network error or generic failure.
5. Explicitly delete the exact temporary job, its AcrPull role assignment and initializer identity
   using the deployment output IDs, and verify all three are absent. Incremental omission does
   **not** delete resources. Subsequent deployments must keep `bootstrapEnabled=false`.
6. Deploy Catalog and Orders with immutable images and verified cross-service HTTPS origins.
   Verify real APIs, an order in SQL, the Orders website and persistence across a revision restart.
   Health endpoints alone are insufficient.

Do not open SQL to public/Azure-services traffic, grant broad database roles, create a public
bootstrap app or reuse identities outside the new group to work around an initialization failure.
The revised conservative estimate is approximately USD 175/month, including the additional
Cosmos/Blob private endpoints, private DNS and uncertain platform
networking allowances, not a hard billing cap. The USD 500 authorization is not an indefinite
spending guarantee; track actual usage, model tokens and resource lifetime.

### Foundry agent configuration

The new Foundry account/project/model are declared in `infra/modules/foundry.bicep`.
After both live app origins are verified, deploy `infra/agent-connections.bicep` to the new group
with that account/project and those origins. Even anonymous OpenAPI tools use explicit project
connections (`authType=None`), one for Catalog and one for Orders.

Render `agent/pizza-agent.template.json` by replacing `__CATALOG_URL__`, `__ORDERS_URL__` with the
verified HTTPS origins (no trailing slash), and `__PROJECT_ID__` with the full new project's ARM ID.
`tools/Configure-PizzaAgent.ps1` validates the approved project scope and renders/submits this template.
Submit the rendered JSON to `POST {projectEndpoint}/agents?api-version=v1`, authenticating through
the current Azure identity for `https://ai.azure.com`. Do not place access tokens in files/source.
The prompt agent uses the new `gpt-5-mini` deployment and exposes only catalog reads and order
creation, not catalog administration. It requires live IDs and explicit order confirmation.

Invoke through the agent's OpenAI responses endpoint
`{projectEndpoint}/agents/pizza-ordering-agent/endpoint/protocols/openai/responses?api-version=v1`.
Prove a real catalog tool call and confirmed synthetic order tool call; compare the returned order
ID with `/api/orders/{id}` and the Orders website. A plausible assistant message is not proof.
The source API reference remains available on each app at `/api-docs`.

### Browser and API regression checks

With local in-memory Catalog and Orders running on ports 5188 and 5189 respectively, run:

```powershell
python -m pip install playwright
python -m playwright install chromium
python tests\ui\catalog_smoke.py
# Or use installed Microsoft Edge without downloading Chromium:
python tests\ui\catalog_smoke.py --channel msedge
```

When both loopback services have cross-service origins configured, add
`--check-service-links` to check Catalog -> Orders -> Catalog navigation on desktop and mobile.

The script checks desktop and mobile create/edit/cancel/delete/photo flows, validation, actual
scroll position and keyboard focus (including reduced motion), API documentation on both services,
all documented API routes and the complete order status lifecycle. It creates synthetic data and
must run only against disposable local in-memory services, never Azure or real customer data.
Use `--catalog` and `--orders` to change loopback URLs.
For explicitly configured services, also pass `--currency-code` with the expected code to verify
matching currency displays in catalog cards, order selection and order totals.

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
