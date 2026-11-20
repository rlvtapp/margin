import { createFileRoute, Link } from "@tanstack/react-router";
import { seo } from "@/seo";
import { site } from "@/site";
import { AgentChat } from "@/components/agent-chat";
import { ConnectionSwitches } from "@/components/connection-switches";
import { HeroScene } from "@/components/hero-scene";
import { PrivacyDiagram } from "@/components/privacy-diagram";
import { FeatureTabs } from "@/components/feature-tabs";
import { BringYourOwn } from "@/components/bring-your-own";
import { Showcase, type ShowcaseView } from "@/components/showcase";

export const Route = createFileRoute("/")({
	component: Home,
	head: () =>
		seo({
			path: "/",
			title: "Margin: a free, open-source mail and calendar app for Mac",
			description:
				"Margin is a free, open-source mail and calendar app for Mac. It connects straight to Gmail, Outlook, iCloud and any IMAP or JMAP account, so nobody else handles your mail.",
			faq: questions,
		}),
});

const more = [
	{ title: "Writes like you", text: "Margin learns your greetings, sign-offs and tone from the mail you send, so drafted replies sound like you, in every language you write in." },
	{ title: "Undo Send", text: "A ring counts down for up to 30 seconds. Change your mind before it closes." },
	{ title: "Send later", text: "Write now, deliver in the morning." },
	{ title: "Send as", text: "Your other addresses come straight from Gmail and Outlook, each with its own name." },
	{ title: "Your own domain", text: "Type your address and Margin works out who hosts it." },
	{ title: "Offline outbox", text: "No signal? It sends when you're back." },
	{ title: "Drafts as you type", text: "Nothing lost, even if the app quits." },
	{ title: "Put a draft away", text: "Look something up mid-sentence. It waits at the top." },
	{ title: "Waiting for reply", text: "Mail you sent that nobody answered, kept in view." },
	{ title: "Rules and blocking", text: "Mute threads, block senders, sort the rest." },
	{ title: "Sign-in codes", text: "Spotted and ready to copy." },
	{ title: "Trackers blocked", text: "The hidden pictures that report when you open mail are taken out." },
	{ title: "Reactions", text: "See Outlook and Gmail reactions on the message, and react with one tap." },
	{ title: "Chat view", text: "A short back-and-forth reads as bubbles, not a stack of emails." },
	{ title: "Who's who", text: "Click a name for everything you two have sent." },
	{ title: "Contacts that find people", text: "Anyone you've mailed, your contacts and your company directory." },
	{ title: "Ask in search", text: "Type a question, get the answer from your mail." },
	{ title: "Swipes your way", text: "Choose what a two-finger swipe does, to the left and to the right." },
	{ title: "Mailboxes in your order", text: "Drag them where you want them." },
	{ title: "Colored labels", text: "Pick a color for every label and group." },
	{ title: "Hidden from screen sharing", text: "On a call, others see an empty window, not your mail." },
	{ title: "Templates", text: "The replies you write again and again, saved for next time." },
	{ title: "Encrypted backup", text: "Your settings and mailboxes in one protected file, ready for a new Mac." },
	{ title: "View source", text: "Every header and the raw message, when you need to check." },
	{ title: "Every Mac", text: "Your mailboxes and settings on all your Macs, synced through your iCloud." },
];

/** The calendar's own windows: Day, Week and Month, taken by the app's snapshot mode. */
const calendarViews: ShowcaseView[] = [
	{
		id: "day",
		label: "Day",
		image: "mac-cal-day",
		text: "Your day next to your colleagues': who's busy, who's out of office, and when you're all free.",
		alt: "The calendar in Margin, showing a day: your meetings in one column, and three colleagues beside you, one of them out of office until Friday",
	},
	{
		id: "week",
		label: "Week",
		image: "mac-cal-week",
		text: "Drag across empty time to make an event, drag one to move it, press Delete to remove it.",
		alt: "The calendar in Margin, showing a week of meetings, with the calendars of two mailboxes and the Mac's Calendar app listed on the left",
	},
	{
		id: "month",
		label: "Month",
		image: "mac-cal-month",
		text: "The whole month, with your Mac's calendars, birthdays and reminders in it too.",
		alt: "The calendar in Margin, showing a month with meetings, a birthday and an all-day event",
	},
];

