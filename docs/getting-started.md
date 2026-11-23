# Getting started

ScreenClip runs on **macOS 14 or later**. A local build needs **Xcode 16 or later**. The Swift package uses tools version 6.0 and the Swift 5 language mode. `Package.swift` has no external dependencies. The Xcode app target adds [Sparkle 2](https://sparkle-project.org) for automatic updates, which Xcode fetches on the first build. SQLite comes from the system through `Sources/CSQLite`.

You also need a local Git repository for each project, and at least one agent:

- **Codex CLI**, with `app-server`
- **Claude Code**
- **Grok Bot**, connected with the Webhook URL and Authorization header from its ScreenClip reports routine

**GitHub CLI** (`gh`) is required to open and merge pull requests, and to push screenshots for Grok Bot.

## Install the release build

On an Apple Silicon Mac you do not need Xcode. Download `ScreenClip.dmg` from the [latest GitHub Release](https://github.com/lludo/ScreenClip/releases/latest), open it, and drag **ScreenClip** into **Applications**. The [1.0.0 release notes](release/v1.0.0.md) cover what is included (later changes are in the [1.0.1](release/v1.0.1.md), [1.0.2](release/v1.0.2.md), [1.0.3](release/v1.0.3.md), [1.0.4](release/v1.0.4.md) and [1.0.5](release/v1.0.5.md) notes) and how to verify the download. Then skip to [First capture](#first-capture).

Intel Macs, and anyone working on ScreenClip itself, build from source.

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
2. **Connect an agent** in **Settings → Connections**. **Detect agents** fills the list. Set **System default** under **AI agent**. In **Project settings**, **Project default** starts as **System default**.
   - **Codex** reuses an existing session when it can.
   - **Claude Code:** **Sign in to Claude Code** opens Terminal for `claude auth login`. You can set **Claude Code executable** and **Model** (empty uses Claude Code's default).
   - **Grok Bot:** open the **Grok Bot** section, click **Connect Grok Bot**, copy **POST to** and **key** (or **header**) from the assistant's **ScreenClip reports** routine, and click **Connect**. The webhook fields are described in [Grok Bot](agents/external-assistant.md#webhook-and-key).
3. Press **⌘⇧2**, allow Screen Recording, select a region, and submit. Change the shortcut in Settings if you want a different one.

A native app with no bundle ID listed still routes when exactly one project's name or repository folder matches the app's name. When you pick a project for an app capture yourself, ScreenClip remembers that app's bundle ID for the project, unless another project already lists it.

Browser URL context is optional and may ask for Safari or Chrome Automation access. Without it, pick the project yourself when routing cannot decide.

ScreenClip hides its own windows during capture by default. To file a report about ScreenClip, turn off **Settings → General → Capture → Hide ScreenClip during capture** and save.

Submitted screenshots are published to the project's GitHub repository, in the fix pull request or on Grok Bot's evidence branch. There is no per-project switch. Redact anything private before you submit. See [What each agent can see](user-guide.md#what-each-agent-can-see).

What happens after submit is in the [user guide](user-guide.md).
