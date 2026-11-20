# PizzaOps configuration

Production requires configuration-only values; credentials and tokens are never
stored in source or sent through this service.

| Key | Purpose |
|---|---|
| `PizzaOps:FoundryEndpoint` | Foundry project endpoint. |
| `PizzaOps:FoundryAgentName` | Managed Prompt Agent name. |
| `PizzaOps:CosmosEndpoint` | Cosmos account endpoint. |
| `PizzaOps:CosmosDatabase` | Durable-state database. |
| `PizzaOps:CosmosTasksContainer` | Task/approval container partitioned by `/tenantId` (default `tasks`). |
| `PizzaOps:CosmosEventsContainer` | Idempotency/trigger container partitioned by `/tenantId` (default `events`). |
| `PizzaOps:ServiceBusNamespace` | Fully qualified Service Bus namespace. |
| `PizzaOps:ServiceBusQueue` | Wakeup queue. |
| `PizzaOps:GraphWebhookClientState` | Constant shared secret used for Graph change validation. |
| `Api:Audience` | Exact required JWT `aud`. Container configuration supplies `Api__Audience`. |
| `Api:AllowedClientId` | Exact allowed Foundry project `azp`/`appid`. Container configuration supplies `Api__AllowedClientId`. |
| `PizzaOps:AllowedIssuers` | Semicolon-separated exact JWT `iss` values accepted by the tool API. |
| `PizzaOps:AllowedTenantId` | Exact JWT `tid` accepted by the tool API. |
| `PizzaOps:RequiredToolRole` | Optional additional allowed `roles` claim. The exact client ID remains required production configuration. |
| `AzureAd:TenantId` / `AzureAd:ClientId` | Teams Agent identity blueprint tenant and client ID. |
| `ToolApi` | Reserved internal Microsoft Identity Web section populated from `Api:Audience` and `PizzaOps:AllowedTenantId`. |
| `PizzaOps:AllowLocalAuthBypass` | Development-only explicit bypass. It defaults to `false` and is ignored in other environments. |
| `PizzaOps:AllowLocalFallbacks` | Development-only in-memory/local dependency fallback. |

The Teams SDK also requires its normal tenant App ID/application configuration.
Its Agentic User authentication is not proven by compile/tests and must be
validated after tenant consent and Agentic User setup.
