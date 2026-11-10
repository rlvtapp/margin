import { useEffect, useRef } from "react";

/**
 * Bits of Margin floating in front of the scene: they bob on their own and lean toward the
 * mouse, nearer ones more. Decorative, so screen readers skip them.
 */
const items: { x: string; y: string; depth: number; tilt: number; speed: number; content: React.ReactNode }[] = [
	{
		x: "2%",
		y: "26%",
		depth: 22,
		tilt: -5,
		speed: 7,
		content: (
			<div className="float-card code">
				<span>
					<small>Sign-in code</small>
					<b>482 913</b>
				</span>
				<em>Copy</em>
			</div>
		),
	},
	{
		x: "60%",
		y: "11%",
		depth: 30,
		tilt: 5,
		speed: 8,
		content: (
			<div className="float-card invite">
				<small>Quarterly planning · Thu 10:00</small>
				<span className="rsvp">
					<i className="yes">Yes</i>
					<i>Maybe</i>
					<i>No</i>
				</span>
			</div>
		),
	},
	{
		x: "6%",
		y: "72%",
		depth: 16,
		tilt: 4,
		speed: 9,
		content: (
			<div className="float-card undo">
				Sending… <em>Undo</em>
			</div>
		),
	},
	{
		x: "56%",
		y: "84%",
		depth: 26,
		tilt: -8,
		speed: 6,
		content: <div className="float-chip">⌘K</div>,
	},
];

export function Floaters() {
	const ref = useRef<HTMLDivElement>(null);

	useEffect(() => {
		const el = ref.current;
		if (!el || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
		let frame = 0;
		function onMove(event: PointerEvent) {
			const x = event.clientX / window.innerWidth - 0.5;
			const y = event.clientY / window.innerHeight - 0.5;
			cancelAnimationFrame(frame);
			frame = requestAnimationFrame(() => {
				el?.style.setProperty("--px", x.toFixed(3));
				el?.style.setProperty("--py", y.toFixed(3));
			});
		}
		window.addEventListener("pointermove", onMove);
		return () => {
			window.removeEventListener("pointermove", onMove);
			cancelAnimationFrame(frame);
		};
	}, []);

	return (
		<div className="floaters" ref={ref} aria-hidden="true">
			{items.map((item, i) => (
				<div
					key={item.x + item.y}
					className="floater"
					style={
						{
							left: item.x,
							top: item.y,
							"--depth": item.depth,
							"--tilt": `${item.tilt}deg`,
							"--speed": `${item.speed}s`,
							"--delay": `${-i * 1.7}s`,
						} as React.CSSProperties
					}
				>
					<div className="bob">{item.content}</div>
				</div>
			))}
		</div>
	);
}
