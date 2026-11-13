# Assistant and connections

Margin has two optional ways to use AI. Both are off unless you turn them on, and neither uses a server of ours.

- **The assistant** works inside Margin: it summarizes a conversation, suggests labels, drafts or rewrites a reply, and takes actions you ask for ("Sort my mail"). You choose which model does it.
- **Connections** let AI apps you already use (Claude, ChatGPT and others that support MCP) search and read your mail through Margin.

## The assistant

### Where it runs

| Provider | Where mail goes | Needs |
| --- | --- | --- |
| On this Mac | Nowhere: Apple's on-device model (Apple Intelligence) | macOS 26+, Apple Intelligence turned on |
| Ollama, LM Studio | Nowhere: a model running on this computer | The app running, a model downloaded |
| Claude Code, ChatGPT (your subscription) | Anthropic or OpenAI, through the tool's own sign-in | Claude Code, or the ChatGPT app (it carries Codex), on this Mac and signed in (Mac only) |
| Claude | Anthropic, with your API key | An Anthropic API key |
| ChatGPT | OpenAI, with your API key | An OpenAI API key |
| Gemini | Google, with your API key | A Google AI Studio key |
| Grok | xAI, with your API key | An xAI API key |
| Other server | The server you enter (any OpenAI-compatible API) | Its address, and a key if it needs one |

"On this Mac" is the default when it's available; otherwise the assistant starts off. Keys are kept in the Keychain. Requests go straight from Margin to the provider.

Nothing runs by itself. Each request starts with something you did: **Summarize** (M), **Suggest labels** (L), **Draft a reply** (D, or ⌘J in the reply box), and **Shorter**, **Friendlier** and **More formal** on what you've typed. Text the assistant writes is labelled with where it came from ("on this Mac", "by Claude").

### How it's built

- `MailCore/Intelligence/MailIntelligence.swift` writes the prompts once for every provider. It turns a thread into a transcript: quoted history and signatures are dropped, and the newest messages are kept when it has to cut to fit the model's budget. It also tidies answers (label spelling, at most three labels, no empty points).
- `MailLanguageModel` is the seam each provider implements, and what the tests replace with a fake.
- `OnDeviceModel` uses `FoundationModels` with guided generation (`@Generable`). Its budget is small (6,000 characters of conversation) because the on-device context window is small.
- `AnthropicModel` calls the Messages API (`anthropic-version: 2026-10-21`). It uses structured output (`output_config.format` with a JSON Schema) at low effort. It defaults to Claude Opus 5.5; the model list comes from the API, so Sonnet and Haiku can be picked. On models that support it, server-side fallback (`fallbacks: "default"`) is on: if Claude declines a request for safety reasons, Anthropic retries it on a model chosen for that case.
- `CommandLineModel` runs Claude Code (`claude -p --tools "" --strict-mcp-config --no-session-persistence --system-prompt … --model haiku`, the mail on standard input) or Codex (`codex exec --ephemeral --sandbox read-only -c model_reasoning_effort=low -c mcp_servers={} --output-last-message …`) once per request, in an empty temporary folder so no project's instructions apply, and reads the same JSON shapes as the hosted models. It uses the person's own subscription and sign-in; Margin stores nothing.
  - **Speed:** Claude Code's start was most of the wait. With no MCP servers or connectors (`--strict-mcp-config`) and no update checks or telemetry (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_AUTOUPDATER`) a request went from about 4.4 s to about 1 s; a whole draft on Haiku takes about 2.5 s. `--bare` would be faster still but only takes an API key, not a subscription sign-in. Codex takes about 4 s, mostly the model; its tool servers are turned off for these requests (one of them can be Margin itself).
  - **Streaming:** Claude Code runs with `--output-format stream-json --include-partial-messages` for Ask and drafts, and the text of the answer or draft is shown as it arrives (`CommandLineRunner.lines`, `StreamedAnswer` with its key). Codex hands over its answer whole.
  - **Finding them:** where they install themselves (`~/.local/bin`, Homebrew, npm, bun), Codex inside the ChatGPT app (`ChatGPT.app/Contents/Resources/codex-cli/bin/codex`), or through the login shell; looked for once and remembered. They only show in Settings on a Mac that has them. Needs Margin outside the sandbox.
  - They answer but don't act (their tools are off), so "Ask Margin to…" uses another assistant. `CommandLineModelTests` uses a stand-in script; `MARGIN_LIVE_CLAUDE=1 swift test --filter liveClaudeCode` runs the real one.

