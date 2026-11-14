# Getting started

ScreenClip runs on **macOS 14 or later**. A local build needs **Xcode 16 or later**. The Swift package uses tools version 6.0 and the Swift 5 language mode. There are no external Swift package dependencies. SQLite comes from the system through `Sources/CSQLite`.

You also need a local Git repository for each project, and at least one agent:

- **Codex CLI**, with `app-server`
- **Claude Code**
- **Grok Bot**, connected with a setup code

**GitHub CLI** (`gh`) is required to open and merge pull requests, and to push screenshots for Grok Bot.

## Build and run

```sh
cp Config/LocalSigning.xcconfig.example Config/LocalSigning.xcconfig
open ScreenClip.xcodeproj
```

Set your Apple Development certificate and team in `Config/LocalSigning.xcconfig`. Git ignores that file. Select **ScreenClip → My Mac** and press **⌘R**. The shared scheme builds, installs, and launches **`/Applications/ScreenClip.app`**. **⌘B** builds without installing.

The same install from Terminal:

```sh
bash scripts/run.sh
```

`bash scripts/run.sh release` installs a Release build instead. Local installation requires a signing certificate so macOS screen-recording permission survives the next update. Ad-hoc signing is enough for a build that you do not install. `bash scripts/build.sh [debug|release]` only builds. The product is `build/DerivedData/Build/Products/<Configuration>/ScreenClip.app`.

Save any open capture, and finish or cancel active work, before installing over a running copy. The installer asks running copies to quit, then replaces `/Applications/ScreenClip.app` and rolls back if the replacement fails. It does not touch the queue.

More commands, tests, and CI are in [Development](development.md).

## First capture

1. **Add a project** in **Settings → Projects**: the Git repository root, base branch, website URLs or native app bundle IDs, and a validation command.
2. **Connect an agent** in **Settings → Connections**. **Detect agents** fills the list. Set **Default agent** under **AI agent**. Codex reuses an existing session when it can. **Sign in to Claude** opens Terminal for `claude auth login`. You can set **Claude Code executable** and **Model** (empty uses Claude Code's default). For Grok Bot, click **Connect Grok Bot**, ask your ScreenClip assistant **Connect ScreenClip**, and paste the setup code. Then turn on **Turn on for this project**. The same switch in **Settings → Projects** is **Allow sending screenshots to the external assistant**. It stays off until you turn it on. The setup code format is in [Grok Bot](agents/external-assistant.md#setup-code).
3. Press **⌘⇧2**, allow Screen Recording, select a region, and submit. Change the shortcut in Settings if you want a different one.

A native app with no bundle ID listed still routes when exactly one project's name or repository folder matches the app's name. When you pick a project for an app capture yourself, ScreenClip remembers that app's bundle ID for the project, unless another project already lists it.

Browser URL context is optional and may ask for Safari or Chrome Automation access. Without it, pick the project yourself when routing cannot decide.

ScreenClip hides its own windows during capture by default. To file a report about ScreenClip, turn off **Settings → General → Capture → Hide ScreenClip during capture** and save.

What happens after submit is in the [user guide](user-guide.md).
