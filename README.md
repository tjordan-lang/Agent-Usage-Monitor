# Agent Usage Monitor

Two small tools that keep an eye on what Codex, OpenCode, and Cline are doing
on your Mac — how much of your limits is left, how many tokens you've burned,
what it's costing, and what you were working on.

- **`macos/`** — the app. A little window with a tab per agent.
- **`tui/`** — the terminal version. One file, no dependencies, just Node.

They show the same things:

- **Limits, in percent left.** Each one has a bar and a reset time like
  `resets in 3h 12m · 23:11`. The clock keeps it short: `23:11` if it resets
  today, `Tue 23:11` later in the week, and `Oct 16 at 19:28` after that.
- **Tokens used today, and all time.**
- **A rough cost** (today and all-time), estimated from published API prices.
- **Recent threads and sessions**, so you can see what you were doing.

Everything comes from files already on your Mac (`~/.codex`,
`~/.local/share/opencode`, `~/.cline`). The only things that touch the
network are the two limit checks for Cline and OpenCode, and those just
reuse the logins those CLIs keep on disk. Nothing else goes anywhere.

## The terminal one

```bash
node tui/agent-usage-monitor.mjs
```

Hit `1`, `2`, or `3` (or `Tab`) to switch agents, `r` to refresh, `q` to
quit.

## The app

Grab `Agent Usage Monitor.app` from the latest release and drop it in
Applications, or build it yourself from `macos/`:

```bash
cd macos
xcodegen generate   # only if you changed project.yml
open AgentUsageMonitor.xcodeproj
```

Press `1`, `2`, or `3` to switch tabs, and leave it open so the numbers stay
fresh — it re-reads everything every minute. Needs macOS 26 or later.

## If the limit bars stop working

The Cline and OpenCode limits use the logins those CLIs already have,
read-only. An expired session is the usual culprit:

- Cline: run `cline auth`
- OpenCode: run `opencode auth login`

No sign-in at all? The limits section just stays hidden.

## Layout

```
macos/   the app (Xcode project)
tui/     the terminal version
```

## License

MIT — see [LICENSE](LICENSE).
