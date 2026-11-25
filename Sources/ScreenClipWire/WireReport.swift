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

/// One report as it travels from the phone to the Mac. The image is the approved, already
/// annotated and redacted PNG; originals never leave the device.
public struct WireReport: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var createdAt: Date
  public var note: String
  public var image: Data?
  public var device: DeviceContext
  public init(id: UUID = UUID(), createdAt: Date = Date(), note: String, image: Data?, device: DeviceContext) {
    self.id = id
    self.createdAt = createdAt
    self.note = note
    self.image = image
    self.device = device
  }
}

/// A `.screenclipreport` file: one JSON document holding the report and its image. Used for the
/// on-device outbox and for AirDrop or file export to the Mac.
public enum ReportFile {
  public static let pathExtension = "screenclipreport"
  public static let typeIdentifier = "com.mirageteam.screenclip.report"
  struct Envelope: Codable {
    var format: Int
    var report: WireReport
  }
  public static func encode(_ report: WireReport) throws -> Data {
    return try WireJSON.encoder().encode(Envelope(format: 1, report: report))
  }
  public static func decode(_ data: Data) throws -> WireReport {
    guard data.count <= Frame.maximumLength else { throw WireError.tooLarge }
    let decoder = WireJSON.decoder()
    struct Header: Decodable { var format: Int }
    guard let header = try? decoder.decode(Header.self, from: data) else { throw WireError.malformed }
    guard header.format == 1 else { throw WireError.unsupportedFormat }
    do { return try decoder.decode(Envelope.self, from: data).report } catch {
      throw WireError.malformed
    }
  }
  public static func write(_ report: WireReport, to url: URL) throws {
    try encode(report).write(to: url, options: .atomic)
  }
  public static func read(from url: URL) throws -> WireReport {
    try decode(Data(contentsOf: url))
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
