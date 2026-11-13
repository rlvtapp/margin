# Home and sorting

**Home** (in the sidebar on every device) is the inbox at a glance:

- A greeting, and how much mail came in today.
- **Don't forget:** today's meetings (from invitations), sent mail still waiting for a reply,
  and bills that haven't been opened.
- A tab per group (Bills to Pay, Travel, Customers…), with how many conversations each has, and
  **Sort now**.

## Layouts

Settings → Reading (Mac) or Appearance (iPhone and iPad) → Layout:

- **Side by side:** the list and the conversation next to each other.
- **Wide list:** the list across the whole window; a conversation opens over it (Mac).
- **Tabs:** side by side, with tabs above the list for the inbox, unread mail and each label, and
  today's meetings.
- **Minimal:** opens on Home without the sidebar; a conversation opens over the list.

On the Mac:

- **Search** sits in the bar across the top of the window (`WindowBar`), with the Unread, Starred
  and Attachments toggles at its end; `/` still jumps to it.
- **Window:** the list and reader edge to edge on the window (the default), or in a rounded inset
  panel (Settings → Appearance → Window, also in the welcome).
- **The one next thing** (`NextUpBadge`), top right of that bar: the next meeting when one is
  happening or starts within a few hours (Join when it's about to start), otherwise the next
  snoozed conversation coming back today. Nothing when there's nothing.
- **Next up** (`NextUpColumn`): with Side by side and enough room, a column right of the reader.
  The next meeting leads as a small card (how soon, time and place, Join); then the rest of the
  week's meetings (All day for all-day ones), **Open Calendar**, snoozed mail and when it comes
  back, and mail waiting for a reply. Meetings come from the same list as the Calendar (account
  calendars and invitations in mail); clicking one opens its invitation. The button next to the
  badge shows or hides it; while it shows, the badge steps aside.

Each mailbox can be left out of All Inboxes (Edit… on the mailbox); it keeps its own inbox,
alerts and everything else. The newest conversations are read ahead after every refresh, so they
open instantly.

## Sorting

Settings → Sorting holds the groups. Each has a name and a line saying what belongs in it; they
can be renamed, reordered, added and removed, and **Start Over** brings back the starter set
(People, Team, Customers, Bills to Pay, Receipts, Orders, Travel, Meetings, Documents, Services,
Newsletters, Promotions).

Sorting a conversation gives it its group as a label, so groups work everywhere labels do:
search, AI apps, backups.

- **With the assistant on**, it reads each conversation and picks one group, or none
  (`MailIntelligence.classify`). That uses whichever model is chosen in Settings → Assistant,
  on the device or with the person's own key.
- **Without it**, only clear cases are sorted, by rules (`EmailSorter.ruleGroup`): invoices,
  receipts, orders, travel, invitations, account notices and newsletters.
- **Sort now** works through the inbox, shows how far it is, and can be stopped. It looks at conversations it hasn't seen, or that got a new message since. Taking one out of its group with the label's ✕ lets it look again; **Not in a group** (Move to group) keeps it out for good (`MailModel.keptOut`). With nothing new, it looks once more at the conversations nothing fitted (`MailModel.lookedAgain` marks them, so a further click doesn't go round again until new mail arrives in them), and says "Nothing new to sort" when there are none, or "None of them fit a group" when a run sorts nothing.
- **Sort new mail as it arrives** sorts the last few hours' mail every minute or so.

**Code:** `MailCore/Triage/EmailGroups.swift`, `MailUI/Model/MailModel+Sorting.swift`,
`MailUI/Views/HomeHeader.swift`, `MailUI/Views/SortingSettings.swift`.

## Margin notes

Home opens with the date and how many conversations need you ("Monday, 9 November · 3 need
you"), not a greeting. Each Home row has a short note in its left margin, against a thin rule,
saying why it matters now (`MailModel.marginNote(for:)`, first match wins):

- **code**: it holds a sign-in code;
- **at 15:00** / **Thu 10:00** / **now**: a meeting from its invitation;
- **bill**: it's in Bills to Pay and asks you to pay: a pay link or "pay now", bank transfer
  details (IBAN, overmaken), a payment reminder, overdue, or a charge that failed
  (`MailNotice.asksForPayment`, read on the device from its words). An invoice that only says
  it's there (amount, due date, PDF) is taken automatically as a rule, and a receipt is paid, so
  neither gets a note. Ask's "bills not opened yet" leaves the same ones out;
- **reply owed** / **owed 3d**: the last word is from someone you know, in the last three weeks,
  and you haven't answered, and it isn't a reminder, confirmation, receipt or system message
  (`MailNotice.expectsNoReply`: an appointment reminder from your dentist asks nothing). Addresses
  like `service@`, `invoice@` or `reminders@` count as automated in the inbox split too. Ask's
  "what needs a reply" uses the same check.

Under the date, one sentence sums it up ("Two replies to write and a bill to open. Planning at
10:00."), from `MailModel.homeSummary`. AI apps connected to Margin get the same list and sentence
with `list_needs_you` (sign-in codes named, never shown).

Rows without a reason keep an empty margin so they line up. The count at the top is the rows
with a note. Every Home layout uses the same date line and notes.
