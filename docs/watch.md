# Apple Watch

`Apps/watchOS` is a small SwiftUI watch app, embedded in the iPhone app (target "Margin Watch").

watchOS doesn't let apps open raw network connections such as IMAP (only audio apps may), so
the watch never talks to mail servers. Margin on the iPhone sends the newest 40 inbox
conversations over WatchConnectivity after every check for mail (`WatchBridge.push`), and the
watch sends back what's tapped: Done, Trash, Star, Read, or one of the suggested short replies,
which the iPhone sends from the right address (`WatchBridge.handle`). Taps made while the
iPhone is out of reach are queued and delivered when it wakes.

Sign-in codes show large, right in the inbox row and at the top of the mail.

To try it alone: launch with `-sample-mail` (and `-open-mail 1` to open one mail straight away).
