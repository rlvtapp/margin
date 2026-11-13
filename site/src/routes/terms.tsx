import { createFileRoute, Link } from "@tanstack/react-router";
import { Prose } from "@/components/chrome";
import { seo } from "@/seo";
import { site } from "@/site";

export const Route = createFileRoute("/terms")({
	component: Terms,
	head: () =>
		seo({
			path: "/terms",
			title: "Terms of use",
			description:
				"The terms for using Margin, the free, open-source mail app for Mac: it stays free, your accounts stay yours, and what we can and can't promise.",
		}),
});

function Terms() {
	return (
		<Prose title="Terms of use" updated={site.updated}>
			<h2>Margin is free, and stays free</h2>
			<p>
				Margin is free to use, and we'll never make money from the app itself.
				That means:
			</p>
			<ul>
				<li>no paywall: nothing in Margin will ever move behind a payment;</li>
				<li>no paid version, subscription or in-app purchases;</li>
				<li>no ads, and no selling or sharing of your data.</li>
			</ul>
			<p>
				If we ever make something that works with Relevate, the company behind
				Margin, it will most likely be a separate app, so Margin stays just a mail
				app. If it ever does come to Margin, it will be a light option that starts
				turned off: you'd choose it yourself, could stop at any time, and Margin
				would work exactly the same without it. We'll never turn it on for you or
				push you into it.
			</p>

			<h2>Your accounts</h2>
			<p>
				Margin connects to mail, contacts and other accounts that you already
				have. Your use of those accounts stays under your provider's own terms,
				and you're responsible for what you send from them.
			</p>

			<h2>No warranty</h2>
			<p>
				Margin is provided "as is", without warranties of any kind. As far as the
				law allows, {site.publisher} isn't liable for any loss that comes from
				using it, including lost or misdirected mail. Keep backups of mail that
				matters; your provider keeps the originals.
			</p>

			<h2>Privacy</h2>
			<p>
				How Margin handles your data is described in the{" "}
				<Link to="/privacy">privacy policy</Link>.
			</p>

			<h2>Changes and contact</h2>
			<p>
				We may update these terms; the date at the top shows the latest version.
				Questions go to{" "}
				<a href={`mailto:${site.contactEmail}`}>{site.contactEmail}</a>.
			</p>
		</Prose>
	);
}
