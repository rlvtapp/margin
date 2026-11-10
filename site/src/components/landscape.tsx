import { useEffect, useRef } from "react";

const W = 1200;
const H = 720;

/** Height of a ridge at x: a few sine waves stacked, so every range has its own skyline. */
function ridgeY(x: number, base: number, height: number, seed: number, rough: number) {
	const t = x / W;
	return (
		base -
		height *
			(0.55 * Math.sin(t * 3.1 + seed) +
				0.3 * Math.sin(t * 7.3 + seed * 2.1) * rough +
				0.15 * Math.sin(t * 17.9 + seed * 3.7) * rough +
				0.6)
	);
}

function ridge(base: number, height: number, seed: number, rough: number) {
	const points: string[] = [];
	for (let x = 0; x <= W; x += 12) points.push(`${x} ${ridgeY(x, base, height, seed, rough).toFixed(1)}`);
	return `M0 ${H} L${points.join(" L")} L${W} ${H} Z`;
}

const front = { base: 590, height: 45, seed: 1.2, rough: 0.5 };

/** A row of pines standing on the front hill. */
function pines() {
	const trees: string[] = [];
	for (let i = 0; i < 80; i++) {
		const x = (i * 173) % W;
		const ground = ridgeY(x, front.base, front.height, front.seed, front.rough) + 4;
		const h = 30 + ((i * 29) % 46);
		const w = h * 0.34;
		trees.push(`M${x} ${(ground - h).toFixed(1)} L${(x + w).toFixed(1)} ${ground.toFixed(1)} L${(x - w).toFixed(1)} ${ground.toFixed(1)} Z`);
	}
	return trees.join(" ");
}

const ranges = [
	{ base: 300, height: 130, seed: 0.3, rough: 0.6, depth: 4 },
	{ base: 360, height: 115, seed: 2.1, rough: 0.8, depth: 8 },
	{ base: 425, height: 100, seed: 4.4, rough: 1, depth: 13 },
	{ base: 495, height: 85, seed: 1.7, rough: 0.9, depth: 19 },
];

const birds = [
	{ y: 110, dur: 26, begin: -4, s: 1 },
	{ y: 135, dur: 26, begin: -5.2, s: 0.8 },
	{ y: 120, dur: 26, begin: -6, s: 0.7 },
	{ y: 170, dur: 34, begin: -20, s: 0.6 },
];

/**
 * The hero's painted landscape: a sky at dusk or in the morning, ranges fading into haze, mist,
 * pines up front, drifting clouds and a few birds. The layers lean with the mouse for depth.
 */
export function Landscape() {
	const root = useRef<SVGSVGElement>(null);

	useEffect(() => {
		const svg = root.current;
		if (!svg) return;
		if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
			svg.pauseAnimations();
			return;
		}
		let frame = 0;
		function onMove(event: PointerEvent) {
			const x = event.clientX / window.innerWidth - 0.5;
			const y = event.clientY / window.innerHeight - 0.5;
			cancelAnimationFrame(frame);
			frame = requestAnimationFrame(() => {
				svg?.style.setProperty("--lx", x.toFixed(3));
				svg?.style.setProperty("--ly", y.toFixed(3));
			});
		}
		window.addEventListener("pointermove", onMove);
		return () => {
			window.removeEventListener("pointermove", onMove);
			cancelAnimationFrame(frame);
		};
	}, []);

	return (
		<svg ref={root} className="landscape" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="xMidYMid slice" aria-hidden="true">
			<defs>
				<linearGradient id="ls-sky" x1="0" y1="0" x2="0" y2="1">
					<stop offset="0" style={{ stopColor: "var(--ls-sky-1)" }} />
					<stop offset="0.45" style={{ stopColor: "var(--ls-sky-2)" }} />
					<stop offset="0.7" style={{ stopColor: "var(--ls-sky-3)" }} />
				</linearGradient>
				<radialGradient id="ls-sun" cx="0.5" cy="0.5" r="0.5">
					<stop offset="0" style={{ stopColor: "var(--ls-sun)" }} />
					<stop offset="0.35" style={{ stopColor: "var(--ls-sun)" }} />
					<stop offset="0.4" style={{ stopColor: "var(--ls-sun)", stopOpacity: 0.35 }} />
					<stop offset="1" style={{ stopColor: "var(--ls-sun)", stopOpacity: 0 }} />
				</radialGradient>
				{ranges.map((r, i) => (
					<linearGradient key={r.seed} id={`ls-range-${i}`} x1="0" y1="0" x2="0" y2="1">
						<stop offset="0" style={{ stopColor: `var(--ls-range-${i})` }} />
						<stop offset="1" style={{ stopColor: `var(--ls-range-${i}-low)` }} />
					</linearGradient>
				))}
				<linearGradient id="ls-mist" x1="0" y1="0" x2="0" y2="1">
					<stop offset="0" style={{ stopColor: "var(--ls-mist)", stopOpacity: 0 }} />
					<stop offset="1" style={{ stopColor: "var(--ls-mist)", stopOpacity: 0.7 }} />
				</linearGradient>
				<filter id="ls-soft">
					<feGaussianBlur stdDeviation="14" />
				</filter>
			</defs>

			<rect width={W} height={H} fill="url(#ls-sky)" />
			<circle cx="560" cy="215" r="190" fill="url(#ls-sun)" className="ls-layer" style={{ "--d": 2 } as React.CSSProperties} />

			<g className="ls-clouds" filter="url(#ls-soft)">
				{[
					{ y: 90, w: 340, dur: 160, begin: -30 },
					{ y: 160, w: 260, dur: 210, begin: -120 },
					{ y: 55, w: 420, dur: 260, begin: -200 },
				].map((c) => (
					<ellipse key={c.y} cy={c.y} rx={c.w / 2} ry="22">
						<animate attributeName="cx" values={`-300;${W + 300}`} dur={`${c.dur}s`} begin={`${c.begin}s`} repeatCount="indefinite" />
					</ellipse>
				))}
			</g>

			{birds.map((b) => (
				<g key={b.y + b.begin} className="ls-bird">
					<path strokeWidth={2 / b.s} transform={`scale(${b.s})`}>
						<animate attributeName="d" values="M-10 0 Q-5 -6 0 0 Q5 -6 10 0;M-10 -4 Q-5 2 0 0 Q5 2 10 -4;M-10 0 Q-5 -6 0 0 Q5 -6 10 0" dur="0.8s" repeatCount="indefinite" />
					</path>
					<animateMotion
						path={`M-40 ${b.y} C 300 ${b.y - 40}, 700 ${b.y + 30}, ${W + 40} ${b.y - 20}`}
						dur={`${b.dur}s`}
						begin={`${b.begin}s`}
						repeatCount="indefinite"
					/>
				</g>
			))}

			{ranges.map((r, i) => (
				<g key={r.seed} className="ls-layer" style={{ "--d": r.depth } as React.CSSProperties}>
					<path d={ridge(r.base, r.height, r.seed, r.rough)} fill={`url(#ls-range-${i})`} />
					<rect x="-40" y={r.base - 10} width={W + 80} height="90" fill="url(#ls-mist)" />
				</g>
			))}

			<g className="ls-layer" style={{ "--d": 26 } as React.CSSProperties}>
				<path d={ridge(front.base, front.height, front.seed, front.rough)} className="ls-front" />
				<path d={pines()} className="ls-front" />
			</g>
		</svg>
	);
}
