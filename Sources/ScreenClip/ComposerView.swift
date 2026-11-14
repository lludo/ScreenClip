import ScreenClipCore
import SwiftUI

struct ComposerView: View {
  @ObservedObject var model: AppModel
  let image: NSImage
  let context: CaptureContext
  let existing: Issue?
  let close: () -> Void
  @StateObject private var document = AnnotationDocument()
  @State private var note = ""
  @State private var projectID: UUID?
  @State private var issueID: UUID?
  @State private var error: String?
  @State private var confirmCancel = false
  @FocusState private var noteFocused: Bool
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "viewfinder").font(.title2).foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 3) {
          Text(existing?.status == .draft ? "Finish your observation" : "What did you notice?")
            .font(.title3.weight(.semibold))
          Text(
            [
              context.appName,
              context.browserURL.flatMap { URL(string: $0)?.host } ?? context.windowTitle ?? "",
            ].filter { !$0.isEmpty }.joined(separator: " · ")
          ).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        Button {
          confirmCancel = true
        } label: {
          Image(systemName: "xmark")
        }.buttonStyle(.plain).accessibilityLabel("Close capture")
      }.padding(20)
      AnnotationCanvas(image: image, document: document).frame(
        minHeight: 220, idealHeight: 330, maxHeight: .infinity)
      HStack(spacing: 6) {
        ForEach(MarkKind.allCases, id: \.self) { kind in
          Button {
            document.tool = kind
          } label: {
            Image(systemName: symbol(kind)).frame(width: 30, height: 27)
          }
          .buttonStyle(.bordered).tint(document.tool == kind ? .orange : nil).help(
            kind.rawValue.capitalized
          )
          .accessibilityLabel(kind.rawValue.capitalized)
        }
        if document.tool == .text {
          TextField("Text to place on image", text: $document.text).textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)
        }
        Spacer()
        Button {
          document.undo()
        } label: {
          Image(systemName: "arrow.uturn.backward")
        }.disabled(document.marks.isEmpty).keyboardShortcut("z", modifiers: .command)
        Button {
          document.redo()
        } label: {
          Image(systemName: "arrow.uturn.forward")
        }.disabled(!document.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
      }.padding(.horizontal, 20).padding(.vertical, 10)
      Divider()
      VStack(alignment: .leading, spacing: 12) {
        ZStack(alignment: .topLeading) {
          if note.isEmpty {
            Text("A quick description, or just the screenshot…").foregroundStyle(.tertiary).padding(
              .top, 8
            ).padding(.leading, 5).allowsHitTesting(false)
          }
          TextEditor(text: $note).font(.body).scrollContentBackground(.hidden).frame(height: 75)
            .focused($noteFocused).accessibilityLabel("Observation description")
        }
        HStack {
          Picker("Project", selection: $projectID) {
            Text("Choose project…").tag(nil as UUID?)
            ForEach(model.snapshot.projects) { Text($0.name).tag(Optional($0.id)) }
          }.frame(maxWidth: 300).disabled(existing != nil && existing?.status != .draft)
          Picker("Issue", selection: $issueID) {
            Text("New issue").tag(nil as UUID?)
            ForEach(
              model.snapshot.issues.filter {
                !$0.archived && $0.projectID == projectID && $0.status != .draft
              }
            ) { Text($0.title).tag(Optional($0.id)) }
            if let existing, existing.status == .draft {
              Text("Current draft").tag(Optional(existing.id))
            }
          }.frame(maxWidth: 300)
        }
        if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        HStack {
          if existing == nil || existing?.status == .draft {
            Button("Save draft") { submit(draft: true) }.keyboardShortcut("s", modifiers: .command)
          }
          Spacer()
          Text("⌘ Return to submit").font(.caption).foregroundStyle(.tertiary)
          Button("Submit", action: { submit(draft: false) }).buttonStyle(.borderedProminent).tint(
            .orange
          ).keyboardShortcut(.return, modifiers: .command)
        }
      }.padding(20)
    }
    .frame(minWidth: 640, idealWidth: 780, minHeight: 560, idealHeight: 690)
    .onAppear {
      noteFocused = true
      projectID =
        existing?.projectID
        ?? ProjectRouter.infer(context, projects: model.snapshot.projects).projectID
      issueID = existing?.id
      if let existing, existing.status == .draft, let capture = existing.captures.first {
        note = capture.note
        if capture.originalPath != nil { document.marks = capture.annotations }
      }
    }
    .onChange(of: projectID) { _, _ in if existing == nil { issueID = nil } }
    .confirmationDialog(
      "Keep this capture?", isPresented: $confirmCancel, titleVisibility: .visible
    ) {
      if existing == nil || existing?.status == .draft {
        Button("Save draft") { submit(draft: true) }
      }
      Button("Discard capture", role: .destructive) { close() }
      Button("Keep editing", role: .cancel) {}
    }
  }
  private func symbol(_ tool: MarkKind) -> String {
    switch tool {
    case .arrow: return "arrow.up.right"
    case .rectangle: return "rectangle"
    case .pen: return "pencil.tip"
    case .text: return "textformat"
    case .redact: return "rectangle.fill"
    }
  }
  private func submit(draft: Bool) {
    do {
      var captured = context
      if projectID != nil
        && ProjectRouter.infer(context, projects: model.snapshot.projects).projectID != projectID
      {
        captured.routingReason = "Project selected by tester"
      }
      let data = try AnnotationRenderer.png(image: image, marks: document.marks)
      let original =
        document.marks.contains { $0.kind == .redact }
        ? nil : try AnnotationRenderer.png(image: image, marks: [])
      try model.submit(
        imageData: data, originalData: original, annotations: document.marks, note: note,
        context: captured, projectID: projectID, existingID: issueID, draft: draft)
      close()
    } catch { self.error = error.localizedDescription }
  }
}
