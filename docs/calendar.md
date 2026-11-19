# Calendar from invitations

Margin keeps a small calendar of the events in invitations it has seen. It stays on the device
(`calendar.json`).

- **Finding them:** an invitation is remembered whenever its message is opened. Every few minutes,
  mail in the inbox that looks like an invitation is read too (from the offline cache when it can
  be), so events are known before they're opened.
- **Next meeting:** above the mail list on Mac, iPhone and iPad, the next meeting in the coming
  hours, with **Join** when it has a meeting link and starts within ten minutes.
- **Reminders:** a notification before each event, 5–30 minutes ahead (Settings → Notifications → Meeting reminders, on the Mac and
  on iPhone), or off. Cancelled and declined events are left out.
- **Answering:** Accept, Maybe and Decline send the organizer a proper reply (iTIP `METHOD:REPLY`
  with your `PARTSTAT`). Add to Calendar hands the event to the Calendar app.
  - **Feedback:** the tapped button fills with a tick at once (every button keeps room for the
    tick, so nothing moves) and the others dim while the reply goes out. A line above the buttons
    (always one line tall) says where the answer stands: "Sending your answer to Sam…", then
    "You're going · Sam has been told" (or might go / not going); "You're going" when the answer
    is known from elsewhere; "Changed since you answered · answer again" when
    an updated invitation (higher `SEQUENCE`) came in after your answer. The notice at the bottom
    says the same, with the sent tick. If sending fails, the error shows and the buttons go back,
    ready to try again.
  - **The reply:** `METHOD:REPLY`, the invitation's `UID` and `SEQUENCE`, a fresh `DTSTAMP` (the
    reply's own creation time, per RFC 5546), one `ATTENDEE` with your `PARTSTAT`, sent to the
    `ORGANIZER` as `text/calendar; method=REPLY` beside a plain-text line. It comes from, and
    names, the address that was invited — an alias when the invitation went there — so the
    organizer's calendar matches it to your guest entry. Your entry in the meeting's guest list
    updates once it's sent.
  - **Sent once:** one answer per invitation can be on its way at a time (`MailModel.answering`,
    keyed by the invitation's UID, shared by the reader card, the Calendar page and the assistant's
    `respond_to_invite`). Taps while it sends do nothing. The same answer to the same version
    (`SEQUENCE`) isn't sent again, even after a restart: sent answers are kept in
    `sent-answers.json` and fill in the buttons on launch. A different answer, or the same one to
    an updated invitation, sends a new reply.
- **Home** lists today's meetings under "Don't forget".

## The Calendar view

Margin's calendar: what's coming up, laid out as a list or a calendar, where events can be made,
moved, changed and deleted. The same on Mac, iPad and iPhone.

- **Opening it:** the calendar button in the account column on Mac (under Snoozed), **Calendar** in
  the sidebar, or **Calendar** in the mailbox list on iPhone and iPad. On Mac the mailbox sidebar
  steps aside while it's open.
