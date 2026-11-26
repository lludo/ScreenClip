// On iOS this module is part of ScreenClipKit and compiles to nothing outside Debug builds.
#if !os(iOS) || DEBUG

import Foundation

/// Where an iOS report came from. Stored on the Mac with the capture, shown to agents.
public struct DeviceContext: Codable, Equatable, Sendable {
  public var platform: String
  public var deviceModel: String
  public var deviceName: String
  public var osVersion: String
  public var appName: String
  public var bundleID: String
  public var appVersion: String
  public var build: String
  public var gitSHA: String?
  public var locale: String
  public var screenWidth: Double
  public var screenHeight: Double
  public var screenScale: Double
  public var orientation: String
  /// The visible screen, outermost first, such as `["UITabBarController", "SettingsViewController"]`.
  public var screenPath: [String]
  public var screenTitle: String?
  /// Set when the tester replaced the live capture with an existing screenshot from Photos. The
  /// image may show an older build, and the screen path and view tree describe the live screen.
  public var pickedScreenshot: PickedScreenshot?
  public init(
    platform: String = "iOS", deviceModel: String = "", deviceName: String = "",
    osVersion: String = "", appName: String = "", bundleID: String = "", appVersion: String = "",
    build: String = "", gitSHA: String? = nil, locale: String = "", screenWidth: Double = 0,
    screenHeight: Double = 0, screenScale: Double = 1, orientation: String = "",
    screenPath: [String] = [], screenTitle: String? = nil
  ) {
    self.platform = platform
    self.deviceModel = deviceModel
    self.deviceName = deviceName
    self.osVersion = osVersion
    self.appName = appName
    self.bundleID = bundleID
    self.appVersion = appVersion
    self.build = build
    self.gitSHA = gitSHA
    self.locale = locale
    self.screenWidth = screenWidth
    self.screenHeight = screenHeight
    self.screenScale = screenScale
    self.orientation = orientation
    self.screenPath = screenPath
    self.screenTitle = screenTitle
  }
  /// "1.2 (34), abc1234" or "1.2 (34)".
  public var testedVersion: String {
    var text = appVersion.isEmpty ? build : (build.isEmpty ? appVersion : "\(appVersion) (\(build))")
    if let gitSHA, !gitSHA.isEmpty { text += text.isEmpty ? gitSHA : ", \(gitSHA)" }
    return text
  }
  /// The innermost screen, for display.
  public var screenName: String? { screenTitle ?? screenPath.last }
}

/// An existing screenshot the tester picked in place of the live capture.
public struct PickedScreenshot: Codable, Equatable, Sendable {
  /// When the screenshot was taken, from its metadata, if it has any.
  public var takenAt: Date?
  /// True when its pixel size matches this device's screen in either orientation.
  public var matchesDevice: Bool
  public init(takenAt: Date? = nil, matchesDevice: Bool) {
    self.takenAt = takenAt
    self.matchesDevice = matchesDevice
  }
}

/// An optional file captured with a report: app logs, the view tree, or device state. Agents
/// read these only when the screenshot and note are not enough.
public struct DiagnosticFile: Codable, Equatable, Sendable {
  /// A plain file name such as `logs.txt`; the Mac accepts only `[a-z0-9-]+.(txt|json)`.
  public var name: String
  /// One line for the prompt, such as "312 log lines from the last 2 minutes".
  public var summary: String
  public var data: Data
  public init(name: String, summary: String, data: Data) {
    self.name = name
    self.summary = summary
    self.data = data
  }
  public static let maximumTotalBytes = 4 * 1024 * 1024
  public var hasSafeName: Bool {
    name.range(of: #"\A[a-z0-9-]{1,40}\.(txt|json)\z"#, options: .regularExpression) != nil
  }
}

/// One report as it travels from the phone to the Mac. The image is the approved, already
/// annotated and redacted PNG; originals never leave the device.
public struct WireReport: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var createdAt: Date
  public var note: String
  public var image: Data?
  public var device: DeviceContext
  /// Optional; reports from earlier SDK builds have none.
  public var diagnostics: [DiagnosticFile]?
  /// Set when the tester says an earlier report is still broken: this capture is added to that
  /// report on the Mac, which sends it back to the agent.
  public var followUpOf: UUID?
  /// Follow-ups wait for the Mac holding the original report. Older sent histories only recorded its name.
  public var destination: ReportDestination?
  public init(
    id: UUID = UUID(), createdAt: Date = Date(), note: String, image: Data?, device: DeviceContext,
    diagnostics: [DiagnosticFile]? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.note = note
    self.image = image
    self.device = device
    self.diagnostics = diagnostics
  }
}

