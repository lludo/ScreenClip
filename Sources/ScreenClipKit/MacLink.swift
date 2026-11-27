#if os(iOS) && DEBUG
  import CryptoKit
  import Foundation
  import Network
  import Observation
  import ScreenClipWire
  import dnssd

  /// Finds ScreenClip on Macs on the local network, pairs with one, and delivers saved reports.
  @MainActor @Observable final class MacLink {
    struct DiscoveredMac: Identifiable, Equatable {
      var macID: UUID?
      /// The link protocol version the Mac advertises, when it advertises one.
      var protocolVersion: Int?
      var name: String
      var endpoint: NWEndpoint
      var id: String { name }
    }
    enum Phase: Equatable {
      case idle, missingInfoPlist, localNetworkDenied, searching
      case connecting(String)
      case pairing(code: String, macName: String)
      case connected(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var discovered: [DiscoveredMac] = []
    private(set) var pairings: [Pairing] = []
    private(set) var lastError: String?
    /// The Mac this device is connected to now.
    private(set) var connectedMacID: UUID?

    @ObservationIgnored private let outbox: Outbox
    @ObservationIgnored let sent: SentLog
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var link: LinkConnection?
    @ObservationIgnored private var linkMac: DiscoveredMac?
    @ObservationIgnored private var exchange: PairingExchange?
    @ObservationIgnored private var pendingPairing: Pairing?
    @ObservationIgnored private var clientNonce = Data()
    private(set) var inFlight: UUID?
    @ObservationIgnored private var skipped: Set<UUID> = []
    @ObservationIgnored private var waiters: [UUID: [(token: UUID, done: (Bool) -> Void)]] = [:]
    @ObservationIgnored private var suspended = true
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    @ObservationIgnored private let pairingStore: PairingKeychain<Pairing>

    init(outbox: Outbox, sent: SentLog, pairingStore: PairingKeychain<Pairing> = PairingKeychain(
      service: "com.mirageteam.screenclip.kit", account: "pairings")
    ) {
      self.outbox = outbox
      self.sent = sent
      self.pairingStore = pairingStore
    }

    var isConnected: Bool {
      if case .connected = phase { return true }
      return false
    }
    var connectedMacName: String? {
      if case .connected(let name) = phase { return name }
      return nil
    }
    var hasPairing: Bool { !pairings.isEmpty }

    /// The host's Info.plist must declare the Bonjour service and a Local Network reason.
    static var missingInfoPlistKeys: [String] {
      let info = Bundle.main.infoDictionary ?? [:]
      var missing: [String] = []
      if !((info["NSBonjourServices"] as? [String]) ?? []).contains(LinkProtocol.serviceType) {
        missing.append("NSBonjourServices (\(LinkProtocol.serviceType))")
      }
      if (info["NSLocalNetworkUsageDescription"] as? String)?.isEmpty ?? true {
        missing.append("NSLocalNetworkUsageDescription")
      }
      return missing
    }

    // MARK: Lifecycle

    func resume() {
      finishBackgroundDelivery()
      suspended = false
      do {
        pairings = try pairingStore.load()
      } catch {
        stopConnections()
        lastError = "Could not read Mac pairings: \(error.localizedDescription)"
        return
      }
      let missing = Self.missingInfoPlistKeys
      guard missing.isEmpty else {
        phase = .missingInfoPlist
        kitLog.error(
          "ScreenClipKit cannot reach your Mac: add \(missing.joined(separator: " and "), privacy: .public) to the Debug Info.plist. Reports are still saved on the device.")
        return
      }
      if browser == nil { startBrowser() }
      if phase == .idle { phase = .searching }
      autoConnect()
    }

    /// Going to the background: finish sending what is waiting first, within the time iOS gives.
    func suspend() {
      if isConnected, inFlight != nil || nextReport != nil {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ScreenClip delivery") { [weak self] in
          MainActor.assumeIsolated { self?.finishBackgroundDelivery() }
        }
        if backgroundTask != .invalid {
          flush()
          return
        }
      }
      stopConnections()
    }

    private func finishBackgroundDelivery() {
      guard backgroundTask != .invalid else { return }
      let task = backgroundTask
      backgroundTask = .invalid
      if UIApplication.shared.applicationState == .background { stopConnections() }
      UIApplication.shared.endBackgroundTask(task)
    }

    private func stopConnections() {
      suspended = true
      browser?.cancel()
      browser = nil
      closeLink()
      discovered = []
      if phase != .missingInfoPlist { phase = .idle }
    }

    private func startBrowser() {
      let browser = NWBrowser(
        for: .bonjourWithTXTRecord(type: LinkProtocol.serviceType, domain: nil),
        using: LinkConnection.tcpParameters())
      browser.stateUpdateHandler = { [weak self, weak browser] state in
        MainActor.assumeIsolated {
          guard let self, let browser, self.browser === browser else { return }
          self.browserStateChanged(state)
        }
      }
      browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
        MainActor.assumeIsolated {
          guard let self, let browser, self.browser === browser else { return }
          self.resultsChanged(results)
        }
      }
      self.browser = browser
      browser.start(queue: .main)
    }

    private func browserStateChanged(_ state: NWBrowser.State) {
      switch state {
      case .failed(let error), .waiting(let error):
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
          if link == nil { phase = .localNetworkDenied }
        } else {
          lastError = error.localizedDescription
        }
        if case .failed = state {
          browser?.cancel()
          browser = nil
          DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.suspended, self.browser == nil else { return }
            self.startBrowser()
          }
        }
      case .ready:
        if phase == .localNetworkDenied { phase = .searching }
      default: break
      }
    }

    private func resultsChanged(_ results: Set<NWBrowser.Result>) {
      discovered = results.compactMap { result in
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var macID: UUID?, version: Int?
        if case .bonjour(let txt) = result.metadata {
          macID = txt[LinkProtocol.txtMacID].flatMap(UUID.init(uuidString:))
          version = txt[LinkProtocol.txtVersion].flatMap(Int.init)
        }
        return DiscoveredMac(macID: macID, protocolVersion: version, name: name, endpoint: result.endpoint)
      }.sorted { $0.name < $1.name }
      autoConnect()
    }

    private func autoConnect() {
      guard !suspended, link == nil else { return }
      guard let mac = discovered.first(where: { mac in pairings.contains { $0.macID == mac.macID } }) else {
        return
      }
      connect(to: mac, pairing: false)
    }

    // MARK: Pairing

    func pair(with mac: DiscoveredMac) {
      closeLink()
      lastError = nil
      connect(to: mac, pairing: true)
    }

    func cancelPairing() {
      closeLink()
      phase = .searching
      autoConnect()
    }

    func forget(_ macID: UUID) {
      guard savePairings(pairings.filter { $0.macID != macID }) else { return }
      if connectedMacID == macID || linkMac?.macID == macID {
        closeLink()
        phase = suspended ? .idle : .searching
        autoConnect()
      }
    }

    func switchTo(_ mac: DiscoveredMac) {
      closeLink()
      connect(to: mac, pairing: false)
    }

    private func savePairings(_ updated: [Pairing]) -> Bool {
      do {
        try pairingStore.save(updated)
        pairings = updated
        return true
      } catch {
        lastError = "Could not save Mac pairings: \(error.localizedDescription)"
        return false
      }
    }

    // MARK: Delivery

    /// Earlier SDKs stored a name in history. Only use it if it identifies one paired Mac.
    private var uniqueMacName: String? {
      guard let name = connectedMacName, pairings.filter({ $0.macName == name }).count == 1 else { return nil }
      return name
    }

    func isDestination(_ destination: ReportDestination?) -> Bool {
      guard let id = connectedMacID else { return false }
      return destination?.matches(macID: id, name: uniqueMacName) ?? true
    }

    func destination(of report: ReportFile.Summary) -> ReportDestination? {
      report.destination ?? report.followUpOf.flatMap { original in sent.entries.first { $0.id == original }?.destination }
    }

    private var nextReport: ReportFile.Summary? {
      outbox.reports.first { !skipped.contains($0.id) && isDestination(destination(of: $0)) }
    }

    func flush() {
      guard inFlight == nil, let link else { return }
      guard let next = nextReport else { return finishBackgroundDelivery() }
      inFlight = next.id
      let file = outbox.url(for: next.id)
      Task { [self] in
        do {
          var report = try await Task.detached(priority: .utility) { try ReportFile.read(from: file) }.value
          guard self.link === link, inFlight == next.id, let macID = connectedMacID, let name = connectedMacName else { return }
          if report.destination?.macID == nil {
            // Bind offline reports before the first send so a lost ack can only retry on that Mac.
            report.destination = ReportDestination(macID: macID, name: name)
            try outbox.add(report)
          }
          link.send(.report(report)) { [weak self] error in
            guard let self, let error, self.link === link, self.inFlight == next.id else { return }
            if error is NWError { link.cancel() } else { self.deliveryFailed(next.id, error.localizedDescription) }
          }
        } catch {
          guard self.link === link, inFlight == next.id else { return }
          deliveryFailed(next.id, error.localizedDescription)
        }
      }
    }

    private func deliveryFailed(_ id: UUID, _ message: String) {
      lastError = message
      guard id == inFlight else { return }
      skipped.insert(id)
      inFlight = nil
      resolve(id, false)
      flush()
    }

    func deleteSaved(_ id: UUID) {
      guard id != inFlight else { return }
      do {
        try outbox.remove(id)
        sendQueue()
      } catch {
        lastError = error.localizedDescription
      }
    }

    /// Tells the Mac which reports are still waiting here.
    func sendQueue() {
      guard isConnected else { return }
      let waiting = outbox.reports.lazy.filter { self.isDestination(self.destination(of: $0)) }.prefix(200)
      link?.send(.queue(waiting.map { QueuedReport(id: $0.id, note: $0.note, createdAt: $0.createdAt) }))
    }

    /// Tells the Mac a merged fix works. Returns false when the Mac is not connected.
    @discardableResult func verify(_ id: UUID) -> Bool {
      guard let entry = sent.entries.first(where: { $0.id == id }), isDestination(entry.destination), let link else { return false }
      link.send(.verify(id: id))
      return true
    }

    /// Asks the Mac again where the sent reports stand.
    func refreshStatuses() {
      guard let id = connectedMacID else { return }
      link?.send(.track(ids: sent.trackedIDs(macID: id, name: uniqueMacName)))
    }

    func retryFailed() {
      skipped.removeAll()
      flush()
    }

    /// Calls `done(true)` when the Mac acknowledges the report, or `done(false)` after `timeout`.
    func whenDelivered(_ id: UUID, timeout: TimeInterval, done: @escaping (Bool) -> Void) {
      let token = UUID()
      waiters[id, default: []].append((token, done))
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
        guard let self, let index = self.waiters[id]?.firstIndex(where: { $0.token == token }) else { return }
        self.waiters[id]?.remove(at: index)
        if self.waiters[id]?.isEmpty == true { self.waiters[id] = nil }
        done(false)
      }
    }

    private func resolve(_ id: UUID, _ delivered: Bool) {
      let pending = waiters.removeValue(forKey: id) ?? []
      for waiter in pending { waiter.done(delivered) }
    }

    // MARK: Connection

    private func connect(to mac: DiscoveredMac, pairing: Bool) {
      let link = LinkConnection(
        connection: NWConnection(to: mac.endpoint, using: LinkConnection.tcpParameters()))
      self.link = link
      linkMac = mac
      clientNonce = Nonce.make()
      exchange = pairing ? PairingExchange() : nil
      pendingPairing = nil
      skipped.removeAll()
      phase = .connecting(mac.name)
      link.onReady = { [weak self, weak link] in
        MainActor.assumeIsolated {
          guard let self, let link, link === self.link else { return }
          link.send(.hello(self.hello()))
        }
      }
      link.onMessage = { [weak self, weak link] message in
        MainActor.assumeIsolated {
          guard let self, let link, link === self.link else { return }
          self.handle(message, on: link)
        }
      }
      link.onClose = { [weak self, weak link] error in
        MainActor.assumeIsolated {
          guard let self, let link, link === self.link else { return }
          self.linkClosed(error)
        }
      }
      link.start()
      DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak link] in
        guard let self, let link, self.link === link, case .connecting = self.phase else { return }
        self.lastError = "Your Mac did not finish connecting."
        link.cancel()
      }
    }

    /// Which side to update when the Mac and this SDK speak different link versions.
    static func versionMismatch(macVersion: Int?) -> String {
      guard let macVersion, macVersion != LinkProtocol.version else {
        return "ScreenClip on your Mac and the ScreenClipKit package in this app are different versions. Update both to the latest."
      }
      return macVersion < LinkProtocol.version
        ? "Update ScreenClip on your Mac to work with this version of the SDK."
        : "Update the ScreenClipKit package in this app to work with ScreenClip on your Mac."
    }

    private func hello() -> Hello {
      let info = Bundle.main.infoDictionary ?? [:]
      return Hello(
        deviceID: KitPreferences.deviceID, deviceName: UIDeviceName.current,
        deviceModel: UIDeviceName.model,
        appName: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "",
        // When pairing, the key and nonce stay back until the Mac has sent its own; the hello
        // only commits to them.
        bundleID: Bundle.main.bundleIdentifier ?? "", nonce: exchange == nil ? clientNonce : Data(),
        pairingCommitment: exchange.map {
          PairingExchange.commitment(publicKey: $0.publicKey, nonce: clientNonce)
        })
    }

    private func handle(_ message: LinkMessage, on link: LinkConnection) {
      switch message {
      case .challenge(let challenge):
        guard case .connecting = phase, linkMac?.macID == nil || linkMac?.macID == challenge.macID else { return link.cancel() }
        if let exchange {
          guard let serverKey = challenge.pairingPublicKey,
            let result = try? exchange.complete(
              peerPublicKey: serverKey, clientPublicKey: exchange.publicKey, serverPublicKey: serverKey,
              clientNonce: clientNonce, serverNonce: challenge.nonce)
          else { return link.cancel() }
          link.send(.pairReveal(publicKey: exchange.publicKey, nonce: clientNonce))
          pendingPairing = Pairing(
            macID: challenge.macID, macName: challenge.macName, key: result.pairingKey.data, pairedAt: Date())
          link.secure(
            SecureChannel(
              pairingKey: result.pairingKey, clientNonce: clientNonce, serverNonce: challenge.nonce, role: .client))
          phase = .pairing(code: result.code, macName: challenge.macName)
        } else {
          guard let pairing = pairings.first(where: { $0.macID == challenge.macID }) else { return link.cancel() }
          link.secure(
            SecureChannel(
              pairingKey: SymmetricKey(data: pairing.key), clientNonce: clientNonce,
              serverNonce: challenge.nonce, role: .client))
        }
      case .welcome(let macID, let macName):
        if var pairing = pendingPairing, pairing.macID == macID {
          pairing.macName = macName
          guard savePairings(pairings.filter { $0.macID != macID } + [pairing]) else { return link.cancel() }
          pendingPairing = nil
          exchange = nil
        } else if exchange == nil, linkMac?.macID == macID, let index = pairings.firstIndex(where: { $0.macID == macID }) {
          if pairings[index].macName != macName {
            var updated = pairings
            updated[index].macName = macName
            guard savePairings(updated) else { return link.cancel() }
          }
        } else { return link.cancel() }
        lastError = nil
        connectedMacID = macID
        phase = .connected(macName)
        sendQueue()
        refreshStatuses()
        flush()
      case .rejected(let reason):
        switch reason {
        case .notPaired:
          lastError = "Your Mac no longer knows this device. Forget it here and pair again."
        case .pairingClosed:
          lastError = "On your Mac, open ScreenClip Settings > iOS and click Pair a device, then try again."
        case .declined:
          lastError = "Pairing was declined on the Mac."
        case .unsupportedVersion:
          lastError = Self.versionMismatch(macVersion: linkMac?.protocolVersion)
        case .busy:
          lastError = "Your Mac is busy. Try again in a moment."
        }
        closeLink()
        phase = .searching
        // closeLink() silences the link's own close callback, which is what schedules the next
        // attempt. A busy Mac is worth another try, and a pairing that did not happen should
        // not leave the device off the Mac it was already paired with. A Mac that no longer
        // knows this device, or speaks another version, would only refuse again.
        switch reason {
        case .busy, .pairingClosed, .declined:
          DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.autoConnect() }
        case .notPaired, .unsupportedVersion: break
        }
      case .sendPending:
        retryFailed()
      case .ack(let id):
        guard inFlight == id, let macID = connectedMacID, let name = connectedMacName else { return }
        do {
          if let report = outbox.reports.first(where: { $0.id == id }) {
            try sent.record(report, macID: macID, macName: name)
          }
          try outbox.remove(id)
        } catch {
          return deliveryFailed(id, error.localizedDescription)
        }
        skipped.remove(id)
        inFlight = nil
        resolve(id, true)
        sendQueue()
        flush()
      case .reportStates(let states):
        if let id = connectedMacID { sent.update(states, macID: id, name: uniqueMacName) }
      case .failed(let id, let text):
        deliveryFailed(id, text)
      case .hello, .pairReveal, .report, .queue, .track, .verify, .ping:
        break
      }
    }

    private func linkClosed(_ error: Error?) {
      defer { finishBackgroundDelivery() }
      let wasPairing: Bool
      if case .pairing = phase { wasPairing = true } else { wasPairing = false }
      link = nil
      linkMac = nil
      connectedMacID = nil
      inFlight = nil
      exchange = nil
      pendingPairing = nil
      if wasPairing, lastError == nil { lastError = "Pairing did not finish." }
      if phase != .missingInfoPlist { phase = suspended ? .idle : .searching }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.autoConnect() }
    }

    private func closeLink() {
      let current = link
      link = nil
      linkMac = nil
      connectedMacID = nil
      inFlight = nil
      exchange = nil
      pendingPairing = nil
      current?.cancel()
    }
  }

  import UIKit

  @MainActor enum UIDeviceName {
    static var current: String { UIDevice.current.name }
    static var model: String { DeviceInfo.modelIdentifier() }
  }
#endif
