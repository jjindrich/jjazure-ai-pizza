# PizzaOps platform constraints and preview limitations

This document records decisions checked against Microsoft documentation on
2026-11-18.

## Supported now

- Foundry Prompt Agents can use the managed
  `microsoft_copilot_preview` Copilot harness. This is preview and must be
  selected at agent creation; it cannot be added to an existing ordinary agent.
- Foundry Skills are separately versioned and attached by immutable version.
- Foundry can publish an agent to Microsoft 365 and Teams, but this produces a
  bot-style channel identity rather than an autopilot or Agentic User.
- Teams SDK 2.2.1 supports Agentic User activities and proactive send with a
  stored conversation reference.
- Routines support schedule, one-shot timer, GitHub issue, and Teams custom
  triggers. Routines do not expose a Graph/calendar trigger.

## Unsupported direct combination

A Foundry Prompt Agent cannot currently be published as an Agent 365 autopilot.
Autopilot publishing and its Entra agent user are supported for Foundry Hosted
Agents, not Prompt Agents. The request intentionally forbids converting the main
runtime into a Hosted Agent. PizzaOps therefore uses an Agentic User factory
bridge for channel identity and proactive delivery while retaining the
Managed Harness Prompt Agent for reasoning.

The direct Foundry Teams publish route remains available for reactive pilots,
but is not the production identity path in this repository because public
documentation does not provide conversation-reference capture or proactive send
for that route.

## Work IQ decision

Work IQ is the preferred Microsoft 365 MCP capability for interactive
user-delegated organizational data, but its current Microsoft 365 connection is
delegated-only. Application-only authentication is unsupported, and delegated
identity passthrough is unavailable when the agent is published to Teams.

The autonomous Agentic User calendar operations in PizzaOps therefore use
Microsoft Graph through the Teams SDK's Agentic User token. The blueprint
requests only the graph permissions actually granted by tenant administration.
An operator may add Work IQ as an additional direct tool in a user-interactive,
non-Teams Foundry experience after the required licenses, admin consent, and
connection are configured.

## Graph and routines

There is no documented Graph-to-Foundry routine bridge. PizzaOps uses a public
Graph webhook endpoint, a validated `clientState`, durable event ledger, and a
Service Bus message. A scheduled wakeup is also a Service Bus scheduled message
rather than a polling Routine. A static Routine is not added merely to satisfy a
deployment checklist because a recurring agent invocation would violate the
no-polling requirement.

## Preview and tenant prerequisites

- The Copilot harness, Skills, Routines, Agentic User template schema, and the
  Teams agent-factory setup contain Preview capabilities.
- A Foundry region must support both the Copilot harness and any optional
  Routines use. Review regional availability before deployment.
- The tenant must support Agentic Users and the agent identity blueprint.
- Global/AI administrators activate the factory and grant blueprint scopes.
- Agent 365 registry sync and activity data require eligible licensing and
  administrator acceptance of terms.
- Teams organization scope may require Microsoft 365 admin approval.
- The Graph app/blueprint requires administrator consent for calendar
  permissions. Tenant policy may additionally restrict application access to
  specific mailboxes.

## Official references

- [Managed Copilot harness](https://learn.microsoft.com/azure/foundry/agents/how-to/use-tools-skills-copilot-harness)
- [Foundry Agent 365 integration](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-365-integration)
- [Publish to Microsoft 365 and Teams](https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot)
- [Set up an agent factory for Teams](https://learn.microsoft.com/microsoftteams/platform/concepts/agentic-identity/agent-factory/setup)
- [Teams proactive messaging](https://learn.microsoft.com/microsoft-365/agents-sdk/proactive-overview)
- [Foundry Routines](https://learn.microsoft.com/azure/foundry/agents/concepts/routines)
- [Work IQ Foundry tool](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/work-iq)
- [Microsoft Graph Outlook change notifications](https://learn.microsoft.com/graph/outlook-change-notifications-overview)
- [Graph subscription resource](https://learn.microsoft.com/graph/api/resources/subscription)
