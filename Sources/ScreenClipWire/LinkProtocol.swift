// On iOS this module is part of ScreenClipKit and compiles to nothing outside Debug builds.
#if !os(iOS) || DEBUG

import CryptoKit
import Foundation
import ImageIO

/// The local-network protocol between the iOS SDK (client) and the Mac app (listener).
///
/// Handshake, in clear:
///   client → `hello` (device identity, nonce, and a public key when pairing)
///   server → `challenge` (session) or `pairChallenge` (pairing), or `rejected`
/// Then every frame is sealed with ChaCha20-Poly1305 under per-direction keys derived from the
/// pairing key and both nonces, with a counter nonce, so frames cannot be replayed or reordered.
/// When pairing, both screens show the same 6-digit code; the Mac sends the sealed `welcome`
/// only after the person confirms it.
public enum LinkProtocol {
  public static let version = 1
  public static let serviceType = "_screenclip._tcp"
  public static let txtMacID = "id"
  public static let txtVersion = "v"
}

public struct Hello: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var deviceID: UUID
  public var deviceName: String
  public var deviceModel: String
  public var appName: String
  public var bundleID: String
  public var nonce: Data
  /// Present only when the device asks to pair.
  public var pairingPublicKey: Data?
  public init(
    protocolVersion: Int = LinkProtocol.version, deviceID: UUID, deviceName: String,
    deviceModel: String, appName: String, bundleID: String, nonce: Data, pairingPublicKey: Data?
  ) {
    self.protocolVersion = protocolVersion
    self.deviceID = deviceID
    self.deviceName = deviceName
    self.deviceModel = deviceModel
    self.appName = appName
    self.bundleID = bundleID
    self.nonce = nonce
    self.pairingPublicKey = pairingPublicKey
  }
}

public struct Challenge: Codable, Equatable, Sendable {
  public var macID: UUID
  public var macName: String
  public var nonce: Data
  /// Present only in answer to a pairing hello.
  public var pairingPublicKey: Data?
  public init(macID: UUID, macName: String, nonce: Data, pairingPublicKey: Data? = nil) {
    self.macID = macID
    self.macName = macName
    self.nonce = nonce
    self.pairingPublicKey = pairingPublicKey
  }
}

public enum RejectReason: String, Codable, Sendable {
  /// The Mac has no key for this device; the device should forget its pairing.
  case notPaired
  /// The device asked to pair while the Mac's pairing window was closed.
  case pairingClosed
  /// The person declined the pairing code.
  case declined
  case unsupportedVersion
  case busy
}

/// A report still waiting on the device, as the Mac lists it.
public struct QueuedReport: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var note: String
  public var createdAt: Date
  public init(id: UUID, note: String, createdAt: Date) {
    self.id = id
    self.note = String(note.prefix(160))
    self.createdAt = createdAt
  }
}

/// Where a delivered report stands on the Mac, for the device's Sent list.
public struct ReportState: Codable, Equatable, Identifiable, Sendable {
  /// The report's id, which is also its capture id on the Mac.
  public var id: UUID
  public var reportNumber: Int?
  public var title: String
  /// An `IssueStatus` raw value, or `removed` when the report was deleted on the Mac.
  public var status: String
  public var projectName: String?
  public var agent: String?
  public var pullRequestURL: String?
  public var updatedAt: Date
  public init(
    id: UUID, reportNumber: Int?, title: String, status: String, projectName: String?, agent: String?,
    pullRequestURL: String?, updatedAt: Date
  ) {
    self.id = id
    self.reportNumber = reportNumber
    self.title = title
    self.status = status
    self.projectName = projectName
    self.agent = agent
    self.pullRequestURL = pullRequestURL
    self.updatedAt = updatedAt
  }
  public static let removed = "removed"
}

public enum LinkMessage: Codable, Equatable, Sendable {
  // In clear, during the handshake.
  case hello(Hello)
  case challenge(Challenge)
  case rejected(RejectReason)
  // Sealed.
  case welcome(macID: UUID, macName: String)
  case report(WireReport)
  case ack(id: UUID)
  case failed(id: UUID, message: String)
  case sendPending
  /// Device → Mac: the reports still saved on the device.
  case queue([QueuedReport])
  /// Device → Mac: delivered reports whose status the device shows; the Mac answers with
  /// `reportStates` and sends updates while connected.
  case track(ids: [UUID])
  /// Mac → device.
  case reportStates([ReportState])
  /// Device → Mac: the tester checked a merged fix and it works.
  case verify(id: UUID)
  case ping

  public var isHandshake: Bool {
    switch self {
    case .hello, .challenge, .rejected: return true
    default: return false
    }
  }
}

/// Length-prefixed frames: a 4-byte big-endian length, one kind byte, then the payload.
public enum Frame {
  public static let maximumLength = 48 * 1024 * 1024
  public enum Kind: UInt8 { case plain = 0, sealed = 1 }

