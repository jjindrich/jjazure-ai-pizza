# PizzaOps demonstration

This scenario uses only synthetic workshop data and the deployed Agentic User
test tenant. The lunch and delivery values are exact enough to make failures
observable.

## Preconditions

- A PizzaOps Agentic User is activated and installed in the test Teams scope.
- PizzaOps.Api has a Foundry project endpoint and deployed agent name.
- The Agentic User's calendar and delegated recipients are test data.
- The Graph webhook subscription for the relevant calendar exists.
- The Foundry project identity can call the PizzaOps OpenAPI tool.
- A Teams user has interacted with PizzaOps once so the service has a durable
  conversation reference.

## Expected scenario

### 1. Start the workshop plan

Send:

> @PizzaOps Máme zítra workshop 10:00–16:00 pro 12 lidí. Zorganizuj
> meetingy a pizzu.

Expected durable outcome:

- one PizzaOps task with the synthetic tenant/user context;
- workshop start `10:00` and end `16:00` in the selected IANA time zone;
- headcount `12`;
- a calendar read/availability trace;
- no financial operation.

### 2. Calculate delivery timing

Given:

- lunch start: `12:30`;
- serving buffer: `5` minutes;
- expected delivery: `40` minutes;
- preparation buffer: `0` minutes.

Expected calculation:

| Value | Time |
|---|---|
| Lunch | 12:30 |
| Target pizza arrival | 12:25 |
| Expected delivery | 40 minutes |
| Order deadline | 11:45 |

The unit test must reject a zero/negative delivery duration and preserve the
time zone.

### 3. Require missing headcount

Start a variant with no headcount. Schedule a continuation at `11:15`. With no
new user message, the expected Teams text is equivalent to:

> Potřebuji potvrdit headcount, abych mohl dokončit plán pizzy.

Evidence required:

- one scheduled Service Bus message;
- one consumed wakeup event;
- one Foundry invocation using the stored conversation;
- one proactive Teams activity;
- no second message if the source event is replayed.

### 4. Move the lunch meeting

Move the lunch event from `12:30` to `13:00` after approval. The Graph
notification must create one `calendar-changed` event. PizzaOps should:

- update target arrival to `12:55`;
- update order deadline to `12:15`;
- update durable state with a new version;
- send one proactive change message.

A replay of the same Graph change notification must not send another message.

### 5. Approval and denied purchase

Ask PizzaOps to create or materially move a meeting. The first call must produce
an approval request, not a calendar write. A decision is accepted only if it is
bound to the same task and canonical input hash.

Ask PizzaOps to pay for or check out the pizza. The policy tool must return
`denied`, and the service must not expose a payment adapter.

## Evidence checklist

Capture these identifiers only; redact message and calendar bodies:

- task ID and event ID;
- approval ID and decision;
- calendar event ID;
- Foundry conversation/response and tool trace IDs;
- Service Bus sequence/message ID;
- Teams outbound activity ID;
- Graph subscription/resource ID;
- Application Insights operation ID.
