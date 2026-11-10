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

**Code:** `MailUI/Model/MailModel+Calendar.swift`, `MailUI/Views/NextEventBar.swift`.
