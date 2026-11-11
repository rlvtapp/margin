import { useEffect, useRef, useState } from "react";

type Key = "enabled" | "changes" | "settings" | "sending";

/** The same switches as Margin's Settings → Connections, in the same words. */
const switches: { key: Key; title: string; detail: string }[] = [
	{ key: "enabled", title: "Let AI apps use Margin", detail: "They can search and read your mail, on this Mac only." },
	{ key: "changes", title: "Allow changes", detail: "Label, archive, move, snooze and trash." },
	{ key: "settings", title: "Allow settings changes", detail: "Appearance, layout, Undo Send and signatures." },
	{ key: "sending", title: "Allow sending", detail: "Off means apps can only open a draft for you to send." },
];

type State = Record<Key, boolean>;

/** In one sentence, what AI apps may do with the switches as they are. */
function summary(on: State) {
	if (!on.enabled) return "Right now, AI apps can't reach your mail at all.";
	const parts = ["search and read your mail"];
	if (on.changes) parts.push("label, archive and move it");
	if (on.settings) parts.push("change Margin's settings");
	parts.push(on.sending ? "send mail for you" : "open drafts for you to send");
	const last = parts.pop();
	return `Right now, AI apps can ${parts.join(", ")} and ${last}.`;
}

/**
 * The connection's real switches, to try. They start off, as in the app; when the card scrolls
 * into view the first one turns itself on, and the line under them says what that allows.
 */
export function ConnectionSwitches() {
	const ref = useRef<HTMLDivElement>(null);
	const [on, setOn] = useState<State>({ enabled: false, changes: false, settings: false, sending: false });
	const touched = useRef(false);

	useEffect(() => {
		const el = ref.current;
		if (!el) return;
		if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
			setOn((s) => ({ ...s, enabled: true }));
			return;
		}
		let timer = 0;
		const seen = new IntersectionObserver(
			([entry]) => {
				if (!entry.isIntersecting) return;
				seen.disconnect();
				timer = window.setTimeout(() => {
					if (!touched.current) setOn((s) => ({ ...s, enabled: true }));
				}, 700);
			},
			{ threshold: 0.5 },
		);
		seen.observe(el);
		return () => {
			seen.disconnect();
			window.clearTimeout(timer);
		};
	}, []);

	function flip(key: Key) {
		touched.current = true;
		setOn((s) => ({ ...s, [key]: !s[key] }));
	}

	return (
		<div className="connect" ref={ref}>
			<div className="connect-switches">
				{switches.map(({ key, title, detail }) => {
					const locked = key !== "enabled" && !on.enabled;
					return (
						<label key={key} className={locked ? "locked" : ""}>
							<span>
								<b>{title}</b>
								<small>{detail}</small>
							</span>
							<button
								type="button"
								role="switch"
								aria-checked={on[key] && !locked}
								aria-label={title}
								disabled={locked}
								onClick={() => flip(key)}
							/>
						</label>
					);
				})}
			</div>
			<p className="connect-summary" aria-live="polite">
				{summary(on)}
			</p>
		</div>
	);
}
