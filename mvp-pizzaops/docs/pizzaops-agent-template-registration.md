# PizzaOps agent-template registration

This deployment uses the local Microsoft
`developer-boundary/README.md` as the governance checklist, but it does not
misapply the sample's Hosted Autopilot deployment step to the main PizzaOps
agent.

The sample creates a `kind: hosted` activity agent with `PublishAsAutopilot:
true`. PizzaOps intentionally remains a Foundry Prompt Agent using the managed
Microsoft Copilot harness. A Prompt Agent cannot be converted to an Autopilot.
The Agent Identity Blueprint therefore belongs to the thin Teams/Agentic User
bridge; that bridge delegates every reasoning turn to the deployed
`pizzaops-agent`.

## Applied registration steps

1. `a365 setup requirements` validated Azure auth, Graph Agent Identity scopes,
   and PowerShell modules. Frontier enrollment remains an operator-verifiable
   warning.
2. `a365 setup all --aiteammate --m365` created:
   - `PizzaOps Blueprint`;
   - blueprint application and service principal;
   - endpoint registration for `/api/messages`;
   - inheritable Graph, Agent 365 Tools, Messaging Bot API, and Power Platform
     permissions.
3. Admin consent completed for the default permissions.
4. The blueprint was federated with the Container App UAMI.
5. Graph delegated permissions for `Calendars.ReadWrite` and
   `OnlineMeetings.ReadWrite` were granted.
6. `scripts/Build-AgentTemplatePackage.ps1` created the tenant package:
   `.local/pizzaops-agent-template-1.0.0.zip`.

Current blueprint:

| Property | Value |
|---|---|
| Blueprint client ID | `<BLUEPRINT_CLIENT_ID>` |
| Blueprint service principal | `<BLUEPRINT_SERVICE_PRINCIPAL_ID>` |
| Callback | `https://ca-pizzaops-api-v2.livelysand-b75eab52.swedencentral.azurecontainerapps.io/api/messages` |
| Bridge UAMI client ID | `<BRIDGE_UAMI_CLIENT_ID>` |
| Bridge UAMI principal ID / FIC subject | `<BRIDGE_UAMI_PRINCIPAL_ID>` |
| Tenant | `<AZURE_TENANT_ID>` |

## Governance gates from the sample

The ZIP is the package to submit through the tenant's approved lifecycle
process. For the referenced MSIT process:

1. The blueprint owner submits the permissions/admin-consent assessment through
   SPACE.
2. The consent request includes Graph calendar scopes, Agent Identity creation,
   Agent 365 observability, and Messaging Bot API as applicable.
3. `Conditionally Approved` is accepted only after the request's permission
   grants are verified.
4. Submit `.local/pizzaops-agent-template-1.0.0.zip` through ALM. Do not invoke
   `PublishAsAutopilot` on `pizzaops-agent`.
5. Keep the developer access/review boundary described by the sample. The
   sample's four `read/write.*.developers` package values apply to a hosted
   Autopilot package; they are not silently fabricated for a Prompt Agent.
6. After ALM completion, open Teams **Store > Agent templates**, activate the
   PizzaOps template, and create an instance in the target tenant domain.

For the JJAzDev non-MSIT tenant, M365 admin upload is the equivalent supported
line-of-business path. This environment's desktop UI did not complete the file
picker flow; the package remains ready for the operator's admin/ALM upload.

## Repeatability

Run:

```powershell
$env:AZURE_TENANT_ID = '<verified-tenant-id>'
$env:PIZZAOPS_BRIDGE_CLIENT_ID = '<verified-bridge-managed-identity-client-id>'
$env:PIZZAOPS_TEAMS_APP_ID = '<existing-teams-app-id>'
.\scripts\Register-AgentTemplate.ps1
```

For an existing package, use its original Teams app ID to preserve its identity.
For a new package, choose a new GUID. These values can also be passed as
`-TenantId`, `-BridgeManagedIdentityClientId`, and `-TeamsAppId`.
The script resolves the configured managed identity client ID to its principal
ID and uses that principal ID as the federated credential subject, as required
by [Microsoft Entra](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity).
It leaves any older, mismatched credential untouched.

