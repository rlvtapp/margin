import { useEffect, useState } from "react";
import { CardsBackdrop, PeopleBackdrop } from "@/components/backdrops";
import { Floaters } from "@/components/floaters";
import { Landscape } from "@/components/landscape";

type Backdrop = "landscape" | "cards" | "people";

const backdrops: Backdrop[] = ["landscape", "cards", "people"];

/**
 * The hero: the app on a Mac and an iPhone in front of a backdrop. Each visit gets one of the
 * backdrops at random (it's chosen in the browser, so the page is the same for everyone until
 * then); `?bg=landscape|cards|people` asks for a particular one.
 */
export function HeroScene() {
	const [backdrop, setBackdrop] = useState<Backdrop | null>(null);
	useEffect(() => {
		const asked = new URLSearchParams(window.location.search).get("bg") as Backdrop | null;
		setBackdrop(asked && backdrops.includes(asked) ? asked : backdrops[Math.floor(Math.random() * backdrops.length)]);
	}, []);

	return (
		<div className={`scene scene-${backdrop ?? "none"}`}>
			{backdrop === "landscape" && <Landscape />}
			{backdrop === "cards" && <CardsBackdrop />}
			{backdrop === "people" && <PeopleBackdrop />}

			<div className="scene-window">
				<img
					className="for-light"
					src="/images/margin-light.jpg"
					alt="Margin on a Mac: the inbox and the command menu"
					width={1800}
					height={1168}
				/>
				<img
					className="for-dark"
					src="/images/margin-dark.jpg"
					alt="Margin on a Mac in dark mode: the inbox and a conversation"
					width={1800}
					height={1168}
				/>
			</div>

			<div className="scene-phone">
				<img
					className="for-light"
					src="/images/margin-iphone-light.jpg"
					alt="Margin on iPhone: the inbox"
					width={506}
					height={1100}
				/>
				<img
					className="for-dark"
					src="/images/margin-iphone-dark.jpg"
					alt="Margin on iPhone in dark mode: the inbox"
					width={506}
					height={1100}
				/>
			</div>

			<Floaters />
		</div>
	);
}
