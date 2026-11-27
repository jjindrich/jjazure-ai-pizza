# Deploy PizzaOps

Deployment has three independent control planes:

1. **Azure resources and the C# bridge** from Bicep and Container Apps.
2. **Foundry agent, Skills, and OpenAPI tool** from the standalone azd project.
3. **Entra/Teams Agentic User activation** from the tenant admin centers.

The repository scripts Agent identity blueprint registration and admin-consented
permissions when run by an appropriately privileged operator. Tenant ALM/app
approval and creation of the final Agentic User instance remain administrator
actions.

For the deployed MVP, registration is now scriptable with
`.\scripts\Register-AgentTemplate.ps1`. It runs the Agent 365 CLI AI teammate
setup, uses the deployed Container App `/api/messages` endpoint, applies the
UAMI federation and calendar scopes, and prepares the template ZIP. The external
tenant ALM/admin upload remains a governance action. See
[agent-template registration](pizzaops-agent-template-registration.md).

## 1. Prerequisites

Install:

- .NET 10 SDK;
- Azure CLI with Bicep;
- Azure Developer CLI 1.37 or later;
- the Foundry azd extensions used by
  `scripts/check-and-setup-dependencies.ps1` in the Microsoft Foundry skill;
- PowerShell 7.3 or later;
- Docker or Azure Container Registry Tasks for building the PizzaOps.Api image.

Sign in yourself with `az login` and `azd auth login`. A user running the Azure
deployment needs permission to create the resource group and role assignments.
Creating the blueprint, granting consent, and activating the factory require the
roles documented by the tenant and Agent 365 administrator.

Select a region supported by the Copilot harness and all required Azure
services. Confirm model quota for a reasoning/tool-calling model. A region
selection does not reserve quota.

Set `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, and `PIZZAOPS_BLUEPRINT_ID`
to the verified target GUIDs before running the bootstrap script, or provide
`-SubscriptionId`, `-TenantId`, and `-TeamsBlueprintClientId`. Registration
also requires the existing Teams app ID and bridge identity client ID; instance
provisioning requires the sponsor ID. See
[agent-template registration](pizzaops-agent-template-registration.md) for
the explicit variables and parameters. The scripts reject missing or invalid
IDs before making changes.

## 2. Build and validate locally

```powershell
dotnet restore PizzaOps.slnx
dotnet build PizzaOps.slnx --configuration Release --no-restore
dotnet test PizzaOps.slnx --configuration Release --no-build
az bicep build --file infra\pizzaops\main.bicep --stdout > $null
az bicep build --file infra\pizzaops\modules\app.bicep --stdout > $null
```

Unit tests use in-memory doubles and make no Azure, Graph, Teams, or Foundry
calls. Inspect `infra/pizzaops/main.bicepparam` before validation and replace
every tenant/project placeholder.

## 3. Deploy Azure support infrastructure

The Bicep deploys the Foundry account and project, the VNet-integrated Container
Apps environment, Cosmos private endpoint and DNS, durable state, queue,
identity, container registry, and observability resources. Public HTTPS ingress
is used for Teams, but Cosmos access uses the private network.

The bootstrap script performs two infrastructure deployments, configures Entra
application roles, builds an image in ACR and deploys the Foundry agent:

```powershell
.\scripts\Deploy-PizzaOps.ps1 -GraphWebhookClientState $existingOrNewClientState
```

This is not an image-only update: review parameters, role changes, costs and
the Graph webhook client-state value before running it. It writes the client
state to the ignored `deployment-output.json`; protect that file. Existing
deployments must supply their current client-state value. For a new deployment,
generate a cryptographically random value in memory and protect it; do not
place it in source control or shell history.

The template disables public Cosmos DB access and creates its private endpoint.
Review the what-if carefully: a bootstrap or infrastructure update changes
resources beyond the API image.

```powershell
az deployment sub validate `
  --location <region> `
  --template-file infra\pizzaops\main.bicep `
  --parameters infra\pizzaops\main.bicepparam

az deployment sub what-if `
  --location <region> `
  --template-file infra\pizzaops\main.bicep `
  --parameters infra\pizzaops\main.bicepparam

az deployment sub create `
  --name pizzaops `
  --location <region> `
  --template-file infra\pizzaops\main.bicep `
  --parameters infra\pizzaops\main.bicepparam
