import { site } from "@/site";

type Page = {
	/** The path, starting with a slash: "/", "/privacy". */
	path: string;
	/** The page's own title; the site name is added after it (not on the homepage). */
	title: string;
	/** One or two sentences, under about 160 characters, for search results and shares. */
	description: string;
	/** Pages that shouldn't be in search results (the 404 page). */
	hidden?: boolean;
};

/**
 * Everything a page tells search engines and link previews: title, description, canonical
 * address, Open Graph and X (Twitter) cards. Each route's `head` returns this.
 */
export function seo({ path, title, description, hidden }: Page) {
	const url = `${site.url}${path}`;
	const fullTitle = path === "/" ? title : `${title} · ${site.name}`;
	const image = `${site.url}/images/share.jpg`;
	const imageAlt = "Margin on a Mac and an iPhone: the inbox and a conversation";
	return {
		meta: [
			{ title: fullTitle },
			{ name: "description", content: description },
			{ name: "robots", content: hidden ? "noindex, follow" : "index, follow, max-image-preview:large" },
			{ property: "og:site_name", content: site.name },
			{ property: "og:type", content: "website" },
			{ property: "og:locale", content: "en_US" },
			{ property: "og:url", content: url },
			{ property: "og:title", content: fullTitle },
			{ property: "og:description", content: description },
			{ property: "og:image", content: image },
			{ property: "og:image:width", content: "1200" },
			{ property: "og:image:height", content: "630" },
			{ property: "og:image:alt", content: imageAlt },
			{ name: "twitter:card", content: "summary_large_image" },
			{ name: "twitter:title", content: fullTitle },
			{ name: "twitter:description", content: description },
			{ name: "twitter:image", content: image },
			{ name: "twitter:image:alt", content: imageAlt },
		],
		links: hidden ? [] : [{ rel: "canonical", href: url }],
	};
}

/**
 * Structured data for search engines: Margin as a free app on Apple's platforms, made by
 * Relevate, and the site itself. Only facts the site states; no ratings or download counts.
 */
export const structuredData = {
	"@context": "https://schema.org",
	"@graph": [
		{
			"@type": "Organization",
			"@id": `${site.publisherURL}/#organization`,
			name: site.publisher,
			url: site.publisherURL,
		},
		{
			"@type": "WebSite",
			"@id": `${site.url}/#website`,
			name: site.name,
			url: site.url,
			inLanguage: "en",
			publisher: { "@id": `${site.publisherURL}/#organization` },
		},
		{
			"@type": "SoftwareApplication",
			"@id": `${site.url}/#app`,
			name: site.name,
			description:
				"A free mail app for Mac, iPhone, iPad and Apple Watch that connects straight to your mail provider, so your mail never passes through anyone else.",
			url: site.url,
			applicationCategory: "CommunicationApplication",
			operatingSystem: "macOS, iOS, iPadOS, watchOS",
			image: `${site.url}/images/share.jpg`,
			screenshot: [`${site.url}/images/margin-light.jpg`, `${site.url}/images/margin-iphone-light.jpg`],
			offers: { "@type": "Offer", price: "0", priceCurrency: "EUR" },
			publisher: { "@id": `${site.publisherURL}/#organization` },
		},
	],
};
