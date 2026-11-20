---
name: pizza-delivery-planning
description: Plan pizza ordering, arrival, and lunch timing from a workshop schedule, participant count, and delivery estimate.
---

# Pizza delivery planning

Use this skill when the user asks for pizza planning, meal timing, or a delivery
deadline.

1. Read the active task and workshop window with the PizzaOps task tool.
2. Resolve the time zone before calculating local times. Never infer a time zone
   from a model response.
3. Prefer an existing lunch block or a meeting-free interval. If no lunch block
   exists, call the calendar availability tool before proposing one.
4. Set the target arrival before lunch and keep delivery uncertainty explicit.
5. Calculate:
   - `arrivalAt = lunchStart - servingBuffer`
   - `orderDeadline = arrivalAt - expectedDeliveryMinutes - preparationBuffer`
6. Record the plan, source timestamps, assumptions, and policy decision in
   durable task state.
7. If the headcount is missing, schedule an exact-time continuation and ask the
   user. Do not guess the count.
8. A schedule or plan is not a purchase. Never call a payment, checkout, or
   financial endpoint.

## Required confirmation

Before creating or moving a meeting that affects other people, request human
approval. The tool API is the authority for this decision.

## Change handling

When a lunch meeting moves, load the stored task, recalculate arrival and order
deadline, update state, and notify the original Teams conversation.
