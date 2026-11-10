import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import react from "@vitejs/plugin-react";
import { nitro } from "nitro/vite";
import { defineConfig } from "vite";

// Every page is prerendered to static files in .output/public, which the
// Worker in wrangler.jsonc serves at margin.relevate.app. No server code runs.
export default defineConfig({
	server: {
		port: 3200,
		// The local development domain that forwards here.
		allowedHosts: ["lc.relevate.dev"],
		watch: { ignored: ["**/.output/**"] },
	},
	plugins: [
		tanstackStart(),
		react(),
		nitro({
			preset: "static",
			prerender: {
				crawlLinks: true,
				// A broken internal link fails the build.
				failOnError: true,
				// privacy.html, not privacy/index.html, so /privacy has no redirect.
				autoSubfolderIndex: false,
				routes: ["/", "/404"],
			},
		}),
	],
	resolve: { tsconfigPaths: true },
});
