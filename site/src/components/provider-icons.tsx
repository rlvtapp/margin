/**
 * Small coloured tiles for the mail providers Margin knows by name. They're our own drawings
 * (a letter or a simple shape in the provider's colour), not anyone's logo.
 */
export type ProviderId =
	| "gmail"
	| "outlook"
	| "icloud"
	| "yahoo"
	| "fastmail"
	| "proton"
	| "zoho"
	| "gmx"
	| "webde"
	| "mailbox"
	| "posteo"
	| "aol"
	| "imap";

type Mark = { name: string; bg: string; art: React.ReactNode };

function letters(text: string, fill = "#fff", size = 11) {
	return (
		<text x="14" y="14" textAnchor="middle" dominantBaseline="central" fontSize={size} fontWeight="700" fill={fill} stroke="none" letterSpacing="-0.4">
			{text}
		</text>
	);
}

export const providerMarks: Record<ProviderId, Mark> = {
	gmail: {
		name: "Gmail",
		bg: "#ffffff",
		art: <path d="M7.5 19.5v-10l6.5 5 6.5-5v10" fill="none" stroke="#ea4335" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" />,
	},
	outlook: {
		name: "Outlook",
		bg: "#1273d4",
		art: <ellipse cx="14" cy="14" rx="4.6" ry="5.4" fill="none" stroke="#fff" strokeWidth="2.6" />,
	},
	icloud: {
		name: "iCloud",
		bg: "#eaf3ff",
		art: <path d="M9.6 19.2h9.2a3.5 3.5 0 0 0 .6-6.95 5 5 0 0 0-9.7-1.1 4.05 4.05 0 0 0-.1 8.05z" fill="#3b8cf6" stroke="none" />,
	},
	yahoo: { name: "Yahoo Mail", bg: "#6001d2", art: letters("Y!", "#fff", 13) },
	fastmail: {
		name: "Fastmail",
		bg: "#0d2a5c",
		art: (
			<path d="M7 10.2h14v8.6H7zM7.4 10.8 14 15.6l6.6-4.8" fill="none" stroke="#fff" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
		),
	},
	proton: { name: "Proton Mail", bg: "#6d4aff", art: letters("P", "#fff", 15) },
	zoho: { name: "Zoho Mail", bg: "#e8453c", art: letters("Z", "#fff", 15) },
	gmx: { name: "GMX", bg: "#1c449b", art: letters("GMX", "#fff", 9.5) },
	webde: { name: "WEB.DE", bg: "#ffd800", art: letters("WEB", "#1a1a1a", 9) },
	mailbox: { name: "mailbox.org", bg: "#4aa53a", art: letters("m", "#fff", 16) },
	posteo: { name: "Posteo", bg: "#86b817", art: letters("po", "#fff", 12.5) },
	aol: { name: "AOL Mail", bg: "#101114", art: letters("Aol.", "#fff", 9.5) },
	imap: {
		name: "Any IMAP or JMAP",
		bg: "#dfe5ee",
		art: (
			<g fill="none" stroke="#3d4656" strokeWidth="1.8" strokeLinecap="round">
				<rect x="7" y="7.5" width="14" height="5.4" rx="1.8" />
				<rect x="7" y="15.1" width="14" height="5.4" rx="1.8" />
				<path d="M10 10.2h.01M10 17.8h.01" />
			</g>
		),
	},
};

/** One provider's tile, 28 points across unless told otherwise. */
export function ProviderIcon({ id, size = 28, x, y }: { id: ProviderId; size?: number; x?: number; y?: number }) {
	const mark = providerMarks[id];
	return (
		<svg className="provider-icon" x={x} y={y} width={size} height={size} viewBox="0 0 28 28" aria-hidden="true">
			<rect width="28" height="28" rx="7.5" fill={mark.bg} />
			{mark.art}
		</svg>
	);
}
