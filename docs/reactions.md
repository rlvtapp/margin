# Reactions

The same on Mac, iPhone and iPad.

## What the providers offer

Email has no reactions of its own. Outlook's (👍 ❤️ 🎉 😆 😮 😢) live inside Microsoft's servers:

- **No API.** Microsoft Graph (v1.0 and beta) and EWS have no way to read reactions on a message or
  to add one. Teams messages have `setReaction`; mail doesn't. Outlook keeps them in undocumented
  mailbox properties (`OwnerReactionType`, `ReactionsSummary`, `ReactionsCount`, property set
  `{41F28F13-83F4-4114-A584-EEDB5A6B0BFF}`), named in a Microsoft blog post but not in the Exchange
  specifications. Margin doesn't read or write them.
- **Between Exchange Online mailboxes** (work and school accounts, also across organizations) a
  reaction shows in Outlook's notifications and a digest email. Nothing reaches IMAP.
- **To anyone else** (Gmail, iCloud, Fastmail, your own server) Outlook sends a short email instead:
  `RE: <subject>` with In-Reply-To and References, then `[like]  Jane Jolie reacted to your
  message:` and the original quoted below a line of underscores. The formatted version shows the
  reaction as a picture (`<img alt="like" src="https://outlook-1.cdn.office.net/assets/reaction/like.png">`);
  some apps turn that into `<https://…/assets/reaction/like.png>` in the text. Taking a reaction
  back sends one with `alt="0"`. There's no reaction header. Microsoft doesn't document any of this;
  it's from real samples (and a French one: "a réagi à votre message :"). The names are like, heart,
  celebrate, laugh, surprised (😲) and sad.
- **Sending one back doesn't make an Outlook reaction.** Nobody has found a way: Exchange shows
  incoming reaction emails, Gmail's included, as ordinary mail.