```

The command requires normal review and spending approval in the target
subscription.

Record the output values:

- API/Container App URL;
- ACR login server;
- Container App managed identity resource/client IDs;
- existing Foundry project identity client ID;
- Cosmos and Service Bus endpoints;
- Application Insights connection information;
- Foundry/OpenAPI audience.

Build and deploy PizzaOps.Api as an immutable digest. Never rely on a mutable
`latest` image in production.

### Update the existing API only

From `mvp-pizzaops`, after reviewing the target and approving the change:

```powershell
.\scripts\Update-PizzaOpsApi.ps1 -WhatIf
.\scripts\Update-PizzaOpsApi.ps1
```

The script checks that the target app is in the expected VNet-integrated
environment, builds in ACR with a unique tag, resolves that exact tag's
digest, updates only the `pizzaops-api` container, and checks the ready revision
and `/health`. It does not change infrastructure, Entra federation, the Teams
callback or the Foundry agent. A `-WhatIf` run performs read-only target checks
and does not build or deploy. For another environment specify
`-SubscriptionId`, `-ResourceGroup`, `-ContainerApp`, `-EnvironmentName`, and
`-Registry` explicitly. A ready/healthy revision does not prove Teams latency
or agent behavior; run the tenant acceptance tests separately.

## 4. Register the Agent identity blueprint

Follow the current [Teams agent factory setup](https://learn.microsoft.com/microsoftteams/platform/concepts/agentic-identity/agent-factory/setup):

1. Register an agent identity blueprint in the development tenant for an AI
   teammate.
2. Associate the PizzaOps Container App user-assigned managed identity as the
   blueprint credential's federated identity.
3. Set the public callback URL to
   `https://<pizzaops-api-host>/api/messages`.
4. Declare only the Microsoft Graph calendar permissions required for the
   Agentic User.
5. Supply the verified blueprint and Teams app IDs to
   `scripts\Build-AgentTemplatePackage.ps1`; it replaces placeholders in the
   generated package without modifying the source templates.
6. Inspect the generated manifest, blueprint binding and icons in the ZIP.
7. Publish the factory as a line-of-business Agent 365 app.

Do not commit the blueprint secret. The deployed service uses its managed
identity through a signed assertion for the blueprint.

## 5. Tenant activation

In the Microsoft 365 admin center, an authorized administrator:

1. enables Agent 365 and accepts the tenant terms;
2. activates the PizzaOps agent factory;
3. limits who can create/activate PizzaOps instances;
4. grants the requested Graph scopes;
5. installs the Agentic User in the required personal/channel scopes;
6. approves any tenant-wide Teams publication separately, if direct Foundry
   publication is also enabled.

Agent factory activation grants identity capabilities; it does not automatically
grant permission to every user's mailbox.

## 6. Create and deploy Foundry Skills and agent

The standalone project is `foundry/pizzaops`, so it cannot be confused with the
older pizza-ordering demo agent.

```powershell
azd env new pizzaops --no-prompt
.\scripts\pizzaops\Deploy-FoundryAgent.ps1 `
  -ProjectEndpoint 'https://<account>.services.ai.azure.com/api/projects/<project>' `
  -ApiUrl 'https://<pizzaops-api-host>' `
  -ApiAudience 'api://<pizzaops-tools-app-or-api-audience>' `
  -ModelDeployment 'gpt-5-mini'
```

The script:

- enables the managed-harness azd preview only for its process;
- creates all four Skills;
- refuses to overwrite an existing Skill version silently;
- sets the active azd environment values;
- deploys `pizzaops-agent`;
- reads the deployed definition back.

For a new Foundry project deployment, each Skill should be version 1. For an
existing project, update a Skill explicitly, then replace the returned version in
`foundry/pizzaops/azure.yaml`; do not assume the default version is the one you
want.

Read back `kind: prompt`, `harness.type: microsoft_copilot_preview`, all four
Skills, and the OpenAPI audience. A deployment that loses the harness is a
failed deployment.

## 7. Configure Graph subscriptions

Use the Agentic User credential and the target mailbox. Subscribe to the
calendar resource, use the PizzaOps.Api Graph webhook endpoint, set a
high-entropy `clientState`, and enable lifecycle notifications.

Outlook calendar subscriptions must be renewed periodically and expire in
fewer than seven days. Renewal is infrastructure lifecycle, not agent polling.
The Container App maps valid change notifications to Service Bus wakeups.

## 8. Smoke test and Teams test

Invoke Foundry without Teams:

```powershell
.\scripts\pizzaops\Invoke-PizzaOps.ps1 `
  -Prompt 'Plan tomorrow''s 10:00-16:00 workshop for 12 people. Do not write a meeting yet.'
```

Then run the end-to-end cases in
[the demonstration guide](pizzaops-demo.md). Verify tool-call IDs, task state,
approval behavior, event deduplication, proactive delivery, and the absence of
any payment tool.

## 9. Validation and deployment

Run the local validation commands above before deploying. Azure deployments are
run explicitly through the PowerShell scripts. Tenant administrator activation
and Graph subscription setup remain separate gates. Do not store credentials
or Graph `clientState` in Git.

## 10. Updates

- Skill change: update its Skill resource, pin a new immutable version, redeploy
  the agent.
- Tool change: build/publish a new API image and agent version if the contract
  changed.
- Teams metadata: publish a new app/factory package; do not change generated
  service IDs blindly.
- Prompt/model/routing: create a new immutable Foundry agent version.
- Infrastructure: validate/what-if, then use the same subscription deployment.

See [troubleshooting](pizzaops-troubleshooting.md) and
[preview limitations](pizzaops-preview-limitations.md).
