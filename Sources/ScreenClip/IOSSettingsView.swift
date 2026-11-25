import AppKit
import ScreenClipCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings > iOS: install ScreenClipKit, run the local server, pair devices, and fetch reports.
struct IOSSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var receiver: IOSReceiver
  @Binding var settings: AppSettings
  @Environment(\.locale) private var locale
  @State private var pairing = false
  @State private var copied: String?

  static let skillURL =
    "https://raw.githubusercontent.com/lludo/ScreenClip/main/plugins/screenclip/skills/install-ios-sdk/SKILL.md"
  static let guideURL = URL(string: "https://github.com/lludo/ScreenClip/blob/main/docs/ios-sdk.md")!
  /// Sent to a coding agent as is, so it stays English.
  static let agentPrompt =
    "Install ScreenClipKit in this iOS app for Debug builds only, following \(skillURL)"
  static let setupCode = """
    // Package: https://github.com/lludo/ScreenClip  (product ScreenClipKit)
    #if DEBUG
    import ScreenClipKit
    #endif

    // In your App init or application(_:didFinishLaunchingWithOptions:)
    #if DEBUG
    ScreenClipKit.start()
    #endif
    """

  var body: some View {
    Form {
      installSection
      serverSection
      devicesSection
    }
    .formStyle(.grouped)
    .sheet(isPresented: $pairing) { PairDeviceSheet(receiver: receiver) }
  }

  private var installSection: some View {
    Section {
      Text(
        chrome:
          "Add ScreenClipKit to the Debug build of your iOS app. Testers shake the device to capture a screen, annotate it, and send it here as a report.",
        comment: "Explains the iOS SDK in Settings. Keep ScreenClipKit."
      ).fixedSize(horizontal: false, vertical: true)
      Text(verbatim: Self.setupCode)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
      HStack {
        Button {
          copy(Self.agentPrompt, as: "prompt")
        } label: {
          Text(chrome: "Copy agent prompt", comment: "Copies a prompt that asks a coding agent to install the iOS SDK.")
        }
        Button {
          copy(Self.setupCode, as: "code")
        } label: {
          Text(chrome: "Copy setup code", comment: "Copies the iOS SDK setup code.")
        }
        if copied != nil {
          Text(chrome: "Copied", comment: "Confirms text was copied to the clipboard.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Link(destination: Self.guideURL) {
          Text(chrome: "Setup guide", comment: "Opens the iOS SDK setup guide.")
        }
      }
      Text(
        chrome:
          "Paste the agent prompt into Claude Code or Codex in your iOS project; it adds the package, the start call, and the Debug-only network settings. Nothing is included in Release builds.",
        comment: "Explains the agent prompt. Keep Claude Code and Codex."
      ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    } header: {
      Text(chrome: "Install the iOS SDK", comment: "Settings section for installing the iOS SDK.")
    }
  }

  private var serverSection: some View {
    Section {
      Toggle(
        isOn: Binding(
          get: { settings.iosServerEnabled == true },
          set: { enabled in
            settings.iosServerEnabled = enabled
            model.setIOSServer(enabled: enabled)
          })
      ) {
        Text(chrome: "Receive reports from iOS devices", comment: "Turns on the local server for the iOS SDK.")
      }
      HStack(spacing: 6) {
        Circle().fill(statusColor).frame(width: 8, height: 8)
        Text(verbatim: statusText).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      Toggle(
        isOn: Binding(
          get: { settings.keepAwakeForIOS ?? true },
          set: { keepAwake in
            settings.keepAwakeForIOS = keepAwake
            model.setKeepAwakeForIOS(keepAwake)
          })
      ) {
        Text(chrome: "Keep this Mac awake while receiving iOS reports", comment: "Prevents idle sleep while the iOS local server is on.")
      }
      Text(
        chrome:
          "The display can still sleep. ScreenClip also stays awake while an agent works on a report. A laptop with its lid closed sleeps unless it is on power with a display attached.",
        comment: "Explains the keep-awake setting."
      ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      LabeledContent {
        Menu {
          Toggle(
            isOn: Binding(get: { settings.iosAgentChoice == nil }, set: { _ in chooseAgent(nil) })
          ) {
            Text(chrome: "Project default", comment: "iOS reports use each project's default agent.")
          }
          Divider()
          ForEach(agentChoices, id: \.self) { kind in
            AgentModelMenu(
              kind: kind, options: model.modelOptions(for: kind), defaultModel: model.defaultModel(for: kind),
              selected: settings.iosAgentChoice?.agent == kind
                ? (settings.iosAgentChoice?.model, settings.iosAgentChoice?.effort) : nil,
              isCurrent: settings.iosAgentChoice?.agent == kind, locale: locale
            ) { chosenModel, chosenEffort in
              chooseAgent(ReportAgentChoice(agent: kind, model: chosenModel, effort: chosenEffort))
            }
          }
        } label: {
          if let choice = settings.iosAgentChoice {
            AgentLabel(
              kind: choice.agent,
              title: AgentModelMenu.summary(
                kind: choice.agent, model: choice.model, effort: choice.effort,
                options: model.modelOptions(for: choice.agent), defaultModel: model.defaultModel(for: choice.agent),
                locale: locale))
          } else {
            Text(chrome: "Project default", comment: "iOS reports use each project's default agent.")
          }
        }
        .menuIndicator(.visible)
        .fixedSize()
      } label: {
        Text(chrome: "Agent for iOS reports", comment: "Picker for the agent, model, and effort used for reports from iOS.")
      }
      Toggle(
        isOn: Binding(
          get: { settings.iosReportsAsDrafts == true },
          set: { drafts in
            settings.iosReportsAsDrafts = drafts
            model.setIOSReportsAsDrafts(drafts)
          })
      ) {
        Text(chrome: "Save iOS reports as drafts", comment: "iOS reports wait as drafts instead of going to an agent.")
      }
      Text(
        chrome:
          "Reports from iOS are filed like captures on this Mac: matched to a project by the app's bundle ID, then queued for the agent above.",
        comment: "Explains how iOS reports are routed."
      ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    } header: {
      Text(chrome: "Local server", comment: "Settings section for the iOS local server.")
    }
  }

  private var devicesSection: some View {
    Section {
      if receiver.devices.isEmpty {
        Text(chrome: "No paired devices yet.", comment: "Empty list of paired iOS devices.")
          .foregroundStyle(.secondary)
      }
      ForEach(receiver.devices) { device in
        HStack(spacing: 10) {
          Image(systemName: "iphone").foregroundStyle(.secondary).frame(width: 18)
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: device.name)
            Text(verbatim: deviceDetail(device)).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if let pending = receiver.connected[device.id] {
            Circle().fill(Color.green).frame(width: 8, height: 8)
            Text(verbatim: connectedText(pending)).font(.caption).foregroundStyle(.secondary)
          }
          Button(role: .destructive) {
            receiver.forget(device.id)
          } label: {
            Text(chrome: "Forget", comment: "Removes a paired iOS device.")
          }
        }
        if let queue = receiver.deviceQueues[device.id], !queue.isEmpty {
          DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(queue) { item in
                HStack(alignment: .firstTextBaseline) {
                  Text(verbatim: item.note.isEmpty
                    ? Chrome.text("Screenshot", locale: locale, comment: "A saved iOS report without a note.")
                    : item.note)
                    .lineLimit(1)
                  Spacer()
                  Text(item.createdAt, style: .relative).foregroundStyle(.secondary)
                }.font(.caption)
              }
            }
          } label: {
            Text(verbatim: Chrome.format(
              "ios.deviceQueue", "Waiting on \(device.name): \(queue.count)", locale: locale,
              comment: "Reports saved on an iOS device, not sent yet. %@ is the device name; %lld is the count."))
              .font(.caption).foregroundStyle(.secondary)
          }
          .padding(.leading, 28)
        }
      }
      HStack {
        Button {
          pairing = true
        } label: {
          Text(chrome: "Pair a device…", comment: "Opens the iOS device pairing sheet.")
        }
        .disabled(!receiver.isRunning)
        Button {
          receiver.fetch()
        } label: {
          Text(chrome: "Fetch", comment: "Asks connected iOS devices to send their saved reports.")
        }
        .disabled(receiver.connected.isEmpty)
        .help(Chrome.text("Ask connected devices to send the reports they saved while this Mac was unreachable.", locale: locale, comment: "Help for the Fetch button."))
        Spacer()
        Button {
          importFile()
        } label: {
          Text(chrome: "Import report file…", comment: "Imports a report file exported from an iOS device.")
        }
      }
      if let event = eventText {
        Text(verbatim: event).font(.caption).foregroundStyle(.secondary)
      }
      Text(
        chrome:
          "Devices send saved reports automatically when they find this Mac. Fetch reaches devices with the app open; others can export reports and AirDrop them here.",
        comment: "Explains automatic delivery, Fetch, and AirDrop. Keep AirDrop."
      ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    } header: {
      Text(chrome: "Devices", comment: "Settings section listing paired iOS devices.")
    }
  }

  private var agentChoices: [AgentKind] {
    AgentPicker.filingChoices(
      detections: model.agents,
      externalAvailable: AgentPicker.externalAvailability(
        configured: model.loadExternalAssistant().isConfigured, hasProject: true
      ).enabled)
  }

  private func chooseAgent(_ choice: ReportAgentChoice?) {
    settings.iosAgentChoice = choice
    model.setIOSAgentChoice(choice)
  }

  private var statusColor: Color {
    switch receiver.state {
    case .listening: return .green
    case .starting: return .orange
    case .failed: return .red
    case .stopped: return .secondary
    }
  }

  private var statusText: String {
    switch receiver.state {
    case .stopped:
      return Chrome.text("Stopped", locale: locale, comment: "The iOS local server is off.")
    case .starting:
      return Chrome.text("Starting…", locale: locale, comment: "The iOS local server is starting.")
    case .listening(let port):
      return Chrome.format(
        "ios.listening", "Listening as “\(receiver.macName)” on port \(Int(port))", locale: locale,
        comment: "The iOS local server is running. %@ is this Mac's name; %lld is a port number.")
    case .failed(let message):
      return Chrome.format(
        "ios.failed", "Could not start: \(message). Check that the macOS firewall allows ScreenClip.",
        locale: locale, comment: "The iOS local server failed. %@ is the system error and stays unchanged.")
    }
  }

  private func deviceDetail(_ device: IOSReceiver.Device) -> String {
    ([device.model] + device.apps).filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private func connectedText(_ pending: Int) -> String {
    Chrome.format(
      "ios.connected", "Connected, \(pending) saved", locale: locale,
      comment: "A paired iOS device is connected. %lld is how many reports it still holds.")
  }

  private var eventText: String? {
    switch receiver.lastEvent {
    case .fetched(let devices):
      return Chrome.format(
        "ios.event.fetched", "Asked \(devices) devices to send saved reports.", locale: locale,
        comment: "After Fetch. %lld is the number of devices.")
    case .received(let name):
      return Chrome.format(
        "ios.event.received", "Received a report from \(name).", locale: locale,
        comment: "An iOS report arrived. %@ is the device name.")
    case .paired(let name):
      return Chrome.format(
        "ios.event.paired", "Paired with \(name).", locale: locale,
        comment: "An iOS device was paired. %@ is the device name.")
    case nil:
      return nil
    }
  }

  private func copy(_ text: String, as kind: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    copied = kind
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == kind { copied = nil } }
  }

  private func importFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    if let type = UTType(filenameExtension: ReportFile.pathExtension) {
      panel.allowedContentTypes = [type]
    }
    guard panel.runModal() == .OK else { return }
    model.importIOSReportFiles(panel.urls)
  }
}

/// Pairing is open only while this sheet is showing.
struct PairDeviceSheet: View {
  @ObservedObject var receiver: IOSReceiver
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 36)).foregroundStyle(.orange)
      if let request = receiver.pairingRequest {
        Text(verbatim: Chrome.format(
          "ios.pair.request", "\(request.deviceName) wants to send reports from \(request.appName).",
          locale: locale,
          comment: "Pairing request. The first %@ is the device name, the second the app name."))
          .font(.headline).multilineTextAlignment(.center)
        Text(chrome: "Confirm only if your device shows the same code:", comment: "Asks to compare pairing codes.")
          .foregroundStyle(.secondary)
        Text(verbatim: request.code)
          .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
          .textSelection(.enabled)
        HStack {
          Button(role: .cancel) {
            receiver.declinePairing()
          } label: {
            Text(chrome: "Decline", comment: "Declines an iOS pairing request.")
          }
          Button {
            receiver.confirmPairing()
            dismiss()
          } label: {
            Text(chrome: "Confirm", comment: "Confirms an iOS pairing request.")
          }
          .buttonStyle(.borderedProminent).tint(.orange).keyboardShortcut(.defaultAction)
        }
      } else {
        Text(chrome: "Pair a device", comment: "Title of the iOS pairing sheet.").font(.headline)
        Text(verbatim: Chrome.format(
          "ios.pair.instructions",
          "On your iPhone or iPad, open the app, shake to open ScreenClip, tap the gear, then tap Pair next to “\(receiver.macName)”.",
          locale: locale, comment: "Pairing instructions. %@ is this Mac's name."))
          .multilineTextAlignment(.center).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        ProgressView().controlSize(.small)
        Button {
          dismiss()
        } label: {
          Text(chrome: "Cancel", comment: "Closes the iOS pairing sheet.")
        }
      }
    }
    .padding(24)
    .frame(width: 420)
    .onAppear { receiver.openPairing() }
    .onDisappear { receiver.closePairing() }
  }
}