/** What the calendar does, plainly. The detail is folded away underneath. */
const calendarFacts: { title: string; text: string; icon: React.ReactNode }[] = [
	{
		title: "Every calendar, one place",
		text: "Your mail accounts' calendars, your Mac's own calendars and your reminders, each in its colour.",
		icon: (
			<>
				<rect x="2.5" y="3.5" width="15" height="14" rx="3" />
				<path d="M2.5 8h15M6.5 2v3M13.5 2v3" />
			</>
		),
	},
	{
		title: "Make, move, delete",
		text: "Drag down empty time for a new event, drag it later, pull its edge to make it longer. Undo puts it back.",
		icon: <path d="M10 2.5v15M2.5 10h15M7.5 5 10 2.5 12.5 5M7.5 15l2.5 2.5 2.5-2.5M5 7.5 2.5 10 5 12.5M15 7.5l2.5 2.5-2.5 2.5" />,
	},
	{
		title: "Compare with colleagues",
		text: "Put their day beside yours to see when they're busy or out of office, and when you're all free.",
		icon: (
			<>
				<circle cx="7.5" cy="7" r="3" />
				<circle cx="14" cy="8" r="2.4" />
				<path d="M2 17c.6-3 2.8-4.6 5.5-4.6S12.4 14 13 17M13.5 12.6c2.3 0 4 1.4 4.5 4" />
			</>
		),
	},
	{
		title: "A call link, built in",
		text: "Invite people and the meeting gets a video call from your account. Join appears when it's time.",
		icon: (
			<>
				<rect x="2.5" y="5.5" width="10.5" height="9" rx="2.5" />
				<path d="m13 9 4.5-2.5v7L13 11" />
			</>
		),
	},
	{
		title: "Suggested times",
		text: "Add people and Margin suggests times when everyone's free, so nobody has to ask.",
		icon: (
			<>
				<circle cx="10" cy="10" r="7.5" />
				<path d="M10 5.5V10l3 2" />
			</>
		),
	},
	{
		title: "Clash warnings",
		text: "An invitation in your mail says what it clashes with, before you answer it.",
		icon: (
			<>
				<path d="M10 2.8 18 16.5H2z" />
				<path d="M10 8v3.6M10 14v.1" />
			</>
		),
	},
];

const questions: { q: string; a: string }[] = [
	{
		q: "Is Margin really free?",
		a: "Yes. There's no paid version, no subscription and no ads. We made it for fun, and it stays free.",
	},
	{
		q: "Does it have a calendar?",
		a: "Yes, a full one: Day, Week and Month, with your mail accounts' calendars, your Mac's calendars and your reminders together. You can make, move and delete events, compare calendars with colleagues and answer invitations, all without leaving Margin.",
	},
	{
		q: "Which mail accounts work?",
		a: "Gmail, Outlook and Microsoft 365, iCloud, Yahoo, Fastmail, Proton, Zoho, GMX, WEB.DE, mailbox.org, Posteo, AOL, and anything else that offers IMAP or JMAP. If you use your own domain, type your address and Margin works out who hosts it.",
	},
	{
		q: "Can I sign in with Google?",
		a: "Yes. While Google reviews Margin's sign-in, Google shows a \"Google hasn't verified this app\" screen first. Choose Advanced, then Go to Margin, and sign in as usual. The screen goes away once Google approves Margin. If you'd rather skip it, choose \"Use an app password instead\" when you add the mailbox.",
	},
	{
		q: "Can you see my mail?",
		a: "No. Margin runs on your device and talks straight to your provider, so your mail never passes through a server of ours.",
	},
	{
		q: "Is Margin open source?",
		a: "Yes. All of Margin's code is on GitHub under the Apache License 2.0, so you can read it, build it yourself and check what it does with your mail.",
	},
	{
		q: "Do I need to make an account?",
		a: "No. You sign in to your mail provider, the same way you would in any mail app. There's nothing to sign up for with us.",
	},
	{
		q: "Does the assistant send my mail somewhere?",
		a: "Only where you choose. With the model on your Mac, nothing leaves it. If you add your own key for a hosted model, the conversation you ask about goes to that provider, straight from your device. You can also turn the assistant off.",
	},
	{
		q: "What do I need to run it?",
		a: "A Mac with macOS 15 or later.",
	},
	{
		q: "How do I install it?",
		a: "Download it from this page: it comes straight from us rather than the Mac App Store. This first version is signed with a free Apple development certificate while our Apple Developer membership is being set up, so the first time, open Margin, then choose Open Anyway in System Settings, under Privacy & Security. After that, Margin updates itself.",
	},
];

/** Every language Margin speaks, each in its own words. */
const languages: [code: string, name: string][] = [
	["en", "English"], ["de", "Deutsch"], ["es", "Español"], ["fr", "Français"], ["it", "Italiano"],
	["nl", "Nederlands"], ["pl", "Polski"], ["pt-BR", "Português (Brasil)"], ["sv", "Svenska"], ["tr", "Türkçe"],
	["hu", "Magyar"], ["ru", "Русский"], ["hi", "हिन्दी"], ["ja", "日本語"], ["ko", "한국어"],
	["zh-Hans", "简体中文"], ["zh-Hant", "繁體中文"],
];

