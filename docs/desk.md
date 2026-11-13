# Workspaces, VIPs and everyday tools

The same on Mac, iPhone and iPad unless a line says otherwise.

## Workspaces

Group mailboxes, like Work and Personal (Settings → Workspaces). Each has a name, a colour and
its mailboxes. Pick one from the menu at the top of the sidebar, or with ⌥⌘1…⌥⌘9 on the Mac; the
sidebar, All Inboxes, Home, VIPs and the counts then cover only that workspace. Workspaces you're
not in keep checking mail quietly: no alerts except sign-in codes, and a dot beside them in the
menu when something unread arrives. Deleting the workspace in view goes back to every mailbox.

## Priority

- **Pin to top:** a conversation's … menu or right-click. Pinned conversations come first in
  inbox lists, until unpinned.
- **VIPs:** a conversation's … menu → Add to VIPs. The VIPs mailbox in the sidebar shows their
  mail; Settings → Notifications → **Only VIPs and sign-in codes** keeps alerts to them.

## Follow-ups

- **Remind me if nobody replies:** next to Send, choose tomorrow, 3 days or a week. If nobody the
  message went to has written back on the same subject by then, Margin alerts you; otherwise the
  reminder goes away quietly. Reminders are kept in `reply-reminders.json` on the device.
- **Add to Reminders:** a conversation's … menu makes a reminder in the Reminders app with a
  `margin://message/<id>` link back to it. Needs Reminders permission.

## Reading and privacy

- **Block trackers** (Settings → Reading, on by default): removes the hidden pictures that report
  when you open mail, even when pictures are allowed, and takes tracking parameters out of links.
  The reader says how many were blocked and from whom. Code: `MailCore/MIME/TrackerBlocker.swift`.
- **Hide Margin from screen sharing and recordings** (Mac): Margin's windows are left out of
  screen sharing, screenshots and recordings.
- **Print… and Save as PDF…** in a conversation's … menu.

## Writing

**Instructions for the assistant** (Settings → Writing): rules in your own words ("No exclamation
marks. Sign off with just my first name.") that every draft and suggested reply follows. They come
after what was learned from your sent mail, so they win.

## First launch

A short welcome: what Margin is with **Add Your Mailbox…** or **Look Around First** (the sample
mail); layout, appearance, the color-blind-safe palette and app icon, each one short row of
the Settings picture tiles so the step fits without scrolling (the window style stays in
Settings); alerts, Contacts suggestions, iCloud sync and copying
sign-in codes; **AI, or just mail**, the same switch as Settings → Assistant → Use AI (`usesAI`),
which says what AI brings on this device; on iPhone and iPad (when the build has a push relay) **Instant notifications**,
which says why the relay exists, what it learns and never sees, and has the same switch as
Settings → Notifications (`usesPushRelay`, docs/push.md); then **You're all set** with a summary (AI on or off among it).

Each step has a small moving picture: rows of people, drawn like Margin's avatars (initials on
their colour) with the odd VIP star and assistant sparkle, sliding past the app icon on the
welcome (popping in from the icon with a little spring), a little window (a phone on iPhone) whose
list of unread dots and avatars takes the layout, appearance and palette as you pick them, the alerts each choice would bring, and mail and a "new mail" nudge
travelling to the device. Steps come into focus from the side they lie on; choices give a small
springy press. With Reduce Motion (in Margin or on the device) everything simply appears. On a
phone the main action is a pill under the thumb with Back as a round button beside it. A step
taller than the window fades at the bottom with a small arrow that scrolls down. After adding
a mailbox the welcome stays put and lists the mailboxes added so far, with **Add Another
Mailbox…** and **Continue**, so several can be added in one go. It shows once (`hasOnboarded`); Help → Welcome to
Margin and Settings → About → Show Welcome open it again. Code: `MailUI/Views/OnboardingView.swift`
and `OnboardingScenes.swift`; `-snapshot-onboarding <n>` on the Mac draws each step.

## Settings

Settings is one searchable list of pages, each with a coloured icon: a sidebar on the Mac, a list
on iPhone and iPad. Each page opens with its icon, its name and one plain line about it
(`SettingsHeader`); rows are plain system rows. About shows the app icon and version, and a
"Made by Relevate" link with the Relevate logo (`RelevateLogo`, drawn from the logo file's paths). Search matches page names and what's on them (typing "tracker" finds Reading),
and the first match opens as you type.

**App icon** (Settings → Appearance): Blue (the main icon), Green, Purple, Orange, Pink, Red and
Graphite, each on a light tile or, with **Dark** on, a dark one; plus Pixel (Relevate's pixel grays)
and Space. Each is an Icon Composer file, `Apps/Shared/AppIcon-<Name>[-Dark].icon`, listed in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` for the
Mac and iOS targets. iPhone and iPad switch the Home Screen icon (the system confirms once); the
Mac shows it in the Dock, also after Margin quits (a Dock tile plug-in keeps it there; macOS has no
way to change an installed app's icon, so Finder keeps the main one). Code:
`MailUI/Model/AppIconChoice.swift`; the Dock part is in [app-icon.md](app-icon.md).

**Code:** `MailUI/Model/MailModel+Workspaces.swift`, `+Priority.swift`, `+Reminders.swift`,
`+Desk.swift`, `+Writing.swift`; `MailUI/Views/WorkspaceViews.swift`, `SettingsPages.swift`.
Tests: `Tests/MailUITests/DeskFeatureTests.swift`.
