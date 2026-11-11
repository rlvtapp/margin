# Contacts and meetings

The same on Mac, iPhone and iPad.

## Contacts

Settings → Contacts. Contacts only feed address suggestions (and fill in names the mail didn't
have); they stay on the device in `contacts.json` and refresh at launch and about every hour.

- **Contacts app:** off until turned on, then asks for permission. It already includes the iCloud,
  Google and Exchange accounts added to the system.
- **Microsoft and Google accounts:** **Connect…** asks the account for contacts and its calendar in
  the sign-in sheet. Microsoft gives saved contacts and the people you work with (Graph `/me/contacts`
  and `/me/people`); Google gives contacts and "other contacts" (People API).
- **Saved mail, every folder:** typing two or more letters in an address field also looks through
  everyone on mail saved on this device, in every mailbox and folder, Sent included (senders and
  recipients; `MailCache.people(matching:)`), most frequent first.
- **Work directory search (Microsoft 365):** with a Microsoft account's contacts connected, the same
  pause also asks Graph's people search (`/me/people?$search=`) and the organization's directory
  (`/users?$search=` with `ConsistencyLevel: eventual`, scope `User.ReadBasic.All`, no admin consent
  needed), so colleagues you've never written to are suggested too. Personal accounts have no
  directory and return nothing. Results come after the people already known
  (`RecipientSuggestions`, `MailModel.searchDirectories`). Accounts connected before the directory
  scope was added need **Connect…** once more.
- **CardDAV:** Fastmail, iCloud, Nextcloud and others: server, username and an app password. The
  server is found through `/.well-known/carddav`, the principal and the address book home.

Suggestions rank people you write to, then people who write to you, then everyone else from the
address books.

AI apps connected to Margin look people up with `find_people`, which returns the same suggestions
(with where each was found), leaving out mailboxes hidden from them.

## Meetings

**New Meeting** (File menu and ⌥⌘N, the command palette, and the iPad keyboard): title, start,
length, people, room or place, notes.

- **Microsoft 365 and Google accounts with their calendar connected:** the meeting is created in
  that calendar, which sends the invitations. Busy people are flagged as you add them.
- **Every other account:** an invitation by email (iCalendar `METHOD:REQUEST`) that any calendar
  can accept.
- Either way it appears in Margin's calendar (next meeting bar, reminders, Home).

## Rooms

In New Meeting, **Add Room…** lists the organization's rooms with Free or Busy for the meeting's
time (Free only by default), and any room can also be added by its address. The room goes on the
invitation as a resource, so it books like in Outlook or Google Calendar.

- **Microsoft 365:** rooms come from `/places` (needs `Place.Read.All`, which some organizations
  must allow as an admin), falling back to `findRooms`.
- **Google Workspace:** only admins can list every room (Directory API). Everyone else adds a room
  by its address, and still sees whether it's free.

## Who's coming

Invitations show a line like "3 yes · 1 maybe · 2 no answer" that opens into everyone invited
(rooms included) with their answer. Answers come from three places, newest winning: the
invitation itself, reply emails (an iTIP `REPLY` updates the one person answering), and, when the
account's calendar is connected, Microsoft 365 or Google directly (by the event's iCalendar UID).
Meetings sent from here open on their own (next meeting bar, Home) with the same guest list.

## With Daybook

When Daybook (the calendar app) is installed, invitations show **Open in Daybook** instead of Add
to Calendar, meetings open there, and New Meeting can hand over to Daybook to find a time. Daybook's
Email Guests and Show Invitation Email open here. See [daybook.md](daybook.md).

## Adapters

The model talks to two interfaces, not to providers:

- `CalendarAdapter`: rooms, busy times, sending a meeting, and attendees' answers. Implemented by
  `MicrosoftGraphClient`, `GoogleCalendarClient`, and `EmailCalendar` (invitations by email, for
  every other account: no rooms or busy times, answers from replies).
- `ContactsAdapter`: contacts. Implemented by `MicrosoftGraphClient`, `GooglePeopleClient`,
  `CardDAVClient` and `SystemContacts` (the Contacts app).

A new provider is one adapter plus its sign-in scopes in `APIAccess`.

Access beyond mail is asked for only when someone turns it on, and kept in the Keychain apart from
the mail tokens (`APIAccess`, `APITokens`).

**Code:** `MailCore/Calendar/Adapters.swift`, `MailCore/Contacts/` (`MeetingAttendee.swift`, `CardDAV.swift`, `VCard.swift`, `MicrosoftGraph.swift`,
`GooglePeople.swift`, `GoogleCalendar.swift`, `MeetingInvite.swift`), `MailCore/Auth/OAuth.swift`;
`MailUI/Model/MailModel+Contacts.swift`, `+Meetings.swift`; `MailUI/Views/ContactsSettings.swift`,
`NewMeetingView.swift`, `MeetingGuests.swift`. Tests: `CardDAVTests`, `GraphAndPeopleTests`,
`GoogleCalendarTests`, `MeetingAnswersTests`.

## Pictures

An avatar shows the person's picture when one of your own address books has it, and their
initials otherwise. Pictures only ever come from where the contact came from:

- **The Contacts app**: the contact's thumbnail, read with the contact.
- **A contacts server (CardDAV)**: the vCard's `PHOTO`, as bytes or as an https link.
- **Google**: the photo address the People API gives with the contact (`photos`). Google's
  made-up letter pictures (`default`) are skipped; Margin draws its own initials.
- **Microsoft**: saved contacts through `me/contacts/{id}/photo`, colleagues through
  `users/{address}/photo`. A personal account has no directory, which just means no picture.
- **Your own mailboxes**: the picture chosen for the mailbox.

Nothing is looked up from the address alone on some other service, so writing to someone never
tells a third party about them.

How it fits together: each `Contact` carries a `ContactPicture` note (`saved`, a `url`, or a
Microsoft reference). Pictures that arrive with the contact are written to the picture store
when contacts are refreshed (`savingPictures`); the rest are fetched the first time that
person's avatar is drawn (`MailModel.pictureData(for:)`). The store (`ContactPictureStore`,
`pictures/` in the app's folder) keeps one 192-pixel JPEG per address, in a file named by a
hash of the address, and remembers for a week that someone has none. `Avatar` reads from
`ContactPictures.shared`, which asks the model once per address and redraws when it arrives.

Tests: `ContactPictureSourceTests` (MailCore), `ContactPictureStoreTests` (MailUI).
