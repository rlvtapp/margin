import { createFileRoute, Link } from "@tanstack/react-router";
import { Prose } from "@/components/chrome";
import { seo } from "@/seo";
import { site } from "@/site";

export const Route = createFileRoute("/support")({
	component: Support,
	head: () =>
		seo({
			path: "/support",
			title: "Support",
			description:
				"Help with Margin: adding Gmail, Outlook, iCloud and other accounts, app passwords, notifications and more. Write to us and a person will reply.",
		}),
});

function Support() {
	return (
		<Prose
			title="Support"
			intro="Answers to the common questions. If yours isn't here, write to us and a person will reply."
		>
			<h2>Adding a mailbox</h2>
			<p>
				Choose Add Mailbox, type your email address, and Margin finds the right
				settings for most providers. For Google and Microsoft accounts you sign
				in on their own page. For others you enter your password, or an app
				password if your provider asks for one.
			</p>

			<h2 id="gmail">Adding Gmail with an app password</h2>
			<p>
				Google doesn't let mail apps use your normal password. Until Google
				sign-in is available in Margin, use an app password:
			</p>
			<ol>
				<li>
					Turn on 2-Step Verification in your Google Account, under Security, if
					it isn't on already.
				</li>
				<li>
					Open{" "}
					<a href="https://myaccount.google.com/apppasswords">
						myaccount.google.com/apppasswords
					</a>
					, type "Margin" as the name, and choose Create.
				</li>
				<li>
					Copy the 16-letter password Google shows and paste it into Margin as
					your password.
				</li>
			</ol>
			<p>
				If your Gmail is run by your work or school and you don't see app
				passwords, your administrator has turned them off.
			</p>

			<h2>Other providers that need an app password</h2>
			<p>
				iCloud Mail, Yahoo and some others also ask for an app password instead
				of your normal one. Margin tells you when that's the case and links to
				the right page.
			</p>

			<h2>Your data</h2>
			<p>
				Margin doesn't send your mail to us. See the{" "}
				<Link to="/privacy">privacy policy</Link> for the details.
			</p>

			<h2>Contact</h2>
			<p>
				Email <a href={`mailto:${site.contactEmail}`}>{site.contactEmail}</a>,
				for questions and bug reports alike. Or find us on X:{" "}
				{site.x.map(({ handle, who }, n) => (
					<span key={handle}>
						{n > 0 && " and "}
						<a href={`https://x.com/${handle}`} rel="noreferrer">
							@{handle}
						</a>{" "}
						({who})
					</span>
				))}
				. Margin's code is open, on{" "}
				<a href={site.source} rel="noreferrer">
					GitHub
				</a>
				, if you'd like to look or help.
			</p>
		</Prose>
	);
}
