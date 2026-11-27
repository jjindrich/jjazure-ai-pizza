# PizzaOps Teams Agent Factory templates

These are tenant-preview package templates, not deployable generated packages.
Agent Factory schema names and tenant entitlements can change independently of
this repository.

Before packaging:

1. Confirm access to the Teams Agent Factory preview in the target tenant.
2. Obtain the verified blueprint client ID and Teams app ID. Reuse the
   original Teams app ID for an existing package; choose a new GUID only for
   a new package.
3. From `mvp-pizzaops`, run
   `.\scripts\Build-AgentTemplatePackage.ps1 -BlueprintId <blueprint-id> -TeamsAppId <teams-app-id>`.
   It substitutes the zero UUID placeholders in the generated files, creates
   the package icons, and writes the ZIP under `.local/`. The same values can
   be supplied through `PIZZAOPS_BLUEPRINT_ID` and `PIZZAOPS_TEAMS_APP_ID`.
4. Verify the generated manifest and blueprint binding before submitting.
5. Set the blueprint callback URL to the deployed
   `https://<pizzaops-host>/api/messages` endpoint.
6. Configure the blueprint's federated identity credential with the managed
   identity's **principal ID** (`bridgeIdentityPrincipalId`) as subject, not
   its client ID. For Azure public cloud use issuer
   `https://login.microsoftonline.com/<tenant-id>/v2.0` and audience
   `api://AzureADTokenExchange`. Approve the trust change before applying it.
7. Declare the minimum Graph permissions on the blueprint; administrator
   consent remains a tenant action.
8. Limit package submission and consent to the target preview tenant.

The manifest does not provision an Entra application, Teams blueprint, Graph
permissions, or tenant consent. Those tenant-only actions remain explicit and
separate from Azure infrastructure deployment.
