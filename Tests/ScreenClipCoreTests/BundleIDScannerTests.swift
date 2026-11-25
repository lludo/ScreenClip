import ScreenClipCore
import XCTest

final class BundleIDScannerTests: XCTestCase {
  private func makeRepo(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-scan-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    for (path, text) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
  }

  private let pbxproj = """
    /* Begin XCBuildConfiguration section */
    		A /* Debug */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				BUNDLE_PREFIX = com.example;
    				PRODUCT_BUNDLE_IDENTIFIER = "$(BUNDLE_PREFIX).shop$(BUNDLE_SUFFIX)";
    				BUNDLE_SUFFIX = .debug;
    			};
    			name = Debug;
    		};
    		B /* Release */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				PRODUCT_BUNDLE_IDENTIFIER = "$(COMPANY_ID).widget";
    				"PRODUCT_BUNDLE_IDENTIFIER[sdk=iphonesimulator*]" = com.ignored.sim;
    			};
    			name = Release;
    		};
    		C /* Tests */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				PRODUCT_BUNDLE_IDENTIFIER = "$(TEAM_PREFIX).$(PRODUCT_NAME:rfc1034identifier)";
    			};
    		};
    /* End XCBuildConfiguration section */
    """

  func testFindsIdentifiersAcrossProjectFormatsAndResolvesVariables() throws {
    let root = try makeRepo([
      "App/Shop.xcodeproj/project.pbxproj": pbxproj,
      "Config/Shared.xcconfig": "COMPANY_ID = com.acme // company\nPRODUCT_BUNDLE_IDENTIFIER = com.acme.clip\n",
      "Gen/project.yml": "options:\n  bundleIdPrefix: com.gen\ntargets:\n  Tool:\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: 'com.gen.tool'\n",
      "Tuist/Project.swift": #"let t = Target(name: "T", bundleId: "io.tuist.app")"#,
      "Old/Info.plist": "<plist><dict><key>CFBundleIdentifier</key><string>org.legacy.app</string></dict></plist>",
      "Gen/Info.plist": "<plist><dict><key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string></dict></plist>",
      "node_modules/pkg/ios/Pkg.xcodeproj/project.pbxproj":
        "buildSettings = {\nPRODUCT_BUNDLE_IDENTIFIER = com.dependency.app;\n};",
      "build/Ignored.xcconfig": "PRODUCT_BUNDLE_IDENTIFIER = com.build.output\n",
    ])
    let found = Set(BundleIDScanner.scan(root: root).map(\.identifier))
    XCTAssertTrue(found.contains("com.example.shop.debug"))
    XCTAssertTrue(found.contains("com.acme.widget"))
    XCTAssertTrue(found.contains("com.acme.clip"))
    XCTAssertTrue(found.contains("com.gen.tool"))
    XCTAssertTrue(found.contains("com.gen.$(TARGET_NAME)"))
    XCTAssertTrue(found.contains("io.tuist.app"))
    XCTAssertTrue(found.contains("org.legacy.app"))
    XCTAssertTrue(found.contains("$(TEAM_PREFIX).$(PRODUCT_NAME:rfc1034identifier)"))
    XCTAssertFalse(found.contains("com.ignored.sim"))
    XCTAssertFalse(found.contains("com.dependency.app"))
    XCTAssertFalse(found.contains("com.build.output"))
    XCTAssertFalse(found.contains { $0.hasPrefix("$(PRODUCT_BUNDLE_IDENTIFIER") })
  }

  func testPatternsNeedRealTextAndMatchWholeIdentifiers() {
    XCTAssertTrue(BundleIDScanner.matches(pattern: "com.gen.$(TARGET_NAME)", "com.gen.Tool"))
    XCTAssertFalse(BundleIDScanner.matches(pattern: "com.gen.$(TARGET_NAME)", "org.com.gen.Tool"))
    XCTAssertFalse(BundleIDScanner.matches(pattern: "$(PRODUCT_BUNDLE_IDENTIFIER)", "com.anything"))
    XCTAssertFalse(BundleIDScanner.matches(pattern: "$(A).$(B)", "com.anything"))
  }

  func testPicksTheProjectWhoseSourceDeclaresTheApp() {
    let shop = Project(name: "Shop", path: "/repos/shop")
    let tools = Project(name: "Tools", path: "/repos/tools")
    let scan: (String) -> [BundleIDScanner.Declaration] = { path in
      path == "/repos/shop"
        ? [.init(identifier: "com.example.shop", source: "Shop.xcodeproj/project.pbxproj")]
        : [.init(identifier: "com.example.$(TARGET_NAME)", source: "project.yml")]
    }
    // An exact declaration beats a wildcard one.
    XCTAssertEqual(BundleIDScanner.projects(declaring: "com.example.shop", in: [shop, tools], scan: scan), [shop])
    XCTAssertEqual(BundleIDScanner.projects(declaring: "com.example.cli", in: [shop, tools], scan: scan), [tools])
    XCTAssertEqual(BundleIDScanner.projects(declaring: "org.other", in: [shop, tools], scan: scan), [])
  }

  func testDemoProjectInThisRepositoryIsFound() throws {
    let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Examples/ScreenClipKitDemo")
    guard FileManager.default.fileExists(atPath: demo.path) else { throw XCTSkip("No demo checkout") }
    XCTAssertTrue(BundleIDScanner.scan(root: demo).contains { $0.identifier == "com.example.ScreenClipKitDemo" })
  }

  func testStoreKeepsAndDeletesDiagnosticsFolders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("diag-store-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try IssueStore(root: root)
    let folder = try store.writeDiagnostics([("logs.txt", Data("hello".utf8)), ("../escape.txt", Data())])
    XCTAssertTrue(folder.hasPrefix(root.appendingPathComponent("diagnostics").path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), ["logs.txt"])
    let copy = try store.copyDiagnostics(folder)
    XCTAssertNotEqual(copy, folder)
    var capture = Capture(note: "n", imagePath: nil, context: CaptureContext())
    capture.diagnostics = ReportDiagnostics(folder: folder, files: [.init(name: "logs.txt", summary: "s", bytes: 5)])
    try store.deleteAssets(for: Issue(projectID: nil, title: "t", capture: capture))
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
    XCTAssertTrue(FileManager.default.fileExists(atPath: copy))
  }

  func testClaudeGetsReadAccessToDiagnosticsFolders() {
    var request = ClaudeTurnRequest(
      executable: "/bin/true", cwd: "/tmp", sessionID: "s", resume: false, prompt: "p", images: [],
      schema: .object([:]))
    XCTAssertFalse(ClaudeCodeClient.arguments(for: request).contains("--add-dir"))
    request.additionalDirectories = ["/data/diagnostics/A"]
    let arguments = ClaudeCodeClient.arguments(for: request)
    let index = arguments.firstIndex(of: "--add-dir")
    XCTAssertEqual(index.map { arguments[$0 + 1] }, "/data/diagnostics/A")
  }
}
