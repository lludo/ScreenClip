# Mac App Store sandbox

**Verdict: do not ship ScreenClip on the Mac App Store.** The sandbox would block the product. Codex, Claude Code, `git`, `gh`, and the project's validation command all run as child processes in the user's repositories, and a sandboxed child inherits the sandbox. There is no App Store-legal way to give those tools the user's Homebrew binaries, `~/.codex`, `~/.claude`, `~/.gitconfig`, SSH keys, and `gh` credentials. A companion helper would be the same conclusion: the app would not work without software App Review does not want a Mac App Store app to require.

Ship the unsandboxed, notarized app from GitHub Releases instead. That path is [direct distribution](direct-distribution.md). This note records why the sandbox fails, what would have worked, and the runtime check. No App Store build configuration or scheme was added.

## What ScreenClip actually runs

Every external command goes through `Process` in `CommandRunner`, `CodexClient`, `ClaudeCodeClient`, or the relaunch helper in `ScreenClipApp`. The child gets `ProcessEnvironment.tools()`, which prepends `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` and otherwise keeps the parent's environment (including `HOME`).

| Work | Executable | What it has to touch |
| --- | --- | --- |
| Codex | User-installed `codex` (`/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, or the ChatGPT.app copy), then `app-server --listen stdio://` | Codex's own config under `~/.codex`, the repo, and the network |
| Claude Code | `claude` on Homebrew, `/usr/local/bin`, `~/.local/bin`, `~/.claude/local`, npm, or bun | `~/.claude`, a browser login, and the repo. Sign-in writes a `.command` file and opens it with `NSWorkspace` so Terminal can run `claude auth login` |
| Git | Hard-coded `/usr/bin/git` | The chosen repo, its `.git`, remotes, and a worktree under Application Support. `git worktree add` writes into the repo's git dir |
| GitHub CLI | `AppSettings.ghPath`, default `/opt/homebrew/bin/gh` | `gh auth status`, pull requests, merges, and `~/.config/gh` |
| Validation | `/bin/zsh -c` with the project's command, 10 minute timeout | Whatever the user typed: `npm`, `python3`, `swift test`, and the files those tools read |
| Grok Bot evidence | The same `/usr/bin/git` and `gh` path | A `screenclip/` branch, commit, fetch, and push, then one HTTPS POST |
| Relaunch | `/bin/sh` waiting, then `/usr/bin/open` | The app bundle |

Project folders are a path string. `ProjectEditor` uses `NSOpenPanel` and stores `url.path`. It does not create a security-scoped bookmark and does not call `startAccessingSecurityScopedResource`. The same is true of the executable chooser in Settings. After relaunch, nothing in the app holds a sandbox extension for that folder.

The shipping entitlements file is only `com.apple.security.automation.apple-events`. Debug builds set `ENABLE_APP_SANDBOX = NO` and `ENABLE_HARDENED_RUNTIME = NO`. Release builds set `ENABLE_APP_SANDBOX = NO` and `ENABLE_HARDENED_RUNTIME = YES`. The bundle id is `com.mirageteam.screenclip`. The app is a menu-bar agent (`LSUIElement`) and uses ScreenCaptureKit, `RegisterEventHotKey`, the Keychain, `SMAppService.mainApp`, and a SQLite file under Application Support.

## 1. User-installed binaries

A sandboxed Mac App Store app cannot do this job by spawning the user's CLIs.

Apple's file-sandbox documentation says an app cannot run programs outside its bundle, its container, or an app-group container by using the user-selected-file entitlements. The separate `com.apple.security.files.user-selected.executable` entitlement is for writing executables into a folder the user picked, not for launching Homebrew. Source: [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

A child created with `Process` or `posix_spawn` inherits the parent's sandbox. Apple's helper-tool guide says a bundled helper must be signed by the same team and carry only `com.apple.security.app-sandbox` and `com.apple.security.inherit`. That inheritance does not apply to `/opt/homebrew/bin/codex` or `~/.local/bin/claude`, because ScreenClip does not sign those binaries and cannot add entitlements to them. Sources: [Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app) and [Enabling App Sandbox](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html). Apple DTS has also been explicit that a child inherits the sandbox whether or not it has the `inherit` entitlement; that entitlement is how a bundled helper avoids opening a second sandbox, and App Review looks for it. The older inherit note says the child receives the parent's static entitlements, not Powerbox access granted after launch (the open panel). Either reading leaves Codex, Claude, git, and gh inside the sandbox.

On current macOS, `/usr/bin/git` is not Git. It is an `xcrun` shim, and `xcrun` refuses to run in an App Sandbox (`xcrun: error: cannot be used within an App Sandbox`). The 2026 Quay write-up hit this while shipping a much narrower Git client, and worked around it by calling the real binary inside Command Line Tools or Xcode, then authenticating with HTTPS instead of `~/.ssh`. ScreenClip also needs arbitrary user binaries, so that workaround does not transfer. Quay's write-up: [A sandboxed app walks into /usr/bin/git](https://code.sailorslog.io/blog/2026-04-10-quay/).

What breaks even if a launch succeeds:

- The child cannot read `~/.codex`, `~/.claude`, `~/.gitconfig`, `~/.ssh`, or `~/.config/gh`. Those directories are outside the container. Codex and Claude then have no login. Git and `gh` have no credentials. SSH cannot see the keys.
- Homebrew prefixes (`/opt/homebrew`, `/usr/local` for Intel) are outside the default sandbox read set. A node or bun launcher that execs another binary, or that loads libraries from the prefix, fails the next `exec` or `dyld` load.
- The child does not receive the parent's security-scoped bookmark. Pointing `cwd` at a repo the user selected does not let `git` write `.git/worktrees` or let `npm test` read the tree.
- `ProcessEnvironment` keeps `HOME`, so the tools look in the real home directory and get `EPERM`, not a quiet fallback.
- Validation is an arbitrary zsh command. Allowing that inside the sandbox would still deny the compilers, package managers, and temp files the command expects. Allowing it outside the sandbox is the unsandboxed app.

### Paths that are not App Store-legal for this app

**Temporary exception entitlements.** `com.apple.security.temporary-exception.files.home-relative-path.read-write` and the absolute-path variant can name specific files. Apple calls them temporary, requires a Feedback Assistant bug when they stand in for a missing sandbox feature, and requires a written justification in App Store Connect. A list that covered `/.codex/`, `/.claude/`, `/.ssh/`, `/.config/gh/`, `/.gitconfig`, and every repository path is a request for the home directory. App Review's own checklist says not to use a file exception to skip the open panel, and not to depend on files the app did not create. Sources: [App Sandbox Temporary Exception Entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html), [App Sandbox information](https://developer.apple.com/help/app-store-connect/reference/app-uploads/app-sandbox-information/), and [QA1773](https://developer.apple.com/library/archive/qa/qa1773/_index.html).

**Security-scoped bookmarks.** They are the supported way to remember a folder the user picked. They do not grant execute permission on that folder, and they do not extend to the tool's private config in `~`. ScreenClip would still have to spawn git inside a sandbox that cannot read SSH keys. Bookmarks are necessary for a sandboxed editor. They are not sufficient for a git-and-agent worker.

**Bundled helpers and XPC.** An embedded git or gh would be a second copy, still sandboxed, still unable to read `~/.ssh` or the user's Codex login. XPC is privilege separation inside the app's sandbox, not a tunnel out of it. [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox) describes that boundary.

**A non-sandboxed companion.** Guideline 2.4.5(ii) requires a self-contained app that does not install code into shared locations. Guideline 2.4.5(iv) says the app may not download or install additional code to add functionality or to change what review saw. Requiring a Homebrew formula or a GitHub helper, then talking to it over a socket, is how some unsandboxed developer tools are built. It is a poor fit for an app whose main feature does not work until that helper is installed, and review can reject it as incomplete or as circumventing the sandbox. Alfred's Powerpack left the Mac App Store for this class of reason: the product runs the user's scripts and talks to the rest of the Mac. Source: [Alfred and the Mac App Store](https://www.alfredapp.com/blog/announcements/alfred-powerpack-and-the-mac-app-store-or-not/). iTerm2, Ghostty, Visual Studio Code, Tower, Fork, and GitHub Desktop are distributed outside the store for the same constraint.

Opening Terminal on a `.command` file, which ScreenClip does for Claude login, is not a general escape hatch. The script lives in the container, Terminal is a different app, and guideline 2.4.5(iv) still applies. It only covers an interactive login, not the worker.

## 2. Repositories and worktrees

`GitWorkspace.prepare` checks that the chosen path is the repo root, then runs `git worktree add` so the worktree lives under Application Support (`<data>/worktrees/<uuid>`) and the branch metadata lives in the repo's `.git`. In a sandbox:

- The open panel plus `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope` can grant the app itself access to that folder, if ScreenClip actually persisted a bookmark. It does not today.
- `/usr/bin/git` is the `xcrun` shim and fails in the sandbox. The real `git` from Command Line Tools can be spawned only if that binary is readable and executable. It still inherits the sandbox, so it still needs a sandbox extension for the repo. The parent's bookmark is not handed to the child.
- `git fetch` and `git push` need either SSH keys or a credential helper. Both live outside the container. Quay's approach (HTTPS plus a token the app supplies, `GIT_TERMINAL_PROMPT=0`) can push from a sandboxed git for a GitHub client that never runs user code. ScreenClip's validation command and the coding agents are user code.

So "NSOpenPanel plus bookmarks, and git keeps working" is not true for this app.

## 3. Capture, hotkey, Keychain, login

These four do not need a companion, and they would survive a sandbox. They are not the features that decide the store question.

**Screen capture.** `CaptureCoordinator` calls `SCShareableContent` and `SCScreenshotManager`. `Info.plist` already has `NSScreenCaptureUsageDescription`. Screen Recording is a separate TCC prompt, not a sandbox entitlement. Sandboxed apps can capture after the user allows it. The current entitlement file does not need a new key for this.

**Global hotkey.** `GlobalShortcut` uses Carbon `RegisterEventHotKey` on the application event target. That is not a `CGEvent` tap and does not need the Accessibility entitlement. Sandboxed menu-bar apps use this API. No change would be required.

**Keychain.** `ExternalAssistantKeychain` stores one generic password (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) under the service `com.screenclip.app.external-assistant`. A sandboxed app can read and write its own items with no extra entitlement. The items are partitioned to the app. This does not let ScreenClip read the GitHub CLI's keychain items, and the CLI could not read ScreenClip's.

**Launch at login.** Settings calls `SMAppService.mainApp.register()` only when the user turns the switch on. That API is the supported login item for a sandboxed app on macOS 13 and later. Guideline 2.4.5(iii) forbids launching at login without consent; the switch is the consent. [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).

**Also fine, with one caveat.** The SQLite queue uses the Application Support directory. In a sandbox that URL is redirected into `~/Library/Containers/com.mirageteam.screenclip/`. The database would keep working, at a new path. User notifications work after the normal permission prompt. Outbound HTTPS needs `com.apple.security.network.client`.

**Browser URL.** `NSAppleScript` asks Safari or Chrome for the active tab, and only when the preference is on. The hardened-runtime entitlement is already present. A sandbox also needs `com.apple.security.temporary-exception.apple-events` listing `com.apple.Safari` and `com.google.Chrome`. QA1773 says the list has to be specific. Review has accepted that exception for apps that read one browser fact, but it is a temporary exception and it would have to be justified in App Store Connect. It is optional product behavior, not the store blocker.

## 4. What would work unchanged

Inside a sandbox, without new code, these pieces already stay in-process:

- Region capture, annotation, redaction, the queue, search, archive, drafts, and project routing that does not need the browser.
- The local SQLite store, inside the container.
- The app's own Keychain item, the global hotkey, the login-item toggle, and notifications.
- The Grok Bot HTTP POST itself (`URLSession` in `ExternalAssistantClient`), once `network.client` is set and the webhook and header are in the Keychain.

These do not work unchanged:

- Codex and Claude Code dispatch, including Claude sign-in.
- Every `git` and `gh` call: worktrees, validation, pull requests, merges, and the Grok Bot evidence branch.
- The validation command.
- The MCP plugin's default data path. The plugin is a Python process Codex or Claude starts. It reads `~/Library/Application Support/ScreenClip`. A sandboxed app would write the container path instead, so the plugin would see an empty queue unless it were pointed at the container. The plugin is not part of the App Store binary.

A "lite" store app that only posted the webhook and uploaded files with the GitHub REST API (a personal access token in the Keychain, no git CLI) is possible. It would drop local agents, worktrees, validation, and merges. That is a different product, and it still would not run Codex or Claude. It is not worth a second build.

## Runtime check

`scripts/sandbox-diagnostic.sh` compiles `scripts/sandbox-diagnostic.swift` into a tiny app, ad-hoc signs it with `scripts/sandbox-diagnostic.entitlements`, and runs it. Those entitlements are the set a store build would have started from: `com.apple.security.app-sandbox`, `network.client`, `files.user-selected.read-write`, and `files.bookmarks.app-scope`. There is no ScreenClip-AppStore configuration or scheme. The macOS CI job runs the script so the result is from Apple's sandbox, not from a seatbelt approximation.

The user-selected entitlement does not, by itself, open any folder. The diagnostic never shows an open panel, so this is the static sandbox a launched app has before the user picks a directory.

Results from the macOS 15 runner are in the section below once CI has recorded them. If this paragraph is still a placeholder, the job log for "App Sandbox diagnostic" on the pull request is the source.

<!-- sandbox-diagnostic-results -->
Pending the macOS CI run on this branch.
<!-- /sandbox-diagnostic-results -->

## What was not added

An Xcode configuration named AppStore, a shared scheme, and `ENABLE_APP_SANDBOX = YES` on the ScreenClip target were considered and skipped. Shipping that configuration would let a Release-looking build be sandboxed by accident. `scripts/release-dmg.sh` refuses to notarize an app whose signature contains `com.apple.security.app-sandbox`.

Direct distribution keeps the current Release settings: hardened runtime on, App Sandbox off, Apple Events entitlement on.
