# PizzaOps infrastructure

This directory provisions the Azure support plane and Foundry project for the
PizzaOps Teams and Agentic User bridge. The Foundry agent calls the
managed-identity-protected API; only the C# bridge identity receives direct
Service Bus permissions.

The Container App is deliberately omitted when `containerImage` is empty. This
supports an initial bootstrap deployment, image publication to the resulting ACR,
and then a second deployment with the image reference.
`scripts\Deploy-PizzaOps.ps1` performs both passes.

## Resources

- VNet-integrated Consumption Container Apps environment with public HTTPS
  ingress and zero-scale HTTP/Service Bus KEDA rules.
- Authenticated private ACR with the admin account and anonymous pull disabled.
- One user-assigned identity for image pull, Key Vault, Service Bus, and scoped
  Cosmos DB access.
- Log Analytics workspace and workspace-based Application Insights.
- Service Bus namespace and the `pizzaops-wakeups` queue, with local SAS auth
  disabled.
- Serverless Cosmos DB account with public access disabled, private endpoint and private DNS, with the
  `pizzaops` database and tenant-partitioned `tasks` and `events` containers.
- Key Vault containing only the Graph webhook client-state secret. The Container
  App reads it through a Key Vault reference rather than receiving the value
  from an ARM template output.

## Required deployment inputs

Do not use the sample zero UUIDs in `main.bicepparam` for a tenant deployment.
Provide the Foundry project identity client ID, Teams blueprint client and
tenant IDs, API audience, and a high-entropy Graph client-state value. For an
existing deployment, preserve the current client-state value.

## Build and deploy

Run from the `mvp-pizzaops` root. `Dockerfile.pizzaops` uses this directory as
its build context; `.dockerignore` excludes local secrets and generated state.

```powershell
az bicep build --file infra\pizzaops\main.bicep --stdout
az bicep build-params --file infra\pizzaops\main.bicepparam --stdout
```

Use `scripts\Deploy-PizzaOps.ps1` for the reviewed infrastructure bootstrap and
`scripts\Update-PizzaOpsApi.ps1` for image-only updates of the existing private
app. Teams Agent Factory assets remain explicit preview/tenant-only templates.
