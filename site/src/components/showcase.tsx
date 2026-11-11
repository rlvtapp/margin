import { useState } from "react";

const views = [
	{
		id: "inbox",
		label: "Inbox",
		image: "hero",
		text: "Every mailbox in one list, the conversation beside it, and what's next at the side.",
		alt: "Margin's inbox: every mailbox in one list, a conversation open, and the next meeting at the side",
	},
	{
		id: "home",
		label: "Home",
		image: "home",
		text: "Replies you owe, a bill, a sign-in code and Friday's meeting, each with the reason next to it.",
		alt: "Home in Margin: a short list headed Needs you, with a sign-in code, two replies owed, an invitation and a bill",
	},
	{
		id: "calendar",
		label: "Calendar",
		image: "calendar",
		text: "The month, today's meetings, Yes, Maybe or No, and a Join button when it's a call.",
		alt: "The calendar in Margin: a month, and a list of today's and tomorrow's meetings with Yes, Maybe and No buttons",
	},
	{
		id: "subscriptions",
		label: "Subscriptions",
		image: "subs",
		text: "How many issues of each newsletter you actually opened, and one click to leave the rest.",
		alt: "Subscriptions in Margin: two newsletters, each with how many issues were opened, and an Unsubscribe button",
	},
];

/** The real app, a whole window at a time: pick a screen and it changes. */
export function Showcase() {
	const [index, setIndex] = useState(0);
	return (
		<div className="showcase">
			<div className="showcase-bar">
				<div className="showcase-tabs" role="tablist">
					{views.map((view, i) => (
						<button type="button" role="tab" aria-selected={i === index} key={view.id} onClick={() => setIndex(i)}>
							{view.label}
						</button>
					))}
				</div>
				{/* Every caption keeps its room, so the bar doesn't move as they change. */}
				<p className="showcase-text">
					{views.map((view, i) => (
						<span key={view.id} className={i === index ? "on" : ""} aria-hidden={i !== index}>
							{view.text}
						</span>
					))}
				</p>
			</div>
			<div className="showcase-window" role="tabpanel">
				{views.map((view, i) => (
					<div key={view.id} className={i === index ? "showcase-shot on" : "showcase-shot"} aria-hidden={i !== index}>
						<img className="for-light" src={`/images/mac-${view.image}-light.jpg`} alt={view.alt} width={2600} height={1608} loading="lazy" />
						<img className="for-dark" src={`/images/mac-${view.image}-dark.jpg`} alt={view.alt} width={2600} height={1608} loading="lazy" />
					</div>
				))}
			</div>
		</div>
	);
}
