// Serve only the prerendered site, including its real 404 page.
export default {
	fetch(request, env) {
		return env.ASSETS.fetch(request);
	},
};
