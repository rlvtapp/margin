import { createFileRoute } from "@tanstack/react-router";
import { NotFound } from "@/components/not-found";
import { seo } from "@/seo";

// Prerendered as 404.html, which the Worker serves for unknown addresses.
export const Route = createFileRoute("/404")({
	component: NotFound,
	head: () =>
		seo({ path: "/404", title: "Page not found", description: "This page doesn't exist.", hidden: true }),
});
