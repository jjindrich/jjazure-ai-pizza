---
name: human-approval-and-policy
description: Enforce PizzaOps autonomous, approval-required, and denied operation classes at every tool boundary.
---

# Human approval and policy

Use this skill whenever an action can change external state or incur impact.

## Autonomous

The agent may read calendar availability, calculate timing, read/update PizzaOps
task state, request a notification, and create a scheduled continuation.

## Approval required

Require a concrete approval record before:

- creating or materially changing a meeting;
- changing an event that affects attendees;
- inviting or removing people;
- preparing an order that moves toward a purchase or external commitment.

An approval is bound to a task, operation, canonical input, actor, expiration
time, and idempotency key. Do not reuse an approval for different input.

## Denied

Do not:

- pay for or charge an order;
- submit a financial transaction;
- add or change payment credentials;
- bypass calendar permissions;
- represent a plan as an actual purchase.

## Procedure

1. Call the policy tool with the requested operation.
2. If `autonomous`, proceed and record the decision.
3. If `approval_required`, summarize impact and create an approval request. Stop
   after the request is stored.
4. If `denied`, explain the limit and offer a non-financial next step.
5. Never implement business authorization solely in these instructions. The
   server-side policy tool remains authoritative.
