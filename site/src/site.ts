// Details shown across the site. Check these before publishing.
export const site = {
	name: "Margin",
	url: "https://margin.relevate.app",
	/** Where questions, privacy requests and bug reports go. */
	contactEmail: "hello@relevate.app",
	/** Where else to reach us: Relevate, and Kaan, who builds Margin. */
	x: [
		{ handle: "rlvtapp", who: "Relevate" },
		{ handle: "kaanmol_", who: "Kaan, who builds Margin" },
	],
	/** Margin's code, open source under the Apache License 2.0. */
	source: "https://github.com/rlvtapp/margin",
	/**
	 * The Mac app: the disk image in the newest GitHub release. `/download/mac` on this site
	 * redirects there too (worker.js), for links that should never change.
	 */
	download: "https://github.com/rlvtapp/margin/releases/latest/download/Margin.dmg",
	/** The version the download is, for search engines (a version is its release date). */
	version: "2026.11.19",
	/** Who publishes Margin. */
	publisher: "Relevate",
	publisherURL: "https://relevate.app",
	/** Shown at the top of the privacy policy and terms. */
	updated: "19 November 2026",
};
