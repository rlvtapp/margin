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

A three-step welcome: what Margin is with **Add Your Mailbox…** or **Look Around First** (the sample
mail), then layout, appearance and app icon, then alerts, Contacts suggestions and copying sign-in
codes. It shows once (`hasOnboarded`); Help → Welcome to Margin and Settings → About → Show
Welcome open it again. Code: `MailUI/Views/OnboardingView.swift`.

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
Mac shows it in the Dock while Margin is open, since macOS has no way to change an installed app's
icon. Code: `MailUI/Model/AppIconChoice.swift`.

**Code:** `MailUI/Model/MailModel+Workspaces.swift`, `+Priority.swift`, `+Reminders.swift`,
`+Desk.swift`, `+Writing.swift`; `MailUI/Views/WorkspaceViews.swift`, `SettingsPages.swift`.
Tests: `Tests/MailUITests/DeskFeatureTests.swift`.
