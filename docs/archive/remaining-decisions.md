# Remaining decisions (archived)

This table lived in the product specification as open questions, with proposed defaults, while the local app was still being built. The questions are closed. The specification's [Decisions](../product-spec.md#decisions) section is the short record. This page keeps the original wording.

| Question | Proposed default at the time | What shipped |
| --- | --- | --- |
| Which source-control host first? | GitHub, behind a provider interface | GitHub only, through `GitHubService` and `gh`. There is no second host. |
| Which browsers first? | Safari and Chrome; confirm how URL access is granted | Safari and Chrome. The optional URL read uses Apple Events and is off until **Read the active browser URL for project matching** is on. |
| Local execution or a hosted plugin/event service? | Local agents first; the read-only plugin is a companion | Codex and Claude Code run locally. Grok Bot is a remote webhook. The MCP plugin stays read-only and optional. |
| Should a merge refresh or relaunch the app under test? | Notify and offer a retest; keep the testing session stable | Merged reports move to **To retest**. ScreenClip does not relaunch the app under test or update the tester's checkout. |
| Can the agent ask and receive replies inside ScreenClip? | Yes, with a link to the agent's own conversation | Codex and Claude Code questions are answered in ScreenClip. Grok Bot questions stay in Grok Bot's chat. |
| What happens to old screenshots and notes? | Retain them locally until deletion; add a retention policy before public release | They stay until you delete the report. There is still no automatic expiry. That gap is on the [roadmap](../roadmap.md). |
| Minimum supported macOS? | macOS 14 or later, once the APIs are checked | macOS 14. `LSMinimumSystemVersion` is `14.0`. The Homebrew cask depends on Sonoma. |
| Distribution channel? | A signed, notarized download first; evaluate the App Store separately | A notarized GitHub Release DMG. The Mac App Store build was evaluated and dropped. See [Release and distribution](../release/README.md). |
| Product name, shortcut, and pricing? | ScreenClip as a working name; configurable shortcut; pricing undecided | The name is ScreenClip. The default shortcut is ⌘⇧2 and it is configurable. The download is free. An optional tip window links to GitHub Sponsors; that profile is not ready ([open TODOs](../open-source.md#open-todos)). |
