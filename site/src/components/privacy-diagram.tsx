import { ProviderIcon, type ProviderId, providerMarks } from "@/components/provider-icons";

const endpoints: ProviderId[] = ["gmail", "outlook", "icloud", "yahoo", "fastmail", "imap"];
/** The rest Margin sets up by name, shown bobbing under the drawing. */
const others: ProviderId[] = ["proton", "zoho", "gmx", "webde", "mailbox", "posteo", "aol"];

const top = 30;
const gap = 68;
const tile = { x: 56, width: 250, height: 52 };
/** Where every route ends: the device's front door. */
const door = { x: 852, y: top + (endpoints.length - 1) * gap * 0.5 + tile.height / 2 };
const corner = 14;

/**
 * A route with square turns: out of the provider, along to the one spine every route shares,
 * down or up that to the trunk, and along the trunk to the device.
 */
function route(i: number) {
	const y = top + i * gap + tile.height / 2;
	const lane = 560;
	const start = tile.x + tile.width;
	const down = y < door.y ? 1 : -1;
	return [
		`M${start} ${y}`,
		`H${lane - corner}`,
		`Q${lane} ${y} ${lane} ${y + down * corner}`,
		`V${door.y - down * corner}`,
		`Q${lane} ${door.y} ${lane + corner} ${door.y}`,
		`H${door.x}`,
	].join(" ");
}

/**
 * Light running along a route: a faint tail with a bright head. Toward your device it's bright;
 * the other way (mail you send) it's dimmer.
 */
function Beam({ d, duration, delay, outbound }: { d: string; duration: number; delay: number; outbound?: boolean }) {
	const style = { animationDuration: `${duration}s`, animationDelay: `${delay}s` };
	return (
		<g className={outbound ? "bp-beam out" : "bp-beam"}>
			<path d={d} pathLength={1} className="tail" style={style} />
			<path d={d} pathLength={1} className="head" style={style} />
		</g>
	);
}

/**
 * How mail travels, as a drawing on dark paper: each provider on the left, your devices on the
 * right, one thin square-cornered line straight between them with light moving along it, and
 * the dashed outline of the mail server that isn't there. The one thing of ours that does
 * exist, the relay that wakes an iPhone for new mail, is drawn too, off the mail's route.
 */
export function PrivacyDiagram() {
	return (
		<div className="blueprint">
			<NarrowDiagram />
			<svg
				className="bp-wide"
				viewBox="0 0 1120 440"
				role="img"
				aria-label="Mail goes straight from your provider to your devices, with no server of ours in between"
			>
				{/* The server that isn't there. */}
				<g className="bp-ghost">
					<rect x="668" y={door.y + 62} width="184" height="64" rx="12" />
					<text x="760" y={door.y + 90} textAnchor="middle">
						A mail server of ours
					</text>
					<text x="760" y={door.y + 109} textAnchor="middle" className="small">
						there isn't one
					</text>
				</g>

				{/* The relay that wakes an iPhone: ours, and never on the mail's route. */}
				<g className="bp-relay">
					<path d={`M1064 ${door.y + 48}V${door.y + 122}`} />
					<rect x="896" y={door.y + 122} width="196" height="58" rx="12" />
					<text x="994" y={door.y + 146} textAnchor="middle">
						Our notification relay
					</text>
					<text x="994" y={door.y + 164} textAnchor="middle" className="small">
						wakes your iPhone, sees no mail
					</text>
				</g>

				{endpoints.map((id, i) => {
					const y = top + i * gap;
					const d = route(i);
					return (
						<g key={id}>
							<path d={d} className="bp-wire" />
							<Beam d={d} duration={3.4 + (i % 3) * 0.5} delay={-i * 1.3} />
							<Beam d={d} duration={4.8 + (i % 3) * 0.5} delay={-i * 1.3 - 2.6} outbound />
							<rect className="bp-node" x={tile.x} y={y} width={tile.width} height={tile.height} rx="13" />
							<ProviderIcon id={id} x={tile.x + 12} y={y + 12} />
							<text className="bp-name" x={tile.x + 52} y={y + 31.5}>
								{providerMarks[id].name}
							</text>
							<circle className="bp-joint" cx={tile.x + tile.width} cy={y + tile.height / 2} r="3.5" />
						</g>
					);
				})}

				<g className="bp-measure">
					<path d={`M700 ${door.y - 26}v-10M${door.x} ${door.y - 26}v-10M700 ${door.y - 31}H${door.x}`} />
					<text x="776" y={door.y - 44} textAnchor="middle">
						direct and encrypted
					</text>
				</g>

				<g className="bp-device" transform={`translate(0 ${door.y - 224})`}>
					<circle className="bp-joint" cx={door.x} cy="224" r="3.5" />
					<rect x="876" y="158" width="150" height="100" rx="9" />
					<rect x="886" y="168" width="130" height="80" rx="3" className="screen" />
					<path d="M858 270h186" />
					<rect x="1042" y="186" width="44" height="84" rx="9" />
					<path d="M1058 194h12" />
					<text x="972" y="308" textAnchor="middle" className="bp-name">
						Your Mac and iPhone
					</text>
				</g>
			</svg>
			<ul className="bp-others" aria-label="Also set up by name">
				{others.map((id, i) => (
					<li key={id} style={{ animationDelay: `${-i * 0.7}s` }}>
						<ProviderIcon id={id} size={22} />
						{providerMarks[id].name}
					</li>
				))}
			</ul>
		</div>
	);
}

/** The same drawing stacked for phones, where the wide one would be too small to read. */
function NarrowDiagram() {
	return (
		<div className="bp-narrow" aria-hidden="true">
			<ul>
				{endpoints.map((id) => (
					<li key={id}>
						<ProviderIcon id={id} size={22} />
						{providerMarks[id].name}
					</li>
				))}
			</ul>
			<div className="stream">
				<i />
				<i />
				<i />
			</div>
			<div className="device-chip">Your Mac and iPhone</div>
			<p>For instant alerts, a small relay of ours wakes your iPhone. It never sees your mail.</p>
		</div>
	);
}
