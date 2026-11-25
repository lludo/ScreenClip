import Foundation

/// Finds the app bundle identifiers a repository declares, so a report from an iOS app (whose
/// bundle ID usually differs from the Mac app's) routes to the right project the first time.
///
/// Reads Xcode projects (`PRODUCT_BUNDLE_IDENTIFIER` in every target and configuration),
/// `.xcconfig` files, Info.plists, XcodeGen `project.yml`, Tuist `Project.swift`, and
/// `Package.swift` app products. Build-setting variables are resolved from the same build
/// settings block or any xcconfig; what cannot be resolved stays a wildcard.
public enum BundleIDScanner {
  public struct Declaration: Equatable, Sendable {
    /// The identifier, possibly with unresolved `$(VARIABLE)` parts.
    public var identifier: String
    /// Path relative to the repository root.
    public var source: String
    public init(identifier: String, source: String) {
      self.identifier = identifier
      self.source = source
    }
    public var isResolved: Bool { !identifier.contains("$") }
  }

  static let skippedFolders: Set<String> = [
    ".git", ".build", "build", "Build", "DerivedData", "Pods", "Carthage", "node_modules", ".swiftpm",
    "vendor", "dist", ".next", "xcuserdata", ".screenclip",
  ]
  static let maximumEntries = 40_000
  static let maximumDepth = 8
  static let maximumFileBytes = 4 * 1024 * 1024

  // MARK: Matching

  /// Projects whose source declares `bundleID`. Exact declarations win over wildcard ones.
  public static func projects(
    declaring bundleID: String, in projects: [Project], scan: (String) -> [Declaration] = cachedScan
  ) -> [Project] {
    guard !bundleID.isEmpty else { return [] }
    var exact: [Project] = []
    var pattern: [Project] = []
    for project in projects where !project.path.isEmpty {
      let declarations = scan(project.path)
      if declarations.contains(where: { $0.isResolved && $0.identifier == bundleID }) {
        exact.append(project)
      } else if declarations.contains(where: { !$0.isResolved && matches(pattern: $0.identifier, bundleID) }) {
        pattern.append(project)
      }
    }
    return exact.isEmpty ? pattern : exact
  }

  /// `com.example.$(SUFFIX)` matches `com.example.shop`. A pattern needs real text besides
  /// variables, so `$(PRODUCT_BUNDLE_IDENTIFIER)` alone matches nothing.
  public static func matches(pattern: String, _ bundleID: String) -> Bool {
    let literal = pattern.replacingOccurrences(of: variablePattern, with: "", options: .regularExpression)
    guard literal.filter({ $0.isLetter || $0.isNumber }).count >= 4 else { return false }
    var expression = "^"
    var remainder = pattern[...]
    while let range = remainder.range(of: variablePattern, options: .regularExpression) {
      expression += NSRegularExpression.escapedPattern(for: String(remainder[..<range.lowerBound]))
      expression += "[A-Za-z0-9.-]+"
      remainder = remainder[range.upperBound...]
    }
    expression += NSRegularExpression.escapedPattern(for: String(remainder)) + "$"
    return bundleID.range(of: expression, options: .regularExpression) != nil
  }

  static let variablePattern = #"\$[({][A-Za-z0-9_:]+[)}]"#

  // MARK: Scanning

  private static let cacheLock = NSLock()
  nonisolated(unsafe) private static var cache: [String: (date: Date, declarations: [Declaration])] = [:]

  /// Scans at most once a minute per repository.
  public static func cachedScan(_ path: String) -> [Declaration] {
    cacheLock.lock()
    if let entry = cache[path], Date().timeIntervalSince(entry.date) < 60 {
      cacheLock.unlock()
      return entry.declarations
    }
    cacheLock.unlock()
    let declarations = scan(root: URL(fileURLWithPath: path))
    cacheLock.lock()
    cache[path] = (Date(), declarations)
    cacheLock.unlock()
    return declarations
  }