The generated `a365.generated.config.json` contains a protected blueprint
secret and is ignored by Git. Keep it in the operator's secure workspace. The
static `a365.config.json` contains no secret and is versioned with an empty
tenant ID. The registration script passes the selected tenant explicitly.

## Create an Agent 365 instance

After the blueprint, endpoint, consent, and tenant package activation are
ready, create the concrete Agent Identity and Agent User. The wrapper in this
repository calls
`tkubica12/agent-demos/autopilots-on-azure/scripts/provision_agent365_instance.py`.
It does not download that dependency. Review and clone the trusted
`https://github.com/tkubica12/agent-demos` checkout into `.local\agent-demos`
or provide its path with `-SourceCheckout`. Python and Azure CLI must be
installed, and the Azure CLI must be signed in to the target tenant with the
necessary Microsoft Graph permissions.

The script:

1. creates the Agent Identity under the blueprint and binds the sponsor;
2. creates the Agent User linked to that Agent Identity;
3. sets the usage location required for licensing;
4. assigns Agent 365, Copilot, Teams, Microsoft 365, and Flow licences.

To create a separate instance, choose a unique instance name, UPN in a verified
tenant domain, display name and mail nickname:

```powershell
$env:AZURE_TENANT_ID = '<verified-tenant-id>'
$env:PIZZAOPS_BLUEPRINT_ID = '<verified-blueprint-client-id>'
$env:PIZZAOPS_SPONSOR_ID = '<verified-sponsor-object-id>'
$instance = @{
  InstanceName = 'pizzaops-workshop'
  AgentUpn = 'pizzaops-workshop@jjazdev.org'
  DisplayName = 'PizzaOps Workshop'
  MailNickname = 'pizzaops-workshop'
}
.\scripts\Provision-Agent365Instance.ps1 @instance -DryRun
.\scripts\Provision-Agent365Instance.ps1 @instance -WhatIf
.\scripts\Provision-Agent365Instance.ps1 @instance
```

The last command asks for confirmation before creating or reusing identities,
setting usage location and assigning licenses. Review availability and costs of
the default licenses first; use `-LicenseSkus` and `-UsageLocation` for a
different approved set or location. Alternatively, pass `-TenantId`,
`-BlueprintId` and `-OwnerId` explicitly. `-DryRun` uses Azure CLI authentication and
read-only Graph calls, but sends no writes. For a new identity, the upstream
script stops its preview before dependent user and license calls because the
new identity ID does not exist yet. `-WhatIf` checks the target without
calling the provisioning module. The tenant, blueprint and sponsor must be
supplied by these environment variables or the corresponding parameters.

With the required identity settings supplied, omitting instance parameters
targets the existing PizzaOps instance, not a new one:

```text
Blueprint: <verified-blueprint-client-id>
Sponsor:   <verified-sponsor-object-id>
UPN:       pizzaops@jjazdev.org
Display:   PizzaOps
Location:  CZ
```

Each instance has separate ignored files
`.local\agent365\instance.<name>.json` and
`.local\agent365\instance.<name>.binding.json`. Preserve both: the first stores
object IDs for retries, while the second binds the state to the tenant,
blueprint, sponsor and UPN. A mismatch stops the wrapper rather than reusing
another identity. An older state without a binding is never trusted
automatically. Restore its original binding from a trusted backup, or first
verify the state, tenant, blueprint, sponsor and UPN against the original
records and Graph. Only after that verification, an administrator can create
the missing ignored `.local\agent365\instance.pizzaops.binding.json` file
with these verified values:

```json
{
  "tenantId": "<verified-tenant-id>",
  "blueprintId": "<verified-blueprint-client-id>",
  "ownerId": "<verified-sponsor-object-id>",
  "agentUpn": "<verified-agent-upn>"
}
```

Never overwrite an existing binding. If a call fails after creation, inspect
and preserve the partial state before retrying; do not delete it or assume an
ambiguous network failure created nothing.

Verify the instance:

```powershell
az ad user show --id <agent-upn> `
  --query '{id:id,displayName:displayName,upn:userPrincipalName,enabled:accountEnabled,usageLocation:usageLocation}' `
  --output json

az rest --method GET `
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/<agent-identity-id>?`$select=id,appId,displayName,servicePrincipalType,accountEnabled"
```

Confirm that all requested licences are assigned and the Agent User is visible
in Teams before running the greeting test.
