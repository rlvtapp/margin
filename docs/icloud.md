# Sync with iCloud

Settings → Backup and Devices → **Sync with iCloud** keeps mailboxes, passwords, settings,
templates and workspaces the same on every Mac, iPhone and iPad signed in to the same Apple
Account. On by default (and offered in the welcome); where iCloud isn't available, a grey note
says why and everything stays on the device. The first launch with sync on moves passwords saved
before into iCloud Keychain.

## How it works

- **Passwords and sign-ins** (mail passwords, OAuth tokens, contact and calendar access, assistant
  keys, CardDAV passwords) become iCloud Keychain items: end-to-end encrypted by Apple. Turning sync
  off moves them back to this device only.
- **Everything else** lives in Margin's own iCloud Drive container, one file each:
  `mailboxes.json` (accounts without secrets), `settings.json`, `templates.json`,
  `workspaces.json`. Apple moves the files; there's no Margin server.
- **Merging:** each device remembers what it last synced, so it knows what changed here. Its
  changes go up with the time they were noticed; everything else comes down. Deleting leaves a
  tombstone for 60 days, so a device that was offline can't bring it back.
- **When:** at launch and about every minute while Margin runs, and with **Sync Now**.
- **Stays on each device:** mail itself (it's on your mail servers), the automatic backup
  schedule, the offline cache, contacts (refetched from their sources), and the sample mailboxes.

Link Another Device still works for moving everything to a device with a different Apple Account.

## Turning it on for your build

iCloud needs a build signed with an Apple developer team and an iCloud container:

1. In Apple Developer, create the container `iCloud.<your bundle id>`.
2. Set `MARGIN_BUNDLE_ID` in `Apps/Config/Margin.xcconfig` and your team in Xcode (Signing & Capabilities).
3. Point the Mac target at `Margin-iCloud.entitlements` and the iPhone and iPad target at
   `Margin-iOS-iCloud.entitlements` (`CODE_SIGN_ENTITLEMENTS`), or add the iCloud capability with
   "iCloud Documents" and the container.
4. Build, open Settings → Backup and Devices, and turn on Sync with iCloud.

Without this, the switch says why it can't sync, and passwords stay on the device.

**Code:** `MailCore/Store/CloudSync.swift` (merge and files), `MailCore/Auth/Credentials.swift`
(`Keychain`, iCloud Keychain), `MailUI/Model/MailModel+Sync.swift`. Tests: `CloudSyncTests`.
