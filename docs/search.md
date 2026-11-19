# Search

Typing in the search field filters the mail on screen at once. Return searches everything: mail
saved on this device first, then every account's server, and the results come together in one
list ("12 found so far · searching servers…" until the last server answers).

## Operators

Operators are a fixed syntax, the same in every language. Anything that isn't one stays words to
find; every word must match. Quotes keep a phrase together: `subject:"launch plan"`, `"press day"`.
Case doesn't matter.

| Operator | Finds |
| --- | --- |
| `from:maya` | Mail from someone whose name or address contains "maya" |
| `to:sam`, `cc:sam` | Mail to or copied to them (both look in To and Cc) |
| `subject:invoice` | Those words in the subject |
| `has:attachment` | Mail with files attached |
| `is:unread`, `is:read` | Unread or read mail |
| `is:starred`, `is:unstarred` | Starred mail, or mail that isn't |
| `after:2026/03/14`, `since:` | Mail on or after that day (`2026-03-14` works too) |
| `before:2026/04/01` | Mail before that day |
| `older_than:7d`, `newer_than:2w` | Relative to now: `d` days, `w` weeks, `m` months, `y` years |
| `in:inbox`, `in:sent`, `in:drafts`, `in:archive`, `in:trash`, `in:spam` | One standard folder |
| `in:receipts` | One of your own folders, by name |
| `in:people`, `in:updates`, `in:newsletters` | One part of the inbox (decided on the device) |
| `in:anywhere`, `in:all` | No folder limit (the default) |

A date that can't be read (`before:tomorrow`) is left as a word to find, so nothing is silently
dropped. `in:` with a folder the account doesn't have doesn't narrow anything.

## How a search runs

`SearchQuery` (MailCore) parses the text into its parts: words, people, subjects, flags, dates
and a folder. Relative dates are turned into moments when the text is read, so a saved search
keeps meaning "the last week".

1. **Saved mail.** The full-text index (`MailCache.search`) is searched for the words plus the
   people and subjects named, so `from:maya` alone still finds Maya's mail. Mail in the inboxes
   on screen is checked too. Both are narrowed by every operator (`SearchQuery.matches`); `in:`
   is looked up among each account's folders.
2. **Servers**, all at once; each provider parses the same text:
   - **IMAP:** a `UID SEARCH` (`IMAPSearch.criteria`): `FROM`, `OR TO … CC …`, `SUBJECT`,
     `UNSEEN`/`SEEN`, `FLAGGED`/`UNFLAGGED`, `SINCE`/`BEFORE` (dates as `14-Mar-2026`) and `TEXT`
     for words. There's no standard key for attachments: `has:attachment` asks for
     `multipart/mixed` mail, and what comes back is narrowed to real attachments on the device.
     The folder `in:` names is the one searched; otherwise the inbox, the archive (or all mail)
     and Sent.
   - **IMAP with raw search** (servers announcing `X-GM-EXT-1`): the query rebuilt in that
     syntax as one `X-GM-RAW` key (`IMAPSearch.rawCriteria`), over all mail. It's rebuilt from
     the parsed parts, so only what the server understands reaches it (`in:people` doesn't);
     dates go as seconds since 1970, so `older_than:` keeps its time of day.
   - **JMAP:** an `Email/query` filter (`JMAPSearch.filter`, RFC 8621 §4.4.1): `from`, `to`/`cc`
     under `OR`, `subject`, `hasAttachment`, `hasKeyword`/`notKeyword` for `$seen` and
     `$flagged`, `after`/`before` in UTC, `inMailbox` and `text`, joined with `AND`.
   - **Microsoft Graph:** `GraphMailProvider.searchParameters`. Words, `from:`, `to:`,
     `subject:`, `has:attachment` (`hasAttachments:true`) and dates (`received>=`, `received<`,
     whole days) go as KQL in `$search`; a phrase goes as its separate words. `in:` searches that
     folder's messages. Graph won't take `$filter` beside `$search`, so `is:unread` and
     `is:starred` narrow the results on the device, or go as `$filter` when nothing else was
     typed. `to:` asks Graph for To only; the device check also looks in Cc.
3. Results are merged, one per Message-ID, newest first, and narrowed by the operators again.

IMAP quoted strings must be ASCII. A search with other text (`café`, `from:zoë`) isn't sent to
IMAP servers; saved mail answers it. JMAP and Graph take any text.

## Saved searches

The bookmark button at the top of a search's results keeps it in the sidebar under **Searches**;
clicked again, it's taken out. A saved search is named after what was typed; right-click it to
rename or delete it. Clicking one runs it again, with its text in the search field. Saved
searches are kept on this device (`savedSearches` in the app's defaults) as the typed text, and
last across launches (`MailModel+SavedSearches`).

## Trying it

```bash
.build/xcode-snapshot/Build/Products/Debug/Margin.app/Contents/MacOS/Margin -snapshot out.png -snapshot-search "from:maya has:attachment"
```

`-snapshot-search` runs that search on the sample mail and keeps it as a saved search, so the
sidebar shows one.
