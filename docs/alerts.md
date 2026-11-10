# New mail alerts and email links

## Alerts

- **What to hear about:** all new mail, **Smart** (people you know and sign-in codes), **Only VIPs and
  sign-in codes** (see [desk.md](desk.md)) or none. Each mailbox
  can follow that or have its own (Edit… on the mailbox → Notifications). Sign-in codes come
  through unless a mailbox's alerts are off entirely.
- **Smart** alerts only for mail in People from someone you know: a contact, a VIP, someone
  you've written to (from saved mail, including Sent), or a reply in a conversation you're part
  of. A promotion that looks personal (no list headers) from a stranger stays quiet.
- **Sound:** on the Mac, Margin's sound, any of the Mac's alert sounds, or none; on iPhone and
  iPad, the system sound or none.
- **Drop-down alerts (Mac):** while Margin runs, new mail comes down from the top of the screen.
  On a Mac with a notch it drops out of the notch, black like the notch; elsewhere it slides
  down under the menu bar. A sign-in code shows big, already copied; a sign-in or "confirm your
  email" link gets one button that opens it in the browser; other mail has Open, Reply (answered
  right there, from the address it came to, with the signature) and Dismiss. Turn it off to get
  ordinary notifications instead.
- **Menu bar (Mac):** sign-in codes and links from the last 15 minutes (one click to copy or
  open) and the newest unread mail, each with a quick reply. It can be turned off in Settings.
- **Sign-in codes** are copied when they arrive (see [siri.md](siri.md)). On the Mac they can
  also be typed into the field you're in (off by default; needs Accessibility permission, and
  only works in the direct download, since App Store apps can't type into other apps).
- **Workspaces you're not in** check mail quietly: no alerts except sign-in codes.

## Email links

On the Mac, Settings → Writing → Email links makes Margin the default mail app, so `mailto:`
links on websites and in other apps open a new message in Margin with the address, subject, body
and Cc filled in. iPhone and iPad register the same links; becoming the default mail app there
needs Apple's mail-client entitlement, which is requested when Margin ships to the App Store.

**Code:** `MailUI/Model/MailModel+Alerts.swift`, `MailUI/Views/DropDownAlert.swift`,
`MailUI/Model/MailModel+Links.swift`, `MailUI/Model/MailModel+Desk.swift` (typing codes).
