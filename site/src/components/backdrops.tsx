/**
 * The hero's two backdrops: message cards floating up, and rows of people sliding past. Now
 * and then someone reacts: a small emoji pops up on a card or a picture and goes again.
 */

const reactions = ["👍", "❤️", "🎉", "😆", "😲"];

/**
 * A reaction that pops up on its picture sometimes. Each has its own slow rhythm, so only a few
 * show at once and never in step.
 */
function Reaction({ seed }: { seed: number }) {
	const style = { animationDuration: `${11 + (seed % 7) * 2.3}s`, animationDelay: `${-((seed * 3.7) % 20)}s` };
	return (
		<em className="bg-reaction" style={style}>
			{reactions[seed % reactions.length]}
		</em>
	);
}

const colors = ["#2f78f5", "#18a874", "#7c5cff", "#e04f9a", "#e0a100", "#e2583e", "#3a8fb7"];

/** Little message cards floating up past the app, at different depths and speeds. */
export function CardsBackdrop() {
	const cards = Array.from({ length: 22 }, (_, i) => ({
		left: (i * 37) % 100,
		size: 0.6 + ((i * 7) % 5) * 0.15,
		speed: 16 + ((i * 11) % 14),
		delay: -((i * 13) % 30),
		color: colors[i % colors.length],
		tilt: ((i * 17) % 20) - 10,
	}));
	return (
		<div className="bg-cards" aria-hidden="true">
			{cards.map((c, i) => (
				<div
					// biome-ignore lint/suspicious/noArrayIndexKey: a fixed list
					key={i}
					className="bg-card"
					style={
						{
							left: `${c.left}%`,
							"--size": c.size,
							"--speed": `${c.speed}s`,
							"--delay": `${c.delay}s`,
							"--tilt": `${c.tilt}deg`,
						} as React.CSSProperties
					}
				>
					<i style={{ background: c.color }} />
					<span>
						<b />
						<b />
					</span>
					{i % 3 === 1 && <Reaction seed={i} />}
				</div>
			))}
		</div>
	);
}

const names = "AMNSLKTPJROEHCVBDGFI".split("");

/** Rows of people (letter avatars) sliding past in opposite directions. */
export function PeopleBackdrop() {
	const rows = Array.from({ length: 7 }, (_, r) =>
		Array.from({ length: 24 }, (_, i) => ({ letter: names[(i * 7 + r * 3) % names.length], color: colors[(i + r * 2) % colors.length] })),
	);
	return (
		<div className="bg-people" aria-hidden="true">
			{rows.map((row, r) => (
				<div
					// biome-ignore lint/suspicious/noArrayIndexKey: a fixed list
					key={r}
					className="bg-people-row"
					style={{ animationDuration: `${50 + r * 7}s`, animationDirection: r % 2 ? "reverse" : "normal" }}
				>
					{[...row, ...row].map((p, i) => (
						// biome-ignore lint/suspicious/noArrayIndexKey: a fixed list
						<i key={i} style={{ background: p.color }}>
							{p.letter}
							{(i + r * 2) % 5 === 2 && <Reaction seed={i + r * 5} />}
						</i>
					))}
				</div>
			))}
		</div>
	);
}
