# Agent Usage Monitor

A terminal UI that tracks your local Codex, OpenCode, and Cline usage. It
mirrors the companion Codex Usage macOS app.

## What it shows

- Subscription limit bars for Codex, OpenCode, and Cline: percent left, a
gauge, and a reset line with a live countdown plus the reset clock time
- Today's and all-time token totals for every agent
- Estimated cost, today and all time, from a local price table
- Recent threads (Codex) and sessions (OpenCode and Cline)

## What it does

- Reads only local data: the Codex state database and session logs, the
OpenCode database, and Cline's session records
- Checks Cline and OpenCode subscription quotas live, reusing the sign-ins
those tools already store on disk
- Sends nothing else anywhere

## How to run

```bash
node tui/agent-usage-monitor.mjs
```

Keys: `1` / `2` / `3` switch agents, `Tab` cycles, `r` refreshes, `q` quits.

## Notes

- This tool is local-only, and shows usage for the machine it runs on.
- It may display local session titles and metadata.
- Quota checks reuse stored sign-ins read-only: Cline's token from
`~/.cline/data/settings/providers.json` (if the session expires, run
`cline auth`) and OpenCode's key from `~/.local/share/opencode/auth.json`
(if rejected, run `opencode auth login`). A tool's limits section stays
hidden when it has no stored sign-in.
- `AGENT_USAGE_MONITOR_SELF_TEST=1` runs assertions; `AGENT_USAGE_MONITOR_ONCE=1`
prints one frame and exits; `AGENT_USAGE_MONITOR_TAB=cline` picks a single tab.
