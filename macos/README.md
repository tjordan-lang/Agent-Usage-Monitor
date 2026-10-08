# Agent Usage Monitor for macOS

A small window with a tab for each agent — Codex, OpenCode, and Cline. Every
tab shows tokens used today and all time, an estimated cost, and recent
sessions, all read from local databases and logs. Press `1`, `2`, or `3` to
switch tabs.

The Cline and OpenCode tabs also pull live subscription limits — 5-hour,
weekly, and monthly — straight from their usage services, using the logins
those tools already keep on disk. Each bar shows the percent left, a
countdown to the reset, and the reset's clock time.

## Install

1. Move `Agent Usage Monitor.app` to Applications and open it once. If macOS
   complains about a locally built app, Control-click it and choose **Open**.
2. Leave it running — it re-reads everything every minute.

Needs macOS 26 or later.

## Build it yourself

From this folder, run `xcodegen generate` (only after changing
`project.yml`), then build the `AgentUsageMonitor` scheme in Xcode.

## Where the numbers come from

- **OpenCode** — adds up the per-message cost OpenCode records in
  `opencode.db`, which it works out from each message's model and published
  pricing.
- **Cline** — uses the cost in each session's metadata when there is one.
  cline-pass sessions record $0, so those get estimated from the same token
  counts at list prices instead.
- **Codex** — doesn't record cost, so each thread is estimated at list prices
  for its model, using the token mix from the local rollout logs (recent
  usage is about 95% cached input, which is much cheaper than fresh input).

"Today" means since local midnight. The prices live in `ModelPricing` in
`App/UsageReader.swift` — USD per 1M tokens, standard tier, with source URLs
and the date they were surveyed. No entry, no count. Prices drift, so treat
these as "what this usage would cost at list prices", not as a bill.