  public static func scan(root: URL) -> [Declaration] {
    let files = candidateFiles(root: root).sorted { $0.path < $1.path }
    // xcconfig values first, so project files can resolve variables they define.
    var configValues: [String: Set<String>] = [:]
    var configurations: [(URL, [String: String])] = []
    var declarations: [Declaration] = []
    for file in files where file.pathExtension == "xcconfig" {
      guard let text = read(file) else { continue }
      let settings = Dictionary(buildSettings(inXcconfig: text), uniquingKeysWith: { _, last in last })
      configurations.append((file, settings))
      for (key, value) in settings {
        configValues[key, default: []].insert(value)
      }
    }
    // A project can have different Debug and Release values for the same variable.
    // Only borrow values from other files when all their declarations agree.
    let shared = configValues.compactMapValues { $0.count == 1 ? $0.first : nil }
    for (file, settings) in configurations {
      if let id = settings["PRODUCT_BUNDLE_IDENTIFIER"] {
        declarations.append(Declaration(identifier: resolve(id, block: settings, config: shared), source: relative(file, root)))
      }
    }
    for file in files where file.pathExtension != "xcconfig" {
      guard let text = read(file) else { continue }
      let source = relative(file, root)
      switch file.pathExtension {
      case "pbxproj":
        for block in buildSettingBlocks(inPbxproj: text) {
          guard let identifier = block["PRODUCT_BUNDLE_IDENTIFIER"] else { continue }
          declarations.append(
            Declaration(identifier: resolve(identifier, block: block, config: shared), source: source))
        }
      case "plist":
        if let identifier = plistBundleIdentifier(text), !identifier.hasPrefix("$(PRODUCT_BUNDLE_IDENTIFIER") {
          declarations.append(Declaration(identifier: resolve(identifier, block: [:], config: shared), source: source))
        }
      case "yml", "yaml":
        for identifier in xcodeGenIdentifiers(text) {
          declarations.append(Declaration(identifier: resolve(identifier, block: [:], config: shared), source: source))
        }
      case "swift":
        for identifier in swiftManifestIdentifiers(text) {
          declarations.append(Declaration(identifier: identifier, source: source))
        }
      default:
        break
      }
    }
    var seen = Set<String>()
    return declarations.filter { !$0.identifier.isEmpty && seen.insert($0.identifier).inserted }
  }

