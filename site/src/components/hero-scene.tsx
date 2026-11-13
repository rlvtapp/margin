import { useEffect, useState } from "react";
import { CardsBackdrop, PeopleBackdrop } from "@/components/backdrops";
import { Floaters } from "@/components/floaters";

type Backdrop = "cards" | "people";

const backdrops: Backdrop[] = ["cards", "people"];

/**
 * The hero: the app on a Mac in front of a backdrop, with a few cards floating in
 * front. Each visit gets one of the two backdrops at random (it's chosen in the browser, so the
 * page is the same for everyone until then); `?bg=cards` or `?bg=people` asks for one.
 */
export function HeroScene() {
	const [backdrop, setBackdrop] = useState<Backdrop | null>(null);
	useEffect(() => {
		const asked = new URLSearchParams(window.location.search).get("bg") as Backdrop | null;
		setBackdrop(asked && backdrops.includes(asked) ? asked : backdrops[Math.floor(Math.random() * backdrops.length)]);
	}, []);

	return (
		<div className="scene">
			{backdrop === "cards" && <CardsBackdrop />}
			{backdrop === "people" && <PeopleBackdrop />}

			<div className="scene-window">
				<img
					className="for-light"
					src="/images/mac-hero-light.jpg"
					alt="Margin on a Mac: every inbox in one list, a conversation open, and the next meeting at the side"
					width={2600}
					height={1608}
				/>
				<img
					className="for-dark"
					src="/images/mac-hero-dark.jpg"
					alt="Margin on a Mac in dark mode: every inbox in one list, a conversation open, and the next meeting at the side"
					width={2600}
					height={1608}
				/>
			</div>

			<Floaters />
		</div>
	);
}
