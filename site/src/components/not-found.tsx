import { Link } from "@tanstack/react-router";

export function NotFound() {
	return (
		<article className="prose">
			<h1>Page not found</h1>
			<p>
				That page doesn't exist. <Link to="/">Go to the home page</Link>.
			</p>
		</article>
	);
}
