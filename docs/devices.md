# Backups and moving to another device

## Backups

Settings → Backup, the same on Mac, iPhone and iPad:

- **Export** a backup (with a password, mail passwords and API keys can be included) and
  **Restore** from one, choosing what to bring back. **Undo Restore** puts everything back as it
  was before the last restore, and removes mailboxes it added.
- **Automatic backups** daily or weekly, keeping the newest 30. On the Mac they can go to any
  folder, or **Use iCloud Drive…** to keep them off the Mac; on iPhone and iPad they're in
  Margin's folder in the Files app. If automatic backups stop working, Margin says so once in a
  notification, and Settings shows why until the next one works.
- **Recovery key:** a second key that also opens password-protected backups, for when the password
  is forgotten. It's kept in the Keychain; write it down or keep it in a password manager.

### Format

A backup is JSON. Encrypted ones hold the contents sealed with AES-GCM under a random key, and
that key sealed once per secret that may open it (the password, and the recovery key when there
is one), each with its own PBKDF2-HMAC-SHA256 salt. See `MailCore/Store/BackupBox.swift`.

## Link another device

Settings → Backup → **Link Another Device…** makes a `.marginlink` file holding the mailboxes with
their passwords, settings, labels, templates and more, locked with a fresh code like `K7QM-3XHP`.
Send the file to the other Mac, iPhone or iPad (AirDrop works), open it there, and type the code.
Nothing already on that device is removed, and the link can be undone with Undo Restore.

**Code:** `MailUI/Model/MailModel+Backup.swift`, `MailUI/Model/MailModel+DeviceLink.swift`,
`MailUI/Views/DeviceLinkSheet.swift`.
