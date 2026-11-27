import Combine
import CryptoKit
import Foundation
import Network

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
  /// The saved reports each connected device says it is holding.
  @Published public private(set) var deviceQueues: [UUID: [QueuedReport]] = [:]
  @Published public private(set) var pairingOpen = false
  @Published public private(set) var pairingRequest: PairingRequest?
  @Published public private(set) var lastEvent: Event?

  public let macID: UUID
  public let macName: String
  /// Saves one report into the queue. Throws to refuse it; the device keeps it and retries.
  public var importReport: (WireReport) throws -> ImportResult = { _ in
    throw ScreenClipError.message("The report queue is unavailable.")
  }
  /// The current state of delivered reports, by report id, for devices' Sent lists.
  public var reportStates: ([UUID]) -> [ReportState] = { _ in [] }
  /// Marks a merged report verified. Throws when it cannot be.
  public var verifyReport: (UUID) throws -> Void = { _ in
    throw ScreenClipError.message("The report queue is unavailable.")
  }
  private let loadRecords: () throws -> [DeviceRecord]
  private let saveRecords: ([DeviceRecord]) throws -> Void
  @Published public private(set) var storageError: String?
  private var records: [DeviceRecord] = []
  private weak var pairingSession: Session?
  private var listener: NWListener?
  private var sessions: [ObjectIdentifier: Session] = [:]
  static let maximumSessions = 16

  final class Session {
    let link: LinkConnection
    var hello: Hello?
    var ready = false
    var awaitingProof = false
    var pendingKey: SymmetricKey?
    /// Set between a pairing hello and its reveal: the Mac's half of the exchange and its nonce.
    var pairing: (exchange: PairingExchange, serverNonce: Data, commitment: Data)?
    /// Reports this device shows in its Sent list, and the states it last received.
    var tracked: [UUID] = []
    var sentStates: [UUID: ReportState] = [:]
    init(link: LinkConnection) { self.link = link }
  }

  public init(
    macID: UUID = IOSReceiver.storedMacID(), macName: String = IOSReceiver.defaultMacName(),
    loadRecords: @escaping () throws -> [DeviceRecord] = IOSReceiverKeychain.store.load,
    saveRecords: @escaping ([DeviceRecord]) throws -> Void = IOSReceiverKeychain.store.save
  ) {
    self.macID = macID
    self.macName = macName
    self.loadRecords = loadRecords
    self.saveRecords = saveRecords
    reloadRecords()
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

  static let restartDelay: TimeInterval = 5

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
              self.scheduleRestart(port: port, advertise: advertise)
            case .cancelled: break
            default: break
            }
          }
        }
      }
      listener.newConnectionHandler = { [weak self, weak listener] connection in
        MainActor.assumeIsolated {
          guard let self, let listener, listener === self.listener else { return connection.cancel() }
          self.accept(connection)
        }
      }
      self.listener = listener
      state = .starting
      listener.start(queue: .main)
    } catch {
      state = .failed(error.localizedDescription)
      scheduleRestart(port: port, advertise: advertise)
    }
  }

  /// A listener that fails (the network changed, mDNSResponder restarted) or cannot be created
  /// stays down. Try again while the server is still meant to be on, so devices do not queue
  /// reports until someone toggles the setting.
  private func scheduleRestart(port: NWEndpoint.Port, advertise: Bool) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, case .failed = self.state, self.listener == nil else { return }
        self.start(port: port, advertise: advertise)
      }
    }
  }

  public func stop() {
    stopListener()
    for session in sessions.values { session.link.cancel() }
    sessions = [:]
    connected = [:]
    deviceQueues = [:]
    pairingSession = nil
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
  }

  public func closePairing() {
    pairingOpen = false
    if pairingRequest != nil || pairingSession != nil { declinePairing() }
  }

  public func confirmPairing(requestID: UUID? = nil) {
    guard pairingOpen, let request = pairingRequest, requestID == nil || request.id == requestID,
      let session = pairingSession, let hello = session.hello, let key = session.pendingKey
    else { return }
    let device = Device(
      id: hello.deviceID, name: hello.deviceName, model: hello.deviceModel,
      apps: hello.appName.isEmpty ? [] : [hello.appName], pairedAt: Date(), lastSeen: Date())
    guard persist(records.filter { $0.device.id != hello.deviceID } + [DeviceRecord(device: device, key: key.data)]) else {
      declinePairing()
      return
    }
    for other in sessions.values where other !== session && other.hello?.deviceID == hello.deviceID {
      disconnect(other)
    }
    session.pendingKey = nil
    session.ready = true
    session.link.send(.welcome(macID: macID, macName: macName))
    connected[hello.deviceID] = 0
    pairingSession = nil
    pairingRequest = nil
    pairingOpen = false
    lastEvent = .paired(deviceName: hello.deviceName)
  }

  public func declinePairing() {
    if let session = pairingSession {
      session.pendingKey = nil
      // Before the reveal the device is not reading clear frames any more: it waits for sealed
      // ones, so a rejection would not be understood. Closing the connection is.
      if session.pairing != nil { session.link.cancel() } else { reject(session, .declined) }
      session.pairing = nil
    }
    pairingSession = nil
    pairingRequest = nil
  }

  public func forget(_ deviceID: UUID) {
    if storageError != nil { reloadRecords() }
    guard storageError == nil else { return }
    guard persist(records.filter { $0.device.id != deviceID }) else { return }
    for session in sessions.values where session.hello?.deviceID == deviceID {
      disconnect(session)
    }
    connected[deviceID] = nil
    deviceQueues[deviceID] = nil
  }

  private func disconnect(_ session: Session) {
    closed(session, key: ObjectIdentifier(session))
    session.link.cancel()
  }

  private func reloadRecords() {
    do {
      records = try loadRecords()
      devices = records.map(\.device)
      storageError = nil
    } catch {
      storageError = error.localizedDescription
    }
  }

  @discardableResult private func persist(_ updated: [DeviceRecord]) -> Bool {
    do {
      try saveRecords(updated)
      records = updated
      devices = updated.map(\.device)
      storageError = nil
      return true
    } catch {
      storageError = error.localizedDescription
      return false
    }
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
        guard let self, let session, self.sessions[key] === session else { return }
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
      if let session, session.hello == nil || session.awaitingProof || session.pairing != nil {
        session.link.cancel()
      }
    }
  }

  private func closed(_ session: Session, key: ObjectIdentifier) {
    guard sessions.removeValue(forKey: key) != nil else { return }
    if pairingSession === session {
      pairingSession = nil
      pairingRequest = nil
    }
    if let id = session.hello?.deviceID, session.ready,
      !sessions.values.contains(where: { $0.ready && $0.hello?.deviceID == id })
    {
      connected[id] = nil
      deviceQueues[id] = nil
    }
  }

  /// Sends devices the reports whose state changed since they last heard. Call after the queue
  /// changes; unchanged states are not resent.
  public func reportsChanged() {
    for session in sessions.values where session.ready && !session.tracked.isEmpty {
      sendStates(to: session, ids: session.tracked)
    }
  }

  private func sendStates(to session: Session, ids: [UUID], force: Bool = false) {
    let changed = reportStates(ids).filter { force || session.sentStates[$0.id] != $0 }
    guard !changed.isEmpty else { return }
    for state in changed { session.sentStates[state.id] = state }
    session.link.send(.reportStates(changed))
  }

  private func reject(_ session: Session, _ reason: RejectReason) {
    session.link.send(.rejected(reason)) { _ in session.link.cancel() }
  }

  private func handle(_ message: LinkMessage, from session: Session) {
    if session.awaitingProof {
      // LinkConnection has authenticated this first sealed frame with the stored device key.
      guard !message.isHandshake, let hello = session.hello else { return session.link.cancel() }
      session.awaitingProof = false
      session.ready = true
      connected[hello.deviceID] = connected[hello.deviceID] ?? 0
      seen(hello)
    }
    switch message {
    case .hello(let hello):
      guard session.hello == nil else { return session.link.cancel() }
      if storageError != nil { reloadRecords() }
      guard storageError == nil else { return reject(session, .busy) }
      session.hello = hello
      // Version 2 changed only how a device pairs. A device paired under version 1 connects
      // the same way as before, so it keeps delivering until its app updates the SDK.
      let pairedEarlier =
        hello.protocolVersion == LinkProtocol.earliestSessionVersion && hello.pairingPublicKey == nil
        && hello.pairingCommitment == nil
      guard hello.protocolVersion == LinkProtocol.version || pairedEarlier else {
        return reject(session, .unsupportedVersion)
      }
      let serverNonce = Nonce.make()
      if let commitment = hello.pairingCommitment {
        guard pairingOpen else { return reject(session, .pairingClosed) }
        guard pairingSession == nil, pairingRequest == nil else { return reject(session, .busy) }
        // The Mac's key and nonce go out before the device shows its own, which the hello only
        // committed to. The code is derived once the reveal matches that commitment.
        let exchange = PairingExchange()
        session.pairing = (exchange, serverNonce, commitment)
        pairingSession = session
        session.link.send(
          .challenge(
            Challenge(macID: macID, macName: macName, nonce: serverNonce, pairingPublicKey: exchange.publicKey)))
        session.link.continueHandshake()
      } else {
        guard let record = records.first(where: { $0.device.id == hello.deviceID }) else {
          return reject(session, .notPaired)
        }
        session.link.send(.challenge(Challenge(macID: macID, macName: macName, nonce: serverNonce)))
        session.link.secure(
          SecureChannel(
            pairingKey: SymmetricKey(data: record.key), clientNonce: hello.nonce, serverNonce: serverNonce,
            role: .server))
        session.awaitingProof = true
        session.link.send(.welcome(macID: macID, macName: macName))
      }
    case .pairReveal(let clientKey, let clientNonce):
      guard let pairing = session.pairing, pairingSession === session, pairingOpen, let hello = session.hello,
        PairingExchange.reveals(pairing.commitment, publicKey: clientKey, nonce: clientNonce),
        let result = try? pairing.exchange.complete(
          peerPublicKey: clientKey, clientPublicKey: clientKey, serverPublicKey: pairing.exchange.publicKey,
          clientNonce: clientNonce, serverNonce: pairing.serverNonce)
      else { return session.link.cancel() }
      session.pairing = nil
      session.link.secure(
        SecureChannel(
          pairingKey: result.pairingKey, clientNonce: clientNonce, serverNonce: pairing.serverNonce,
          role: .server))
      session.pendingKey = result.pairingKey
      pairingRequest = PairingRequest(deviceName: hello.deviceName, appName: hello.appName, code: result.code)
    case .report(let report):
      guard session.ready else { return session.link.cancel() }
      do {
        let result = try importReport(report)
        session.link.send(.ack(id: report.id))
        if !session.tracked.contains(report.id) {
          session.tracked.insert(report.id, at: 0)
          if session.tracked.count > 100, let removed = session.tracked.popLast() { session.sentStates[removed] = nil }
        }
        sendStates(to: session, ids: [report.id])
        if result == .imported {
          lastEvent = .received(deviceName: session.hello?.deviceName ?? "")
        }
      } catch {
        session.link.send(.failed(id: report.id, message: error.localizedDescription))
      }
    case .queue(let items):
      guard session.ready, let id = session.hello?.deviceID else { return }
      let list = Array(items.prefix(200))
      connected[id] = list.count
      deviceQueues[id] = list
    case .track(let ids):
      guard session.ready else { return }
      session.tracked = Array(ids.prefix(100))
      session.sentStates.removeAll()
      sendStates(to: session, ids: session.tracked, force: true)
    case .verify(let id):
      guard session.ready else { return session.link.cancel() }
      do {
        try verifyReport(id)
      } catch {
        session.link.send(.failed(id: id, message: error.localizedDescription))
      }
      sendStates(to: session, ids: [id], force: true)
    case .ping:
      break
    case .challenge, .rejected, .welcome, .ack, .failed, .sendPending, .reportStates:
      // Only the Mac sends these.
      session.link.cancel()
    }
  }

  private func seen(_ hello: Hello) {
    guard let index = records.firstIndex(where: { $0.device.id == hello.deviceID }) else { return }
    var updated = records
    updated[index].device.lastSeen = Date()
    updated[index].device.name = hello.deviceName
    if !hello.appName.isEmpty, !updated[index].device.apps.contains(hello.appName) {
      updated[index].device.apps.append(hello.appName)
    }
    persist(updated)
  }
}

/// Paired iOS devices and their keys, in the login Keychain.
public enum IOSReceiverKeychain {
  public static let store = PairingKeychain<IOSReceiver.DeviceRecord>(service: "com.screenclip.app.ios-devices", account: "devices")
  public static func load() -> [IOSReceiver.DeviceRecord] { (try? store.load()) ?? [] }
  public static func save(_ records: [IOSReceiver.DeviceRecord]) { try? store.save(records) }
}
