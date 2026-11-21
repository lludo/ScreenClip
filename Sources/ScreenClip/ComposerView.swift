import ScreenClipCore
import SwiftUI

extension ComposerView {
  /// The Undo and Redo buttons own ⌘Z window-wide. While a text field is being edited, the
  /// keystroke belongs to that text: undoing a mark instead could silently drop a redaction.
  /// A mouse click on the buttons always edits the marks.
  static func textUndo(redo: Bool) -> Bool {
    guard NSApp.currentEvent?.type == .keyDown,
      let text = NSApp.keyWindow?.firstResponder as? NSTextView
    else { return false }
    if let manager = text.undoManager {
      if redo { if manager.canRedo { manager.redo() } } else if manager.canUndo { manager.undo() }
    }
    return true
  }
}

struct ComposerView: View {
  @ObservedObject var model: AppModel
  let image: NSImage?
  let context: CaptureContext
  let existing: Issue?
  let close: () -> Void
  @StateObject private var document = AnnotationDocument()
  @State private var note = ""
  @State private var projectID: UUID?
  @State private var issueID: UUID?
  @State private var choice = ReportAgentChoice(agent: .codex)
  @State private var error: String?
  /// Whether Grok Bot is connected. Cached: the Keychain must not be read on every keystroke.
  @State private var externalConfigured = false
  @FocusState private var noteFocused: Bool
  @Environment(\.locale) private var locale
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: image == nil ? "text.alignleft" : "viewfinder").font(.title3).foregroundStyle(.orange)
        Group {
          if existing?.status == .draft {
            Text(chrome: "Finish your observation", comment: "Composer title when editing a draft.")
          } else {
            Text(chrome: "What did you notice?", comment: "Composer title for a new capture.")
          }
        }
          .font(.title3.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
          .layoutPriority(1)
        Spacer(minLength: 12)
        Text(
          [
            context.appName,
            context.browserURL.flatMap { URL(string: $0)?.host } ?? context.windowTitle ?? "",
          ].filter { !$0.isEmpty }.joined(separator: " · ")
        ).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }.padding(.horizontal, 20).padding(.vertical, 10)
      if let image {
        annotationTools
        Divider()
        AnnotationCanvas(image: image, document: document).frame(
          minHeight: 160, idealHeight: 330, maxHeight: .infinity)
      }
      Divider()
      ZStack(alignment: .topLeading) {
        if note.isEmpty {
          Group {
            if image == nil {
              Text(chrome: "Describe what you noticed…", comment: "Placeholder for a text-only report.")
            } else {
              Text(chrome: "A quick description, or just the screenshot…",
                comment: "Placeholder for the optional capture note.")
            }
          }.foregroundStyle(.tertiary).padding(
            .top, 8
          ).padding(.leading, 5).allowsHitTesting(false)
        }
        TextEditor(text: $note).font(.body).scrollContentBackground(.hidden).frame(minHeight: 75, maxHeight: image == nil ? .infinity : 75)
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
              Picker(selection: Binding(get: { projectID }, set: { newProject in
                // Choosing the current project again keeps a hand-picked agent.
                guard newProject != projectID else { return }
                projectID = newProject
                if issueID != existing?.id { issueID = nil }
                selectInitialAgent()
              })) {
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
              Picker(selection: Binding(get: { issueID }, set: { newIssue in
                guard newIssue != issueID else { return }
                issueID = newIssue
                selectInitialAgent()
              })) {
                Text(chrome: "New issue", comment: "Files the capture as a new report.").tag(nil as UUID?)
                ForEach(followUpTargets) { Text(verbatim: $0.referencedTitle).tag(Optional($0.id)) }
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
              Menu {
                agentMenuItems
              } label: {
                AgentLabel(kind: lockedAgent ?? choice.agent, title: agentSummary)
              }
              .menuIndicator(.visible)
              .frame(maxWidth: .infinity, alignment: .leading)
              .disabled(lockedAgent != nil || agentChoices.isEmpty)
              .accessibilityLabel(Text(chrome: "Agent", comment: "Accessibility label for the agent picker."))
              .help(
                lockedAgent != nil
                  ? Text(chrome: "Follow-up captures continue with the issue's existing agent.", comment: "Help when the agent cannot be changed.")
                  : Text(chrome: "Which agent works on this report, with its model and effort.", comment: "Help for the agent picker, which also chooses the model and reasoning effort."))
            }.frame(width: column, alignment: .leading)
          }
        }
        .frame(height: 52)
        if (lockedAgent ?? choice.agent) == .external, let hint = externalAvailability.localizedHint(locale: locale) {
          Text(verbatim: hint).font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        } else if model.initialAgentChoice(for: projectID).agent == .external,
          !externalConfigured
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
          Spacer(minLength: 8)
          Text(chrome: "⌘ Return to submit", comment: "Hint that Command-Return submits. Keep the ⌘ symbol.")
            .font(.caption).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
          if canSaveDraft {
            Button { submit(draft: true) } label: {
              Text(chrome: "Save draft", comment: "Saves the capture without sending it.")
            }.keyboardShortcut("s", modifiers: .command).disabled(missingNote)
          }
          Button(action: { submit(draft: false) }) {
            Text(chrome: "Submit", comment: "Submits the capture.")
          }.buttonStyle(.borderedProminent).tint(.orange)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(missingNote || (lockedAgent == nil && agentChoices.isEmpty))
        }
      }.padding(20)
    }
    .frame(minWidth: 680, idealWidth: 860, minHeight: image == nil ? 320 : 560, idealHeight: image == nil ? 380 : 720)
    .onAppear {
      externalConfigured = model.loadExternalAssistant().isConfigured
      noteFocused = true
      projectID =
        existing?.projectID
        ?? ProjectRouter.infer(context, projects: model.snapshot.projects).projectID
      issueID = existing?.id
      selectInitialAgent()
      if let existing, existing.status == .draft, let capture = existing.captures.first {
        note = capture.note
        if capture.originalPath != nil { document.marks = capture.annotations }
      }
    }
    .onChange(of: model.agents) { _, _ in
      // Saving or removing the Grok Bot connection refreshes the agent list.
      externalConfigured = model.loadExternalAssistant().isConfigured
      reconcileAgent()
    }
    .onChange(of: model.codexModels) { _, _ in reconcileAgent() }
  }
  @ViewBuilder private var annotationTools: some View {
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
        if !Self.textUndo(redo: false) { document.undo() }
      } label: {
        Image(systemName: "arrow.uturn.backward")
      }.disabled(document.marks.isEmpty).keyboardShortcut("z", modifiers: .command)
        .help(Text(chrome: "Undo", comment: "Undoes the last annotation or text edit."))
        .accessibilityLabel(Text(chrome: "Undo", comment: "Undoes the last annotation or text edit."))
      Button {
        if !Self.textUndo(redo: true) { document.redo() }
      } label: {
        Image(systemName: "arrow.uturn.forward")
      }.disabled(!document.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
        .help(Text(chrome: "Redo", comment: "Redoes the last undone annotation or text edit."))
        .accessibilityLabel(Text(chrome: "Redo", comment: "Redoes the last undone annotation or text edit."))
    }.padding(.horizontal, 20).padding(.vertical, 10)
    if document.tool == .text {
      TextField(
        "", text: $document.text,
        prompt: Text(
          chrome: "Type a label, then click on the image to place it",
          comment: "Placeholder for an annotation text label."))
        .textFieldStyle(.roundedBorder).padding(.horizontal, 20).padding(.bottom, 10)
    }
  }
  /// Drafts are new reports or the draft being edited, never evidence on a submitted issue.
  private var canSaveDraft: Bool {
    issueID == nil || (issueID == existing?.id && existing?.status == .draft)
  }
  /// Submitted issues in the chosen project that can take this capture, newest first.
  private var followUpTargets: [Issue] {
    Issue.newestFirst(model.snapshot.issues.filter {
      !$0.archived && $0.projectID == projectID && $0.status != .draft
    })
  }
  /// Adding evidence to a submitted issue keeps that issue's agent and session.
  private var lockedAgent: AgentKind? {
    guard let issueID, let target = model.issue(issueID), target.status != .draft else {
      return nil
    }
    return target.resolvedAgent
  }
  private var externalAvailability: ExternalAgentAvailability {
    AgentPicker.externalAvailability(configured: externalConfigured, hasProject: projectID != nil)
  }
  private var agentChoices: [AgentKind] {
    if let lockedAgent { return [lockedAgent] }
    return AgentPicker.filingChoices(
      detections: model.agents, externalAvailable: externalAvailability.enabled)
  }
  private var missingNote: Bool {
    image == nil && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  private func selectInitialAgent() {
    if let issueID, let target = model.issue(issueID),
      target.status != .draft || (target.projectID == projectID && target.agent != nil)
    {
      choice = ReportAgentChoice(agent: target.resolvedAgent, model: target.agentModel, effort: target.agentEffort)
    } else {
      choice = model.initialAgentChoice(for: projectID)
    }
    reconcileAgent()
  }
  private func reconcileAgent() {
    guard lockedAgent == nil else { return }
    if !agentChoices.contains(choice.agent), let first = agentChoices.first {
      let fallback = AgentSelection.projectDefault(model.project(projectID), system: model.snapshot.settings.preferredAgent)
      choice = ReportAgentChoice(agent: agentChoices.contains(fallback) ? fallback : first)
    }
    (choice.model, choice.effort) = AgentModelCatalog.reconcile(
      model: choice.model, effort: choice.effort, in: model.modelOptions(for: choice.agent))
  }
  /// The selection shown on the menu button: the agent, then the model and effort when the
  /// report does not keep the defaults. A follow-up shows the issue's existing choice.
  private var agentSummary: String {
    if let lockedAgent, let issueID, let target = model.issue(issueID) {
      // A Codex chat keeps the model it started with, which today's Settings may not name.
      let unnamedDefault = lockedAgent == .codex && target.agentModel == nil
      return AgentModelMenu.summary(
        kind: lockedAgent, model: target.agentModel, effort: target.agentEffort,
        options: model.modelOptions(for: lockedAgent),
        defaultModel: unnamedDefault ? nil : model.defaultModel(for: lockedAgent), locale: locale)
    }
    if agentChoices.isEmpty {
      return model.detectingAgents
        ? Chrome.text("Checking agents…", locale: locale, comment: "Agent list is still loading.")
        : Chrome.text("No agents available", locale: locale, comment: "No coding agent can take this report.")
    }
    return AgentModelMenu.summary(
      kind: choice.agent, model: choice.model, effort: choice.effort,
      options: model.modelOptions(for: choice.agent), defaultModel: model.defaultModel(for: choice.agent),
      locale: locale)
  }
  /// Each agent can be chosen directly with its defaults, or through its submenus with a
  /// model and then an effort, so Claude Code · Opus · Extra high is one pick.
  @ViewBuilder private var agentMenuItems: some View {
    ForEach(agentChoices, id: \.self) { kind in
      AgentModelMenu(
        kind: kind, options: model.modelOptions(for: kind),
        defaultModel: model.defaultModel(for: kind),
        selected: kind == choice.agent ? (choice.model, choice.effort) : nil,
        isCurrent: kind == choice.agent, locale: locale
      ) { chosenModel, chosenEffort in
        choice = ReportAgentChoice(agent: kind, model: chosenModel, effort: chosenEffort)
      }
    }
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
      if !draft, (lockedAgent ?? choice.agent) == .external, let hint = externalAvailability.hint {
        error = hint
        return
      }
      var captured = context
      if projectID != nil
        && ProjectRouter.infer(context, projects: model.snapshot.projects).projectID != projectID
      {
        captured.routingReason = "Project selected by tester"
      }
      let data = try image.map { try AnnotationRenderer.png(image: $0, marks: document.marks) }
      let original =
        document.marks.contains { $0.kind == .redact }
        ? nil : try image.map { try AnnotationRenderer.png(image: $0, marks: []) }
      try model.submit(
        imageData: data, originalData: original, annotations: document.marks, note: note,
        context: captured, projectID: projectID, existingID: issueID, draft: draft,
        agent: lockedAgent ?? choice.agent, agentModel: choice.model,
        agentEffort: choice.effort)
      close()
    } catch { self.error = error.localizedDescription }
  }
}
