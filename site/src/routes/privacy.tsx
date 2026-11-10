import { createFileRoute } from "@tanstack/react-router";
import { Prose } from "@/components/chrome";
import { seo } from "@/seo";
import { site } from "@/site";

export const Route = createFileRoute("/privacy")({
	component: Privacy,
	head: () =>
		seo({
			path: "/privacy",
			title: "Privacy policy",
			description:
				"How Margin handles your mail and your data: mail goes straight between your device and your provider, and stays on your devices.",
		}),
});

function Privacy() {
	return (
		<Prose
			title="Privacy policy"
			updated={site.updated}
			intro={`Margin is a mail app that runs on your own devices. It connects straight to your mail provider, and ${site.publisher} never receives your mail, your contacts or your passwords. This page explains exactly what goes where.`}
		>
			<h2>The short version</h2>
			<ul>
				<li>Your mail travels only between your device and your mail provider.</li>
				<li>Passwords and sign-ins are kept in your device's Keychain.</li>
				<li>There's no Margin account, no tracking, no analytics and no ads.</li>
				<li>
					Margin sends no crash or bug reports. If something goes wrong, we only
					find out when you tell us.
				</li>
				<li>We don't sell, share or look at your data, because we never have it.</li>
				<li>
					Margin is free for good: no paywall, no paid version, no ads. Anything
					to do with Relevate would most likely be a separate app, and otherwise
					an option you turn on yourself, never something switched on for you.
				</li>
			</ul>

			<h2>Your mail</h2>
			<p>
				Margin reads and sends mail by connecting directly from your device to
				your mail provider, using the standard IMAP, SMTP and JMAP protocols,
				or the provider's own interface for Google and Microsoft accounts. Mail
				you've opened is kept on your device so it's quick and works offline.
				It's stored in Margin's private storage and removed when you remove the
				mailbox or delete the app.
			</p>
			<p>
				Sorting your inbox into people, updates and newsletters, rules, blocking,
				muting, sign-in code detection and search all happen on your device.
			</p>

			<h2>Passwords and sign-ins</h2>
			<p>
				Passwords, app passwords and sign-in tokens are stored in your device's
				Keychain. If you turn on Sync with iCloud, they're kept in iCloud
				Keychain, which Apple encrypts end to end. When you sign in with Google
				or Microsoft, you sign in on their own page and Margin receives a token
				that only works for your account. We never see it.
			</p>

			<h2>Google accounts</h2>
			<p>
				If you sign in with a Google account, Margin uses Google's interfaces to
				read, organise, send and delete your mail; to read your contacts so it
				can suggest addresses; to list meeting rooms, check when people and
				rooms are free, and create the event when you send a meeting
				invitation; and to turn your out-of-office reply on or off when you ask
				it to. This data is used only
				to show and manage your mail inside Margin on your devices. It isn't
				sent to us, used for advertising, or sold, and no person reads it.
			</p>
			<p>
				Margin's use and transfer to any other app of information received from
				Google APIs will adhere to the{" "}
				<a href="https://developers.google.com/terms/api-services-user-data-policy">
					Google API Services User Data Policy
				</a>
				, including the Limited Use requirements.
			</p>
			<p>
				You can remove Margin's access at any time in your Google Account, under
				Security, Third-party apps and services.
			</p>

			<h2>Microsoft accounts</h2>
			<p>
				If you sign in with a Microsoft account, Margin uses Microsoft's
				interfaces in the same way: for your mail, contacts, meeting rooms and
				automatic replies, only on your devices. You can remove its access in
				your Microsoft account's privacy or app permissions settings.
			</p>

			<h2>Contacts and calendars</h2>
			<p>
				If you allow it, Margin reads the Contacts app on your device to suggest
				addresses and show names. It can also read contacts from your Google or
				Microsoft account, or from a contacts server you add. Contacts stay on
				your device and are never uploaded. Meeting invitations are answered by
				sending standard replies through your own mail account.
			</p>

			<h2>Sync with iCloud</h2>
			<p>
				If you turn on Sync with iCloud, your mailbox settings, templates and
				preferences are stored in Margin's folder in your own iCloud, so your
				other devices can use them. Your mail itself isn't copied there; it
				stays with your provider. This goes through Apple, not through us, and
				you can turn it off in Margin's settings.
			</p>

			<h2>Instant notifications on iPhone and iPad</h2>
			<p>
				iPhones don't let apps stay connected in the background, so for instant
				new-mail alerts Margin uses a small relay that we run. It works like this: your mail
				provider tells the relay that something new arrived, the relay asks
				Apple to wake your phone, and your phone then fetches the mail directly
				from your provider.
			</p>
			<p>The relay stores only:</p>
			<ul>
				<li>your device's push token from Apple and a random ID for your device;</li>
				<li>a random ID for each mailbox, and the setup code your provider needs;</li>
				<li>
					for Gmail, a one-way fingerprint (hash) of your address, so it can tell
					which phone to wake. Google's notice includes your address and a
					change counter; the relay doesn't keep the address itself.
				</li>
			</ul>
			<p>
				It never receives your mail, its subject or sender, or your passwords.
				None of what it does see is written to its logs either: not your email
				address, not your device's push token and not your IP address. A log
				line says only which kind of request came in, the random ID it was for,
				and whether it worked. Records are deleted when you remove the mailbox, when you turn
				notifications off, or when Apple reports the device is gone. Mailboxes
				that can't send these notices, such as most IMAP servers, don't use the
				relay at all.
			</p>
			<p>
				The relay is optional. Turn off Instant notifications in Margin's
				Settings → Notifications and your device is deleted from the relay,
				with everything it held for it. Margin then checks for new mail in the
				background instead, as often as iOS allows.
			</p>

			<h2>The assistant</h2>
			<p>
				Summaries, reply drafts and other assistant features run on Apple's
				on-device model by default, so nothing leaves your device. If you choose
				a different assistant in settings, such as a model running on your own
				computer or a hosted service with your own key, the mail you ask about
				is sent to that service under its own terms. It only runs when you ask.
			</p>

			<h2>Setting up a mailbox</h2>
			<p>
				To find your provider's server settings, Margin may look up your email
				domain (the part after the @) in your provider's own setup file or in a
				public directory of mail servers. Only the domain is sent, never your
				full address.
			</p>
			<p>
				If your address is on your own domain (like you@yourcompany.com), Margin
				fetches that website's icon once, straight from the website, to show as
				the mailbox's picture. It's kept on your device. Nothing is sent to anyone
				else, and addresses at gmail.com, outlook.com and the like are skipped.
			</p>

			<h2>Other connections</h2>
			<p>
				Margin can let AI apps on the same Mac search and read your mail. This
				is off until you turn it on, works only on that Mac, and can't change or
				send anything unless you allow it. Pictures in mail are blocked until you
				allow them, so senders can't tell when you open their message.
			</p>

			<h2>Crashes and bug reports</h2>
			<p>
				Margin has no crash reporter and sends no diagnostics, so we can't see
				when something goes wrong. If you run into a problem, please tell us;
				that's the only way we'll know. You decide what to include.
			</p>
			<p>
				One exception is up to Apple and you: if you've chosen to share
				analytics with app developers in your iPhone, iPad or Mac settings,
				Apple may pass us anonymous crash reports. You can turn that off in
				Privacy &amp; Security → Analytics &amp; Improvements.
			</p>

			<h2>This website</h2>
			<p>
				This website has no cookies, no analytics and no tracking. Like any
				website, our hosting provider handles the requests for these pages and
				may keep standard technical logs for security.
			</p>

			<h2>Children</h2>
			<p>
				Margin isn't directed at children under 13, and we don't knowingly
				collect information from anyone, at any age.
			</p>

			<h2>Your choices</h2>
			<p>
				Everything Margin keeps is on your devices, so removing a mailbox or
				deleting the app removes it. You can also revoke Margin's access in your
				Google or Microsoft account at any time. If you'd like us to delete
				anything from the notification relay, or have any question, write to us.
			</p>

			<h2>Changes</h2>
			<p>
				If we change how Margin handles data, we'll update this page and the
				date at the top before the change ships.
			</p>

			<h2>Contact</h2>
			<p>
				{site.publisher} ·{" "}
				<a href={`mailto:${site.contactEmail}`}>{site.contactEmail}</a>
			</p>
		</Prose>
	);
}
