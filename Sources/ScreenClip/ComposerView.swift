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
  @Environment(\.locale) private var locale
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "viewfinder").font(.title2).foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 3) {
          Group {
            if existing?.status == .draft {
              Text(chrome: "Finish your observation", comment: "Composer title when editing a draft.")
            } else {
              Text(chrome: "What did you notice?", comment: "Composer title for a new capture.")
            }
          }
            .font(.title3.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
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
          .buttonStyle(.plain).help(Text(verbatim: kind.localizedTitle(locale: locale)))
          .accessibilityLabel(Text(verbatim: kind.localizedTitle(locale: locale)))
        }
        Divider().frame(height: 22).padding(.horizontal, 4)
        Menu {
          ForEach(MarkColor.allCases, id: \.self) { color in
            Button {
              document.color = color
            } label: {
              Label {
                Text(verbatim: color.localizedTitle(locale: locale))
              } icon: {
                Image(systemName: document.color == color ? "checkmark.circle.fill" : "circle.fill")
              }
              .foregroundStyle(Color(nsColor: color.nsColor))
            }
          }
        } label: {
          Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: document.color.nsColor))
            .overlay(Circle().stroke(.primary.opacity(0.3), lineWidth: 0.5))
        }.frame(width: 46).help(
          Text(chrome: "Annotation color", comment: "Opens the annotation color menu.")
        ).accessibilityLabel(
          Text(verbatim: Chrome.format(
            "composer.color", "Annotation color: \(document.color.localizedTitle(locale: locale))",
            locale: locale, comment: "Accessibility label. %@ is the selected color name."))
        )
        .disabled(document.tool == .redact)
        Picker(selection: $document.lineWidth) {
          Text(chrome: "Thin", comment: "Thinnest annotation stroke.").tag(0.003)
          Text(chrome: "Medium", comment: "Medium annotation stroke.").tag(0.006)
          Text(chrome: "Bold", comment: "Thickest annotation stroke.").tag(0.012)
        } label: {
          Text(chrome: "Stroke", comment: "Annotation stroke thickness picker.")
        }.labelsHidden().frame(minWidth: 104, idealWidth: 140).help(
          Text(chrome: "Stroke thickness", comment: "Help for the stroke thickness picker.")
        ).accessibilityLabel(
          Text(chrome: "Stroke thickness", comment: "Accessibility label for stroke thickness.")
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
        TextField(
          "", text: $document.text,
          prompt: Text(
            chrome: "Type a label, then click on the image to place it",
            comment: "Placeholder for an annotation text label."))
          .textFieldStyle(.roundedBorder).padding(.horizontal, 20).padding(.bottom, 10)
      }
      Divider()
      AnnotationCanvas(image: image, document: document).frame(
        minHeight: 160, idealHeight: 330, maxHeight: .infinity)
      Divider()
      ZStack(alignment: .topLeading) {
        if note.isEmpty {
          Text(
            chrome: "A quick description, or just the screenshot…",
            comment: "Placeholder for the optional capture note."
          ).foregroundStyle(.tertiary).padding(
            .top, 8
          ).padding(.leading, 5).allowsHitTesting(false)
        }
        TextEditor(text: $note).font(.body).scrollContentBackground(.hidden).frame(height: 75)
          .focused($noteFocused).accessibilityLabel(
            Text(chrome: "Observation description", comment: "Accessibility label for the capture note."))
      }.padding(20)
      Divider()
      VStack(alignment: .leading, spacing: 12) {
        GeometryReader { geometry in
          let column = max(0, (geometry.size.width - 40) / 3)
          HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
              Text(chrome: "Project", comment: "Caption above the project picker.").font(.caption)
                .foregroundStyle(.secondary)
              Picker(selection: $projectID) {
                Text(chrome: "Choose project…", comment: "Project picker placeholder.").tag(nil as UUID?)
                ForEach(model.snapshot.projects) { project in
                  Label(project.name, systemImage: project.displaySymbol).tag(Optional(project.id))
                }
              } label: {
                Text(chrome: "Project", comment: "Accessibility label for the project picker.")
              }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text(chrome: "Project", comment: "Accessibility label for the project picker."))
                .disabled(existing != nil && existing?.status != .draft)
            }.frame(width: column, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
              Text(chrome: "Issue", comment: "Caption above the issue picker.").font(.caption)
                .foregroundStyle(.secondary)
              Picker(selection: $issueID) {
                Text(chrome: "New issue", comment: "Files the capture as a new report.").tag(nil as UUID?)
                ForEach(
                  model.snapshot.issues.filter {
                    !$0.archived && $0.projectID == projectID && $0.status != .draft
                  }
                ) { Text(verbatim: $0.referencedTitle).tag(Optional($0.id)) }
                if let existing, existing.status == .draft {
                  if let reference = existing.reportReference {
                    Text(verbatim: Chrome.format(
                      "composer.currentDraft", "Current draft \(reference)", locale: locale,
                      comment: "Issue picker row for the draft being edited. %@ is the report number."))
                      .tag(Optional(existing.id))
                  } else {
                    Text(chrome: "Current draft", comment: "Issue picker row for an unnumbered draft.")
                      .tag(Optional(existing.id))
                  }
                }
              } label: {
                Text(chrome: "Issue", comment: "Accessibility label for the issue picker.")
              }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text(chrome: "Issue", comment: "Accessibility label for the issue picker."))
            }.frame(width: column, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
              Text(chrome: "Agent", comment: "Caption above the agent picker.").font(.caption)
                .foregroundStyle(.secondary)
              Picker(selection: $agent) {
                if agentChoices.isEmpty && lockedAgent == nil {
                  Text(verbatim: model.detectingAgents
                    ? Chrome.text("Checking agents…", locale: locale, comment: "Agent list is still loading.")
                    : Chrome.text("No agents available", locale: locale, comment: "No coding agent can take this report.")
                  ).tag(agent)
                } else {
                  ForEach(agentChoices, id: \.self) { kind in
                    AgentLabel(kind: kind).tag(kind)
                  }
                }
              } label: {
                Text(chrome: "Agent", comment: "Accessibility label for the agent picker.")
              }
              .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
              .disabled(lockedAgent != nil || agentChoices.isEmpty)
              .accessibilityLabel(Text(chrome: "Agent", comment: "Accessibility label for the agent picker."))
              .help(
                lockedAgent != nil
                  ? Text(chrome: "Follow-up captures continue with the issue's existing agent.", comment: "Help when the agent cannot be changed.")
                  : Text(chrome: "Which agent works on this report.", comment: "Help for the agent picker."))
            }.frame(width: column, alignment: .leading)
          }
        }
        .frame(height: 52)
        if (lockedAgent ?? agent) == .external, let hint = externalAvailability.localizedHint(locale: locale) {
          Text(verbatim: hint).font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        } else if model.effectiveAgent(for: projectID) == .external,
          model.loadExternalAssistant().isConfigured == false
        {
          Text(verbatim: ProviderPhrase.notConnected.localized(.external, locale: locale))
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let error {
          Text(verbatim: Chrome.stored(error, locale: locale)).font(.caption).foregroundStyle(.red)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .center) {
          if canSaveDraft {
            Button { submit(draft: true) } label: {
              Text(chrome: "Save draft", comment: "Saves the capture without sending it.")
            }.keyboardShortcut("s", modifiers: .command)
          }
          Spacer(minLength: 8)
          Text(chrome: "⌘ Return to submit", comment: "Hint that Command-Return submits. Keep the ⌘ symbol.")
            .font(.caption).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
          Button(action: { submit(draft: false) }) {
            Text(chrome: "Submit", comment: "Submits the capture.")
          }.buttonStyle(.borderedProminent).tint(.orange)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(lockedAgent == nil && agentChoices.isEmpty)
        }
      }.padding(20)
    }
    .frame(minWidth: 680, idealWidth: 860, minHeight: 560, idealHeight: 720)
    .onAppear {
      noteFocused = true
      projectID =
        existing?.projectID
        ?? ProjectRouter.infer(context, projects: model.snapshot.projects).projectID
      issueID = existing?.id
      if let lockedAgent {
        agent = lockedAgent
      } else if let existing, existing.status == .draft, let chosen = existing.agent {
        agent = chosen
      } else {
        agent = model.effectiveAgent(for: projectID)
      }
      reconcileAgent()
      if let existing, existing.status == .draft, let capture = existing.captures.first {
        note = capture.note
        if capture.originalPath != nil { document.marks = capture.annotations }
      }
    }
    .onChange(of: projectID) { _, new in
      if existing == nil { issueID = nil }
      if lockedAgent == nil, existing == nil || new != existing?.projectID {
        agent = model.effectiveAgent(for: new)
      }
      reconcileAgent()
    }
    .onChange(of: issueID) { _, _ in
      if let lockedAgent {
        agent = lockedAgent
      } else if issueID == nil {
        agent = model.effectiveAgent(for: projectID)
      }
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
