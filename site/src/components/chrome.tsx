import { Link } from "@tanstack/react-router";
import { ThemeSwitch } from "@/components/theme-switch";
import { site } from "@/site";

export function Header() {
	return (
		<header className="top">
			<Link to="/" className="brand">
				<img src="/icon.svg" alt="" width={22} height={22} />
				Margin
			</Link>
			<nav className="middle">
				<a href="/#features">Features</a>
				<a href="/#privacy">Privacy</a>
				<a href="/#agents">AI apps</a>
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
			<span>
				A side project from <a href={site.publisherURL}>{site.publisher}</a> · ©{" "}
				{new Date().getFullYear()}
			</span>
			<nav>
				<Link to="/privacy">Privacy</Link>
				<Link to="/terms">Terms</Link>
				<Link to="/support">Support</Link>
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
