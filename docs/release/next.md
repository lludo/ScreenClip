# Next ScreenClip release

You can report a screenshot you took earlier on your iPhone or iPad. Your app can supply its own diagnostic files, and a coding agent can suggest project settings for you to review on the Mac.

## New

- In the iOS report sheet, tap the photo button to choose an existing screenshot. The Mac shows that it came from Photos and includes its capture date when available. The live screen’s view tree is omitted for these reports.
- Apps can use `ScreenClipKit.setAttachmentProvider` to attach text or JSON files. **Attach logs and diagnostics** controls whether providers run and whether their files are sent. [SDK guide](https://screenclipai.com/ios)
- Claude Code and Codex can propose a validation command or base branch. Review the suggestion in the menu bar popover or the project’s settings. Accepting a validation command continues reports waiting for one.

## Fixes

- Pull request descriptions keep their Before and After screenshots. ScreenClip removes its evidence folder from the pull request head before merging.
- Captures preserve the app’s contents when a transparent system window covers the scene, including on iPad.
- Local fixes now incorporate the latest base branch before project validation. A binary conflict stays open until it is resolved.
- The menu bar shows a red dot when a report or project setting needs attention. Project settings fit within the sheet, including longer translated labels.
- Reinstalling a Debug app on the same device preserves its pairing when the pairing keys remain in the Keychain.
- The iOS composer keeps the note above the keyboard and provides larger annotation controls. Exported screenshots use the device’s corner shape when the original dimensions match.
