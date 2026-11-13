# Website

`site/` is Margin's homepage at **margin.relevate.app**: the home page, the privacy policy, terms
and support. Google and Apple both ask for these addresses when an app is reviewed; Google's
OAuth review checks that the privacy policy carries the Limited Use statement (it's on
`/privacy`, under "Google accounts").

It's a TanStack Start app prerendered to plain HTML. Nothing runs on a server: the Worker in
`site/wrangler.jsonc` only serves the files, and the pages set no cookies and load no analytics.

## Working on it

```bash
cd site
pnpm install
pnpm dev        # http://localhost:3200
pnpm build      # writes .output/public; a broken internal link fails the build
pnpm types:check
```

- Pages are in `site/src/routes/` (`index`, `privacy`, `terms`, `support`, `404`).
- The look: clean and modern, with the play in the pictures. One typeface throughout (the
  system's own on Apple devices, the one the app is set in; Inter elsewhere), big tight
  two-part headings (the second part in the quiet colour, `.dim`), a heading on the left and a
  paragraph on the right (`.block`), thin borders, a near-black dark theme. The tokens (colours,
  corners, the space between sections) are at the top of `src/styles.css`. No serif or
  handwriting faces, no scroll-driven sections, no line down the page.
- The home page's parts are in `site/src/components/`:
  - `hero-scene`: the app on a Mac and an iPhone in front of a backdrop picked at random for
    each visit (`backdrops`: message cards floating up, or rows of people sliding past; `?bg=cards`
    or `?bg=people` asks for one), where a reaction pops up on a card or a picture now and then,
    with `floaters`, cards that bob and lean toward the mouse. (A painted landscape was a third
    backdrop; he dropped it.)
  - `feature-tabs`: a list on the left, a live card on the right, moving on by itself until
    someone picks one: `mini-inbox` (answers J, K, E and S), Home, Meetings, `translate-demo`
    and the assistant's summary.
  - `showcase`: the real app, a whole window at a time, with a row of buttons to pick the screen.
  - `privacy-diagram`: how mail travels, as thin lines on dark paper. Providers on the left with
    their tiles (`provider-icons`: our own drawings in each provider's colour, not their logos),
    square-cornered routes into one spine and a trunk to the devices, light running along them,
    the dashed outline of the mail server that doesn't exist, and the notification relay that
    does (drawn off the mail's route, because that's where it is). The other providers bob
    underneath.
  - `agent-chat`: an AI app answering a question from your mail, as a small, finished-looking
    app window: Margin listed as its connected tool, the question, a "searching your mail" step
    that ticks, the answer typed out, the conversation it came from, and a composer. It plays
    once in view and nothing shifts while it does. (He likes the chat, but an unpolished mock-up
    of one reads as fake.)
  - `connection-switches`: beside it, the real switches from Settings → Connections, to try,
    with a sentence underneath saying what they allow. They start off, as in the app; in view,
    the first turns itself on. Keep the wording in step with `ConnectionsSettingsView.swift`.
  - `bring-your-own`: the AI apps Margin adds itself to (the list in `MCPInstaller.swift`) and
    the models the assistant can run on (`AssistantProvider`), as bobbing chips. Keep both lists
    in step with the app. "Claude subscription" and "ChatGPT subscription" are the Claude Code
    and Codex providers (your own sign-in, no API key); "Claude API" and "ChatGPT API" use a key.
  - "Writes like you" in the "And the rest" grid, and "replies that sound like you" on the
    Assistant tab, are the writing profile (`WritingProfile`): learned on the device from sent
    mail, plus the optional "Study My Writing" description. `/privacy` says what each sends.
  - The FAQ (`questions` in `routes/index.tsx`, native `<details>`), the contact cards (the
    address and X handles in `src/site.ts`, and the GitHub repository), "Why we made it", the
    blue closing panel, and the Relevate logo in the footer (`relevate-logo`).
  Everything stops for people who turn on Reduce Motion.
- Margin is open source: the code is at https://github.com/rlvtapp/margin (`site.source`). The
  home page says so under the hero's buttons, in the FAQ, in a contact card, in "Why we made it"
  and on the closing panel; the shared footer (`components/chrome.tsx`) links it as "Source
  code" on every page, and the support page's Contact section mentions it. Plain links only: no
  GitHub buttons, star counts or anything else that loads from GitHub.
- What the page says about servers has to stay true: mail never passes through one of ours, but
  the notification relay for iPhone and iPad is ours. Say "your mail never passes through a
  server of ours", not "no server".
- The Mac app is a direct download, not on the Mac App Store (it isn't sandboxed; see
  [release.md](release.md)). Until there's a file to link, the hero button, the FAQ and the
  closing panel say "coming soon"; when there is, make the hero button a real download link.
- Light and dark follow the system until someone uses the switch in the header; the choice is
  kept in `localStorage` and applied before the page paints.
- The contact address, source link, publisher and the "last updated" date are in
  `site/src/site.ts`. Change the date whenever the privacy policy or terms change.
- Pictures are in `site/public/images/`. The Mac ones (`mac-hero`, `mac-home`, `mac-calendar`,
  `mac-subs`, each `-light` and `-dark`) are pictures of the real window, taken by the app's
  `-snapshot` mode ([architecture.md](architecture.md)) with `-snapshot-size 1520x940
  -snapshot-no-next-up -snapshot-glass` (Next up stays closed on the pictures): the window
  comes up behind your other windows for a moment and the system's own picture of it is saved,
  so Liquid Glass and the scrolling parts are in it. Launch it in the background so it doesn't
  take over the screen, and keep the pointer off the window's top left (a row under it shows
  its hover buttons):
  `open -g -W -n -a .build/xcode-snapshot/Build/Products/Debug/Margin.app --args -snapshot
  /tmp/mac-home-dark.png -appearance dark -snapshot-size 1520x940 -snapshot-place home
  -snapshot-no-next-up -snapshot-glass`. The hero is `-snapshot-select "Lisbon"`, the others
  `-snapshot-place home`, `calendar` and `subscription`. Then
  `sips -s format jpeg -s formatOptions 80 -Z 2600`. The window isn't the active one, so its
  buttons at the top left are grey. The pictures have square corners; the page rounds them to
  the window's own corners (`.showcase-window`).
  `share.jpg` is the 1200×630 preview card for links, and `apple-touch-icon.png` the home-screen
  icon. The card is dark: the icon, the hero headline and lead, "Open source" with the GitHub
  repository, and the dark hero picture on the right. `.github/social-preview.png` is the same
  card at 1280×640 for the repository's social preview on GitHub. When the hero picture is
  retaken, redo both from it.
- The icon (`site/public/icon.svg`) is the default app icon from `Apps/Shared/AppIcon.icon`.

## Keeping the privacy policy true

The policy describes what the app does. When a change sends anything new off the device (a new
provider interface, a new relay field, a new assistant service), update `/privacy` in the same
change. The relay's own list of what it stores is in `relay/README.md`.

## Publishing

`pnpm run deploy` builds and deploys `site/` with Wrangler (see release.md). The Worker claims the custom domain
`margin.relevate.app` in the `relevate.app` zone.

## Search and sharing

- Each page's `head` calls `seo()` from `src/seo.ts`: title, description (keep it under about
  160 characters), canonical address, robots, Open Graph and X cards with `images/share.jpg`.
  The 404 page passes `hidden: true` so it isn't indexed.
- The root route adds theme colours, the web manifest (`public/site.webmanifest`), PNG icons
  next to `icon.svg`, and the structured data from `structuredData` in `src/seo.ts` (Relevate as
  the organization, the site, and Margin as a free app). Keep that to facts the site states.
- `public/robots.txt` points to `public/sitemap.xml`. Add new pages to the sitemap and update
  each `lastmod` when a page changes.
