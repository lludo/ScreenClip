import Combine
import CryptoKit
import Foundation
import Network
import Security

/// The Mac side of ScreenClipKit: advertises ScreenClip on the local network with Bonjour,
/// pairs iOS devices, and accepts reports from paired devices only.
///
/// Reports become prompts for coding agents that can write to the tester's repositories, so an
/// unpaired device can never deliver one. Pairing is accepted only while the pairing window is
/// open, and only after the person confirms that both screens show the same code.
@MainActor public final class IOSReceiver: ObservableObject {
  public enum ServerState: Equatable {
    case stopped
    case starting
    case listening(port: UInt16)
    case failed(String)
  }
  public struct Device: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var model: String
    public var apps: [String]
    public var pairedAt: Date
    public var lastSeen: Date?
    public init(id: UUID, name: String, model: String, apps: [String], pairedAt: Date, lastSeen: Date?) {
      self.id = id
      self.name = name
      self.model = model
      self.apps = apps
      self.pairedAt = pairedAt
      self.lastSeen = lastSeen
    }
  }
  public struct PairingRequest: Identifiable, Equatable {
    public let id = UUID()
    public let deviceName: String
    public let appName: String
    public let code: String
  }
  /// What the device's pairing record stores; the key never leaves the Keychain otherwise.
  public struct DeviceRecord: Codable, Equatable {
    public var device: Device
    public var key: Data
    public init(device: Device, key: Data) {
      self.device = device
      self.key = key
    }
  }
  public enum ImportResult: Equatable { case imported, duplicate }
  /// The latest thing that happened, for the iOS settings status line.
  public enum Event: Equatable {
    case fetched(devices: Int)
    case received(deviceName: String)
    case paired(deviceName: String)
  }

  @Published public private(set) var state: ServerState = .stopped
  @Published public private(set) var devices: [Device] = []
  /// Connected devices and the number of saved reports each says it is holding.
  @Published public private(set) var connected: [UUID: Int] = [:]
  @Published public private(set) var pairingOpen = false
  @Published public private(set) var pairingRequest: PairingRequest?
  @Published public private(set) var lastEvent: Event?

  public let macID: UUID
  public let macName: String
  /// Saves one report into the queue. Throws to refuse it; the device keeps it and retries.
  public var importReport: (WireReport) throws -> ImportResult = { _ in .imported }
  private let loadRecords: () -> [DeviceRecord]
  private let saveRecords: ([DeviceRecord]) -> Void
  private var records: [DeviceRecord]
  private var listener: NWListener?
  private var sessions: [ObjectIdentifier: Session] = [:]
  static let maximumSessions = 16

  final class Session {
    let link: LinkConnection
    var hello: Hello?
    var ready = false
    var pendingKey: SymmetricKey?
    init(link: LinkConnection) { self.link = link }
  }

  public init(
    macID: UUID = IOSReceiver.storedMacID(), macName: String = IOSReceiver.defaultMacName(),
    loadRecords: @escaping () -> [DeviceRecord] = IOSReceiverKeychain.load,
    saveRecords: @escaping ([DeviceRecord]) -> Void = IOSReceiverKeychain.save
  ) {
    self.macID = macID
    self.macName = macName
    self.loadRecords = loadRecords
    self.saveRecords = saveRecords
    records = loadRecords()
    devices = records.map(\.device)
  }

  nonisolated public static func storedMacID(defaults: UserDefaults = .standard) -> UUID {
    if let text = defaults.string(forKey: "iosReceiverMacID"), let id = UUID(uuidString: text) { return id }
    let id = UUID()
    defaults.set(id.uuidString, forKey: "iosReceiverMacID")
    return id
  }
  nonisolated public static func defaultMacName() -> String {
    Host.current().localizedName ?? ProcessInfo.processInfo.hostName
  }

  public var isRunning: Bool {
    switch state {
    case .starting, .listening: return true
    default: return false
    }
  }

  // MARK: Server

  /// Starts listening. `port` is for tests; normally the system picks one and Bonjour advertises it.
  public func start(port: NWEndpoint.Port = .any, advertise: Bool = true) {
    guard listener == nil else { return }
    do {
      let listener = try NWListener(using: LinkConnection.tcpParameters(), on: port)
      if advertise {
        listener.service = NWListener.Service(
          name: macName, type: LinkProtocol.serviceType, domain: nil,
          txtRecord: NWTXTRecord([
            LinkProtocol.txtMacID: macID.uuidString, LinkProtocol.txtVersion: String(LinkProtocol.version),
          ]))
      }
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready: self.state = .listening(port: listener.port?.rawValue ?? 0)
            case .failed(let error):
              self.state = .failed(error.localizedDescription)
              self.stopListener()
            case .cancelled: break
            default: break
            }
          }
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.accept(connection) }
        }
      }
      self.listener = listener
      state = .starting
      listener.start(queue: .main)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  public func stop() {
    stopListener()
    for session in sessions.values { session.link.cancel() }
    sessions = [:]
    connected = [:]
    pairingRequest = nil
    pairingOpen = false
    state = .stopped
  }

  private func stopListener() {
    listener?.cancel()
    listener = nil
  }

  /// Asks every connected device to send the reports it saved while the Mac was unreachable.
  /// Returns how many devices were asked.
  @discardableResult public func fetch() -> Int {
    let ready = sessions.values.filter(\.ready)
    for session in ready { session.link.send(.sendPending) }
    lastEvent = .fetched(devices: ready.count)
    return ready.count
  }

  // MARK: Pairing

  public func openPairing() {
    pairingOpen = true
    pairingRequest = nil
  }

  public func closePairing() {
    pairingOpen = false
    if pairingRequest != nil { declinePairing() }
  }

  public func confirmPairing() {
    guard let (id, session) = sessions.first(where: { $0.value.pendingKey != nil }),
      let hello = session.hello, let key = session.pendingKey
    else { return }
    _ = id
    let device = Device(
      id: hello.deviceID, name: hello.deviceName, model: hello.deviceModel,
      apps: hello.appName.isEmpty ? [] : [hello.appName], pairedAt: Date(), lastSeen: Date())
    records.removeAll { $0.device.id == hello.deviceID }
    records.append(DeviceRecord(device: device, key: key.data))
    persist()
    session.pendingKey = nil
    session.ready = true
    session.link.send(.welcome(macID: macID, macName: macName))
    connected[hello.deviceID] = 0
    pairingRequest = nil
    pairingOpen = false
    lastEvent = .paired(deviceName: hello.deviceName)
  }

  public func declinePairing() {
    if let session = sessions.values.first(where: { $0.pendingKey != nil }) {
      session.link.send(.rejected(.declined)) { _ in session.link.cancel() }
      session.pendingKey = nil
    }
    pairingRequest = nil
  }

  public func forget(_ deviceID: UUID) {
    records.removeAll { $0.device.id == deviceID }
    persist()
    for session in sessions.values where session.hello?.deviceID == deviceID {
      session.link.cancel()
    }
    connected[deviceID] = nil
  }

  private func persist() {
    saveRecords(records)
    devices = records.map(\.device)
  }

  // MARK: Connections

  private func accept(_ connection: NWConnection) {
    guard sessions.count < Self.maximumSessions else {
      connection.cancel()
      return
    }
    let link = LinkConnection(connection: connection)
    let session = Session(link: link)
    let key = ObjectIdentifier(session)
    sessions[key] = session
    link.onMessage = { [weak self, weak session] message in
      MainActor.assumeIsolated {
        guard let self, let session else { return }
        self.handle(message, from: session)
      }
    }
    link.onClose = { [weak self, weak session] _ in
      MainActor.assumeIsolated {
        guard let self, let session else { return }
        self.closed(session, key: key)
      }
    }
    link.start()
    // A connection that never says hello does not hold a slot.
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak session] in
      if let session, session.hello == nil { session.link.cancel() }
    }
  }

  private func closed(_ session: Session, key: ObjectIdentifier) {
    sessions[key] = nil
    if session.pendingKey != nil { pairingRequest = nil }
    if let id = session.hello?.deviceID, session.ready,
      !sessions.values.contains(where: { $0.ready && $0.hello?.deviceID == id })
    {
      connected[id] = nil
    }
  }

  private func reject(_ session: Session, _ reason: RejectReason) {
    session.link.send(.rejected(reason)) { _ in session.link.cancel() }
  }

  private func handle(_ message: LinkMessage, from session: Session) {
    switch message {
    case .hello(let hello):
      guard session.hello == nil else { return session.link.cancel() }
      session.hello = hello
      guard hello.protocolVersion == LinkProtocol.version else { return reject(session, .unsupportedVersion) }
      let serverNonce = Nonce.make()
      if let clientKey = hello.pairingPublicKey {
        guard pairingOpen else { return reject(session, .pairingClosed) }
        guard pairingRequest == nil else { return reject(session, .busy) }
        let exchange = PairingExchange()
        guard
          let result = try? exchange.complete(
            peerPublicKey: clientKey, clientPublicKey: clientKey, serverPublicKey: exchange.publicKey,
            clientNonce: hello.nonce, serverNonce: serverNonce)
        else { return session.link.cancel() }
        session.link.send(
          .challenge(
            Challenge(macID: macID, macName: macName, nonce: serverNonce, pairingPublicKey: exchange.publicKey)))
        session.link.secure(
          SecureChannel(pairingKey: result.pairingKey, clientNonce: hello.nonce, serverNonce: serverNonce, role: .server))
        session.pendingKey = result.pairingKey
        pairingRequest = PairingRequest(deviceName: hello.deviceName, appName: hello.appName, code: result.code)
      } else {
        guard let record = records.first(where: { $0.device.id == hello.deviceID }) else {
          return reject(session, .notPaired)
        }
        session.link.send(.challenge(Challenge(macID: macID, macName: macName, nonce: serverNonce)))
        session.link.secure(
          SecureChannel(
            pairingKey: SymmetricKey(data: record.key), clientNonce: hello.nonce, serverNonce: serverNonce,
            role: .server))
        session.ready = true
        session.link.send(.welcome(macID: macID, macName: macName))
        connected[hello.deviceID] = connected[hello.deviceID] ?? 0
        seen(hello)
      }
    case .report(let report):
      guard session.ready else { return session.link.cancel() }
      do {
        let result = try importReport(report)
        session.link.send(.ack(id: report.id))
        if result == .imported {
          lastEvent = .received(deviceName: session.hello?.deviceName ?? "")
        }
      } catch {
        session.link.send(.failed(id: report.id, message: error.localizedDescription))
      }
    case .status(let pending):
      guard session.ready, let id = session.hello?.deviceID else { return }
      connected[id] = max(0, pending)
    case .ping:
      break
    case .challenge, .rejected, .welcome, .ack, .failed, .sendPending:
      // Only the Mac sends these.
      session.link.cancel()
    }
  }

  private func seen(_ hello: Hello) {
    guard let index = records.firstIndex(where: { $0.device.id == hello.deviceID }) else { return }
    records[index].device.lastSeen = Date()
    records[index].device.name = hello.deviceName
    if !hello.appName.isEmpty, !records[index].device.apps.contains(hello.appName) {
      records[index].device.apps.append(hello.appName)
    }
    persist()
  }
}

/// Paired iOS devices and their keys, in the login Keychain.
public enum IOSReceiverKeychain {
  private static let service = "com.screenclip.app.ios-devices"
  private static let account = "devices"
  private static var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }
  public static func load() -> [IOSReceiver.DeviceRecord] {
    var read = query
    read[kSecReturnData as String] = true
    read[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
      return []
    }
    return (try? JSONDecoder().decode([IOSReceiver.DeviceRecord].self, from: data)) ?? []
  }
  public static func save(_ records: [IOSReceiver.DeviceRecord]) {
    guard !records.isEmpty, let data = try? JSONEncoder().encode(records) else {
      SecItemDelete(query as CFDictionary)
      return
    }
    if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
      return
    }
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(add as CFDictionary, nil)
  }
}
