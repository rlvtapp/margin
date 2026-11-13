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
				or the provider's own interface for Google and Microsoft accounts.
				Recent mail and mail you've opened is kept on your device so it's quick
				and works offline.
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

			<h2 id="google">Google accounts</h2>
			<p>
				This section describes what Google user data Margin accesses when you
				sign in with a Google account, what it does with it, and how it's
				protected.
			</p>
			<h3>Google user data Margin accesses</h3>
			<ul>
				<li>
					<b>Your Gmail messages and settings:</b> the messages in your mailbox
					(senders, recipients, subjects, dates, text and attachments), your
					labels and folders, drafts, and whether a message is read or starred.
					If you use automatic replies, Margin also reads and changes your
					out-of-office setting.
				</li>
				<li>
					<b>Your basic profile:</b> your email address, name and profile
					picture, to label the mailbox in the app.
				</li>
				<li>
					<b>Your contacts</b>, only if you turn that on: names, email
					addresses and pictures of your contacts and of people you've
					mailed.
				</li>
				<li>
					<b>Your calendar</b>, only if you turn that on: when you and the
					people you invite are free or busy, your organisation's meeting
					rooms, and the events Margin creates or answers for you.
				</li>
			</ul>
			<h3>How Margin uses it</h3>
			<p>
				Only to give you the mail app's own features, on your devices: showing
				and searching your mail, sending mail and replies, archiving, moving,
				labelling, marking and deleting messages (including deleting them for
				good when you empty the trash), saving drafts, suggesting addresses as
				you type, sending and answering meeting invitations, and turning your
				automatic reply on or off when you ask. Each of these changes is made
				in your Google account because you did it in Margin.
			</p>
			<p>
				Margin doesn't use Google user data for advertising, doesn't sell it,
				and doesn't use it to develop, improve or train AI or machine-learning
				models. No person at {site.publisher} can read it, because it never
				reaches us.
			</p>
			<h3>Where it's kept and how it's protected</h3>
			<ul>
				<li>
					<b>On your device only.</b> Margin talks straight to Google from
					your device. Your mail, contacts and calendar data are not sent to,
					or stored on, any server of ours.
				</li>
				<li>
					<b>Encrypted on the way.</b> Every connection to Google uses TLS
					encryption.
				</li>
				<li>
					<b>Sign-in kept in the Keychain.</b> You sign in on Google's own
					page; Margin never sees your password. The access token Google
					gives Margin is stored in your device's Keychain, which the system
					encrypts, and is only ever sent to Google.
				</li>
				<li>
					<b>Saved mail in private storage.</b> Mail saved for speed and
					offline use sits in Margin's own sandboxed storage, which other apps
					can't read, and is covered by your disk's encryption (FileVault)
					when that's on.
				</li>
			</ul>
			<h3>Sharing and transfer</h3>
			<p>
				Margin doesn't share Google user data with anyone. There is one case
				where data leaves your Mac for somewhere other than Google, and you
				start it: if you choose an assistant other than the one on your Mac
				and add your own key or sign-in for it, the conversation you ask about
				(or, if you ask it to study your writing, a sample of your sent mail) is
				sent from your Mac to that service when you ask.
			</p>
			<h3>Keeping and deleting</h3>
			<p>
				Saved mail and the sign-in token stay on your device until you remove
				the mailbox or delete the app; either removes them. You can also clear
				saved mail in Margin's settings, and remove Margin's access at any time
				in your Google Account, under Security, Third-party apps and services.
			</p>
			<p>
				Margin's use and transfer to any other app of information received from
				Google APIs will adhere to the{" "}
				<a href="https://developers.google.com/terms/api-services-user-data-policy">
					Google API Services User Data Policy
				</a>
				, including the Limited Use requirements.
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
				addresses and show names and pictures. It can also read contacts from
				your Google or Microsoft account, or from a contacts server you add. A
				person's picture comes only from the address book they're in; Margin
				never looks an address up anywhere else. Contacts stay on your device
				and are never uploaded. Meeting invitations are answered by
				sending standard replies through your own mail account.
			</p>

			<h2>Sync with iCloud</h2>
			<p>
				If you turn on Sync with iCloud, your mailbox settings, templates and
				preferences are stored in Margin's folder in your own iCloud, so your
				other Macs can use them. Your mail itself isn't copied there; it
				stays with your provider. This goes through Apple, not through us, and
				you can turn it off in Margin's settings.
			</p>

			<h2>The assistant</h2>
			<p>
				Summaries, reply drafts and other assistant features run on Apple's
				on-device model by default, so nothing leaves your device. If you choose
				a different assistant in settings, such as a model running on your own
				computer, a hosted service with your own key, or Claude Code or Codex
				signed in to your own Claude or ChatGPT subscription, the mail you ask
				about is sent to that service under its own terms. It only runs when you
				ask.
			</p>
			<p>
				So that drafted replies sound like you, Margin learns how you write
				(your usual greetings, sign-offs, length and tone) from the mail you
				send. It works this out on your device, without a language model, and
				keeps it there; you can turn this off in settings. If you choose "Study
				My Writing", the assistant you picked reads up to 40 of your recent sent
				emails per language, once, and writes a description of your voice; only
				the description is kept. When a hosted service drafts a reply, these
				notes on your style go with the request.
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
				analytics with app developers in your Mac's settings,
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
				Google or Microsoft account at any time. If you have any question, write
				to us.
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
