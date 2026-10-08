# Codex Usage for macOS

The app adds a Codex Usage button to Control Center and a small usage window. Its app window has separate tabs for Codex and OpenCode. Usage is read from their local databases and logs; no network calls are made.

The OpenCode tab reads `~/.local/share/opencode/opencode.db` and shows all-time token totals plus recent session token counts. The Codex tab reads the local Codex state database and session logs.

## Install

1. Move `Codex Usage.app` to Applications and open it once. If macOS blocks this locally built app, Control-click it and choose **Open**.
2. Open Control Center, choose **Edit Controls**, find **Codex Usage**, and add it.
3. Leave the app running to refresh the shared snapshot every minute.

The Control Center display updates when macOS reloads the control. Click it to open the menu bar app. Requires macOS 26 or later.

## Rebuild

From this folder, run `xcodegen generate`, then build the `CodexUsageControl` scheme in Xcode. The app requires macOS 26 or later.