  public static func encode(kind: Kind, payload: Data) -> Data {
    var length = UInt32(payload.count + 1).bigEndian
    var data = Data(bytes: &length, count: 4)
    data.append(kind.rawValue)
    data.append(payload)
    return data
  }
  /// The frame length announced by a 4-byte header, or nil when it is out of range.
  public static func length(header: Data) -> Int? {
    guard header.count == 4 else { return nil }
    let value = header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    guard value >= 1, value <= maximumLength else { return nil }
    return Int(value)
  }

  static let encoder = WireJSON.encoder()
  static let decoder = WireJSON.decoder()
  public static func json(_ message: LinkMessage) throws -> Data { try encoder.encode(message) }
  public static func message(_ data: Data) throws -> LinkMessage {
    do { return try decoder.decode(LinkMessage.self, from: data) } catch { throw WireError.malformed }
  }
}

/// Per-direction ChaCha20-Poly1305 with counter nonces.
public struct SecureChannel: Sendable {
  let sendKey: SymmetricKey
  let receiveKey: SymmetricKey
  var sendCounter: UInt64 = 0
  var receiveCounter: UInt64 = 0

  public enum Role: Sendable { case client, server }

  public init(pairingKey: SymmetricKey, clientNonce: Data, serverNonce: Data, role: Role) {
    let salt = clientNonce + serverNonce
    func derive(_ label: String) -> SymmetricKey {
      HKDF<SHA256>.deriveKey(
        inputKeyMaterial: pairingKey, salt: salt, info: Data("screenclip-link-\(label)-v1".utf8),
        outputByteCount: 32)
    }
    let clientToServer = derive("c2s")
    let serverToClient = derive("s2c")
    sendKey = role == .client ? clientToServer : serverToClient
    receiveKey = role == .client ? serverToClient : clientToServer
  }

  static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
    var big = counter.bigEndian
    return try ChaChaPoly.Nonce(data: Data(count: 4) + Data(bytes: &big, count: 8))
  }
  public mutating func seal(_ plaintext: Data) throws -> Data {
    let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter))
    sendCounter += 1
    return Data(box.ciphertext) + box.tag
  }
  public mutating func open(_ data: Data) throws -> Data {
    guard data.count >= 16 else { throw WireError.authenticationFailed }
    do {
      let box = try ChaChaPoly.SealedBox(
        nonce: Self.nonce(receiveCounter), ciphertext: data.dropLast(16), tag: data.suffix(16))
      let plaintext = try ChaChaPoly.open(box, using: receiveKey)
      receiveCounter += 1
      return plaintext
    } catch { throw WireError.authenticationFailed }
  }
}

/// One side of a pairing: an ephemeral P-256 key agreement.
public struct PairingExchange: Sendable {
  public let privateKey: P256.KeyAgreement.PrivateKey
  public init() { privateKey = P256.KeyAgreement.PrivateKey() }
  public var publicKey: Data { privateKey.publicKey.rawRepresentation }

  public struct Result: Sendable {
    /// Stored on both sides; the long-term key for this device and Mac.
    public let pairingKey: SymmetricKey
    /// Shown on both screens for the person to compare, such as "042 917".
    public let code: String
  }

  /// Derives the pairing key and the comparison code. Both public keys and both nonces are bound
  /// in, so a relay that swaps keys produces a different code on each screen.
  public func complete(
    peerPublicKey: Data, clientPublicKey: Data, serverPublicKey: Data, clientNonce: Data,
    serverNonce: Data
  ) throws -> Result {
    let peer: P256.KeyAgreement.PublicKey
    do { peer = try P256.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey) } catch {
      throw WireError.authenticationFailed
    }
    let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
    let salt = clientNonce + serverNonce
    let transcript = clientPublicKey + serverPublicKey
    let key = shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: salt, sharedInfo: Data("screenclip-pair-key-v1".utf8) + transcript,
      outputByteCount: 32)
    let codeBytes = shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: salt, sharedInfo: Data("screenclip-pair-code-v1".utf8) + transcript,
      outputByteCount: 4
    ).withUnsafeBytes { Data($0) }
    let value = codeBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
    let digits = String(format: "%06u", value)
    return Result(
      pairingKey: key, code: "\(digits.prefix(3)) \(digits.suffix(3))")
  }
}

public enum Nonce {
  public static func make() -> Data {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
  }
}

extension SymmetricKey {
  public var data: Data { withUnsafeBytes { Data($0) } }
}

public enum PNG {
  public static func encode(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
  public static func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
}

/// JSON for frames and report files. Dates stay in Foundation's default numeric form so a
/// report round-trips exactly.
enum WireJSON {
  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
  static func decoder() -> JSONDecoder { JSONDecoder() }
}

#endif
