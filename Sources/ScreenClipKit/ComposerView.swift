#if os(iOS) && DEBUG
  import Observation
  import ScreenClipWire
  import SwiftUI
  import UIKit

  @MainActor @Observable final class ComposerModel {
    var marks: [Annotation] = []
    var draft: Annotation?
    var tool: MarkKind = .arrow
    var color: MarkColor = .red
    var note = ""
    var pendingTextPoint: MarkPoint?
    var pendingText = ""
    private var redoMarks: [Annotation] = []
    private var ordinaryDiagnostics = KitPreferences.attachDiagnostics
    private var redactedDiagnostics = false

    var hasRedactions: Bool { marks.contains { $0.kind == .redact } }
    var attachDiagnostics: Bool {
      get { hasRedactions ? redactedDiagnostics : ordinaryDiagnostics }
      set {
        if hasRedactions {
          redactedDiagnostics = newValue
        } else {
          ordinaryDiagnostics = newValue
          KitPreferences.attachDiagnostics = newValue
        }
      }
    }

    var canUndo: Bool { !marks.isEmpty }
    var canRedo: Bool { !redoMarks.isEmpty }
    func add(_ mark: Annotation) {
      marks.append(mark)
      redoMarks.removeAll()
    }
    func undo() { if let mark = marks.popLast() { redoMarks.append(mark) } }
    func redo() { if let mark = redoMarks.popLast() { marks.append(mark) } }
  }

  struct ComposerView: View {
    let image: UIImage
    let link: MacLink
    let outbox: Outbox
    let followUp: FollowUpTarget
    let stillBroken: (SentLog.Entry) -> Void
    let send: (String, Data, Bool) async throws -> Void
    let cancel: () -> Void
    @State private var model = ComposerModel()
    @State private var showingSettings = false
    @State private var saving = false
    @State private var saveError: String?
    @FocusState private var noteFocused: Bool

    var body: some View {
      NavigationStack {
        VStack(spacing: 0) {
          HStack(spacing: 4) {
            AnnotationPalette { colorButtons }
            AnnotationCanvasView(image: image, model: model)
            AnnotationPalette { toolButtons }
          }
          .padding(4)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.black)
          Divider()
          if let entry = followUp.entry {
            HStack {
              Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.orange)
              Text(followUpTitle(entry)).font(.footnote).lineLimit(1)
              Spacer()
              Button {
                followUp.entry = nil
              } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
              }
              .accessibilityLabel("File as a new report instead")
            }
            .padding(.horizontal, 14).padding(.top, 8)
          }
          HStack(spacing: 4) {
            TextField("What's wrong here?", text: $model.note, axis: .vertical)
              .lineLimit(1...4)
              .focused($noteFocused)
              .accessibilityIdentifier("screenclip.note")
              .padding(10)
            if noteFocused {
              Button { noteFocused = false } label: {
                Text("Done").frame(minWidth: 52, minHeight: 44)
              }
              .buttonStyle(.borderless)
              .accessibilityLabel("Dismiss keyboard")
            }
          }
          .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
          .padding(.horizontal, 12).padding(.top, 6)
          HStack(spacing: 8) {
            historyButton("Undo", symbol: "arrow.uturn.backward", enabled: model.canUndo, action: model.undo)
            historyButton("Redo", symbol: "arrow.uturn.forward", enabled: model.canRedo, action: model.redo)
            Spacer(minLength: 4)
            Toggle(isOn: $model.attachDiagnostics) {
              Text("Attach logs and diagnostics").font(.footnote)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHint("Recent app logs, the screen's layout, and device state. The agent reads them only if needed.")
          }
          .padding(.horizontal, 12).padding(.vertical, 4)
          if model.hasRedactions {
            Text("Logs and diagnostics may contain text you covered in the screenshot.")
              .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 6)
          }
        }
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
          ToolbarItem(placement: .principal) { ConnectionBadge(link: link) }
          ToolbarItemGroup(placement: .confirmationAction) {
            Button {
              showingSettings = true
            } label: {
              Image(systemName: "gearshape")
            }
            .accessibilityLabel("ScreenClip settings")
            Button("Send") {
              guard !saving else { return }
              saving = true
              Task { @MainActor in
                defer { saving = false }
                guard let image = image.cgImage, let png = AnnotationDrawing.renderPNG(image: image, marks: model.marks) else {
                  saveError = "Could not render the annotated screenshot."
                  return
                }
                do {
                  try await send(model.note.trimmingCharacters(in: .whitespacesAndNewlines), png,
                    model.attachDiagnostics)
                } catch {
                  saveError = error.localizedDescription
                }
              }
            }
              .bold()
          }
        }
        .sheet(isPresented: $showingSettings) {
          NavigationStack {
            KitSettingsView(link: link, outbox: outbox) { entry in
              stillBroken(entry)
              showingSettings = false
            }
              .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } }
              }
          }
        }
        .alert("Could not save the report", isPresented: Binding(
          get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) { Button("OK") {} } message: { Text(saveError ?? "") }
        .alert(
          "Add text",
          isPresented: Binding(
            get: { model.pendingTextPoint != nil }, set: { if !$0 { model.pendingTextPoint = nil } })
        ) {
          TextField("Text", text: $model.pendingText)
          Button("Add") {
            let text = model.pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let point = model.pendingTextPoint, !text.isEmpty {
              model.add(Annotation(kind: .text, points: [point], text: text, color: model.color))
            }
            model.pendingText = ""
            model.pendingTextPoint = nil
          }
          Button("Cancel", role: .cancel) { model.pendingTextPoint = nil }
        }
      }
      .disabled(saving)
      .overlay { if saving { ProgressView("Saving report…").padding().background(.regularMaterial, in: Capsule()) } }
      .tint(.orange)
    }

    private func followUpTitle(_ entry: SentLog.Entry) -> String {
      let number = entry.state?.reportNumber.map { "#\($0) " } ?? ""
      let title = entry.state?.title ?? ""
      return "Still broken: \(number)\(title.isEmpty ? entry.note : title)"
    }

  }

  struct ConnectionBadge: View {
    let link: MacLink
    var body: some View {
      HStack(spacing: 5) {
        Circle().fill(link.isConnected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
        Text(link.connectedMacName ?? (link.hasPairing ? "Mac not reachable" : "No Mac paired"))
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .accessibilityElement(children: .combine)
    }
  }

  extension ComposerView {
    private var toolButtons: some View {
      ForEach(Self.tools, id: \.0) { tool, symbol, name in
        Button {
          model.tool = tool
        } label: {
          Image(systemName: symbol)
            .font(.body.weight(.medium))
            .foregroundStyle(model.tool == tool ? Color.orange : .white)
            .frame(width: 36, height: 36)
            .background(model.tool == tool ? Color.orange.opacity(0.2) : .clear, in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
        .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
      }
    }

    private static let tools: [(MarkKind, String, String)] = [
      (.arrow, "arrow.up.right", "Arrow"), (.rectangle, "rectangle", "Rectangle"),
      (.ellipse, "circle", "Ellipse"), (.pen, "scribble", "Pen"), (.text, "textformat", "Text"),
      (.redact, "eye.slash.fill", "Redact"),
    ]

    private var colorButtons: some View {
      ForEach([MarkColor.red, .orange, .yellow, .green, .blue, .white], id: \.self) { color in
        Button {
          model.color = color
        } label: {
          Circle().fill(Color(cgColor: color.cgColor))
            .frame(width: 22, height: 22)
            .overlay {
              if model.color == color {
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black)
              }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(color.rawValue.capitalized)
        .accessibilityAddTraits(model.color == color ? .isSelected : [])
        .disabled(model.tool == .redact)
        .opacity(model.tool == .redact ? 0.4 : 1)
      }
    }

    private func historyButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Image(systemName: symbol)
          .frame(width: 44, height: 44)
          .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
          .contentShape(Rectangle())
      }
      .accessibilityLabel(title)
      .disabled(!enabled)
    }
  }

  private struct AnnotationPalette<Buttons: View>: View {
    @ViewBuilder let buttons: Buttons

    var body: some View {
      ViewThatFits(in: .vertical) {
        stack
        ScrollView(.vertical) { stack }
      }
      .frame(width: 44)
      .buttonStyle(.plain)
      .background(.regularMaterial, in: Capsule())
      .clipShape(Capsule())
      .environment(\.colorScheme, .dark)
    }

    private var stack: some View {
      VStack(spacing: 0) { buttons }.padding(.vertical, 4)
    }
  }

  /// The screenshot with marks drawn by the shared renderer. Points are fractions of the image.
  struct AnnotationCanvasView: View {
    let image: UIImage
    let model: ComposerModel

    var body: some View {
      GeometryReader { proxy in
        let rect = fittedRect(in: proxy.size)
        ZStack(alignment: .topLeading) {
          Image(uiImage: image).resizable().frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
          Canvas { context, _ in
            let marks = model.marks + (model.draft.map { [$0] } ?? [])
            context.withCGContext { cg in AnnotationDrawing.draw(marks, in: rect, context: cg) }
          }
          .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in changed(value, rect: rect) }
            .onEnded { value in ended(value, rect: rect) })
      }
      .accessibilityLabel("Screenshot. Draw to annotate.")
      .accessibilityIdentifier("screenclip.canvas")
    }

    private func fittedRect(in size: CGSize) -> CGRect {
      guard image.size.width > 0, image.size.height > 0 else { return CGRect(origin: .zero, size: size) }
      let scale = min(size.width / image.size.width, size.height / image.size.height)
      let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      return CGRect(
        x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width,
        height: fitted.height)
    }

    private func point(_ location: CGPoint, rect: CGRect) -> MarkPoint {
      MarkPoint(
        max(0, min(1, (location.x - rect.minX) / rect.width)),
        max(0, min(1, (location.y - rect.minY) / rect.height)))
    }

    private func changed(_ value: DragGesture.Value, rect: CGRect) {
      guard model.tool != .text else { return }
      let p = point(value.location, rect: rect)
      if var draft = model.draft {
        if draft.kind == .pen { draft.points.append(p) } else { draft.points[1] = p }
        model.draft = draft
      } else {
        guard rect.contains(value.startLocation) else { return }
        let start = point(value.startLocation, rect: rect)
        model.draft = Annotation(
          kind: model.tool, points: [start, p], color: model.color,
          lineWidth: model.tool == .pen ? 0.008 : 0.006)
      }
    }

    private func ended(_ value: DragGesture.Value, rect: CGRect) {
      if model.tool == .text {
        if rect.contains(value.location) { model.pendingTextPoint = point(value.location, rect: rect) }
        return
      }
      guard let draft = model.draft else { return }
      model.draft = nil
      // Ignore taps that did not draw anything.
      let first = draft.points.first, last = draft.points.last
      if let first, let last, draft.kind != .pen, abs(first.x - last.x) < 0.005, abs(first.y - last.y) < 0.005 {
        return
      }
      if draft.kind == .pen, draft.points.count < 3 { return }
      model.add(draft)
    }
  }
#endif
