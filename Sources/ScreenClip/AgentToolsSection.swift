import AppKit
import ScreenClipCore
import SwiftUI

/// Settings section that registers ScreenClip's read-only MCP server with each local coding
/// agent, so any project's sessions can check their reports without reading the database.
struct AgentToolsSection: View {
  let dataFolder: URL
  let settings: AppSettings
  @Environment(\.locale) private var locale
  @State private var installed: [AgentKind: Bool] = [:]
  @State private var installing: AgentKind?
  @State private var copied: String?
  @State private var failure: String?

  private var server: URL { AgentMCPSetup.serverURL(dataFolder: dataFolder) }

  var body: some View {
    Section {
      Text(
        chrome:
          "Lets Claude Code and Codex, in any project, check that project's ScreenClip reports: open, in progress, and blocked. The tools only read your queue.",
        comment: "Explains the MCP server install. Keep Claude Code, Codex, ScreenClip."
      ).fixedSize(horizontal: false, vertical: true)
      ForEach(AgentMCPSetup.supportedAgents) { kind in row(kind) }
      if installed.values.contains(true) {
        Text(
          chrome:
            "Start a new agent session, then ask: “Check this project's ScreenClip tasks.”",
          comment: "Tells the user how to try the installed MCP server. Keep ScreenClip."
        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      if let failure {
        Text(verbatim: Chrome.stored(failure, locale: locale)).font(.caption)
          .foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Text(chrome: "Other MCP apps", comment: "Row for apps other than Claude Code and Codex.")
        Spacer()
        copyButton(
          id: "json",
          text: AgentMCPSetup.genericConfiguration(server: server, dataFolder: dataFolder),
          label: Chrome.text("Copy JSON", locale: locale, comment: "Copies the MCP server configuration as JSON."))
      }
    } header: {
      Text(chrome: "Check tasks from your agents", comment: "Settings section for installing the ScreenClip MCP server.")
    }
    .onAppear(perform: refresh)
  }

  private func row(_ kind: AgentKind) -> some View {
    let isInstalled = installed[kind] == true
    let executable = executablePath(kind)
    let available = FileManager.default.isExecutableFile(atPath: executable)
    // The Claude Code plugin already provides the tools; a user-level entry would duplicate them.
    let fromPlugin = kind == .claude && isInstalled
      && AgentMCPSetup.name(dataFolder: dataFolder) == AgentMCPSetup.serverName
      && AgentMCPSetup.installedThroughPlugin()
    return HStack(alignment: .firstTextBaseline) {
      Image(systemName: isInstalled ? "checkmark.circle.fill" : "circle.dashed")
        .foregroundStyle(isInstalled ? Color.green : Color.secondary)
      VStack(alignment: .leading, spacing: 2) {
        AgentLabel(kind: kind)
        Group {
          if isInstalled {
            Text(chrome: "Installed", comment: "The ScreenClip MCP server is installed for this agent.")
          } else if available {
            Text(chrome: "Not installed", comment: "The ScreenClip MCP server is not installed for this agent.")
          } else {
            Text(chrome: "Not found", comment: "No Claude Code executable was found.")
          }
        }.font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      copyButton(
        id: kind.rawValue,
        text: AgentMCPSetup.terminalCommand(kind, server: server, dataFolder: dataFolder),
        label: Chrome.text("Copy command", locale: locale, comment: "Copies the Terminal command that installs the MCP server."))
      Button { install(kind, executable: executable) } label: {
        if installing == kind {
          Text(chrome: "Installing…", comment: "The MCP server is being installed.")
        } else if isInstalled {
          Text(chrome: "Reinstall", comment: "Installs the MCP server again.")
        } else {
          Text(chrome: "Install", comment: "Installs the MCP server for this agent.")
        }
      }
      .disabled(!available || installing != nil || fromPlugin)
      .modifier(InstallButtonStyle(prominent: available && !isInstalled))
    }
  }

  private func copyButton(id: String, text: String, label: String) -> some View {
    Button {
      prepare()
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      copied = id
      Task {
        try? await Task.sleep(for: .seconds(2))
        if copied == id { copied = nil }
      }
    } label: {
      if copied == id {
        Text(chrome: "Copied", comment: "Confirms text was copied to the clipboard.")
      } else {
        Text(verbatim: label)
      }
    }
  }

  private func executablePath(_ kind: AgentKind) -> String {
    kind == .codex ? AgentDetector.codexPath(settings) : AgentDetector.claudePath(settings)
  }

  private func refresh() {
    for kind in AgentMCPSetup.supportedAgents {
      installed[kind] = AgentMCPSetup.isInstalled(kind, dataFolder: dataFolder)
    }
  }

  /// Copies the bundled server into the data folder; the stored path then outlives app updates.
  @discardableResult
  private func prepare() -> Bool {
    guard let bundled = Bundle.main.url(forResource: "server", withExtension: "py") else {
      failure = "ScreenClip's MCP server is missing from this build."
      return false
    }
    do {
      try AgentMCPSetup.prepareServer(from: bundled, dataFolder: dataFolder)
      return true
    } catch {
      failure = error.localizedDescription
      return false
    }
  }

  private func install(_ kind: AgentKind, executable: String) {
    failure = nil
    guard prepare() else { return }
    installing = kind
    Task {
      defer { installing = nil; refresh() }
      let environment = ProcessEnvironment.agent()
      let add = AgentMCPSetup.installArguments(kind, server: server, dataFolder: dataFolder)
      do {
        var result = try await CommandRunner.run(
          executable, add, timeout: 30, environment: environment)
        // Replace an existing entry only when the agent refuses the add because of it, so a
        // failing CLI never leaves the agent without the tools it had.
        if result.status != 0, AgentMCPSetup.isAlreadyConfigured(result.error + result.output) {
          _ = try await CommandRunner.run(
            executable, AgentMCPSetup.removeArguments(kind, dataFolder: dataFolder), timeout: 30,
            environment: environment)
          result = try await CommandRunner.run(
            executable, add, timeout: 30, environment: environment)
        }
        if result.status != 0 {
          let detail = [result.error, result.output]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
          failure = detail ?? "\(kind.title) exited with status \(result.status)."
        }
      } catch {
        failure = error.localizedDescription
      }
    }
  }
}

/// The first install is the call to action; Reinstall stays quiet.
private struct InstallButtonStyle: ViewModifier {
  let prominent: Bool
  func body(content: Content) -> some View {
    if prominent {
      content.buttonStyle(.borderedProminent).tint(.orange)
    } else {
      content.buttonStyle(.bordered)
    }
  }
}
