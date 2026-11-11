/** A name with a small coloured tile, bobbing gently. The tiles are plain initials, not logos. */
function Chip({ name, color, index }: { name: string; color: string; index: number }) {
	return (
		<li style={{ animationDelay: `${-index * 0.6}s` }}>
			<i style={{ background: color }}>{name[0]}</i>
			{name}
		</li>
	);
}

const apps: [string, string][] = [
	["Claude", "#d97757"],
	["ChatGPT", "#10a37f"],
	["Cursor", "#4b5160"],
	["VS Code", "#2f7fd8"],
	["Windsurf", "#0fb5a6"],
	["Codex", "#5b5bd6"],
	["Gemini CLI", "#4a7cf7"],
	["LM Studio", "#7c5cff"],
	["Antigravity", "#e0457b"],
	["Claude Code", "#c2603f"],
];

const models: [string, string][] = [
	["On this Mac", "#2f78f5"],
	["Ollama", "#525866"],
	["LM Studio", "#7c5cff"],
	["Claude", "#d97757"],
	["ChatGPT", "#10a37f"],
	["Gemini", "#4a7cf7"],
	["Grok", "#6b7280"],
	["Any other server", "#8a93a3"],
];

/**
 * What you can bring along: the AI apps you already use (Margin adds itself to them in a
 * click), and the model the built-in assistant runs on.
 */
export function BringYourOwn() {
	return (
		<div className="byo">
			<section>
				<h3>Your AI apps</h3>
				<p>
					One click in Margin's settings adds it to the app you already use. It
					speaks MCP, so anything else that does can connect too.
				</p>
				<ul className="chips">
					{apps.map(([name, color], i) => (
						<Chip key={name} name={name} color={color} index={i} />
					))}
				</ul>
			</section>
			<section>
				<h3>Your model, your key</h3>
				<p>
					The built-in assistant runs on the model you pick. A key you add goes
					straight to that provider, never through us.
				</p>
				<ul className="chips">
					{models.map(([name, color], i) => (
						<Chip key={name} name={name} color={color} index={i + 3} />
					))}
				</ul>
			</section>
		</div>
	);
}
