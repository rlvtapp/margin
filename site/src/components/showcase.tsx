import { useEffect, useState } from "react";

export type ShowcaseView = {
	id: string;
	label: string;
	/** The picture's name in `/images`, without `-light.jpg` or `-dark.jpg`. */
	image: string;
	text: string;
	alt: string;
};

const appViews: ShowcaseView[] = [
	{
		id: "inbox",
		label: "Inbox",
		image: "mac-hero",
		text: "Every mailbox in one list, with the conversation right beside it.",
		alt: "Margin's inbox: every mailbox in one list, with a conversation open",
	},
	{
		id: "home",
		label: "Home",
		image: "mac-home",
		text: "Replies you owe, a bill, a sign-in code and Friday's meeting, each with the reason next to it.",
		alt: "Home in Margin: a short list headed Needs you, with a sign-in code, two replies owed, an invitation and a bill",
	},
	{
		id: "subscriptions",
		label: "Subscriptions",
		image: "mac-subs",
		text: "How many issues of each newsletter you actually opened, and one click to leave the rest.",
		alt: "Subscriptions in Margin: two newsletters, each with how many issues were opened, and an Unsubscribe button",
	},
];

/**
 * The real app, a whole window at a time: pick a screen and it changes. With `cycle`, it moves
 * on by itself every so many seconds until someone picks one (never with Reduce Motion).
 */
export function Showcase({ views = appViews, cycle }: { views?: ShowcaseView[]; cycle?: number }) {
	const [index, setIndex] = useState(0);
	const [paused, setPaused] = useState(!cycle);

	useEffect(() => {
		if (paused || !cycle || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
		const timer = window.setTimeout(() => setIndex((i) => (i + 1) % views.length), cycle * 1000);
		return () => window.clearTimeout(timer);
	}, [index, paused, cycle, views.length]);

	return (
		<div className="showcase">
			<div className="showcase-bar">
				<div className="showcase-tabs" role="tablist">
					{views.map((view, i) => (
						<button
							type="button"
							role="tab"
							aria-selected={i === index}
							key={view.id}
							onClick={() => {
								setIndex(i);
								setPaused(true);
							}}
						>
							{view.label}
							{i === index && !paused && <span className="showcase-progress" style={{ animationDuration: `${cycle}s` }} />}
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
						{(["light", "dark"] as const).map((theme) => (
							<img
								key={theme}
								className={`for-${theme}`}
								src={`/images/${view.image}-${theme}.jpg`}
								srcSet={`/images/${view.image}-${theme}-1600.jpg 1600w, /images/${view.image}-${theme}.jpg 2600w`}
								sizes="(max-width: 1240px) 95vw, 1180px"
								alt={view.alt}
								width={2600}
								height={1608}
								loading="lazy"
							/>
						))}
					</div>
				))}
			</div>
		</div>
	);
}
