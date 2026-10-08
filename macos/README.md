# Codex Usage for macOS

The app adds a Codex Usage button to Control Center and a small usage window. Its app window has separate tabs for Codex, OpenCode, and Cline. Usage totals are read from their local databases and logs. The Cline and OpenCode tabs also show live subscription quota bars, checked directly with Cline's and OpenCode Go's usage services using the sign-ins those tools already keep on disk.

The OpenCode tab reads `~/.local/share/opencode/opencode.db`; the Codex tab reads the local Codex state database and session logs; the Cline tab reads the local Cline session records under `~/.cline/data/sessions`. All three tabs show today's and all-time token totals, an estimated cost for today and for all time, and recent session token counts. The Cline and OpenCode tabs also show 5-hour, weekly, and monthly subscription limit bars: Cline from `GET https://api.cline.bot/api/v1/users/me/plan/usage-limits` (token read read-only from `~/.cline/data/settings/providers.json`; if the session expires, run `cline auth`), and OpenCode from `GET https://opencode.ai/zen/go/v1/usage` (key read read-only from `~/.local/share/opencode/auth.json`). Each limit bar shows the percent left, a live countdown to the reset, and the reset's clock time. The limits section stays hidden when a tool has no stored sign-in.

## Install

1. Move `Codex Usage.app` to Applications and open it once. If macOS blocks this locally built app, Control-click it and choose **Open**.
2. Open Control Center, choose **Edit Controls**, find **Codex Usage**, and add it.
3. Leave the app running to refresh the shared snapshot every minute.

The Control Center display updates when macOS reloads the control. Click it to open the app. Requires macOS 26 or later.

## Rebuild

From this folder, run `xcodegen generate`, then build the `CodexUsageControl` scheme in Xcode. The app requires macOS 26 or later.

## Estimated cost

Each tab shows an estimated cost in dollars, both for today and for all time:

- **OpenCode** sums the per-message cost that OpenCode itself records in `opencode.db`, computed by OpenCode from each message's model and its published pricing.
- **Cline** uses the cost recorded in each session's metadata where Cline reports one; sessions covered by cline-pass (which record $0) are estimated from the same token counts at API list prices.
- **Codex** records no cost, so each thread is estimated at current pay-as-you-go list prices for the thread's model, applying the token mix observed in the local rollout logs (recent usage runs ~95 % cached input, which is priced far below fresh input).

“Today” means since local midnight: Codex threads created today, OpenCode messages recorded today, and Cline sessions started today. The price table — USD per 1M tokens, standard tier, with source URLs and the survey date — lives in `ModelPricing` in `App/UsageReader.swift`. Models without a price entry are not counted. Pricing changes over time, so treat these figures as estimates of what the same usage would cost at API list prices, not as billing statements.