  static func candidateFiles(root: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsPackageDescendants])
    else { return [] }
    var files: [URL] = []
    var visited = 0
    for case let url as URL in enumerator {
      visited += 1
      if visited > maximumEntries { break }
      let name = url.lastPathComponent
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values?.isSymbolicLink == true {
        enumerator.skipDescendants()
        continue
      }
      if values?.isDirectory == true {
        if skippedFolders.contains(name) || enumerator.level > maximumDepth {
          enumerator.skipDescendants()
          continue
        }
        // .xcodeproj is a package: look inside for project.pbxproj.
        if url.pathExtension == "xcodeproj" {
          let project = url.appendingPathComponent("project.pbxproj")
          if FileManager.default.fileExists(atPath: project.path) { files.append(project) }
        }
        continue
      }
      switch url.pathExtension {
      case "xcconfig": files.append(url)
      case "plist" where name.lowercased().contains("info"): files.append(url)
      case "yml" where name == "project.yml", "yaml" where name == "project.yaml": files.append(url)
      case "swift" where name == "Project.swift" || name == "Package.swift": files.append(url)
      default: break
      }
    }
    return files
  }

  static func read(_ url: URL) -> String? {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumFileBytes,
      let data = try? Data(contentsOf: url)
    else { return nil }
    if data.starts(with: Array("bplist".utf8)),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let identifier = plist["CFBundleIdentifier"] as? String
    {
      return "<key>CFBundleIdentifier</key><string>\(identifier)</string>"
    }
    return String(data: data, encoding: .utf8)
  }

  static func relative(_ url: URL, _ root: URL) -> String {
    let path = url.standardizedFileURL.path
    let base = root.standardizedFileURL.path + "/"
    return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
  }

  // MARK: Parsers

  /// Each `buildSettings = { … };` block of a pbxproj as key/value pairs.
  static func buildSettingBlocks(inPbxproj text: String) -> [[String: String]] {
    var blocks: [[String: String]] = []
    var remainder = text[...]
    while let start = remainder.range(of: "buildSettings = {") {
      var depth = 1
      var index = start.upperBound
      while index < remainder.endIndex, depth > 0 {
        let character = remainder[index]
        if character == "{" { depth += 1 } else if character == "}" { depth -= 1 }
        index = remainder.index(after: index)
      }
      let body = remainder[start.upperBound..<index]
      var block: [String: String] = [:]
      for line in body.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let equals = trimmed.firstIndex(of: "="), trimmed.hasSuffix(";") else { continue }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        var value = trimmed[trimmed.index(after: equals)...].dropLast().trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        if !key.isEmpty, !key.contains("[") { block[key] = value }
      }
      blocks.append(block)
      remainder = remainder[index...]
    }
    return blocks
  }

  static func buildSettings(inXcconfig text: String) -> [(String, String)] {
    text.split(separator: "\n").compactMap { line in
      let trimmed = line.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
      let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
      let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty, !key.contains("["), !value.isEmpty else { return nil }
      return (key, value)
    }
  }

  static func plistBundleIdentifier(_ text: String) -> String? {
    guard let range = text.range(of: #"<key>CFBundleIdentifier</key>\s*<string>([^<]+)</string>"#, options: .regularExpression)
    else { return nil }
    let match = String(text[range])
    return match.components(separatedBy: "<string>").last?.replacingOccurrences(of: "</string>", with: "")
      .trimmingCharacters(in: .whitespaces)
  }

  /// `PRODUCT_BUNDLE_IDENTIFIER: x` entries, and `bundleIdPrefix: com.x` as `com.x.$(TARGET_NAME)`.
  static func xcodeGenIdentifiers(_ text: String) -> [String] {
    var identifiers: [String] = []
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      for (key, suffix) in [("PRODUCT_BUNDLE_IDENTIFIER:", ""), ("bundleIdPrefix:", ".$(TARGET_NAME)")]
      where trimmed.hasPrefix(key) {
        let value = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if !value.isEmpty { identifiers.append(value + suffix) }
      }
    }
    return identifiers
  }

  /// `bundleId: "…"` (Tuist) and `bundleIdentifier: "…"` (SwiftPM app products).
  static func swiftManifestIdentifiers(_ text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: #"bundleId(?:entifier)?:\s*"([^"]+)""#) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).compactMap {
      Range($0.range(at: 1), in: text).map { String(text[$0]) }
    }
  }

  /// Replaces `$(KEY)` and `${KEY}` with values from the same build settings, then xcconfigs.
  /// `$(PRODUCT_NAME:rfc1034identifier)` is resolved too. Unknown variables are kept.
  static func resolve(_ value: String, block: [String: String], config: [String: String]) -> String {
    var current = value
    // A few passes resolve variables defined in terms of other variables.
    for _ in 0..<5 {
      var output = ""
      var remainder = current[...]
      var changed = false
      while let match = remainder.range(of: variablePattern, options: .regularExpression) {
        output += remainder[..<match.lowerBound]
        let token = String(remainder[match])
        let parts = token.dropFirst(2).dropLast().split(separator: ":", maxSplits: 1).map(String.init)
        let key = parts.first ?? ""
        if key == "inherited" {
          changed = true
        } else if let replacement = block[key] ?? config[key], !replacement.contains(token) {
          var text = replacement
          if parts.count > 1, parts[1].hasPrefix("rfc1034identifier"), !text.contains("$") {
            text = String(text.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" })
          }
          output += text
          changed = true
        } else {
          output += token
        }
        remainder = remainder[match.upperBound...]
      }
      output += remainder
      current = output
      if !changed { break }
    }
    return current.trimmingCharacters(in: .whitespaces)
  }
}
