import { useEffect, useState } from "react";
import { MiniInbox } from "@/components/mini-inbox";

type Tab = { id: string; title: string; text: string; card: () => React.ReactNode };

function HomeCard() {
	return (
		<div className="card">
			<h3>Good morning, Alex</h3>
			<p className="card-sub">12 emails came in today</p>
			<div className="nudge">
				<b>Don't forget</b> 1 bill to pay · 1 invitation to answer
			</div>
			<ul className="buckets">
				<li>
					<i style={{ background: "#7c5cff" }} />
					People <span>4</span>
				</li>
				<li>
					<i style={{ background: "#2f78f5" }} />
					Updates <span>6</span>
				</li>
				<li>
					<i style={{ background: "#e0a100" }} />
					Newsletters <span>2</span>
				</li>
			</ul>
		</div>
	);
}

function MeetingCard() {
	const [answer, setAnswer] = useState("Yes");
	return (
		<div className="card">
			<p className="card-sub">Invitation from Lena Fischer</p>
			<h3>Quarterly planning</h3>
			<p className="card-sub">Thursday 10:00 – 11:00 · Room Harbour</p>
			<div className="people">
				{["#7c5cff", "#18a874", "#e0a100", "#e04f9a"].map((c, i) => (
					<i key={c} style={{ background: c }}>
						{"LMSN"[i]}
					</i>
				))}
				<span>4 going</span>
			</div>
			<div className="rsvp big">
				{["Yes", "Maybe", "No"].map((a) => (
					<button type="button" key={a} className={answer === a ? "yes" : ""} onClick={() => setAnswer(a)}>
						{a}
					</button>
				))}
			</div>
		</div>
	);
}

function SummaryCard() {
	const lines = [
		"Lena can't make Thursday at 2",
		"She suggests Friday at 10, or Monday afternoon",
		"Same agenda: launch numbers and hiring",
	];
	return (
		<div className="card">
			<p className="card-sub">Summary · on this Mac</p>
			<h3>Can we move Thursday's review?</h3>
			<ul className="typed">
				{lines.map((line, i) => (
					<li key={line} style={{ animationDelay: `${0.3 + i * 0.6}s` }}>
						{line}
					</li>
				))}
			</ul>
			<div className="suggest">
				<span>Friday at 10 works</span>
				<span>Suggest Monday</span>
			</div>
		</div>
	);
}

const tabs: Tab[] = [
	{
		id: "keys",
		title: "Keyboard first",
		text: "J and K to move, E to mark done, S to star, ⌘K for everything else. Try it on the card.",
		card: () => <MiniInbox />,
	},
	{
		id: "home",
		title: "A calmer Home",
		text: "What needs you today, at the top. People, updates and newsletters sorted on your device.",
		card: () => <HomeCard />,
	},
	{
		id: "meetings",
		title: "Meetings",
		text: "Answer invitations in one click, see who's coming, and book a room.",
		card: () => <MeetingCard />,
	},
	{
		id: "assistant",
		title: "Assistant",
		text: "Summaries and reply drafts from the model on your Mac, or your own key. Only when you ask.",
		card: () => <SummaryCard />,
	},
];

const seconds = 7;

/** Feature list on the left, a live card on the right; it moves on by itself until you choose. */
export function FeatureTabs() {
	const [index, setIndex] = useState(0);
	const [paused, setPaused] = useState(false);

	useEffect(() => {
		if (paused || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
		const timer = window.setTimeout(() => setIndex((i) => (i + 1) % tabs.length), seconds * 1000);
		return () => window.clearTimeout(timer);
	}, [index, paused]);

	const tab = tabs[index];
	return (
		<div className="tabs">
			<div className="tab-list" role="tablist">
				{tabs.map((t, i) => (
					<button
						type="button"
						role="tab"
						aria-selected={i === index}
						key={t.id}
						className="tab"
						onClick={() => {
							setIndex(i);
							setPaused(true);
						}}
					>
						<span className="tab-title">{t.title}</span>
						<span className="tab-text">{t.text}</span>
						{i === index && !paused && <span className="tab-progress" style={{ animationDuration: `${seconds}s` }} />}
					</button>
				))}
			</div>
			<div className="tab-stage" role="tabpanel">
				<div className="tab-card" key={tab.id}>
					{tab.card()}
				</div>
			</div>
		</div>
	);
}