**Turning AI off.** Settings → Assistant starts with **Use AI**. Off makes Margin a plain mail app (`usesAI`, stored as `aiOff`): no assistant runs at all, so Ask, summaries, suggested replies, AI drafts, translation by AI, rules in words, AI sorting and actions are gone, and AI apps can't connect over MCP (Settings → Connections says so, with **Turn On AI**). Assistants already added stay saved for when it's turned back on. Home still sorts mail into its groups by Margin's own rules, and the system translation, inbox tabs and rule suggestions keep working, since none of them uses a model. The switch travels with a backup.

**Several assistants.** Settings → Assistant lists every assistant added (Add Assistant, Change, Remove), each with its own key and model; new ones start on their fastest, cheapest model (Claude: Haiku; Claude Code: haiku; Codex: low reasoning), which is plenty for mail. **Who does what** picks one for Ask and writing (answers, drafts, summaries, rules in words, translations) and one for **quick suggestions** (the reply bubbles and label ideas); Automatic puts the quick ones on Apple's model on this Mac when it has one (fast, free, private), else the main assistant on its cheapest model (`quickProviderChoice`, `quickIntelligence`, `AssistantSettings.onQuickestModel`: Haiku for Claude and Claude Code, the fastest listed model for ChatGPT; other providers keep their model, since that needs a server's list). **Sorting into groups** (Sort Now, and new mail as it arrives) has its own choice with the same Automatic (`sortProviderChoice`, `sortIntelligence`): it runs once per conversation, so a quick model suits it, and it no longer goes through the Ask assistant. Actions keep their own choice. The list and Ask's header show the Claude and ChatGPT apps' own icons, read from the installed apps through macOS (`ProviderIcon`); Margin bundles no other company's artwork and falls back to a symbol. Ask's header picks any ready assistant and model for the next question (`askChoices`). Ask also answers faster: it routes a question by topic (`askTopic`: schedule, bills, replies, general), sends only the conversations that topic needs, and waits at most 2 s for missing message bodies and 1.5 s for the calendar (`wait(for:upTo:)`). Drafts written with AI now fill in as they're written, on every assistant that streams (Claude, ChatGPT and others with a key, Apple's model, Claude Code).

