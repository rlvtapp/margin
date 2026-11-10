import { useEffect, useRef, useState } from "react";

type Row = { id: number; from: string; subject: string; color: string; starred?: boolean };

const start: Row[] = [
	{ id: 1, from: "Maya", subject: "Launch plan for March", color: "#7c5cff" },
	{ id: 2, from: "Kettle", subject: "Your sign-in code is 482 913", color: "#e2583e" },
	{ id: 3, from: "Noor", subject: "Lisbon in May?", color: "#18a874" },
	{ id: 4, from: "Sam", subject: "Quick invoice question", color: "#2f78f5" },
	{ id: 5, from: "Mum", subject: "Sunday lunch", color: "#e0a100" },
	{ id: 6, from: "Lena", subject: "Invitation: Quarterly planning", color: "#e04f9a" },
];

/** Mail that arrives while you watch. */
const incoming: Omit<Row, "id">[] = [
	{ from: "Ines", subject: "Coffee next week?", color: "#6f8f2a" },
	{ from: "Parcel", subject: "Your parcel is out for delivery", color: "#3a8fb7" },
	{ from: "Ava", subject: "Photos from the weekend", color: "#d0587e" },
	{ from: "Bank", subject: "Card payment of €42.10", color: "#8a5cd6" },
	{ from: "Theo", subject: "Dinner on Friday?", color: "#e2583e" },
];

const keys = [
	{ key: "j", label: "J", text: "Next" },
	{ key: "k", label: "K", text: "Previous" },
	{ key: "e", label: "E", text: "Done" },
	{ key: "s", label: "S", text: "Star" },
] as const;

type Key = (typeof keys)[number]["key"];
const most = 6;

/**
 * A tiny inbox that answers the same keys as Margin. It plays itself until someone presses a
 * key, and new mail keeps flying in either way.
 */
export function MiniInbox() {
	const [rows, setRows] = useState(start);
	const [index, setIndex] = useState(0);
	const [pressed, setPressed] = useState<Key | null>(null);
	const [leaving, setLeaving] = useState<number | null>(null);
	const [fresh, setFresh] = useState<number | null>(null);
	const [flying, setFlying] = useState(0);
	const [note, setNote] = useState("Try J, K, E and S");
	const [done, setDone] = useState(0);
	const human = useRef(false);
	const next = useRef({ id: 100, incoming: 0 });
	const state = useRef({ rows, index });
	state.current = { rows, index };

	/** An envelope flies in, then the new mail drops in at the top. */
	function arrive() {
		if (state.current.rows.length >= most) return;
		setFlying((f) => f + 1);
		window.setTimeout(() => {
			const mail = incoming[next.current.incoming++ % incoming.length];
			const row = { ...mail, id: next.current.id++ };
			setRows((all) => [row, ...all].slice(0, most));
			setIndex((i) => (state.current.rows.length === 0 ? 0 : i + 1));
			setFresh(row.id);
			setNote(`New mail from ${row.from}`);
			window.setTimeout(() => setFresh((f) => (f === row.id ? null : f)), 900);
		}, 650);
	}

	function press(key: Key) {
		setPressed(key);
		window.setTimeout(() => setPressed((p) => (p === key ? null : p)), 160);
		const { rows, index } = state.current;
		if (rows.length === 0) return arrive();
		if (key === "j") setIndex(Math.min(rows.length - 1, index + 1));
		if (key === "k") setIndex(Math.max(0, index - 1));
		if (key === "s") {
			const row = rows[index];
			setRows(rows.map((r) => (r.id === row.id ? { ...r, starred: !r.starred } : r)));
			setNote(row.starred ? "Unstarred" : "Starred");
		}
		if (key === "e") {
			const row = rows[index];
			setLeaving(row.id);
			window.setTimeout(() => {
				const left = state.current.rows.filter((r) => r.id !== row.id);
				setRows(left);
				setIndex((i) => Math.min(i, Math.max(0, left.length - 1)));
				if (left.length === 0) setNote("Inbox zero. Lovely.");
				setLeaving(null);
				setDone((d) => d + 1);
			}, 220);
			setNote("Marked done");
		}
	}

	// Real keys, when nobody is typing somewhere else.
	useEffect(() => {
		function onKey(event: KeyboardEvent) {
			if (event.metaKey || event.ctrlKey || event.altKey) return;
			const target = event.target as HTMLElement | null;
			if (target?.closest("input, textarea, [contenteditable]")) return;
			const key = event.key.toLowerCase();
			if (!keys.some((k) => k.key === key)) return;
			human.current = true;
			press(key as Key);
		}
		window.addEventListener("keydown", onKey);
		return () => window.removeEventListener("keydown", onKey);
	}, []);

	// Plays a little script until a person takes over; mail keeps arriving regardless.
	useEffect(() => {
		if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
		const script: (Key | "new")[] = ["j", "s", "j", "e", "new", "k", "e", "j", "new", "e", "k", "s"];
		let step = 0;
		const timer = window.setInterval(() => {
			const action = script[step++ % script.length];
			if (human.current) {
				if (step % 6 === 0) arrive();
				return;
			}
			if (action === "new") arrive();
			else press(action);
		}, 1100);
		return () => window.clearInterval(timer);
	}, []);

	return (
		<div className="mini">
			<div className="mini-window">
				<div className="mini-bar">
					<span className="dots">
						<i />
						<i />
						<i />
					</span>
					<span className="mini-title">Inbox</span>
					<span className="mini-count">{done > 0 ? `${done} done` : `${rows.length} new`}</span>
				</div>
				{flying > 0 && (
					<svg key={flying} className="mini-envelope" viewBox="0 0 36 25" aria-hidden="true">
						<rect width="36" height="25" rx="5" fill="#2f78f5" />
						<path d="M1 1 L18 14 L35 1 Z" fill="#a9ccff" />
					</svg>
				)}
				<ul>
					{rows.map((row, i) => (
						<li
							key={row.id}
							className={[i === index ? "on" : "", leaving === row.id ? "leaving" : "", fresh === row.id ? "fresh" : ""].join(" ")}
							onClick={() => {
								human.current = true;
								setIndex(i);
							}}
						>
							<span className="avatar" style={{ background: row.color }}>
								{row.from[0]}
							</span>
							<span className="from">{row.from}</span>
							<span className="subject">{row.subject}</span>
							<span className={row.starred ? "star on" : "star"}>★</span>
						</li>
					))}
					{rows.length === 0 && <li className="empty">Nothing left. New mail is on its way.</li>}
				</ul>
				<div className="mini-note" aria-live="polite">
					{note}
				</div>
			</div>
			<div className="keys">
				{keys.map((k) => (
					<button
						type="button"
						key={k.key}
						className={pressed === k.key ? "key down" : "key"}
						onClick={() => {
							human.current = true;
							press(k.key);
						}}
					>
						<kbd>{k.label}</kbd>
						<span>{k.text}</span>
					</button>
				))}
			</div>
		</div>
	);
}
