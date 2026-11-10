# Margin and Daybook

Daybook is the calendar app; Margin is mail. When both are installed they hand things to each
other with links. Neither needs the other: every button below only appears when the other app is
installed, and nothing is shared behind the scenes.

## Margin → Daybook

| Where in Margin | What it opens |
| --- | --- |
| An invitation's **Open in Daybook** (instead of Add to Calendar) | `daybook://event?uid=…&start=…&ics=…` |
| The next meeting (bar, Home, a meeting sent from here) | `daybook://event?uid=…&start=…` |
| New Meeting → **Open in Daybook** | `daybook://new?title=…&start=…&end=…&attendees=…&location=…&notes=…` |

## Daybook → Margin

| Where in Daybook | What it opens |
| --- | --- |
| An event with guests: **Email Guests** | `margin://compose?to=…&subject=…` (a `mailto:` link when Margin isn't installed) |
| An event that came from an invitation: **Show Invitation Email** | `margin://invite?uid=…` |

## Link formats

All parameters are URL query items, percent-encoded. Dates are ISO 8601 with a time zone
(`2026-11-10T09:00:00Z`). Lists are comma-separated.

**`daybook://event`**
- `uid`: the event's iCalendar UID.
- `start` (optional): when it starts, so Daybook can show that day if it doesn't know the event.
- `ics` (optional): the invitation's iCalendar text, base64url without padding, so Daybook can
  offer to add it when it doesn't have the event yet.

Daybook shows the event if it has one with that UID, otherwise opens the day of `start` and, with
`ics`, offers to add it (Going / Maybe / Not going, or just adding it).

**`daybook://new`**: `title`, `start`, `end`, `attendees` (addresses), `location`, `notes`, all
optional. Daybook opens a new event with those filled in, so the person can find a time and send
it from their calendar.

**`margin://compose`**: `to`, `cc` (addresses), `subject`, `body`. Margin opens a new message.

**`margin://invite`**: `uid`. Margin opens the email the invitation came in, if it has it; otherwise
it says it couldn't find it.

## Knowing the other app is there

- Mac: `NSWorkspace.shared.urlForApplication(toOpen: URL(string: "daybook://")!)` (or `margin://`).
- iPhone and iPad: `UIApplication.shared.canOpenURL`, with the other app's scheme listed under
  `LSApplicationQueriesSchemes` in Info.plist.
