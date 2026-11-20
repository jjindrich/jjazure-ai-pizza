# PizzaOps Teams Agent Factory templates

These are tenant-preview package templates, not deployable generated packages.
Agent Factory schema names and tenant entitlements can change independently of
this repository.

Before packaging:

1. Confirm access to the Teams Agent Factory preview in the target tenant.
2. Replace every `REPLACE_` value and the zero UUID placeholders.
3. Rename `manifest.preview.json` to `manifest.json` while packaging.
4. Keep `agentic-user.template.json` at the package root.
5. Run `.\scripts\Build-AgentTemplatePackage.ps1`. It creates the approved
   package-owned `color.png` and `outline.png` assets and writes the ZIP under
   `.local/`.
6. The current package is already bound to blueprint
   `d935a216-c452-4e0b-93e9-96ef4141d64e`; only rebuild this package if that
   blueprint is deliberately replaced.
7. Set the blueprint callback URL to the deployed
   `https://<pizzaops-host>/api/messages` endpoint.
8. Configure the blueprint's federated identity credential with the managed
   identity's **principal ID** (`bridgeIdentityPrincipalId`) as subject, not
   its client ID. For Azure public cloud use issuer
   `https://login.microsoftonline.com/<tenant-id>/v2.0` and audience
   `api://AzureADTokenExchange`. Approve the trust change before applying it.
9. Declare the minimum Graph permissions on the blueprint; administrator
   consent remains a tenant action.
10. Limit package submission and consent to the target preview tenant.

The manifest does not provision an Entra application, Teams blueprint, Graph
permissions, or tenant consent. Those tenant-only actions remain explicit and
separate from Azure infrastructure deployment.
