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
- The home page's moving parts are in `site/src/components/`: `hero-scene` (the SVG sky with the
  flock of envelopes, day or night with the theme), `floaters` (cards that bob and lean toward the
  mouse), `privacy-diagram` (mail moving straight between providers and the device),
  `feature-tabs` (cards that play through on their own; the first is `mini-inbox`, which answers
  J, K, E and S), and `agent-chat` (an AI app asking Margin a question, played once in view).
  Everything stops for people who turn on Reduce Motion.
- Light and dark follow the system until someone uses the switch in the header; the choice is
  kept in `localStorage` and applied before the page paints.
- The contact address, source link, publisher and the "last updated" date are in
  `site/src/site.ts`. Change the date whenever the privacy policy or terms change.
- Screenshots are in `site/public/images/`: the Mac window and the iPhone, each in a light and a
  dark version; the page shows the pair that matches the theme. `share.jpg` is the 1200×630
  preview card for links, and `apple-touch-icon.png` the home-screen icon. Make new ones with the app's `-snapshot` mode
  ([architecture.md](architecture.md)).
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
