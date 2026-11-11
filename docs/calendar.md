# Calendar from invitations

Margin keeps a small calendar of the events in invitations it has seen. It stays on the device
(`calendar.json`).

- **Finding them:** an invitation is remembered whenever its message is opened. Every few minutes,
  mail in the inbox that looks like an invitation is read too (from the offline cache when it can
  be), so events are known before they're opened.
- **Next meeting:** above the mail list on Mac, iPhone and iPad, the next meeting in the coming
  hours, with **Join** when it has a meeting link and starts within ten minutes.
- **Reminders:** a notification before each event, 5–30 minutes ahead (Settings → Reading, or
  Settings → Reading on iPhone), or off. Cancelled and declined events are left out.
- **Answering:** Accept, Maybe and Decline send the organizer a proper reply. Add to Calendar hands
  the event to the Calendar app.
- **Home** lists today's meetings under "Don't forget".

## The Calendar view

A simple page for what's coming up, not a calendar app (that's Daybook). The same on Mac, iPad and
iPhone.

- **Opening it:** the calendar button in the account column on Mac (under Snoozed), **Calendar** in
  the sidebar, or **Calendar** in the mailbox list on iPhone and iPad. On Mac the mailbox sidebar
  steps aside while it's open.
- **Header:** Calendar, where the meetings come from, and **Refresh** (looks through the mail
  again and rereads account calendars).
- **Month:** pick a day; days with something on have a dot, today is in the accent colour, the
  chosen day sits on a soft circle. Neighbouring months' days are faded. **Today** comes back.
- **Agenda:** from the chosen day, two weeks by day (Today in the accent colour, Tomorrow, then
  the date). Each meeting: an accent line, the time (or All day) with Repeats under it, the title,
  and where (a room, or the call's service from its link) and who invited you. Meetings that
  have ended are left out; declined ones are dimmed; cancelled ones aren't shown.
- **Going?** Yes, Maybe and No under each meeting you were invited to, yours filled in the
  accent colour. Events from an account's calendar are answered through it (Microsoft 365
  `accept`/`tentativelyAccept`/`decline`, Google by updating your attendee entry); the organizer
  is told. Invitations only known from mail are answered with an iTIP reply, as in the message.
  Meetings you organized have no answer.
- **Up next:** from today, the next meeting leads as a card: a live countdown ("In 25 min",
  "Now · 20 min left"), the title, time, place and organizer, up to five guests' faces and how many
  are invited, Going?, and Join filled in the accent colour.
- **Between meetings:** today has a line for now with the time; gaps of half an hour or more say
  how long you're free ("1 h 30 free"); a meeting that starts before the previous one ends says
  "Overlaps with …".
- **Clicking a meeting** opens the email its invitation came in, wherever it is now.
- **Join** on events with a meeting link: filled in the accent colour when it starts within 15
  minutes or is on now, a soft tint before that.
- **Right-click:** Show Invitation (opens the email, wherever it is now) and Copy Meeting Link.

**From your mail:** besides the inbox, Margin looks through the last two months of saved mail in
every folder for invitations and answers, oldest first: Outlook moves an invitation to Deleted
Items once you answer it, and your "Accepted:" replies sit in Sent. Your own reply sets your answer
(the invitation's attendee list is updated from it). Up to 20 bodies not yet on the device are
fetched per pass.

**Where events come from:** invitations in the mail, always. Under the month, each Microsoft or
Google mailbox has **Connect** (one sign-in, the same as Settings → Contacts → Connect, which also
lets New Meeting use that calendar); once connected it shows a check, and Margin also reads that calendar
(`/me/calendarView`, or Google's `events` with `singleEvents`) for the month shown, a week either
side, at launch, when another month is shown, and with **Refresh**. An invitation that's also in
the account's calendar shows once (matched by iCalendar UID). Events read from an API stay in
memory; they aren't saved.

**Ask** uses the same agenda for the next two weeks, and says when it can only see invitations.

**Code:** `MailUI/Model/MailModel+Calendar.swift`, `MailUI/Model/MailModel+CalendarView.swift`,
`MailUI/Views/CalendarPage.swift`, `MailUI/Views/NextEventBar.swift`,
`MailCore/Calendar/CalendarEvents.swift`.
