import { createFileRoute, Link } from "@tanstack/react-router";
import { seo } from "@/seo";
import { AgentChat } from "@/components/agent-chat";
import { FeatureTabs } from "@/components/feature-tabs";
import { HeroScene } from "@/components/hero-scene";
import { PrivacyDiagram } from "@/components/privacy-diagram";

export const Route = createFileRoute("/")({
	component: Home,
	head: () =>
		seo({
			path: "/",
			title: "Margin: a free mail app for Mac, iPhone and iPad",
			description:
				"All your mail in one place, nothing in between. Margin connects straight to Gmail, Outlook, iCloud and any IMAP server. Free, with no account to make.",
		}),
});

const more = [
	{ title: "Undo Send", text: "Change your mind for up to 30 seconds." },
	{ title: "Send later", text: "Write now, deliver in the morning." },
	{ title: "Offline outbox", text: "No signal? It sends when you're back." },
	{ title: "Drafts as you type", text: "Nothing lost, even if the app quits." },
	{ title: "Rules and blocking", text: "Mute threads, block senders, sort the rest." },
	{ title: "Sign-in codes", text: "Spotted and ready to copy." },
	{ title: "One-click unsubscribe", text: "Newsletters gone in a click." },
	{ title: "Every device", text: "Mac, iPhone, iPad and Apple Watch, synced through your iCloud." },
];

function Home() {
	return (
		<>
			<section className="hero">
				<a className="badge" href="#agents">
					<span>New</span> AI apps can read and sort your mail through Margin
				</a>
				<h1>
					All your mail in one place.
					<br />
					<span className="dim">Nothing in between.</span>
				</h1>
				<p className="lead">
					Bring Gmail, Outlook, iCloud and any IMAP or JMAP account into one fast
					app for Mac, iPhone and iPad. It talks straight to your provider, and
					it's free.
				</p>
				<div className="actions">
					<span className="button" aria-disabled="true">
						Coming soon to the App Store
					</span>
					<a className="button ghost" href="#features">
						See what it does
					</a>
				</div>
				<p className="meta">Free · Mac, iPhone, iPad and Apple Watch</p>
			</section>

			<HeroScene />

			<section className="split" id="privacy">
				<h2>
					Privacy.
					<br />
					<span className="dim">We never see your mail.</span>
				</h2>
				<div>
					<p>
						Because there's nothing in between. Margin runs on your device and
						talks straight to your provider. No Margin server, no analytics, no
						tracking, not even a sign-up.
					</p>
					<Link to="/privacy" className="arrow">
						Read the privacy policy
					</Link>
				</div>
			</section>
			<PrivacyDiagram />

			<section className="split" id="features">
				<h2>
					Fast.
					<br />
					<span className="dim">Made for getting through it.</span>
				</h2>
				<p>
					Margin is built to empty your inbox quickly, with the keyboard or the
					mouse, and to keep what matters on top.
				</p>
			</section>
			<FeatureTabs />

			<section className="split" id="agents">
				<h2>
					Connections.
					<br />
					<span className="dim">Your mail in your AI apps.</span>
				</h2>
				<p>
					Margin has a built-in connection for AI apps on your Mac. They can
					search and read your mail across every account; changing and sending
					each need your own switch. It's off until you turn it on.
				</p>
			</section>
			<div className="agents">
				<AgentChat />
				<ul className="facts">
					<li>
						<b>On this Mac only</b>
						<span>The connection never leaves your computer.</span>
					</li>
					<li>
						<b>Read-only by default</b>
						<span>Moving, labelling and sending each have their own switch.</span>
					</li>
					<li>
						<b>Every account</b>
						<span>One question searches all your mailboxes at once.</span>
					</li>
				</ul>
			</div>

			<section className="split">
				<h2>
					And the rest.
					<br />
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
						no paywall, no paid version, no ads.
					</p>
				</blockquote>
				<p className="why-sign">The Relevate team</p>
			</section>

			<section className="final">
				<img src="/icon.svg" alt="" width={72} height={72} />
				<h2>Your mail, your way.</h2>
				<p>Free. Coming soon to the App Store.</p>
			</section>
		</>
	);
}
