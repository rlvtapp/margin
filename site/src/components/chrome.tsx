import { Link } from "@tanstack/react-router";
import { RelevateLogo } from "@/components/relevate-logo";
import { ThemeSwitch } from "@/components/theme-switch";
import { site } from "@/site";

export function Header() {
	return (
		<header className="top">
			<Link to="/" className="brand">
				<img src="/icon.svg" alt="" width={26} height={26} />
				Margin
			</Link>
			<nav className="middle">
				<a href="/#features">Features</a>
				<a href="/#privacy">Privacy</a>
				<a href="/#agents">AI apps</a>
				<a href="/#faq">FAQ</a>
				<Link to="/support">Support</Link>
			</nav>
			<div className="end">
				<ThemeSwitch />
				<span className="pill">Coming soon</span>
			</div>
		</header>
	);
}

export function Footer() {
	return (
		<footer className="bottom">
			<a className="made-by" href={site.publisherURL} aria-label={`Made by ${site.publisher}`}>
				<RelevateLogo height={26} />
			</a>
			<nav>
				<Link to="/privacy">Privacy</Link>
				<Link to="/terms">Terms</Link>
				<Link to="/support">Support</Link>
				<span className="year">© {new Date().getFullYear()}</span>
			</nav>
		</footer>
	);
}

/** A page of plain reading: privacy, terms, support. */
export function Prose({
	title,
	intro,
	updated,
	children,
}: {
	title: string;
	intro?: string;
	updated?: string;
	children: React.ReactNode;
}) {
	return (
		<article className="prose">
			<h1>{title}</h1>
			{updated && <p className="updated">Updated {updated}</p>}
			{intro && <p className="intro">{intro}</p>}
			{children}
		</article>
	);
}
