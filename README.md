# zot sidekick

A macOS menu bar app that provides quick access to zot from anywhere on your system.

## Features

- **Menu Bar Integration**: Lives in your menu bar for quick access
- **Global Hotkey**: Long-press the Right Option key to toggle the panel from anywhere
- **Floating Panel**: Spotlight-style centered floating window that remembers its position and size
- **Chat Interface**: Clean, dark-themed chat interface with streaming responses
- **Image Support**: Drag and drop images for vision-based queries
- **Sessions**: Conversations auto-save and can be browsed, searched, reloaded, and deleted
- **Working Directory**: Set context for file operations
- **Inline Settings**: Configure provider, authentication (API key or subscription), and model directly in the panel

## Requirements

- macOS 14.0 or later
- Xcode 26 or later (the app icon uses Icon Composer, which needs Xcode 26+)
- An Anthropic, OpenAI, etc. API key, or a supported subscription login

> **Note on subscription login.** The OAuth client IDs used are the ones published in Anthropic's Claude Code CLI, OpenAI's Codex CLI, and the Kimi Code CLI device-code flow. Reusing them from a third-party tool may be against their terms of service and may be revoked at any time. Use it at your own risk; the API-key flow is the safe default.

The `zot` binary is **baked into the app bundle**, downloaded from the
[official GitHub releases](https://github.com/patriceckhart/zot). No separate
zot install is required, and the app never uses any zot on your system PATH.

## Updates (in-app, native Swift)

The app manages its own copy of the zot binary in Application Support and
updates it entirely in Swift (`ZotUpdater.swift`):

- On launch and on demand it checks the GitHub releases API for the latest
  version.
- When a newer version exists, Settings shows a primary "Update zot" button
  that downloads the correct darwin build for your architecture, extracts it,
  and atomically replaces the installed binary, then restarts the bridge.
- The bundled in-app copy only seeds the first install; downloaded updates
  are preferred and are not overwritten unless a newer build ships in the app.

No shell script is involved at runtime.

### Refreshing the baked-in copy (developers only)

`scripts/bundle-zot.sh` is a pre-release helper to refresh the binary that
ships inside the app bundle. It is not part of the running app and does not
affect the in-app update path.

## Installation

1. Open `zot sidekick.xcodeproj` in Xcode
2. Build and run (Cmd+R)
3. Grant accessibility (for the global hotkey) and screen recording permissions when prompted
4. Open the panel and click the gear (Settings) in the top bar to configure authentication

## Usage

### Summoning the Panel

- **Menu Bar Click**: Click the icon in the menu bar to toggle the panel
- **Global Hotkey**: Long-press the Right Option key (about 0.4s) to toggle it from anywhere
- **Dismiss**: Press Escape or click the menu bar icon again

The panel remembers the position and size you drag it to across hide/show.
It resets to the default centered position only when you quit and relaunch.

### Chat

- Type your question in the input field at the bottom
- Press Enter or click the send button
- Drag and drop images onto the window to include them in your query
- Click "Copy" on any assistant response to copy it to clipboard
- Click "Paste into …" to paste the response into your previously active application

### Working Directory

- Click the folder icon in the input bar to set a working directory
- Zot will use this directory as context for file operations

### Sessions

- Conversations are saved automatically after each reply
- Click "Sessions" in the panel top bar to browse, search, reload, or delete saved sessions
- Sessions are stored as flat JSON files in
  `~/Library/Application Support/Zot Sidekick/Sessions/` (no project folders)
- Click "+ New" to start a fresh conversation

### Settings

- Click the gear (Settings) in the panel top bar to open settings inline
- Configure:
  - Provider (Anthropic, OpenAI, ChatGPT Subscription, Kimi, Google, DeepSeek, Ollama)
  - Authentication: either a subscription login or an API key
  - Default Model
  - Zot binary version, with a primary "Check for Updates" / "Update zot" button

### Subscription Login

Providers that support subscriptions (Anthropic Claude, ChatGPT, Kimi) offer a
"Log in with subscription" button. This runs the same OAuth flow as the zot CLI:

- Anthropic and ChatGPT open a browser and capture the callback on a local
  loopback port (PKCE).
- Kimi uses the OAuth device flow (a code plus a browser page).

Tokens are written to the bundled binary's `ZOT_HOME/auth.json`, so the
embedded zot uses your subscription with no extra setup. API keys are stored
the same way. Use "Sign Out" to remove stored credentials for a provider.

## Architecture


- **AppDelegate**: Owns the menu bar icon, the panel, and the global hotkey
- **HotkeyMonitor**: Long-press Right Option detection (CGEvent tap with an NSEvent fallback)
- **PanelController**: Controls the floating panel window and remembers its frame
- **PanelChatView**: SwiftUI chat UI, including the inline settings overlay (`InlineSettingsView`) and the typing indicator
- **AppState**: Observable state management with `@Observable`, plus binary preparation and session/auth orchestration
- **ZotBridge**: Spawns and communicates with the bundled `zot rpc` process via JSON-RPC
- **SessionStore**: Flat-file JSON persistence for sessions (no project folders)
- **ZotAuth / ZotOAuthLogin**: API keys and subscription OAuth, written to `ZOT_HOME/auth.json`
- **ZotUpdater**: GitHub release checks and in-Swift download/install of the binary
- **SettingsWindow**: A standalone settings window (legacy fallback; the inline panel settings are the primary path)

## Development

The app uses:
- SwiftUI for the UI
- Observation framework for state management
- ScreenCaptureKit for screenshot functionality
- Process for spawning the bundled zot binary
- NWListener loopback servers for OAuth callbacks
- Icon Composer (`Icon.icon`) for the app icon

## Releases (GitHub Actions)

`.github/workflows/build-dmg.yml` builds the app on `macos-latest` (pinned to
the latest Xcode for Icon Composer support) on every push and on manual
dispatch. It:

- auto-versions each build from the run number with rollover
  (`0.0.1 ... 0.0.99 -> 0.1.0 ... 0.99.99 -> 1.0.0 ...`),
- ad-hoc signs the app (including the embedded zot binary),
- packages a `Zot-Sidekick-<version>.dmg` containing the app and an
  `Applications` symlink for drag-and-drop install,
- uploads the DMG as a build artifact, and publishes a GitHub Release on
  tag pushes (`vX.Y.Z`).

The builds are unsigned/ad-hoc, so on first launch users may need to
right-click the app and choose Open (or allow it in System Settings) until a
Developer ID signature and notarization are added.

## Distribution

This app bundles the zot binary and spawns it as a child process that reads
and writes files anywhere and runs developer tools. That model requires the
sandbox to be off (`ENABLE_APP_SANDBOX = NO`) and is therefore distributed as
a notarized, Developer ID-signed build outside the Mac App Store, the same as
the zot CLI itself. The Mac App Store requires a sandbox that would prevent
the embedded agent from doing its job, so it is not a target for this app.

For release: archive in Xcode, sign with your Developer ID (deep-signing the
embedded `zot-bin`), notarize with `notarytool`, then staple and ship the
`.dmg`.

## License

MIT
