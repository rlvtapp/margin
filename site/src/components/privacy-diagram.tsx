import { useEffect, useRef } from "react";

const providers = ["Gmail", "Outlook", "iCloud", "Fastmail", "Any IMAP or JMAP"];
const top = 40;
const gap = 64;

/**
 * Mail moving straight between each provider and your device, with the empty space where a
 * company's server would usually sit.
 */
export function PrivacyDiagram() {
	const svg = useRef<SVGSVGElement>(null);
	useEffect(() => {
		if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) svg.current?.pauseAnimations();
	}, []);

	return (
		<>
			<NarrowDiagram />
			<svg ref={svg} className="diagram" viewBox="0 0 1000 380" role="img" aria-label="Mail goes straight from your provider to your device, with no server in between">
			<defs>
				{providers.map((name, i) => {
					const y = top + i * gap + 22;
					return <path key={name} id={`wire-${i}`} d={`M250 ${y} C 470 ${y}, 560 190, 760 190`} />;
				})}
			</defs>

			<g className="empty-server">
				<rect x="430" y="300" width="150" height="56" rx="12" />
				<text x="505" y="324" textAnchor="middle">
					Our servers
				</text>
				<text x="505" y="343" textAnchor="middle" className="small">
					nothing passes here
				</text>
			</g>

			{providers.map((name, i) => {
				const y = top + i * gap;
				return (
					<g key={name}>
						<use href={`#wire-${i}`} className="wire" />
						<rect className="node" x="80" y={y} width="170" height="44" rx="12" />
						<text className="node-label" x="165" y={y + 27} textAnchor="middle">
							{name}
						</text>
						{[0, 1].map((n) => (
							<circle key={n} r="4" className={n === 0 ? "packet" : "packet back"}>
								<animateMotion
									dur={`${2.6 + i * 0.35}s`}
									begin={`${-i * 0.7 - n * 1.3}s`}
									repeatCount="indefinite"
									keyPoints={n === 0 ? "0;1" : "1;0"}
									keyTimes="0;1"
									calcMode="linear"
								>
									<mpath href={`#wire-${i}`} />
								</animateMotion>
							</circle>
						))}
					</g>
				);
			})}

			<g className="device" transform="translate(770 130)">
				<rect x="0" y="0" width="130" height="86" rx="8" />
				<rect x="10" y="10" width="110" height="66" rx="3" className="screen" />
				<path d="M-14 100 H144" />
				<rect x="150" y="34" width="40" height="72" rx="8" />
				<text x="95" y="140" textAnchor="middle" className="node-label">
					Your Mac and iPhone
				</text>
			</g>
		</svg>
		</>
	);
}

/** The same idea stacked for phones, where the wide drawing would be too small to read. */
function NarrowDiagram() {
	return (
		<div className="diagram-narrow" aria-hidden="true">
			<div className="chips">
				{providers.map((name) => (
					<span key={name}>{name}</span>
				))}
			</div>
			<div className="stream">
				<i />
				<i />
				<i />
			</div>
			<div className="device-chip">Your Mac and iPhone</div>
			<p>No server of ours in between.</p>
		</div>
	);
}
