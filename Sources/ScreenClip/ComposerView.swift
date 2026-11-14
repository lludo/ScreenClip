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
  @State private var agent: AgentKind = .codex
  @State private var error: String?
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
      }.padding(20)
      HStack(spacing: 6) {
        ForEach(MarkKind.allCases, id: \.self) { kind in
          Button {
            document.tool = kind
          } label: {
            Image(systemName: symbol(kind)).frame(width: 36, height: 30)
              .foregroundStyle(document.tool == kind ? Color.orange : Color.primary)
              .background(
                document.tool == kind ? Color.orange.opacity(0.14) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 6)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(
                  document.tool == kind ? Color.orange.opacity(0.4) : .clear, lineWidth: 1))
          }
          .buttonStyle(.plain).help(
            kind.rawValue.capitalized
          )
          .accessibilityLabel(kind.rawValue.capitalized)
        }
        Divider().frame(height: 22).padding(.horizontal, 4)
        Menu {
          ForEach(MarkColor.allCases, id: \.self) { color in
            Button {
              document.color = color
            } label: {
              Label(
                color.rawValue.capitalized,
                systemImage: document.color == color ? "checkmark.circle.fill" : "circle.fill"
              )
              .foregroundStyle(Color(nsColor: color.nsColor))
            }
          }
        } label: {
          Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: document.color.nsColor))
            .overlay(Circle().stroke(.primary.opacity(0.3), lineWidth: 0.5))
        }.frame(width: 46).help("Annotation color").accessibilityLabel(
          "Annotation color: " + document.color.rawValue
        )
        .disabled(document.tool == .redact)
        Picker("Stroke", selection: $document.lineWidth) {
          Text("Thin").tag(0.003)
          Text("Medium").tag(0.006)
          Text("Bold").tag(0.012)
        }.labelsHidden().frame(width: 104).help("Stroke thickness").accessibilityLabel(
          "Stroke thickness"
        )
        .disabled(document.tool == .redact || document.tool == .text)
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
      if document.tool == .text {
        TextField("Type a label, then click on the image to place it", text: $document.text)
          .textFieldStyle(.roundedBorder).padding(.horizontal, 20).padding(.bottom, 10)
      }
      Divider()
      AnnotationCanvas(image: image, document: document).frame(
        minHeight: 160, idealHeight: 330, maxHeight: .infinity)
      Divider()
      ZStack(alignment: .topLeading) {
        if note.isEmpty {
          Text("A quick description, or just the screenshot…").foregroundStyle(.tertiary).padding(
            .top, 8
          ).padding(.leading, 5).allowsHitTesting(false)
        }
        TextEditor(text: $note).font(.body).scrollContentBackground(.hidden).frame(height: 75)
          .focused($noteFocused).accessibilityLabel("Observation description")
      }.padding(20)
      Divider()
      VStack(alignment: .leading, spacing: 12) {
        GeometryReader { geometry in
          HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
              Text("Project").font(.caption).foregroundStyle(.secondary)
              Picker("Project", selection: $projectID) {
                Text("Choose project…").tag(nil as UUID?)
                ForEach(model.snapshot.projects) {
                  Label($0.name, systemImage: $0.displaySymbol).tag(Optional($0.id))
                }
              }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Project")
                .disabled(existing != nil && existing?.status != .draft)
            }.frame(width: max(0, (geometry.size.width - 40) / 3), alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
              Text("Issue").font(.caption).foregroundStyle(.secondary)
              Picker("Issue", selection: $issueID) {
                Text("New issue").tag(nil as UUID?)
                ForEach(
                  model.snapshot.issues.filter {
                    !$0.archived && $0.projectID == projectID && $0.status != .draft
                  }
                ) { Text($0.referencedTitle).tag(Optional($0.id)) }
                if let existing, existing.status == .draft {
                  Text(existing.reportReference.map { "Current draft \($0)" } ?? "Current draft")
                    .tag(Optional(existing.id))
                }
              }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Issue")
            }.frame(width: max(0, (geometry.size.width - 40) / 3), alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
              Text("Agent").font(.caption).foregroundStyle(.secondary)
              Picker("Agent", selection: $agent) {
                if agentChoices.isEmpty && lockedAgent == nil {
                  Text(model.detectingAgents ? "Checking agents…" : "No agents available").tag(agent)
                } else {
                  ForEach(agentChoices, id: \.self) { kind in
                    AgentLabel(kind: kind).tag(kind)
                  }
                }
              }
              .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
              .disabled(lockedAgent != nil || agentChoices.isEmpty)
              .accessibilityLabel("Agent")
              .help(
                lockedAgent != nil
                  ? "Follow-up captures continue with the issue's existing agent."
                  : "Which agent works on this report.")
            }.frame(width: max(0, (geometry.size.width - 40) / 3), alignment: .leading)
          }
        }
        .frame(height: 52)
        if lockedAgent == .external, let hint = externalAvailability.hint {
          Text(hint).font(.caption).foregroundStyle(.orange)
        }
        if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        HStack {
          if canSaveDraft {
            Button("Save draft") { submit(draft: true) }.keyboardShortcut("s", modifiers: .command)
          }
          Spacer()
          Text("⌘ Return to submit").font(.caption).foregroundStyle(.tertiary)
          Button("Submit", action: { submit(draft: false) }).buttonStyle(.borderedProminent).tint(
            .orange
          ).keyboardShortcut(.return, modifiers: .command)
            .disabled(lockedAgent == nil && agentChoices.isEmpty)
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
      agent = lockedAgent ?? existing?.agent ?? model.snapshot.settings.preferredAgent
      reconcileAgent()
      if let existing, existing.status == .draft, let capture = existing.captures.first {
        note = capture.note
        if capture.originalPath != nil { document.marks = capture.annotations }
      }
    }
    .onChange(of: projectID) { _, _ in
      if existing == nil { issueID = nil }
      reconcileAgent()
    }
    .onChange(of: issueID) { _, _ in
      agent = lockedAgent ?? existing?.agent ?? model.snapshot.settings.preferredAgent
      reconcileAgent()
    }
    .onChange(of: model.agents) { _, _ in reconcileAgent() }
  }
  /// Drafts are new reports or the draft being edited, never evidence on a submitted issue.
  private var canSaveDraft: Bool {
    issueID == nil || (issueID == existing?.id && existing?.status == .draft)
  }
  /// Adding evidence to a submitted issue keeps that issue's agent and session.
  private var lockedAgent: AgentKind? {
    guard let issueID, let target = model.issue(issueID), target.status != .draft else {
      return nil
    }
    return target.resolvedAgent
  }
  private var externalAvailability: ExternalAgentAvailability {
    AgentPicker.externalAvailability(
      configured: model.loadExternalAssistant().isConfigured, hasProject: projectID != nil,
      projectOptIn: model.project(projectID)?.sendsExternalScreenshots == true)
  }
  private var agentChoices: [AgentKind] {
    if let lockedAgent { return [lockedAgent] }
    return AgentPicker.filingChoices(
      detections: model.agents, externalAvailable: externalAvailability.enabled)
  }
  private func reconcileAgent() {
    if let lockedAgent { agent = lockedAgent }
    else if !agentChoices.contains(agent), let first = agentChoices.first { agent = first }
  }
  private func symbol(_ tool: MarkKind) -> String {
    switch tool {
    case .arrow: return "arrow.up.right"
    case .rectangle: return "rectangle"
    case .ellipse: return "oval"
    case .pen: return "pencil.tip"
    case .text: return "textformat"
    case .redact: return "rectangle.fill"
    }
  }
  private func submit(draft: Bool) {
    do {
      if !draft, (lockedAgent ?? agent) == .external, let hint = externalAvailability.hint {
        error = hint
        return
      }
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
        context: captured, projectID: projectID, existingID: issueID, draft: draft,
        agent: lockedAgent ?? agent)
      close()
    } catch { self.error = error.localizedDescription }
  }
}
