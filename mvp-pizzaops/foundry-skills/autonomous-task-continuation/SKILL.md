---
name: autonomous-task-continuation
description: Persist incomplete work and resume it from an exact event or timer without retaining a continuously running agent.
---

# Autonomous task continuation

Use this skill when work cannot finish in the current turn.

1. Write the complete task snapshot: objective, Teams conversation reference,
   participants, workshop window, time zone, lunch plan, delivery assumptions,
   missing inputs, approvals, and correlation ID.
2. Choose one exact wakeup source:
   - a scheduled Service Bus message for a due time;
   - a Graph calendar notification for a meeting change.
3. Schedule with an idempotency key. A repeated event must not create duplicate
   notifications or meeting writes.
4. End the current invocation after durable persistence succeeds.
5. On wakeup, load state by task ID, evaluate only new facts, and continue the
   same Foundry conversation when one exists.
6. If the operation needs a human decision, create an approval or ask in the
   original Teams conversation and schedule another bounded check if necessary.
7. Never claim that a timer, notification, calendar change, or tool call succeeded
   until the tool returns a durable identifier.

## Platform boundary

The Copilot harness provides reasoning and tool orchestration. Service Bus,
Cosmos DB, Graph notifications, and the Teams bridge provide durable activation
and delivery; they do not replace the Foundry agent loop.
