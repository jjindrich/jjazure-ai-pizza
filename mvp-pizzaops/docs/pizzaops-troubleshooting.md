# Troubleshooting PizzaOps

## First correlation step

Start with `traceId`, `taskId`, and `eventId`. Use the same IDs in PizzaOps.Api
logs, Foundry tool spans, Service Bus messages, and Teams/Graph callbacks. Do not
copy prompt, message, or calendar bodies into a support issue.

## Teams agent does not respond

1. Confirm the Agentic User factory was activated and the app is installed for
   the user or team.
2. Check the blueprint callback URL and `api/messages` reachability.
3. Look for inbound SDK authentication failures. Validate blueprint client ID,
   tenant ID, and managed-identity federated credential.
4. Verify the Foundry project endpoint and agent name in PizzaOps.Api.
5. Run the agent smoke invocation from `foundry/pizzaops`.

For the current deployment, the Teams callback must point to `ca-pizzaops-api-v2`
in the VNet-integrated environment. If Cosmos returns `403` with public access
disabled, check private endpoint approval and DNS from that environment; do
not enable public access as a workaround.

Outbound Teams `AADSTS700213` indicates a federation mismatch. Compare the
assertion subject with the UAMI **principal ID**, not its client ID; check the
issuer and audience as well. A trust change requires separate approval.

The managed-harness agent creates conversations at its own agent endpoint.
An obsolete conversation ID is replaced on a 404 without replacing the Teams
task. Responses use structured input and `POST` to the same agent's
`/responses` endpoint; a `GET /responses/<prompt>` indicates a regression.

## Foundry tool calls return 401/403

- Confirm the OpenAPI audience is the same in `azure.yaml`, Easy Auth/Token
  validation, and the Container App environment.
- Confirm the Foundry project identity can request a token for that audience and
  call the API.
- Do not replace managed identity authentication with an anonymous endpoint for
  production.

## Calendar read or write fails

- Confirm the stored task is associated with an Agentic User identity.
- Confirm the blueprint has the minimum calendar permissions and administrator
  consent.
- For writes, verify a current approval ID and the canonical input hash. An
  approval for old input cannot authorize changed attendees or times.
- Check tenant application-access policy if the agent must operate on mailboxes
  beyond its own.

## No proactive message at wakeup

- Find the Service Bus message and event ledger record.
- Check that event claiming succeeded; a `processed` duplicate is expected
  behavior, not a retry.
- Verify the task has Teams `conversationId`, `serviceUrl`, and Agentic User
  identity saved from an inbound activity.
- Confirm the Teams app is still installed. A blocked or uninstalled app can
  return `403 MessageWritesBlocked`.
- Re-run the proactive send with the same idempotency key only after confirming
  the earlier attempt did not deliver.

## Calendar change did not wake the agent

- Confirm the Graph subscription exists, is not expired, and has lifecycle
  notification handling.
- Validate the notification URL is public HTTPS and returns the exact
  `validationToken` response.
- Check `clientState` and do not log the secret value.
- Verify the event resource maps to an active PizzaOps task. Unknown events are
  quarantined and never used as agent instructions.

Outlook subscriptions currently expire in fewer than seven days. Renewal is a
service-maintenance operation and must not be confused with calendar polling.

## Duplicate Teams messages or meeting writes

Service Bus, Teams, and Graph delivery is at least once. A duplicate event should
have the same idempotency key and stop at the event ledger. Investigate a missing
or unstable key rather than making retries less frequent.

## `412` version conflict

This is expected optimistic concurrency. Reload the task, recompute the desired
patch from the current state, and submit a new version. Do not force-overwrite
the newer version.

## Foundry invocation is slow or incomplete

Use Foundry trace search for the agent response and tool spans. Check model
capacity, API latency, Service Bus delay, and tool timeout independently. A
successful prompt response alone does not prove that a tool call, approval, or
calendar write completed; require its returned ID.

## Direct Foundry Teams publication limitations

If you chose direct publishing instead of the Agentic User factory, a managed
Teams bot-style surface may work reactively. Do not expect that path to provide
an Agentic User, conversation-reference capture, or a documented proactive
message API. Those requirements use the PizzaOps bridge.
