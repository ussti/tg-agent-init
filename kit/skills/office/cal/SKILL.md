---
name: cal
description: >
  Cal.com bookings and availability through the bundled `cal` tool: list event types,
  upcoming bookings, free slots, create / cancel / reschedule bookings.
  Use when the user asks about their Cal.com schedule or booking links.
  Booking and cancelling notify other people — confirm first. Needs CAL_API_KEY.
---

# cal — Cal.com

Tool path: `"$AGENT_WS/skills/cal/cal"`. It reads `CAL_API_KEY` from the environment;
if it is missing the tool says so (add it: `agent-keys add cal`).

```bash
CAL="$AGENT_WS/skills/cal/cal"
"$CAL" me                                   # account profile
"$CAL" calendars                            # connected calendars
"$CAL" events                               # event types and their limits
"$CAL" event-create --title T --slug s --minutes 30
"$CAL" event-update --id 123 --buffer-after 15 --minimum-notice 720
"$CAL" schedule                             # availability schedules
"$CAL" schedule-set --days mon,tue,wed,thu,fri --start 10:00 --end 18:00
"$CAL" slots --event-id 123 --from 2026-09-22 --to 2026-09-26
"$CAL" bookings --status upcoming           # upcoming | past | cancelled | recurring
"$CAL" cancel --uid abc123 --reason "..."
"$CAL" reschedule --uid abc123 --start 2026-09-24T10:00:00Z
```

## Confirm first

Creating event types, cancelling and rescheduling bookings notify other people or
change what they can book. Show the user what will change and wait for a yes.