function Home() {
	return (
		<>
			<section className="hero">
				<a className="badge" href="#calendar">
					<span>New</span> A full calendar, next to your mail
				</a>
				<h1>
					Your mail and calendar in one place.{" "}
					<br />
					<span className="dim">Nothing in between.</span>
				</h1>
				<p className="lead">
					Gmail, Outlook, iCloud and any IMAP or JMAP account, beside a full
					calendar, in one fast app for Mac. It talks straight to your provider,
					so nobody else handles your mail. Not even us.
				</p>
				<div className="actions">
					<a className="button" href={site.download}>
						Download for Mac
					</a>
					<a className="button ghost" href="#features">
						See what it does
					</a>
				</div>
				<InstallNote />
				<GmailNote />
				<p className="meta">
					Free and open source, with no account to make.{" "}
					<a href={site.source} rel="noreferrer">
						See the code on GitHub
					</a>
				</p>
			</section>

			<HeroScene />

			<section className="block" id="features">
				<h2>
					Fast.{" "}
					<span className="dim">Made for getting through it.</span>
				</h2>
				<p className="lead">
					Margin is built to empty your inbox quickly, with the keyboard or the
					trackpad, and to keep the few things that need you on top.
				</p>
			</section>
			<FeatureTabs />

			<section className="block" id="calendar">
				<h2>
					Your calendar too.{" "}
					<span className="dim">Right next to your mail.</span>
				</h2>
				<p className="lead">
					Day, Week and Month, with your mail accounts' calendars, your Mac's
					calendars and your reminders together. Make a meeting, move it, see
					when colleagues are free, and answer invitations where they arrive.
				</p>
			</section>
			<Showcase views={calendarViews} cycle={6} />
			<ul className="cal-facts">
				{calendarFacts.map((f) => (
					<li key={f.title}>
						<svg viewBox="0 0 20 20" aria-hidden="true">
							{f.icon}
						</svg>
						<b>{f.title}</b>
						<span>{f.text}</span>
					</li>
				))}
			</ul>
			<div className="faq cal-detail">
				<details>
					<summary>
						How the calendar works, in detail
						<svg viewBox="0 0 16 16" aria-hidden="true">
							<path d="M8 3v10M3 8h10" />
						</svg>
					</summary>
					<ul>
						<li>
							<b>Google and Microsoft 365</b> calendars are read and changed
							through the provider's own interface, straight from your Mac. For
							other mailboxes, Margin shows the invitations in your mail.
						</li>
						<li>
							<b>The Calendar app and Reminders</b> stay off until you choose
							Show in the list of calendars, and macOS asks first. Whatever
							accounts they hold come along, and changes sync through them as
							usual.
						</li>
						<li>
							<b>Comparing calendars</b> needs a Microsoft 365 or Google account,
							and works for people at your organization or who share their
							calendar with you. Out of office comes from Microsoft 365; Google
							only says busy.
						</li>
						<li>
							<b>Suggested times</b> come from Microsoft 365 itself where it can,
							otherwise from everyone's busy times. For people whose calendar
							can't be seen, Margin suggests times you're free.
						</li>
						<li>
							<b>Video calls</b> are made by your account's calendar, with the
							call service it already uses. Your Mac's Calendar app can't add
							one, so Margin offers to move the event to a mailbox's calendar.
						</li>
						<li>
							<b>Answers to invitations</b> go to the organizer as standard
							calendar replies, from the address that was invited. Changes
							reach guests through the calendar itself.
						</li>
						<li>
							All of it is in the <a href={`${site.source}/blob/main/docs/calendar.md`}>calendar's notes on GitHub</a>.
						</li>
					</ul>
				</details>
			</div>

			<section className="block" id="look">
				<h2>
					The real thing.{" "}
					<span className="dim">Have a look around.</span>
				</h2>
				<p className="lead">
					These are the app's own windows, as they look on a Mac. Pick a screen.
				</p>
			</section>
			<Showcase />

			<section className="block" id="privacy">
				<h2>
					Private.{" "}
					<span className="dim">We never see your mail.</span>
				</h2>
				<div>
					<p className="lead">
						Margin runs on your device and talks straight to your provider. Your
						mail never passes through a server of ours, and there are no
						analytics, no tracking and nothing to sign up for.
					</p>
					<Link to="/privacy" className="text-link">
						Read the privacy policy
					</Link>
				</div>
			</section>
			<PrivacyDiagram />

			<section className="block" id="agents">
				<h2>
					Connected.{" "}
					<span className="dim">Your mail in your AI apps.</span>
				</h2>
				<p className="lead">
					Margin has a built-in connection for AI apps on your Mac. They can
					search and read your mail across every account. Changing things and
					sending each need a switch of their own, and it's all off until you
					turn it on.
				</p>
			</section>
			<div className="agents">
				<AgentChat />
				<ConnectionSwitches />
			</div>
			<ul className="facts">
				<li>
					<b>On this Mac only</b>
					<span>The connection never leaves your computer.</span>
				</li>
				<li>
					<b>Read-only to start</b>
					<span>Changing, settings and sending each have their own switch.</span>
				</li>
				<li>
					<b>Every account</b>
					<span>One question searches all your mailboxes at once.</span>
				</li>
				<li>
					<b>Rules from a sentence</b>
					<span>"Archive anything from the parking app": your AI app makes the rule, you see it in Margin.</span>
				</li>
				<li>
					<b>What needs you</b>
					<span>It can ask Margin what's waiting on you today, and who someone is.</span>
				</li>
			</ul>

			<section className="block" id="bring-your-own">
				<h2>
					Bring your own.{" "}
					<span className="dim">Your apps, your model, your subscription.</span>
				</h2>
				<p className="lead">
					Margin doesn't sell you an AI. It works with the ones you already have,
					and with none at all if you'd rather.
				</p>
			</section>
			<BringYourOwn />

			<section className="block" id="more">
				<h2>
					And the rest.{" "}
					<span className="dim">The things you'd miss.</span>
				</h2>
			</section>
			<div className="more">
				{more.map((m) => (
					<div key={m.title}>
						<b>{m.title}</b>
						<span>{m.text}</span>
					</div>
				))}
			</div>

			<section className="block" id="languages">
				<h2>
					Your language.{" "}
					<span className="dim">{languages.length} of them, everywhere in the app.</span>
				</h2>
				<p className="lead">
					Every button, menu and setting is translated, and Margin can use a
					different language from the rest of your device.
				</p>
				<ul className="languages">
					{languages.map(([code, name]) => (
						<li key={code} lang={code}>
							{name}
						</li>
					))}
				</ul>
			</section>

			<section className="block" id="faq">
				<h2>
					Questions.{" "}
					<span className="dim">Straight answers.</span>
				</h2>
			</section>
			<div className="faq">
				{questions.map(({ q, a }) => (
					<details key={q}>
						<summary>
							{q}
							<svg viewBox="0 0 16 16" aria-hidden="true">
								<path d="M8 3v10M3 8h10" />
							</svg>
						</summary>
						<p>{a}</p>
					</details>
				))}
			</div>

			<section className="block" id="contact">
				<h2>
					Say hello.{" "}
					<span className="dim">Or tell us what broke.</span>
				</h2>
				<p className="lead">
					Margin has no analytics, so if something breaks we won't know until you
					tell us. Ideas are welcome too.
				</p>
			</section>
			<div className="contact">
				<a href={`mailto:${site.contactEmail}`}>
					<span>Email</span>
					<b>{site.contactEmail}</b>
				</a>
				{site.x.map(({ handle, who }) => (
					<a key={handle} href={`https://x.com/${handle}`} rel="noreferrer">
						<span>{who} on X</span>
						<b>@{handle}</b>
					</a>
				))}
				<a href={site.source} rel="noreferrer">
					<span>Code and contributions on GitHub</span>
					<b>rlvtapp/margin</b>
				</a>
			</div>

			<section className="why" id="why">
				<p className="why-label">Why we made it</p>
				<blockquote>
					<p>
						Honestly? We were bored, and making a mail app sounded fun. So we
						made one.
					</p>
					<p>
						We're the team behind <a href="https://relevate.app">Relevate</a>.
						Margin is free, because we made it for fun, and it stays that way:
						no paywall, no paid version, no ads. And the{" "}
						<a href={site.source}>code is open</a>, so you don't have to take
						our word for any of it.
					</p>
				</blockquote>
				<p className="why-sign">The Relevate team</p>
			</section>

			<section className="final">
				<img src="/icon.svg" alt="" width={84} height={84} />
				<h2>Your mail and calendar, your way.</h2>
				<p>Free and open source, for Mac.</p>
				<div className="actions">
					<a className="button" href={site.download}>
						Download for Mac
					</a>
				</div>
				<InstallNote />
				<GmailNote />
			</section>
		</>
	);
}

/** The honest note beside every download button, until the app is notarized. */
function InstallNote() {
	return (
		<p className="install-note">
			This first version is signed with a free Apple development certificate
			while our Apple Developer membership is being set up. The first time,
			open it, then choose Open Anyway in System Settings › Privacy &amp;
			Security. After that, Margin updates itself.{" "}
			<Link to="/support" hash="install">
				Step by step
			</Link>
		</p>
	);
}

/** Beside the install note: Google sign-in until Google has reviewed it (docs/google-verification.md). */
function GmailNote() {
	return (
		<p className="install-note">
			Using Gmail? While Google reviews Margin, signing in shows a "Google
			hasn't verified this app" screen. Choose Advanced, then Go to Margin.
			It goes away once Google approves it.
		</p>
	);
}
