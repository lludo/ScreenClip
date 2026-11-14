import ScreenClipCore
import SwiftUI

/// Adds a text note to a report after it was filed.
struct ContextNoteEditor: View {
  @ObservedObject var model: AppModel
  let issueID: UUID
  /// Opened from Needs follow-up on a merged or verified report: the note is the feedback for
  /// another fix.
  var followUp = false
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var error: String?
  @FocusState private var focused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        (followUp ? "Request a follow-up" : "Add context")
          + (model.issue(issueID)?.reportReference.map { (followUp ? " on " : " to ") + $0 } ?? "")
      ).font(.headline)
      Text(
        followUp
          ? "Describe what was not addressed or still looks wrong."
          : "Describe what you noticed or add details you missed when filing."
      ).foregroundStyle(.secondary)
      TextEditor(text: $text).font(.body).focused($focused)
        .padding(6).frame(height: 150)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
        .accessibilityLabel("Additional context")
      Text(contextHint).font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).font(.callout).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(followUp ? "Request follow-up" : "Save context") {
          do {
            try model.addContext(issueID, text: text, followUp: followUp)
            dismiss()
          } catch { self.error = error.localizedDescription }
        }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 460)
      .onAppear { focused = true }
  }
  private var contextHint: String {
    guard let issue = model.issue(issueID) else { return "" }
    if issue.dispatchUncertain {
      return "Your note will be included after the chat is reconciled."
    }
    switch issue.status {
    case .draft: return "Your note stays with this draft until you submit it."
    case .needsProject: return "Choose a project in the report before work can begin."
    case .working:
      return "Your note will be included in follow-up work after the current work finishes."
    case .needsYou:
      return
        "Your note will be included when work continues. Answer any pending questions in the report."
    default: return "Saving queues this report with your added context."
    }
  }
}
