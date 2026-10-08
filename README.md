# Codex Usage for macOS

The app adds a Codex Usage button to Control Center and a small usage window. Its app window has separate tabs for Codex, OpenCode, and Cline. Usage totals are read from their local databases and logs. The Cline and OpenCode tabs also show live subscription quota bars, checked directly with Cline's and OpenCode Go's usage services using the sign-ins those tools already keep on disk.

The OpenCode tab reads `~/.local/share/opencode/opencode.db`; the Codex tab reads the local Codex state database and session logs; the Cline tab reads the local Cline session records under `~/.cline/data/sessions`. All three tabs show token totals and recent session token counts. The Cline and OpenCode tabs also show 5-hour, weekly, and monthly subscription limit bars: Cline from `GET https://api.cline.bot/api/v1/users/me/plan/usage-limits` (token read read-only from `~/.cline/data/settings/providers.json`; if the session expires, run `cline auth`), and OpenCode from `GET https://opencode.ai/zen/go/v1/usage` (key read read-only from `~/.local/share/opencode/auth.json`). Each limit bar shows the percent left and a live countdown to the reset. The limits section stays hidden when a tool has no stored sign-in.

## Install

1. Move `Codex Usage.app` to Applications and open it once. If macOS blocks this locally built app, Control-click it and choose **Open**.
2. Open Control Center, choose **Edit Controls**, find **Codex Usage**, and add it.
3. Leave the app running to refresh the shared snapshot every minute.

The Control Center display updates when macOS reloads the control. Click it to open the menu bar app. Requires macOS 26 or later.

## Rebuild

From this folder, run `xcodegen generate`, then build the `CodexUsageControl` scheme in Xcode. The app requires macOS 26 or later.
