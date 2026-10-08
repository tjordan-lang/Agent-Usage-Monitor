# Agent Usage Monitor

Two local, read-only tools for watching what your coding agents are doing on
this machine:

- **`macos/`** — a macOS app ("Codex Usage") with per-agent tabs.
- **`tui/`** — a zero-dependency terminal UI
  ([`tui/agent-usage-monitor.mjs`](tui/agent-usage-monitor.mjs)).

Both show the same things for **Codex**, **OpenCode**, and **Cline**:

- Subscription limit bars: percent left, a gauge, and a reset line with a live
  countdown plus the reset clock time (`23:11` today, `Tue 23:11` within a
  week, `Oct 16 at 19:28` beyond)
- Today's and all-time token totals
- Estimated cost, today and all time (pay-as-you-go list prices)
- Recent threads and sessions

Everything is read from local files (`~/.codex`, `~/.local/share/opencode`,
`~/.cline`). The only network calls are the two subscription quota checks,
which reuse the sign-ins the CLIs already store on disk; nothing else leaves
the machine.

## The terminal UI

```bash
node tui/agent-usage-monitor.mjs
```

Keys: `1` / `2` / `3` switch agents, `Tab` cycles, `r` refreshes, `q` quits.

## The macOS app

Build from `macos/` (requires macOS 26 or later):

```bash
cd macos
xcodegen generate   # only after changing project.yml
open CodexUsageControl.xcodeproj
```

Install: move `Codex Usage.app` to Applications and open it once, and leave
it running to refresh every minute.

## Quota sign-ins

- **Cline** — token read read-only from `~/.cline/data/settings/providers.json`;
  if the session expires, run `cline auth`.
- **OpenCode** — key read read-only from `~/.local/share/opencode/auth.json`;
  if rejected, run `opencode auth login`.

A tool's limits section stays hidden until it has a stored sign-in.

## Layout

```
macos/   Xcode project and macOS app
tui/     terminal UI script
```

## License

MIT — see [LICENSE](LICENSE).