public struct ReportDestination: Codable, Equatable, Sendable {
  public var macID: UUID?
  public var name: String
  public init(macID: UUID?, name: String) {
    self.macID = macID
    self.name = name
  }
  public func matches(macID: UUID, name: String?) -> Bool {
    self.macID.map { $0 == macID } ?? (self.name == name)
  }
}

/// A `.screenclipreport` file: one JSON document holding the report and its image. Used for the
/// on-device outbox and for AirDrop or file export to the Mac.
public enum ReportFile {
  public static let pathExtension = "screenclipreport"
  public static let typeIdentifier = "com.mirageteam.screenclip.report"
  struct Envelope<Report: Codable>: Codable {
    var format: Int
    var report: Report
  }
  /// The fields needed to list the outbox, without decoding every screenshot at app startup.
  public struct Summary: Codable, Identifiable, Sendable {
    public var id: UUID
    public var note: String
    public var createdAt: Date
    public var followUpOf: UUID?
    public var destination: ReportDestination?
    public init(_ report: WireReport) {
      id = report.id
      note = report.note
      createdAt = report.createdAt
      followUpOf = report.followUpOf
      destination = report.destination
    }
  }
  public static func encode(_ report: WireReport) throws -> Data {
    let data = try WireJSON.encoder().encode(Envelope(format: 1, report: report))
    // Leave room for the sealed frame's kind and authentication tag on delivery.
    guard data.count <= Frame.maximumLength - Frame.sealedOverhead else { throw WireError.tooLarge }
    return data
  }
  public static func decode(_ data: Data) throws -> WireReport {
    try decode(WireReport.self, from: data)
  }
  private static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
    guard data.count <= Frame.maximumLength else { throw WireError.tooLarge }
    let decoder = WireJSON.decoder()
    guard let header = try? decoder.decode(Header.self, from: data) else { throw WireError.malformed }
    guard header.format == 1 else { throw WireError.unsupportedFormat }
    do { return try decoder.decode(Envelope<T>.self, from: data).report } catch {
      throw WireError.malformed
    }
  }
  private struct Header: Decodable { var format: Int }
  public static func write(_ report: WireReport, to url: URL) throws {
    try encode(report).write(to: url, options: .atomic)
  }
  public static func read(from url: URL) throws -> WireReport {
    try decode(contents(of: url))
  }
  public static func summary(from url: URL) throws -> Summary {
    try decode(Summary.self, from: contents(of: url))
  }
  private static func contents(of url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw WireError.malformed }
    guard let size = values.fileSize, size <= Frame.maximumLength else { throw WireError.tooLarge }
    return try Data(contentsOf: url, options: .mappedIfSafe)
  }
}

public enum WireError: Error, Equatable, LocalizedError {
  case unsupportedFormat, tooLarge, malformed, authenticationFailed, notPaired, closed

  public var errorDescription: String? {
    switch self {
    case .unsupportedFormat: return "This report was made by a newer ScreenClip."
    case .tooLarge: return "The report is too large."
    case .malformed: return "The report could not be read."
    case .authenticationFailed: return "The connection could not be verified."
    case .notPaired: return "This device is not paired with this Mac."
    case .closed: return "The connection closed."
    }
  }
}

#endif
