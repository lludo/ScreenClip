import AppKit
import ScreenClipCore
import SwiftUI
import UniformTypeIdentifiers

/// Adds text and image evidence to a report after it was filed.
struct ContextNoteEditor: View {
  @ObservedObject var model: AppModel
  let issueID: UUID
  /// Opened from Needs follow-up on a merged or verified report: the note is the feedback for
  /// another fix.
  var followUp = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @State private var text = ""
  @State private var attachments: [ContextImageAttachment] = []
  @State private var loading = false
  @State private var dropTargeted = false
  @State private var choosingImages = false
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
          Text(
            chrome: "Additional context", comment: "Accessibility label for the context note field."
          ))
      attachmentEditor
      Text(verbatim: contextHint).font(.caption)
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let error {
        Text(verbatim: Chrome.stored(error, locale: locale)).font(.callout).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button(role: .cancel) {
          dismiss()
        } label: {
          Text(chrome: "Cancel", comment: "Closes the context note editor without saving.")
        }.keyboardShortcut(.cancelAction)
        Button {
          do {
            try model.addContext(
              issueID, text: text, images: attachments.map(\.data), followUp: followUp)
            dismiss()
          } catch { self.error = error.localizedDescription }
        } label: {
          if followUp {
            Text(
              chrome: "Request follow-up", comment: "Saves a follow-up note and starts another fix."
            )
          } else {
            Text(chrome: "Save context", comment: "Saves additional context on the report.")
          }
        }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
          .disabled(
            loading
              || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && attachments.isEmpty)
          )
      }
    }.padding(24).frame(minWidth: 460, idealWidth: 520)
      .onAppear { focused = true }
  }
  private var attachmentEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        choosingImages = true
      } label: {
        Label {
          Text(chrome: "Drop images here or choose images…", comment: "Context image drop area.")
        } icon: {
          Image(systemName: "photo.badge.plus")
        }
        .frame(maxWidth: .infinity).padding(12)
      }.buttonStyle(.plain)
        .background(
          dropTargeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 6))
      if loading { ProgressView().controlSize(.small) }
      if !attachments.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 12) {
            ForEach(attachments) { attachment in
              VStack(spacing: 4) {
                Image(nsImage: attachment.image).resizable().scaledToFit()
                  .frame(width: 120, height: 90)
                Button {
                  attachments.removeAll { $0.id == attachment.id }
                } label: {
                  Label {
                    Text(chrome: "Remove image", comment: "Removes a pending image attachment.")
                  } icon: {
                    Image(systemName: "xmark.circle")
                  }
                }.buttonStyle(.borderless)
              }
            }
          }
        }.frame(height: 120)
      }
    }
    .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
      guard !loading else { return false }
      loading = true
      Task { @MainActor in
        defer { loading = false }
        for provider in providers {
          do {
            let data: Data
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
              let urlData = try await load(provider, type: UTType.fileURL.identifier)
              guard let url = URL(dataRepresentation: urlData, relativeTo: nil), url.isFileURL
              else {
                throw ScreenClipError.message("Unable to load image attachment.")
              }
              let accessing = url.startAccessingSecurityScopedResource()
              defer { if accessing { url.stopAccessingSecurityScopedResource() } }
              data = try Data(contentsOf: url)
            } else if let type = provider.registeredTypeIdentifiers.first(where: {
              UTType($0)?.conforms(to: .image) == true
            }) {
              data = try await load(provider, type: type)
            } else {
              throw ScreenClipError.message("Unable to load image attachment.")
            }
            try appendImage(data)
          } catch { self.error = error.localizedDescription }
        }
      }
      return true
    }
    .fileImporter(
      isPresented: $choosingImages, allowedContentTypes: [.image], allowsMultipleSelection: true
    ) { result in
      do {
        for url in try result.get() {
          let accessing = url.startAccessingSecurityScopedResource()
          defer { if accessing { url.stopAccessingSecurityScopedResource() } }
          try appendImage(Data(contentsOf: url))
        }
      } catch { self.error = error.localizedDescription }
    }
  }
  private func appendImage(_ data: Data) throws {
    guard let image = NSImage(data: data), NSBitmapImageRep(data: data) != nil else {
      throw ScreenClipError.message("Unable to load image attachment.")
    }
    attachments.append(ContextImageAttachment(data: data, image: image))
  }
  private func load(_ provider: NSItemProvider, type: String) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
        if let data {
          continuation.resume(returning: data)
        } else {
          continuation.resume(
            throwing: error ?? ScreenClipError.message("Unable to load image attachment."))
        }
      }
    }
  }
  private var contextHint: String {
    guard let issue = model.issue(issueID) else { return "" }
    let comment: StaticString = "Hint under the added-context field: when the note takes effect."
    if issue.dispatchUncertain {
      return Chrome.text(
        "Your note will be included after the chat is reconciled.", locale: locale, comment: comment)
    }
    switch issue.status {
    case .draft:
      return Chrome.text("Your note stays with this draft until you submit it.", locale: locale, comment: comment)
    case .needsProject:
      return Chrome.text("Choose a project in the report before work can begin.", locale: locale, comment: comment)
    case .working:
      return Chrome.text(
        "Your note will be included in follow-up work after the current work finishes.", locale: locale,
        comment: comment)
    case .needsYou:
      return Chrome.text(
        "Your note will be included when work continues. Answer any pending questions in the report.",
        locale: locale, comment: comment)
    default:
      return Chrome.text("Saving queues this report with your added context.", locale: locale, comment: comment)
    }
  }
}

private struct ContextImageAttachment: Identifiable {
  let id = UUID()
  let data: Data
  let image: NSImage
}
