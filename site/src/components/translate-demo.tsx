import { useEffect, useRef, useState } from "react";

const lines: [german: string, english: string][] = [
	["Hallo Alex,", "Hi Alex,"],
	[
		"die Wohnung am Fluss ist im Mai frei. Soll ich sie für das zweite Wochenende buchen?",
		"the flat by the river is free in May. Shall I book it for the second weekend?",
	],
	["Viele Grüße, Jonas", "Best wishes, Jonas"],
];

type Phase = "original" | "working" | "translated";

/**
 * A message in German with Margin's own Translate line above it. It translates itself once when
 * it comes into view, a line at a time as the app does, and the button switches back and forth.
 */
export function TranslateDemo({ active }: { active: boolean }) {
	const [phase, setPhase] = useState<Phase>("original");
	const [done, setDone] = useState(0);
	const played = useRef(false);
	const timers = useRef<number[]>([]);

	function clear() {
		for (const t of timers.current) window.clearTimeout(t);
		timers.current = [];
	}

	function translate() {
		clear();
		if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
			setDone(lines.length);
			setPhase("translated");
			return;
		}
		setPhase("working");
		setDone(0);
		lines.forEach((_, i) => {
			timers.current.push(window.setTimeout(() => setDone(i + 1), 500 + i * 420));
		});
		timers.current.push(window.setTimeout(() => setPhase("translated"), 500 + lines.length * 420));
	}

	function toggle() {
		if (phase === "working") return;
		if (phase === "translated") {
			clear();
			setPhase("original");
			setDone(0);
		} else {
			translate();
		}
	}

	useEffect(() => {
		if (!active || played.current) return;
		played.current = true;
		const start = window.setTimeout(translate, 900);
		return () => window.clearTimeout(start);
	}, [active]);

	useEffect(() => clear, []);

	return (
		<div className="card letter">
			<div className="letter-from">
				<span className="avatar" style={{ background: "#3a8fb7" }}>
					JW
				</span>
				<b>Jonas Weber</b>
				<span>to Alex Rivera</span>
			</div>
			<div className="translate-line">
				<svg viewBox="0 0 20 20" aria-hidden="true">
					<path d="M3 5h8M7 3v2M9.5 5c-.6 3-2.8 5.4-6 6.6M5 8c.9 1.6 2.4 2.9 4.4 3.6M10.5 17l3.5-8 3.5 8M11.7 14.4h4.6" />
				</svg>
				<span>{phase === "translated" ? "Translated from German" : "Written in German"}</span>
				<i>·</i>
				<button type="button" onClick={toggle} disabled={phase === "working"}>
					{phase === "working" ? "Translating…" : phase === "translated" ? "Show original" : "Translate"}
				</button>
			</div>
			<div className="letter-body" aria-live="polite">
				{lines.map(([german, english], i) => (
					<p key={german} className={i < done ? "swapped" : ""}>
						{i < done ? english : german}
					</p>
				))}
			</div>
		</div>
	);
}
