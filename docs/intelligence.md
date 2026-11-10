# Assistant and connections

Margin has two optional ways to use AI. Both are off unless you turn them on, and neither uses a server of ours.

- **The assistant** works inside Margin: it summarizes a conversation, suggests labels and drafts or rewrites a reply. You choose which model does it.
- **Connections** let AI apps you already use (Claude, ChatGPT and others that support MCP) search and read your mail through Margin.

## The assistant

### Where it runs

| Provider | Where mail goes | Needs |
| --- | --- | --- |
| On this Mac | Nowhere: Apple's on-device model (Apple Intelligence) | macOS 26+, Apple Intelligence turned on |
| Ollama, LM Studio | Nowhere: a model running on this computer | The app running, a model downloaded |
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
- `OpenAICompatibleModel` covers ChatGPT, Gemini (Google's OpenAI-compatible endpoint), Grok, Ollama, LM Studio and other servers. It asks for `json_schema` output and falls back to JSON mode, with the schema in the instructions, for servers that don't support schemas.

### Ask

Ask is a chat about your mail, with past chats kept on the device and slash commands (`/catchup`, `/waiting`, `/summarize`, `/reply`, `/cleanup`, `/help`). Beside the question field:

- **Attach** pictures, PDFs or text files. Their text goes along with the question; words in pictures are read on the device (Vision), so this works with every provider.
- **Dictate** the question. Speech is turned into text on the device when it supports that; the microphone is only on while dictating.
- **Model** in the header shows which model answers, and switches between the provider's models.

Changes Ask suggests (archive these, mark read) only happen when tapped.

### Labels

Labels are kept on this device (`labels.json` in Application Support), under the conversation's account and first Message-ID, so they survive moves between folders. IMAP keywords are too uneven across servers to rely on. Suggested labels appear as dashed chips that you add with one click.

## Connections (MCP)

Turn on **Settings → Connections → Let AI apps use Margin**, and Margin runs a [Model Context Protocol](https://modelcontextprotocol.io) server on `127.0.0.1`.

**What apps can do:**

| Always, while on | With "Allow changes" | With "Allow settings changes" | With "Allow sending" |
| --- | --- | --- | --- |
| `list_mailboxes`, `list_folders`, `search_mail`, `read_conversation` (includes any invitation), `read_attachment` (text and PDFs as text; pictures as pictures, with the words in them), `list_labels`, `get_selection` (what you have open or selected), `list_outbox`, `list_templates`, `list_newsletters`, `list_waiting`, `get_settings`, `open_in_margin` (a conversation, view, folder or search), `check_new_mail`, `create_draft` (opens a message in Margin for you to send; can start from a template and carry attachments), `save_draft` (saves to the mailbox's Drafts folder with the signature, so it waits on every device), `list_drafts`, `update_draft` (replaces a draft; the old one goes to Trash), `get_writing_style` (what Margin learned from your sent mail, plus your writing rules) | `archive`, `trash`, `mark_spam`, `move_to_folder`, `set_read`, `set_starred`, `snooze`, `unsnooze`, `add_label`, `remove_label`, `rename_label`, `delete_label`, `stop_waiting`, `unsubscribe`, `archive_newsletter`, `list_spam` (sender and subject only) and `not_spam`, `create_folder`, `rename_folder`, `delete_folder` (empty folders only), `hide_folder`, `save_template`, `update_template`, `delete_template`, `reschedule`, `cancel_scheduled`, `add_to_calendar`, `undo_last`, `delete_draft` | `change_settings` (appearance and theme, layout, Undo Send, follow-up time, new-mail sound, swipes), `set_signature` | `send_email` (now or at `send_at`, from any send-as address, with Undo Send and the signature), `send_now`, `respond_to_invite` |

Sorting from an AI app: `list_groups` shows Home's groups and what belongs in each; `list_to_sort` returns up to 200 conversations that still need sorting (not in a group, not looked at) with the total left; `skip_sorting` marks ones nothing fits, so the agent repeats list, sort, skip until the total is 0. `search_mail` pages too (`limit` up to 100, `offset`, and `total` and `next_offset` in the answer). `sort_into_group` files conversations into one (it shows on Home straight away, and Margin's own Sort Now skips them); `create_group` adds a group when none fits. Plain labels (`add_label`) don't show on Home, and Margin's instructions to AI apps say so.

Drafting from an AI app: it reads the conversation, calls `get_writing_style`, then `save_draft` (or `update_draft` when asked for changes). Drafts land in the mailbox's real Drafts folder, so they show in Margin on every device and in any other mail app; nothing is sent until you send it (`send_email` is a separate permission).

Change tools take `ids`, a list of up to 100 conversations, so an agent can sort a whole search in one call. If any id isn't found, nothing changes. Labels an agent adds are Margin's own labels: they show on the conversation straight away, and `add_label` reuses an existing label's spelling ("invoices" lands on "Invoices"). `rename_label` and `delete_label` work across every conversation; deleting a label never touches the mail.

**Undo:** `undo_last` puts back the last change made through the connection, never one you made. Margin keeps the last 20 for as long as it's running. Labels, snoozes, read and star, templates, the outbox, waiting for reply, folders and settings are restored from a snapshot. Moves (archive, trash, junk, folders) are undone by finding the messages again by Message-ID in the folder they went to, because IMAP gives moved mail new ids. Sending, unsubscribing and answering invitations can't be undone, and their tools say so.

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
and per person you write to one-to-one.

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
- When the profile's format changes, an older one starts over and is relearned from sent mail
  at the next launch.
