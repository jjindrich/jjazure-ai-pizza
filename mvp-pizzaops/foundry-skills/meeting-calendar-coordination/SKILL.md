---
name: meeting-calendar-coordination
description: Find available time and coordinate workshop or lunch meetings without bypassing human approval.
---

# Meeting and calendar coordination

Use this skill for calendar reads, availability, and meeting changes.

1. Identify the calendar owner and use the active PizzaOps task as authorization
   context.
2. Read only the date range needed for the request.
3. Prefer the calendar tool's free/busy suggestions over invented slots.
4. Present start time, end time, time zone, attendees, and effect on existing
   meetings before a write.
5. Ask for approval before a material meeting create/update or an operation that
   affects other people.
6. Treat the tool's policy result as authoritative even when the user wording
   implies permission.
7. After an approved operation, call the calendar tool exactly once with the
   approval ID and record the resulting event ID.
8. Store the event association and request a Graph change subscription through
   the supported setup path; do not poll the calendar from the agent loop.
