# Margin push relay

A small service that turns "new mail" pings from mail providers into Apple push notifications,
so Margin on iPhone and iPad hears about new mail right away. It never receives mail content or
credentials: providers tell it only that something changed, and the phone fetches the mail itself.

The protocol is described in [`../docs/push.md`](../docs/push.md) ("Relay protocol (v1)").

## What it does

- The phone registers its APNs token (`POST /v1/devices`) and gets a device id and secret.
- For each account that supports push, the phone creates a subscription
  (`POST /v1/subscriptions`) and gets a hook URL to hand to the provider:
  - Microsoft Graph change notifications → `POST /v1/hooks/graph/<id>`
  - JMAP push → `POST /v1/hooks/jmap/<id>`
  - Gmail through Pub/Sub → `POST /v1/hooks/gmail?token=…` (one shared endpoint)
- When a provider calls a hook, the relay sends the phone a "new mail" alert (at most one per
  subscription every 10 seconds). JMAP verification codes go to the phone as a silent push.
- If Apple says a device token is gone (`410`), the device and its subscriptions are deleted.
- `GET /healthz` answers `200`.

## What it stores

One SQLite file with:

- devices: id, APNs token, environment (production or sandbox), app bundle id, and a SHA-256
  hash of the device secret;
- subscriptions: id, device, kind, the phone's opaque account id, the gmail address hash
  (SHA-256 of the lowercased address, computed on the phone), the Graph client state, and the
  time of the last push.

No addresses in plain text, no mail, no credentials. Logs carry only method, path and status.

## Configuration

| Variable           | Required | Meaning                                                                  |
| ------------------ | -------- | ------------------------------------------------------------------------ |
| `PORT`             | no       | Port to listen on. Default `8080`.                                       |
| `DATABASE_PATH`    | yes      | Path of the SQLite file (created if missing).                            |
| `PUBLIC_URL`       | yes      | Public HTTPS address of the relay, used to build hook URLs.              |
| `APNS_KEY_PATH`    | yes\*    | Path of the APNs auth key (`AuthKey_XXXXXXXXXX.p8`).                     |
| `APNS_KEY`         | yes\*    | The key file's contents instead of a path (for hosts with secret vars).  |
| `APNS_KEY_ID`      | yes      | The key's id (the `XXXXXXXXXX` part).                                    |
| `APNS_TEAM_ID`     | yes      | Your Apple developer team id.                                            |
| `GMAIL_PUSH_TOKEN` | yes      | A long random secret that the Pub/Sub push subscription adds as `token`. |
| `RUST_LOG`         | no       | Log filter, default `info`.                                              |

\* One of `APNS_KEY_PATH` or `APNS_KEY`. In `APNS_KEY`, line breaks may be written as `\n`.

The relay stops at startup with a clear message if anything required is missing or the key
can't be used.

## Run locally

```sh
cd relay
export DATABASE_PATH=./relay.sqlite3
export PUBLIC_URL=https://your-tunnel.example
export APNS_KEY_PATH=~/keys/AuthKey_ABC123DEFG.p8
export APNS_KEY_ID=ABC123DEFG
export APNS_TEAM_ID=TEAM123456
export GMAIL_PUSH_TOKEN=$(openssl rand -hex 32)
cargo run
```

Providers have to reach the hooks over public HTTPS, so for real end-to-end testing put the relay
behind a tunnel or a deployed host and set `PUBLIC_URL` to that address. Debug builds of the app
register with `"environment": "sandbox"`, which the relay sends to Apple's sandbox host.

Tests use an in-memory database and a fake push sender:

```sh
cargo test
```

With Docker:

```sh
docker build -t margin-relay .
docker run -p 8080:8080 -v margin-relay-data:/data -v ~/keys:/keys:ro \
  -e PUBLIC_URL=… -e APNS_KEY_PATH=/keys/AuthKey_ABC123DEFG.p8 \
  -e APNS_KEY_ID=… -e APNS_TEAM_ID=… -e GMAIL_PUSH_TOKEN=… margin-relay
```

## Point the app at it

Set `MarginPushRelayURL` in the app's Info.plist (`Apps/Margin-iOS-Info.plist` and
`Apps/Margin-Info.plist`) to the relay's `PUBLIC_URL`, for example `https://push.example.org`.
An empty value turns instant notifications off for that build.

## One-time operator setup

1. **APNs key.** In the Apple developer account, create a key with Apple Push Notifications
   service enabled, download the `.p8` once, and note its key id and your team id. One key works
   for both production and sandbox. Each device registers with its app's bundle id as the topic.
2. **Gmail (Google Cloud Pub/Sub).** In the Google Cloud project whose OAuth client the app uses:
   1. Enable the Gmail API and Pub/Sub API.
   2. Create a topic, for example `projects/<project>/topics/margin-gmail`. The app names this
      topic in its Gmail `watch` call.
   3. Grant `gmail-api-push@system.gserviceaccount.com` the **Pub/Sub Publisher** role on that
      topic, so Gmail may publish to it.
   4. Create a **push** subscription on the topic with the endpoint
      `https://<PUBLIC_URL host>/v1/hooks/gmail?token=<GMAIL_PUSH_TOKEN>`.
3. **Microsoft Graph and JMAP** need no setup on the relay: the phone creates those subscriptions
   itself with the hook URL the relay returns. Graph checks the URL with a validation request,
   which the relay answers.
4. Serve the relay over HTTPS with a persistent volume for `DATABASE_PATH`. `fly.toml` does
   this on Fly.io; the steps are in [`../docs/release.md`](../docs/release.md).
