import {
	createRootRoute,
	HeadContent,
	Outlet,
	Scripts,
} from "@tanstack/react-router";
import { Footer, Header } from "@/components/chrome";
import { themeScript } from "@/components/theme-switch";
import { structuredData } from "@/seo";
import css from "@/styles.css?url";

export const Route = createRootRoute({
	head: () => ({
		meta: [
			{ charSet: "utf-8" },
			{ name: "viewport", content: "width=device-width, initial-scale=1" },
			// Each page adds its own title, description and share tags (see seo.ts).
			{ name: "color-scheme", content: "light dark" },
			{ name: "theme-color", content: "#ffffff", media: "(prefers-color-scheme: light)" },
			{ name: "theme-color", content: "#0c0f15", media: "(prefers-color-scheme: dark)" },
			{ name: "application-name", content: "Margin" },
			{ name: "apple-mobile-web-app-title", content: "Margin" },
			{ name: "format-detection", content: "telephone=no" },
		],
		scripts: [
			{ children: themeScript },
			{ type: "application/ld+json", children: JSON.stringify(structuredData) },
		],
		links: [
			{ rel: "stylesheet", href: css },
			{ rel: "icon", href: "/favicon.ico?v=margin", sizes: "32x32" },
			{ rel: "icon", href: "/favicon-32.png?v=margin", type: "image/png", sizes: "32x32" },
			{ rel: "icon", href: "/icon.svg?v=margin", type: "image/svg+xml", sizes: "any" },
			{ rel: "apple-touch-icon", href: "/apple-touch-icon.png" },
			{ rel: "manifest", href: "/site.webmanifest" },
		],
	}),
	component: Root,
});

function Root() {
	return (
		<html lang="en" suppressHydrationWarning>
			<head>
				<HeadContent />
			</head>
			<body>
				<Header />
				<main>
					<Outlet />
				</main>
				<Footer />
				<Scripts />
			</body>
		</html>
	);
}
