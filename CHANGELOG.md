# Changelog

## 1.4.0 - 2026-11-03

Needs JoeBro 1.4.0 or later on your Mac.

### Added

- **Coding agents** linked with [joebro-plugins](https://github.com/joexk1/joebro-plugins) (Claude Code, Codex, opencode) appear in the Agents tab and the Dynamic Island, counted once.
- **Approve or Deny from the lock screen** when one of them is waiting on a permission prompt. Approving needs Face ID; denying never does. Works when the agent runs in kitty or tmux.
- **Proactive mode** in Settings: off, read only or full. You can see what JoeBro spotted or did in the background and undo it.
- **Shopping list** in the Workspace hub.
- **Apple Health.** Read-only HealthKit access to daily totals (steps, sleep, heart rate, workouts), sent only to your own JoeBro for a weekly recap. Off until you allow it.

## 1.3.0 - 2026-10-13

First public release. Needs JoeBro 1.3.0 or later on your Mac.

### Added

- Pairing with your Mac by QR code, link, or pasting the URL and token. The app checks both before saving anything.
- The phone agent: one persistent chat that follows your default model and delegates work to chats bound to folders.
- Chats, agents, documents, email, calendar, research and workspace tabs, all served by your own Mac.
- Inbox for notices from the agent, tasks and agents.
- Optional push notifications and Live Activities, using your own Apple key.
- Optional location for weather.
- Share extension, voice input and a Face ID lock.
- No MCP servers are connected by default.

### Security

- The token is stored in the Keychain, on that phone only.
- The phone can't add MCP servers or plugins on the Mac.
