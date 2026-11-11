# Instant notifications on iPhone and iPad

iOS doesn't let an app keep a mail connection open in the background, so instant notifications
need a push from Apple. Margin gets one without anyone setting anything up and without any server
seeing mail or passwords:

1. The app asks the mail provider itself to report new mail to Margin's relay:
   - **Gmail:** the Gmail API `watch` call (with the account's existing sign-in), naming Margin's
     Pub/Sub topic. Google posts `{emailAddress, historyId}` to the relay.
   - **Microsoft 365 and Outlook.com:** a Microsoft Graph change subscription on the inbox's
     messages, pointing at the relay. Microsoft posts the subscription id and `clientState`.
   - **JMAP (Fastmail and others):** a JMAP `PushSubscription` pointing at the relay. The server
     posts `StateChange` objects.
2. The relay only knows "this subscription belongs to this phone" and sends Apple a push that says
   "new mail" (localized on the phone). It never receives credentials or message content.
3. On the phone, the push shows "New mail" and wakes Margin, which fetches the new mail itself,
   replaces that alert with the real sender and subject (following the person's alert settings),
   or removes it when the mail isn't worth an alert.

Plain IMAP servers (iCloud Mail, Yahoo, most hosts) can't report new mail to anyone, so those
accounts keep iOS background checks.

The relay is optional: **Settings → Notifications → Instant notifications** (iPhone and iPad, shown
only when the build has a relay; on by default). The first-launch welcome explains it too, on its own step with the
same switch. Turning it off (`MailModel.usesPushRelay`):

- ends each Microsoft Graph subscription and stops Gmail's `watch`, where the sign-in still works;
- deletes the phone from the relay (`DELETE /v1/devices/{id}`), which deletes every subscription
  of it there;
- forgets the device id and secret on the phone. Mail is then fetched by background checks.

The last push token iOS gave is kept on the phone, so turning it back on registers again at once.

The phone renews subscriptions on its own (Gmail weekly, Microsoft every few days, JMAP when the
server drops them) whenever Margin runs.

## Relay protocol (v1)

JSON over HTTPS. The relay's address is built into the app (`MarginPushRelayURL` in Info.plist);
an empty value turns instant notifications off for that build.

### Devices

`POST /v1/devices` with `{"token": "<APNs token, hex>", "environment": "production" | "sandbox",
"topic": "<app bundle id>"}` → `201 {"device": "<id>", "secret": "<secret>"}`.

Later calls from the phone send `Authorization: Bearer <secret>`. Registering the same token
again replaces the old device (and its subscriptions move to the new one).

`DELETE /v1/devices/<id>` → `204`, and its subscriptions are gone.

### Subscriptions

`POST /v1/subscriptions` with
`{"kind": "graph" | "gmail" | "jmap", "account": "<opaque id from the phone>",
"address_hash": "<sha256 hex of the lowercased address, gmail only>"}` →
`201 {"id": "<id>", "url": "<hook URL to give the provider>", "client_state": "<secret, graph only>"}`.

`DELETE /v1/subscriptions/<id>` → `204`.

### Hooks (called by providers)

- `POST /v1/hooks/graph/<id>`:
  - with `?validationToken=…` (Microsoft's handshake): answer `200`, `text/plain`, the token as is;
  - otherwise a body `{"value": [{"subscriptionId", "clientState", "changeType", "resource"}]}`:
    every item whose `clientState` matches the subscription's sends a push. `202`.
- `POST /v1/hooks/jmap/<id>`: a `StateChange` (`{"@type": "StateChange", "changed": {…}}`) sends a
  push; a `PushVerification` (`{"@type": "PushVerification", "pushSubscriptionId", "verificationCode"}`)
  sends a background push carrying the code so the phone can finish setting it up. `202`.
- `POST /v1/hooks/gmail?token=<shared secret>`: a Pub/Sub push
  (`{"message": {"data": "<base64 of {\"emailAddress\", \"historyId\"}>"}}`): the address is
  hashed and every gmail subscription with that hash gets a push. Wrong token: `403`. `204`.

### Pushes the relay sends

- New mail (`apns-push-type: alert`, `apns-collapse-id: <subscription id>`; at most one per
  subscription every 10 seconds):
  `{"aps": {"alert": {"title-loc-key": "PUSH_NEW_MAIL_TITLE", "loc-key": "PUSH_NEW_MAIL"},
  "sound": "default", "mutable-content": 1, "content-available": 1, "thread-id": "<account>"},
  "margin": {"account": "<account>", "subscription": "<id>"}}`
- JMAP verification (`apns-push-type: background`, priority 5):
  `{"aps": {"content-available": 1}, "margin": {"subscription": "<id>", "verify": "<code>"}}`

If Apple answers `410 Unregistered`, the device and its subscriptions are deleted.

### What the relay stores

Devices (id, APNs token, environment, topic, a hash of the secret) and subscriptions (id,
device, kind, the phone's opaque account id, the gmail address hash, the graph client state, when
it last pushed). No addresses in plain text, no mail, no credentials. Logs carry no addresses or
tokens.

The relay lives in `relay/` (Rust). See `relay/README.md` to run your own.
