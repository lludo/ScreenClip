import XCTest

@testable import ScreenClipCore

final class AgentSelectionTests: XCTestCase {
  func testProviderPhrasesUseOneTemplate() {
    for phrase in ProviderPhrase.allCases {
      let patterns = AgentKind.allCases.map { kind in
        phrase.english(kind).replacingOccurrences(of: kind.title, with: "%@")
      }
      XCTAssertEqual(Set(patterns).count, 1, phrase.rawValue)
      XCTAssertEqual(patterns[0], phrase.template)
      for kind in AgentKind.allCases {
        XCTAssertEqual(phrase.english(kind), phrase.template.replacingOccurrences(of: "%@", with: kind.title))
      }
    }
    XCTAssertEqual(ProviderPhrase.ready.english(.codex), "Codex ready")
    XCTAssertEqual(ProviderPhrase.ready.english(.claude), "Claude Code ready")
    XCTAssertEqual(ProviderPhrase.ready.english(.external), "Grok Bot ready")
    XCTAssertEqual(ProviderPhrase.readyDetail(kind: .external, extra: "example.invalid"), "Grok Bot ready · example.invalid")
    XCTAssertEqual(
      ProviderPhrase.noResponse(kind: .codex, path: "/tmp/codex"), "Codex at /tmp/codex did not respond.")
  }

  func testResolutionUsesSystemThenProjectThenCapture() {
    var project = Project(name: "Demo", path: "/demo")
    XCTAssertNil(project.defaultAgent)
    XCTAssertEqual(AgentSelection.projectDefault(project, system: .codex), .codex)
    XCTAssertEqual(AgentSelection.projectDefault(project, system: .claude), .claude)
    project.defaultAgent = .external
    XCTAssertEqual(AgentSelection.projectDefault(project, system: .claude), .external)
    XCTAssertEqual(AgentSelection.projectDefault(project, system: .codex), .external)
    XCTAssertEqual(
      AgentSelection.capture(override: .codex, project: project, system: .claude), .codex)
    XCTAssertEqual(
      AgentSelection.capture(override: nil, project: project, system: .claude), .external)
    XCTAssertEqual(AgentSelection.capture(override: nil, project: nil, system: .codex), .codex)
  }

  func testOlderProjectsMigrateAnEnabledGrokToggleAndKeepInherit() throws {
    let id = UUID()
    func decoded(_ fields: [String: Any]) throws -> Project {
      var object: [String: Any] = [
        "id": id.uuidString, "name": "Demo", "path": "/demo", "baseBranch": "main",
        "origins": [String](), "bundleIDs": [String](), "validationCommand": "", "autoMerge": true,
      ]
      for (key, value) in fields { object[key] = value }
      let data = try JSONSerialization.data(withJSONObject: object)
      return try JSONDecoder().decode(Project.self, from: data)
    }
    let untouched = try decoded([:])
    XCTAssertNil(untouched.defaultAgent)
    XCTAssertFalse(untouched.sendsExternalScreenshots)
    let optedIn = try decoded(["allowExternalScreenshots": true])
    XCTAssertEqual(optedIn.defaultAgent, .external)
    XCTAssertTrue(optedIn.sendsExternalScreenshots)
    let explicitInherit = try decoded(["allowExternalScreenshots": true, "defaultAgent": NSNull()])
    XCTAssertNil(explicitInherit.defaultAgent)
    let explicitCodex = try decoded(["defaultAgent": "codex", "allowExternalScreenshots": true])
    XCTAssertEqual(explicitCodex.defaultAgent, .codex)

    var inherited = try decoded(["allowExternalScreenshots": true, "defaultAgent": NSNull()])
    let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inherited)) as? [String: Any]
    XCTAssertTrue(saved?["defaultAgent"] is NSNull)
    inherited.allowExternalScreenshots = true
    let again = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(inherited))
    XCTAssertNil(again.defaultAgent)
    XCTAssertEqual(AgentSelection.projectDefault(again, system: .claude), .claude)
    XCTAssertEqual(AgentSelection.projectDefault(optedIn, system: .codex), .external)
  }
}
