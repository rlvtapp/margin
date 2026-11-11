import { useEffect, useRef, useState } from "react";

const answer =
	"Maya moved the launch to the 12th. Sam takes the FAQ page, and she sends the final plan tomorrow morning.";

/**
 * An AI app answering a question from your mail through Margin: a small app window with the
 * question, Margin working as its connected tool, the answer typed out, and the conversation
 * it came from. Everything has its room from the start, so nothing shifts as it plays; it
 * plays once when it scrolls into view.
 */
export function AgentChat() {
	const ref = useRef<HTMLDivElement>(null);
	const [searched, setSearched] = useState(false);
	const [typed, setTyped] = useState(0);

	useEffect(() => {
		const el = ref.current;
		if (!el) return;
		if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
			setSearched(true);
			setTyped(answer.length);
			return;
		}
		const timers: number[] = [];
		const seen = new IntersectionObserver(
			([entry]) => {
				if (!entry.isIntersecting) return;
				seen.disconnect();
				timers.push(
					window.setTimeout(() => {
						setSearched(true);
						const type = window.setInterval(() => {
							setTyped((t) => {
								if (t >= answer.length) window.clearInterval(type);
								return Math.min(answer.length, t + 2);
							});
						}, 20);
						timers.push(type);
					}, 1700),
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

	const answered = typed >= answer.length;
	return (
		<div className="chat" ref={ref}>
			<div className="chat-bar">
				<span className="dots">
					<i />
					<i />
					<i />
				</span>
				<b>Your AI app</b>
				<span className="chat-linked">
					<img src="/icon.svg" alt="" width={16} height={16} />
					Margin
					<i />
				</span>
			</div>

			<div className="chat-body">
				<p className="chat-ask">What did Maya decide about the launch?</p>

				<div className={searched ? "chat-tool done" : "chat-tool"}>
					<img src="/icon.svg" alt="" width={18} height={18} />
					<span className="chat-tool-text">
						<b>Searching your mail</b>
						<b>Searched your mail</b>
					</span>
					<small>2 mailboxes</small>
					<svg viewBox="0 0 16 16" aria-hidden="true">
						<circle cx="8" cy="8" r="6" />
						<path d="M5.3 8.2l1.9 1.9 3.6-4" />
					</svg>
				</div>

				<p className="chat-answer">
					{/* The whole answer keeps its room from the start. */}
					<span className="room" aria-hidden="true">
						{answer}
					</span>
					<span className="text">
						{answer.slice(0, typed)}
						{searched && !answered && <span className="caret" />}
					</span>
				</p>

				<div className={answered ? "chat-source shown" : "chat-source"}>
					<span className="avatar" style={{ background: "#7c5cff" }}>
						ML
					</span>
					<span>
						<b>Launch plan for March</b>
						<small>Maya, Alex, 3 messages</small>
					</span>
					<em>Open in Margin</em>
				</div>
			</div>

			<div className="chat-compose">
				<span>Ask about your mail</span>
				<i>
					<svg viewBox="0 0 16 16" aria-hidden="true">
						<path d="M8 12.5v-9M4.2 7.2 8 3.4l3.8 3.8" />
					</svg>
				</i>
			</div>
		</div>
	);
}
