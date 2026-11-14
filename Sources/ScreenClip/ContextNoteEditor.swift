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
  @Environment(\.locale) private var locale
  @State private var text = ""
  @State private var error: String?
  @FocusState private var focused: Bool
  private var title: String {
    let reference = model.issue(issueID)?.reportReference
    if followUp {
      if let reference {
        return Chrome.format(
          "context.followUpOn", "Request a follow-up on \(reference)", locale: locale,
          comment: "Follow-up sheet title. %@ is the report number, such as #26.")
      }
      return Chrome.text("Request a follow-up", locale: locale, comment: "Follow-up sheet title.")
    }
    if let reference {
      return Chrome.format(
        "context.addTo", "Add context to \(reference)", locale: locale,
        comment: "Context sheet title. %@ is the report number.")
    }
    return Chrome.text("Add context", locale: locale, comment: "Context sheet title.")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(verbatim: title).font(.headline).fixedSize(horizontal: false, vertical: true)
      Group {
        if followUp {
          Text(
            chrome: "Describe what was not addressed or still looks wrong.",
            comment: "Follow-up note instructions.")
        } else {
          Text(
            chrome: "Describe what you noticed or add details you missed when filing.",
            comment: "Additional context instructions.")
        }
      }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      TextEditor(text: $text).font(.body).focused($focused)
        .padding(6).frame(height: 150)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
        .accessibilityLabel(
          Text(chrome: "Additional context", comment: "Accessibility label for the context note field."))
      Text(verbatim: Chrome.stored(contextHint, locale: locale)).font(.caption)
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let error {
        Text(verbatim: Chrome.stored(error, locale: locale)).font(.callout).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button(role: .cancel) { dismiss() } label: {
          Text(chrome: "Cancel", comment: "Closes the context note editor without saving.")
        }.keyboardShortcut(.cancelAction)
        Button {
          do {
            try model.addContext(issueID, text: text, followUp: followUp)
            dismiss()
          } catch { self.error = error.localizedDescription }
        } label: {
          if followUp {
            Text(chrome: "Request follow-up", comment: "Saves a follow-up note and starts another fix.")
          } else {
            Text(chrome: "Save context", comment: "Saves additional context on the report.")
          }
        }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(minWidth: 460, idealWidth: 520)
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