- **Gmail** documents its own format: a `text/vnd.google.email-reaction+json` part,
  `{"version":1,"emoji":"👍"}`, between the text and the HTML, with In-Reply-To naming the message
  ([format](https://developers.google.com/workspace/gmail/reactions/format)).
- **Turning them off:** a message with the header `x-ms-reactions: disallow` can't be reacted to in
  Outlook (Microsoft's one documented control). Margin honours it too.

Sources: [Reactions in Outlook](https://support.microsoft.com/en-us/office/reactions-in-microsoft-outlook-06315501-a790-4a2a-90c1-fbc89d84c393),
[Manage reactions](https://learn.microsoft.com/en-us/microsoft-365-apps/outlook/manage/manage-outlook-reactions),
the Graph [message](https://learn.microsoft.com/en-us/graph/api/resources/message?view=graph-rest-beta) reference.

## Seeing reactions

A reaction email shows as a chip under the message it answers ("😆 Jane", "👍 3"; hover or
long-press for who), instead of as a message of its own. It's placed on the message its reply
headers name, or else on the latest earlier message someone else wrote. If that message isn't in
the conversation (older than what's loaded), the reaction shows as one line ("Jane reacted to your
message") with the subject, and **Show message** shows the email as sent.

Recognised as reactions, only in replies:

- **Outlook's email**, from the plain text or the preview: `[like]`, `[heart]`, `[celebrate]`,
  `[laugh]`, `[surprised]`, `[sad]` (or an emoji, the picture's link, or the picture in the
  formatted version), then "reacted to your message" in any of Margin's languages. Only the English
  and French wording are confirmed from real mail; the others are Margin's best guess.
- **Outlook's "taken back" email** removes that person's reaction.
- **Gmail's reaction part.**
- **The same shape in other languages**: a known reaction, then the sender's name and a few words
  before a colon (`👍 Jane Jolie reagerade på ditt meddelande:`). A tag Margin can't read
  (`[EXTERNAL]`) or a name alone (`👍 Jane: sure`) doesn't count.
- **A reply that is only an emoji** (up to three), maybe with "Sent from my iPhone" or the quoted
  original after it. `👍 on it` is an ordinary reply.

Reaction emails sort into **Updates**, not People, so they don't count as mail that needs you. In
the list, a conversation's row leaves its reactions out (names, preview, count), and replies and
suggested replies answer the last person who wrote, not the last who reacted.

## Reacting

The smiley button under a message from a person offers Outlook's six reactions. Reacting sends the
sender (only them) a short reply in Outlook's shape, in the app's language:

```
👍 Kaan Mol reacted to your message:
________________________________
From: Jane Jolie <jane@example.org>
Sent: Tuesday, November 10, 2026 at 09:12
To: Kaan Mol <kaan@example.com>
Subject: Plans

<the original text>
```

It also carries Gmail's reaction part, so it reads as a reaction in Margin and in Gmail, and as a
short reply anywhere else, Outlook included (Exchange shows incoming reaction emails as ordinary
mail). Gmail's part is left out where Gmail wouldn't take it: when you weren't in To or Cc, or the
message went to more than 20 people. Not yet tried against a real Gmail or Microsoft 365 mailbox.

It's offered only on messages from a person (not lists or automatic mail), not on your own, not when
the sender sent `x-ms-reactions: disallow`, and once per message. A reaction is mail, so it can't be
taken back. It's sent straight away (no Undo Send wait) and shows on the message at once.

Code: `MailReaction` (MailCore, recognising, placing, the reply, Gmail's part), `MIMEParser` and
`MessageBuilder` (`MessageBody.reaction`, `Draft.reaction`), `MailModel+Reactions.swift`,
`ReactionViews.swift`; hooked into `MessageView` (`ReaderView.swift`) and `TouchConversation.swift`.
The `x-ms-reactions` header is fetched with the list (IMAP `HEADER.FIELDS`, JMAP `header:`).
Tests: `ReactionTests` (including the shape of a real Outlook reaction email). Snapshot mode:
`-snapshot-select "Launch plan" -snapshot-reactions`.

## Outlook's own reactions (opt-in, unofficial)

Between two Microsoft 365 mailboxes no email is sent, so these only show when **Show Outlook
reactions** is on: Mailboxes → Edit… → **Reactions**, Microsoft accounts only, off by default. Turning
it on asks the account for `Mail.Read` in the sign-in sheet (sign-in itself never asks for it).
Turning it off stops using that permission and forgets what was read; the permission stays granted in
the Microsoft account until removed there (My Apps or account.microsoft.com → Privacy → Apps).

How it works: when a conversation opens, Margin asks Graph for its newest 12 messages by Message-ID
(`/me/messages?$filter=internetMessageId eq '<…>'`, any folder, Sent included), each at most every
two minutes, expanding Outlook's undocumented `ReactionsSummary` property (`Binary
{41F28F13-83F4-4114-A584-EEDB5A6B0BFF} name ReactionsSummary`). That's a small binary list: `v` and a
version byte; counts (`=` and a 16-bit count each) up to a zero byte; then per person a flag byte
(1 = Bcc), the time as 32-bit minutes since 1601, and `emoji,name,address,` up to a zero byte. Decoded
the way MSGReader (`Reaction.cs`, MIT) and Glen Scales' `Reactions.ps1` do; `0` is a reaction taken
back and is left out. The reactions join the ones that came by email, one per person (the newest).

Microsoft documents none of this and can change it: reading then returns nothing and the chips from
Outlook stop appearing; nothing else breaks. Untested against a real mailbox. Reacting still sends the
short reply: writing these properties only changes your own copy, it doesn't reach the sender.

Code: `OutlookReactions` and `MicrosoftGraphClient.outlookReactions(messageID:)`
(`Sources/MailCore/Contacts/OutlookReactions.swift`), `APIAccess.reactions`,
`MailModel.loadOutlookReactions(for:)`, `OutlookReactionsSection`. Tests: `OutlookReactionsTests`.
