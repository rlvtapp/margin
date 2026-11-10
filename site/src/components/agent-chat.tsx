import { useEffect, useRef, useState } from "react";

const steps = [
	{ tool: "search_mail", detail: "“launch plan” · 2 mailboxes" },
	{ tool: "read_conversation", detail: "Launch plan for March · 3 messages" },
];

const answer =
	"Maya moved the launch to the 12th. Sam takes the FAQ page, and she sends the final plan tomorrow morning.";

/** An AI app asking Margin about your mail, played once when it scrolls into view. */
export function AgentChat() {
	const ref = useRef<HTMLDivElement>(null);
	const [stage, setStage] = useState(0);
	const [typed, setTyped] = useState(0);

	useEffect(() => {
		const el = ref.current;
		if (!el) return;
		if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
			setStage(4);
			setTyped(answer.length);
			return;
		}
		const timers: number[] = [];
		const seen = new IntersectionObserver(
			([entry]) => {
				if (!entry.isIntersecting) return;
				seen.disconnect();
				[1, 2, 3].forEach((s, i) => {
					timers.push(window.setTimeout(() => setStage(s), 500 + i * 900));
				});
				timers.push(
					window.setTimeout(() => {
						setStage(4);
						const type = window.setInterval(() => {
							setTyped((t) => {
								if (t >= answer.length) window.clearInterval(type);
								return Math.min(answer.length, t + 2);
							});
						}, 22);
						timers.push(type);
					}, 3300),
				);
			},
			{ threshold: 0.5 },
		);
		seen.observe(el);
		return () => {
			seen.disconnect();
			for (const t of timers) window.clearTimeout(t);
		};
	}, []);

	return (
		<div className="chat" ref={ref}>
			<div className="chat-head">
				<span className="chat-app" />
				Your AI app <span className="chat-tag">Margin · on this Mac</span>
			</div>
			<div className={stage >= 1 ? "bubble shown" : "bubble"}>What did Maya decide about the launch?</div>
			{steps.map((s, i) => (
				<div key={s.tool} className={stage >= i + 2 ? "step shown" : "step"}>
					<span className="tick">✓</span>
					<b>{s.tool}</b>
					<span>{s.detail}</span>
				</div>
			))}
			<p className={stage >= 4 ? "reply shown" : "reply"}>
				{answer.slice(0, typed)}
				{stage >= 4 && typed < answer.length && <span className="caret" />}
			</p>
		</div>
	);
}
