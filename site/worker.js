// Serve the prerendered site, including its real 404 page. Two addresses point at the newest
// published GitHub release instead (docs/updates.md), so they never change between versions:
// the Mac app's update feed, and the download for the website's button.
const RELEASES = "https://github.com/rlvtapp/margin/releases/latest/download";
const REDIRECTS = {
	"/appcast.xml": `${RELEASES}/appcast.xml`,
	"/download/mac": `${RELEASES}/Margin.dmg`,
};

export default {
	fetch(request, env) {
		const target = REDIRECTS[new URL(request.url).pathname];
		if (target) {
			return new Response(null, {
				status: 302,
				headers: { Location: target, "Cache-Control": "public, max-age=300" },
			});
		}
		return env.ASSETS.fetch(request);
	},
};
