import { useEffect, useState } from "react";

type Theme = "light" | "dark";

/** Runs in <head> before the page paints, so a saved choice never flashes the other theme. */
export const themeScript = `try{var t=localStorage.getItem("theme");if(t==="light"||t==="dark")document.documentElement.dataset.theme=t}catch(e){}`;

function current(): Theme {
	const set = document.documentElement.dataset.theme;
	if (set === "light" || set === "dark") return set;
	return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function ThemeSwitch() {
	const [theme, setTheme] = useState<Theme | null>(null);
	useEffect(() => setTheme(current()), []);

	function flip() {
		const next: Theme = current() === "dark" ? "light" : "dark";
		document.documentElement.dataset.theme = next;
		try {
			localStorage.setItem("theme", next);
		} catch {}
		setTheme(next);
	}

	return (
		<button type="button" className="theme" onClick={flip} aria-label="Switch light or dark">
			<svg viewBox="0 0 20 20" aria-hidden="true">
				{theme === "dark" ? (
					<>
						<circle cx="10" cy="10" r="3.6" />
						<path d="M10 2v2M10 16v2M2 10h2M16 10h2M4.3 4.3l1.4 1.4M14.3 14.3l1.4 1.4M4.3 15.7l1.4-1.4M14.3 5.7l1.4-1.4" />
					</>
				) : (
					<path d="M16 12.5A6.5 6.5 0 0 1 7.5 4a6.5 6.5 0 1 0 8.5 8.5z" />
				)}
			</svg>
		</button>
	);
}
