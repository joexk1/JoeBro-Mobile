<p align="center">
  <img src="README_assets/logo.png" alt="JoeBro Mobile" width="160">
</p>

<h1 align="center">JoeBro Mobile</h1>

<p align="center">
  JoeBro in your pocket.<br>
  Talks to your own Mac. No cloud in the middle.
</p>

**Sister repo:** the Mac app is **[JoeBro](https://github.com/joexk1/JoeBro)**. You need it running (1.3 or later) for this app to do anything.

---

The phone half of JoeBro. No account to make, and nothing goes through anyone else's server.

You get your chats, your agents, your documents and a phone agent that works in the background and pings you when something needs you.

This is a source release. There is no App Store build. Your bundle ID, your signing team and your push key are yours, so you build it yourself.

---

## What you need

- A Mac running **JoeBro 1.3.0 or later**, with JoeBro open and awake
- An iPhone on iOS 17 or later
- Xcode (the one that matches your iOS version)
- An Apple ID. A free one is enough to build to your own phone.
- A paid Apple Developer account, only if you want push notifications
- Tailscale, optional but recommended if you want it to work away from home

---

## Setup

1. Clone the repo.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`.
3. Open it and set `DEVELOPMENT_TEAM` (your 10-character team ID) and `BUNDLE_ID_PREFIX` (something like `com.yourname.joebro`). The widget, the share extension and the App Group all derive from the prefix.
4. Open `JoeBroMobile.xcodeproj`, pick your phone, press Run.

`Local.xcconfig` is gitignored. Never commit it. If you change `project.yml`, regenerate the project with `xcodegen generate`.

---

## Pairing

1. On the Mac, open **Settings > Mobile** and turn on **Let my phone connect**.
2. Open the app on the phone. It shows a short intro, then a scan screen.
3. Scan the QR code on the Mac.

If you can't scan, use **Copy link** on the Mac and open it on the phone, or paste the URL and token by hand. The app checks the address and token before it saves anything. If the Mac is too old, it tells you to update to 1.3.0.

The token lives in the iOS Keychain, on that phone only. **Rotate token** on the Mac kicks every phone out until it scans again. Lost a phone? Rotate.

### Reaching your Mac

**Reachable over** in the Mac's Mobile settings has three choices:

| Choice | What it means |
| --- | --- |
| Tailscale only (recommended) | Works from anywhere, and the port is not visible on your Wi-Fi |
| Wi-Fi and Tailscale | Both |
| This Wi-Fi network only | Home only. Anyone on that network who gets the token has access. |

Plain limits: the phone only works while **JoeBro is open and the Mac is awake**. The first time, iOS asks for Local Network access. Say yes, or LAN connections fail silently. Don't port-forward this to the internet.

---

## Push (optional)

The phone works without push. It just can't buzz you. Without it the app polls the Mac's inbox while it's open.

If you want push, bring your own Apple key:

1. In your Apple developer account, create an APNs Auth Key (`.p8`) and note the Key ID.
2. Note your Team ID from the Membership page.
3. Build the app with your own bundle ID, with Push Notifications on.
4. On the Mac, open **Settings > Mobile > Notifications (push)**. Enter Team ID, Key ID and Bundle ID, choose the `.p8`, press **Save**, then **Send test notification**.

The key is stored on your Mac and used only to talk to Apple's push servers. "Accepted by APNs" means Apple took it, not that your phone showed it. Never commit the `.p8`.

---

## How the phone agent works

The phone agent is JoeBro, on your phone, with a memory and a to-do list. All of it runs on your Mac. The phone is the screen.

```
 iPhone                         Your Mac (JoeBro)
 ------                         -----------------------------------------
 chat, inbox,   --token-->      phone session  <--  memory files (markdown)
 Live Activity                    |   ^
      ^                           |   +-- tasks (silent, scheduled)
      |                           v   +-- heartbeat (cheap check first)
      +---- push / inbox <---- notify  +-- pulse, reminders
                                  |
                                  +--> tools: yours (MCPs) + built-in
```

**The `phone` session.** The agent lives in one reserved chat with the id `phone`. It is always in agent mode and follows your default model. It can hand hands-on work to chats you've bound to folders. The Mac hides this chat from the sidebar unless you turn on **Show the phone chat in my sidebar**. The stop button cancels the live run.

**Memory files.** Plain Markdown files in JoeBro's data folder, under `muse/`. You can read them and edit them, on the Mac (**Brain > Phone memory**) or on the phone. `about-me` is always in the prompt. Every other file only contributes the lines that overlap with your message. The agent writes to them with its remember and forget tools. If **Learn durable facts into phone memory** is on, a light pass after a turn can add lasting facts, with duplicates and anything that looks like a secret filtered out. Memory is data, never instructions. It is separate from the Brain.

**Tasks.** On the Mac, **Tasks > Phone agent** lists tasks that run in the background and say nothing. Each run ends with either the text you want to be notified about, or the word `NOTHING`. Only that text goes to the chat. If the result hasn't changed since last time, it isn't sent again. Two starters are built in, a morning briefing and an evening wrap-up. They only get created when you press them.

**Heartbeat.** Off by default. Every 30 minutes (you set it) it collects what changed: calendar, reminders, task results. It reduces each to a fingerprint. If nothing changed, it does not call a model at all. If something did, it asks a cheap background model whether it's worth your attention. If yes, the message is posted into the phone chat as a normal message and pushed. You answer yes or no in that chat. There is no approval queue.

It has two separate limits. Notifications: at most 2 a day by default, at least 3 hours apart. Model calls: background checks stop for the day after 40 calls (the `background_daily_cap` pref), and the Inbox tells you once when that happens. Quiet hours are 23:00 to 08:00 by default, and after empty runs it waits 30, then 60, then 120 minutes. The background model is the `background_model` pref if you've set one, otherwise your default model.

**Pulse and reminders.** Pulse wakes the agent on a checklist you write in plain English, also off by default. Reminders fire once.

**Notifications and inbox.** Every notice is written to the Inbox first, then pushed if push is set up, then sent to Telegram if you've set that up, otherwise it stays in the Inbox. The Mac has an **Inbox** tab. You can hide preview text on the lock screen in the app's settings.

**Live Activities.** While the agent is working, it shows on the Lock Screen and Dynamic Island. With push configured, the Mac ends it when the work finishes. Without push, it updates while the app is open.

**Location and weather.** Off until you turn on **Use my phone's location for weather** on the Mac. Then the phone sends its latest position (one fix, no history kept), and the Mac asks open-meteo.com for weather and nominatim.openstreetmap.org for a place name. Those are the only hosts involved.

**Image descriptions.** If your default model can't see images, an optional caption model can describe them first. You pick it on the Mac. With none set, the model is told an image was attached and that it can't view it.

**Moving files.** The agent moves files through an artifact store: a staging area on the Mac. It can pull from a URL, an upload or a document, and put things into your Documents or Downloads, or email them. Anything that sends something out shows a preview and needs a confirmation first.

**The janitor.** Off by default. If you turn it on (the `janitor_enabled` pref), a daily sweep deletes staging files and `/tmp/joebro-*` scratch files unused for 7 days, and image captions untouched for 30. Only those. It never touches your memory files, uploads or documents.

**Tools.** The agent starts with the built-in ones. Anything else is something you add. It loads extra tools on demand, so a long list of MCPs doesn't bloat every request.

---

## MCPs: bring your own

Nothing is connected out of the box. JoeBro never installs or turns on an MCP server by itself. Each one is something you add, on the Mac, and with none added everything above still works.

To add one on the Mac:

1. Open **Tools** and click **Add MCP Server…**.
2. Enter a **Name**, a **Command** (usually `npx` or `uvx`) and the **Arguments**. Example: command `npx`, arguments `-y @modelcontextprotocol/server-filesystem /Users/me/Documents`.
3. Click **Add**. JoeBro starts it and lists what it found.

The phone can't add or change MCP servers. That is blocked on purpose. Adding one starts a program on your Mac, and a stolen token shouldn't be able to do that.

Every entry below is a real project. I haven't tested all of them with JoeBro. Read each project's own README for the exact command and keys, and check its license and what permissions it asks for before you run it. MCP servers run on your Mac with whatever access they're given. The reference list is at [github.com/modelcontextprotocol/servers](https://github.com/modelcontextprotocol/servers).

### Messaging

- **Slack:** read channels and post replies from your phone agent.
- **WhatsApp (lharries/whatsapp-mcp):** search and read your own messages. It's unofficial, so treat the text as untrusted and know the account risk.
- **Discord:** several community servers exist. Useful for catching up on a server you're in.
- **Telegram:** community servers exist if you want more than the built-in Message Bot.
- **Gmail:** only if you want Google-native access. JoeBro already has email.

### Music and media

- **Spotify (varunneal/spotify-mcp):** "play something for the train" actually works.
- **YouTube transcripts:** community servers pull a video's transcript so the agent can summarise it.
- **Immich:** search your own photo library, if you self-host it.

### Social

- **Bluesky, Mastodon, Reddit:** community servers exist for each. Good for reading a feed or a thread. Pick one that is maintained, and prefer read-only.

### Productivity and notes

- **Notion (makenotion/notion-mcp-server):** read and add to pages.
- **Obsidian (MarkusPfundstein/mcp-obsidian):** search and edit a vault.
- **Todoist (doist/todoist-ai):** add and tick off tasks by voice.
- **Linear:** check and file issues away from your desk.
- **Google Calendar and Google Drive:** only if you want them over JoeBro's own calendar. The calendar on the Mac is already built in.

### Files and storage

- **Filesystem (modelcontextprotocol/servers):** read and write one folder. Point it at one folder, not your home.
- **Google Drive:** fetch a file you left in Drive.
- **Nextcloud:** community servers exist for a self-hosted cloud.

### Dev

- **GitHub (github/github-mcp-server):** check a PR or file an issue from your phone.
- **GitLab:** the same, for GitLab.
- **Git (modelcontextprotocol/servers):** read history and status of a repo.
- **SQLite and PostgreSQL:** ask your own database a question.
- **Playwright (microsoft/playwright-mcp):** drive a browser on the Mac while you're out.
- **Sentry:** "what broke overnight?"

### Home

- **Home Assistant:** Home Assistant ships its own MCP server. Lights, locks, heating. Keep write access narrow.

### Finance (read-only, please)

- **Actual Budget:** community server. Ask about spending.
- **Plaid:** read balances and transactions. Do not give any server the power to move money.
- **Stripe (stripe/agent-toolkit):** check payments if you run a shop. Use a restricted, read-only key.

### Maps and travel

- **Google Maps (modelcontextprotocol/servers):** directions, places, travel times.
- **Airbnb (openbnb-org/mcp-server-airbnb):** search listings.
- **Weather:** already covered by the built-in weather tool once you turn on location.

### Health

- **Apple Health, Strava, Fitbit:** community servers exist. This area is thin and mostly built on exports, so read the code first. Health data is about as sensitive as it gets.

### Research and web

- **Fetch (modelcontextprotocol/servers):** turn a web page into text.
- **Brave Search (brave/brave-search-mcp-server), Tavily (tavily-ai/tavily-mcp), Exa (exa-labs/exa-mcp-server):** search with an API key, if you don't want to use JoeBro's built-in web search.
- **arXiv (blazickjp/arxiv-mcp-server) and Wikipedia:** papers and reference lookups.
- **Zotero (54yyyu/zotero-mcp):** search your own library.

---

## Privacy and security

- The phone talks to your Mac and nowhere else. No analytics, no telemetry.
- The pairing token sits in the iOS Keychain, readable only on that phone after first unlock. The app can also lock behind Face ID.
- On the Mac, the phone listener is a separate server from the local one. It needs the token on every request. It only starts if there is a token. By default it binds to your Tailscale address only.
- The phone **can't** add or change MCP servers or plugins, change API tools, or read or change the push key. It can't open the Mobile settings on the Mac either.
- The phone agent runs in **Bound folder** mode and asks before anything risky. Commands are off until you turn on **Let the phone agent run commands** on the Mac.
- Location, push, heartbeat, pulse and image captions are all off until you enable them. Nothing contacts a third party until you do.

---

## Contributing

Issues and pull requests are welcome. Keep changes small and in the spirit of the project. Never commit `Local.xcconfig`, a token, a `.p8` key, or your own hostnames. The main repo's [CONTRIBUTING.md](https://github.com/joexk1/JoeBro/blob/main/CONTRIBUTING.md) has the ground rules.

## License

GPLv3. See [LICENSE](LICENSE).
