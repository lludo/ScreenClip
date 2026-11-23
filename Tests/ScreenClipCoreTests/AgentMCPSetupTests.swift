import XCTest

@testable import ScreenClipCore

final class AgentMCPSetupTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    addTeardownBlock { [home] in try? FileManager.default.removeItem(at: home!) }
  }

  private var standardData: URL { home.appendingPathComponent("Library/Application Support/ScreenClip") }

  private func write(_ text: String, to path: String) throws {
    let url = home.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  func testInstallCommandsUseUserScopeAndTheCopiedServer() {
    let server = AgentMCPSetup.serverURL(dataFolder: standardData)
    XCTAssertEqual(server.lastPathComponent, "server.py")
    XCTAssertEqual(
      AgentMCPSetup.installArguments(.claude, server: server, dataFolder: standardData, home: home),
      ["mcp", "add", "--scope", "user", "screenclip", "--", "/usr/bin/python3", server.path])
    XCTAssertEqual(
      AgentMCPSetup.installArguments(.codex, server: server, dataFolder: standardData, home: home),
      ["mcp", "add", "screenclip", "--", "/usr/bin/python3", server.path])
    XCTAssertEqual(AgentMCPSetup.removeArguments(.claude), ["mcp", "remove", "--scope", "user", "screenclip"])
    XCTAssertEqual(AgentMCPSetup.removeArguments(.codex), ["mcp", "remove", "screenclip"])
    XCTAssertEqual(AgentMCPSetup.installArguments(.external, server: server, dataFolder: standardData), [])
  }

  func testAnotherDataFolderIsPassedToTheServer() {
    let data = home.appendingPathComponent("Dev Queue")
    let server = AgentMCPSetup.serverURL(dataFolder: data)
    let claude = AgentMCPSetup.installArguments(.claude, server: server, dataFolder: data, home: home)
    XCTAssertEqual(claude[4...5], ["-e", "SCREENCLIP_DATA_DIR=\(data.path)"])
    let codex = AgentMCPSetup.installArguments(.codex, server: server, dataFolder: data, home: home)
    XCTAssertEqual(codex[2...3], ["--env", "SCREENCLIP_DATA_DIR=\(data.path)"])
    let command = AgentMCPSetup.terminalCommand(.claude, server: server, dataFolder: data, home: home)
    XCTAssertTrue(command.hasPrefix("claude mcp add --scope user -e 'SCREENCLIP_DATA_DIR="), command)
    let json = AgentMCPSetup.genericConfiguration(server: server, dataFolder: data, home: home)
    let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    let entry = (object?["mcpServers"] as? [String: Any])?["screenclip"] as? [String: Any]
    XCTAssertEqual(entry?["command"] as? String, "/usr/bin/python3")
    XCTAssertEqual(entry?["args"] as? [String], [server.path])
    XCTAssertEqual((entry?["env"] as? [String: String])?["SCREENCLIP_DATA_DIR"], data.path)
  }

  func testShellQuoting() {
    XCTAssertEqual(AgentMCPSetup.shellQuote("/usr/bin/python3"), "/usr/bin/python3")
    XCTAssertEqual(AgentMCPSetup.shellQuote("/a b/it's"), "'/a b/it'\\''s'")
  }

  func testPrepareServerCopiesAndRefreshesTheScript() throws {
    let bundled = home.appendingPathComponent("bundled.py")
    try "print('v1')".write(to: bundled, atomically: true, encoding: .utf8)
    let copied = try AgentMCPSetup.prepareServer(from: bundled, dataFolder: standardData)
    XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "print('v1')")
    let mode = try FileManager.default.attributesOfItem(atPath: copied.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o700)
    try "print('v2')".write(to: bundled, atomically: true, encoding: .utf8)
    try AgentMCPSetup.prepareServer(from: bundled, dataFolder: standardData)
    XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "print('v2')")
  }

  func testDetectsClaudeServerOrPlugin() throws {
    XCTAssertFalse(AgentMCPSetup.isInstalled(.claude, home: home))
    try write(#"{"mcpServers": {"other": {}}}"#, to: ".claude.json")
    XCTAssertFalse(AgentMCPSetup.isInstalled(.claude, home: home))
    try write(#"{"mcpServers": {"screenclip": {"command": "python3"}}}"#, to: ".claude.json")
    XCTAssertTrue(AgentMCPSetup.isInstalled(.claude, home: home))
    try write("{}", to: ".claude.json")
    try write(#"{"enabledPlugins": {"screenclip@screenclip": false}}"#, to: ".claude/settings.json")
    XCTAssertFalse(AgentMCPSetup.isInstalled(.claude, home: home))
    try write(#"{"enabledPlugins": {"screenclip@screenclip": true}}"#, to: ".claude/settings.json")
    XCTAssertTrue(AgentMCPSetup.isInstalled(.claude, home: home))
  }

  func testDetectsCodexServer() throws {
    XCTAssertFalse(AgentMCPSetup.isInstalled(.codex, home: home))
    try write("[mcp_servers.screenclip_other]\n[mcp_servers.screenclip.env]\n", to: ".codex/config.toml")
    XCTAssertFalse(AgentMCPSetup.isInstalled(.codex, home: home))
    try write("model = \"o3\"\n\n[mcp_servers.screenclip]\ncommand = \"python3\"\n", to: ".codex/config.toml")
    XCTAssertTrue(AgentMCPSetup.isInstalled(.codex, home: home))
    try write("[mcp_servers.\"screenclip\"]\n", to: ".codex/config.toml")
    XCTAssertTrue(AgentMCPSetup.isInstalled(.codex, home: home))
    XCTAssertFalse(AgentMCPSetup.isInstalled(.external, home: home))
  }
}