- **Views:** **Agenda**, **Day**, **Week** and **Month**, picked at the top right in a glass capsule (the picked one in dark glass, sliding over, like the inbox's filter chips) and remembered
  (`calendarMode`). Week needs room for seven columns, so a narrow window or a phone offers Agenda,
  Day and Month, and shows Day when Week was picked. Day, Week and Month have previous, **Today** and next in one glass capsule, and the day, week or month shown. **Refresh** looks through the mail again and rereads
  every calendar.
- **Sidebar:** with room (820 points or more), the month to pick a day and the list of calendars
  sit on the left, whatever the view. Narrower, Agenda stacks them above the list of meetings and
  the other views put the list behind a button.
- **The list of calendars:** each mailbox, the Calendar app's calendars (once shown) and Reminders
  (once shown), each with a box in its colour, ticked while it's shown. Unticking hides that
  calendar's meetings everywhere in Margin (the next-meeting bar, Home, Ask too), and it's
  remembered (`calendar.hidden`). A mailbox's colour is its own; a Calendar app calendar's colour
  is brought to the nearest of Margin's (`Palette.nearestAccountIndex`).
- **Month (sidebar and Agenda):** pick a day; days with something on have a dot, today is in the
  accent colour, the chosen day sits on a soft circle. Neighbouring months' days are faded.
  **Today** comes back.
- **Agenda:** from the chosen day, two weeks by day (Today in the accent colour, Tomorrow, then
  the date). Each meeting: a line in its calendar's colour, the time (or All day) with Repeats
  under it, the title, and where (a room, or the call's service from its link), which Calendar
  app calendar it's in, and who invited you. Reminders due that day come first, overdue ones on
  today. Meetings that have ended are left out; declined ones are dimmed; cancelled ones aren't
  shown.
- **Day and Week:** a column per day with the hours down the side, scrolled to just before now
  (or to 8:00 on other days). All-day events and reminders sit in a strip above, as tall as the
  busiest day so the hours don't move. Meetings are tinted in their calendar's colour; ones still
  waiting for your answer are outlined, declined ones faded; overlapping ones sit side by side
  (`PlacedMeeting.layout`). Today has a line for now. In a week, clicking a day's heading opens
  that day. Clicking a meeting shows it: when and where, who invited you and how many are going,
  Going?, Join, Edit… for events you can change, and Show Invitation. With it open, Backspace
  (or Delete) deletes it.
- **Scrolling and zoom (Mac):** two fingers sideways move the days with the fingers and, on
  letting go, lock onto the nearer whole day (`CalendarScroll.settle`); momentum carries on first.
  Each swipe locks to one direction, so the hours never drift while the days move. In Week the
  week then starts on whatever day it settled on (‹ › and Today put it back on the region's week).
  Shift and a mouse wheel move a day per notch. In Day with colleagues, one swipe is one day, as
  their columns can't slide. Pinch, or ⌘+ and ⌘− (⌘0 back) while Day or Week shows, makes hours
  taller or shorter around the fingers or the middle (`calendar.hourHeight`, from the height
  that just fits the day up to 120 points). `DayScroller` and the sliding come from Daybook.
- **Month:** a box per day (five or six weeks, as the month needs) with what's on: all-day
  events as a tinted bar, the rest as a dot, the time and the title, then reminders, and "3 more"
  when it doesn't fit. Clicking a day opens it in Day.
- **Going?** Yes, Maybe and No under each meeting you were invited to, yours filled in the
  accent colour. Events from an account's calendar are answered through it (Microsoft 365
  `accept`/`tentativelyAccept`/`decline`, Google by updating your attendee entry); the organizer
  is told. Invitations only known from mail are answered with an iTIP reply, as in the message,
  through the same once-per-answer path. The picker shows your answer at once and waits while it
  is sent. Tapping your current answer again is allowed (an updated invitation may need it); the
  model sends nothing when that answer already went out for this version.
  Meetings you organized have no answer, and neither do the Calendar app's own events (EventKit
  can't send answers): answer those in the Calendar app, or as the invitation in the mail.
- **Up next:** from today, the next meeting leads as a card: a live countdown ("In 25 min",
  "Now · 20 min left"), the title, time, place and organizer, up to five guests' faces and how many
  are invited, Going?, and Join filled in the accent colour.
- **Between meetings:** today has a line for now with the time; gaps of half an hour or more say
  how long you're free ("1 h 30 free"); a meeting that starts before the previous one ends says
  "Overlaps with …".
- **Clicking a meeting** in the agenda opens the email its invitation came in, wherever it is now;
  an event with no invitation opens in the editor when it can be changed.
- **Join** on events with a meeting link: filled in the accent colour when it starts within 15
  minutes or is on now, a soft tint before that.
- **Right-click:** Edit… and Delete (events you can change), Show Invitation (opens the email,
  wherever it is now), and Copy Meeting Link. On a reminder: Open in Reminders.

**Making and changing events** (`MailModel+EventEditing.swift`, `Views/CalendarEditing.swift`,
`MailCore/Calendar/CalendarWriting.swift`):

- **New Event:** the + in the top bar (the next half hour today, nine o'clock on another day);
  in Day and Week, drag down empty time to make an event that long, or double-click for an hour
  from there (on iPhone and iPad, touch and hold first, so a swipe still scrolls); in Month,
  right-click a day. Everything snaps to the quarter hour.
- **The event window:** a big title, then one row per part with its symbol on the left (after
  Daybook's): **calendar** (a menu grouped into Mailboxes and On this Mac, each in its colour; the
  one used last is picked next time, `calendar.newEventsIn`), **when** (start "to" end, moving the
  start keeps the length; All day and the length beside it), **people**, **suggest a time**,
  **video call**, **place** and **notes**. Delete Event, Cancel and Add Event / Send Invitations /
  Save (⌘↩) sit in a bar at the bottom; esc closes.
- **People:** chips (face, name, ✕; Backspace in the empty field takes the last off), and a field
  whose suggestions float over the form rather than stretching it. Only people worth inviting are
  offered: people you've written to (`AddressBook.writtenTo`), who shared a calendar with you, or
  in your organization's directory, so automated senders and one-off senders stay out
  (`MailModel.inviteeSuggestions`). Those whose busy times can be seen come first, with a calendar
  mark (a green dot on their chip). This device's Calendar app can't send invitations, so adding
  someone moves a new event to the first mailbox's calendar and says so.
- **The day beside it (Mac):** the event window's right side shows the event's day (‹ › move it a
  day): your other meetings in their colours, a bar per person invited where they're busy, and
  the event itself in its calendar's colour, which can be dragged to another time (quarter hours,
  keeping its length). Above it one line: **You're free then** / **Everyone's free then**,
  **Clashes with …**, or **… is busy then** (`DayPeek`). The idea of a day beside the form comes
  from desktop mail apps; the look is Margin's.
- **Suggest a time:** folded away until opened. Open, it shows the suggested times (below) and
  "All your calendars", which opens **Count me busy in**: a tick per calendar of yours (each
  mailbox's calendars and the Calendar app's) to count or leave out; the choice is kept
  (`calendar.suggest.skip`, `MailModel.busyCalendarChoices`).
- **Video calls:** a connected mailbox's calendar shows **Video call** with its service under it
  (Microsoft Teams, or Skype where that's what the account offers, from the calendar's own
  `defaultOnlineMeetingProvider`; Google Meet for Google). Turned on, the calendar makes the
  call and puts its join link on the event, and guests get it with the invitation: Graph
  `isOnlineMeeting` + `onlineMeetingProvider`, Google `conferenceData.createRequest` with
  `conferenceDataVersion=1`. An event without a call can get one later the same way
  (`EventChanges.addVideoCall`); one that has a call shows **Join** instead. New events with
  people (Meet in Everyone's free) start with it on. This device's Calendar app can't make
  calls: there the row offers **Add a video call**, which moves a new event to a mailbox's
  calendar; a link can still go in the place. The service is asked once per
  mailbox (`MailModel.videoCallService(for:)`).
- **Where events can go:** this device's calendars that can be written to (not birthdays,
  holidays or subscriptions), once the Calendar app is shown, and each mailbox whose calendar is
  connected. With neither, + is dimmed and says what to do.
- **Changing:** drag a meeting to another time (and in Week, another day); drag its bottom edge
  to make it longer or shorter; the time shows while dragging. Or **Edit…** (in its details,
  or right-click) opens the editor, which also has **Delete Event**. Only what changed is sent
  (`MailModel.changes(from:to:)`), so what Margin can't see of an event (an Outlook event's
  formatted notes, say) stays as it was; notes only show in the editor when the calendar gives
  them in full (the Calendar app and Google, not Microsoft 365).
- **What can be changed:** events you made, in a calendar that can be written to
  (`CalendarEvent.canChange`). Other people's meetings are answered with Going?, not moved;
  invitations only known from the mail can only be answered.
- **Repeating events** ask "Only This Event" or "All Events". All Events moves the whole
  series by as much as this one moved (`EventChanges.forSeries`): Microsoft 365 through the
  series master (`seriesMasterId`), Google through `recurringEventId`, the Calendar app from
  the first occurrence with `.futureEvents`.
- **Guests are told** by the calendar itself: Microsoft 365 always, Google with
  `sendUpdates=all`. The Calendar app syncs the change to its own account.
- **At once, with Undo:** the page changes before the calendar answers; if the calendar refuses,
  it goes back and says why. The notice at the bottom has **Undo** (`UndoKind.calendar`):
  moving or editing goes back, a new event is deleted, a deleted event is made again in the
  same calendar (not a deleted series, which can't come back as it was).

**Comparing with colleagues** (`MailModel+Colleagues.swift`): **Compare with** in the sidebar
has a + that opens a field (folded away otherwise). Its suggestions are only people whose busy
times can be seen: calendars shared with you (Graph `/me/calendars` owners, Google
`calendarList`, `CalendarSharing`) first, then people you know at your own organization's
domain; nobody at a public mail service (`MailModel.colleagueSuggestions`, `workDomains`).
Each colleague gets a colour of their own (not one a mailbox or another colleague has) and a
face with a ring in it; the list is kept (`calendar.compare`); hovering shows ✕ to take someone
off (right-click too; always shown on iPhone and iPad).

- **Day:** a column for You and one per colleague. Each heading has their face and, today, where
  they are now ("Busy until 15:00", "Free until 13:00", "Free for the rest of the day"). Their busy
  times are striped in their colour with the time; only busy times are shared, never what.
  Where you and everyone are free for half an hour or more between 8:00 and 18:00 (from now on,
  today), a dashed band across the columns says "Everyone's free · 1 h" with **Meet**, which opens
  New Event there with them as People, in a connected mailbox's calendar so they get the
  invitation (`MailModel.freeTogether(on:)`, built on `FreeTime.slots`).
- **Week:** a thin bar per colleague down the right of each day where they're busy, with the
  time on hover; meetings leave room for the bars.
- **Where it comes from:** each colleague is asked from the connected Microsoft 365 or Google
  calendar in their own domain (else the first connected one), through the same free/busy call
  New Meeting uses (`getSchedule`, `freeBusy`), for the month shown and a week either side, again
  with Refresh. Without a connected calendar the section says to connect one.
- **Out of office:** Microsoft 365 says what kind of busy each stretch is, and Margin keeps it
  (`BusyTime.kind`: busy, tentative, out of office, working elsewhere). Out of office shows with
  a plane: "Out of office until Friday" under their name (joined across a night or a weekend; a
  midnight end reads as the day before), "Out of office" in the sidebar (the date on hover), a
  day-long absence as a chip in the all-day strip, and a lighter bar in Week. Tentative reads
  "Maybe busy" with fainter stripes; working elsewhere has no stripes and still counts as free
  for Everyone's free. Google's free/busy only says busy, so Google colleagues show plain busy.
- **Not shared:** people outside the organization, or whose calendars aren't shared, come back
  with an error from Microsoft or Google. They're left out of the answer, not taken for free:
  their column says "Their calendar isn't shared with you", the sidebar says "Not shared with
  you", and they don't count for Everyone's free (`colleaguesHidden`).

**Suggested times** (`MailModel+SuggestedTimes.swift`, `MailCore/Calendar/MeetingTimes.swift`,
`Views/SuggestedTimesRow.swift`): when an event has people in it, the editor shows "Suggested
times" under the dates: up to five glass chips, like the inbox's filter chips ("Tomorrow, 10:00",
"Fri 14:30"), soonest first. Picking one moves the event there and keeps its length; the picked
chip is filled. Hovering (or VoiceOver) says who's busy and whose calendar can't be seen. While it
looks, the row keeps its height with "Looking for times…", so the form doesn't jump. Under it,
anyone busy at the time chosen, however it was chosen: "Sam is busy then". New Meeting has the
same row under the length (its People section already says who's busy).

- **Everyone free:** a time is suggested only when you're free in every calendar the Calendar
  shows that's ticked under Count me busy in (all of them unless changed; never events you
  declined or all-day ones) and
  everyone whose calendar can be seen is free. Working hours 09:00 to 17:00, weekdays, the next
  two weeks, from the next quarter hour. Working elsewhere counts as free.
- **Spread out:** at most two a day: the start of each gap and, for a long one, the first whole
  hour past its middle, so the choice isn't 09:00, 09:15, 09:30.
- **Microsoft 365** suggests times itself (`POST /me/findMeetingTimes`, everyone required and
  free, in the organizer's working hours). These come first, unless they clash with your own
  events it can't see (the Calendar app's, another mailbox's); the rest is filled from Margin's
  own. The call needs a work or school account and Calendars.Read.Shared, which connecting the
  calendar asks for. Calendars connected before it was added keep working (a refresh that's
  turned down tries again without it, `OAuthClient.laterScopes`) and get it by connecting again.
  When the account turns the call down, it isn't asked again until Margin restarts, and Margin
  works the times out alone.
- **Google, and everywhere else:** worked out on the Mac or iPhone from your calendars and
  everyone's free/busy (`busyTimes`, asked from the connected mailbox in their domain, as for
  Comparing with colleagues), with `FreeTime.slots`. Without a connected calendar, or for
  people outside the organization, their time can't be seen: the suggestions are your own free
  times and the chip says whose calendar couldn't be seen. Never taken for free.

**The Calendar app and Reminders:** both are off until **Show** is pressed in the list of
calendars. The first time, the system asks (`NSCalendarsFullAccessUsageDescription`,
`NSRemindersFullAccessUsageDescription`); if it was refused before, System Settings opens at
Privacy instead. Shown, Margin reads (EventKit, `MailCore/Calendar/DeviceCalendar.swift`) every
calendar the Calendar app shows (iCloud, Exchange, Google, subscriptions, birthdays) for the month
shown, a week either side, and reads again whenever the Calendar app or Reminders change
something (`EKEventStoreChanged`). Reminders brings in to-dos that aren't done and have a due date
in that range, and overdue ones from the last month. A reminder's circle ticks it done in
Reminders too; it stays, struck through, until the next read, so a slip can be undone. Events
are written only when you make, move, change or delete one (above). A Calendar app event that's also known from an account or an invitation
shows once (same UID, or same title and start). Margin doesn't remind you of Calendar app events
(the Calendar app already does). **Stop Showing** (the … next to the heading) turns them off.
Event ids from the device start with `device:`.

**From your mail:** invitations and answers are known by their calendar data, never by subject
words. The mail list already reads each message's structure (IMAP `BODYSTRUCTURE`), which names a
`text/calendar` part and its METHOD (`MailMessage.calendarMethod`: REQUEST, REPLY, CANCEL), so it's
known before the body is downloaded. Besides the inbox, Margin looks through the last two months
of saved mail in every folder for messages with calendar data, oldest first: Outlook moves an
invitation to Deleted Items once you answer it, and your answers sit in Sent. Your own answer sets
yours (the invitation's attendee list is updated from its calendar part). Up to 30 bodies not yet
on the device are fetched per pass. An answer sent as plain text without calendar data (Outlook
over IMAP does this unless it's set to send iCalendar) isn't read; nor are JMAP accounts until the
body is downloaded. Answers and cancellations sort into Updates; an answer card replaces their
text (`MeetingNotice.detect(invite:text:)`).

**Where events come from:** invitations in the mail, always. Under the month, each Microsoft or
Google mailbox has **Connect** (one sign-in, the same as Settings → Contacts → Connect, which also
lets New Meeting use that calendar); once connected it shows a check, and Margin also reads
every calendar of that mailbox, its own and ones shared with you (`CalendarListing`: Graph
`/me/calendars` then each one's `calendarView`; Google `calendarList` then each one's `events`
with `singleEvents`), for the month shown, a week either side, at launch, when another month is
shown, and with **Refresh**. A mailbox with several calendars lists each under it in the
sidebar (folded with its chevron), each in its own colour (the main one in the mailbox's) and
hidden on its own (`account:<id>:<calendar>`). Every sidebar section (Mailboxes, Compare with,
Calendar app, Reminders) folds from its heading, remembered (`calendar.folded.*`). On Google,
only the main calendar's events can be changed here.

An invitation that's also in a calendar shows once, opening the invitation's email. They're
matched by iCalendar UID, read the same way however it arrived (`MailModel.meetingUID`: Microsoft
rewrites a meeting from elsewhere into its own hex id carrying the invitation's UID after
`vCal-Uid`, and gives each occurrence its own id), else by the same title at the same time.
Events read from an API stay in memory; they aren't saved.

**Clashes:** an invitation email's card says **Clashes with …** (and how many more) when
something else in your calendars is on then, not counting the meeting itself, all-day events or
ones you declined (`MailModel.clashes`); it reads that day's calendars when it opens.

**Ask** uses the same agenda for the next two weeks, and says when it can only see invitations.

**Code:** `MailUI/Model/MailModel+Calendar.swift`, `MailUI/Model/MailModel+CalendarView.swift`,
`MailUI/Model/MailModel+DeviceCalendar.swift`, `MailUI/Model/MailModel+EventEditing.swift`,
`MailUI/Model/MailModel+Colleagues.swift`,
`MailUI/Views/CalendarPage.swift` (the page, the agenda, the list of calendars),
`MailUI/Views/CalendarBoards.swift` (Day, Week, Month, dragging),
`MailUI/Views/CalendarEditing.swift` (the editor, the repeating-event question),
`MailCore/Calendar/CalendarWriting.swift`,
`MailUI/Views/NextEventBar.swift`, `MailCore/Calendar/CalendarEvents.swift`,
`MailCore/Calendar/DeviceCalendar.swift`. Tests: `Tests/MailUITests/CalendarPageTests.swift`,
`Tests/MailUITests/DeviceCalendarTests.swift`, `Tests/MailUITests/EventEditingTests.swift`, `Tests/MailUITests/ColleagueCalendarTests.swift`. Snapshots: `-snapshot-place calendar
-snapshot-calendar-mode agenda|day|week|month` (sample meetings, Calendar app events and reminders).

## AI apps (MCP)

AI apps connected to Margin (docs/intelligence.md, "Connections") see and manage the same
calendar as the Calendar page, through the tools in `MailUI/Connections/MailToolbox+Calendar.swift`.
The tools are `get_events`, `find_free_time`, `list_calendars`, `create_event`, `move_event`,
`update_event` and `delete_event`.

- **Reading, whenever the connection is on:** `get_events` (a range of up to 92 days, by
  default the next week; optionally one calendar or words in the title, place or people),
  `get_event` (one event in full: guests and their answers, rooms, join link, notes, organizer,
  source, and the conversation its invitation came in), `list_calendars`, `list_reminders`,
  `find_free_time`, `get_free_busy` and `suggest_meeting_times`. Events come from every source the page shows:
  invitations in the mail (`source: invitation`), connected Microsoft 365 and Google calendars
  (`account`) and the Calendar app (`calendar_app`), with the same de-duplication. A range
  outside the months the page has read is read afresh for the AI app without changing what the
  page shows (`agenda(from:to:accountEvents:deviceEvents:)`). Calendars unticked in the page and
  mailboxes hidden from AI apps are left out of everything.
- **Free time:** `find_free_time` finds open slots of a given length in working hours (09:00 to
  17:00 unless `work_start` and `work_end` say otherwise; Margin has no working-hours setting),
  weekdays unless asked, up to 31 days ahead, rounded to quarter hours (`MailCore/Calendar/FreeTime.swift`).
  Every event counts as busy except all-day ones and ones you declined; a maybe counts as busy.
- **Colleagues' free/busy:** `get_free_busy` asks the work calendar for up to 20 people or rooms
  (`busyTimes(for:from:to:)`: Microsoft 365 `getSchedule`, Google `freeBusy`). Only a mailbox
  whose Microsoft 365 or Google Workspace calendar is connected can ask; otherwise the tool says
  so. Anyone the calendar says nothing about (outside the organization, say) comes back as
  `unknown`, never as free.
- **Suggested meeting times:** `suggest_meeting_times` gives up to five times for a meeting of
  `minutes` with up to 20 people, the same ones the editor suggests (see Suggested times), each
  with who's `free`, `busy` and `unknown`, and `suggested_by` (`calendar` for Microsoft 365's
  own, `margin` otherwise). Reading only; `create_event` books one. Mailboxes hidden from AI
  apps aren't read or asked.
- **Which calendar:** `list_calendars` gives each calendar an id (`account:…`, `device:…`,
  `invitations`, `reminders`), and every event carries its `calendar_id`. A mailbox and a
  Calendar app calendar can share a name ("Work"), so a name is only taken when one calendar has
  it; otherwise the tool lists the ids to choose from, never guesses. A calendar that couldn't be
  read just now is named in `unreadable_calendars`, so an empty day there isn't taken for a free one.
- **Changing, with "Allow changes":** `create_event` adds an event to the one calendar named
  (by id from `list_calendars`; the one used last, or the Calendar app's default, when left out),
  `move_event`, `update_event` and `delete_event` change an event in the calendar it lives in
  (only that date of a repeating event, unless `all_dates`), through the same functions as the
  page (`MailModel+EventEditing.swift`), so the page shows the change at once with **Undo**.
  Nothing is copied between calendars. Only events you can change in the page can be changed:
  other people's meetings and invitations only known from the mail are refused, with a pointer to
  `respond_to_invite`. `set_reminder_done` ticks a reminder done or not done, and
  `create_reminder` adds one (on a day or at a time, in a list) to the Reminders app.
- **Telling other people needs "Allow sending" too:** inviting people with `create_event` (only
  into a mailbox's calendar, which sends the invitations), changing or deleting an event that has
  guests (their calendars tell them), and answering. `respond_to_invite` answers either the
  invitation in a conversation (`id`) or an event from `get_events` (`event_id`), through the
  same once-per-answer path as the page's Going?: the account's calendar for its events, a reply
  email for invitations from the mail. The Calendar app's own events can't be answered from here.
- **Undo:** `undo_last` doesn't take back calendar and reminder changes; the notice in Margin
  has Undo for event changes.
- **Asking first:** the tools never ask for calendar or reminders access. While the Calendar
  app or Reminders isn't shown in the page, the tools say to press **Show** there.
- **Trying it:** `Margin -sample-mail` on the Mac runs Margin with the sample mailboxes,
  meetings, Calendar app events and reminders, its connection on port 47911 with its own
  settings and token, and changes and sending allowed; `Margin --mcp -sample-mail` is its stdio
  bridge, which never reaches the real Margin. Tests: `Tests/MailUITests/CalendarToolsTests.swift`.

## Add to Notes (Mac)

A message's … menu has **Add to Notes** next to Add to Reminders. It makes a note in the Notes app
with the subject as its title, who sent it and when, the latest message's text, and an **Open in
Margin** link (`margin://message/…`). Notes has no framework for other apps, so Margin asks it
through AppleScript (`NSAppleScript`, `com.apple.security.automation.apple-events`,
`NSAppleEventsUsageDescription`); the Mac asks once whether Margin may control Notes, and if
that's refused Margin says where to allow it. The text is escaped for HTML and for the script's
string, so a message can't run anything (`DeviceCalendarTests.notesTextIsEscaped`). iPhone and
iPad have no way for an app to add a note, so it's Mac only.
