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
/** The window is about 850 pixels wide on a desktop screen, nearly the full width on a phone. */
const heroSizes = "(max-width: 900px) 92vw, 850px";
const heroSet = (theme: "light" | "dark") =>
	`/images/mac-hero-${theme}-1600.jpg 1600w, /images/mac-hero-${theme}.jpg 2600w`;

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
				{/* The light picture first: it's what most visitors see, and the page's biggest
				    picture. The dark one loads only when it's the one shown. */}
				<img
					className="for-light"
					src="/images/mac-hero-light.jpg"
					srcSet={heroSet("light")}
					sizes={heroSizes}
					alt="Margin on a Mac: every inbox in one list, with a conversation open"
					width={2600}
					height={1608}
					fetchPriority="high"
				/>
				<img
					className="for-dark"
					src="/images/mac-hero-dark.jpg"
					srcSet={heroSet("dark")}
					sizes={heroSizes}
					alt="Margin on a Mac in dark mode: every inbox in one list, with a conversation open"
					width={2600}
					height={1608}
					loading="lazy"
				/>
			</div>

			<Floaters />
		</div>
	);
}
