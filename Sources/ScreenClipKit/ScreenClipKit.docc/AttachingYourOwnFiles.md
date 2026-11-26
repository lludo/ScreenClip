# Attaching your own files

Add your app's own state to every report, so the agent sees what the screenshot can't show.

## Overview

Your app knows things ScreenClip can't see: the signed-in account, what's in the cart, which feature flags are on, the last request the backend answered. Register an attachment provider and its files travel with every report, next to the built-in <doc:Diagnostics>.

```swift
#if DEBUG
ScreenClipKit.setAttachmentProvider("cart") { context in
  let cart = await MainActor.run { CartStore.shared.snapshot }  // any Encodable
  return [try .json(cart, name: "cart", summary: "the cart's \(cart.items.count) items and promo codes")]
}
#endif
```

The agent reads each file's name and summary in its prompt. It opens a file only when the screenshot and note aren't enough, so write the summary for it: say what is inside.

### When the provider runs

The provider starts when the report sheet opens, not when the tester taps **Send**:

- Its data matches the screen the tester captured, not whatever the app shows a minute later.
- Slow work, such as a network call, a database read, or a file on disk, overlaps the time the tester spends marking up.

After **Send**, ScreenClip waits up to `timeout` more (5 seconds by default, at most 30) with **Saving report…** on screen. It then sends the report without whatever hasn't arrived.

The provider runs off the main actor. Read main-actor state with `await MainActor.run { … }`, and keep heavy work out of that closure.

### Several files, async work, and context

A provider returns any number of attachments. Return an empty array to add nothing this time.

```swift
ScreenClipKit.setAttachmentProvider("account", timeout: .seconds(10)) { context in
  let session = await MainActor.run { Session.current }
  guard let session else { return [] }
  let flags = try await FeatureFlags.shared.current()
  APILog.shared.mark("ScreenClip report \(context.reportID)")
  return [
    try .json(session.debugSummary, name: "account", summary: "signed-in account, plan, and region"),
    .text(flags.description, name: "feature-flags", summary: "remote feature flags in effect"),
    .text(await APILog.shared.recent(20), name: "api-requests", summary: "last 20 backend requests and status codes"),
  ]
}
```

``ScreenClipReportContext`` carries the report's `reportID`, `capturedAt`, `screenTitle`, and `screenPath`. Log the report id next to your own records, such as a backend request id or an analytics session, to tie them to the report.

### Cancellation and failure

- The provider is cancelled when the tester cancels the report, or turns off **Attach logs and diagnostics**. Use cancellable APIs or check `Task.isCancelled`.
- If the provider throws or misses its timeout, only its own files are left out. The report is still sent, and a line is logged under the `ScreenClipKit` subsystem.

### Registering and removing

Each id holds one provider. Registering the same id again replaces it, so calling ``ScreenClipKit/ScreenClipKit/setAttachmentProvider(_:timeout:_:)`` from an initializer or `onAppear` is safe. ``ScreenClipKit/ScreenClipKit/removeAttachmentProvider(_:)`` removes it. Providers run concurrently, and their files are listed in registration order.

### Names and limits

- `name` becomes a file name the Mac accepts. It is lowercased, anything other than letters, digits, and `-` becomes `-`, and it is cut to 32 characters, plus `.txt` or `.json`. A name already in use, such as `logs.txt` or another provider's, gets `-2`, `-3`, and so on.
- Each attachment can be up to 1 MB (``ScreenClipAttachment/maximumBytes``). Larger ones are left out.
- All files in a report share a 4 MB limit. When a report is over it, the largest files are dropped first.

### What not to attach

Don't attach secrets. On the Mac, token-like strings are hidden in text files, but JSON files are stored as sent. Any attached file can be read by an agent working on the report.

In Release builds ``ScreenClipKit/ScreenClipKit/setAttachmentProvider(_:timeout:_:)`` does nothing, and the closure is never called. Keep the call inside `#if DEBUG` anyway, so the code that gathers the data stays out of Release too.