- `OpenAICompatibleModel` covers ChatGPT, Gemini (Google's OpenAI-compatible endpoint), Grok, Ollama, LM Studio and other servers. It asks for `json_schema` output and falls back to JSON mode, with the schema in the instructions, for servers that don't support schemas.

### Taking actions

The assistant can do things, not just write them: **Sort my mail**, or **Ask Margin to…** followed by anything ("archive last week's newsletters", "star everything from Maya"). On the Mac both are in the command palette (⌘K); typing a sentence there also offers "Ask Margin to “…”" under the search. On iPhone and iPad, the ✨ button in the list's top bar opens a sheet with both; iPad keyboards also have them in the Message menu.

It uses the same tools AI apps get over MCP (the table under [Connections](#connections-mcp)), with the same handlers and the same switches, now also shown in **Settings → Assistant → What the assistant may do**:

- Without **Allow changes** it can only look (search, read, list). The card says so and where to change it.
- **Sort my mail** may always sort into Home's groups (`list_groups`, `list_to_sort`, `sort_into_group`, `skip_sorting`, `read_conversation`), the same thing Sort Now does without asking. It gets no other tools.
- Sending (`send_email`, `send_now`, answering invitations) needs **Allow sending**; without it the assistant can only open a draft for you. The instructions also tell it to send only when asked to.
- Mailboxes hidden from AI apps, Junk, Trash and sign-in codes are hidden from it too.

While it works, a card (bottom right on the Mac, above the list on iPhone) shows each step as it happens ("Looked at mail to sort", "Sorted mail") with **Stop**. "Sort my mail" also drives Home's own progress ("Sorting 12 of 80 · Stop"), and Stop there stops it. Stopping keeps what's done. At the end the card shows the model's one- or two-sentence summary (or how far it got, if it stopped) and **Undo**, which puts back everything the run changed that can be: labels and groups, what sorting had looked at, snoozes, moves, read and star, folders, templates, scheduled mail, rules. Sent mail and unsubscribes stay. Each action is also listed in Recent activity (Settings → Assistant and Settings → Connections) with who did it ("by Grok").

**Which provider takes actions.** Actions can go to a different provider from everything else, so Apple's on-device model can write summaries while Grok (or Claude, ChatGPT, Gemini) sorts the inbox. **Settings → Assistant → For actions, use** picks one; **Automatic** takes the best one set up: hosted providers first (Claude, ChatGPT, Gemini, Grok), then other servers, LM Studio and Ollama, then Apple's model. Every provider set up and saved in Settings → Assistant is remembered (`assistantProfiles`, keys stay in the Keychain), so it stays available for actions after switching the assistant back to another one.

**Providers without tool calling.** The hosted providers and Apple's model support tools. For Ollama, LM Studio and other servers it depends on the server and the model, so Margin finds out: **Check** in Settings asks the model to call a harmless `check_connection` tool, and a real run notices it too, from the server's error ("does not support tools", "requires --enable-auto-tool-choice", "requires --jinja") or, for "Sort my mail", from an answer with no tool calls at all. The answer is remembered per server and model. A provider that can't take actions drops out of the list, Settings says "LM Studio can answer questions but can't take actions. Actions go to Grok instead.", and a run that hits it hands over to the next provider, with a line on the card ("LM Studio can't take actions, so Grok took over."). Apple's model hands over the same way when a job is too big for it. When no provider can, the card says so and what to set up; nothing fails silently.

A run makes at most 40 requests for "Sort my mail" and 25 otherwise; tool results are cut to fit the model (40,000 characters for hosted models, 12,000 for local ones, 3,000 on device).

| Provider | How tools are sent |
| --- | --- |
| Claude | Messages API `tools` with `input_schema`; `tool_use` blocks back; all `tool_result` blocks in one user message (`is_error` on failures). The answer's content, thinking blocks included, is sent back unchanged. Effort is medium; server-side fallback as above. |
| ChatGPT, Grok, Ollama, LM Studio, other servers | Chat Completions `tools` (type `function`) with `tool_choice: "auto"`; `tool_calls` back (arguments as JSON text, or an object from some local servers); one `tool` message per result. Arguments that aren't valid JSON aren't run; the model is told to try again. |
| Gemini | Gemini's own `generateContent` (next to the OpenAI-style address in Settings): `functionDeclarations` with `parametersJsonSchema`, `functionCall` parts back, `functionResponse` parts (with the call's id) in a user turn. The model's content is sent back unchanged, so thought signatures are kept. |
| On this Mac / device | Foundation Models: each tool is a `Tool` whose arguments come from the same JSON Schema, converted to a `DynamicGenerationSchema`; the framework runs the loop. Its context window is small, so it gets 14 tools (or the 5 sorting ones) and asks for 10 conversations at a time. |

**Code:** `MailCore/Intelligence/MailAgent.swift` (the shared loop, `AgentLoop`, and the three HTTP formats), `OnDeviceAgent.swift` (Foundation Models), `MailUI/Model/MailModel+Agent.swift` (permissions, steps, progress, undo), `MailUI/Intelligence/AgentViews.swift` (the card, the iPhone sheet, the switches). `MailToolbox` takes `permissions` and `only` so the same tool list serves both MCP and the assistant. Tests: `AgentLoopTests` (the loop, and each provider's requests and answers over a stubbed network) and `AssistantAgentTests` (a scripted model driving the real tools).

### Ask

Ask is a chat about your mail, with past chats kept on the device and slash commands (`/catchup`, `/replies`, `/waiting`, `/summarize`, `/reply`, `/cleanup`, `/unsubscribe`, `/feedback`, `/help`). `/feedback the dark mode is lovely` opens a message to the Margin team (hello@relevate.app for now) with what you wrote and your Margin version; nothing goes out until you send it. Settings → Assistant → Ask sets the answer length (brief, normal, detailed), your own instructions, whether it looks only in the mailbox in view, and the suggested questions it starts with (`AskPreferences`). Without an assistant (no Apple Intelligence on the device and no other service), Ask isn't offered anywhere: not in the reading pane, Home, ⌘K, search or the menus. Summaries are kept on the device and come back while their conversation has no newer email. Beside the question field:

- **Attach** pictures, PDFs or text files. Their text goes along with the question; words in pictures are read on the device (Vision), so this works with every provider.
- **Dictate** the question. Speech is turned into text on the device when it supports that; the microphone is only on while dictating.
- **Model** in the header shows which model answers, and switches between the provider's models.

Changes Ask suggests (archive these, mark read) only happen when tapped.

What keeps answers honest with a small model on the device:

- The facts Ask is given (`MailModel.askFacts`) always carry every heading, with "none" when it's empty ("Mail that needs a reply: none."). A heading left out made the model answer a question about replies with meetings.
- The instructions hold no example names: an example line with a name in it came back in answers as a real person. Names, times and places may only be used as written in the facts or the mail.
- Words of the question itself ("reply", "needs", "mail", "today") aren't searched for in saved mail; "reply" alone found every no-reply sender.
- A conversation is shown under "From your mail" only when the answer speaks of it: one of its people, a telling word of its subject, or a time, date or amount it holds (`MailIntelligence.answer(_:speaksOf:bodies:)`).

Tests: `Tests/MailCoreTests/AnswerSourcesTests.swift`, `Tests/MailUITests/AskFactsTests.swift`.

**What an answer draws on**, numbered so it can cite them: first what Home already knows needs you
(up to four replies owed, two unopened bills, three of today's mails from people), then saved mail
matching the question's words (recent first). Junk, Trash and accounts no longer in Margin are
left out. Message bodies that aren't on the device are fetched all at once. Facts go along too: the
date, the next two weeks of meetings (see [calendar.md](calendar.md)), bills and replies owed, each
marked with its conversation number.

**While it works** the chat says what it's doing ("Searching your mail…", "Reading 6
conversations…"), then the answer appears as it's written: streamed from Claude and
OpenAI-compatible servers, and from Apple Intelligence. The `answer` field is read out of the JSON
as it arrives (`StreamedAnswer`).

**Answers** start with a sentence that answers the question, put three or more things on "- "
lines (shown as bullets with a hanging indent), use bold only for a line's key detail, stay under
about 80 words, and leave out anything the question didn't ask about, spam included.

### Labels

Labels are kept on this device (`labels.json` in Application Support), under the conversation's account and first Message-ID, so they survive moves between folders. IMAP keywords are too uneven across servers to rely on. Suggested labels appear as dashed chips that you add with one click.

## Connections (MCP)

Turn on **Settings → Connections → Let AI apps use Margin**, and Margin runs a [Model Context Protocol](https://modelcontextprotocol.io) server on `127.0.0.1`.

**What apps can do:**

| Always, while on | With "Allow changes" | With "Allow settings changes" | With "Allow sending" |
| --- | --- | --- | --- |
| `list_mailboxes`, `list_folders`, `search_mail`, `read_conversation` (includes any invitation), `read_attachment` (text and PDFs as text; pictures as pictures, with the words in them), `list_labels`, `get_selection` (what you have open or selected), `list_outbox`, `list_templates`, `list_newsletters`, `list_waiting`, `get_settings`, `open_in_margin` (a conversation, view, folder or search), `check_new_mail`, `create_draft` (opens a message in Margin for you to send; can start from a template and carry attachments), `save_draft` (saves to the mailbox's Drafts folder with the signature, so it waits on every device), `list_drafts`, `update_draft` (replaces a draft; the old one goes to Trash), `get_writing_style` (what Margin learned from your sent mail, plus your writing rules), `list_rules`, `preview_rule` (which inbox conversations a rule would match), `list_needs_you` (Home's "Needs you" list), `find_people` (the To field's suggestions) | `archive`, `trash`, `mark_spam`, `move_to_folder`, `set_read`, `set_starred`, `snooze`, `unsnooze`, `add_label`, `remove_label`, `rename_label`, `delete_label`, `stop_waiting`, `unsubscribe`, `archive_newsletter`, `list_spam` (sender and subject only) and `not_spam`, `create_folder`, `rename_folder`, `delete_folder` (empty folders only), `hide_folder`, `save_template`, `update_template`, `delete_template`, `reschedule`, `cancel_scheduled`, `add_to_calendar`, `undo_last`, `delete_draft`, `create_rule`, `update_rule`, `delete_rule` | `change_settings` (appearance and theme, layout, Undo Send, follow-up time, new-mail sound, swipes), `set_signature` | `send_email` (now or at `send_at`, from any send-as address, with Undo Send and the signature), `send_now`, `respond_to_invite` |

Sorting from an AI app: `list_groups` shows Home's groups and what belongs in each; `list_to_sort` returns up to 200 conversations that still need sorting (not in a group, not looked at) with the total left; `skip_sorting` marks ones nothing fits, so the agent repeats list, sort, skip until the total is 0. `search_mail` pages too (`limit` up to 100, `offset`, and `total` and `next_offset` in the answer). `sort_into_group` files conversations into one (it shows on Home straight away, and Margin's own Sort Now skips them); `create_group` adds a group when none fits. Plain labels (`add_label`) don't show on Home, and Margin's instructions to AI apps say so.

Drafting from an AI app: it reads the conversation, calls `get_writing_style`, then `save_draft` (or `update_draft` when asked for changes). Drafts land in the mailbox's real Drafts folder, so they show in Margin on every device and in any other mail app; nothing is sent until you send it (`send_email` is a separate permission).

What needs you and who's who: `list_needs_you` returns Home's "Needs you" list (the conversations with a margin note, all inboxes, not snoozed), each with its id, subject, people, date, unread and the reason: `kind` (reply, meeting, bill, code) and the note Home shows ("reply owed", "owed 3d", "at 14:00"), plus the same one-line summary Home shows under the date (`MailModel.homeSummary`). A sign-in code is only named as a reason; its value never leaves Margin. `find_people` takes 2 or more characters of a name or address and returns up to 20 people (10 by default) from exactly what the To field suggests (`AddressBook.suggestions`, then `MailModel.searchDirectories`: saved mail in every folder including Sent, and work directories), each with `source`: `mail`, `contacts`, `saved_mail` or `directory`. Mailboxes hidden from AI apps are left out of both.

Rules from an AI app: a standing request ("move all build notifications to Updates", "always mark mail from my bank as important") becomes one of Settings → Rules. `create_rule` takes the same parts as the Settings form: `field` (from, to, subject), `contains`, `action` (archive, trash, mark_read, star, label, group, move), a `target` for label, group and move, and an optional `mailbox`. Margin checks them: empty text, an unknown field or mailbox, a group that isn't one of Home's, or a folder no mailbox has are refused with a message naming what to call instead (`list_groups`, `list_folders`, `list_mailboxes`); a `group` rule labels mail with the group's name, so it shows on Home. One action per rule, so "star and label" is two rules; the same rule twice is saved once. The agent calls `preview_rule` first to see what it would match, and `list_rules`, `update_rule` (only what changes) and `delete_rule` manage them by id. Rules act on new mail only, so the answer says how many inbox conversations already match; the agent handles those with the usual tools if asked. Rules for mailboxes hidden from AI apps are never listed or changed. A notice shows in Margin when an agent adds, changes or removes a rule, and `undo_last` puts the rules back.

Change tools take `ids`, a list of up to 100 conversations, so an agent can sort a whole search in one call. If any id isn't found, nothing changes. Labels an agent adds are Margin's own labels: they show on the conversation straight away, and `add_label` reuses an existing label's spelling ("invoices" lands on "Invoices"). `rename_label` and `delete_label` work across every conversation; deleting a label never touches the mail.

**Undo:** `undo_last` puts back the last change made through the connection, never one you made. Margin keeps the last 20 for as long as it's running. Labels, snoozes, read and star, templates, the outbox, waiting for reply, folders, rules and settings are restored from a snapshot. Moves (archive, trash, junk, folders) are undone by finding the messages again by Message-ID in the folder they went to, because IMAP gives moved mail new ids. Sending, unsubscribing and answering invitations can't be undone, and their tools say so.

Junk and Trash are never exposed. Settings shows recent activity, such as "Read a conversation, 2 minutes ago".

**How apps connect:**

- **Codex (and the ChatGPT app on the Mac)** should use STDIO, not HTTP: in Codex's "Add MCP server", choose STDIO with command `/Applications/Margin.app/Contents/MacOS/Margin` and argument `--mcp`, or run `codex mcp add margin -- /Applications/Margin.app/Contents/MacOS/Margin --mcp` and restart the app. No token is needed; the bridge reads it from the Keychain. (Codex's HTTP form only offers OAuth-style client authentication, not a bearer header.) Margin must be in Applications: every install points at `/Applications/Margin.app` when it's there, and warns when it isn't. Margin also answers `resources/list`, `resources/templates/list` and `prompts/list` with empty lists, which Codex asks for on every start.
- **Claude Code** uses the HTTP transport directly. Settings shows the command, for example `claude mcp add --transport http margin http://127.0.0.1:47901/mcp --header "Authorization: Bearer …"`.
- **Claude Desktop, ChatGPT and other apps** start Margin's own binary with `--mcp` (the stdio transport). It reads JSON-RPC from stdin, forwards each message to the running app, and opens Margin in the background if it isn't running.

**Adding Margin in one click (Mac):** Settings → Connections has an "Add Margin to" button for each app below. How each one works:

| App | How Margin adds itself |
| --- | --- |
| Cursor | Opens Cursor's install link (`cursor://anysphere.cursor-deeplink/mcp/install`). |
| VS Code | Opens VS Code's install link (`vscode:mcp/install?…`). |
| LM Studio | Opens LM Studio's install link (`lmstudio://add_mcp`). |
| Claude | Writes `mcpServers.margin` into `~/Library/Application Support/Claude/claude_desktop_config.json`. |
| Windsurf | Writes `mcpServers.margin` into `~/.codeium/windsurf/mcp_config.json`. |
| Gemini CLI | Writes `mcpServers.margin` into `~/.gemini/settings.json`. |
| Codex | Writes a `[mcp_servers.margin]` table into `~/.codex/config.toml`, with `startup_timeout_sec = 30` because Codex gives a server 10 seconds and opening Margin first can take longer. |
| ChatGPT | The ChatGPT app on the Mac runs local MCP servers through Codex, so this writes the same `~/.codex/config.toml` entry. ChatGPT on the web only reaches servers on the internet, which Margin deliberately isn't. |
| Antigravity | Writes `mcpServers.margin` into `~/.gemini/antigravity/mcp_config.json`. |
| Claude Code | Copies the `claude mcp add` command above, to paste in Terminal. |

Margin is sandboxed, so the first time it writes one of these files, macOS asks you to pick the file (it opens at the right place). Every other setting and server in the file is kept. All entries run `Margin --mcp`.

**Security:**

- The server listens on the loopback address only.
- Every request needs the bearer token. It's made once, kept in the Keychain, and can be replaced in Settings.
- Requests with a non-local `Origin` header are refused, which keeps web pages out (DNS rebinding).
- The sandboxed app has the `network.server` entitlement for this alone.

**Code:** `MailCore/MCP/MCPServer.swift` handles JSON-RPC independently of transport. `MCPHTTPServer.swift` is the Streamable HTTP transport. `MailUI/Connections/MailToolbox.swift` defines the tools. `Apps/macOS/MCPBridge.swift` is the stdio bridge.

## Your writing

Settings → Assistant → Your writing. With **Learn how I write** on, Margin reads the emails you
send (on the device, plain text analysis, no model) and keeps your habits in `WritingProfile`:
greetings, sign-offs, typical length, how casual you sound, exclamation marks and emoji, overall
and per person you write to one-to-one. It also reads sentence length (the middle of each email),
paragraphs, whether you write in lower case, formal or informal address where the language has
the choice (je/u, du/Sie, tu/vous, tú/usted; decided per reader, never from how you write to
others: what you've used with them before, else what their latest email uses with you, else the
formal form, as is usual with someone you haven't written to), how your first sentence usually starts, the closing
sentence you keep using ("Laat maar weten als je nog vragen hebt."), and three- and four-word
phrases you use in at least 3 emails and one in ten. Names (a capital inside a sentence),
numbers and addresses never become phrases. Phrases, openers and closers are kept for everyone and
per language, not per person, so the profile stays small (phrases used once fall away past 4,000).

- **What counts as yours.** Quoted mail is cut off in every common form: "On … wrote:" (also
  wrapped onto two lines), Outlook's "From: / Sent:" block in English, Dutch, German and French,
  its line of underscores, "Original Message", and phone signatures ("Sent from Outlook for iOS").
  Before this, Outlook replies counted the quoted company mail as yours, which made emails look
  long and brought in phrases like "contact met ons op". The name under your sign-off is learned
  (`signedNames`) and used instead of a mailbox's display name. Lines like "Thanks!" don't count
  as sentences, there's no paragraph rule (converted HTML has a blank line after every line), and
  length is a ceiling ("usually under N words, a short message gets a short answer"), never a
  target: told "about 196 words", a model padded a two-line answer. Every draft is also told not
  to repeat thanks or enthusiasm or add filler. With a study, the description leads and the
  counted phrases are left out; where the two differ, the description wins.
- **Your voice (a study).** Counting can't hear how someone sounds, so Settings → Your voice has
  **Study My Writing**: the Ask and writing assistant, on a stronger model where it has one
  (`AssistantProvider.studyModel`: Sonnet instead of Haiku, for Claude and Claude Code), reads up
  to 40 recent sent emails per language (the two most written in, at least 5 of 12+ words each),
  cut to fit the model, and writes 8 to 12 points on tone, rhythm, openings and closings, quoted
  phrases, how you ask and say no, and what you never do (`MailIntelligence.studyWriting`). It is
  asked for style only, no names, facts or topics. Only the description is kept
  (`WritingProfile.voices`, with which assistant wrote it and from how many emails), and it goes
  along with every draft after the rules. It runs only when you press the button, since it sends
  those emails to the assistant you chose; **Forget** drops it. Starting over keeps it.

- **Per language.** Each sent email's language is detected on the device (Apple's
  NaturalLanguage), and habits are also kept per language and per language per person. Drafts
  use the language of the conversation (`MailModel.languageOf`) and only that language's
  greetings and sign-offs; a language with too little learned gets your general traits (length,
  emoji), never another language's greeting. The "casual" measure (contractions) only applies to
  English.
- **No sample emails.** Drafts get rules only (greetings, sign-offs, length, tone, punctuation).
  Including real sent emails as examples was tried and dropped: small models copied their content
  into unrelated replies. Every drafting request also says to answer only what the conversation
  says.
- **Punctuation.** Whether you use em or en dashes is learned; if you don't, drafts are told not
  to, and any that slip through (models love them) become commas before you see the draft. The
  same applies to suggested replies and drafts AI apps save over MCP.
- **Your rules** (writing instructions) always come last and win over what was learned.
- **Try it** at the bottom of the page: paste an email, optionally who it's from and what to say,
  and **Write my reply** shows the reply as Margin would write it for you, with a note on which
  language and habits it used and, folded away, exactly what Margin told the assistant. Without a
  sender, the name the email is signed with is used, or no name at all. Nothing is sent or saved.
- When the profile's format changes (`WritingProfile.currentVersion`), an older one starts over
  and is relearned from sent mail at the next launch, keeping the studied voices and the people
  you had Margin forget (`forgotten`, never learned about again).

### Hold Space to dictate on Mac

This is experimental and off until turned on in Settings → Experimental (`holdSpaceDictates`);
while off, Space is only ever a space. When on: in an editable native text field in Margin, hold Space for 350 milliseconds to start
on-device dictation. Release Space to insert the words at the original selection; Escape
cancels. A short press still types a space. Secure fields and modified shortcuts are excluded.
The microphone and speech permissions are requested on first use. If the current language
has no on-device recognizer, Margin shows an explanation rather than sending audio away.
Changing the text, selection or focused field prevents a late result from overwriting it.
This shortcut applies inside Margin; it does not listen for keys in other apps or target
embedded web editors.
